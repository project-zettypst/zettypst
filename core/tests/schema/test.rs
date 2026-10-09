use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde_json::Value;
use typst::foundations::Dict;
use zettyp_eval::{Runtime, WorldOptions};

fn runtime() -> Runtime {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    Runtime::new_with_options(
        root,
        WorldOptions {
            ignore_system_fonts: true,
            ..Default::default()
        },
    )
    .unwrap()
}

fn evaluate(runtime: &mut Runtime, body: &str) -> Result<Value, String> {
    let entry = PathBuf::from("core/tests/schema/main.typ");
    let source = format!(
        r#"#import "/core/graph-schema.typ" as schema
#import "/core/knowledge/schema.typ" as knowledge
#import "/core/policy/schema.typ" as policy
#import "@preview/valkyrie:0.2.2" as z
{body}
"#
    );
    let evaluation = runtime
        .evaluate_with_sources(
            &entry,
            Dict::new(),
            BTreeMap::from([(entry.clone(), Some(source))]),
        )
        .unwrap();
    evaluation
        .result
        .output
        .as_ref()
        .map(|value| serde_json::to_value(value).unwrap())
        .map_err(|error| format!("{error:#}"))
}

fn check(runtime: &mut Runtime, expression: &str, ty: &str) -> Result<Value, String> {
    evaluate(
        runtime,
        &format!(
            r#"#let value = {expression}
#let result = schema.checked(value, {ty}, scope: ("test",))
#assert.eq(result, value)
#metadata((tag: <schema.test>, value: result))<eval.announcement>"#
        ),
    )
}

#[test]
fn readonly_arrays_match_existing_validation_rules() {
    let mut runtime = runtime();
    // Compare to Valkyrie's rebuilding arrays, including exact error paths.
    for (value, item, bounds, expected_error) in [
        ("()", "schema.id", "", None),
        (r#"("a", "b")"#, "schema.id", ", min: 1, max: 2", None),
        ("(none, auto, (payload: (1, 2)))", "schema.opaque", "", None),
        ("none", "schema.id", "", Some("test: Expected array")),
        ("auto", "schema.id", "", Some("test: Expected array")),
        ("42", "schema.id", "", Some("test: Expected array")),
        (
            "()",
            "schema.id",
            ", min: 1",
            Some("test: Length must be at least 1"),
        ),
        (
            r#"("a",)"#,
            "schema.id",
            ", max: 0",
            Some("test: Length must be at most 0"),
        ),
        (
            r#"("a", "")"#,
            "schema.id",
            "",
            Some("test.1: Length must be at least 1"),
        ),
        (r#"("a", 3)"#, "schema.id", "", Some("test.1: Expected str")),
        (
            r#"(("a",), ("b", ""))"#,
            "schema.array(schema.id)",
            "",
            Some("test.1.1: Length must be at least 1"),
        ),
    ] {
        let readonly = format!("schema.array({item}{bounds})");
        let rebuilding = format!("z.array({item}{bounds}, default: none)");
        let actual = check(&mut runtime, value, &readonly);
        let previous = check(&mut runtime, value, &rebuilding);
        match expected_error {
            None => assert_eq!(actual.unwrap(), previous.unwrap(), "{value}"),
            Some(message) => {
                assert!(actual.unwrap_err().contains(message), "{value}: {message}");
                assert!(
                    previous.unwrap_err().contains(message),
                    "{value}: {message}"
                );
            }
        }
    }
}

#[test]
fn parsed_elements_are_checked_but_do_not_replace_inputs() {
    let mut runtime = runtime();
    evaluate(
        &mut runtime,
        r#"#let value = ("1", "2")
#let item = z.integer(min: 1, pre-transform: (self, value) => int(value))
#assert.eq(z.parse(value, schema.array(item)), value)
#assert.eq(schema.checked(value, schema.array(item)), value)
#assert.eq(z.parse((none,), schema.array(z.integer(default: 7))), (none,))"#,
    )
    .unwrap();
    let error = evaluate(
        &mut runtime,
        r#"#let item = z.integer(min: 1, pre-transform: (self, value) => int(value))
#let _ = z.parse(("1", "0"), schema.array(item), scope: ("test",))"#,
    )
    .unwrap_err();
    assert!(error.contains("test.1:"), "{error}");
}

#[test]
fn nested_records_and_indexed_fields_are_still_checked() {
    let mut runtime = runtime();
    for (value, ty, message) in [
        (
            r#"((id: "a", value: none),)"#,
            "schema.array(schema.node-declaration)",
            "test.0.origin: Missing required field",
        ),
        (
            r#"((id: "a", value: none, origin: none, extra: true),)"#,
            "schema.array(schema.node-declaration)",
            "test.0.extra: Unknown field",
        ),
        (
            r#"((id: "a", value: none, origin: none), (id: "", value: none, origin: none))"#,
            "schema.array(schema.node-declaration)",
            "test.1.id: Length must be at least 1",
        ),
        (
            r#"(nodes: ("a",), edges: (e: (source: "a", target: 3)))"#,
            "schema.graph",
            "test.edges.e.target: Expected str",
        ),
        (
            r#"(nodes: ("a",), edges: ("": (source: "a", target: "a")))"#,
            "schema.graph",
            "test.edges..key: Length must be at least 1",
        ),
    ] {
        let error = check(&mut runtime, value, ty).unwrap_err();
        assert!(error.contains(message), "{error}");
    }
}

#[test]
fn bounded_policy_and_registry_arrays_keep_their_contracts() {
    let mut runtime = runtime();
    for (value, ty, message) in [
        (
            "(1,)",
            "knowledge.no-positional",
            "test: Length must be at most 0",
        ),
        (
            r#"(kind: "failure", invocation: "a", issues: ())"#,
            "policy.failure",
            "test.issues: Length must be at least 1",
        ),
        (
            r#"(kind: "blocked", invocation: "a", dependencies: ())"#,
            "policy.blocked",
            "test.dependencies: Length must be at least 1",
        ),
        (
            r#"(kind: "blocked", invocation: "a", dependencies: ("b", ""))"#,
            "policy.blocked",
            "test.dependencies.1: Length must be at least 1",
        ),
        (
            r#"(kind: "blocked", invocation: "a", dependencies: none)"#,
            "policy.blocked",
            "test.dependencies: Expected array",
        ),
    ] {
        let error = check(&mut runtime, value, ty).unwrap_err();
        assert!(error.contains(message), "{error}");
    }
    check(&mut runtime, "()", "knowledge.no-positional").unwrap();
    check(
        &mut runtime,
        r#"(kind: "failure", invocation: "a", issues: (none, (detail: (1, 2))))"#,
        "policy.failure",
    )
    .unwrap();
    check(
        &mut runtime,
        r#"(kind: "blocked", invocation: "a", dependencies: ("b", "b"))"#,
        "policy.blocked",
    )
    .unwrap();
}
