#import "instance.typ": consumer

/// HTML expands each request in the requesting document, as PDF does: labels,
/// numbering and footnotes are resolved by Typst in place. The expanded body
/// is marked as a copy of the target's mainmatter.
#let instances = counter("zettypst.html.instance")
#let expand = consumer(
  "zettyp-html-",
  instances,
  "HTML",
  wrap: body => html.elem(
    "div",
    attrs: ("data-zk-main-copy": ""),
    body,
  ),
)
#let consume(request, env) = {
  assert(
    env.note.route != none,
    message: "cannot embed unpublished node: " + request.target,
  )
  expand(request, env)
}
