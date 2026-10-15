#import "note.typ": reference-color
#import "transclusion/declaration.typ": include-color
#import "../../core/vocabulary.typ"
#import "content.typ": display-value
#import "evaluation.typ": evaluation-issues

/// Register (color, resolver) pairs using complete vocabulary identities.
/// A resolver receives (edge, origin) and returns (target, origin).
#let register-navigation(..entries) = {
  assert(
    entries.named().len() == 0,
    message: "navigation registrations must be positional",
  )
  let rules = ()
  for (color, resolve) in entries.pos() {
    assert(
      vocabulary.enum-value(color),
      message: "navigation color must be a vocabulary member",
    )
    assert(
      type(resolve) == function,
      message: "navigation resolver must be a function",
    )
    assert(
      not rules.any(rule => rule.color == color),
      message: "duplicate navigation color",
    )
    rules.push((color: color, resolve: resolve))
  }
  rules
}

/// Ordinary references and includes both address the edge's target node.
#let edge-target(edge, origin) = (target: edge.target, origin: origin)

#let navigation-rules = register-navigation(
  (reference-color, edge-target),
  (include-color, edge-target),
)

// Navigation belongs to the initial graph, independently of policy success.
#let navigation(project, rules: navigation-rules) = {
  let calls = ()
  for (id, edge) in project.state.graph.edges {
    let color = project.state.values.edges.at(id).relation
    let rule = rules.find(rule => rule.color == color)
    if rule == none { continue }
    let call = (rule.resolve)(edge, project.origins.edges.at(id))
    assert(
      call.target in project.state.graph.nodes,
      message: "navigation target must identify a node",
    )
    calls.push(call)
  }
  let incoming = (:)
  for call in calls {
    let occurrences = incoming.at(call.target, default: ())
    occurrences.push(call.origin)
    incoming.insert(call.target, occurrences)
  }
  let nodes = (:)
  for id in project.state.graph.nodes {
    nodes.insert(id, (
      id: id,
      origin: project.origins.nodes.at(id),
      definition: project.origins.nodes.at(id),
      references: incoming.at(id, default: ()),
    ))
  }
  // A reference inside a heading takes priority over the heading's range.
  (
    calls.map(call => (
      nodes.at(call.target) + (origin: call.origin)
    ))
      + project.state.graph.nodes.map(id => nodes.at(id))
  )
}

#let announce-editor(
  lsp,
  project,
  execution,
  final,
  project-notes: none,
  hover: none,
  navigation-rules: navigation-rules,
) = {
  let targets = navigation(project, rules: navigation-rules)
  for target in targets {
    lsp.announce(lsp.effect-kinds.definition, lsp.definition(
      applies-to: target.origin,
      target: target.definition,
    ))
    lsp.announce(lsp.effect-kinds.references, lsp.references(
      applies-to: target.origin,
      targets: target.references,
      declarations: (target.definition,),
    ))
  }
  if final != none {
    let notes = project-notes(project, final)
      .map(note => (note.id, note))
      .to-dict()
    for target in targets {
      let note = notes.at(target.id)
      lsp.announce(lsp.effect-kinds.hover, lsp.hover(
        applies-to: target.origin,
        contents: hover(note),
      ))
    }
  }
  // Clear every observed source document, including imported reference content.
  let origins = (
    project.origins.nodes.values()
      + project.origins.edges.values()
      + project.unclassified.map(it => it.origin)
  )
  for origin in origins {
    lsp.announce(
      lsp.effect-kinds.publish-diagnostics,
      lsp.publish-diagnostics(document: origin),
    )
  }
  for issue in evaluation-issues(execution) {
    for origin in issue.origins {
      lsp.announce(
        lsp.effect-kinds.publish-diagnostics,
        lsp.publish-diagnostics(
          document: origin,
          diagnostics: (
            lsp.diagnostic(
              origin: origin,
              message: issue.message,
              code: issue.code,
              severity: lsp.severity.error,
              source: "zettypst",
            ),
          ),
        ),
      )
    }
  }
}

#let hover(note) = (
  kind: "plaintext",
  value: display-value(note.title)
    + "\n@"
    + note.id
    + "\n\n"
    + note
      .metadata
      .keys()
      .sorted()
      .map(key => key + ": " + display-value(note.metadata.at(key)))
      .join("\n"),
)
