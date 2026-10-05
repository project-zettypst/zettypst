//! POC protocol: JSON-RPC requests over a local Unix socket, one JSON per line.
//! Only eval and shutdown are implemented; no batch requests.

use std::collections::BTreeMap;
use std::fs;
use std::io::{self, BufRead, BufReader, BufWriter, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use anyhow::{Context, Result};
use serde::Deserialize;
use serde_json::{Value, json};
use typst::foundations::{Dict, Value as TypstValue};
use zettyp_eval::{Runtime, WorldOptions};

pub fn serve(root: &Path, socket: &Path, options: WorldOptions) -> Result<()> {
    let runtime = Arc::new(Mutex::new(Runtime::new_with_options(root, options)?));
    // An existing path may belong to another server; never remove it on startup.
    let listener = UnixListener::bind(socket)
        .with_context(|| format!("failed to bind socket {}", socket.display()))?;
    fs::set_permissions(socket, fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    let stopping = Arc::new(AtomicBool::new(false));
    let mut clients = Vec::<thread::JoinHandle<()>>::new();
    eprintln!("zettyp-eval listening on {}", socket.display());

    let result = (|| -> io::Result<()> {
        while !stopping.load(Ordering::Acquire) {
            clients.retain(|client| !client.is_finished());
            match listener.accept() {
                Ok((stream, _)) => {
                    let runtime = runtime.clone();
                    let stopping = stopping.clone();
                    clients.push(thread::spawn(move || {
                        if let Err(error) = handle_client(stream, &runtime, &stopping) {
                            eprintln!("zettyp-eval client: {error:#}");
                        }
                    }));
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(20));
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(error) => return Err(error),
            }
        }
        Ok(())
    })();
    stopping.store(true, Ordering::Release);
    drop(listener);
    for client in clients {
        let _ = client.join();
    }
    fs::remove_file(socket)?;
    result.context("socket listener failed")
}

fn handle_client(
    stream: UnixStream,
    runtime: &Mutex<Runtime>,
    stopping: &AtomicBool,
) -> Result<()> {
    // macOS inherits O_NONBLOCK from the listener. Client IO uses blocking
    // writes so responses larger than the socket buffer are not truncated.
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(Duration::from_millis(100)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut writer = BufWriter::new(stream);
    let mut message = Vec::new();
    while !stopping.load(Ordering::Acquire) {
        match reader.read_until(b'\n', &mut message) {
            Ok(0) => break,
            Ok(_) => {}
            // Preserve partial messages across timeouts, and let idle clients
            // notice shutdown without holding the evaluator lock.
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock
                        | io::ErrorKind::TimedOut
                        | io::ErrorKind::Interrupted
                ) =>
            {
                continue;
            }
            Err(error) => return Err(error.into()),
        }
        let response = match serde_json::from_slice::<Value>(&message) {
            Ok(request) => dispatch(request, runtime, stopping),
            Err(_) => Some(error(Value::Null, -32700, "Parse error", Value::Null)),
        };
        message.clear();
        if let Some(response) = response {
            serde_json::to_writer(&mut writer, &response)?;
            writer.write_all(b"\n")?;
            writer.flush()?;
        }
    }
    Ok(())
}

fn dispatch(request: Value, runtime: &Mutex<Runtime>, stopping: &AtomicBool) -> Option<Value> {
    let id = request.get("id");
    if request.get("jsonrpc") != Some(&json!("2.0"))
        || !request.get("method").is_some_and(Value::is_string)
        || id.is_some_and(|id| !matches!(id, Value::Null | Value::String(_) | Value::Number(_)))
    {
        return Some(error(Value::Null, -32600, "Invalid Request", Value::Null));
    }
    let response_id = id.cloned().unwrap_or(Value::Null);
    let params = request.get("params").cloned().unwrap_or_else(|| json!({}));
    let response = match request["method"].as_str().unwrap() {
        "eval" => evaluate(response_id, params, runtime),
        "shutdown" if params == json!({}) => {
            stopping.store(true, Ordering::Release);
            json!({"jsonrpc": "2.0", "id": response_id, "result": null})
        }
        "shutdown" => error(
            response_id,
            -32602,
            "shutdown takes no parameters",
            Value::Null,
        ),
        _ => error(response_id, -32601, "Method not found", Value::Null),
    };
    // Notifications execute without sending a response.
    id.map(|_| response)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct EvalParams {
    entry: PathBuf,
    #[serde(default)]
    inputs: BTreeMap<String, String>,
    /// Complete in-memory source set; all other files are read from disk.
    #[serde(default)]
    sources: BTreeMap<PathBuf, Option<String>>,
}

fn evaluate(id: Value, params: Value, runtime: &Mutex<Runtime>) -> Value {
    if !params.is_object() {
        return error(id, -32602, "eval expects named parameters", Value::Null);
    }
    let params: EvalParams = match serde_json::from_value(params) {
        Ok(params) => params,
        Err(reason) => return error(id, -32602, &reason.to_string(), Value::Null),
    };
    let inputs = params
        .inputs
        .into_iter()
        .map(|(key, value)| (key.into(), TypstValue::Str(value.into())))
        .collect::<Dict>();
    // Only evaluation holds the lock, not waiting for requests or writing output.
    let evaluation = match runtime.lock() {
        Ok(mut runtime) => {
            match runtime.evaluate_with_sources(params.entry, inputs, params.sources) {
                Ok(evaluation) => evaluation,
                Err(reason) => return error(id, -32602, &reason.to_string(), Value::Null),
            }
        }
        Err(_) => return error(id, -32603, "Evaluator is unavailable", Value::Null),
    };
    let warnings: Vec<_> = evaluation
        .result
        .warnings
        .iter()
        .map(|warning| warning.message.as_str())
        .collect();
    match &evaluation.result.output {
        Ok(output) => match serde_json::to_value(output) {
            Ok(output) => json!({
                "jsonrpc": "2.0", "id": id,
                "result": {"revision": evaluation.revision, "output": output, "warnings": warnings, "reads": evaluation.reads},
            }),
            Err(reason) => error(id, -32603, &reason.to_string(), Value::Null),
        },
        Err(reason) => error(
            id,
            -32001,
            &reason.to_string(),
            json!({
                "revision": evaluation.revision, "warnings": warnings, "reads": evaluation.reads,
            }),
        ),
    }
}

fn error(id: Value, code: i64, message: &str, data: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message, "data": data}})
}
