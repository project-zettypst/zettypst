use super::*;
use std::collections::BTreeMap;
use typst::foundations::Dict;
use zettyp_eval::{Runtime, WorldOptions};

fn anchor(source: &Source, body: &str) -> Anchor {
    let start = source.text().find(body).unwrap();
    let end = start + body.len();
    Anchor {
        source: "/project/main.typ".into(),
        range: Bytes { start, end },
        utf16: Range::new(
            position(source, start).unwrap(),
            position(source, end).unwrap(),
        ),
    }
}

#[test]
fn minimal_insertions_preserve_original_source() -> Result<()> {
    for (text, body, expected) in [
        ("#note()[Body]", "[Body]", "#note(id: <new>)[Body]"),
        ("#note[Body]", "[Body]", "#note(id: <new>)[Body]"),
        (
            "#alias(x: 1)[Body]",
            "[Body]",
            "#alias(id: <new>, x: 1)[Body]",
        ),
        (
            "#note(/*keep*/)[Body]",
            "[Body]",
            "#note(id: <new>/*keep*/)[Body]",
        ),
        (
            "#note(\n // 中文 🚀\n x: 1,\n)[Body]",
            "[Body]",
            "#note(id: <new>, \n // 中文 🚀\n x: 1,\n)[Body]",
        ),
        (
            "#note()[#note()[Inner]]",
            "[Inner]",
            "#note()[#note(id: <new>)[Inner]]",
        ),
        (
            "#note()[#note()[Inner]]",
            "[#note()[Inner]]",
            "#note(id: <new>)[#note()[Inner]]",
        ),
        (
            "前文 🚀\r\n#note()[正文]",
            "[正文]",
            "前文 🚀\r\n#note(id: <new>)[正文]",
        ),
        (
            "#ns.note([Body], x: 1)",
            "[Body]",
            "#ns.note(id: <new>, [Body], x: 1)",
        ),
    ] {
        let source = Source::detached(text);
        let (at, insertion) = insert_argument(&source, &anchor(&source, body), "id", "<new>")?;
        let mut changed = text.to_owned();
        changed.insert_str(at, &insertion);
        assert_eq!(changed, expected);
    }
    Ok(())
}

#[test]
fn ambiguous_and_invalid_edits_are_rejected() {
    for (text, body, name, value) in [
        ("#note(id: <old>)[Body]", "[Body]", "id", "<new>"),
        ("#note(..options)[Body]", "[Body]", "id", "<new>"),
        ("#let body = [Body]\n#note(body)", "[Body]", "id", "<new>"),
        ("#note(body: [Body])", "[Body]", "id", "<new>"),
        ("#note()[Body]", "Body", "id", "<new>"),
        ("#note()[Body]", "[Body]", "id: bad", "<new>"),
        ("#note()[Body]", "[Body]", "let", "<new>"),
        ("#note()[Body]", "[Body]", "id", "1, other: 2"),
        ("#note()[Body]", "[Body]", "id", "..args"),
        ("#note()[Body]", "[Body]", "id", "1); f(2"),
        ("#note()[Body]", "[Body]", "id", ""),
    ] {
        let source = Source::detached(text);
        assert!(
            insert_argument(&source, &anchor(&source, body), name, value).is_err(),
            "{text} {name} {value}"
        );
    }
    let source = Source::detached("#note()[正文]");
    let mut body = anchor(&source, "[正文]");
    body.utf16.start.character += 1;
    assert!(insert_argument(&source, &body, "id", "<new>").is_err());
}

#[test]
fn tagged_contract_is_mandatory() {
    for edit in [
        json!({"origin": {}, "new-text": "x"}),
        json!({"kind": "ast.unknown"}),
        json!({"kind": "text.replace", "origin": {}, "new-text": "x", "body": {}}),
    ] {
        assert!(serde_json::from_value::<Edit>(edit).is_err());
    }
}

/// Exercise the real Typst constructors and inspect externalization, retaining
/// an unsaved overlay even after both disk and the runtime have moved on.
#[test]
fn announcement_to_workspace_edit_uses_evaluated_snapshot() -> Result<()> {
    let temp = tempfile::tempdir()?;
    let root = temp.path().canonicalize()?;
    let package = Path::new(env!("CARGO_MANIFEST_DIR")).join("../typst");
    std::fs::create_dir(root.join("lib"))?;
    std::fs::copy(package.join("core/eval.typ"), root.join("eval.typ"))?;
    // Preserve the adapters' relative import layout in this isolated fixture.
    std::fs::create_dir_all(root.join("core"))?;
    std::fs::copy(package.join("core/eval.typ"), root.join("core/eval.typ"))?;
    for name in ["lib.typ", "ast.typ"] {
        std::fs::copy(package.join("lsp").join(name), root.join("lib").join(name))?;
    }
    let text = r#"#import "lib/lib.typ" as lsp
#let note(body, id: none) = {
  if id != none { assert.eq(id, <new>); return body }
  let title = body.children.find(it => it.func() == heading)
  lsp.announce(lsp.effect-kinds.code-actions, lsp.offer-code-actions(
    document: title,
    actions: (lsp.code-action(
      applies-to: title,
      title: "Insert an argument",
      edit: lsp.workspace-edit(edits: (
        lsp.ast.insert-argument(body: body, name: "id", value-source: "<new>"),
        lsp.text-edit(origin: title, new-text: "== Renamed"),
      )),
    ),),
  ))
}
#note()[
== Original
Body.
]
"#;
    std::fs::write(
        root.join("main.typ"),
        "#panic(\"disk must not be evaluated\")",
    )?;
    let mut runtime = Runtime::new_with_options(
        &root,
        WorldOptions {
            ignore_system_fonts: true,
            ..Default::default()
        },
    )?;
    let old = runtime.evaluate_with_sources(
        "main.typ",
        Dict::new(),
        BTreeMap::from([("main.typ".into(), Some(text.into()))]),
    )?;
    let mut output = serde_json::to_value(
        old.result
            .output
            .as_ref()
            .map_err(|e| anyhow::anyhow!("{e:#}"))?,
    )?;
    runtime.evaluate_with_sources(
        "main.typ",
        Dict::new(),
        BTreeMap::from([("main.typ".into(), Some("Different document".into()))]),
    )?;
    std::fs::write(root.join("main.typ"), "New disk text")?;
    resolve(&mut output, &old.sources, &root)?;
    let values: crate::values::Announcements = serde_json::from_value(output.clone())?;
    let uri = lsp_types::Url::from_file_path(root.join("main.typ")).unwrap();
    let view = crate::values::View {
        root: root.clone(),
        client_root: root.clone(),
        aliases: BTreeMap::new(),
        versions: BTreeMap::from([(uri.clone(), 7)]),
        code_actions: true,
        disabled_actions: true,
    };
    let heading = &output["lsp.code-actions"][0]["actions"][0]["applies-to"]["range-utf16"];
    let query = crate::values::Query::parse(
        "textDocument/codeAction",
        json!({
            "textDocument": {"uri": uri}, "range": heading, "context": {"diagnostics": []},
        }),
    )?;
    let response = values.respond(&query, &view)?;
    let change = &response[0]["edit"]["documentChanges"][0];
    assert_eq!(change["textDocument"]["version"], 7);
    let edits = change["edits"].as_array().unwrap();
    assert_eq!(edits.len(), 2);
    assert_eq!(edits[0]["newText"], "id: <new>");
    assert_eq!(edits[1]["newText"], "== Renamed");
    // No write to disk is performed by syntax resolution or the code action.
    assert_eq!(
        std::fs::read_to_string(root.join("main.typ"))?,
        "New disk text"
    );

    // Only the test applies the returned LSP edits and evaluates the candidate.
    // Production syntax resolution does not perform a second evaluation.
    let source = Source::detached(text);
    let byte = |position: Position| {
        let lines = source.lines();
        let line = lines.line_to_byte(position.line as usize).unwrap();
        lines
            .utf16_to_byte(lines.byte_to_utf16(line).unwrap() + position.character as usize)
            .unwrap()
    };
    let mut edits: Vec<lsp_types::TextEdit> = serde_json::from_value(change["edits"].clone())?;
    edits.sort_by_key(|edit| (edit.range.start, edit.range.end));
    let mut patched = text.to_owned();
    for edit in edits.into_iter().rev() {
        patched.replace_range(byte(edit.range.start)..byte(edit.range.end), &edit.new_text);
    }
    assert!(patched.contains("#note(id: <new>)["));
    assert!(patched.contains("== Renamed"));
    let verified = runtime.evaluate_with_sources(
        "main.typ",
        Dict::new(),
        BTreeMap::from([("main.typ".into(), Some(patched))]),
    )?;
    assert!(
        verified.result.output.is_ok(),
        "{:?}",
        verified.result.output
    );
    assert_eq!(
        std::fs::read_to_string(root.join("main.typ"))?,
        "New disk text"
    );

    // The same plan must fail as a whole when two inserts collide.
    let item = output["lsp.code-actions"][0]["actions"][0]["edit"]["edits"][0].clone();
    output["lsp.code-actions"][0]["actions"][0]["edit"]["edits"]
        .as_array_mut()
        .unwrap()
        .push(item);
    let conflicting: crate::values::Announcements = serde_json::from_value(output)?;
    assert!(conflicting.respond(&query, &view).is_err());
    Ok(())
}
