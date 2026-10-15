#import "../../../core/vocabulary.typ"

/// Projects register this identity in their relation vocabulary.
#let include-color = (
  vocabulary.register("relation", ..("include": <zk.include>)).at("include")
)

/// Read an include marker without descending into reference supplements.
#let inclusion(element) = {
  if type(element) != content or element.func() != ref { return none }
  let supplement = element.at("supplement", default: none)
  if type(supplement) != content or supplement.func() != metadata {
    return none
  }
  let marker = supplement.value
  if (
    type(marker) != dictionary
      or marker.at("protocol", default: none) != "zettyp.include"
  ) {
    return none
  }
  assert.eq(
    marker.at("version", default: none),
    1,
    message: "unsupported include protocol version",
  )
  let origin = marker.at("origin", default: none)
  assert(
    type(origin) == content and origin.func() in (ref, heading),
    message: "include declaration requires an original reference or section heading",
  )
  if origin.func() == ref {
    assert.eq(
      origin.target,
      element.target,
      message: "include target differs from its origin",
    )
  }
  marker
}

/// Shared representation for authored includes and extracted definitions.
/// source-level belongs to the enclosing source, not an absolute output level.
#let include-content(
  target,
  origin,
  level: auto,
  title: none,
  heading-renderer: none,
  source-level: none,
) = {
  ref(target, supplement: metadata((
    protocol: "zettyp.include",
    version: 1,
    origin: origin,
    source-level: source-level,
    level: level,
    title: title,
    heading-renderer: heading-renderer,
  )))
}

/// Declare one use of an existing node; loading and expansion happen later.
/// Keep the original ref for source navigation, not the generated wrapper.
#let include-note(
  reference,
  level: auto,
  title: none,
  heading-renderer: none,
) = {
  assert(
    type(reference) == content and reference.func() == ref,
    message: "include needs one native reference",
  )
  assert(
    inclusion(reference) == none,
    message: "include cannot wrap another include",
  )
  assert(
    level == auto or (type(level) == int and level > 0),
    message: "include level must be a positive integer or auto",
  )
  assert(
    title == none or type(title) in (content, str, function),
    message: "include title must be content, a string, a selector, or none",
  )
  assert(
    heading-renderer == none or type(heading-renderer) == function,
    message: "include heading renderer must be a function or none",
  )
  include-content(
    reference.target,
    reference,
    level: level,
    title: title,
    heading-renderer: heading-renderer,
  )
}
