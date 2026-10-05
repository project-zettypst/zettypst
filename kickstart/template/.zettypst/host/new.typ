#import "common.typ": *
#let req = host.request()
#assert(req.keys().all(key => key in ("title", "now")), message: "unknown new request field")
#assert(type(req.title) == str and req.title.trim() != "", message: "title is required")
#let state = snapshot()
#let id = str(project-lib.allocate-id(now(req.now), state.project.state.graph.nodes))
#let path = "note/" + id + ".typ"
#let paths = toml("/" + manifest).paths
#assert(path not in paths, message: "new path is already registered")
// Plain text is inserted as a string expression, never as executable markup.
#let content = "#import \"../.zettypst/lib.typ\": *\n#show: zettel\n\n= #text(" + json.encode(req.title) + ") <" + id + ">\n"
#eval.announce(<host.plan>, host.plan(
  (
    host.create(path, content),
    host.replace(manifest, read("/" + manifest), manifest-text(paths + (path,))),
  ),
  verification("new-verify", (id: id, path: path, title: req.title), state.errors),
))
