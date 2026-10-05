use anyhow::Result;
use std::{collections::BTreeMap, fs, path::Path};
use typst::foundations::{Dict, Value};
use zettyp_eval::{Runtime, WorldOptions};

fn copy(source: &Path, dest: &Path) -> Result<()> {
    fs::create_dir_all(dest)?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        if entry.file_type()?.is_dir() {
            copy(&entry.path(), &dest.join(entry.file_name()))?;
        } else {
            fs::copy(entry.path(), dest.join(entry.file_name()))?;
        }
    }
    Ok(())
}
fn inputs(value: serde_json::Value) -> Dict {
    [("host.request".into(), Value::Str(value.to_string().into()))]
        .into_iter()
        .collect()
}
#[test]
fn kickstart_plans_verify_in_virtual_workspace() -> Result<()> {
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let root = tempfile::tempdir()?;
    let packages = tempfile::tempdir()?;
    for (name, dir) in [
        ("zettyp-core", "core"),
        ("zettyp-lsp", "lsp/typst"),
        ("zettyp-host", "host/typst"),
    ] {
        copy(
            &repo.join(dir),
            &packages.path().join(format!("preview/{name}/0.1.0")),
        )?;
    }
    copy(&repo.join("kickstart/template"), root.path())?;
    let manifest = "# Registered notes\npaths = [\"note/welcome.typ\"]\n";
    fs::write(root.path().join(".zettypst/source.toml"), manifest)?;
    let mut runtime = Runtime::new_with_options(
        root.path(),
        WorldOptions {
            ignore_system_fonts: true,
            package_path: Some(packages.path().into()),
            ..Default::default()
        },
    )?;
    let read = runtime.evaluate(".zettypst/host/nodes.typ", Dict::new())?;
    let value = serde_json::to_value(read.result.output.as_ref().unwrap())?;
    assert_eq!(value["host.node"][0]["id"], "welcome");
    // A control character has no JSON escape that is also valid Typst.
    let request = serde_json::json!({"title": "A \"title\" #safe\u{7}", "now": {"year": 2026, "month": 10, "day": 5, "hour": 12, "minute": 0, "second": 0}});
    let plan = runtime.evaluate(".zettypst/host/new.typ", inputs(request))?;
    let value = serde_json::to_value(plan.result.output.as_ref().unwrap())?;
    let plan = &value["host.plan"][0];
    assert_eq!(plan["result"], serde_json::json!({}));
    let mut sources = BTreeMap::new();
    for effect in plan["effects"].as_array().unwrap() {
        sources.insert(
            effect["path"].as_str().unwrap().into(),
            Some(effect["content"].as_str().unwrap().into()),
        );
    }
    let verify = &plan["verify"];
    let params = verify["inputs"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(k, v)| (k.as_str().into(), Value::Str(v.as_str().unwrap().into())))
        .collect();
    let result = runtime.evaluate_with_sources(
        verify["entry"].as_str().unwrap(),
        params,
        sources.clone(),
    )?;
    let output = serde_json::to_value(result.result.output.as_ref().unwrap())?;
    let id = output["host.node"][0]["id"].as_str().unwrap();
    assert_eq!(output["host.node"].as_array().unwrap().len(), 1);
    assert_eq!(
        fs::read_to_string(root.path().join(".zettypst/source.toml"))?,
        manifest
    );
    for (path, content) in sources {
        fs::write(root.path().join(path), content.unwrap())?;
    }
    let registered = fs::read_to_string(root.path().join(".zettypst/source.toml"))?;
    assert!(
        registered.starts_with("# Registered notes\n"),
        "{registered}"
    );
    assert!(
        registered.contains(&format!("note/{id}.typ")),
        "{registered}"
    );
    let note = root.path().join(format!("note/{id}.typ"));
    let body = fs::read_to_string(&note)?;
    fs::write(&note, format!("{body}\n@{id}\n"))?;
    let selfref = runtime.evaluate(
        ".zettypst/host/delete.typ",
        inputs(serde_json::json!({"id": id})),
    )?;
    assert!(
        selfref.result.output.is_ok(),
        "a self-reference is not incoming: {:?}",
        selfref.result.output
    );
    let welcome = root.path().join("note/welcome.typ");
    let old = fs::read_to_string(&welcome)?;
    fs::write(&welcome, format!("{old}\n@{id}\n"))?;
    let refused = runtime.evaluate(
        ".zettypst/host/delete.typ",
        inputs(serde_json::json!({"id": id})),
    )?;
    assert!(
        refused.result.output.is_err(),
        "incoming edges require force"
    );
    let deleted = runtime.evaluate(
        ".zettypst/host/delete.typ",
        inputs(serde_json::json!({"id": id, "force": true})),
    )?;
    let output = serde_json::to_value(deleted.result.output.as_ref().unwrap())?;
    let plan = &output["host.plan"][0];
    let sources = plan["effects"]
        .as_array()
        .unwrap()
        .iter()
        .map(|effect| {
            (
                effect["path"].as_str().unwrap().into(),
                effect.get("content").map(|v| v.as_str().unwrap().into()),
            )
        })
        .collect();
    let params = plan["verify"]["inputs"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(k, v)| (k.as_str().into(), Value::Str(v.as_str().unwrap().into())))
        .collect();
    let result = runtime.evaluate_with_sources(
        plan["verify"]["entry"].as_str().unwrap(),
        params,
        sources,
    )?;
    assert!(result.result.output.is_ok(), "{:?}", result.result.output);
    fs::write(
        root.path().join("result.typ"),
        r#"#import "@preview/zettyp-core:0.1.0": eval
#import "@preview/zettyp-host:0.1.0" as host
#eval.announce(<host.plan>, host.plan((), (entry: "verify.typ", inputs: (:)),
  result: (created: false, key: none, nested: (values: (1, "value")))))"#,
    )?;
    let result = runtime.evaluate("result.typ", Dict::new())?;
    let output = serde_json::to_value(result.result.output.as_ref().unwrap())?;
    assert_eq!(
        output["host.plan"][0]["result"],
        serde_json::json!({"created": false, "key": null, "nested": {"values": [1, "value"]}})
    );
    for expr in [
        "host.node(1, \"x\", [x], (:))",
        "host.node(\"x\", \"x\", [x], (nested: ([x],)))",
        "host.create(\"../escape\", \"x\")",
        "host.plan((), (entry: \"x.typ\", inputs: (a: 1)))",
        "host.plan((), (entry: \"x.typ\", inputs: (:)), result: ())",
        "host.plan((), (entry: \"x.typ\", inputs: (:)), result: (nested: ([x],)))",
    ] {
        fs::write(
            root.path().join("bad.typ"),
            format!("#import \"@preview/zettyp-host:0.1.0\" as host\n#{expr}"),
        )?;
        assert!(
            runtime
                .evaluate("bad.typ", Dict::new())?
                .result
                .output
                .is_err(),
            "{expr}"
        );
    }
    Ok(())
}
