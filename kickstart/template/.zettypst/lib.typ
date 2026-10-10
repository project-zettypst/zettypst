#import "@preview/zettyp-core:0.1.0": (
  eval, graph, knowledge, observation, policy, semantic, vocabulary,
)
#import "@preview/zettyp-lsp:0.1.0" as lsp

// Public entrypoint; importing it never loads the source manifest.
#import "vocabulary.typ": colors, lifecycle
#import "content.typ": (
  declarations, display-value, elements, emit, references, without-root,
)
#import "note.typ": (
  allocate-id, note, observations, read-note, zettel, zk_metadata,
)
#import "relations.typ": (
  colored-edge, dependency-groups, derive-lifecycle, evolves-from, reachable,
  relation-issues, replaces, successors,
)
#import "project.typ": load, project-notes
#import "evaluation.typ": evaluate, evaluation-issues, final-observation
#import "editor.typ": announce-editor, navigation
#import "export.typ": announce-project
#import "html.typ": card, export-html, rendering, route

#let publish(project, program, execution, editor: true, export: true) = {
  assert(
    project.state != none,
    message: "resolve knowledge assembly issues before publication",
  )
  let final = final-observation(program, execution)
  if editor { announce-editor(project, execution, final) }
  if export { announce-project(project, final) }
}
