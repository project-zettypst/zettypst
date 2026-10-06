# ZetTypst

A Typst-native Zettelkasten note system, where the document language also serves as the semantic language of the knowledge system.

- [`core/`](core/): Graph and state descriptions and declarations
- [`eval/`](eval/): A persistent incremental evaluation runtime
- [`lsp/`](lsp/): Editor integration and Typst wrappers for selected LSP capabilities
- [`host/`](host/): Typst constructors for create, replace and delete file plans
- [`kickstart/`](kickstart/): An example configuration
- [`nvim/`](nvim/): A Neovim plugin built on [zettyp-lsp](lsp/), offering note creation, search, deletion, and content capture (similar to [Zotero Connector](https://www.zotero.org/download/connectors))
- [`site/`](site/): Web publication with [Forester](https://www.forester-notes.org/index/index.xml)-style cards and stacked reading inspired from [Andyʼs working notes](https://notes.andymatuschak.org/About_these_notes)

[Contributing](CONTRIBUTING.md) [MIT](LICENSE).
