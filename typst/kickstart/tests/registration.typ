#import "../lib.typ" as ks
#import "../src/note.typ": definitions
#import "../../core/lib.typ": graph, vocabulary

#let colors = vocabulary.register(
  "relation",
  ref: ks.reference-color.value,
  ..("include": ks.include-color.value),
)
#let schema = ks.metadata-schema(
  registry: vocabulary.registry(relation: colors),
  data: (defaults: (:), schema: graph.schema.record("Empty", (:))),
)
#let zettel = ks.zettel.with(schema)
#let note = ks.note
#let source(body, path) = definitions(body).first() + (path: path)
#let topic = source(
  zettel[
    = Topic <topic>
    #note()[
      == First
      First body.
      #note()[
        === Child
        Child body.
      ]
    ]
    #note()[
      == Second
      Second body.
    ]
  ],
  "note/topic.typ",
)
#let occupied = source(
  zettel[
    = Already used elsewhere <topic-1>
  ],
  "note/occupied.typ",
)
#let sources = (topic, occupied)
#let plan = ks.plan-note-registration(sources)
#assert.eq(plan.entries.map(entry => entry.id), (
  <topic-2>,
  <topic-2-1>,
  <topic-3>,
))
#assert.eq(plan.entries.at(1).required.map(entry => entry.id), (
  <topic-2>,
  <topic-2-1>,
))
#assert.eq(plan.entries.last().required.map(entry => entry.id), (<topic-3>,))

// Strategies see the original definition and project-wide reserved identities.
#let custom(ctx) = {
  assert(ctx.definition.id == none)
  assert(ctx.path == "note/topic.typ")
  assert("topic-1" in ctx.used)
  label("custom-" + str(ctx.used.len()))
}
#assert.eq(
  ks
    .plan-note-registration(sources, allocate: custom)
    .entries
    .map(entry => entry.id),
  (<custom-2>, <custom-3>, <custom-4>),
)

// Existing identities are never passed to the allocator, even after moving.
#let registered = source(
  zettel[
    = Different parent <moved>
    #note(id: <topic-2>)[
      == Renamed
      Body.
      #note(id: <topic-2-1>)[
        === Child
        Body.
      ]
    ]
  ],
  "note/moved.typ",
)
#assert.eq(
  ks
    .plan-note-registration((registered,), allocate: ctx => panic(
      "must not allocate",
    ))
    .entries,
  (),
)
#let project = ks.load(sources: (registered,))
#assert.eq(project.issues, ())
#assert.eq(project.state.graph.nodes, ("moved", "topic-2", "topic-2-1"))
#assert(project
  .state
  .graph
  .edges
  .values()
  .any(edge => (
    edge.source == "moved" and edge.target == "topic-2"
  )))
#assert(
  not project
    .state
    .graph
    .edges
    .values()
    .any(edge => (
      edge.source == "moved" and edge.target == "topic-2-1"
    )),
)
Registration policy checks passed.
