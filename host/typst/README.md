# zettyp-host

Policy-free constructors for `<host.node>` and `<host.plan>` announcements.
Import `eval` from Core to announce the returned values. `node` externalizes
source-backed content with `eval.inspect`; metadata must recursively contain
only dictionaries, arrays, strings, numbers, booleans and `none`.

`create(path, content)`, `replace(path, before, content)` and `delete(path, before)`
return ordered file effects. Paths are canonical project-relative paths.
`plan(effects, verify)` carries a verification entry and string inputs.
`request()` decodes the JSON dictionary in `sys.inputs.at("host.request")`.

The consumer owns interaction, locking, conflict detection and file IO. Project
entries own intent, graph semantics and policy. See Kickstart's `.zettypst/host`.
