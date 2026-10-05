use super::*;
use crate::snapshot::Payload;
use zettyp_eval::content_hash;

fn payload(root: &Path) -> Payload {
    Payload {
        dependencies: serde_json::from_value(json!({
            "files": [{"path": root.join("main.typ"), "hash": content_hash(b"original")}],
            "packages": [], "font_book": null, "unsupported": null
        }))
        .unwrap(),
        output: json!({"lsp.hover": [{
            "applies-to": {"source": root.join("main.typ"), "range-utf16": {"start": {"line":0,"character":0}, "end":{"line":0,"character":8}}},
            "contents": {"kind":"plaintext", "value":"restored hover"}
        }]}),
        warnings: vec![],
    }
}

fn open(root: &Path, text: &str) -> Notification {
    Notification::new(
        "textDocument/didOpen".into(),
        json!({"textDocument": {
            "uri": Url::from_file_path(root.join("main.typ")).unwrap(),
            "languageId": "typst", "version":1, "text":text
        }}),
    )
}

fn hover(root: &Path) -> Request {
    Request::new(
        42.into(),
        "textDocument/hover".into(),
        json!({
            "textDocument":{"uri":Url::from_file_path(root.join("main.typ")).unwrap()},
            "position":{"line":0,"character":1}
        }),
    )
}

#[test]
fn snapshot_serves_hover_before_warmup_and_identical_open_preserves_it() -> Result<()> {
    let root = tempfile::tempdir()?;
    let root = root.path().canonicalize()?;
    std::fs::write(root.join("main.typ"), "original")?;
    let (connection, client) = Connection::memory();
    let (mut server, _jobs) = server(&connection);
    server.config.root = root.clone();
    server.config.client_root = root.clone();
    begin(&mut server, &client)?;
    server.worker_event(Event::Restored(payload(&root)))?;
    assert!(server.active.is_some(), "warmup still active");
    assert!(server.restored_dependencies.is_some());
    server.notification(open(&root, "original"))?;
    assert_eq!(server.generation, 0);
    progress_values(&client);
    server.request(hover(&root))?;
    let Message::Response(response) = client.receiver.try_recv()? else {
        panic!("query not answered")
    };
    assert_eq!(
        response.result.unwrap()["contents"]["value"],
        "restored hover"
    );
    server.completed(output())?;
    assert!(server.restored_dependencies.is_none());
    Ok(())
}

#[test]
fn different_buffer_or_unobserved_disk_change_invalidates_before_query() -> Result<()> {
    for disk in [false, true] {
        let dir = tempfile::tempdir()?;
        let root = dir.path().canonicalize()?;
        std::fs::write(root.join("main.typ"), "original")?;
        let (connection, client) = Connection::memory();
        let (mut server, _jobs) = server(&connection);
        server.config.root = root.clone();
        server.config.client_root = root.clone();
        server.watching = false;
        begin(&mut server, &client)?;
        server.worker_event(Event::Restored(payload(&root)))?;
        progress_values(&client);
        if disk {
            std::fs::write(root.join("main.typ"), "changed!")?;
        } else {
            server.notification(open(&root, "unsaved"))?;
        }
        server.request(hover(&root))?;
        assert!(server.cache.is_none());
        assert!(server.restored_dependencies.is_none());
        assert!(server.waiting.contains_key(&RequestId::from(42)));
        assert!(client.receiver.try_iter().all(|message| match message {
            Message::Response(_) => false,
            Message::Notification(n) => n.method != "$/progress",
            _ => true,
        }));
    }
    Ok(())
}

#[test]
fn late_snapshot_after_change_is_not_installed_and_error_drops_old_success() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let root = dir.path().canonicalize()?;
    std::fs::write(root.join("main.typ"), "original")?;
    let (connection, client) = Connection::memory();
    let (mut server, _jobs) = server(&connection);
    server.config.root = root.clone();
    server.config.client_root = root.clone();
    begin(&mut server, &client)?;
    server.changed()?;
    server.worker_event(Event::Restored(payload(&root)))?;
    assert!(server.cache.is_none());
    server.completed(output())?;
    progress_values(&client);
    server.due = Some(Instant::now());
    server.schedule()?;
    server.progress.tick(&connection, Instant::now())?;
    assert!(client.receiver.is_empty());
    server.worker_event(Event::Restored(payload(&root)))?;
    assert!(server.cache.as_ref().unwrap().is_ok());
    server.completed(Err(failure(
        ErrorCode::RequestFailed,
        "fresh compilation failed",
    )))?;
    assert!(server.cache.as_ref().unwrap().is_err());
    assert!(server.restored_dependencies.is_none());
    Ok(())
}

#[test]
#[cfg(not(unix))]
fn unsupported_storage_evaluates_sources_and_answers_queued_hover() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let root = dir.path().canonicalize()?;
    std::fs::write(
        root.join("main.typ"),
        r#"#metadata((tag: label("lsp.hover"), value: (
  applies-to: (source: sys.inputs.source, range-utf16: (
    start: (line: 0, character: 0), end: (line: 0, character: 8),
  )),
  contents: (kind: "plaintext", value: "fresh hover"),
)))<eval.announcement>"#,
    )?;
    let (connection, client) = Connection::memory();
    let (mut server, _jobs) = server(&connection);
    server.config.root = root.clone();
    server.config.client_root = root.clone();
    server.config.evaluation = EvalParams {
        entry: "main.typ".into(),
        inputs: BTreeMap::from([(
            "source".into(),
            root.join("main.typ").to_str().unwrap().into(),
        )]),
        ..Default::default()
    };
    server.worker = Worker::start(
        root.clone(),
        WorldOptions {
            ignore_system_fonts: true,
            ..Default::default()
        },
    )?;
    begin(&mut server, &client)?;
    server.request(hover(&root))?;
    assert!(server.cache.is_none());
    assert!(server.waiting.contains_key(&RequestId::from(42)));

    let result = server
        .worker
        .results
        .recv_timeout(Duration::from_secs(30))?;
    // Receiving the result also synchronizes the preceding restore attempt.
    let mut cold_start = false;
    for event in server.worker.events.try_iter().collect::<Vec<_>>() {
        match &event {
            Event::Status("No valid snapshot; evaluating project sources") => cold_start = true,
            Event::Status(_) => {}
            Event::Restored(_) => panic!("unsupported storage restored a snapshot"),
        }
        server.worker_event(event)?;
    }
    assert!(cold_start);
    progress_values(&client);
    server.completed(result)?;
    assert!(server.index_ready);
    assert!(server.cache.as_ref().unwrap().is_ok());
    assert!(server.restored_dependencies.is_none());
    assert!(server.waiting.is_empty());

    // The queued query and a later query both use the freshly evaluated index.
    for queued in [true, false] {
        if !queued {
            server.request(hover(&root))?;
        }
        let responses: Vec<_> = client
            .receiver
            .try_iter()
            .filter_map(|message| match message {
                Message::Response(response) => Some(response),
                _ => None,
            })
            .collect();
        assert_eq!(responses.len(), 1);
        assert_eq!(responses[0].id, RequestId::from(42));
        assert!(responses[0].error.is_none());
        assert_eq!(
            responses[0].result.as_ref().unwrap()["contents"]["value"],
            "fresh hover"
        );
    }
    Ok(())
}
