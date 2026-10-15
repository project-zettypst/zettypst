#import "../../../core/policy/lib.typ" as policy
#import "../../../core/vocabulary.typ"
#import "../relations.typ": dependency-groups, reachable

/// Check the include subgraph globally, independently of publication roots.
#let issues(state, origins, color, unclassified) = {
  // Assembly excludes unknown targets from the graph. They must not silently
  // disappear from validation: an include always denotes a knowledge node.
  let missing = unclassified
    .filter(edge => edge.value.relation == color)
    .map(edge => (
      code: <zk.transclusion.missing-target>,
      message: "missing include target: " + repr(edge.target),
      occurrences: (edge.id,),
      origins: (edge.origin,),
    ))
  let groups = dependency-groups(state, (color,))
  let cycles = groups
    .filter(group => reachable(groups, group.target, group.source))
    .map(group => (
      code: <zk.transclusion.cycle>,
      message: "include graph contains a cycle through "
        + repr(group.source)
        + " -> "
        + repr(group.target),
      occurrences: group.occurrences,
      origins: group.occurrences.map(id => origins.edges.at(id)),
    ))
  // Only edges on a cycle are diagnosed. Parallel occurrences retain all
  // source locations; ordinary references never participate in this check.
  missing + cycles
}

/// Bind assembly provenance and unresolved references to a validating identity
/// policy. Pass the same project's origins and unclassified declarations.
/// Final semantic consumers must depend on this invocation's success.
#let transclusion-policy(
  registry,
  origins,
  color: none,
  unclassified: (),
) = {
  assert(
    vocabulary.enum-value(color) and vocabulary.contains(registry, color),
    message: "include relation must be a registered color",
  )
  policy.definition(
    1,
    states => states.first(),
    check: states => issues(states.first(), origins, color, unclassified),
  )
}
