#import "rules.typ": *
#import "/core/lib.typ": eval, observation, policy, semantic
#import "/core/policy/verification.typ"

#let build(calls) = {
  let result = policy.assemble(calls, inputs: ("initial",))
  assert.eq(result.issues, ())
  policy.compile(result.wiring, contract)
}
#let enabled = observation.definition(
  read-enabled,
  on-error: error => (unavailable: error),
)
#let bindings = (
  observation.binding("early", enabled, at: "initial"),
  observation.binding("gated", enabled, at: "gated"),
  observation.binding(
    "final",
    observation.definition(
      state => {
        assert(read-enabled(state), message: "blocked observer must not run")
        read-enabled(state)
      },
      on-error: error => (unavailable: error),
    ),
    at: "final",
  ),
)

#let program = build(calls)
#let compiled = observation.compile(program, bindings)
#assert.eq(compiled.issues, ())
#let verified = verification.verify(
  program,
  bindings.map(binding => verification.claim(binding, "final")),
)
#assert.eq(verified.issues, ())
#assert(verified.evidence != none)

// Collection consumes the observation plan, not preservation evidence.
#let run(input) = {
  let execution = policy.evaluate(program, inputs: (input,))
  let table = observation.collect(compiled.plan, execution)
  (
    execution: execution,
    early: observation.query(table, "early"),
    gated: observation.query(table, "gated"),
    final: observation.query(table, "final"),
  )
}

#let invalid-phase = verification.verify(program, (
  verification.claim(
    observation.binding(
      "phase",
      observation.definition(read-phase, on-error: error => error),
      at: "initial",
    ),
    "final",
  ),
))
#let compensated = build((
  call(flip, "initial", "middle"),
  call(flip, "middle", "final"),
))
#let invalid-compensation = verification.verify(compensated, (
  verification.claim(
    observation.binding("enabled", enabled, at: "initial"),
    "final",
  ),
))
#let summary(result) = (
  has-evidence: result.evidence != none,
  issues: result.issues,
)

#eval.announce(<policy.verified-observation>, (
  domain-size: semantic.states(contract).len(),
  verification: summary(verified),
  proofs: verified.evidence.claims.map(claim => (
    observation: claim.binding.name,
    at: claim.binding.at,
    target: claim.target,
    steps: claim.steps.map(step => (
      source: step.source,
      invocation: step.invocation,
      port: step.port,
      admissible: step.evidence.admissible,
    )),
  )),
  success: run(initial),
  failure: run(update(initial, enabled: false)),
  invalid-phase: summary(invalid-phase),
  invalid-compensation: summary(invalid-compensation),
  restored: policy.evaluate(compensated, inputs: (initial,)).results.final.value
    == initial,
))
