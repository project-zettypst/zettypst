/// Structural policy types; composition and contract checks remain separate.
#import "@preview/valkyrie:0.2.2" as z
#import "../graph-schema.typ" as graph
#import "../graph-schema.typ": checked

#let arity = z.integer(min: 0)
#let index = arity
#let callable = z.function()
#let arguments = graph.array(graph.opaque)
#let identities = graph.array(graph.id)
#let tag(values) = z.string(assertions: (z.assert.one-of(values),))

#let operation = graph.record("Operation", (arity: arity, apply: callable))
#let operations = graph.array(operation)
#let morphism = graph.record("Morphism", (arity: arity, outputs: operations))
#let definition = graph.record("PolicyDefinition", (
  arity: arity,
  check: callable,
  run: callable,
))
#let invocation = graph.record("Invocation", (
  id: graph.id,
  definition: definition,
  inputs: identities,
  origin: graph.opaque,
))
#let invocations = graph.array(invocation)

#let sum = graph.record("Sum", (
  side: tag(("left", "right")),
  value: graph.opaque,
))
#let sums = graph.array(sum)
#let issues = arguments
#let failure = graph.record("Failure", (
  kind: tag(("failure",)),
  invocation: graph.id,
  issues: graph.array(graph.opaque, min: 1),
))
#let blocked = graph.record("Blocked", (
  kind: tag(("blocked",)),
  invocation: graph.id,
  dependencies: graph.array(graph.id, min: 1),
))
#let error-kind = tag(("failure", "blocked"))
#let error = (
  z.base-type(name: "InvocationError", types: (dictionary,))
    + (
      handle-descendents: (self, value, ctx: z.z-ctx(), scope: ()) => {
        let kind = z.parse(
          value.at("kind", default: none),
          error-kind,
          ctx: ctx,
          scope: scope + ("kind",),
        )
        let _ = z.parse(
          value,
          if kind == "failure" { failure } else { blocked },
          ctx: ctx,
          scope: scope,
        )
        value
      },
    )
)

#let observer = graph.record("ObservationDefinition", (
  observe: callable,
  on-error: callable,
))
#let binding = graph.record("ObservationBinding", (
  name: graph.id,
  definition: observer,
  at: graph.id,
  origin: graph.opaque,
))
#let bindings = graph.array(binding)
#let claim = graph.record("PreservationClaim", (
  binding: binding,
  target: graph.id,
  origin: graph.opaque,
))
#let claims = graph.array(claim)
