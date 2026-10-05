use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use typst::foundations::Dict;
use typst::syntax::{FileId, VirtualPath};
use zettyp_eval::Runtime;

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        // Keep socket paths short on macOS.
        let base = if cfg!(unix) {
            PathBuf::from("/tmp")
        } else {
            std::env::temp_dir()
        };
        static NEXT_ID: AtomicU64 = AtomicU64::new(0);
        let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        let root = base.join(format!("zettyp-eval-{}-{nonce}-{id}", std::process::id()));
        fs::create_dir(&root).unwrap();
        fs::write(root.join("main.typ"), "#import \"dep.typ\": value\n#metadata((tag: label(\"demo\"), value: value))<eval.announcement>").unwrap();
        fs::write(root.join("dep.typ"), "#let value = 1").unwrap();
        Self(root)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn disk_updates_reuse_sources_and_recover_from_errors() {
    let fixture = Fixture::new();
    let mut runtime = Runtime::new(&fixture.0).unwrap();
    let old = runtime.evaluate("main.typ", Dict::new()).unwrap();
    let unchanged = runtime.evaluate("main.typ", Dict::new()).unwrap();
    let id = FileId::new(None, VirtualPath::new("dep.typ"));
    let source = old.sources.source(id).unwrap();
    assert_eq!(
        source.text().as_ptr(),
        unchanged.sources.source(id).unwrap().text().as_ptr()
    );

    fs::write(fixture.0.join("dep.typ"), "#let value = (").unwrap();
    let failed = runtime.evaluate("main.typ", Dict::new()).unwrap();
    assert!(failed.result.output.is_err());
    assert!(runtime.latest().unwrap().result.output.is_err());

    fs::write(fixture.0.join("dep.typ"), "#let value = 2").unwrap();
    let updated = runtime.evaluate("main.typ", Dict::new()).unwrap();
    assert_eq!(updated.revision, 4);
    assert_eq!(
        serde_json::to_value(updated.result.output.as_ref().unwrap()).unwrap(),
        json!({"demo": [2]})
    );
    assert_eq!(source.text(), "#let value = 1");
}

#[cfg(unix)]
#[test]
fn rpc_evaluates_then_shuts_down() {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixStream;
    use std::process::{Child, Command, Stdio};
    use std::time::{Duration, Instant};

    struct Process(Child);
    impl Drop for Process {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    let fixture = Fixture::new();
    let socket = fixture.0.join("rpc.sock");
    let mut process = Process(
        Command::new(env!("CARGO_BIN_EXE_zettyp-eval"))
            .args(["serve", "--ignore-system-fonts", "--root"])
            .arg(&fixture.0)
            .arg("--socket")
            .arg(&socket)
            .stdout(Stdio::null())
            .spawn()
            .unwrap(),
    );
    // Allow cold font initialization on slower or contended CI runners.
    let timeout = Duration::from_secs(30);
    let deadline = Instant::now() + timeout;
    let mut stream = loop {
        let error = match UnixStream::connect(&socket) {
            Ok(stream) => break stream,
            Err(error) => error,
        };
        if let Some(status) = process.0.try_wait().unwrap() {
            panic!(
                "server exited before accepting connections: {status}; last connection error: {error}"
            );
        }
        assert!(
            Instant::now() < deadline,
            "server did not start; last connection error: {error}",
        );
        std::thread::sleep(Duration::from_millis(10));
    };
    stream.set_read_timeout(Some(timeout)).unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut call = |id, method, params| -> Value {
        serde_json::to_writer(
            &mut stream,
            &json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}),
        )
        .unwrap();
        stream.write_all(b"\n").unwrap();
        let mut response = String::new();
        reader.read_line(&mut response).unwrap();
        serde_json::from_str(&response).unwrap()
    };
    let first = call(1, "eval", json!({"entry": "main.typ"}));
    assert_eq!(first["result"]["output"], json!({"demo": [1]}));
    assert_eq!(first["result"]["revision"], 1);
    assert_eq!(first["result"]["warnings"], json!([]));
    assert_eq!(first["result"]["reads"].as_object().unwrap().len(), 2);
    fs::write(fixture.0.join("dep.typ"), "#let value = 2").unwrap();
    let second = call(2, "eval", json!({"entry": "main.typ"}));
    assert_eq!(second["result"]["output"], json!({"demo": [2]}));
    assert_eq!(second["result"]["revision"], 2);
    let overlay = call(
        3,
        "eval",
        json!({"entry": "main.typ", "sources": {"dep.typ": "#let value = 3"}}),
    );
    assert_eq!(overlay["result"]["output"], json!({"demo": [3]}));
    assert!(overlay["result"]["reads"].get("dep.typ").is_none());
    let deleted = call(
        4,
        "eval",
        json!({"entry": "main.typ", "sources": {"dep.typ": null}}),
    );
    assert_eq!(deleted["error"]["code"], -32001);
    assert!(deleted["error"]["data"]["reads"].get("dep.typ").is_none());
    assert_eq!(
        call(5, "shutdown", json!({})),
        json!({"jsonrpc": "2.0", "id": 5, "result": null})
    );
    assert!(process.0.wait().unwrap().success());
    assert!(!socket.exists());
}
