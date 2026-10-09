/// Structural graph types. Validation preserves inputs without applying defaults.
#import "@preview/valkyrie:0.2.2" as z

#let checked(value, schema, scope: ("argument",)) = {
  let _ = z.parse(value, schema, scope: scope)
  value
}

/// Fixed records require every declared field and reject unknown fields.
#let record(name, fields) = (
  z.base-type(name: name, types: (dictionary,))
    + (
      handle-descendents: (self, value, ctx: z.z-ctx(), scope: ()) => {
        for key in fields.keys() {
          if key not in value {
            return (self.fail-validation)(
              self,
              value,
              ctx: ctx,
              scope: scope + (key,),
              message: "Missing required field",
            )
          }
        }
        for (key, item) in value {
          if key not in fields {
            return (self.fail-validation)(
              self,
              value,
              ctx: ctx,
              scope: scope + (key,),
              message: "Unknown field",
            )
          }
          let _ = z.parse(item, fields.at(key), ctx: ctx, scope: scope + (key,))
        }
        value
      },
    )
)

#let id = z.string(min: 1)
#let opaque = z.any()
/// Validate every element without rebuilding the array. Only length assertions
/// run on the array itself, so discarding parsed elements preserves their checks.
#let array(item, min: none, max: none) = (
  z.array(item, min: min, max: max, default: none)
    + (
      handle-descendents: (self, value, ctx: z.z-ctx(), scope: ()) => {
        for (index, entry) in value.enumerate() {
          let _ = (self.descendents-schema.validate)(
            self.descendents-schema,
            entry,
            ctx: ctx,
            scope: scope + (str(index),),
          )
        }
        value
      },
    )
)

/// Dynamic dictionary keys are graph identities; values follow the given type.
#let indexed(item) = (
  z.base-type(name: "identity-indexed dictionary", types: (dictionary,))
    + (
      handle-descendents: (self, value, ctx: z.z-ctx(), scope: ()) => {
        for (key, entry) in value {
          let _ = z.parse(key, id, ctx: ctx, scope: scope + (key, "key"))
          let _ = z.parse(entry, item, ctx: ctx, scope: scope + (key,))
        }
        value
      },
    )
)

#let node-declaration = record("NodeDeclaration", (
  id: id,
  value: opaque,
  origin: opaque,
))
#let edge-declaration = record("EdgeDeclaration", (
  id: id,
  source: id,
  target: id,
  value: opaque,
  origin: opaque,
))

#let fragment = record("GraphFragment", (
  nodes: array(node-declaration),
  edges: array(edge-declaration),
))
#let fragments = array(fragment)
#let endpoints = record("Endpoints", (source: id, target: id))
#let graph = record("Graph", (nodes: array(id), edges: indexed(endpoints)))
#let assignments = record("Assignments", (
  nodes: indexed(opaque),
  edges: indexed(opaque),
))
#let state = record("GraphState", (graph: graph, values: assignments))
