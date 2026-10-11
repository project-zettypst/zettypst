// Importing configuration never reads the source manifest.
#import "@preview/zettyp-core:0.1.0": (
  graph, kickstart, observation, policy, vocabulary,
)
#import "@preview/zettyp-lsp:0.1.0" as lsp
#import "sources.typ"
#import kickstart: display-value, evaluation-issues, without-root

// Vocabulary and metadata.
#let lifecycle = vocabulary.register(
  "lifecycle",
  active: "active",
  legacy: "legacy",
  archived: "archived",
)
#let colors = vocabulary.register(
  "relation",
  ref: kickstart.reference-color.value,
  replaces: <zk.replaces>,
  evolves-from: <zk.evolves-from>,
)
#let registry = vocabulary.registry(lifecycle: lifecycle, relation: colors)
#let text-field = graph.schema.typed("text", (str,))
#let metadata-schema = kickstart.metadata-schema(
  registry: registry,
  // Finite semantic values: booleans, registered enums, and their records.
  value: (lifecycle: lifecycle.active),
  // Open data is structurally checked; its value space need not be finite.
  data: (
    defaults: (aliases: (), abstract: "", tags: ()),
    schema: graph.schema.record("NoteData", (
      aliases: graph.schema.array(text-field),
      abstract: text-field,
      tags: graph.schema.array(text-field),
    )),
  ),
)
// Notes supply flat fields; the schema determines value/data ownership.
#let zk_metadata = kickstart.metadata.with(metadata-schema)
#let zettel = kickstart.zettel.with(metadata-schema, metadata: zk_metadata)
#let replaces = kickstart.colored-edge.with(registry, colors.replaces)
#let evolves-from = kickstart.colored-edge.with(registry, colors.evolves-from)

// Named neighbor projections are publication data, not policy assignments.
#let projections = (
  replaced-by: (color: colors.replaces, direction: "incoming"),
  evolved-into: (color: colors.evolves-from, direction: "incoming"),
)
#let project-notes = kickstart.project-notes.with(projections: projections)
#let load = kickstart.load.with(manifest: sources.manifest, read: sources.note)

// Native policy wiring; origins are bound separately for every project.
#let lifecycle-rule = kickstart.lifecycle-policy.with(
  metadata-schema,
  field: "lifecycle",
  archived: lifecycle.archived,
  legacy: lifecycle.legacy,
  replaces: colors.replaces,
  evolves-from: colors.evolves-from,
)
#let program(project) = policy.assemble(
  (
    policy.invocation("semantic", lifecycle-rule(project.origins), inputs: (
      "initial",
    )),
  ),
  inputs: ("initial",),
)
#let evaluate = kickstart.evaluate.with(
  registry: registry,
  program: program,
  inputs: project => (project.state,),
)

// Publication selects an explicitly declared observation.
#let observations = (
  observation.binding(
    "final",
    observation.definition(state => state, on-error: error => none),
    at: "semantic",
  ),
)
#let final-observation = kickstart.observe.with(
  bindings: observations,
  name: "final",
)

// Presentation callbacks receive the same projected note records.
#let hover(note) = (
  kind: "plaintext",
  value: display-value(note.title)
    + "\n@"
    + note.id
    + "\n\n"
    + note
      .metadata
      .keys()
      .sorted()
      .map(key => key + ": " + display-value(note.metadata.at(key)))
      .join("\n"),
)
#let route(note) = note.id + "/index.html"
#let card(note) = {
  note.body
  if note.backlinks.len() > 0 [
    Backlinks: #note.backlinks.map(it => ref(label(it.id))).join[, ]
  ]
}
#let announce-editor = kickstart.announce-editor.with(
  lsp,
  project-notes: project-notes,
  hover: hover,
)
#let announce-project = kickstart.announce-project.with(
  project-notes: project-notes,
)
#let publish = kickstart.publish.with(
  final-observation: final-observation,
  editor-output: announce-editor,
  project-output: announce-project,
)
#let export-html = kickstart.export-html.with(
  final-observation: final-observation,
  project-notes: project-notes,
  route: route,
  card: card,
)

// Persist this label in source; used contains the assembled string identities.
#let allocate-id(now, used) = {
  assert(type(now) == datetime and now.year() != none and now.hour() != none)
  assert(type(used) == array and used.all(id => type(id) == str))
  let base = now.display("[year][month][day]T[hour][minute][second]")
  let candidate = base
  let suffix = 0
  while candidate in used {
    suffix += 1
    candidate = base + "-" + str(suffix)
  }
  label(candidate)
}
