#import "vocabulary.typ": colors, lifecycle

#let emit = metadata

// Shallow: declarations through sequences/styles. Deep: rendered bodies too.
// References and metadata are leaves: never walk supplements or payloads.
#let elements(body, deep: false) = {
  if type(body) == array {
    return body.map(it => elements(it, deep: deep)).flatten()
  }
  if type(body) != content { return () }
  if body.func() in (ref, emit) { return (body,) }
  let fields = body.fields()
  let keys = if deep { ("children", "child", "body") } else if (
    "styles" in fields
  ) {
    ("children", "child")
  } else { ("children",) }
  let key = keys.find(key => key in fields)
  if key == none { (body,) } else { elements(fields.at(key), deep: deep) }
}

#let declarations(body, protocol, deep: false) = (
  elements(body, deep: deep)
    .filter(it => (
      it.func() == emit
        and type(it.value) == dictionary
        and it.value.at("protocol", default: none) == protocol
        and it.value.at("version", default: none) == 1
    ))
    .map(it => it.value)
)

#let references(body) = elements(body, deep: true).filter(it => (
  it.func() == ref
))

// The body without its root heading, found as read-note finds it: through
// sequences and styles only. Without the note's own label, it can be repeated
// (in a preview, an expansion) without duplicating the label every link targets.
#let without-root(body, id) = {
  if type(body) != content { return body }
  let fields = body.fields()
  if "children" in fields {
    return fields
      .children
      .filter(it => {
        not (
          it.func() == heading and it.at("label", default: none) == label(id)
        )
      })
      .map(it => without-root(it, id))
      .join()
  }
  if "child" in fields and "styles" in fields {
    return (body.func())(without-root(fields.child, id), fields.styles)
  }
  if body.func() == heading and body.at("label", default: none) == label(id) {
    return []
  }
  body
}

#let display-value(value) = {
  if type(value) == content {
    elements(value, deep: true)
      .map(it => {
        if repr(it.func()) == "space" { " " } else if (
          it.func() in (linebreak, parbreak)
        ) { "\n" } else { it.fields().at("text", default: repr(it)) }
      })
      .join()
  } else if type(value) == array {
    value.map(display-value).join(", ")
  } else if (
    type(value) == dictionary
      and value in (lifecycle.values() + colors.values())
  ) {
    display-value(value.value)
  } else if type(value) in (str, label) { str(value) } else { repr(value) }
}
