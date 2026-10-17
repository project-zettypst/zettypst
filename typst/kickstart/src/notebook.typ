// Notebook setup: the template's wiring as one default table. A project
// passes only what differs (cf. a Neovim plugin's setup()):
// - data keys merge one known level (a field, a projection, a view);
// - behaviour keys replace the default (call kickstart.defaults.* to wrap it);
// - extension keys append to the default chain;
// - advanced keys receive (default, env) and may change between versions.
// Enumerations are declared by the project as ordinary variables first, so
// editors complete their members; setup receives the registered objects.
#import "../../core/lib.typ" as core
#import "../../lsp/lib.typ" as lsp
#import core: graph, observation, policy, vocabulary
#import "metadata.typ": metadata, metadata-schema
#import "note.typ": reference-color, zettel
#import "sections.typ": note
#import "relations.typ": colored-edge
#import "transclusion/declaration.typ": include-color, include-note
#import "project.typ": discover, load, project-notes
#import "registration.typ": (
  allocate-note-id, announce-note-registration, plan-note-registration,
)
#import "evaluation.typ": evaluate, observe
#import "editor.typ" as editor
#import "export.typ": announce-project, publish
#import "policies/lifecycle.typ": lifecycle-policy
#import "transclusion/policy.typ": transclusion-policy
#import "html.typ": export-html
#import "pdf.typ": export-pdf
#import "card.typ" as card-module

/// Register a vocabulary; add it to a default with `+`.
#let register = vocabulary.register
/// Default vocabularies. `ref` and `include` are protocol relations.
#let vocab = (
  lifecycle: register(
    "lifecycle",
    active: "active",
    legacy: "legacy",
    archived: "archived",
  ),
  relation: register(
    "relation",
    ref: reference-color.value,
    replaces: <zk.replaces>,
    evolves-from: <zk.evolves-from>,
    ..("include": include-color.value),
  ),
)
#let direction = (incoming: "incoming", outgoing: "outgoing")
#let builtin-relations = ("ref", "include")

#let text-field = graph.schema.typed("text", (str,))
#let defaults = (
  vocabularies: vocab,
  metadata: (
    value: (lifecycle: vocab.lifecycle.active),
    data: (
      defaults: (aliases: (), abstract: "", tags: ()),
      fields: (
        aliases: graph.schema.array(text-field),
        abstract: text-field,
        tags: graph.schema.array(text-field),
      ),
    ),
  ),
  projections: (
    replaced-by: (
      color: vocab.relation.replaces,
      direction: direction.incoming,
    ),
    evolved-into: (
      color: vocab.relation.evolves-from,
      direction: direction.incoming,
    ),
  ),
  views: (:),
  hover: editor.hover,
  route: note => note.id + "/index.html",
  card: card-module.card,
  allocate-note-id: allocate-note-id,
  pdf-reference: (source, it) => {
    if it.element != none and it.element.func() == heading {
      link(it.target)[[#it.element.body]]
    } else { it }
  },
  policies: (),
  editor-outputs: (),
  load: none,
  program: none,
  zk-metadata: none,
)

#let replace(value) = (zettyp-replace: value)
#let replaced(value) = (
  type(value) == dictionary and value.keys() == ("zettyp-replace",)
)

#let fail(path, message) = panic(
  "zettyp.notebook: `" + path.trim(".", at: start) + "` " + message,
)

// Merge one level: each key of `given` replaces the default's entry.
#let merge-level(path, base, given) = {
  if replaced(given) { return given.zettyp-replace }
  if type(given) != dictionary { fail(path, "must be a dictionary") }
  base + given
}

#let known(path, given, keys) = {
  if type(given) != dictionary { fail(path, "must be a dictionary") }
  for key in given.keys() {
    if key not in keys {
      fail(
        path + "." + key,
        "is not a setup option; expected one of " + keys.join(", "),
      )
    }
  }
}

#let merge-metadata(base, given) = {
  if replaced(given) { return given.zettyp-replace }
  known("metadata", given, ("value", "data"))
  let data = given.at("data", default: (:))
  if not replaced(data) { known("metadata.data", data, ("defaults", "fields")) }
  (
    value: merge-level("metadata.value", base.value, given.at(
      "value",
      default: (:),
    )),
    data: if replaced(data) { data.zettyp-replace } else {
      (
        defaults: merge-level(
          "metadata.data.defaults",
          base.data.defaults,
          data.at("defaults", default: (:)),
        ),
        fields: merge-level(
          "metadata.data.fields",
          base.data.fields,
          data.at("fields", default: (:)),
        ),
      )
    },
  )
}

#let member-of(members, value) = (
  vocabulary.enum-value(value)
    and value.variant in members
    and members.at(value.variant) == value
)

#let require-function(path, value) = if type(value) != function {
  fail(path, "must be a function")
}

// Fail at the boundary that broke the contract, not somewhere downstream.
#let returns(path, check, expected, f) = (..args) => {
  let result = f(..args)
  if not check(result) {
    fail(path, "must return " + expected + ", got " + repr(type(result)))
  }
  result
}

#let checked-hover = returns.with(
  "hover",
  it => (
    type(it) == dictionary
      and it.keys().sorted() == ("kind", "value")
      and type(it.kind) == str
      and type(it.value) == str
  ),
  "(kind: str, value: str)",
)
#let checked-route = returns.with(
  "route",
  it => (
    it == none
      or type(it) == str
        and it.ends-with(".html")
        and it.split("/").all(part => part not in ("", ".", ".."))
  ),
  "none or a relative .html path",
)

/// Build the notebook's functions. `manifest` and `read` resolve project
/// paths and so must be defined in the project.
#let notebook(manifest: none, read: none, ..options) = {
  assert.eq(
    options.pos(),
    (),
    message: "zettyp.notebook: options must be named",
  )
  require-function("manifest", manifest)
  require-function("read", read)
  let given = options.named()
  known("", given, defaults.keys())
  let opt(key) = given.at(key, default: defaults.at(key))

  // Enumerations: whole vocabularies, as declared by the project.
  let vocabularies = merge-level(
    "vocabularies",
    defaults.vocabularies,
    given.at("vocabularies", default: (:)),
  )
  for (name, members) in vocabularies {
    if (
      type(members) != dictionary
        or not members
          .pairs()
          .all(((variant, it)) => (
            vocabulary.enum-value(it)
              and it.type == name
              and it.variant == variant
          ))
    ) {
      fail(
        "vocabularies." + name,
        "must be registered with kickstart.register(\"" + name + "\", ...)",
      )
    }
  }
  let colors = vocabularies.relation
  for name in builtin-relations {
    if colors.at(name, default: none) != vocab.relation.at(name) {
      fail(
        "vocabularies.relation",
        "must keep the protocol relation `"
          + name
          + "`; extend kickstart.vocab.relation with +",
      )
    }
  }
  let registry = vocabulary.registry(..vocabularies)

  // Metadata: values must be members of the declared vocabularies.
  let meta = merge-metadata(defaults.metadata, given.at(
    "metadata",
    default: (:),
  ))
  for (field, value) in meta.value {
    if vocabulary.enum-value(value) {
      let members = vocabularies.at(value.type, default: none)
      if members == none or not member-of(members, value) {
        fail(
          "metadata.value." + field,
          "is not a member of the declared vocabulary " + repr(value.type),
        )
      }
    }
  }
  for key in meta.data.defaults.keys() + meta.data.fields.keys() {
    if key.starts-with("$") {
      fail("metadata.data." + key, "uses the reserved \"$\" prefix")
    }
  }
  let metadata-schema = metadata-schema(
    registry: registry,
    value: meta.value,
    data: (
      defaults: meta.data.defaults,
      schema: graph.schema.record("NoteData", meta.data.fields),
    ),
  )
  let zk_metadata = metadata.with(metadata-schema)
  if given.at("zk-metadata", default: none) != none {
    require-function("zk-metadata", given.zk-metadata)
    zk_metadata = (given.zk-metadata)(zk_metadata, (
      registry: registry,
      metadata-schema: metadata-schema,
    ))
  }

  // Relation projections publish neighbours by name.
  let projections = merge-level(
    "projections",
    defaults.projections,
    given.at("projections", default: (:)),
  )
  for (name, projection) in projections {
    if not member-of(colors, projection.at("color", default: none)) {
      fail(
        "projections." + name + ".color",
        "must be a member of vocabularies.relation",
      )
    }
    if projection.at("direction", default: none) not in direction.values() {
      fail(
        "projections." + name + ".direction",
        "must be kickstart.direction.incoming or .outgoing",
      )
    }
  }

  // Sources and loading.
  let default-load = load.with(manifest: manifest, read: read)
  let discover = discover.with(manifest: manifest, read: read)
  let load-impl = if given.at("load", default: none) == none {
    default-load
  } else {
    require-function("load", given.load)
    (given.load)(default-load, (registry: registry, discover: discover))
  }
  let project-notes = project-notes.with(projections: projections)

  // Policies: protocol stages, then the project's own, in order.
  let include-rule = transclusion-policy.with(
    registry,
    color: colors.at("include"),
  )
  let lifecycle-members = vocabularies.at("lifecycle", default: none)
  let lifecycle-rule = if lifecycle-members != none {
    for name in ("archived", "legacy") {
      if name not in lifecycle-members {
        fail("vocabularies.lifecycle", "must keep the member " + name)
      }
    }
    for name in ("replaces", "evolves-from") {
      if name not in colors {
        fail(
          "vocabularies.relation",
          "must keep " + name + " while vocabularies.lifecycle is declared",
        )
      }
    }
    lifecycle-policy.with(
      metadata-schema,
      field: "lifecycle",
      archived: lifecycle-members.archived,
      legacy: lifecycle-members.legacy,
      replaces: colors.replaces,
      evolves-from: colors.evolves-from,
    )
  }
  let extra = opt("policies")
  if type(extra) != array { fail("policies", "must be an array") }
  let names = (
    ("include-validity",)
      + if lifecycle-rule != none { ("lifecycle",) } else { () }
  )
  for (i, stage) in extra.enumerate() {
    if (
      type(stage) != dictionary
        or stage.keys().sorted() != ("name", "rule")
        or type(stage.rule) != function
    ) {
      fail(
        "policies." + str(i),
        "must be (name: str, rule: (project, env) => policy)",
      )
    }
    if stage.name in names {
      fail("policies." + str(i), "repeats the stage " + repr(stage.name))
    }
    names.push(stage.name)
  }
  let env = (
    registry: registry,
    vocabularies: vocabularies,
    metadata-schema: metadata-schema,
  )
  let default-program(project) = {
    let stages = (
      policy.invocation(
        "include-validity",
        include-rule(project.origins, unclassified: project.unclassified),
        inputs: ("initial",),
      ),
    )
    if lifecycle-rule != none {
      stages.push(policy.invocation(
        "lifecycle",
        lifecycle-rule(project.origins),
        inputs: (
          "include-validity",
        ),
      ))
    }
    let previous = if lifecycle-rule != none { "lifecycle" } else {
      "include-validity"
    }
    for stage in extra {
      stages.push(policy.invocation(
        stage.name,
        (stage.rule)(project, env),
        inputs: (
          previous,
        ),
      ))
      previous = stage.name
    }
    policy.assemble(stages, inputs: ("initial",))
  }
  let program = if given.at("program", default: none) == none {
    default-program
  } else { (given.program)(default-program, env) }
  let evaluate = evaluate.with(
    registry: registry,
    program: program,
    inputs: project => (project.state,),
  )
  // The final observation reads the last stage, whichever it is.
  let last = names.last()
  let observations = (
    observation.binding(
      "final",
      observation.definition(state => state, on-error: error => none),
      at: last,
    ),
  )
  let final-observation = observe.with(bindings: observations, name: "final")

  // Presentation.
  require-function("hover", opt("hover"))
  require-function("route", opt("route"))
  require-function("card", opt("card"))
  let hover = checked-hover(opt("hover"))
  let route = checked-route(opt("route"))
  let views = merge-level("views", defaults.views, opt("views"))
  for (name, view) in views { require-function("views." + name, view) }
  let card = opt("card")
  let outputs = opt("editor-outputs")
  if type(outputs) != array or not outputs.all(it => type(it) == function) {
    fail(
      "editor-outputs",
      "must be an array of (project, execution, final, env) => content",
    )
  }
  let announce-editor(project, execution, final) = {
    editor.announce-editor(
      lsp,
      project,
      execution,
      final,
      project-notes: project-notes,
      hover: hover,
    )
    for output in outputs { output(project, execution, final, env) }
  }
  let announce-project = announce-project.with(project-notes: project-notes)
  let allocate = opt("allocate-note-id")
  require-function("allocate-note-id", allocate)

  // Edge constructors for every project relation, by name.
  let edges = colors
    .pairs()
    .filter(((name, _)) => name not in builtin-relations)
    .map(((name, color)) => (name, colored-edge.with(registry, color)))
    .to-dict()

  (
    ..edges,
    lifecycle: lifecycle-members,
    colors: colors,
    registry: registry,
    metadata-schema: metadata-schema,
    zk_metadata: zk_metadata,
    zettel: zettel.with(metadata-schema, metadata: zk_metadata),
    note: note.with(metadata: zk_metadata),
    include-note: include-note,
    projections: projections,
    project-notes: project-notes,
    discover: discover,
    load: load-impl,
    allocate-note-id: allocate,
    plan-note-registration: plan-note-registration.with(allocate: allocate),
    announce-note-registration: announce-note-registration.with(lsp),
    program: program,
    evaluate: evaluate,
    observations: observations,
    final-observation: final-observation,
    route: route,
    announce-editor: announce-editor,
    announce-project: announce-project,
    publish: publish.with(
      final-observation: final-observation,
      editor-output: announce-editor,
      project-output: announce-project,
    ),
    export-pdf: export-pdf.with(
      final-observation: final-observation,
      project-notes: project-notes,
      render-reference: opt("pdf-reference"),
    ),
    // A route passed at the call site is checked like the configured one.
    export-html: (..args) => {
      let named = args.named()
      if "route" in named {
        require-function("route", named.route)
        named.route = checked-route(named.route)
      }
      export-html(
        ..args.pos(),
        final-observation: final-observation,
        project-notes: project-notes,
        route: route,
        card: card,
        node-fields: projections.keys(),
        views: views,
        documents: if "zettypst.documents" in sys.inputs {
          json(bytes(sys.inputs.at("zettypst.documents")))
        } else { auto },
        ..named,
      )
    },
  )
}
