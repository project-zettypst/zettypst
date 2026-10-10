#import "@preview/zettyp-core:0.1.0": eval
#import "project.typ": project-notes

#let announce-project(project, final) = {
  if final != none {
    eval.announce(
      <zk.notes>,
      project-notes(project, final).map(note => (
        note + (origin: eval.inspect(note.origin))
      )),
    )
    eval.announce(<zk.graph>, (
      state: final,
      origins: (
        nodes: project
          .origins
          .nodes
          .pairs()
          .map(((id, origin)) => (id, eval.inspect(origin)))
          .to-dict(),
        edges: project
          .origins
          .edges
          .pairs()
          .map(((id, origin)) => (id, eval.inspect(origin)))
          .to-dict(),
      ),
    ))
  }
  eval.announce(<zk.references.unclassified>, project.unclassified.map(item => (
    item + (origin: eval.inspect(item.origin))
  )))
}
