//! Decode the Typst wrapper contract and translate it, without domain queries.
use std::collections::BTreeMap;
use std::path::PathBuf;

use anyhow::{Result, bail, ensure};
use lsp_types::*;
use serde::Deserialize;
use serde_json::Value;

pub enum Query {
    Hover(HoverParams),
    Definition(GotoDefinitionParams),
    References(ReferenceParams),
    Actions(CodeActionParams),
}

impl Query {
    pub fn parse(method: &str, params: Value) -> Result<Self> {
        let query = match method {
            "textDocument/hover" => Self::Hover(serde_json::from_value(params)?),
            "textDocument/definition" => Self::Definition(serde_json::from_value(params)?),
            "textDocument/references" => Self::References(serde_json::from_value(params)?),
            "textDocument/codeAction" => Self::Actions(serde_json::from_value(params)?),
            _ => bail!("unsupported query"),
        };
        if let Self::Actions(params) = &query {
            ensure!(
                params.range.start <= params.range.end,
                "invalid request range"
            );
        }
        Ok(query)
    }

    pub fn uri(&self) -> &Url {
        match self {
            Self::Hover(p) => &p.text_document_position_params.text_document.uri,
            Self::Definition(p) => &p.text_document_position_params.text_document.uri,
            Self::References(p) => &p.text_document_position.text_document.uri,
            Self::Actions(p) => &p.text_document.uri,
        }
    }
}

/// Editor identities and versions at the same generation as the announcements.
pub struct View {
    pub root: PathBuf,
    pub client_root: PathBuf,
    pub aliases: BTreeMap<PathBuf, Url>,
    pub versions: BTreeMap<Url, i32>,
    pub code_actions: bool,
    pub disabled_actions: bool,
}

impl View {
    fn location(&self, origin: &Origin) -> Result<Location> {
        ensure!(
            origin.range.start <= origin.range.end,
            "invalid announcement range"
        );
        let uri = match self.aliases.get(&origin.source) {
            Some(uri) => uri.clone(),
            None => {
                let path = origin
                    .source
                    .strip_prefix(&self.root)
                    .map(|relative| self.client_root.join(relative))
                    .unwrap_or_else(|_| origin.source.clone());
                Url::from_file_path(path).map_err(|_| {
                    anyhow::anyhow!("invalid source path: {}", origin.source.display())
                })?
            }
        };
        Ok(Location {
            uri,
            range: origin.range,
        })
    }

    fn same_document(&self, origin: &Origin, uri: &Url) -> Result<bool> {
        if &self.location(origin)?.uri == uri {
            return Ok(true);
        }
        let Ok(path) = uri.to_file_path() else {
            return Ok(false);
        };
        let path = path
            .strip_prefix(&self.client_root)
            .map(|relative| self.root.join(relative))
            .unwrap_or(path);
        Ok(path == origin.source)
    }

    fn matches(&self, origin: &Origin, uri: &Url, range: Range) -> Result<bool> {
        if !self.same_document(origin, uri)? {
            return Ok(false);
        }
        let target = origin.range;
        Ok(if range.start == range.end {
            if target.start == target.end {
                range.start == target.start
            } else {
                target.start <= range.start && range.start < target.end
            }
        } else {
            range.start < target.end && target.start < range.end
        })
    }
}

#[derive(Deserialize)]
struct Origin {
    source: PathBuf,
    #[serde(rename = "range-utf16")]
    range: Range,
}

#[derive(Default, Deserialize)]
pub struct Announcements {
    #[serde(default, rename = "lsp.hover")]
    hovers: Vec<HoverValue>,
    #[serde(default, rename = "lsp.definition")]
    definitions: Vec<DefinitionValue>,
    #[serde(default, rename = "lsp.references")]
    references: Vec<ReferencesValue>,
    #[serde(default, rename = "lsp.publish-diagnostics")]
    diagnostics: Vec<DiagnosticReport>,
    #[serde(default, rename = "lsp.code-actions")]
    actions: Vec<ActionReport>,
}

impl Announcements {
    pub fn respond(&self, query: &Query, view: &View) -> Result<Value> {
        match query {
            Query::Hover(params) => {
                let p = &params.text_document_position_params;
                for item in &self.hovers {
                    if view.matches(&item.applies_to, &p.text_document.uri, point(p.position))? {
                        return Ok(serde_json::to_value(Hover {
                            contents: HoverContents::Markup(item.contents.clone()),
                            range: Some(item.applies_to.range),
                        })?);
                    }
                }
                Ok(Value::Null)
            }
            Query::Definition(params) => {
                let p = &params.text_document_position_params;
                for item in &self.definitions {
                    if view.matches(&item.applies_to, &p.text_document.uri, point(p.position))? {
                        return Ok(serde_json::to_value(view.location(&item.target)?)?);
                    }
                }
                Ok(Value::Null)
            }
            Query::References(params) => {
                let p = &params.text_document_position;
                for item in &self.references {
                    if view.matches(&item.applies_to, &p.text_document.uri, point(p.position))? {
                        let origins = item.targets.iter().chain(
                            item.declarations
                                .iter()
                                .filter(|_| params.context.include_declaration),
                        );
                        let locations = origins
                            .map(|o| view.location(o))
                            .collect::<Result<Vec<_>>>()?;
                        return Ok(serde_json::to_value(locations)?);
                    }
                }
                Ok(serde_json::json!([]))
            }
            Query::Actions(params) => {
                let mut actions = Vec::new();
                if view.code_actions {
                    for report in &self.actions {
                        // The document anchor identifies the publication, not its extent.
                        if !view.same_document(&report.document, &params.text_document.uri)? {
                            continue;
                        }
                        for item in &report.actions {
                            if item.disabled.is_some() && !view.disabled_actions {
                                continue;
                            }
                            if let Some(only) = &params.context.only
                                && !only.iter().any(|kind| {
                                    let expected = kind.as_str();
                                    expected.is_empty()
                                        || item.kind.as_ref().is_some_and(|actual| {
                                            actual.as_str() == expected
                                                || actual
                                                    .as_str()
                                                    .starts_with(&format!("{expected}."))
                                        })
                                })
                            {
                                continue;
                            }
                            if view.matches(
                                &item.applies_to,
                                &params.text_document.uri,
                                params.range,
                            )? {
                                actions.push(item.convert(view)?);
                            }
                        }
                    }
                }
                Ok(serde_json::to_value(actions)?)
            }
        }
    }

    pub fn publications(&self, view: &View) -> Result<BTreeMap<Url, Vec<Diagnostic>>> {
        let mut documents = BTreeMap::<Url, Vec<Diagnostic>>::new();
        for report in &self.diagnostics {
            let uri = view.location(&report.document)?.uri;
            let diagnostics = documents.entry(uri.clone()).or_default();
            for item in &report.diagnostics {
                ensure!(
                    view.location(&item.origin)?.uri == uri,
                    "diagnostic origin belongs to a different publication document"
                );
                diagnostics.push(item.convert(view)?);
            }
        }
        Ok(documents)
    }
}

fn point(position: Position) -> Range {
    Range {
        start: position,
        end: position,
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "kebab-case")]
struct HoverValue {
    applies_to: Origin,
    contents: MarkupContent,
}

#[derive(Deserialize)]
#[serde(rename_all = "kebab-case")]
struct DefinitionValue {
    applies_to: Origin,
    target: Origin,
}

#[derive(Deserialize)]
#[serde(rename_all = "kebab-case")]
struct ReferencesValue {
    applies_to: Origin,
    targets: Vec<Origin>,
    declarations: Vec<Origin>,
}

#[derive(Deserialize)]
struct DiagnosticReport {
    document: Origin,
    diagnostics: Vec<DiagnosticValue>,
}

#[derive(Deserialize)]
#[serde(rename_all = "kebab-case")]
struct DiagnosticValue {
    origin: Origin,
    message: String,
    severity: Option<DiagnosticSeverity>,
    code: Option<NumberOrString>,
    source: Option<String>,
    tags: Option<Vec<DiagnosticTag>>,
    related_information: Option<Vec<DiagnosticRelatedInformation>>,
    data: Option<Value>,
}

impl DiagnosticValue {
    fn convert(&self, view: &View) -> Result<Diagnostic> {
        Ok(Diagnostic {
            range: view.location(&self.origin)?.range,
            severity: self.severity,
            code: self.code.clone(),
            source: self.source.clone(),
            message: self.message.clone(),
            tags: self.tags.clone(),
            related_information: self.related_information.clone(),
            data: self.data.clone(),
            ..Diagnostic::default()
        })
    }
}

#[derive(Deserialize)]
struct ActionReport {
    document: Origin,
    actions: Vec<ActionValue>,
}

#[derive(Deserialize)]
#[serde(rename_all = "kebab-case")]
struct ActionValue {
    applies_to: Origin,
    title: String,
    kind: Option<CodeActionKind>,
    diagnostics: Vec<DiagnosticValue>,
    edit: Option<EditValue>,
    is_preferred: Option<bool>,
    disabled: Option<String>,
    data: Option<Value>,
}

impl ActionValue {
    fn convert(&self, view: &View) -> Result<CodeAction> {
        Ok(CodeAction {
            title: self.title.clone(),
            kind: self.kind.clone(),
            diagnostics: Some(
                self.diagnostics
                    .iter()
                    .map(|d| d.convert(view))
                    .collect::<Result<_>>()?,
            ),
            edit: self.edit.as_ref().map(|e| e.convert(view)).transpose()?,
            is_preferred: self.is_preferred,
            disabled: self.disabled.as_ref().map(|reason| CodeActionDisabled {
                reason: reason.clone(),
            }),
            data: self.data.clone(),
            ..CodeAction::default()
        })
    }
}

#[derive(Deserialize)]
struct EditValue {
    edits: Vec<TextEditValue>,
}

#[derive(Deserialize)]
enum TextEditKind {
    #[serde(rename = "text.replace")]
    Replace,
}

// AST edits have already been lowered against the worker's source snapshot.
#[derive(Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct TextEditValue {
    #[serde(rename = "kind")]
    _kind: TextEditKind,
    origin: Origin,
    new_text: String,
}

impl EditValue {
    fn convert(&self, view: &View) -> Result<WorkspaceEdit> {
        let mut documents = BTreeMap::<Url, Vec<TextEdit>>::new();
        for item in &self.edits {
            let location = view.location(&item.origin)?;
            documents.entry(location.uri).or_default().push(TextEdit {
                range: location.range,
                new_text: item.new_text.clone(),
            });
        }
        let edits = documents
            .into_iter()
            .map(|(uri, edits)| {
                let mut ranges: Vec<_> = edits.iter().map(|edit| edit.range).collect();
                ranges.sort_by_key(|range| (range.start, range.end));
                ensure!(
                    ranges.windows(2).all(|pair| {
                        pair[0].end <= pair[1].start && pair[0].start != pair[1].start
                    }),
                    "workspace edit contains overlapping ranges"
                );
                Ok(TextDocumentEdit {
                    text_document: OptionalVersionedTextDocumentIdentifier {
                        version: view.versions.get(&uri).copied(),
                        uri,
                    },
                    edits: edits.into_iter().map(OneOf::Left).collect(),
                })
            })
            .collect::<Result<_>>()?;
        Ok(WorkspaceEdit {
            document_changes: Some(DocumentChanges::Edits(edits)),
            ..WorkspaceEdit::default()
        })
    }
}
