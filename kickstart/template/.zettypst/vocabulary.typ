#import "@preview/zettyp-core:0.1.0": vocabulary

#let lifecycle = vocabulary.register(
  "lifecycle",
  active: "active",
  legacy: "legacy",
  archived: "archived",
)

#let colors = vocabulary.register(
  "relation",
  ref: <zk.ref>,
  replaces: <zk.replaces>,
  evolves-from: <zk.evolves-from>,
)
