#import "../../core/graph.typ"
#import "../../core/vocabulary.typ"
#import "content.typ": emit

#let colored-edge(registry, color, body) = {
  assert(
    vocabulary.enum-value(color) and vocabulary.contains(registry, color),
    message: "relation color must be a registered enum",
  )
  emit((protocol: "zettyp.dependency", version: 1, color: color, body: body))
  body
}

/// Query one color and direction; parallel occurrences yield one neighbor.
#let neighbors(state, id, color: none, direction: none) = {
  assert(vocabulary.enum-value(color), message: "expected a relation color")
  assert(
    direction in ("incoming", "outgoing"),
    message: "unknown edge direction",
  )
  let incoming = direction == "incoming"
  let edges = if incoming { graph.incoming } else { graph.outgoing }
  let endpoint = if incoming { "source" } else { "target" }
  edges(state.graph, id)
    .filter(edge => state.values.edges.at(edge).relation == color)
    .map(edge => state.graph.edges.at(edge).at(endpoint))
    .dedup()
}

#let project-neighbors(state, id, projections) = (
  projections
    .pairs()
    .map(((name, query)) => (name, neighbors(state, id, ..query)))
    .to-dict()
)

/// Group the selected relation view without changing original occurrences.
#let dependency-groups(state, colors) = {
  let ids = state
    .graph
    .edges
    .keys()
    .filter(id => state.values.edges.at(id).relation in colors)
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
