#import "../lib.typ" as project-lib
#import "@preview/zettyp-core:0.1.0": eval
#import "@preview/zettyp-host:0.1.0" as host

#let manifest = ".zettypst/source.toml"
#let snapshot() = {
  let project = project-lib.load()
  assert.eq(project.issues, (), message: "knowledge assembly failed")
  let result = project-lib.evaluate(project)
  let final = project-lib.final-observation(result.flow, result.execution)
  let errors = result.execution.results.values()
    .filter(it => it.status == "failure")
    .map(it => it.issues).flatten()
    .map(it => repr((code: str(it.code), message: it.message, occurrences: it.occurrences)))
  (project: project, final: final, errors: errors)
}
#let check-errors(state, baseline) = {
  // Multiset comparison preserves repeated diagnostics without source-offset drift.
  let remaining = baseline
  for error in state.errors {
    let index = remaining.position(it => it == error)
    assert(index != none, message: "migration introduced an error: " + error)
    let _ = remaining.remove(index)
  }
}
#let announce-node(note) = eval.announce(
  <host.node>,
  host.node(note.id, project-lib.display-value(note.title), note.origin, note.metadata),
)
#let notes(state) = {
  assert.eq(state.final.status, "available", message: "semantic evaluation failed")
  project-lib.project-notes(state.project, state.final.value)
}
// Rewrites only the paths array, preserving comments and other settings.
#let manifest-text(before, paths) = {
  let assignment = regex("(?m)^paths\\s*=\\s*\\[[^\\]]*\\]")
  assert.eq(before.matches(assignment).len(), 1, message: "manifest needs exactly one paths array")
  before.replace(assignment, "paths = [" + paths.map(json.encode).join(", ") + "]")
}
#let verification(entry, intent, baseline) = (
  entry: ".zettypst/host/" + entry + ".typ",
  inputs: ("host.request": json.encode(intent + (baseline: baseline))),
)
#let now(value) = {
  assert(type(value) == dictionary)
  datetime(year: value.year, month: value.month, day: value.day,
    hour: value.hour, minute: value.minute, second: value.second)
}
