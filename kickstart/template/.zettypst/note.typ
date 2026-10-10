#import "@preview/zettyp-core:0.1.0": knowledge
#import "vocabulary.typ": colors, lifecycle
#import "content.typ": declarations, elements, emit, references

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

#let zk_metadata(
  aliases: (),
  abstract: "",
  tags: (),
  relation: lifecycle.active,
) = {
  assert(type(aliases) == array and aliases.all(it => type(it) == str))
  assert(type(abstract) == str and type(tags) == array)
  assert(relation in lifecycle.values(), message: "unknown lifecycle state")
  (
    value: (relation: relation),
    data: (aliases: aliases, abstract: abstract, tags: tags),
  )
}

#let read-note(body, metadata: zk_metadata()) = {
  assert(type(body) == content, message: "note body must be content")
  let roots = elements(body).filter(it => {
    if it.func() != heading { return false }
    let fields = it.fields()
    let level = fields.at("level", default: auto)
    if level == auto { level = fields.at("depth", default: none) }
    level == 1
  })
  assert.eq(
    roots.len(),
    1,
    message: "note requires exactly one level-one root heading",
  )
  let root = roots.first()
  let identity = root.fields().at("label", default: none)
  assert(
    type(identity) == label,
    message: "note root heading requires a persistent label",
  )
  let id = str(identity)
  let outgoing = (
    references(body).map(origin => (origin: origin, color: colors.ref))
      + declarations(body, "zettyp.dependency", deep: true)
        .map(marker => (
          references(marker.body).map(origin => (
            origin: origin,
            color: marker.color,
          ))
        ))
        .flatten()
  )
  knowledge.local(
    id,
    value: metadata.value,
    data: metadata.data + (title: root.body),
    origin: root,
    references: outgoing
      .enumerate()
      .map(((index, item)) => knowledge.reference(
        str(id.len()) + ":" + id + "/ref/" + str(index),
        target: str(item.origin.target),
        value: (relation: item.color),
        origin: item.origin,
      )),
  )
}

#let note = knowledge.raw-to-local(read-note)

#let zettel(metadata: zk_metadata, body) = {
  assert(
    type(metadata) == function,
    message: "zettel metadata must be a configured function",
  )
  emit((
    protocol: "zettyp.note",
    version: 1,
    local: (note.observe)(body, metadata: metadata()),
    body: body,
  ))
}

#let observations(body) = declarations(body, "zettyp.note")
