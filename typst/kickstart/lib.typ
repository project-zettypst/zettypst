/// Configurable notebook functions built on the core primitives.
#import "src/metadata.typ": metadata, metadata-schema
#import "src/content.typ": (
  declarations, display-value, elements, emit, references, without-root,
)
#import "src/note.typ": observations, read-note, reference-color, zettel
#import "src/sections.typ": note
#import "src/relations.typ": (
  ancestor-roots, colored-edge, neighbor-index, neighbors, project-neighbors,
)
#import "src/policies/lifecycle.typ": lifecycle-policy
#import "src/transclusion/declaration.typ": include-color, include-note
#import "src/transclusion/policy.typ": transclusion-policy
#import "src/project.typ": discover, load, project-notes
#import "src/registration.typ": (
  allocate-note-id, announce-note-registration, plan-note-registration,
)
#import "src/evaluation.typ": evaluate, evaluation-issues, observe
#import "src/editor.typ" as lsp
#import "src/editor.typ": announce-editor, navigation
#import "src/export.typ": announce-project, publish
#import "src/html.typ" as site
#import "src/html.typ": export-html
#import "src/pdf.typ": export-pdf
#import "src/transclusion/render.typ": (
  expanded as expand-transclusion, renderer as transclusion-renderer,
)
#import "src/transclusion/pdf.typ" as pdf
#import "src/host.typ" as host
#import "src/capture/lib.typ" as capture
