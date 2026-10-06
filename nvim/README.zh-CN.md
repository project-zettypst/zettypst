# zettypst.nvim

[ZetTypst](https://github.com/project-zettypst/zettypst) 笔记系统的官方 [Neovim](https://github.com/neovim/neovim) 插件，以 [zettypst-lsp](https://github.com/project-zettypst/zettypst/tree/main/lsp) 为计算后端，依赖 [snacks.nvim](https://github.com/folke/snacks.nvim)。支持最新 Neovim 稳定版与夜间构建版本。针对 [zettypst-kickstart](https://github.com/project-zettypst/zettypst/tree/main/kickstart) 开箱即用

```lua
require("zettypst").setup(require("zettypst.presets.kickstart"))
```

[MIT](LICENSE)
