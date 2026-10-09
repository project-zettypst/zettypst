/// Knowledge declarations reuse the graph's structural types.
#import "@preview/valkyrie:0.2.2" as z
#import "../graph-schema.typ" as graph
#import "../graph-schema.typ": checked

#let raw-to-local = graph.record("RawToLocalDefinition", (
  stage: z.string(assertions: (z.assert.one-of(("raw-to-local",)),)),
  observe: z.function(),
))
#let registry = (
  z.base-type(name: "ObserverRegistry", types: (dictionary,))
    + (
      handle-descendents: (self, value, ctx: z.z-ctx(), scope: ()) => {
        for (name, definition) in value {
          let _ = z.parse(
            definition,
            raw-to-local,
            ctx: ctx,
            scope: scope + (name,),
          )
        }
        value
      },
    )
)

#let no-positional = graph.array(graph.opaque, max: 0)

#let reference = graph.record("ReferenceDeclaration", (
  id: graph.id,
  target: graph.id,
  value: graph.opaque,
  origin: graph.opaque,
))
#let references = graph.array(reference)

#let local = graph.record("Local", (
  node: graph.node-declaration,
  references: graph.array(graph.edge-declaration),
  data: z.base-type(name: "open dictionary", types: (dictionary,)),
))
#let locals = graph.array(local)
