//! LSP lifecycle, source overlays and scheduling. No Typst-domain policy lives here.
use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, ensure};
use crossbeam_channel::select_biased;
use lsp_server::{
    Connection, ErrorCode, Message, Notification, Request, RequestId, Response, ResponseError,
};
use lsp_types::*;
use serde_json::{Value, json};
use zettyp_eval::{Dependencies, WorldOptions};

use crate::progress::Progress;
use crate::values::{Announcements, Query, View};
use crate::worker::{EvalParams, Event, Job, Output, Worker, failure};

#[cfg(test)]
mod tests;

const DEBOUNCE: Duration = Duration::from_millis(120);
const WATCH_ID: &str = "zettyp/watch";

struct Config {
    root: PathBuf,
    client_root: PathBuf,
    evaluation: EvalParams,
    code_actions: bool,
    disabled_actions: bool,
    diagnostic_versions: bool,
    watch_registration: bool,
    relative_patterns: bool,
    work_done_progress: bool,
    host_write_root: Option<PathBuf>,
}

impl Config {
    #[allow(deprecated)]
    fn from_initialize(params: InitializeParams, root: Option<PathBuf>) -> Result<Self> {
        let host_write_root = params
            .initialization_options
            .as_ref()
            .and_then(|options| options.get("hostWriteRoot"))
            .map(|value| {
                crate::host::relative(value.as_str().context("hostWriteRoot must be a string")?)
            })
            .transpose()?;
        let mut options = params
            .initialization_options
            .context("initializationOptions must contain entry and optional inputs")?;
        if let Some(options) = options.as_object_mut() {
            options.remove("hostWriteRoot");
        }
        let evaluation: EvalParams = serde_json::from_value(options)?;
        evaluation.validate()?;
        if let Some(folders) = &params.workspace_folders {
            ensure!(
                folders.len() <= 1,
                "use one zettyp-lsp instance per project root"
            );
        }
        let uri = params
            .workspace_folders
            .as_ref()
            .and_then(|folders| folders.first())
            .map(|folder| folder.uri.clone())
            .or(params.root_uri);
        let client_root = match root {
            Some(path) => std::path::absolute(path)?,
            None => match uri {
                Some(uri) => uri
                    .to_file_path()
                    .map_err(|_| anyhow::anyhow!("project root must be a file URI"))?,
                None => params
                    .root_path
                    .map(PathBuf::from)
                    .context("a project root is required")?,
            },
        };
        let root = client_root
            .canonicalize()
            .context("cannot resolve project root")?;
        ensure!(root.is_dir(), "project root must be a directory");
        let caps = serde_json::to_value(params.capabilities)?;
        let enabled = |pointer| {
            caps.pointer(pointer)
                .and_then(Value::as_bool)
                .unwrap_or(false)
        };
        Ok(Self {
            root,
            client_root,
            evaluation,
            code_actions: enabled("/workspace/workspaceEdit/documentChanges")
                && caps
                    .pointer("/textDocument/codeAction/codeActionLiteralSupport")
                    .is_some_and(Value::is_object),
            disabled_actions: enabled("/textDocument/codeAction/disabledSupport"),
            diagnostic_versions: enabled("/textDocument/publishDiagnostics/versionSupport"),
            watch_registration: enabled("/workspace/didChangeWatchedFiles/dynamicRegistration"),
            relative_patterns: enabled("/workspace/didChangeWatchedFiles/relativePatternSupport"),
            work_done_progress: enabled("/window/workDoneProgress"),
            host_write_root,
        })
    }

    fn relative(&self, uri: &Url) -> Result<PathBuf> {
        let path = uri
            .to_file_path()
            .map_err(|_| anyhow::anyhow!("document must be a file URI"))?;
        for root in [&self.client_root, &self.root] {
            if let Ok(relative) = path.strip_prefix(root) {
                return Ok(relative.to_owned());
            }
        }
        let real = path
            .canonicalize()
            .context("document is outside the project root")?;
        Ok(real
            .strip_prefix(&self.root)
            .context("document is outside the project root")?
            .to_owned())
    }
}

struct Document {
    uri: Url,
    version: i32,
    text: String,
}

enum Kind {
    Lsp,
    // None means cancellation or invalidation already completed this request.
    Command(Option<RequestId>),
    Detached(Option<RequestId>),
}

struct Active {
    generation: u64,
    kind: Kind,
}

struct Server<'a> {
    connection: &'a Connection,
    config: Config,
    worker: Worker,
    progress: Progress,
    index_ready: bool,
    restored_dependencies: Option<Dependencies>,
    documents: BTreeMap<PathBuf, Document>,
    generation: u64,
    active: Option<Active>,
    cache: Option<Result<Announcements, ResponseError>>,
    waiting: HashMap<RequestId, Query>,
    commands: VecDeque<(RequestId, EvalParams)>,
    published: BTreeSet<Url>,
    due: Option<Instant>,
    watching: bool,
    shutdown: bool,
}

pub fn run(connection: &Connection, root: Option<PathBuf>, options: WorldOptions) -> Result<()> {
    let (id, params) = connection.initialize_start()?;
    let setup = (|| {
        let config = Config::from_initialize(serde_json::from_value(params)?, root)?;
        let worker = Worker::start(config.root.clone(), options.clone())?;
        Ok::<_, anyhow::Error>((config, worker))
    })();
    let (config, worker) = match setup {
        Ok(setup) => setup,
        Err(error) => {
            connection.sender.send(
                Response::new_err(id, ErrorCode::InvalidParams as i32, error.to_string()).into(),
            )?;
            return Err(error);
        }
    };
    connection.initialize_finish(id, json!({
        "capabilities": {
            "positionEncoding": "utf-16",
            "textDocumentSync": {"openClose": true, "change": 1, "save": {"includeText": false}},
            "hoverProvider": true,
            "definitionProvider": true,
            "referencesProvider": true,
            "codeActionProvider": config.code_actions,
            "executeCommandProvider": {"commands": ["zettyp.eval", "zettyp.evalDetached"]}
        },
        "serverInfo": {"name": "zettyp-lsp", "version": env!("CARGO_PKG_VERSION")}
    }))?;
    let mut server = Server {
        connection,
        progress: Progress::new(config.work_done_progress),
        index_ready: false,
        restored_dependencies: None,
        config,
        worker,
        documents: BTreeMap::new(),
        generation: 0,
        active: None,
        cache: None,
        waiting: HashMap::new(),
        commands: VecDeque::new(),
        published: BTreeSet::new(),
        due: Some(Instant::now() + DEBOUNCE),
        watching: false,
        shutdown: false,
    };
    server.register_watching(options.package_path.as_deref())?;
    server.run()
}

impl Server<'_> {
    fn run(&mut self) -> Result<()> {
        loop {
            self.schedule()?;
            self.progress.tick(self.connection, Instant::now())?;
            let delay = if self.active.is_none() && !self.shutdown {
                self.due
                    .map(|due| due.saturating_duration_since(Instant::now()))
                    .unwrap_or(Duration::from_secs(86400))
            } else {
                Duration::from_secs(86400)
            };
            let delay = self.progress.deadline().map_or(delay, |due| {
                delay.min(due.saturating_duration_since(Instant::now()))
            });
            // Process already-received source changes before publishing a completion.
            select_biased! {
                recv(self.connection.receiver) -> message => {
                    let message = message.context("LSP client disconnected without exit")?;
                    match message {
                        Message::Notification(n) if n.method == "exit" => {
                            ensure!(self.shutdown, "exit received without shutdown");
                            return Ok(());
                        }
                        Message::Request(request) => self.request(request)?,
                        Message::Notification(notification) if !self.shutdown => {
                            if let Err(error) = self.notification(notification) {
                                self.log(MessageType::ERROR, format!("Invalid notification: {error:#}"))?;
                            }
                        }
                        Message::Response(response) if !self.shutdown => self.client_response(response)?,
                        _ => {}
                    }
                }
                recv(self.worker.events) -> event => {
                    self.worker_event(event.context("evaluation worker stopped unexpectedly")?)?;
                }
                recv(self.worker.results) -> result => {
                    let result = result.context("evaluation worker stopped unexpectedly")?;
                    self.completed(result)?;
                }
                default(delay) => {}
            }
        }
    }

    fn view(&self) -> View {
        View {
            root: self.config.root.clone(),
            client_root: self.config.client_root.clone(),
            aliases: self
                .documents
                .iter()
                .map(|(path, doc)| (self.config.root.join(path), doc.uri.clone()))
                .collect(),
            versions: self
                .documents
                .values()
                .map(|doc| (doc.uri.clone(), doc.version))
                .collect(),
            code_actions: self.config.code_actions,
            disabled_actions: self.config.disabled_actions,
        }
    }

    fn send(&self, id: RequestId, result: Result<Value, ResponseError>) -> Result<()> {
        let response = match result {
            Ok(value) => Response::new_ok(id, value),
            Err(error) => Response {
                id,
                result: None,
                error: Some(error),
            },
        };
        self.connection.sender.send(response.into())?;
        Ok(())
    }

    fn log(&self, kind: MessageType, message: String) -> Result<()> {
        self.connection.sender.send(
            Notification::new(
                "window/logMessage".into(),
                LogMessageParams { typ: kind, message },
            )
            .into(),
        )?;
        Ok(())
    }

    fn request(&mut self, request: Request) -> Result<()> {
        let Request { id, method, params } = request;
        if self.shutdown {
            return self.send(
                id,
                Err(failure(
                    ErrorCode::InvalidRequest,
                    "server is shutting down",
                )),
            );
        }
        match method.as_str() {
            "shutdown" => {
                self.shutdown = true;
                self.due = None;
                self.progress
                    .finish(self.connection, "Server shutting down")?;
                self.reject_pending(failure(
                    ErrorCode::RequestCanceled,
                    "server is shutting down",
                ))?;
                self.publish(BTreeMap::new())?;
                self.send(id, Ok(Value::Null))
            }
            "workspace/executeCommand" => {
                let parsed = (|| -> Result<EvalParams> {
                    let params: ExecuteCommandParams = serde_json::from_value(params)?;
                    ensure!(
                        matches!(
                            params.command.as_str(),
                            "zettyp.eval" | "zettyp.evalDetached"
                        ),
                        "unsupported command: {}",
                        params.command
                    );
                    ensure!(
                        params.arguments.len() == 1,
                        "zettyp.eval expects one object with entry and optional inputs"
                    );
                    let mut evaluation: EvalParams =
                        serde_json::from_value(params.arguments.into_iter().next().unwrap())?;
                    evaluation.detached = params.command == "zettyp.evalDetached";
                    ensure!(
                        evaluation.detached || evaluation.sources.is_empty(),
                        "sources require zettyp.evalDetached"
                    );
                    evaluation.validate()?;
                    Ok(evaluation)
                })();
                match parsed {
                    Ok(params) => {
                        self.commands.push_back((id, params));
                        Ok(())
                    }
                    Err(error) => self.send(
                        id,
                        Err(failure(ErrorCode::InvalidParams, error.to_string())),
                    ),
                }
            }
            "textDocument/hover"
            | "textDocument/definition"
            | "textDocument/references"
            | "textDocument/codeAction" => {
                let query = Query::parse(&method, params).and_then(|query| {
                    self.config.relative(query.uri())?;
                    Ok(query)
                });
                match query {
                    Ok(query) => {
                        // Without watched-file support, do not reuse results across
                        // requests that might have unobserved disk changes.
                        if let Some(dependencies) = &self.restored_dependencies {
                            if !dependencies.matches(&self.config.root, &self.sources()) {
                                self.changed()?;
                            }
                        } else if !self.watching {
                            self.cache = None;
                        }
                        if let Some(cache) = &self.cache {
                            let result = cache.as_ref().map_err(Clone::clone).and_then(|values| {
                                values.respond(&query, &self.view()).map_err(invalid_output)
                            });
                            self.send(id, result)
                        } else {
                            self.waiting.insert(id, query);
                            self.due = Some(Instant::now());
                            Ok(())
                        }
                    }
                    Err(error) => self.send(
                        id,
                        Err(failure(ErrorCode::InvalidParams, error.to_string())),
                    ),
                }
            }
            _ => self.send(
                id,
                Err(failure(
                    ErrorCode::MethodNotFound,
                    format!("unsupported method: {method}"),
                )),
            ),
        }
    }

    fn notification(&mut self, notification: Notification) -> Result<()> {
        match notification.method.as_str() {
            "$/cancelRequest" => {
                let params: CancelParams = serde_json::from_value(notification.params)?;
                let id = match params.id {
                    NumberOrString::Number(id) => RequestId::from(id),
                    NumberOrString::String(id) => RequestId::from(id),
                };
                let mut found = self.waiting.remove(&id).is_some();
                if let Some(index) = self.commands.iter().position(|(pending, _)| pending == &id) {
                    self.commands.remove(index);
                    found = true;
                }
                if let Some(Active {
                    kind: Kind::Command(pending) | Kind::Detached(pending),
                    ..
                }) = &mut self.active
                    && pending.as_ref() == Some(&id)
                {
                    *pending = None;
                    found = true;
                }
                if found {
                    self.send(
                        id,
                        Err(failure(ErrorCode::RequestCanceled, "request cancelled")),
                    )?;
                }
            }
            "textDocument/didOpen" => {
                let params: DidOpenTextDocumentParams =
                    serde_json::from_value(notification.params)?;
                let doc = params.text_document;
                if let Ok(path) = self.config.relative(&doc.uri) {
                    let identical = self.restored_dependencies.as_ref().is_some_and(|deps| {
                        deps.contains_text(&self.config.root.join(&path), &doc.text)
                    });
                    self.documents.insert(
                        path,
                        Document {
                            uri: doc.uri,
                            version: doc.version,
                            text: doc.text,
                        },
                    );
                    if !identical {
                        self.changed()?;
                    }
                }
            }
            "textDocument/didChange" => {
                let params: DidChangeTextDocumentParams =
                    serde_json::from_value(notification.params)?;
                if let Ok(path) = self.config.relative(&params.text_document.uri) {
                    ensure!(
                        !params.content_changes.is_empty()
                            && params
                                .content_changes
                                .iter()
                                .all(|change| change.range.is_none()),
                        "server requires full text synchronization"
                    );
                    if let Some(doc) = self.documents.get_mut(&path)
                        && params.text_document.version > doc.version
                    {
                        doc.text = params.content_changes.into_iter().last().unwrap().text;
                        doc.version = params.text_document.version;
                        self.changed()?;
                    }
                }
            }
            "textDocument/didClose" => {
                let params: DidCloseTextDocumentParams =
                    serde_json::from_value(notification.params)?;
                if let Ok(path) = self.config.relative(&params.text_document.uri)
                    && self.documents.remove(&path).is_some()
                {
                    self.changed()?;
                }
            }
            "textDocument/didSave" => {
                let params: DidSaveTextDocumentParams =
                    serde_json::from_value(notification.params)?;
                if self.config.relative(&params.text_document.uri).is_ok() {
                    self.changed()?;
                }
            }
            "workspace/didChangeWatchedFiles" => {
                let params: DidChangeWatchedFilesParams =
                    serde_json::from_value(notification.params)?;
                if !params.changes.is_empty() {
                    self.changed()?;
                }
            }
            _ => {}
        }
        Ok(())
    }

    fn changed(&mut self) -> Result<()> {
        self.generation += 1;
        self.cache = None;
        self.restored_dependencies = None;
        self.due = Some(Instant::now() + DEBOUNCE);
        self.reject_pending(failure(
            ErrorCode::ContentModified,
            "source snapshot changed",
        ))?;
        self.publish(BTreeMap::new())
    }

    fn reject_pending(&mut self, error: ResponseError) -> Result<()> {
        for (id, _) in std::mem::take(&mut self.waiting) {
            self.send(id, Err(error.clone()))?;
        }
        for (id, params) in std::mem::take(&mut self.commands) {
            if params.detached && error.code == ErrorCode::ContentModified as i32 {
                self.commands.push_back((id, params));
            } else {
                self.send(id, Err(error.clone()))?;
            }
        }
        let active_id = match &mut self.active {
            Some(Active {
                kind: Kind::Command(id),
                ..
            }) => id.take(),
            Some(Active {
                kind: Kind::Detached(id),
                ..
            }) if error.code != ErrorCode::ContentModified as i32 => id.take(),
            _ => None,
        };
        if let Some(id) = active_id {
            self.send(id, Err(error))?;
        }
        Ok(())
    }

    fn schedule(&mut self) -> Result<()> {
        if self.shutdown || self.active.is_some() {
            return Ok(());
        }
        let (kind, params) = if self.due.is_some_and(|due| due <= Instant::now()) {
            self.due = None;
            (Kind::Lsp, self.config.evaluation.clone())
        } else if let Some((id, params)) = self.commands.pop_front() {
            (
                if params.detached {
                    Kind::Detached(Some(id))
                } else {
                    Kind::Command(Some(id))
                },
                params,
            )
        } else {
            return Ok(());
        };
        let sources = if params.detached {
            BTreeMap::new()
        } else {
            self.sources()
        };
        self.worker.jobs.send(Job {
            params,
            sources,
            index: matches!(kind, Kind::Lsp),
        })?;
        if matches!(kind, Kind::Lsp) {
            self.progress.start(Instant::now());
        }
        self.active = Some(Active {
            generation: self.generation,
            kind,
        });
        Ok(())
    }

    fn sources(&self) -> BTreeMap<PathBuf, String> {
        self.documents
            .iter()
            .map(|(path, doc)| (path.clone(), doc.text.clone()))
            .collect()
    }

    fn worker_event(&mut self, event: Event) -> Result<()> {
        if self.shutdown
            || !self.active.as_ref().is_some_and(|active| {
                active.generation == self.generation && matches!(active.kind, Kind::Lsp)
            })
        {
            return Ok(());
        }
        match event {
            Event::Status(message) => self.progress.report(self.connection, message)?,
            Event::Restored(payload) => {
                // Recheck current overlays/disk on the receiving side before publication.
                if !payload
                    .dependencies
                    .matches(&self.config.root, &self.sources())
                {
                    return Ok(());
                }
                let values = serde_json::from_value::<Announcements>(payload.output)
                    .map_err(|error| invalid_output(error.into()));
                let installed = values.and_then(|values| {
                    let publications = values.publications(&self.view()).map_err(invalid_output)?;
                    Ok((values, publications))
                });
                match installed {
                    Ok((values, publications)) => {
                        self.publish(publications)?;
                        self.cache = Some(Ok(values));
                        self.restored_dependencies = Some(payload.dependencies);
                        self.index_ready = true;
                        self.progress.report(self.connection,
                            "Hover, Definition, References and Diagnostics ready from snapshot; warming evaluator")?;
                        for (id, query) in std::mem::take(&mut self.waiting) {
                            let result = self
                                .cache
                                .as_ref()
                                .unwrap()
                                .as_ref()
                                .map_err(Clone::clone)
                                .and_then(|values| {
                                    values.respond(&query, &self.view()).map_err(invalid_output)
                                });
                            self.send(id, result)?;
                        }
                    }
                    Err(_) => self.progress.report(
                        self.connection,
                        "Invalid snapshot; evaluating project sources",
                    )?,
                }
            }
        }
        Ok(())
    }

    fn completed(&mut self, result: Result<Output, ResponseError>) -> Result<()> {
        let active = self.active.take().context("unexpected evaluator result")?;
        if self.shutdown
            || (active.generation != self.generation && !matches!(active.kind, Kind::Detached(_)))
        {
            // Startup spans superseded attempts; only a current result ends it.
            // Shutdown already closed any visible progress in request().
            return Ok(());
        }
        match active.kind {
            Kind::Command(Some(id)) => {
                // Keep command output entirely separate from the LSP cache.
                // Versions let explicit consumers check their own later actions.
                let result = result.map(|output| {
                    json!({
                        "revision": output.revision,
                        "output": output.output,
                        "warnings": output.warnings,
                        "reads": output.reads,
                        "versions": self.view().versions,
                    })
                });
                self.send(id, result)?;
            }
            Kind::Detached(Some(id)) => self.send(
                id,
                result.map(|output| {
                    json!({
                        "revision": output.revision, "output": output.output,
                        "warnings": output.warnings, "reads": output.reads,
                    })
                }),
            )?,
            Kind::Command(None) | Kind::Detached(None) => {}
            Kind::Lsp => {
                self.restored_dependencies = None;
                if result.is_ok() {
                    self.progress
                        .report(self.connection, "Installing announcements")?;
                }
                let view = self.view();
                let values = result.and_then(|output| {
                    for warning in output.warnings {
                        // Failure to write the log is handled by subsequent protocol IO.
                        let _ = self.log(MessageType::WARNING, warning);
                    }
                    let writes = crate::host::Writes::prepare(
                        &output.output,
                        &self.config.root,
                        self.config.host_write_root.as_deref(),
                        self.documents.keys().cloned(),
                    )
                    .map_err(invalid_output)?;
                    let values: Announcements = serde_json::from_value(output.output)
                        .map_err(|error| invalid_output(error.into()))?;
                    let publications = values.publications(&view).map_err(invalid_output)?;
                    writes.commit(&self.config.root).map_err(invalid_output)?;
                    Ok((values, publications))
                });
                self.cache = Some(match values {
                    Ok((values, publications)) => {
                        self.publish(publications)?;
                        Ok(values)
                    }
                    Err(error) => {
                        self.publish(BTreeMap::new())?;
                        self.log(MessageType::ERROR, error.message.clone())?;
                        Err(error)
                    }
                });
                let ready = self.cache.as_ref().is_some_and(Result::is_ok);
                self.index_ready |= ready;
                self.progress.finish(
                    self.connection,
                    if ready {
                        "Knowledge index ready"
                    } else {
                        "Knowledge index update failed; see server log"
                    },
                )?;
                // A request arriving during evaluation can have set this again.
                self.due = None;
                for (id, query) in std::mem::take(&mut self.waiting) {
                    let result = self
                        .cache
                        .as_ref()
                        .unwrap()
                        .as_ref()
                        .map_err(Clone::clone)
                        .and_then(|values| values.respond(&query, &view).map_err(invalid_output));
                    self.send(id, result)?;
                }
            }
        }
        Ok(())
    }

    fn publish(&mut self, mut publications: BTreeMap<Url, Vec<Diagnostic>>) -> Result<()> {
        for uri in &self.published {
            publications.entry(uri.clone()).or_default();
        }
        let view = self.view();
        self.published.clear();
        for (uri, diagnostics) in publications {
            if !diagnostics.is_empty() {
                self.published.insert(uri.clone());
            }
            let version = if self.config.diagnostic_versions {
                view.versions.get(&uri).copied()
            } else {
                None
            };
            self.connection.sender.send(
                Notification::new(
                    "textDocument/publishDiagnostics".into(),
                    PublishDiagnosticsParams {
                        uri,
                        diagnostics,
                        version,
                    },
                )
                .into(),
            )?;
        }
        Ok(())
    }

    fn register_watching(&self, package_path: Option<&Path>) -> Result<()> {
        if !self.config.watch_registration {
            return self.log(MessageType::WARNING,
                "Client has no dynamic file watching; results refresh on document events and requests.".into());
        }
        let mut roots = vec![self.config.root.clone()];
        if let Some(path) = package_path.and_then(|path| path.canonicalize().ok())
            && !path.starts_with(&self.config.root)
        {
            roots.push(path);
        }
        let watchers = roots
            .iter()
            .map(|root| {
                let pattern = if self.config.relative_patterns {
                    json!({"baseUri": Url::from_directory_path(root).unwrap(), "pattern": "**/*"})
                } else {
                    // Escape glob metacharacters in the literal project path.
                    let path = root.to_string_lossy().replace('\\', "/");
                    let escaped = path
                        .chars()
                        .map(|c| match c {
                            '[' => "[[]".into(),
                            ']' => "[]]".into(),
                            '*' => "[*]".into(),
                            '?' => "[?]".into(),
                            '{' => "[{]".into(),
                            '}' => "[}]".into(),
                            _ => c.to_string(),
                        })
                        .collect::<String>();
                    json!(format!("{}/**/*", escaped.trim_end_matches('/')))
                };
                json!({"globPattern": pattern, "kind": 7})
            })
            .collect::<Vec<_>>();
        self.connection.sender.send(
            Request::new(
                RequestId::from(WATCH_ID.to_owned()),
                "client/registerCapability".into(),
                json!({"registrations": [{
                    "id": "zettyp.sources", "method": "workspace/didChangeWatchedFiles",
                    "registerOptions": {"watchers": watchers}
                }]}),
            )
            .into(),
        )?;
        Ok(())
    }

    fn client_response(&mut self, response: Response) -> Result<()> {
        self.progress.response(self.connection, &response)?;
        if response.id == RequestId::from(WATCH_ID.to_owned()) {
            self.watching = response.error.is_none();
            if let Some(error) = response.error {
                self.log(
                    MessageType::WARNING,
                    format!("File watching unavailable: {}", error.message),
                )?;
            }
        }
        Ok(())
    }
}

fn invalid_output(error: anyhow::Error) -> ResponseError {
    failure(
        ErrorCode::RequestFailed,
        format!("invalid LSP announcement: {error:#}"),
    )
}
