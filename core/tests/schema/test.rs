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

/// Boundary cases shared by the error snapshot and fast-path agreement tests.
/// Each entry is (value, schema, expected error suffix or None when valid).
const BOUNDARY_CASES: &[(&str, &str, Option<&str>)] = &[
    ("0", "policy.arity", None),
    ("-1", "policy.arity", Some("test: Value must be at least 0")),
    ("1.5", "policy.arity", Some("test: Expected int. Got float")),
    ("none", "policy.arity", Some("test: Expected int. Got none")),
    ("x => x", "policy.callable", None),
    (
        "1",
        "policy.callable",
        Some("test: Expected function. Got integer"),
    ),
    (
        "none",
        "policy.callable",
        Some("test: Expected function. Got none"),
    ),
    (r#"(side: "right", value: none)"#, "policy.sum", None),
    (
        r#"(side: "up", value: 1)"#,
        "policy.sum",
        Some(r#"test.side: Unknown string `"up"`"#),
    ),
    (
        "(side: 1, value: 1)",
        "policy.sum",
        Some("test.side: Expected str. Got integer"),
    ),
    (
        r#"(side: "left")"#,
        "policy.sum",
        Some("test.value: Missing required field"),
    ),
    (
        r#"(kind: "blocked", invocation: "a", dependencies: ("b",))"#,
        "policy.error",
        None,
    ),
    (
        r#"(invocation: "a")"#,
        "policy.error",
        Some("test.kind: Expected str. Got none"),
    ),
    (
        r#"(kind: "x", invocation: "a")"#,
        "policy.error",
        Some(r#"test.kind: Unknown string `"x"`"#),
    ),
    (
        r#"(kind: "failure", invocation: "a", issues: ())"#,
        "policy.error",
        Some("test.issues: Length must be at least 1"),
    ),
    (
        r#"(kind: "failure", invocation: "a", issues: (1,), extra: 2)"#,
        "policy.error",
        Some("test.extra: Unknown field"),
    ),
    (
        "1",
        "policy.error",
        Some("test: Expected dictionary. Got integer"),
    ),
    (
        r#"(id: "i", definition: (arity: 1, check: x => x, run: x => x), inputs: ("a",), origin: none)"#,
        "policy.invocation",
        None,
    ),
    (
        r#"(id: "i", definition: (arity: 1, check: x => x, run: 2), inputs: ("a",), origin: none)"#,
        "policy.invocation",
        Some("test.definition.run: Expected function. Got integer"),
    ),
    (
        r#"(binding: (name: "n", definition: (observe: x => x, on-error: x => x), at: "a", origin: none), target: "", origin: none)"#,
        "policy.claim",
        Some("test.target: Length must be at least 1"),
    ),
    (
        r#"(node: (id: "a", value: none, origin: none), references: (), data: (:))"#,
        "knowledge.local",
        None,
    ),
    (
        r#"(node: (id: "a", value: none, origin: none), references: (), data: 1)"#,
        "knowledge.local",
        Some("test.data: Expected dictionary. Got integer"),
    ),
    (
        r#"(note: (stage: "raw-to-local", observe: x => x))"#,
        "knowledge.registry",
        None,
    ),
    (
        r#"(note: (stage: "other", observe: x => x))"#,
        "knowledge.registry",
        Some(r#"test.note.stage: Unknown string `"other"`"#),
    ),
    (
        r#"(note: (stage: "raw-to-local", observe: 1))"#,
        "knowledge.registry",
        Some("test.note.observe: Expected function. Got integer"),
    ),
    (
        "1",
        "knowledge.registry",
        Some("test: Expected dictionary. Got integer"),
    ),
    (
        r#"(id: "r", target: "", value: none, origin: none)"#,
        "knowledge.reference",
        Some("test.target: Length must be at least 1"),
    ),
    (
        r#"(graph: (nodes: ("a",), edges: (:)), values: (nodes: (a: 1), edges: (:)))"#,
        "schema.state",
        None,
    ),
    (
        "(graph: (nodes: (1,), edges: (:)), values: (nodes: (:), edges: (:)))",
        "schema.state",
        Some("test.graph.nodes.0: Expected str. Got integer"),
    ),
    (
        r#"(graph: (nodes: (), edges: (:)), values: (nodes: ("": 1), edges: (:)))"#,
        "schema.state",
        Some("test.values.nodes..key: Length must be at least 1"),
    ),
    (
        "(nodes: none, edges: ())",
        "schema.fragment",
        Some("test.nodes: Expected array. Got none"),
    ),
    (
        "(nodes: (), edges: auto)",
        "schema.fragment",
        Some("test.edges: Expected array. Got none"),
    ),
    (
        r#"(id: "e", source: "a", target: none, value: none, origin: none)"#,
        "schema.edge-declaration",
        Some("test.target: Expected str. Got none"),
    ),
];

#[test]
fn boundary_schema_errors_are_stable() {
    let mut runtime = runtime();
    for (value, ty, expected) in BOUNDARY_CASES {
        let result = check(&mut runtime, value, ty);
        match expected {
            None => {
                result.unwrap_or_else(|error| panic!("{ty} {value}: {error}"));
            }
            Some(message) => {
                // Diagnostics are Debug-formatted, so quotes arrive escaped.
                let error = result.unwrap_err().replace("\\\"", "\"");
                let expected = format!("Schema validation failed on {message}");
                assert!(error.contains(&expected), "{ty} {value}: {error}");
            }
        }
    }
}
