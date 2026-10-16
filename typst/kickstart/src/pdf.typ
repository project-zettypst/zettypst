#import "transclusion/render.typ": renderer
#import "transclusion/pdf.typ" as pdf-consumer

/// Render the evaluated nodes into a single paged document. Sources and graph
/// identities remain canonical; every transcluded body has isolated labels.
#let export-pdf(
  project,
  result,
  final-observation: none,
  project-notes: none,
  view: pdf-consumer.view,
  consume: pdf-consumer.consume,
  render-reference: (source, reference) => reference,
) = {
  let state = final-observation(result.program, result.execution)
  assert(state != none, message: "semantic evaluation failed")
  let notes = project-notes(project, state)
    .map(note => (note.id, note))
    .to-dict()
  let bodies = project.notes.map(it => (it.local.node.id, it.body)).to-dict()
  let render = renderer(
    notes,
    bodies,
    view: view,
    consume: consume,
    render-reference: render-reference,
  )
  for id in notes.keys() { (render.document-body)(id).body }
}
