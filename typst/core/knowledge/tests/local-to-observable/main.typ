#import "/core/lib.typ": eval, graph, knowledge
#import "rules.typ": observe, readers
#import "a.typ" as a
#import "b.typ" as b

#let locals = (a.raw, b.raw).map(readers.note.observe)
#let assembled = knowledge.assemble(locals)
#assert.eq(assembled.issues, ())

#let initial = assembled.state
#let updated = graph.assign(initial, nodes: (
  b: initial.values.nodes.b + (active: true),
))
#assert.eq(updated.graph, initial.graph)
#assert.eq(initial.values.nodes.b.active, false)
#assert.eq(graph.incoming(updated.graph, "b"), ("a/ref/1", "a/ref/2"))
#assert.eq(assembled.unclassified.len(), 1)

#eval.announce(<knowledge.test>, observe(
  updated,
  assembled.data,
  assembled.origins,
  assembled.unclassified,
))
