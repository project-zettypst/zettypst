/// The disjoint union of contract-valid GraphStates and invocation errors.
/// Left holds a state; right holds a failure or blocked error with its producer.
/// Sources and dependency wiring remain outside this carrier.
#import "../semantic.typ"
#import "../graph.typ"
#import "clone.typ"
#import "sum.typ"

#let success(contract, state) = sum.left(semantic.checked(contract, state))

#let failure(id, issues) = {
  graph.require-id(id)
  assert(
    type(issues) == array and issues.len() > 0,
    message: "failure requires a non-empty issue array",
  )
  sum.right((kind: "failure", invocation: id, issues: issues.dedup()))
}

#let blocked(id, dependencies) = {
  graph.require-id(id)
  assert(
    type(dependencies) == array and dependencies.len() > 0,
    message: "blocked requires unavailable input identities",
  )
  for source in dependencies {
    graph.require-id(source)
  }
  sum.right((
    kind: "blocked",
    invocation: id,
    dependencies: dependencies.dedup().sorted(),
  ))
}

/// Check carrier membership, not policy applicability.
/// Malformed sums, errors and contract violations panic.
#let checked(contract, result) = {
  let validate = sum.merge(
    state => success(contract, state),
    error => {
      assert(type(error) == dictionary, message: "expected an invocation error")
      let kind = error.at("kind", default: none)
      if kind == "failure" {
        assert(
          semantic.same-keys(error, ("kind", "invocation", "issues")),
          message: "invalid failure error",
        )
        return failure(error.invocation, error.issues)
      }
      assert(kind == "blocked", message: "unknown invocation error kind")
      assert(
        semantic.same-keys(error, ("kind", "invocation", "dependencies")),
        message: "invalid blocked error",
      )
      blocked(error.invocation, error.dependencies)
    },
  )
  validate(result)
}

/// Both branches return the caller's chosen observation space.
/// Observer receives a state; on-error receives the complete error payload.
/// No invocation identity, DAG access or diagnostic side effects are added.
#let lift-observer(contract, observer, on-error) = {
  let observe = sum.merge(observer, on-error)
  result => observe(checked(contract, result))
}

/// Collect checked policy inputs: all ordered states or all ordered errors.
/// Preserve repeated errors; blocked determines producer deduplication.
/// Empty inputs yield a successful empty tuple for nullary policies.
#let collect-inputs(inputs) = {
  assert(type(inputs) == array, message: "policy inputs must be an array")
  let append = sum.merge(
    states => sum.merge(
      state => sum.left(states + (state,)),
      error => sum.right((error,)),
    ),
    errors => sum.merge(
      _ => sum.right(errors),
      error => sum.right(errors + (error,)),
    ),
  )
  inputs.fold(sum.left(()), (collected, input) => (append(collected))(input))
}

/// Lift one definition at a fixed invocation identity and semantic contract.
/// Validate all inputs before collecting errors. Only all-left inputs reach
/// check; only an empty check result reaches run. Contract panics propagate.
#let lift(contract, id, definition) = {
  graph.require-id(id)
  let execute = sum.merge(
    states => {
      let issues = (definition.check)(states)
      assert(
        type(issues) == array,
        message: "policy check must return an issue array",
      )
      if issues.len() > 0 { return failure(id, issues) }
      success(contract, (definition.run)(states))
    },
    errors => blocked(id, errors.map(error => error.invocation)),
  )
  clone.operation(definition.arity, arguments => {
    let inputs = arguments.map(result => checked(contract, result))
    execute(collect-inputs(inputs))
  })
}
