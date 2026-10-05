mod host_tests;
mod snapshot_tests;

use super::*;
use crossbeam_channel::unbounded;

// Use a controlled worker: test protocol/lifecycle boundaries without timing a compiler.
fn server(connection: &Connection) -> (Server<'_>, crossbeam_channel::Receiver<Job>) {
    let (jobs, requests) = unbounded();
    let (_, results) = unbounded();
    let root = std::env::current_dir().unwrap();
    let config = Config {
        client_root: root.clone(),
        root,
        evaluation: EvalParams {
            entry: "lsp.typ".into(),
            inputs: BTreeMap::new(),
            ..Default::default()
        },
        code_actions: false,
        disabled_actions: false,
        diagnostic_versions: false,
        watch_registration: false,
        relative_patterns: false,
        work_done_progress: true,
        host_write_root: None,
    };
    (
        Server {
            connection,
            config,
            worker: Worker {
                jobs,
                results,
                events: crossbeam_channel::never(),
            },
            progress: Progress::new(true),
            index_ready: false,
            restored_dependencies: None,
            documents: BTreeMap::new(),
            generation: 0,
            active: None,
            cache: None,
            waiting: HashMap::new(),
            commands: VecDeque::new(),
            published: BTreeSet::new(),
            due: Some(Instant::now()),
            watching: true,
            shutdown: false,
        },
        requests,
    )
}

fn begin(server: &mut Server<'_>, client: &Connection) -> Result<()> {
    server.schedule()?;
    server.progress.tick(server.connection, Instant::now())?;
    let Message::Request(create) = client.receiver.try_recv()? else {
        panic!("expected create")
    };
    assert_eq!(create.method, "window/workDoneProgress/create");
    server.client_response(Response::new_ok(create.id, ()))?;
    let Message::Notification(begin) = client.receiver.try_recv()? else {
        panic!("expected begin")
    };
    assert_eq!(begin.params["value"]["kind"], "begin");
    Ok(())
}

fn output() -> Result<Output, ResponseError> {
    Ok(Output {
        revision: 1,
        output: json!({}),
        warnings: vec![],
        dependencies: Dependencies::default(),
        reads: BTreeMap::new(),
    })
}

fn progress_values(client: &Connection) -> Vec<Value> {
    client
        .receiver
        .try_iter()
        .filter_map(|message| match message {
            Message::Notification(n) if n.method == "$/progress" => Some(n.params["value"].clone()),
            _ => None,
        })
        .collect()
}

#[test]
fn ready_follows_publication_and_cache_installation() -> Result<()> {
    let (connection, client) = Connection::memory();
    let (mut server, _jobs) = server(&connection);
    begin(&mut server, &client)?;
    // A previous publication must be cleared before readiness is announced.
    server
        .published
        .insert(Url::from_file_path(server.config.root.join("note.typ")).unwrap());
    server.completed(output())?;
    assert!(server.index_ready);
    assert!(server.cache.as_ref().unwrap().is_ok());
    let messages: Vec<_> = client.receiver.try_iter().collect();
    let methods: Vec<_> = messages
        .iter()
        .map(|m| match m {
            Message::Notification(n) => n.method.as_str(),
            _ => "other",
        })
        .collect();
    assert_eq!(
        methods,
        [
            "$/progress",
            "textDocument/publishDiagnostics",
            "$/progress"
        ]
    );
    let Message::Notification(end) = messages.last().unwrap() else {
        unreachable!()
    };
    assert_eq!(end.params["value"]["kind"], "end");
    assert_eq!(end.params["value"]["message"], "Knowledge index ready");
    Ok(())
}

#[test]
fn failed_or_invalid_outputs_end_without_claiming_ready() -> Result<()> {
    for result in [
        Err(failure(ErrorCode::RequestFailed, "compile failed")),
        Ok(Output {
            revision: 1,
            output: json!(false),
            warnings: vec![],
            dependencies: Dependencies::default(),
            reads: BTreeMap::new(),
        }),
    ] {
        let (connection, client) = Connection::memory();
        let (mut server, _jobs) = server(&connection);
        begin(&mut server, &client)?;
        server.completed(result)?;
        assert!(!server.index_ready);
        assert!(server.cache.as_ref().unwrap().is_err());
        let values = progress_values(&client);
        assert_eq!(values.last().unwrap()["kind"], "end");
        assert!(
            values.last().unwrap()["message"]
                .as_str()
                .unwrap()
                .contains("failed")
        );
    }
    Ok(())
}

#[test]
fn superseded_results_keep_one_startup_task_until_current_result() -> Result<()> {
    let (connection, client) = Connection::memory();
    let (mut server, _jobs) = server(&connection);
    begin(&mut server, &client)?;
    server.changed()?;
    server.completed(output())?;
    assert!(!server.index_ready);
    assert!(server.cache.is_none());
    assert!(client.receiver.is_empty());
    for _ in 0..2 {
        server.due = Some(Instant::now());
        server.schedule()?;
        server.progress.tick(&connection, Instant::now())?;
        assert!(client.receiver.is_empty());
        server.changed()?;
        server.completed(output())?;
        assert!(client.receiver.is_empty());
    }
    server.due = Some(Instant::now());
    server.schedule()?;
    server.completed(output())?;
    assert!(server.index_ready);
    let values = progress_values(&client);
    assert_eq!(
        values
            .iter()
            .map(|v| v["kind"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["report", "end"]
    );
    Ok(())
}

#[test]
fn shutdown_balances_progress_before_reply_and_late_completion_is_silent() -> Result<()> {
    let (connection, client) = Connection::memory();
    let (mut server, _jobs) = server(&connection);
    begin(&mut server, &client)?;
    server.request(Request::new(99.into(), "shutdown".into(), Value::Null))?;
    let messages: Vec<_> = client.receiver.try_iter().collect();
    let Message::Notification(end) = &messages[0] else {
        panic!("expected end")
    };
    assert_eq!(end.params["value"]["kind"], "end");
    assert!(matches!(messages.last(), Some(Message::Response(_))));
    server.completed(output())?;
    assert!(client.receiver.is_empty());
    Ok(())
}

#[test]
fn commands_and_updates_after_startup_stay_silent_even_if_slow_or_failed() -> Result<()> {
    let (connection, client) = Connection::memory();
    let (mut server, _jobs) = server(&connection);
    server.due = None;
    server
        .commands
        .push_back((1.into(), server.config.evaluation.clone()));
    server.schedule()?;
    server
        .progress
        .tick(&connection, Instant::now() + Duration::from_secs(1))?;
    assert!(client.receiver.is_empty());
    server.completed(output())?;
    assert!(matches!(client.receiver.try_recv()?, Message::Response(_)));
    assert!(!server.index_ready);
    server.due = Some(Instant::now());
    begin(&mut server, &client)?;
    server.completed(output())?;
    progress_values(&client);
    for result in [
        output(),
        Err(failure(ErrorCode::RequestFailed, "edit failed")),
        output(),
    ] {
        server.changed()?;
        server.due = Some(Instant::now());
        server.schedule()?;
        server
            .progress
            .tick(&connection, Instant::now() + Duration::from_secs(60))?;
        assert!(server.progress.deadline().is_none());
        server.completed(result)?;
        let messages: Vec<_> = client.receiver.try_iter().collect();
        assert!(messages.iter().all(|message| match message {
            Message::Notification(n) => n.method != "$/progress",
            Message::Request(_) => false,
            _ => true,
        }));
    }
    Ok(())
}

#[test]
fn capability_is_opt_in() -> Result<()> {
    for supported in [false, true] {
        let params = serde_json::from_value(json!({
            "capabilities": {"window": {"workDoneProgress": supported}},
            "initializationOptions": {"entry": "lsp.typ"}
        }))?;
        let config = Config::from_initialize(params, Some(std::env::current_dir()?))?;
        assert_eq!(config.work_done_progress, supported);
    }
    let params = serde_json::from_value(json!({
        "capabilities": {}, "initializationOptions": {"entry": "lsp.typ"}
    }))?;
    assert!(!Config::from_initialize(params, Some(std::env::current_dir()?))?.work_done_progress);
    Ok(())
}

#[test]
fn detached_command_schedules_only_explicit_sources() -> Result<()> {
    let (connection, client) = Connection::memory();
    let (mut server, jobs) = server(&connection);
    server.due = None;
    server.documents.insert(
        "main.typ".into(),
        Document {
            uri: Url::from_file_path(server.config.root.join("main.typ")).unwrap(),
            version: 1,
            text: "unsaved".into(),
        },
    );
    server.request(Request::new(91.into(), "workspace/executeCommand".into(), json!({
        "command": "zettyp.evalDetached", "arguments": [{"entry": "main.typ", "sources": {"gone.typ": null}}]
    })))?;
    server.schedule()?;
    let job = jobs.recv()?;
    assert!(job.params.detached);
    assert!(job.sources.is_empty());
    assert_eq!(
        job.params.sources.get(std::path::Path::new("gone.typ")),
        Some(&None)
    );
    server.completed(output())?;
    assert!(server.cache.is_none());
    let Message::Response(response) = client.receiver.recv()? else {
        panic!("response expected")
    };
    assert_eq!(response.result.unwrap()["reads"], json!({}));
    Ok(())
}

#[test]
fn detached_survives_document_changes_during_evaluation() -> Result<()> {
    let (connection, client) = Connection::memory();
    let (mut server, _jobs) = server(&connection);
    server.active = Some(Active {
        generation: 0,
        kind: Kind::Detached(Some(92.into())),
    });
    server.changed()?;
    server.completed(output())?;
    let response = client
        .receiver
        .try_iter()
        .find_map(|message| match message {
            Message::Response(response) => Some(response),
            _ => None,
        })
        .unwrap();
    assert!(response.error.is_none());
    assert_eq!(response.result.unwrap()["revision"], 1);
    Ok(())
}
