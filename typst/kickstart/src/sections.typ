#import "content.typ": declarations, elements, emit
#import "transclusion/declaration.typ": include-content

/// Define a node in place. Discovery owns extraction; this call only records
/// the already-evaluated body and its configured metadata function.
#let note(body, id: none, metadata: () => none) = {
  assert(id == none or type(id) == label, message: "note id must be a label")
  assert(type(body) == content, message: "note requires content")
  assert(
    type(metadata) == function,
    message: "note metadata must be a function",
  )
  emit((
    protocol: "zettyp.section",
    version: 1,
    id: id,
    metadata: metadata,
    body: body,
  ))
}

#let marker(element) = {
  if element.func() != emit { return none }
  let value = element.value
  if (
    type(value) != dictionary
      or value.at("protocol", default: none) != "zettyp.section"
  ) {
    return none
  }
  assert.eq(value.version, 1, message: "unsupported section protocol version")
  value
}

#let heading-level(element) = {
  let level = element.at("level", default: auto)
  if level == auto { level = element.at("depth", default: none) }
  assert(
    type(level) == int and level > 0,
    message: "heading needs an explicit level",
  )
  level
}

#let section-root(body) = {
  let content = elements(body).filter(element => {
    if repr(element.func()) in ("space", "parbreak", "linebreak") {
      return false
    }
    if element.func() == text and element.text.trim() == "" { return false }
    true
  })
  assert(
    content.len() > 0 and content.first().func() == heading,
    message: "note body must start with its root heading",
  )
  let root = content.first()
  assert(
    content
      .slice(1)
      .filter(it => it.func() == heading)
      .all(it => heading-level(it) > heading-level(root)),
    message: "headings inside note must be deeper than its root",
  )
  root
}

/// Extract definitions before observing references. Styles remain around their
/// original content; only styles inside a definition enter its stored body.
/// Records retain the original heading, independently of its canonical label.
#let extract(body, root: none, id: none) = {
  let declaration = marker(body)
  if declaration != none {
    assert(
      declaration.id != none,
      message: "note requires registration: persist an id before graph evaluation",
    )
    let original = section-root(declaration.body)
    assert(
      root == none or heading-level(original) > heading-level(root),
      message: "nested note heading must be deeper than its enclosing node",
    )
    let anchor = original.at("label", default: none)
    assert(
      anchor == none or anchor == declaration.id,
      message: "note root label conflicts with its declared id",
    )
    let child = extract(declaration.body, root: original, id: declaration.id)
    (
      body: include-content(
        declaration.id,
        original,
        source-level: heading-level(original),
      ),
      nodes: (
        (
          id: declaration.id,
          root: original,
          metadata: declaration.metadata,
          body: child.body,
        ),
      )
        + child.nodes,
    )
  } else if root != none and body == root {
    (
      body: if body.at("label", default: none) == id { body } else {
        [#body#id]
      },
      nodes: (),
    )
  } else {
    let fields = body.fields()
    let parts = if "children" in fields { fields.children } else if (
      "styles" in fields and "child" in fields
    ) {
      (fields.child,)
    } else if (
      body.func() == block and type(fields.at("body", default: none)) == content
    ) {
      (fields.body,)
    } else { none }
    if parts == none {
      assert(
        declarations(body, "zettyp.section", deep: true).len() == 0,
        message: "note definition in unsupported container",
      )
      return (body: body, nodes: ())
    }
    let results = parts.map(part => extract(part, root: root, id: id))
    let content = results.map(it => it.body).join()
    let rebuilt = if "styles" in fields and "child" in fields {
      (body.func())(content, fields.styles)
    } else if body.func() == block {
      let _ = fields.remove("body")
      block(content, ..fields)
    } else { content }
    (body: rebuilt, nodes: results.map(it => it.nodes).flatten())
  }
}
