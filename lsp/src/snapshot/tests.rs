use super::*;
#[cfg(unix)]
use typst::foundations::Dict;

#[cfg(unix)]
fn fixture() -> Result<(tempfile::TempDir, Runtime, Store, EvalParams, Payload)> {
    let dir = tempfile::tempdir()?;
    let root = dir.path().join("project");
    fs::create_dir(&root)?;
    let root = root.canonicalize()?;
    fs::write(
        root.join("main.typ"),
        "#metadata((tag: label(\"lsp.hover\"), value: (:)))<eval.announcement>",
    )?;
    let mut runtime = Runtime::new_with_options(
        &root,
        WorldOptions {
            ignore_system_fonts: true,
            ..Default::default()
        },
    )?;
    let evaluation = runtime.evaluate("main.typ", Dict::new())?;
    let directory = dir.path().join("snapshots");
    private_directory(&directory)?;
    let store = Store {
        root,
        directory,
        identity: serde_json::json!({"binary": "test-build"}),
    };
    let params = EvalParams {
        entry: "main.typ".into(),
        inputs: BTreeMap::new(),
        ..Default::default()
    };
    let payload = Payload {
        dependencies: evaluation.dependencies.clone(),
        output: serde_json::json!({"lsp.hover": []}),
        warnings: vec![],
    };
    Ok((dir, runtime, store, params, payload))
}

#[test]
#[cfg(unix)]
fn roundtrip_is_private_and_source_change_or_inputs_miss() -> Result<()> {
    let (_dir, runtime, store, params, payload) = fixture()?;
    store.save(&params, payload, &BTreeMap::new())?;
    let loaded = store.load(&runtime, &params, &BTreeMap::new())?;
    assert_eq!(loaded.output, serde_json::json!({"lsp.hover": []}));
    let changed = EvalParams {
        inputs: BTreeMap::from([("mode".into(), "changed".into())]),
        ..params.clone()
    };
    assert!(store.load(&runtime, &changed, &BTreeMap::new()).is_err());
    let mut changed_store = Store {
        identity: serde_json::json!({"binary": "another-build"}),
        ..Store {
            root: store.root.clone(),
            directory: store.directory.clone(),
            identity: Value::Null,
        }
    };
    assert!(
        changed_store
            .load(&runtime, &params, &BTreeMap::new())
            .is_err()
    );
    changed_store.identity = serde_json::json!({"root": "moved"});
    assert!(
        changed_store
            .load(&runtime, &params, &BTreeMap::new())
            .is_err()
    );
    fs::write(store.root.join("main.typ"), "changed")?;
    assert!(store.load(&runtime, &params, &BTreeMap::new()).is_err());
    Ok(())
}

#[test]
#[cfg(unix)]
fn corrupt_checksum_and_unsupported_version_are_misses() -> Result<()> {
    let (_dir, runtime, store, params, payload) = fixture()?;
    store.save(&params, payload, &BTreeMap::new())?;
    let path = store
        .directory
        .join(format!("{}.json", store.key(&params)?));
    let original = fs::read(&path)?;
    let mut envelope: Envelope = serde_json::from_slice(&original)?;
    envelope.payload.output = serde_json::json!({"wrong": "output"});
    fs::write(&path, serde_json::to_vec(&envelope)?)?;
    assert!(store.load(&runtime, &params, &BTreeMap::new()).is_err());
    let mut envelope: Envelope = serde_json::from_slice(&original)?;
    envelope.version += 1;
    fs::write(&path, serde_json::to_vec(&envelope)?)?;
    assert!(store.load(&runtime, &params, &BTreeMap::new()).is_err());
    fs::write(path, b"{truncated")?;
    assert!(store.load(&runtime, &params, &BTreeMap::new()).is_err());
    Ok(())
}

#[test]
#[cfg(unix)]
fn unsaved_and_unsupported_snapshots_are_not_written() -> Result<()> {
    let (_dir, _runtime, store, params, mut payload) = fixture()?;
    let different = BTreeMap::from([("main.typ".into(), "unsaved".into())]);
    assert!(
        store
            .save(
                &params,
                Payload {
                    dependencies: payload.dependencies.clone(),
                    output: payload.output.clone(),
                    warnings: vec![]
                },
                &different
            )
            .is_err()
    );
    payload.dependencies.unsupported = Some("clock".into());
    assert!(store.save(&params, payload, &BTreeMap::new()).is_err());
    assert_eq!(fs::read_dir(store.directory)?.count(), 0);
    Ok(())
}

#[test]
#[cfg(unix)]
fn public_or_symlinked_files_are_rejected() -> Result<()> {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let (_dir, runtime, store, params, payload) = fixture()?;
    store.save(&params, payload, &BTreeMap::new())?;
    let path = store
        .directory
        .join(format!("{}.json", store.key(&params)?));
    assert_eq!(fs::metadata(&path)?.permissions().mode() & 0o777, 0o600);
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644))?;
    assert!(store.load(&runtime, &params, &BTreeMap::new()).is_err());
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
    let target = path.with_extension("target");
    fs::rename(&path, &target)?;
    symlink(target, &path)?;
    assert!(store.load(&runtime, &params, &BTreeMap::new()).is_err());
    Ok(())
}

#[test]
#[cfg(unix)]
fn oversized_snapshots_are_rejected_before_reading() -> Result<()> {
    let (_dir, runtime, store, params, payload) = fixture()?;
    store.save(&params, payload, &BTreeMap::new())?;
    let path = store
        .directory
        .join(format!("{}.json", store.key(&params)?));
    fs::OpenOptions::new()
        .write(true)
        .open(path)?
        .set_len(MAX_BYTES + 1)?;
    assert!(store.load(&runtime, &params, &BTreeMap::new()).is_err());
    Ok(())
}

#[test]
#[cfg(not(unix))]
fn private_storage_is_unsupported_without_creating_files() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let directory = dir.path().join("snapshots");
    let path = directory.join("snapshot.json");
    for result in [private_directory(&directory), private_file(&path)] {
        assert_eq!(
            result.unwrap_err().to_string(),
            "private snapshot storage unsupported on this platform"
        );
    }
    assert!(!directory.exists());
    assert_eq!(fs::read_dir(dir.path())?.count(), 0);
    assert!(Store::new(&dir.path().canonicalize()?, &WorldOptions::default()).is_err());
    Ok(())
}
