/// Display instances of transcluded bodies. Instance labels are rendering
/// identities, never source or graph IDs.
/// Discover labels before layout. Metadata payloads and ref supplements are not
/// new declarations; deferred labels cannot participate in this static mapping.
#let labels(value) = {
  if type(value) == array { return value.map(labels).flatten() }
  if type(value) == dictionary { return value.values().map(labels).flatten() }
  if type(value) != content or value.func() in (metadata, ref) { return () }
  let fields = value.fields()
  let own = fields.at("label", default: none)
  (
    (if own == none { () } else { (own,) })
      + fields.values().map(labels).flatten()
  )
}

/// Rebuild changed native elements only. Positional bodies/children remain
/// positional, styles remain lexical, and label-valued link/ref targets remap.
#let instantiate(value, mapping) = {
  if type(value) == label { return mapping.at(str(value), default: value) }
  if type(value) == array { return value.map(it => instantiate(it, mapping)) }
  if type(value) == dictionary {
    return value
      .pairs()
      .map(((key, it)) => (key, instantiate(it, mapping)))
      .to-dict()
  }
  if type(value) != content or value.func() == metadata { return value }
  let fields = value.fields()
  let changed = instantiate(fields, mapping)
  if changed == fields { return value }
  let anchor = changed.remove("label", default: none)
  let rebuilt = if "styles" in changed and "child" in changed {
    (value.func())(changed.child, changed.styles)
  } else if repr(value.func()) == "sequence" {
    changed.children.join()
  } else if value.func() == ref {
    let target = changed.remove("target")
    ref(target, ..changed)
  } else if value.func() == link {
    let dest = changed.remove("dest")
    let body = changed.remove("body")
    link(dest, body, ..changed)
  } else if "body" in changed {
    let body = changed.remove("body")
    // A heading's resolved level and syntactic depth cannot both be supplied.
    if value.func() == heading and "level" in changed {
      let _ = changed.remove("depth", default: none)
    }
    (value.func())(body, ..changed)
  } else if "children" in changed {
    let children = changed.remove("children")
    (value.func())(..children, ..changed)
  } else {
    panic(
      "transclusion cannot instantiate this labeled element: "
        + repr(value.func()),
    )
  }
  if anchor == none { rebuilt } else { [#rebuilt#anchor] }
}

/// A consumer expanding each request in the requesting document, with every
/// label its body declares renamed under `prefix` and the instance number, so
/// copies stay distinct and number in place. `instances` numbers them; `name`
/// labels diagnostics. `wrap` places the expanded body inside the view.
#let consumer(prefix, instances, name, wrap: body => body) = (request, env) => {
  let declared = labels(env.body)
  assert(
    declared.all(id => not str(id).starts-with(prefix)),
    message: prefix + " is reserved for " + name + " display instances",
  )
  assert.eq(
    declared.dedup().len(),
    declared.len(),
    message: "duplicate local label in "
      + name
      + " source node: "
      + request.target,
  )
  instances.step()
  context {
    let instance = prefix + str(instances.get().first()) + "-"
    let mapping = declared
      .enumerate()
      .map(((index, id)) => (
        str(id),
        label(instance + str(index)),
      ))
      .to-dict()
    let body = (env.expand)(transform: value => instantiate(value, mapping))
    show selector(heading)
      .or(math.equation)
      .or(figure)
      .or(footnote): element => {
      let id = element.at("label", default: none)
      assert(
        id == none or str(id).starts-with(prefix),
        message: name + " transclusion labels must be available before layout",
      )
      element
    }
    (env.view)(env.note, request + (body: wrap(body)))
  }
}
