#import "declaration.typ": inclusion
#import "../content.typ": without-root
#import "../sections.typ": marker as section-marker

/// Relative level 1 is the node root; explicit level overrides its placement.
#let render-policy(context-level, relative-level, level: auto) = {
  assert(type(context-level) == int and context-level >= 0)
  assert(type(relative-level) == int and relative-level > 0)
  assert(level == auto or (type(level) == int and level > 0))
  let base = if level == auto { context-level } else { level - 1 }
  base + relative-level
}

#let default-render-policy = render-policy

#let heading-level(element) = {
  let level = element.at("level", default: auto)
  if level == auto { level = element.at("depth", default: none) }
  assert(
    type(level) == int and level > 0,
    message: "heading needs an explicit level",
  )
  level
}

// A walk returns (rendered content, last heading level).
// Only headings in the caller's flow affect subsequent automatic inclusions.
#let walk(body, level, embed, project-heading) = {
  let marker = inclusion(body)
  let fields = body.fields()

  if marker != none {
    let source-level = marker.at("source-level", default: none)
    let placement = if source-level == none { marker.level } else {
      project-heading(source-level)
    }
    let child = embed(
      str(body.target),
      context-level: level,
      level: placement,
      title: marker.title,
      heading-renderer: marker.heading-renderer,
    )
    (child, if source-level == none { level } else { placement })
  } else if body.func() == heading {
    let adjusted = project-heading(heading-level(body))
    let title = fields.remove("body")
    let anchor = fields.remove("label", default: none)
    let _ = fields.remove("depth", default: none)
    fields.insert("level", adjusted)
    let rendered = heading(title, ..fields)
    if anchor != none { rendered = [#rendered#anchor] }
    (rendered, adjusted)
  } else if repr(body.func()) == "sequence" {
    let parts = ()
    for child in body.children {
      let (rendered, next-level) = walk(child, level, embed, project-heading)
      parts.push(rendered)
      level = next-level
    }
    (parts.join(), level)
  } else if "styles" in fields and "child" in fields {
    let (rendered, next-level) = walk(
      fields.child,
      level,
      embed,
      project-heading,
    )
    ((body.func())(rendered, fields.styles), next-level)
  } else if (
    body.func() == block and type(fields.at("body", default: none)) == content
  ) {
    let (rendered, _) = walk(fields.body, level, embed, project-heading)
    let _ = fields.remove("body")
    (block(rendered, ..fields), level)
  } else {
    (body, level)
  }
}

/// Expand includes using embed(target, context-level:, level:, title:, heading-renderer:).
/// The callback resolves nodes and recursively renders them; this traversal
/// neither loads sources nor creates knowledge declarations.
#let expand(body, embed: none, level: 1, project-heading: value => value) = {
  assert(type(body) == content, message: "expanded body must be content")
  assert(
    type(embed) == function,
    message: "expansion requires an embed function",
  )
  assert(
    type(level) == int and level > 0,
    message: "expansion level must be positive",
  )

  assert(
    type(project-heading) == function,
    message: "heading projection must be a function",
  )
  let (rendered, _) = walk(body, level, embed, project-heading)
  // Unsupported containers and deferred includes must not become plain links.
  show ref: reference => {
    assert(
      inclusion(reference) == none,
      message: "include in unsupported container or deferred content",
    )
    reference
  }
  rendered
}

/// Resolve a per-instance title from the final node metadata.
#let instance-title(note, title) = {
  let chosen = if title == none { note.title } else if type(title) == function {
    let aliases = note
      .metadata
      .at("aliases", default: ())
      .map(name => (name, name))
      .to-dict()
    title(aliases)
  } else { title }
  assert(
    type(chosen) in (content, str),
    message: "include title must resolve to content or a string",
  )
  chosen
}

/// Bind final node records, source bodies, and an output-specific view.
/// Both indexes are keyed by node ID. The view receives (note, instance),
/// where instance holds title, body, level, open, and heading-renderer.
/// The view owns instance anchors, never knowledge labels or relationship lists.
/// Returns embed, document-body, and scope. All node content carries a lexical
/// reference renderer; copying it does not change its source identity.
#let renderer(
  nodes,
  bodies,
  view: none,
  render-policy: default-render-policy,
  render-reference: (source, reference) => reference,
) = {
  assert(type(nodes) == dictionary and type(bodies) == dictionary)
  assert(type(view) == function, message: "renderer requires an embedding view")
  assert(
    type(render-policy) == function,
    message: "renderer requires a render policy",
  )

  assert(
    type(render-reference) == function,
    message: "reference renderer must be a function",
  )

  // This closure reads only its arguments, even when show rules run at layout.
  let scope(source, body) = {
    show metadata: element => {
      assert(
        section-marker(element) == none,
        message: "note definition must be available before layout; deferred definitions are unsupported",
      )
      element
    }
    show ref: reference => {
      assert(
        inclusion(reference) == none,
        message: "unexpanded include in node content",
      )
      render-reference(source, reference)
    }
    body
  }
  let prepare(
    source,
    body,
    embed,
    level: 1,
    project-heading: value => value,
  ) = scope(
    source,
    expand(body, embed: embed, level: level, project-heading: project-heading),
  )

  let embed(
    target,
    context-level: 0,
    level: auto,
    title: none,
    open: true,
    heading-renderer: none,
    trail: (),
  ) = {
    assert(
      target in nodes and target in bodies,
      message: "missing embed target: " + repr(target),
    )
    assert(
      target not in trail,
      message: "include cycle on current expansion path",
    )
    assert(type(open) == bool, message: "embed open must be a boolean")
    assert(
      heading-renderer == none or type(heading-renderer) == function,
      message: "embed heading renderer must be a function or none",
    )
    let note = nodes.at(target)
    let chosen = instance-title(note, title)
    let source-root = heading-level(note.origin)
    let project-heading(source-level) = {
      let relative-level = source-level - source-root + 1
      let projected = render-policy(context-level, relative-level, level: level)
      assert(
        type(projected) == int and projected > 0,
        message: "render policy must return a positive heading level",
      )
      projected
    }
    let root-level = project-heading(source-root)
    let main = without-root(bodies.at(target), target)
    let body = prepare(
      target,
      main,
      embed.with(trail: trail + (target,)),
      level: root-level,
      project-heading: project-heading,
    )
    scope(target, view(note, (
      title: chosen,
      body: body,
      level: root-level,
      open: open,
      heading-renderer: heading-renderer,
    )))
  }

  // Keep the canonical root label only in the standalone document body.
  // Prepare main independently so copied views retain their source scope.
  let document-body(target) = {
    let source = bodies.at(target)
    let nested = embed.with(trail: (target,))
    let source-root = heading-level(nodes.at(target).origin)
    let project-heading(level) = level - source-root + 1
    (
      body: prepare(target, source, nested, project-heading: project-heading),
      main: prepare(
        target,
        without-root(source, target),
        nested,
        project-heading: project-heading,
      ),
    )
  }
  (embed: embed, document-body: document-body, scope: scope)
}
