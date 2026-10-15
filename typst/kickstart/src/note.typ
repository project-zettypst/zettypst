#import "../../core/knowledge/lib.typ" as knowledge
#import "../../core/vocabulary.typ"
#import "metadata.typ": checked, metadata as make-metadata
#import "content.typ": declarations, elements, emit, references
#import "transclusion/declaration.typ": include-color, inclusion
#import "sections.typ": extract

// Ordinary references have a fixed protocol identity.
#let reference-color = vocabulary.register("relation", ref: <zk.ref>).ref

#let root-heading(body) = {
  let roots = elements(body).filter(it => {
    if it.func() != heading { return false }
    let level = it.at("level", default: auto)
    if level == auto { level = it.at("depth", default: none) }
    level == 1
  })
  assert.eq(
    roots.len(),
    1,
    message: "note requires exactly one level-one root heading",
  )
  let root = roots.first()
  assert(
    type(root.at("label", default: none)) == label,
    message: "note root heading requires a persistent label",
  )
  root
}

/// Parallel observers retain targets separately from original source content.
#let ordinary-references(body) = (
  references(body)
    .filter(reference => inclusion(reference) == none)
    .map(reference => (target: reference.target, origin: reference))
)

#let included-references(body) = (
  references(body)
    .filter(reference => inclusion(reference) != none)
    .map(reference => (
      target: reference.target,
      origin: inclusion(reference).origin,
    ))
)

#let outgoing(body) = {
  let observers = (
    (observe: ordinary-references, color: reference-color),
    (observe: included-references, color: include-color),
  )
  let colored(occurrences, color) = occurrences.map(occurrence => (
    occurrence + (color: color)
  ))
  let base = observers
    .map(observer => colored((observer.observe)(body), observer.color))
    .flatten()
  let dependencies = declarations(body, "zettyp.dependency", deep: true)
    .map(marker => observers
      .map(observer => colored((observer.observe)(marker.body), marker.color))
      .flatten())
    .flatten()
  base + dependencies
}

/// Observe one node's own body, independently of its definition syntax.
/// Keep the original heading as provenance even when display content changes.
#let read-node(schema, body, id: none, root: none, metadata: none) = {
  assert(type(body) == content, message: "note body must be content")
  assert(type(id) == label, message: "node requires a persistent label")
  assert(
    type(root) == content and root.func() == heading,
    message: "node requires an original root heading",
  )
  let metadata = if metadata == none { make-metadata(schema) } else {
    checked(schema, metadata)
  }
  let id = str(id)
  let links = outgoing(body)
  assert(
    links.all(item => (
      vocabulary.enum-value(item.color)
        and vocabulary.contains(schema.registry, item.color)
    )),
    message: "note references require registered relation colors",
  )
  knowledge.local(
    id,
    value: metadata.value,
    // Protocol data and user metadata occupy separate namespaces.
    data: (title: root.body, metadata: metadata.data),
    origin: root,
    references: links
      .enumerate()
      .map(((index, item)) => knowledge.reference(
        str(id.len()) + ":" + id + "/ref/" + str(index),
        target: str(item.target),
        value: (relation: item.color),
        origin: item.origin,
      )),
  )
}

/// File notes declare identity on their level-one root heading.
#let read-note(schema, body, metadata: none) = {
  let root = root-heading(body)
  read-node(schema, body, id: root.label, root: root, metadata: metadata)
}

/// Discover definitions without requiring every node to have a persistent ID.
#let zettel(schema, metadata: () => none, body) = {
  assert(
    type(metadata) == function,
    message: "zettel metadata must be a configured function",
  )
  let original = root-heading(body)
  let extracted = extract(body, root: original, id: original.label)
  emit((
    protocol: "zettyp.source",
    version: 1,
    schema: schema,
    definition: (
      id: original.label,
      root: original,
      metadata: metadata,
      source-body: body,
      body: extracted.body,
      children: extracted.nodes,
    ),
  ))
}

#let definitions(body) = declarations(body, "zettyp.source")

/// Flatten definitions only at the observation boundary; no temporary IDs.
#let observe-definitions(source) = {
  let walk(definition) = {
    assert(
      definition.id != none,
      message: "note requires registration: persist an id before graph evaluation",
    )
    (
      (
        (
          local: read-node(
            source.schema,
            definition.body,
            id: definition.id,
            root: definition.root,
            metadata: (definition.metadata)(),
          ),
          body: definition.body,
        ),
      )
        + definition.children.map(walk).flatten()
    )
  }
  walk(source.definition)
}

#let observations(body) = definitions(body).map(observe-definitions).flatten()
