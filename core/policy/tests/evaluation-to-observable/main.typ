#import "/core/lib.typ": eval, graph, policy, semantic, vocabulary

// The arithmetic fixture uses a finite semantic vocabulary, not raw integers.
#let numbers = vocabulary.register(
  "number",
  initial: 2,
  left: 3,
  right: 4,
  merged: -1,
  final: -10,
)
#let number(value) = numbers.values().find(member => member.value == value)
#let initial = (
  graph
    .assemble((
      graph.fragment(nodes: (graph.node("note", value: numbers.initial),)),
    ))
    .state
)
#let contract = semantic.contract(
  initial,
  registry: vocabulary.registry(number: numbers),
)

#let left(state) = graph.assign(state, nodes: (
  note: number(state.values.nodes.note.value + 1),
))
#let right(state) = graph.assign(state, nodes: (
  note: number(state.values.nodes.note.value * 2),
))
#let merge(a, b) = graph.assign(a, nodes: (
  note: number(a.values.nodes.note.value - b.values.nodes.note.value),
))
#let tail(state) = graph.assign(state, nodes: (
  note: number(state.values.nodes.note.value * 10),
))

#let right-policy = policy.definition(1, xs => right(xs.first()))
#let calls(branch, join, end) = (
  policy.invocation("final", end, inputs: ("merged",)),
  policy.invocation("merged", join, inputs: ("left", "right")),
  policy.invocation("left", branch, inputs: ("initial",)),
  policy.invocation("right", right-policy, inputs: ("initial",)),
)
#let run(declarations) = {
  let built = policy.assemble(declarations, inputs: ("initial",))
  assert.eq(built.issues, ())
  policy.evaluate(policy.compile(built.wiring, contract), inputs: (initial,))
}

#let successful = calls(
  policy.definition(1, xs => left(xs.first())),
  policy.definition(2, xs => merge(xs.at(0), xs.at(1))),
  policy.definition(1, xs => tail(xs.first())),
)

// These panics prove failed runs and blocked checks/runs are not called.
#let failing = calls(
  policy.definition(
    1,
    xs => panic("failed policy ran"),
    check: xs => ((kind: "rejected", message: "left is unavailable"),),
  ),
  policy.definition(
    2,
    xs => panic("blocked merge ran"),
    check: xs => panic("blocked merge checked"),
  ),
  policy.definition(
    1,
    xs => panic("blocked tail ran"),
    check: xs => panic("blocked tail checked"),
  ),
)

#eval.announce(<policy.evaluation>, (
  initial: initial,
  direct: tail(merge(left(initial), right(initial))),
  success: run(successful),
  success-reordered: run(successful.rev()),
  failure: run(failing),
  failure-reordered: run(failing.rev()),
))
