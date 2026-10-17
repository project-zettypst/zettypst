/// Site integration contracts and generic HTML rendering support.

// Layout unsupported by HTML is rendered as SVG; other targets are untouched.

#let frame(body) = context if target() == "html" { html.frame(body) } else {
  body
}

/// Wrap a layout package's constructor, e.g. `framed(fletcher.diagram)`.
/// Package diagrams are opaque `context`, so they must be declared.
#let framed(constructor) = (..args) => frame(constructor(..args))

// Typst's MathML omits these. A frame inside MathML cannot be typeset by
// MathJax, so an equation containing one is framed as a whole instead.
// (`html` exists only when HTML export is enabled, so frames match by name.)
#let paged-only = (
  math.cancel,
  math.underline,
  underline,
  box,
  block,
  stack,
  grid,
  place,
  scale,
  move,
  rotate,
)
#let needs-frame(value) = if type(value) == array {
  value.any(needs-frame)
} else if type(value) == content {
  (
    value.func() in paged-only
      or repr(value.func()) == "frame"
      or value.fields().values().any(needs-frame)
  )
} else { false }

// Show rules also reach content laid out inside frames, where the target is
// paged again; each rule therefore checks the target where it applies.
#let on-html(rule) = it => context if target() == "html" { rule(it) } else {
  it
}

#let html-rules(body) = {
  // Frames share the page's type size (Forester's 12pt).
  set text(size: 12pt)
  // Typst reserves h1 for the document title: native heading level n
  // exports as HTML level n + 1. Reject rather than silently degrading it.
  show heading: on-html(it => {
    let level = it.level + 1
    assert(
      level <= 6,
      message: "HTML heading level "
        + str(level)
        + " exceeds h6; flatten the document or its transclusions",
    )
    it
  })
  show math.equation: on-html(it => {
    if not needs-frame(it.body) { return it }
    // Text decoration needs text layout even when embedded in an equation.
    show underline: line => box(line)
    // Inline frames end at the baseline; descenders overflow, so they align.
    if it.block { html.div(class: "zk-frame", html.frame(it)) } else {
      box(html.frame(it))
    }
  })
  // MathML export drops overline; as an overline accent (U+203E) it stays
  // semantic, and the math pipeline makes it stretch.
  show math.overline: on-html(it => math.accent(it.body, "\u{203E}"))
  // Inline layout stays inline: a box around paged-only content is framed whole.
  show box: on-html(it => {
    let body = it.body
    if body == none or repr(body.func()) == "frame" or not needs-frame(body) {
      return it
    }
    box(html.frame(it))
  })
  show selector.or(stack, grid, place, scale, move, rotate): on-html(
    it => html.div(
      class: "zk-frame",
      html.frame(it),
    ),
  )
  show align: on-html(it => {
    let x = it.alignment.x
    let side = if x == center { "center" } else if x in (right, end) {
      "right"
    } else { "left" }
    html.div(style: "text-align: " + side, it.body)
  })
  body
}

#let tree(summary, body, open: true, attrs: (:)) = html.section(
  class: "block",
  html.elem("details", attrs: attrs + if open { (open: "") } else { (:) }, {
    html.summary(summary)
    body
  }),
)

// Content repeated in a view must not advance the document's counters, or all
// numbering after it would shift; each counter is restored after the copy.
#let counted = (
  math.equation,
  heading,
  footnote,
  figure.where(kind: image),
  figure.where(kind: table),
  figure.where(kind: raw),
)
#let isolated(body) = context {
  let saved = counted.map(key => counter(key).get())
  body
  for (key, value) in counted.zip(saved) { counter(key).update(value) }
}

// Containers carry node identity; links receive their source explicitly.
// A canonical card also carries its stable link target as the section's ID.
#let node(id, body, anchor: none) = html.elem(
  "section",
  attrs: ("data-zk-node": id) + if anchor == none { (:) } else { (id: anchor) },
  body,
)

#let node-link(source, target, body) = html.elem(
  "span",
  attrs: (
    class: "zk-link",
    "data-zk-source": source,
    "data-zk-target": target,
  ),
  body,
)

#let unpublished(body) = html.span(class: "zk-unpublished", body)

#let expand-attrs(target) = ("data-zk-expand": target)

/// Resolved views map names to auto (in-place), none (disabled), or content.
#let view-attrs(views) = {
  let names = views
    .pairs()
    .filter(((_, value)) => value == auto)
    .map(((name, _)) => name)
  if names.len() > 0 { ("data-zk-view": names.join(" ")) } else { (:) }
}

// Empty templates explicitly disable views; absent markers allow fallback.
#let view-templates(views) = {
  for (name, value) in views.pairs().filter(((_, value)) => value != auto) {
    html.elem("template", attrs: ("data-zk-view": name), if value != none {
      isolated(value)
    })
  }
}

// ---- Card metadata island (data-zk-meta, version 1) -------------------------
// Each canonical card carries its metadata once, as JSON. Scalars, arrays and
// records are kept; a vocabulary member becomes its value; content is rendered
// into a numbered <template> slot and referenced as {"$slot": n}, which the
// site replaces with {"$html": "..."} after math typesetting. Node references
// are {"$node": id}. Keys starting with "$" are reserved for these markers.

#let vocabulary-member(value) = (
  type(value) == dictionary
    and value.keys().sorted() == ("type", "value", "variant")
)

// Returns the encoded value and the slots extended by its content.
#let encode-meta(value, slots) = {
  if value == none or type(value) in (str, int, float, bool) {
    (value, slots)
  } else if type(value) == content {
    (("$slot": slots.len()), slots + (value,))
  } else if vocabulary-member(value) {
    encode-meta(value.value, slots)
  } else if type(value) == array {
    let items = ()
    for item in value {
      let (encoded, next) = encode-meta(item, slots)
      items.push(encoded)
      slots = next
    }
    (items, slots)
  } else if type(value) == dictionary {
    let fields = (:)
    for (key, item) in value {
      assert(
        not key.starts-with("$"),
        message: "metadata keys starting with \"$\" are reserved: " + key,
      )
      let (encoded, next) = encode-meta(item, slots)
      fields.insert(key, encoded)
      slots = next
    }
    (fields, slots)
  } else {
    panic("unsupported metadata value of type " + str(type(value)))
  }
}

#let node-refs(ids) = ids.map(id => ("$node": id))

/// A card's metadata island. `nodes` names metadata fields that hold node
/// IDs; `relations` maps names to arrays of node IDs.
#let meta-island(id, title: none, metadata: (:), nodes: (), relations: (:)) = {
  let (title, slots) = encode-meta(title, ())
  let fields = (:)
  for (key, value) in metadata {
    if key in nodes {
      fields.insert(key, node-refs(value))
    } else {
      let (encoded, next) = encode-meta(((key): value), slots)
      fields.insert(key, encoded.at(key))
      slots = next
    }
  }
  let record = (
    version: 1,
    id: id,
    title: title,
    metadata: fields,
    relations: relations
      .pairs()
      .map(((key, ids)) => (key, node-refs(ids)))
      .to-dict(),
  )
  // "<" never appears literally, so the raw text cannot close its element.
  html.elem(
    "script",
    attrs: (type: "application/json", "data-zk-meta": ""),
    json.encode(record, pretty: false).replace("<", "\\u003c"),
  )
  isolated(for (index, slot) in slots.enumerate() {
    html.elem("template", attrs: ("data-zk-meta-slot": str(index)), slot)
  })
}

/// Publish resolved entries with string id, route and title fields.
#let publish-index(entries) = asset("zettypst.json", json.encode(entries))
