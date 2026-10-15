#import "../../core/knowledge/lib.typ" as knowledge
#import "note.typ": definitions, observe-definitions
#import "relations.typ": neighbor-index, project-neighbors

/// Read through project-owned callbacks; package paths never address project files.
#let discover(manifest: none, read: none) = {
  let paths = manifest().at("paths", default: none)
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
  paths
    .map(path => {
      let records = definitions(read(path))
      assert(
        records.len() > 0,
        message: "source has no zettel declaration: " + path,
      )
      records.map(record => record + (path: path))
    })
    .flatten()
}

/// Strict graph entry: discovery can be shared with editor registration.
#let load(manifest: none, read: none, sources: none) = {
  if sources == none { sources = discover(manifest: manifest, read: read) }
  let notes = sources
    .map(source => (
      observe-definitions(source).map(record => record + (path: source.path))
    ))
    .flatten()
  knowledge.assemble(notes.map(note => note.local)) + (notes: notes)
}

#let project-notes(project, state, projections: (:)) = {
  let index = neighbor-index(state, projections)
  project.notes.map(note => {
    let id = note.local.node.id
    let data = project.data.at(id)
    let metadata = (
      data.metadata,
      state.values.nodes.at(id),
      project-neighbors(index, id),
    ).fold((:), (fields, part) => {
      for key in part.keys() {
        assert(key not in fields, message: "conflicting metadata field: " + key)
      }
      fields + part
    })
    (
      id: id,
      title: data.title,
      path: note.path,
      metadata: metadata,
      origin: project.origins.nodes.at(id),
    )
  })
}
