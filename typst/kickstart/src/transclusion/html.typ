/// HTML consumes the request, not the expanded target body. Only final scalar
/// placement data crosses the boundary; custom heading functions run in Typst.
#let consume(request, env) = {
  assert(
    env.note.route != none,
    message: "cannot embed unpublished node: " + request.target,
  )
  let slot = html.elem("div", attrs: (
    "data-zk-transclusion": request.target,
    "data-zk-source": request.source,
    "data-zk-level": str(request.level),
    "data-zk-relative": if request.relative { "true" } else { "false" },
  ))
  (env.view)(env.note, request + (body: slot))
}
