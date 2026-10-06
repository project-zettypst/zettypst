local M = {}
function M.check()
  vim.health.start("zettypst.nvim")
  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim supports the required LSP APIs")
  else
    vim.health.error("Neovim 0.11+ is required")
  end
  if not require("zettypst.titles").supported() then
    vim.health.warn("This Neovim lacks nvim__ns_set; inline titles are disabled")
  end
  if #vim.api.nvim_get_runtime_file("parser/typst.*", false) > 0 then
    vim.health.ok("Typst Tree-sitter parser available")
  else
    vim.health.warn("Install the Typst Tree-sitter parser for inline titles")
  end
  if pcall(require, "snacks.picker") then
    vim.health.ok("Snacks picker available")
  else
    vim.health.error("Install snacks.nvim for :Zet search")
  end
  local clients = vim.lsp.get_clients({ name = "zettyp-lsp" })
  if require("zettypst.config").options.autostart then
    local native = vim.lsp.config["zettyp-lsp"]
    if not native or not native.cmd then
      vim.health.error("Autostart needs vim.lsp.config['zettyp-lsp'].cmd")
    end
    if not require("zettypst.config").options.root_dir then
      vim.health.warn("Autostart needs root_dir or presets.kickstart to discover a project")
    end
  end
  if #clients == 0 then
    vim.health.warn("No zettyp-lsp client running")
  end
  for _, client in ipairs(clients) do
    local commands = (client.server_capabilities.executeCommandProvider or {}).commands or {}
    if vim.tbl_contains(commands, "zettyp.evalDetached") then
      vim.health.ok("detached evaluation available")
    else
      vim.health.error("Update zettyp-lsp: zettyp.evalDetached is missing")
    end
  end
  if require("zettypst.config").options.capture then
    if vim.fn.executable("curl") == 0 then
      vim.health.error("Capture needs curl to fetch pages and papers")
    end
    if vim.fn.executable("pdftotext") == 0 then
      vim.health.warn("Install pdftotext (poppler) to read identifiers from PDF text")
    end
  end
  if not require("zettypst.config").options.entries.nodes then
    vim.health.warn("Configure entries or explicitly enable presets.kickstart")
  end
end
return M
