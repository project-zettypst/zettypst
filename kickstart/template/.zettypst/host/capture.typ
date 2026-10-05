#import "common.typ": *
#import "@preview/zettyp-capture:0.1.0" as capture
#import "capture-config.typ" as settings
#let state = snapshot()
#let read-file(path, encoding: "utf8") = read("/" + host.path(path), encoding: encoding)
#let register-note(path) = {
  let before = read-file(manifest)
  let paths = toml.decode(before).paths
  (host.replace(manifest, before, manifest-text(paths + (path,))),)
}
#eval.announce(<host.plan>, capture.plan(host.request(),
  nodes: notes(state), settings: settings, read-file: read-file,
  allocate-id: value => str(project-lib.allocate-id(now(value), state.project.state.graph.nodes)),
  note-path: id => "note/" + id + ".typ",
  register-note: register-note,
  verification: intent => verification("capture-verify", intent, state.errors),
))
