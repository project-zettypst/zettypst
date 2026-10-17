// Two notes linking each other and themselves, laid out by the site card with
// every view repeating the body, so copied links are rendered too.
#import ".zettypst/lib.typ": zk
#let (evaluate, export-html, load, ..) = zk
#import "@preview/zettyp:0.1.0": kickstart
#import kickstart.site: card

#let project = load()
#assert.eq(project.issues, ())
#export-html(project, evaluate(project), card: card.with(views: (
  expand: note => note.main,
)))
