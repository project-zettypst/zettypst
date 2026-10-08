#import "common.typ": *
#let intent = host.request()
#let state = snapshot()
#check-errors(state, intent.baseline)
#assert(
  intent.id not in state.project.state.graph.nodes,
  message: "deleted node remains",
)
#assert(
  intent.path not in toml("/" + manifest).paths,
  message: "deleted source remains registered",
)
