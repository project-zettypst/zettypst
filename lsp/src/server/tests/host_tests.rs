use super::*;

fn write_output() -> Output {
    Output {
        revision: 1,
        output: json!({"host.write-file": [{
            "version": 1, "id": "titles", "path": "cache/titles.toml", "content": "title = '测试'"
        }]}),
        warnings: vec![],
        dependencies: Dependencies::default(),
        reads: BTreeMap::new(),
    }
}

#[test]
fn only_current_lsp_results_write() -> Result<()> {
    for case in [
        "current",
        "stale",
        "shutdown",
        "command",
        "cancelled",
        "failure",
        "invalid",
    ] {
        let root = tempfile::tempdir()?;
        let (connection, _client) = Connection::memory();
        let (mut server, _jobs) = server(&connection);
        server.config.root = root.path().to_owned();
        server.config.client_root = root.path().to_owned();
        server.config.host_write_root = Some("cache".into());
        server.active = Some(Active {
            generation: 0,
            kind: match case {
                "command" => Kind::Command(Some(RequestId::from(1))),
                "cancelled" => Kind::Command(None),
                _ => Kind::Lsp,
            },
        });
        if case == "stale" {
            server.generation = 1;
        }
        if case == "shutdown" {
            server.shutdown = true;
        }
        let mut output = write_output();
        if case == "invalid" {
            output.output["lsp.hover"] = json!(false);
        }
        server.completed(if case == "failure" {
            Err(failure(ErrorCode::RequestFailed, "failed"))
        } else {
            Ok(output)
        })?;
        assert_eq!(
            root.path().join("cache/titles.toml").exists(),
            case == "current",
            "{case}"
        );
    }
    Ok(())
}

#[test]
fn snapshot_restoration_never_executes_writes() -> Result<()> {
    let root = tempfile::tempdir()?;
    let (connection, _client) = Connection::memory();
    let (mut server, _jobs) = server(&connection);
    server.config.root = root.path().to_owned();
    server.config.host_write_root = Some("cache".into());
    server.active = Some(Active {
        generation: 0,
        kind: Kind::Lsp,
    });
    server.worker_event(Event::Restored(crate::snapshot::Payload {
        output: write_output().output,
        dependencies: Dependencies::default(),
        warnings: vec![],
    }))?;
    assert!(!root.path().join("cache").exists());
    Ok(())
}

#[test]
fn initialization_separates_host_authorization_from_eval_params() -> Result<()> {
    let root = tempfile::tempdir()?;
    let params: InitializeParams = serde_json::from_value(json!({
        "capabilities": {},
        "initializationOptions": {"entry": "lsp.typ", "hostWriteRoot": "cache/generated"}
    }))?;
    let config = Config::from_initialize(params, Some(root.path().to_owned()))?;
    assert_eq!(
        config.host_write_root,
        Some(PathBuf::from("cache/generated"))
    );
    assert_eq!(config.evaluation.entry, PathBuf::from("lsp.typ"));
    Ok(())
}
