#import "@preview/zettyp-core:0.1.0": graph
#import "vocabulary.typ": colors, lifecycle
#import "content.typ": emit

#let colored-edge(color, body) = {
  assert(color in (colors.replaces, colors.evolves-from))
  emit((protocol: "zettyp.dependency", version: 1, color: color, body: body))
  body
}

#let replaces = colored-edge.with(colors.replaces)

#let evolves-from = colored-edge.with(colors.evolves-from)

// Group only the dependency view; original edge occurrences remain intact.
#let dependency-groups(state) = {
  let ids = state
    .graph
    .edges
    .keys()
    .filter(id => (
      state.values.edges.at(id).relation
        in (colors.replaces, colors.evolves-from)
    ))
  ids
    .map(id => state.graph.edges.at(id))
    .dedup()
    .map(edge => (
      edge + (occurrences: ids.filter(id => state.graph.edges.at(id) == edge))
    ))
}

#let reachable(edges, start, target) = {
  let pending = (start,)
  let visited = ()
  while pending.len() > 0 {
    let id = pending.pop()
    if id == target { return true }
    if id in visited { continue }
    visited.push(id)
    pending += edges.filter(edge => edge.source == id).map(edge => edge.target)
  }
  false
}

#let relation-issues(state, origins) = {
  let groups = dependency-groups(state)
  groups
    .map(group => {
      let kinds = group
        .occurrences
        .map(id => state.values.edges.at(id).relation)
        .dedup()
      let endpoints = repr(group.source) + " -> " + repr(group.target)
      let problems = ()
      if kinds.len() > 1 {
        problems.push((
          code: <zk.relation.color-conflict>,
          message: "conflicting dependency colors: " + endpoints,
        ))
      }
      // Only edges on a cycle are diagnosed, not edges entering or leaving it.
      if reachable(groups, group.target, group.source) {
        problems.push((
          code: <zk.relation.cycle>,
          message: "dependency graph contains a cycle through " + endpoints,
        ))
      }
      problems.map(issue => (
        issue
          + (
            occurrences: group.occurrences,
            origins: group.occurrences.map(id => origins.edges.at(id)),
          )
      ))
    })
    .flatten()
}

#let successors(state, id) = {
  let incoming = graph.incoming(state.graph, id)
  let sources(color) = incoming
    .filter(edge => state.values.edges.at(edge).relation == color)
    .map(edge => state.graph.edges.at(edge).source)
    .dedup()
  (
    replaced-by: sources(colors.replaces),
    evolved-into: sources(colors.evolves-from),
  )
}

#let derive-lifecycle(state) = graph.assign(state, nodes: (
  state
    .values
    .nodes
    .pairs()
    .fold((:), (values, pair) => {
      let (id, value) = pair
      let next = successors(state, id)
      let relation = if next.replaced-by.len() > 0 {
        lifecycle.archived
      } else if next.evolved-into.len() > 0 { lifecycle.legacy } else {
        value.relation
      }
      values.insert(id, value + (relation: relation))
      values
    })
))
