use std::collections::BTreeSet;
use std::path::Path;

use serde_json::{Value, json};
use typst::foundations::Dict;
use zettyp_eval::Runtime;

#[test]
fn assembled_policy_dependencies_reach_external_consumers() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let mut runtime = Runtime::new(root).unwrap();
    let evaluation = runtime
        .evaluate(
            "core/policy/tests/assembly-to-observable/main.typ",
            Dict::new(),
        )
        .unwrap();
    let output = serde_json::to_value(evaluation.result.output.as_ref().unwrap()).unwrap();
    assert_eq!(output.as_object().unwrap().len(), 1);
    let announcements = output["policy.test"].as_array().unwrap();
    assert_eq!(announcements.len(), 1);
    let result = &announcements[0];

    assert_eq!(result["inputs"], json!(["initial"]));
    assert_eq!(result["slots"], json!({"initial": 0, "contextual": 1, "related": 2, "semantic": 3}));
    let layers = result["layers"].as_array().unwrap();
    assert_eq!(layers.len(), 2);
    let branches = layers[0].as_array().unwrap();
    assert_eq!(branches.len(), 2);
    assert_eq!(
        branches
            .iter()
            .map(|id| id.as_str().unwrap())
            .collect::<BTreeSet<_>>(),
        BTreeSet::from(["related", "contextual"]),
    );
    assert_eq!(layers[1], json!(["semantic"]));

    let nodes = result["nodes"].as_array().unwrap();
    assert_eq!(nodes.len(), 4);
    for (id, kind, arguments) in [
        ("initial", "input", json!([])),
        ("related", "call", json!(["initial"])),
        ("contextual", "call", json!(["initial"])),
        ("semantic", "call", json!(["related", "contextual"])),
    ] {
        let matches: Vec<&Value> = nodes.iter().filter(|node| node["id"] == id).collect();
        assert_eq!(matches.len(), 1, "product {id}");
        assert_eq!(matches[0]["kind"], kind);
        assert_eq!(matches[0]["arguments"], arguments);
    }
}
