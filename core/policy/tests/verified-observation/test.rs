use std::collections::BTreeSet;
use std::path::Path;

use serde_json::{Value, json};
use typst::foundations::Dict;
use zettyp_eval::Runtime;

fn report() -> Value {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let mut runtime = Runtime::new(root).unwrap();
    let evaluation = runtime
        .evaluate(
            "core/policy/tests/verified-observation/main.typ",
            Dict::new(),
        )
        .unwrap();
    let output = serde_json::to_value(evaluation.result.output.as_ref().unwrap()).unwrap();
    assert_eq!(output.as_object().unwrap().len(), 1);
    let announcements = output["policy.verified-observation"].as_array().unwrap();
    assert_eq!(announcements.len(), 1);
    announcements[0].clone()
}

#[test]
fn verified_early_observation_reaches_external_consumers() {
    let report = report();
    assert_eq!(report["domain-size"], 4);
    assert_eq!(
        report["verification"],
        json!({"has-evidence": true, "issues": []})
    );
    let success = &report["success"];
    for name in ["early", "gated", "final"] {
        assert_eq!(success[name]["value"], true);
        assert_eq!(success[name]["origin"], Value::Null);
    }
    assert_eq!(success["early"]["at"], "initial");
    assert_eq!(success["gated"]["at"], "gated");
    assert_eq!(success["final"]["at"], "final");
    let proofs = report["proofs"].as_array().unwrap();
    assert_eq!(proofs.len(), 3);
    for (proof, (name, at, steps)) in proofs.iter().zip([
        ("early", "initial", 3),
        ("gated", "gated", 1),
        ("final", "final", 0),
    ]) {
        assert_eq!(proof["observation"], name);
        assert_eq!(proof["at"], at);
        assert_eq!(proof["target"], "final");
        assert_eq!(proof["steps"].as_array().unwrap().len(), steps);
    }
    assert_eq!(
        proofs[0]["steps"],
        json!([
            {"source": "initial", "invocation": "derived", "port": 0, "admissible": 4},
            {"source": "derived", "invocation": "gated", "port": 0, "admissible": 2},
            {"source": "gated", "invocation": "final", "port": 0, "admissible": 4},
        ])
    );
    let output = &success["execution"]["results"]["final"];
    assert_eq!(output["side"], "left");
    assert_eq!(
        success["early"]["value"],
        output["value"]["values"]["nodes"]["note"]["enabled"]
    );
    assert_eq!(
        output["value"]["values"]["nodes"]["note"]["phase"],
        json!({
            "type": "phase", "variant": "after", "value": "after",
        })
    );
}

#[test]
fn downstream_failure_preserves_only_available_binding_locations() {
    let report = report();
    let failure = &report["failure"];
    assert_eq!(failure["early"]["value"], false);
    assert_eq!(failure["early"]["at"], "initial");
    assert_eq!(
        failure["gated"],
        json!({
            "at": "gated", "origin": null,
            "value": {"unavailable": {"kind": "failure", "invocation": "gated", "issues": [{"kind": "disabled"}]}},
        })
    );
    assert_eq!(
        failure["final"],
        json!({
            "at": "final", "origin": null,
            "value": {"unavailable": {"kind": "blocked", "invocation": "final", "dependencies": ["gated"]}},
        })
    );
    let results = &failure["execution"]["results"];
    assert_eq!(results["derived"]["side"], "left");
    assert_eq!(
        results["gated"],
        json!({"side": "right", "value": {"kind": "failure", "invocation": "gated", "issues": [{"kind": "disabled"}]}})
    );
    assert_eq!(
        results["final"],
        json!({"side": "right", "value": {"kind": "blocked", "invocation": "final", "dependencies": ["gated"]}})
    );
}

#[test]
fn local_changes_are_rejected_even_when_later_calls_restore_the_value() {
    let report = report();
    assert_eq!(report["restored"], true);
    for (case, observation, invocations) in [
        ("invalid-phase", "phase", BTreeSet::from(["derived"])),
        (
            "invalid-compensation",
            "enabled",
            BTreeSet::from(["middle", "final"]),
        ),
    ] {
        assert_eq!(report[case]["has-evidence"], false);
        let issues = report[case]["issues"].as_array().unwrap();
        assert!(!issues.is_empty());
        let actual: BTreeSet<_> = issues
            .iter()
            .map(|issue| {
                assert_eq!(issue["kind"], "observation-changed");
                assert_eq!(issue["observation"], observation);
                assert_eq!(issue["at"], "initial");
                assert_eq!(issue["target"], "final");
                assert_ne!(issue["before"], issue["after"]);
                assert_eq!(issue["inputs"].as_array().unwrap().len(), 1);
                assert_eq!(issue["port"], 0);
                issue["invocation"].as_str().unwrap()
            })
            .collect();
        assert_eq!(actual, invocations);
    }
}
