#import "/core/lib.typ": graph, policy, semantic, vocabulary

#let phase = vocabulary.register("phase", before: "before", after: "after")
#let initial = (
  graph
    .assemble((
      graph.fragment(
        nodes: (
          graph.node("note", value: (enabled: true, phase: phase.before)),
        ),
      ),
    ))
    .state
)
#let contract = semantic.contract(
  initial,
  registry: vocabulary.registry(phase: phase),
)

#let read-enabled(state) = state.values.nodes.note.enabled
#let read-phase(state) = state.values.nodes.note.phase
#let update(state, ..fields) = graph.assign(state, nodes: (
  note: state.values.nodes.note + fields.named(),
))

#let advance = policy.definition(1, xs => update(
  xs.first(),
  phase: phase.after,
))
#let gate = policy.definition(
  1,
  xs => xs.first(),
  check: xs => if read-enabled(xs.first()) { () } else {
    ((kind: "disabled"),)
  },
)
#let identity = policy.definition(1, xs => xs.first())
#let flip = policy.definition(1, xs => update(
  xs.first(),
  enabled: not read-enabled(xs.first()),
))

#let call(definition, input, output) = policy.invocation(
  output,
  definition,
  inputs: (input,),
)
#let calls = (
  call(identity, "gated", "final"),
  call(gate, "derived", "gated"),
  call(advance, "initial", "derived"),
)
