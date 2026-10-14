use std::fs;
use std::path::Path;

use serde_json::{Value, json};
use typst::foundations::Dict;
use zettyp_eval::Runtime;

fn assert_origin(origin: &Value, path: &Path, expected: &str) {
    assert_eq!(
        Path::new(origin["source"].as_str().unwrap())
            .canonicalize()
            .unwrap(),
        path.canonicalize().unwrap(),
    );
    let text = fs::read_to_string(path).unwrap();
    let start = origin["range"]["start"].as_u64().unwrap() as usize;
    let end = origin["range"]["end"].as_u64().unwrap() as usize;
    assert_eq!(&text[start..end], expected);

    // Compute editor coordinates independently from the returned byte offsets.
    for (key, byte) in [("start", start), ("end", end)] {
        let prefix = &text[..byte];
        let line = prefix.bytes().filter(|&b| b == b'\n').count();
        let column = prefix.rsplit('\n').next().unwrap().encode_utf16().count();
        assert_eq!(
            origin["range-utf16"][key],
            json!({"line": line, "character": column}),
        );
    }
}

#[test]
fn local_observations_reach_external_consumers_with_source_locations() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let fixtures = root.join("core/knowledge/tests/local-to-observable");
    let mut runtime = Runtime::new(root).unwrap();
    let evaluation = runtime
        .evaluate(
            "core/knowledge/tests/local-to-observable/main.typ",
            Dict::new(),
        )
        .unwrap();
    let output = serde_json::to_value(evaluation.result.output.as_ref().unwrap()).unwrap();
    assert_eq!(output.as_object().unwrap().len(), 1);
    let announcements = output["knowledge.test"].as_array().unwrap();
    assert_eq!(announcements.len(), 1);
    let result = &announcements[0];

    assert_eq!(result["active"], true);
    assert_eq!(result["title"], "Open title B 😀");
    assert_origin(
        &result["definition"],
        &fixtures.join("b.typ"),
        "[Node B 😀]",
    );

    let references = result["references"].as_array().unwrap();
    assert_eq!(references.len(), 2);
    for (reference, id, text) in [
        (&references[0], "a/ref/1", "[First reference 😀]"),
        (&references[1], "a/ref/2", "Second reference"),
    ] {
        assert_eq!(reference["id"], id);
        assert_origin(&reference["origin"], &fixtures.join("a.typ"), text);
    }

    let unclassified = result["unclassified"].as_array().unwrap();
    assert_eq!(unclassified.len(), 1);
    assert_eq!(unclassified[0]["id"], "a/ref/3");
    assert_eq!(unclassified[0]["target"], "anchor");
    assert_origin(
        &unclassified[0]["origin"],
        &fixtures.join("a.typ"),
        "Unclassified reference",
    );
}
