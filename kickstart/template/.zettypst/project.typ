#import "@preview/zettyp-core:0.1.0": knowledge
#import "note.typ": observations
#import "relations.typ": successors

// Loading is explicit: importing this configuration never reads the manifest.
#let load(manifest: "/.zettypst/source.toml") = {
  let paths = toml(manifest).at("paths", default: none)
  assert(
    type(paths) == array and paths.all(path => type(path) == str),
    message: "source manifest requires an array of paths",
  )
  assert.eq(paths.dedup().len(), paths.len(), message: "duplicate source path")
  assert(
    paths.all(path => (
      not path.contains("\\")
        and path.split("/").all(part => part not in ("", ".", ".."))
    )),
    message: "source paths must be project-relative with forward slashes",
  )
  let notes = paths
    .map(path => {
      let records = observations(include ("/" + path))
      assert(
        records.len() > 0,
        message: "source has no zettel declaration: " + path,
      )
      records.map(record => record + (path: path))
    })
    .flatten()
  knowledge.assemble(notes.map(note => note.local)) + (notes: notes)
}

#let project-notes(project, state) = project.notes.map(note => {
  let id = note.local.node.id
  let data = project.data.at(id)
  let title = data.remove("title")
  (
    id: id,
    title: title,
    path: note.path,
    metadata: data + state.values.nodes.at(id) + successors(state, id),
    origin: project.origins.nodes.at(id),
  )
})
