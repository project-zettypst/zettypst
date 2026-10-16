// Forester tree markup (tree.xsl): details > summary > header, with backmatter
// in a footer. Node data supplies the summary and its canonical label;
// mainmatter is rendered once and exposed to output consumers.

#import "../../site/lib.typ" as site
#import site: html-rules, tree

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

#let frontmatter(note, title, heading-renderer: none) = html.header({
  let render-heading = if heading-renderer == none { html.h1 } else {
    heading-renderer
  }
  render-heading({
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

// Instance anchors identify rendered occurrences, never knowledge nodes.
// This counter is deliberately separate from document heading counters.
#let instances = counter("zettypst.embed.instance")

/// Shared HTML view for source includes and relationship-list entries.
/// The renderer has already expanded the body and resolved heading levels.
#let embedded(note, instance) = {
  show: html-rules
  let render-heading = if instance.heading-renderer == none {
    heading.with(level: instance.level)
  } else {
    title => (instance.heading-renderer)(title, instance.level)
  }
  instances.step()
  context {
    let anchor = "zk-instance-" + str(instances.get().first())
    site.node(note.id, tree(
      frontmatter(note, instance.title, heading-renderer: render-heading),
      instance.body,
      open: instance.open,
      attrs: (id: anchor),
    ))
  }
}

// Relation queries supply targets; embedding supplies their complete mainmatter.
// Embedded views never append another relationship list.
#let backmatter(title, notes, embed) = if notes.len() > 0 {
  assert(
    type(embed) == function,
    message: "relationship views require an embed function",
  )
  tree(
    html.header(html.h1(title)),
    site.isolated(
      notes.map(note => embed(note.id, context-level: 1, open: false)).join(),
    ),
  )
}

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
/// not advance counters. Custom templates must not duplicate referenced Typst
/// labels. Transclusion requests instead reuse the canonical HTML mainmatter.
#let card(note, embed: none, views: (:)) = {
  show: html-rules
  let shown = (
    (preview: note => auto, expand: note => auto, about: about) + views
  )
    .pairs()
    .map(((name, view)) => (name, view(note)))
    .to-dict()
  html.elem("details", attrs: (open: "") + site.view-attrs(shown), {
    [#html.summary(frontmatter(note, note.title))#label(note.id)]
    html.elem("div", attrs: ("data-zk-main": ""), note.main)
  })
  site.view-templates(shown)
  html.footer({
    backmatter("Context", note.at("context", default: ()), embed)
    backmatter("Backlinks", note.backlinks, embed)
    backmatter("Related", note.links, embed)
  })
}
