//! A single, serial evaluator. Scheduling and source versions belong to the LSP.
use std::collections::BTreeMap;
use std::path::{Component, PathBuf};
use std::thread;

use anyhow::{Result, bail};
use crossbeam_channel::{Receiver, Sender, unbounded};
use lsp_server::{ErrorCode, ResponseError};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use typst::foundations::{Dict, Value as TypstValue};
use zettyp_eval::{Dependencies, Runtime, WorldOptions};

use crate::snapshot::{Payload, Store};
use crate::values::{Announcements, View};

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EvalParams {
    pub entry: PathBuf,
    #[serde(default)]
    pub inputs: BTreeMap<String, String>,
}

impl EvalParams {
    pub fn validate(&self) -> Result<()> {
        if self.entry.is_absolute()
            || self
                .entry
                .components()
                .any(|part| matches!(part, Component::ParentDir))
            || !self
                .entry
                .components()
                .any(|part| matches!(part, Component::Normal(_)))
        {
            bail!("entry must be a non-empty project-relative path without '..'");
        }
        Ok(())
    }
}

pub struct Job {
    pub params: EvalParams,
    pub sources: BTreeMap<PathBuf, String>,
    pub index: bool,
}

#[derive(Serialize)]
pub struct Output {
    pub revision: u64,
    pub output: Value,
    pub warnings: Vec<String>,
    #[serde(skip)]
    pub dependencies: Dependencies,
}

pub enum Event {
    Status(&'static str),
    Restored(Payload),
}

pub struct Worker {
    pub jobs: Sender<Job>,
    pub results: Receiver<Result<Output, ResponseError>>,
    pub events: Receiver<Event>,
}

impl Worker {
    pub fn start(root: PathBuf, options: WorldOptions) -> Result<Self> {
        let (jobs, requests) = unbounded::<Job>();
        let (completed, results) = unbounded();
        let (updates, events) = unbounded();
        thread::Builder::new()
            .name("zettyp-eval".into())
            .spawn(move || {
                // Runtime/font discovery no longer blocks the LSP handshake.
                let store = Store::new(&root, &options);
                let mut runtime = Runtime::new_with_options(&root, options);
                let mut attempted_restore = false;
                for job in requests {
                    let result = match &mut runtime {
                        Ok(runtime) => {
                            if job.index && !attempted_restore {
                                attempted_restore = true;
                                let _ = updates.send(Event::Status("Validating saved index"));
                                match store.as_ref().ok().and_then(|store| {
                                    store.load(runtime, &job.params, &job.sources).ok()
                                }) {
                                    Some(payload) => {
                                        let _ = updates.send(Event::Restored(payload));
                                    }
                                    None => {
                                        let _ = updates.send(Event::Status(
                                            "No valid snapshot; evaluating project sources",
                                        ));
                                    }
                                }
                            }
                            evaluate(runtime, &job)
                        }
                        Err(error) => Err(failure(
                            ErrorCode::RequestFailed,
                            format!("evaluator initialization failed: {error:#}"),
                        )),
                    };
                    let snapshot = if job.index && store.is_ok() {
                        result.as_ref().ok().and_then(|output| {
                            if output.dependencies.unsupported.is_some() {
                                return None;
                            }
                            // Avoid cloning/serializing large announcements for ordinary unsaved edits.
                            if !output.dependencies.matches(&root, &job.sources) {
                                return None;
                            }
                            let view = View {
                                root: root.clone(),
                                client_root: root.clone(),
                                aliases: BTreeMap::new(),
                                versions: BTreeMap::new(),
                                code_actions: false,
                                disabled_actions: false,
                            };
                            let values: Announcements =
                                serde_json::from_value(output.output.clone()).ok()?;
                            values.publications(&view).ok()?;
                            Some(Payload {
                                output: output.output.clone(),
                                dependencies: output.dependencies.clone(),
                                warnings: output.warnings.clone(),
                            })
                        })
                    } else {
                        None
                    };
                    if completed.send(result).is_err() {
                        break;
                    }
                    // Persistence is off the foreground result path. Revalidate again before writing.
                    if let (Ok(store), Some(payload)) = (&store, snapshot)
                        && let Err(error) = store.save(&job.params, payload, &job.sources)
                    {
                        eprintln!("zettyp-lsp: snapshot not saved: {error}");
                    }
                }
            })?;
        Ok(Self {
            jobs,
            results,
            events,
        })
    }
}

fn evaluate(runtime: &mut Runtime, job: &Job) -> Result<Output, ResponseError> {
    let inputs = job
        .params
        .inputs
        .clone()
        .into_iter()
        .map(|(key, value)| (key.into(), TypstValue::Str(value.into())))
        .collect::<Dict>();
    let evaluation = runtime
        .evaluate_with_sources(
            &job.params.entry,
            inputs,
            job.sources
                .iter()
                .map(|(path, text)| (path.clone(), Some(text.clone())))
                .collect(),
        )
        .map_err(|error| failure(ErrorCode::InvalidParams, error.to_string()))?;
    let warnings: Vec<_> = evaluation
        .result
        .warnings
        .iter()
        .map(|warning| warning.message.to_string())
        .collect();
    let value = evaluation
        .result
        .output
        .as_ref()
        .map_err(|error| ResponseError {
            code: ErrorCode::RequestFailed as i32,
            message: format!("{error:#}"),
            data: Some(json!({"revision": evaluation.revision, "warnings": warnings})),
        })?;
    let output = serde_json::to_value(value)
        .map_err(|error| failure(ErrorCode::RequestFailed, error.to_string()))?;
    Ok(Output {
        revision: evaluation.revision,
        output,
        warnings,
        dependencies: evaluation.dependencies.clone(),
    })
}

pub fn failure(code: ErrorCode, message: impl Into<String>) -> ResponseError {
    ResponseError {
        code: code as i32,
        message: message.into(),
        data: None,
    }
}
