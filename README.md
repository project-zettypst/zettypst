# ZetTypst

A Typst-native Zettelkasten note system, where the document language also serves as the semantic language of the knowledge system. Get started with the [template](https://github.com/project-zettypst/grove).

- [zettyp](typst/): The Typst package for ZetTypst, providing a [semantic core](typst/core/), [default notebook implementation and example configuration](typst/kickstart/), and generic interfaces for [file operations](typst/host/), [language server integration](typst/lsp/), and [site generation](typst/site/)
- [zettyp-eval](eval/): A persistent incremental evaluation runtime
- [zettyp-lsp](lsp/): Communicates with editors through [zettyp.lsp](typst/lsp/), implementing selected LSP capabilities
- [zettypst.nvim](nvim/): A Neovim plugin built on [zettyp-lsp](lsp/), offering note creation, search, deletion, and content capture (similar to [Zotero Connector](https://www.zotero.org/download/connectors))
- [zettypst-site](site/): An Astro integration built on [zettyp.site](typst/site/), publishing static sites with [Forester](https://www.forester-notes.org/index/index.xml)-style cards and stacked reading inspired by [Andy’s working notes](https://notes.andymatuschak.org/About_these_notes)

[Contributing](CONTRIBUTING.md) [MIT](LICENSE).
