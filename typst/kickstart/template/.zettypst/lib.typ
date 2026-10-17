// Importing configuration never reads the source manifest.
#import "@preview/zettyp:0.1.0": kickstart
#import kickstart: display-value, evaluation-issues, without-root
#import "sources.typ"

// Enumerations are declared first, so notes and setup complete their members.
// Extend one with `+`, e.g., kickstart.register("lifecycle", frozen: "frozen").
#let lifecycle = kickstart.vocab.lifecycle
#let relation = kickstart.vocab.relation

// Pass only what differs from kickstart.defaults: metadata fields, projections,
// policies, hover, route, card and views. Unknown options fail with their path.
#let zk = kickstart.notebook(
  manifest: sources.manifest,
  read: sources.note,
  vocabularies: (lifecycle: lifecycle, relation: relation),
)
#let (
  colors,
  registry,
  metadata-schema,
  zk_metadata,
  zettel,
  note,
  include-note,
  replaces,
  evolves-from,
  projections,
  project-notes,
  discover,
  load,
  allocate-note-id,
  plan-note-registration,
  announce-note-registration,
  program,
  evaluate,
  observations,
  final-observation,
  route,
  announce-editor,
  announce-project,
  publish,
  export-pdf,
  export-html,
  ..,
) = zk
