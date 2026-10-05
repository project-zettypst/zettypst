# zettyp-eval

Persistent Typst evaluation and source provenance, available as a Rust library and CLI. 

```sh
zettyp-eval main.typ --root . --input key=value
```

Persistent server (Unix only):

```sh
zettyp-eval serve --root . --socket /tmp/zettyp-eval.sock
```

[MIT](LICENSE).
