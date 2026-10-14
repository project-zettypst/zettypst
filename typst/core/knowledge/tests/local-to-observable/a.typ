#import "/core/lib.typ": knowledge

#let raw = (
  id: "a",
  title: "Note A",
  origin: [Node A],
  references: (
    knowledge.reference("a/ref/1", target: "b", origin: [First reference 😀]),
    knowledge.reference("a/ref/2", target: "b", origin: [Second reference]),
    knowledge.reference(
      "a/ref/3",
      target: "anchor",
      origin: [Unclassified reference],
    ),
  ),
)
