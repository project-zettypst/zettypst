// Bibliography identity, key and merge policy of the zettyp-capture package.
#import "../capture/lib.typ": bibtex-identity, merge-bibliography
#let before = "@article{old,\n  title = {Old Paper},\n  doi = {10.1/X}\n}\n"
#let entries = ((key: "old", fields: (title: "Old Paper", doi: "10.1/X"), start: 0, end: before.len() - 1),)
#let merge(fields, key: "new", asset: none, base: before, known: entries) = merge-bibliography(
  (path: "ref.bib", before: base, entries: known, entry: (type: "article", key: key, fields: fields)),
  asset,
  path => before,
)

// Normalized identifiers find the duplicate; it keeps its key and gains missing fields.
#let enriched = merge((title: "Other", doi: "https://doi.org/10.1/x", author: "Ada"))
#assert.eq(enriched.key, "old")
#assert.eq(enriched.content, "@article{old,\n  title = {Old Paper},\n  doi = {10.1/X},\n  author = {Ada},\n}\n")
// A same-key entry with the same title is the same work; nothing changes.
#assert.eq(merge((title: " old paper "), key: "old").content, before)
// A different work under a taken key receives the next free suffix.
#let renamed = merge((title: "Different"), key: "old")
#assert.eq(renamed.key, "old-2")
#assert(renamed.content.ends-with("}\n\n@article{old-2,\n  title = {Different},\n}\n"))
// A new file holds only the rendered entry, including the stored asset.
#assert.eq(
  merge((title: "A {B}  c"), base: none, known: (), asset: (path: "assets/x.pdf")).content,
  "@article{new,\n  title = {A B c},\n  file = {assets/x.pdf},\n}\n",
)
#assert.eq((bibtex-identity.eprint)("arXiv:2401.12345v2"), "2401.12345")
#assert.eq((bibtex-identity.eprint)("https://arxiv.org/pdf/2401.12345v3.pdf"), "2401.12345")
