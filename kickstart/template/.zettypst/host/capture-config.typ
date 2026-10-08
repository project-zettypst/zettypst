// Project-owned rendering and additional capture records.
#let bibliography-path = "ref.bib"
#let render(req, id) = {
  let values = (
    (abstract: req.abstract, tags: (("capture",) + req.keywords).dedup())
      + req.metadata
  )
  (
    "#import \"../.zettypst/lib.typ\": *\n"
      + "#let zk-metadata = zk_metadata.with(.."
      + repr(values)
      + ")\n"
      + "#show: zettel.with(metadata: zk-metadata)\n\n"
      + "= #text("
      + repr(req.title)
      + ") <"
      + id
      + ">\n\n"
  )
}
#import "@preview/zettyp-host:0.1.0" as host
#let extra-effects(req, id, path) = {
  if req.at("bibliography", default: none) == none { return () }
  let before = read("/index.typ")
  if before.contains("bibliography(") { return () }
  (
    host.replace(
      "index.typ",
      before,
      before + "\n#bibliography(" + repr(bibliography-path) + ")\n",
    ),
  )
}
