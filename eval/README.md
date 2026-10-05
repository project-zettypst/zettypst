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

RPC `eval` accepts `entry`, string-valued `inputs`, and optional `sources` mapping
project-relative paths to text or `null`. A null override makes the file absent.
Omitted paths fall back to disk. Replies include `revision`, `output`, `warnings`
and `reads`: project-relative paths mapped to the SHA-256 of the exact disk bytes
consumed, or `null` for missing files. Both source imports and binary/data reads
are recorded; explicit overrides, package files and fonts are excluded. Failed
evaluations also carry reads in the RPC error data.
