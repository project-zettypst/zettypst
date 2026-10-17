// Importing configuration never reads the source manifest.
#import "@preview/zettyp:0.1.0": kickstart
#import "sources.typ"

// Enumerations are declared first, so notes and setup complete their members.
// Extend one with `+`, e.g. kickstart.register("lifecycle", frozen: "frozen").
#let lifecycle = kickstart.vocab.lifecycle
#let relation = kickstart.vocab.relation

// Pass only what differs from kickstart.defaults. Entrypoints take what they
// need from `zk`; notes import the names below.
#let zk = kickstart.notebook(
  manifest: sources.manifest,
  read: sources.note,
  vocabularies: (lifecycle: lifecycle, relation: relation),
)
#let (zettel, note, zk_metadata, include-note, replaces, evolves-from, ..) = zk
