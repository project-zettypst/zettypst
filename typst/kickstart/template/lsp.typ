// Discover pending definitions before strict graph assembly.
#import ".zettypst/lib.typ": zk
#let (
  announce-note-registration,
  discover,
  evaluate,
  load,
  plan-note-registration,
  publish,
  ..,
) = zk

#let sources = discover()
#let registration = plan-note-registration(sources)
#announce-note-registration(sources, registration)
#if registration.entries.len() == 0 {
  let project = load(sources: sources)
  assert.eq(project.issues, ())
  let result = evaluate(project)
  publish(project, result.program, result.execution, export: false)
}
