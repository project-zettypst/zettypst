#import "common.typ": *
#let intent = host.request()
#let state = snapshot()
#check-errors(state, intent.baseline)
#let matches = notes(state).filter(note => note.id == intent.id)
#assert.eq(matches.len(), 1)
#let note = matches.first()
#assert.eq(note.path, intent.path)
#if intent.created { assert.eq(project-lib.display-value(note.title), intent.title) }
#assert.eq(json("/.zettypst/captures.json").at(intent.identity).id, intent.id)
#if intent.bibliography != none {
  assert.eq(read("/" + intent.bibliography.path), intent.bibliography.content)
}
#if intent.asset != none {
  assert.eq(read("/" + intent.asset.path, encoding: none).slice(0, 5), bytes("%PDF-"))
}
#announce-node(note)
