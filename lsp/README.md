# zettyp-lsp

A stdio LSP adapter for Typst announcements, backed by one persistent `zettyp-eval` runtime.

```sh
zettyp-lsp --root .
```

[MIT](../LICENSE).

### Detached evaluation

`workspace/executeCommand` with `command: "zettyp.evalDetached"` accepts one
argument `{entry, inputs?, sources?}`. Inputs are strings; sources map relative
paths to text or `null` tombstones. It evaluates disk plus these explicit
sources, without open-document overlays. The reply is
`{revision, output, warnings, reads}`; reads map project-relative paths to
SHA-256 hashes or `null` for absent files. Document changes do not invalidate a
detached request. Explicit cancellation and shutdown still cancel it.

Detached results never populate the LSP index, persist snapshots, publish
diagnostics or execute file projections. `zettyp.eval` remains the command for
editor-aware reads. The server treats announcement labels and data generically;
transaction policy belongs to the caller and its Typst entries.
