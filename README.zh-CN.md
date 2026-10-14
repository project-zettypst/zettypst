# ZetTypst

Typst 原生 Zettelkasten 笔记系统，让文档语言同时成为知识系统的语义语言。使用[模板](https://github.com/project-zettypst/grove)快速开始。

- [zettyp](typst/)：ZetTypst 的 Typst 包，提供[语义核心](typst/core/)、[默认笔记实现与样例配置](typst/kickstart/)，以及[文件操作](typst/host/)、[语言服务器适配](typst/lsp/)与[网站构建](typst/site/)的通用接口
- [zettyp-eval](eval/)：常驻增量求值运行时
- [zettyp-lsp](lsp/)：通过 [zettyp.lsp](typst/lsp/) 与编辑器通信，实现部分 LSP 功能
- [zettypst.nvim](nvim/)：基于 [zettyp-lsp](lsp/) 的 Neovim 插件，提供笔记创建、搜索、删除与内容采集能力（类似 [Zotero Connector](https://www.zotero.org/download/connectors)）
- [zettypst-site](site/)：Astro 集成，基于[zettyp.site](typst/site/)，提供 [Forester](https://www.forester-notes.org/index/index.xml) 风格卡片与堆叠阅读（灵感来自 [Andy’s working notes](https://notes.andymatuschak.org/About_these_notes)）的静态站点发布

[参与开发](CONTRIBUTING.md) [MIT](LICENSE).
