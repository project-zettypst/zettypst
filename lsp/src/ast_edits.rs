//! Lower declared syntax edits against retained evaluation sources, never disk.
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, ensure};
use lsp_types::{Position, Range};
use serde::Deserialize;
use serde_json::{Value, json};
use typst::syntax::{self, LinkedNode, Side, Source, SyntaxKind, ast};
use zettyp_eval::SourceSnapshot;

#[cfg(test)]
mod tests;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Bytes {
    start: usize,
    end: usize,
}

#[derive(Deserialize)]
struct Anchor {
    source: PathBuf,
    range: Bytes,
    #[serde(rename = "range-utf16")]
    utf16: Range,
}

#[derive(Deserialize)]
#[serde(tag = "kind", deny_unknown_fields)]
enum Edit {
    #[serde(rename = "text.replace")]
    Text {
        origin: Value,
        #[serde(rename = "new-text")]
        new_text: String,
    },
    #[serde(rename = "ast.insert-argument")]
    InsertArgument {
        body: Anchor,
        name: String,
        #[serde(rename = "value-source")]
        value: String,
    },
}

/// Normalized announcements can be persisted with their existing dependency
/// fingerprints. Restoration does not need to reparse newer source text.
pub fn resolve(output: &mut Value, sources: &SourceSnapshot, root: &Path) -> Result<()> {
    let Some(reports) = output.get_mut("lsp.code-actions") else {
        return Ok(());
    };
    for report in reports
        .as_array_mut()
        .context("code actions must be an array")?
    {
        let actions = report
            .get_mut("actions")
            .and_then(Value::as_array_mut)
            .context("code action report requires actions")?;
        for action in actions {
            let Some(edit) = action.get_mut("edit").filter(|v| !v.is_null()) else {
                continue;
            };
            let items = edit
                .get_mut("edits")
                .context("workspace edit requires edits")?;
            let operations: Vec<Edit> = serde_json::from_value(items.clone())?;
            let resolved = operations
                .into_iter()
                .map(|operation| match operation {
                    Edit::Text { origin, new_text } => Ok(json!({
                        "kind": "text.replace", "origin": origin, "new-text": new_text,
                    })),
                    Edit::InsertArgument { body, name, value } => {
                        let relative = body
                            .source
                            .strip_prefix(root)
                            .context("AST edit source must belong to the project")?;
                        let relative = relative.to_str().context("invalid AST source path")?;
                        let _ = crate::host::relative(relative)?;
                        let id = syntax::FileId::new(syntax::RootedPath::new(
                            syntax::VirtualRoot::Project,
                            syntax::VirtualPath::new(relative)?,
                        ));
                        let source = sources.source(id).context("AST source was not evaluated")?;
                        ensure!(
                            sources.path_for(id)? == body.source,
                            "AST source identity mismatch"
                        );
                        let (at, insertion) = insert_argument(source, &body, &name, &value)?;
                        let position = position(source, at)?;
                        Ok(json!({
                            "kind": "text.replace",
                            "origin": {
                                "source": body.source,
                                "range": {"start": at, "end": at},
                                "range-utf16": {"start": position, "end": position},
                            },
                            "new-text": insertion,
                        }))
                    }
                })
                .collect::<Result<Vec<_>>>()?;
            *items = Value::Array(resolved);
        }
    }
    Ok(())
}

fn position(source: &Source, byte: usize) -> Result<Position> {
    ensure!(
        source.text().is_char_boundary(byte),
        "invalid UTF-8 source boundary"
    );
    let line = source
        .lines()
        .byte_to_line(byte)
        .context("source offset out of bounds")?;
    let start = source
        .lines()
        .line_to_byte(line)
        .context("invalid source line")?;
    Ok(Position::new(
        line.try_into()?,
        source.text()[start..byte]
            .encode_utf16()
            .count()
            .try_into()?,
    ))
}

fn insert_argument(
    source: &Source,
    anchor: &Anchor,
    name: &str,
    value: &str,
) -> Result<(usize, String)> {
    let range = anchor.range.start..anchor.range.end;
    ensure!(
        range.start < range.end && range.end <= source.text().len(),
        "invalid AST body range"
    );
    ensure!(
        Range::new(position(source, range.start)?, position(source, range.end)?) == anchor.utf16,
        "AST byte and UTF-16 ranges disagree",
    );
    ensure!(
        source.root().errors_and_warnings().0.is_empty(),
        "cannot edit erroneous source"
    );

    // Parse the name and value in their actual syntactic roles. Reject injected
    // arguments, statements, trailing tokens, and names that are not identifiers.
    let identifier = syntax::parse_code(name);
    let children: Vec<_> = identifier.children().collect();
    ensure!(
        children.len() == 1
            && children[0].kind() == SyntaxKind::Ident
            && children[0]
                .cast::<ast::Ident>()
                .is_some_and(|id| id.as_str() == name),
        "argument name must be one identifier",
    );
    let probe = syntax::parse_code(&format!("f({value})"));
    ensure!(
        probe.errors_and_warnings().0.is_empty(),
        "invalid argument expression"
    );
    let exprs: Vec<_> = probe.children().filter(|n| !n.kind().is_trivia()).collect();
    ensure!(exprs.len() == 1, "argument value must be one expression");
    let call = exprs[0]
        .cast::<ast::FuncCall>()
        .context("argument value escaped its call")?;
    let arguments: Vec<_> = call.args().items().collect();
    ensure!(
        arguments.len() == 1 && matches!(arguments[0], ast::Arg::Pos(_)),
        "argument value must be one positional expression"
    );

    let linked = LinkedNode::new(source.root());
    let mut body = linked
        .leaf_at(range.start, Side::After)
        .context("missing body syntax")?;
    loop {
        if body.kind() == SyntaxKind::ContentBlock && body.range() == range {
            break;
        }
        body = body
            .parent()
            .context("origin must identify an exact content block")?
            .clone();
    }
    let args = body.parent().context("body has no enclosing arguments")?;
    ensure!(
        args.kind() == SyntaxKind::Args,
        "body must be a direct call argument"
    );
    let parent = args.parent().context("arguments have no call")?;
    ensure!(
        parent.kind() == SyntaxKind::FuncCall,
        "body must belong to a function call"
    );
    let call = parent
        .get()
        .cast::<ast::FuncCall>()
        .context("invalid call syntax")?;
    for arg in call.args().items() {
        match arg {
            ast::Arg::Named(arg) => ensure!(
                arg.name().as_str() != name,
                "argument already exists: {name}"
            ),
            ast::Arg::Spread(_) => {
                anyhow::bail!("cannot prove argument absence with spread arguments")
            }
            _ => {}
        }
    }
    let open = args.children().find(|n| n.kind() == SyntaxKind::LeftParen);
    let (at, insertion) = if let Some(open) = open {
        let close = args
            .children()
            .find(|n| n.kind() == SyntaxKind::RightParen)
            .context("unclosed argument list")?;
        let occupied = args.children().any(|n| {
            n.range().start >= open.range().end
                && n.range().end <= close.range().start
                && !n.kind().is_trivia()
        });
        (
            open.range().end,
            format!("{name}: {value}{}", if occupied { ", " } else { "" }),
        )
    } else {
        // Insert before the argument list, not before an arbitrary later body.
        (args.range().start, format!("({name}: {value})"))
    };
    let mut candidate = source.text().to_string();
    candidate.insert_str(at, &insertion);
    ensure!(
        syntax::parse(&candidate).errors_and_warnings().0.is_empty(),
        "insertion produces invalid syntax"
    );
    Ok((at, insertion))
}
