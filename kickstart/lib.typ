/// Configurable notebook functions built on the core primitives.
#import "src/metadata.typ": metadata, metadata-schema
#import "src/content.typ": (
  declarations, display-value, elements, emit, references, without-root,
)
#import "src/note.typ": observations, read-note, reference-color, zettel
#import "src/relations.typ": colored-edge, neighbors, project-neighbors
#import "src/policies/lifecycle.typ": lifecycle-policy
#import "src/project.typ": load, project-notes
#import "src/evaluation.typ": evaluate, evaluation-issues, observe
#import "src/editor.typ": announce-editor, navigation
#import "src/export.typ": announce-project, publish
#import "src/html.typ": export-html
