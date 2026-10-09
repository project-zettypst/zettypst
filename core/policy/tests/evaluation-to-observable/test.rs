use std::path::Path;

use serde_json::{Value, json};
use typst::foundations::Dict;
use zettyp_eval::Runtime;

fn evaluate_fixture() -> Value {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let mut runtime = Runtime::new(root).unwrap();
    let evaluation = runtime
        .evaluate(
            "core/policy/tests/evaluation-to-observable/main.typ",
            Dict::new(),
        )
        .unwrap();
    let output = serde_json::to_value(evaluation.result.output.as_ref().unwrap()).unwrap();
    assert_eq!(output.as_object().unwrap().len(), 1);
    let announcements = output["policy.evaluation"].as_array().unwrap();
    assert_eq!(announcements.len(), 1);
    announcements[0].clone()
}

#[test]
fn successful_evaluation_matches_direct_composition() {
    let report = evaluate_fixture();
    let success = &report["success"];
    assert_eq!(success, &report["success-reordered"]);
    assert_eq!(success["results"]["final"]["value"], report["direct"]);

    let results = success["results"].as_object().unwrap();
    assert_eq!(results.len(), 5);
    for (id, expected) in [
        ("initial", 2),
        ("left", 3),
        ("right", 4),
        ("merged", -1),
        ("final", -10),
    ] {
        let result = &results[id];
        assert_eq!(result["side"], "left", "product {id}");
        assert_eq!(
            result["value"]["values"]["nodes"]["note"]["value"],
            expected
        );
        assert_eq!(result["value"]["values"]["nodes"]["note"]["type"], "number");
        assert_eq!(result["value"]["graph"], report["initial"]["graph"]);
        assert_eq!(result["value"]["values"]["edges"], json!({}));
    }
    assert_eq!(results["initial"]["value"], report["initial"]);
}

#[test]
fn failure_blocks_dependents_but_preserves_independent_results() {
    let report = evaluate_fixture();
    let failure = &report["failure"];
    assert_eq!(failure, &report["failure-reordered"]);
    let results = failure["results"].as_object().unwrap();
    assert_eq!(results.len(), 5);
    assert_eq!(results["initial"], report["success"]["results"]["initial"]);
    assert_eq!(results["right"], report["success"]["results"]["right"]);
    assert_eq!(
        results["left"],
        json!({
            "side": "right",
            "value": {
                "kind": "failure", "invocation": "left",
                "issues": [{"kind": "rejected", "message": "left is unavailable"}],
            },
        })
    );
    assert_eq!(
        results["merged"],
        json!({
            "side": "right",
            "value": {"kind": "blocked", "invocation": "merged", "dependencies": ["left"]},
        })
    );
    assert_eq!(
        results["final"],
        json!({
            "side": "right",
            "value": {"kind": "blocked", "invocation": "final", "dependencies": ["merged"]},
        })
    );
}
