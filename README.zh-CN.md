# ZetTypst

Typst 原生 Zettelkasten 笔记系统，让文档语言同时成为知识系统的语义语言。

- [`core/`](core/)：图与状态的描述与声明模式，
- [`eval/`](eval/)：常驻增量求值运行时
- [`lsp/`](lsp/)：编辑器适配与部分 LSP 能力的 Typst 包装
- [`host/`](host/)：create / replace / delete 文件计划的 Typst 构造器
- [`kickstart/`](kickstart/)：一套样例配置
- [`nvim/`](nvim/)：基于 [zettyp-lsp](lsp/) 的 Neovim 插件，提供笔记创建、搜索、删除能力与内容采集 (类似 [Zotero Connector](https://www.zotero.org/download/connectors))
- [`site/`](site/)：[Forester](https://www.forester-notes.org/index/index.xml) 风格卡片与 stack 阅读 (灵感来自 [Andyʼs working notes](https://notes.andymatuschak.org/About_these_notes)) 的 Web 网页发布

[参与开发](CONTRIBUTING.md) [MIT](LICENSE).
