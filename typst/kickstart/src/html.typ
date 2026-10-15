#import "content.typ": display-value
#import "card.typ": card, embedded, frontmatter
#import "transclusion/render.typ": renderer
#import "transclusion/declaration.typ": include-color
#import "relations.typ": ancestor-roots, neighbor-index

#import "../../site/lib.typ" as site

#let export-html(
  project,
  result,
  final-observation: none,
  project-notes: none,
  route: none,
  card: none,
  view: embedded,
) = {
  let state = final-observation(result.program, result.execution)
  assert(state != none, message: "semantic evaluation failed")
  // Context is rooted in the complete include graph, before route filtering.
  let includes = neighbor-index(state, (
    parents: (color: include-color, direction: "incoming"),
  ))
  let bodies = project.notes.map(it => (it.local.node.id, it.body)).to-dict()
  let notes = (:)
  for note in project-notes(project, state) {
    let path = route(note)
    assert(
      path == none
        or path.ends-with(".html")
          and path.split("/").all(part => part not in ("", ".", "..")),
      message: "route must be a relative .html path or none: " + note.id,
    )
    notes.insert(note.id, note + (route: path))
  }
  // Endpoints of every relation colour, deduplicated, published and non-self.
  let neighbours(id, from, to) = state
    .graph
    .edges
    .values()
    .filter(edge => edge.at(from) == id and edge.at(to) != id)
    .map(edge => edge.at(to))
    .dedup()
    .map(it => notes.at(it))
    .filter(it => it.route != none)

  // The same embedding function serves source includes and relation views.
  // Unpublished nodes may be linked, but their bodies must not leak through
  // a published node's transclusions.
  let published-view(note, instance) = {
    assert(
      note.route != none,
      message: "cannot embed unpublished node: " + note.id,
    )
    view(note, instance)
  }
  // Reference ownership is an explicit input, not a layout-time state.
  let render-reference(source, reference) = {
    let target = notes.at(str(reference.target), default: none)
    if target == none { return reference }
    let body = if reference.supplement in (auto, none, []) {
      target.title
    } else {
      reference.supplement
    }
    if target.route == none { return site.unpublished(body) }
    site.node-link(source, target.id, link(reference.target, body))
  }
  let render = renderer(
    notes,
    bodies,
    view: published-view,
    render-reference: render-reference,
  )
  let published = notes.values().filter(it => it.route != none)
  let documents = (:)
  for note in published {
    let content = (render.document-body)(note.id)
    let full = (
      note
        + content
        + (
          "context": ancestor-roots(includes, note.id, "parents").map(
            id => notes.at(id),
          ),
          backlinks: neighbours(note.id, "target", "source"),
          links: neighbours(note.id, "source", "target"),
        )
    )
    documents.insert(
      note.route,
      documents.at(note.route, default: ()) + (full,),
    )
  }

  for (path, group) in documents {
    document(
      path,
      title: display-value(group.first().title),
      group
        .map(note => (render.scope)(
          note.id,
          site.node(note.id, card(note, embed: render.embed)),
        ))
        .join(),
    )
  }
  // Titles for search and stack chrome; the page HTML carries everything else.
  site.publish-index(published.map(note => (
    id: note.id,
    route: note.route,
    title: display-value(note.title),
  )))
}
