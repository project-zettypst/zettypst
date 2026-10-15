// Mechanical source edits. These declarations never execute or write files.
#import "../core/eval.typ" as eval

/// Insert a missing named argument in the call directly containing this body.
/// The LSP resolves the body against the evaluated source snapshot.
/// value-source must contain one Typst expression, not plain display text.
#let insert-argument(body: none, name: none, value-source: none) = {
  assert(type(body) == content, message: "AST edit body must be content")
  assert(type(name) == str, message: "AST argument name must be a string")
  assert(
    type(value-source) == str,
    message: "AST argument value must be source text",
  )
  (
    kind: "ast.insert-argument",
    body: eval.inspect(body),
    name: name,
    value-source: value-source,
  )
}
