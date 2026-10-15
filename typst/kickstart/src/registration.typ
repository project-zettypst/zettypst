/// Default internal-node naming policy. Parentage is used only at allocation;
/// persisted identities never change when definitions move or are renamed.
#let allocate-note-id(ctx) = {
  let suffix = 1
  let candidate = ctx.parent-id + "-" + str(suffix)
  while candidate in ctx.used {
    suffix += 1
    candidate = ctx.parent-id + "-" + str(suffix)
  }
  label(candidate)
}

#let default-allocator = allocate-note-id

/// Plan all pending definitions together so actions from one analysis reserve
/// distinct candidates. This does not register them or change the knowledge graph.
#let plan-note-registration(sources, allocate: default-allocator) = {
  assert(type(allocate) == function, message: "ID allocator must be a function")
  let existing(definition) = {
    let own = if definition.id == none { () } else { (str(definition.id),) }
    own + definition.children.map(existing).flatten()
  }
  let used = sources.map(source => existing(source.definition)).flatten()
  assert(used.all(id => id != ""), message: "node ID must not be empty")
  assert.eq(
    used.dedup().len(),
    used.len(),
    message: "duplicate persistent node ID",
  )

  let walk(definition, parent-id, path, used, ancestors) = {
    let id = definition.id
    let entries = ()
    let chain = ancestors
    if id == none {
      assert(
        parent-id != none,
        message: "pending node requires a persistent ancestor",
      )
      id = allocate((
        parent-id: parent-id,
        used: used,
        definition: definition,
        path: path,
      ))
      assert(type(id) == label, message: "ID allocator must return a label")
      assert(
        str(id) != "" and str(id) not in used,
        message: "ID allocator returned an empty or occupied identity",
      )
      used.push(str(id))
      let entry = (
        id: id,
        body: definition.source-body,
        origin: definition.root,
        path: path,
      )
      chain += (entry,)
      entries.push(entry + (required: chain))
    }
    for child in definition.children {
      let result = walk(child, str(id), path, used, chain)
      used = result.used
      entries += result.entries
    }
    (used: used, entries: entries)
  }
  let entries = ()
  for source in sources {
    let result = walk(source.definition, none, source.path, used, ())
    used = result.used
    entries += result.entries
  }
  (entries: entries)
}

/// The editor consumes ordinary code actions; naming remains a Typst policy.
#let announce-note-registration(lsp, sources, plan) = {
  let edit(entry) = lsp.ast.insert-argument(
    body: entry.body,
    name: "id",
    value-source: repr(entry.id),
  )
  for path in sources.map(source => source.path).dedup() {
    let source = sources.find(source => source.path == path)
    let entries = plan.entries.filter(entry => entry.path == path)
    let diagnostics = entries.map(entry => lsp.diagnostic(
      origin: entry.origin,
      message: "Node has no persistent ID; register it to include it in the graph.",
      severity: lsp.severity.warning,
      code: "note.unregistered",
      source: "zettypst",
    ))
    lsp.announce(lsp.effect-kinds.publish-diagnostics, lsp.publish-diagnostics(
      document: source.definition.root,
      diagnostics: diagnostics,
    ))
    let actions = entries
      .map(entry => {
        let actions = (
          lsp.code-action(
            applies-to: entry.origin,
            title: "Register node: " + str(entry.id),
            kind: "quickfix",
            edit: lsp.workspace-edit(edits: entry.required.map(edit)),
          ),
        )
        if entries.len() > 1 {
          // File show-rule bodies do not retain a reliable whole-file span.
          // Offer the batch action at each original pending heading instead.
          actions.push(lsp.code-action(
            applies-to: entry.origin,
            title: "Register all unnamed nodes in this file",
            kind: "quickfix",
            edit: lsp.workspace-edit(edits: entries.map(edit)),
          ))
        }
        actions
      })
      .flatten()
    lsp.announce(lsp.effect-kinds.code-actions, lsp.offer-code-actions(
      document: source.definition.root,
      actions: actions,
    ))
  }
}
