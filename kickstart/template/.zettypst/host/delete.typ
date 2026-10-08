#import "common.typ": *
#let req = host.request()
#assert(
  req.keys().all(key => key in ("id", "force", "now")),
  message: "unknown delete request field",
)
#assert(type(req.id) == str)
#let force = req.at("force", default: false)
#assert(type(force) == bool)
#let state = snapshot()
#let matches = state.project.notes.filter(note => note.local.node.id == req.id)
#assert.eq(matches.len(), 1, message: "node does not exist")
#let note = matches.first()
#assert.eq(
  state.project.notes.filter(it => it.path == note.path).len(),
  1,
  message: "delete requires a source containing exactly one node",
)
#let incoming = (
  state
    .project
    .state
    .graph
    .edges
    .values()
    .filter(
      edge => edge.target == req.id and edge.source != req.id,
    )
)
#assert(
  force or incoming.len() == 0,
  message: "node has incoming edges; force is required",
)
#let before = read("/" + manifest)
#let paths = toml(bytes(before)).paths
#eval.announce(<host.plan>, host.plan(
  (
    host.delete(note.path, read("/" + note.path)),
    host.replace(manifest, before, manifest-text(before, paths.filter(path => (
      path != note.path
    )))),
  ),
  verification("delete-verify", (id: req.id, path: note.path), state.errors),
))
