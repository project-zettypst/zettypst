#import "@preview/zettyp-core:0.1.0": observation, policy, semantic, vocabulary
#import "vocabulary.typ": colors, lifecycle
#import "relations.typ": derive-lifecycle, relation-issues

// Each evaluation starts from the original locals, never a derived snapshot.
#let evaluate(project) = {
  assert(
    project.state != none,
    message: "resolve knowledge assembly issues before evaluation",
  )
  let contract = semantic.contract(
    project.state,
    registry: vocabulary.registry(lifecycle: lifecycle, relation: colors),
  )
  let lifecycle-rule = policy.definition(
    1,
    states => derive-lifecycle(states.first()),
    check: states => relation-issues(states.first(), project.origins),
  )
  let assembled = policy.assemble(
    (policy.invocation("semantic", lifecycle-rule, inputs: ("initial",)),),
    inputs: ("initial",),
  )
  assert.eq(assembled.issues, ())
  let program = policy.compile(assembled.wiring, contract)
  (
    program: program,
    execution: policy.evaluate(program, inputs: (project.state,)),
  )
}

// A local snapshot needs no preservation proof. Errors are published separately.
#let final-observation(program, execution) = {
  let observer = observation.definition(state => state, on-error: error => none)
  let compiled = observation.compile(program, (
    observation.binding("final", observer, at: "semantic"),
  ))
  assert.eq(compiled.issues, ())
  observation
    .query(observation.collect(compiled.plan, execution), "final")
    .value
}

#let evaluation-issues(execution) = (
  execution
    .results
    .values()
    .filter(it => it.side == "right" and it.value.kind == "failure")
    .map(it => it.value.issues)
    .flatten()
)
