// Forester tree markup (tree.xsl): details > summary > header, with backmatter
// in a footer. The note's root heading becomes the card's summary, so its
// label remains the card's anchor. Links are ordinary refs to note labels.

// ---- Layout that HTML cannot express -----------------------------------------
// Such content is kept as a Typst-rendered SVG frame; other targets are untouched.

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
  show math.equation: on-html(it => {
    if not needs-frame(it.body) { return it }
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

// ---- Cards ------------------------------------------------------------------

#let meta-items(meta) = {
  let items = ()
  let lifecycle = meta.at("lifecycle", default: none)
  if type(lifecycle) == dictionary and lifecycle.value != "active" {
    items.push(html.span(class: "status", lifecycle.value))
  }
  let tags = meta.at("tags", default: ())
  if tags.len() > 0 { items.push(tags.join(", ")) }
  for (key, text) in (
    ("replaced-by", "Replaced by"),
    ("evolved-into", "Evolved into"),
  ) {
    let ids = meta.at(key, default: ())
    if ids.len() > 0 {
      items.push[#text #ids.map(id => ref(label(id))).join[, ]]
    }
  }
  items
}

#let frontmatter(note, title) = html.header({
  html.h1({
    title
    [ ]
    // A ref, so the slug is rendered as a link to its note like any other.
    html.span(class: "slug", ref(label(note.id), supplement: [\[#note.id\]]))
  })
  let items = meta-items(note.metadata)
  if items.len() > 0 {
    html.div(class: "metadata", html.ul(
      items.map(it => html.li(class: "meta-item", it)).join(),
    ))
  }
})

#let tree(summary, body, open: true, attrs: (:)) = html.section(
  class: "block",
  html.elem("details", attrs: attrs + if open { (open: "") } else { (:) }, {
    html.summary(summary)
    body
  }),
)

// Collapsed trees; the site expands each from its canonical card.
#let backmatter(title, notes) = if notes.len() > 0 {
  tree(
    html.header(html.h1(title)),
    notes
      .map(it => tree(frontmatter(it, it.title), none, open: false, attrs: (
        "data-zk-expand": it.id,
      )))
      .join(),
  )
}

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

// ---- Views -------------------------------------------------------------------

#let blank(value) = value in (none, "", (), (:), [])

// One metadata value as text: vocabulary members by name, lists joined.
#let metadata-value(value) = if type(value) == dictionary and "value" in value {
  value.value
} else if type(value) == dictionary {
  value
    .pairs()
    .filter(((_, it)) => not blank(it))
    .map(((key, it)) => [#key: #metadata-value(it)])
    .join[; ]
} else if type(value) == array {
  value.map(metadata-value).join[, ]
} else if type(value) == bool {
  if value [yes] else [no]
} else if type(value) in (str, content) { value } else { repr(value) }

/// The default `about` view: the note's metadata and its graph neighbourhood,
/// as the editor's hover shows them.
#let about(note) = html.elem("dl", attrs: (class: "zk-about"), {
  for (key, value) in note.metadata {
    if not blank(value) {
      html.elem("dt", key)
      html.elem("dd", metadata-value(value))
    }
  }
  html.elem("dt", "backlinks")
  html.elem("dd", str(note.backlinks.len()))
  html.elem("dt", "links")
  html.elem("dd", str(note.links.len()))
})

/// The card layout. `views` are policies deciding, per note, what the card
/// shows when it appears elsewhere, by name:
/// - `preview`: a hover preview, from a link in another card;
/// - `expand`: an in-place expansion of a collapsed tree;
/// - `about`: a hover preview from the card's own links (its slug, say);
///   by default its metadata.
/// Each returns `auto` (the card's title and body, marked in place), `none`
/// (no such view) or content, e.g. `note => [#note.metadata.abstract]`.
/// Content is rendered like the card, kept inert in a `<template>`, and does
/// not advance counters. `note.main` (the body without its root heading) can
/// be repeated safely; other labels it holds must not be referenced twice.
#let card(note, views: (:)) = {
  show: html-rules
  let shown = (
    (preview: note => auto, expand: note => auto, about: about) + views
  )
    .pairs()
    .map(((name, view)) => (name, view(note)))
  let in-place = shown.filter(((_, it)) => it == auto).map(((name, _)) => name)
  let marked = if in-place.len() > 0 {
    ("data-zk-view": in-place.join(" "))
  } else { (:) }
  html.elem("details", attrs: (open: "") + marked, {
    show heading.where(level: 1): it => html.summary(frontmatter(note, it.body))
    note.body
  })
  for (name, view) in shown.filter(((_, it)) => it != auto) {
    html.elem("template", attrs: ("data-zk-view": name), if view != none {
      isolated(view)
    })
  }
  html.footer({
    backmatter("Backlinks", note.backlinks)
    backmatter("Related", note.links)
  })
}
