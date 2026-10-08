/// Pure policy definitions and identified invocation declarations.
#import "clone.typ"
#import "../graph.typ"

/// A policy consumes one ordered array of states and produces one state.
/// Check consumes the same array and returns an array of issues.
/// Neither function is executed during declaration or structural assembly.
/// The shared semantic contract is supplied when the definition is lifted.
#let definition(arity, run, check: arguments => ()) = {
  clone.require-arity(arity)
  assert(type(run) == function, message: "policy run must be a function")
  assert(type(check) == function, message: "policy check must be a function")
  (arity: arity, check: check, run: run)
}

/// Declare one invocation; its identity also addresses its single result.
/// Definitions may be reused, but invocation identities must be unique.
/// Input order and repetitions specify ports, not scheduling dependencies.
/// Assembly resolves references and checks port counts and acyclicity.
#let invocation(id, definition, inputs: (), origin: none) = {
  graph.require-id(id)
  assert(
    type(definition) == dictionary
      and type(definition.at("arity", default: none)) == int
      and definition.arity >= 0
      and type(definition.at("check", default: none)) == function
      and type(definition.at("run", default: none)) == function,
    message: "invocation requires a policy definition",
  )
  assert(type(inputs) == array, message: "invocation inputs must be an array")
  for source in inputs {
    graph.require-id(source)
  }
  (id: id, definition: definition, inputs: inputs, origin: origin)
}
