#import "content.typ": display-value
#import "card.typ": card, embedded, frontmatter
#import "transclusion/render.typ": renderer
#import "transclusion/html.typ" as html-consumer
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
  consume: html-consumer.consume,
  documents: auto,
  render-unclassified: (source, reference) => reference,
) = {
  assert(
    documents == auto
      or (
        type(documents) == array and documents.all(path => type(path) == str)
      ),
    message: "documents must be auto or an array of publication routes",
  )
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
  // Stable canonical anchors also work when the target is compiled in another batch.
  let anchor(id) = {
    let hex = ""
    for byte in bytes(id) {
      hex += (if byte < 16 { "0" } else { "" }) + str(byte, base: 16)
    }
    "zk-node-" + hex
  }
  let destination(path, target) = {
    let from = path.split("/").slice(0, -1)
    let to = target.route.split("/")
    while from.len() > 0 and to.len() > 0 and from.first() == to.first() {
      from = from.slice(1)
      to = to.slice(1)
    }
    (from.map(_ => "..") + to).join("/") + "#" + anchor(target.id)
  }
  // Document routing and lexical reference ownership are explicit inputs.
  let render-reference(path, source, reference) = {
    let target = notes.at(str(reference.target), default: none)
    if target == none { return render-unclassified(source, reference) }
    let body = if reference.supplement in (auto, none, []) {
      target.title
    } else {
      reference.supplement
    }
    if target.route == none { return site.unpublished(body) }
    site.node-link(source, target.id, link(destination(path, target), body))
  }
  let published = notes.values().filter(it => it.route != none)
  let selected = documents
  let documents = (:)
  for note in published {
    if selected != auto and note.route not in selected { continue }
    let full = (
      note
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
    let render = renderer(
      notes,
      bodies,
      view: published-view,
      consume: consume,
      render-reference: render-reference.with(path),
    )
    document(
      path,
      title: display-value(group.first().title),
      {
        // Each HTML document has its own numbering baseline. This also prevents
        // copied backmatter in earlier bundle documents from delaying convergence.
        for key in site.counted { counter(key).update(0) }
        group
          .map(note => (render.scope)(
            note.id,
            site.node(note.id, {
              html.span(id: anchor(note.id))
              card(
                note + (render.document-body)(note.id),
                embed: render.embed.with(source: note.id),
              )
            }),
          ))
          .join()
      },
    )
  }
  // Titles for search and stack chrome; the page HTML carries everything else.
  site.publish-index(published.map(note => (
    id: note.id,
    route: note.route,
    title: display-value(note.title),
  )))
}
