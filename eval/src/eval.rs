use anyhow::{Context, Result, anyhow, bail};
use typst::diag::Warned;
use typst::foundations::{Array, Content, Dict, Label, NativeElement, Selector, Value};
use typst::introspection::{Introspector, MetadataElem};
use typst::{World, WorldExt};
use typst_layout::PagedDocument;

use crate::world::ProjectWorld;

const ANNOUNCEMENT_LABEL: &str = "eval.announcement";
const INSPECT_LABEL: &str = "eval.inspect";

/// Evaluate the prepared world and return announcements grouped by tag.
/// Call `ProjectWorld::prepare` before another evaluation, or use `Runtime`.
pub fn eval(world: &ProjectWorld) -> Warned<Result<Value>> {
    let compiled = typst::compile::<PagedDocument>(world);
    let output = compiled
        .output
        .map_err(|diagnostics| anyhow!("Typst evaluation failed: {diagnostics:#?}"))
        .and_then(|document| collect_announcements(&document, world));

    Warned {
        output,
        warnings: compiled.warnings,
    }
}

fn collect_announcements(document: &PagedDocument, world: &ProjectWorld) -> Result<Value> {
    let label =
        Label::construct(ANNOUNCEMENT_LABEL.into()).map_err(|error| anyhow!(error.to_string()))?;
    let selector = Selector::Label(label);
    let mut grouped = Dict::new();

    for announcement in document.introspector().query(&selector) {
        if announcement.func() != MetadataElem::ELEM {
            bail!("{ANNOUNCEMENT_LABEL} must label metadata content");
        }

        let Value::Dict(fields) = announcement
            .get_by_name("value")
            .map_err(|error| anyhow!("announcement metadata has no value: {error:?}"))?
        else {
            bail!("announcement metadata value must be a dictionary");
        };

        let tag = match fields
            .get("tag")
            .map_err(|error| anyhow!(error.to_string()))?
        {
            Value::Label(tag) => *tag,
            other => bail!("announcement tag must be a label, got {}", other.ty()),
        };
        let value = fields
            .get("value")
            .map_err(|error| anyhow!(error.to_string()))?
            .clone();
        let value = rewrite_inspects(value, world)?;
        push_announcement(&mut grouped, tag, value)?;
    }

    Ok(Value::Dict(grouped))
}

fn push_announcement(grouped: &mut Dict, tag: Label, value: Value) -> Result<()> {
    let tag = tag.resolve().to_string();
    if !grouped.contains(&tag) {
        grouped.insert(tag.clone().into(), Value::Array(Array::new()));
    }

    match grouped.at_mut(&tag).map_err(|error| anyhow!("{error:?}"))? {
        Value::Array(values) => {
            values.push(value);
            Ok(())
        }
        _ => unreachable!("announcement groups are always arrays"),
    }
}

fn rewrite_inspects(value: Value, world: &ProjectWorld) -> Result<Value> {
    match value {
        Value::Content(content) if has_label(&content, INSPECT_LABEL) => {
            resolve_inspect(&content, world)
        }
        Value::Array(values) => {
            let values = values
                .into_iter()
                .map(|value| rewrite_inspects(value, world))
                .collect::<Result<Vec<_>>>()?;
            Ok(Value::Array(values.into_iter().collect()))
        }
        Value::Dict(fields) => {
            let fields = fields
                .into_iter()
                .map(|(key, value)| Ok((key, rewrite_inspects(value, world)?)))
                .collect::<Result<Vec<_>>>()?;
            Ok(Value::Dict(fields.into_iter().collect()))
        }
        other => Ok(other),
    }
}

fn has_label(content: &Content, expected: &str) -> bool {
    content
        .label()
        .is_some_and(|label| label.resolve().as_str() == expected)
}

fn resolve_inspect(marker: &Content, world: &ProjectWorld) -> Result<Value> {
    if marker.func() != MetadataElem::ELEM {
        bail!("{INSPECT_LABEL} must label metadata content");
    }

    let target = marker
        .get_by_name("value")
        .map_err(|error| anyhow!("inspect metadata has no value: {error:?}"))?;
    let Value::Content(target) = target else {
        bail!("inspect metadata value must be content");
    };

    let span = target.span();
    let id = span.id().context("inspected content has no source file")?;
    let range = world
        .range(span)
        .context("cannot resolve inspected content span")?;
    let path = world.path_for(id)?;
    let source = path
        .to_str()
        .with_context(|| format!("source path is not valid UTF-8: {}", path.display()))?;

    let mut external_range = Dict::new();
    external_range.insert("start".into(), Value::Int(range.start.try_into()?));
    external_range.insert("end".into(), Value::Int(range.end.try_into()?));

    // Resolve editor coordinates against the evaluated source, never a later
    // disk read. Keep the original byte range for non-editor consumers.
    let text = world.source(id)?;
    let position = |byte| -> Result<Value> {
        let lines = text.lines();
        let line = lines.byte_to_line(byte).context("invalid source offset")?;
        let start = lines.line_to_byte(line).context("invalid source line")?;
        let character = text.text()[start..byte].encode_utf16().count();
        let mut value = Dict::new();
        value.insert("line".into(), Value::Int(line.try_into()?));
        value.insert("character".into(), Value::Int(character.try_into()?));
        Ok(Value::Dict(value))
    };
    let mut utf16_range = Dict::new();
    utf16_range.insert("start".into(), position(range.start)?);
    utf16_range.insert("end".into(), position(range.end)?);

    let mut inspect = Dict::new();
    inspect.insert("source".into(), Value::Str(source.into()));
    inspect.insert("range".into(), Value::Dict(external_range));
    inspect.insert("range-utf16".into(), Value::Dict(utf16_range));
    Ok(Value::Dict(inspect))
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    use anyhow::{Context, Result};
    use typst::foundations::{Dict, Value};

    use super::eval;
    use crate::world::ProjectWorld;

    #[test]
    fn groups_announcements_and_resolves_inspects() -> Result<()> {
        let nonce = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!("zettyp-eval-{}-{nonce}", std::process::id()));
        fs::create_dir(&root)?;
        fs::write(
            root.join("main.typ"),
            r#"#let inspect(value) = [#metadata(value)<eval.inspect>]
#let announce(tag, value) = [#metadata((tag: tag, value: value))<eval.announcement>]
#announce(label("demo"), (origin: inspect([hello]), ordinary: [world]))
"#,
        )?;

        let world = ProjectWorld::new(&root, "main.typ", Dict::new())?;
        let Value::Dict(output) = eval(&world).output? else {
            unreachable!("eval always returns a dictionary");
        };
        let Value::Array(values) = output.get("demo").map_err(anyhow::Error::msg)? else {
            unreachable!("announcement groups are arrays");
        };
        let Value::Dict(payload) = &values.as_slice()[0] else {
            unreachable!("fixture payload is a dictionary");
        };
        let Value::Dict(origin) = payload.get("origin").map_err(anyhow::Error::msg)? else {
            unreachable!("inspect resolves to a dictionary");
        };
        let Value::Str(source) = origin.get("source").map_err(anyhow::Error::msg)? else {
            unreachable!("inspect source is a string");
        };
        let Value::Dict(range) = origin.get("range").map_err(anyhow::Error::msg)? else {
            unreachable!("inspect range is a dictionary");
        };
        let Value::Int(start) = range.get("start").map_err(anyhow::Error::msg)? else {
            unreachable!("range start is an integer");
        };
        let Value::Int(end) = range.get("end").map_err(anyhow::Error::msg)? else {
            unreachable!("range end is an integer");
        };

        let source_text = fs::read_to_string(source.as_str())?;
        let inspected = source_text
            .get(usize::try_from(*start)?..usize::try_from(*end)?)
            .context("inspect range is not a source boundary")?;
        assert_eq!(inspected, "hello");
        assert!(matches!(payload.get("ordinary"), Ok(Value::Content(_))));

        fs::remove_dir_all(root)?;
        Ok(())
    }
}
