#import "/core/lib.typ": eval, policy

#let relation = policy.definition(1, xs => panic("must not execute"))
#let context-policy = policy.definition(1, xs => panic("must not execute"))
#let merge = policy.definition(2, xs => panic("must not execute"))

#let result = policy.assemble(
  (
    policy.invocation("semantic", merge, inputs: ("related", "contextual")),
    policy.invocation("related", relation, inputs: ("initial",)),
    policy.invocation("contextual", context-policy, inputs: ("initial",)),
  ),
  inputs: ("initial",),
)

// Recover argument order from resolved port addresses.
#let observe(wiring) = (
  inputs: wiring.inputs,
  slots: wiring.slots,
  layers: wiring.layers,
  nodes: wiring.ids.map(id => (
    id: id,
    kind: if id in wiring.inputs { "input" } else { "call" },
    arguments: if id in wiring.inputs { () } else {
      wiring.calls.at(id).ports.map(slot => wiring.ids.at(slot))
    },
  )),
)

#assert.eq(result.issues, ())
#eval.announce(<policy.test>, observe(result.wiring))
