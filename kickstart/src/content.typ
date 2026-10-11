#import "../../core/vocabulary.typ"

#let emit = metadata

// References and metadata are leaves; payloads and supplements are not bodies.
#let children(body, deep: false) = {
  if body.func() in (ref, emit) { return none }
  let fields = body.fields()
  let keys = (
    ("children",)
      + if deep {
        ("child", "body")
      } else if "styles" in fields { ("child",) } else { () }
  )
  let key = keys.find(key => key in fields)
  if key != none { fields.at(key) }
}

/// Walk sequences and styles, optionally descending into rendered bodies.
#let elements(body, deep: false) = {
  if type(body) == array {
    return body.map(elements.with(deep: deep)).flatten()
  }
  if type(body) != content { return () }
  let nested = children(body, deep: deep)
  if nested == none { (body,) } else { elements(nested, deep: deep) }
}

#let declarations(body, protocol, deep: false) = (
  elements(body, deep: deep)
    .filter(it => it.func() == emit)
    .map(it => it.value)
    .filter(value => (
      type(value) == dictionary
        and value.at("protocol", default: none) == protocol
        and value.at("version", default: none) == 1
    ))
)

#let references(body) = elements(body, deep: true).filter(it => (
  it.func() == ref
))

/// Remove the root label through sequences and styles, preserving other bodies.
#let without-root(body, id) = {
  if type(body) != content { return body }
  if body.func() == heading and body.at("label", default: none) == label(id) {
    return []
  }
  let fields = body.fields()
  if "children" in fields {
    return fields.children.map(it => without-root(it, id)).join()
  }
  if "styles" in fields and "child" in fields {
    return (body.func())(without-root(fields.child, id), fields.styles)
  }
  body
}

#let text-fragment(element) = (
  (space: " ", linebreak: "\n", parbreak: "\n").at(
    repr(element.func()),
    default: element.fields().at("text", default: repr(element)),
  )
)

/// Display enum payloads without imposing a vocabulary or a naming scheme.
#let display-value(value) = {
  if vocabulary.enum-value(value) { return display-value(value.value) }
  if type(value) == content {
    return elements(value, deep: true)
      .map(text-fragment)
      .map(display-value)
      .join()
  }
  if type(value) == array { return value.map(display-value).join(", ") }
  if type(value) in (str, label) { str(value) } else { repr(value) }
}
