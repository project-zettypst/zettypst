/// Tagged disjoint unions with opaque payloads.
#let left(value) = (side: "left", value: value)
#let right(value) = (side: "right", value: value)

/// Merge A -> C and B -> C into A + B -> C.
/// Only the selected branch runs. No policy semantics or panic recovery.
#let merge(on-left, on-right) = {
  assert(
    type(on-left) == function and type(on-right) == function,
    message: "sum branches must be functions",
  )
  value => {
    assert(
      type(value) == dictionary
        and value.keys().sorted() == ("side", "value")
        and value.side in ("left", "right"),
      message: "expected a tagged disjoint union",
    )
    if value.side == "left" { on-left(value.value) } else {
      on-right(value.value)
    }
  }
}
