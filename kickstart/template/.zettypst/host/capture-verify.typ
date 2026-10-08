#import "common.typ": *
#import "@preview/zettyp-capture:0.1.0" as capture
#let intent = host.request()
#let state = snapshot()
#check-errors(state, intent.baseline)
#let candidates = notes(state).map(note => (
  note + (title: project-lib.display-value(note.title))
))
#let note = capture.verify(intent, nodes: candidates, read-file: (
  path,
  encoding: "utf8",
) => read("/" + host.path(path), encoding: encoding))
#announce-node(note)
