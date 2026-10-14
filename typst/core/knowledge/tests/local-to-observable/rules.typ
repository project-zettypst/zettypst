#import "/core/lib.typ": eval, knowledge

#let readers = knowledge.register(
  note: knowledge.raw-to-local(raw => knowledge.local(
    raw.id,
    value: (active: false),
    data: (title: raw.title),
    origin: raw.origin,
    references: raw.references,
  )),
)

// Observe the selected state together with its fixed data and source origins.
#let observe(state, data, origins, unclassified) = (
  active: state.values.nodes.b.active,
  title: data.b.title,
  definition: eval.inspect(origins.nodes.b),
  references: state
    .graph
    .edges
    .keys()
    .map(id => (
      id: id,
      origin: eval.inspect(origins.edges.at(id)),
    )),
  unclassified: unclassified.map(item => (
    id: item.id,
    target: item.target,
    origin: eval.inspect(item.origin),
  )),
)
