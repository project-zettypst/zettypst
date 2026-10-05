#import "common.typ": *
#import "capture-config.typ" as settings
#let req = host.request()
#assert(req.keys().all(key => key in (
  "kind", "title", "abstract", "keywords", "selection", "url", "metadata", "asset",
  "bibliography", "existing_id", "matched_by", "translator", "now",
)), message: "unknown capture field")
#assert(req.kind in ("web", "paper", "paper-note"))
#assert(type(req.title) == str and req.title.trim() != "")
#assert(type(req.abstract) == str and type(req.selection) == str and type(req.url) == str)
#assert(type(req.keywords) == array and req.keywords.all(it => type(it) == str))
#assert(type(req.metadata) == dictionary)
#let state = snapshot()
#let registry-path = ".zettypst/captures.json"
#let registry-before = read("/" + registry-path)
#let registry = json.decode(registry-before)
#let bib = req.at("bibliography", default: none)
#let asset = req.at("asset", default: none)
#let identity = if bib != none { "bib:" + bib.key } else { "url:" + req.url }
#let prior = registry.at(identity, default: none)
#if prior == none and asset != none {
  prior = registry.values().find(record => record.at("sha256", default: none) == asset.sha256)
}
#let id = if prior != none { prior.id } else { req.at("existing_id", default: none) }
#if id != none and id not in state.project.state.graph.nodes { id = none }
#let created = id == none
#if created { id = str(project-lib.allocate-id(now(req.now), state.project.state.graph.nodes)) }
#let path = if created { "note/" + id + ".typ" } else {
  notes(state).find(note => note.id == id).path
}
#let effects = ()
#if asset != none {
  let _ = host.path(asset.path)
  assert(asset.sha256.contains(regex("^[0-9a-f]{64}$")))
  assert.eq(asset.path, "assets/" + asset.sha256 + ".pdf")
  assert.eq(read("/" + asset.path, encoding: none).slice(0, 5), bytes("%PDF-"))
}
#if bib != none {
  assert.eq(bib.path, settings.bibliography-path, message: "bibliography path differs from project capture config")
  assert(bib.key.contains(regex("^[a-zA-Z0-9_:.-]+$")))
  if bib.before == none {
    effects.push(host.create(bib.path, bib.content))
  } else {
    assert.eq(read("/" + bib.path), bib.before, message: "bibliography changed; retry capture")
    if bib.content != bib.before { effects.push(host.replace(bib.path, bib.before, bib.content)) }
  }
}
#if created {
  let body = settings.render(req, id)
  if bib != none { body += "Source: #cite(label(" + repr(bib.key) + "))\n\n" }
  if req.url != "" { body += "#link(" + repr(req.url) + ")[Source URL]\n\n" }
  if asset != none { body += "#link(" + repr("../" + asset.path) + ")[Local PDF]\n\n" }
  if req.selection != "" { body += "#text(" + repr(req.selection) + ")\n" }
  else if req.abstract != "" { body += "#text(" + repr(req.abstract) + ")\n" }
  effects.push(host.create(path, body))
  let paths = toml("/" + manifest).paths
  effects.push(host.replace(manifest, read("/" + manifest), manifest-text(paths + (path,))))
}
#let record = (id: id, note: path, kind: req.kind, url: req.url)
#if bib != none { record += (key: bib.key) }
#if asset != none { record += (file: asset.path, sha256: asset.sha256) }
#registry.insert(identity, record)
#let registry-after = json.encode(registry)
#if registry-before != registry-after {
  effects.push(host.replace(registry-path, registry-before, registry-after))
}
#{ effects += settings.extra-effects(req, id, path) }
#eval.announce(<host.plan>, host.plan(effects,
  verification("capture-verify", (id: id, path: path, title: req.title, created: created,
    identity: identity, bibliography: bib, asset: asset), state.errors),
))
