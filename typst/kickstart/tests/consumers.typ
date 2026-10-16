#import "../lib.typ": *
#import "../../core/lib.typ": graph, vocabulary
#let colors = vocabulary.register("relation", ref: reference-color.value, ..(
  "include": include-color.value,
))
#let registry = vocabulary.registry(relation: colors)
#let schema = metadata-schema(registry: registry, data: (
  defaults: (:),
  schema: graph.schema.record("Empty", (:)),
))
#let zettel = zettel.with(schema)
#let a = zettel[
  = A <a>
  == Local <local-section>
  See @local-section and #link(<local-section>)[local link].
  $ x = 1 $ <equation-a>
  See @equation-a.
  #figure([Diagram], caption: [Caption]) <figure-a>
  See @figure-a.
  Text#footnote[Footnote body]<footnote-a>, again#footnote(<footnote-a>).
]
#let b = zettel[
  = B <b>
  #include-note[@a]
  #include-note[@a]
]
#let project = load(
  manifest: () => (paths: ("a", "b")),
  read: path => if path == "a" { a } else { b },
)
#let nodes = (
  project
    .notes
    .map(it => (
      it.local.node.id,
      (
        id: it.local.node.id,
        title: it.local.data.title,
        metadata: (:),
        origin: it.local.node.origin,
      ),
    ))
    .to-dict()
)
#let bodies = project.notes.map(it => (it.local.node.id, it.body)).to-dict()
#let render = transclusion-renderer(
  nodes,
  bodies,
  view: pdf.view,
  consume: pdf.consume,
)
#set heading(numbering: "1.")
#set math.equation(numbering: "(1)")
#(render.document-body)("a").body
#(render.document-body)("b").body

#context {
  let local = query(heading).filter(it => it.body == [Local])
  assert.eq(local.len(), 3)
  assert.eq(local.map(it => it.label).dedup().len(), 3)
  let equations = query(math.equation).filter(it => (
    it.at("label", default: none) != none
  ))
  assert.eq(equations.len(), 3)
  assert.eq(equations.map(it => it.label).dedup().len(), 3)
  let figures = query(figure)
  assert.eq(figures.len(), 3)
  assert.eq(figures.map(it => it.label).dedup().len(), 3)
}
