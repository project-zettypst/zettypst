local M = {}
-- Resolve independently of LSP attachment, including startup/dashboard buffers.
function M.root_dir(buf)
  local resolve = require("zettypst.config").options.root_dir
  if not resolve then
    return nil
  end
  buf = buf or 0
  local path = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= "" or path == "" then
    path = vim.fn.getcwd()
  end
  local root = resolve(path)
  assert(
    root == nil or (type(root) == "string" and root ~= ""),
    "root_dir must return a non-empty path or nil"
  )
  return root and (vim.uv.fs_realpath(root) or vim.fs.normalize(vim.fn.fnamemodify(root, ":p")))
end

function M.setup(options)
  require("zettypst.config").setup(options)
  require("zettypst.snapshot").setup()
  require("zettypst.commands").setup()
  if require("zettypst.config").options.capture then
    require("zettypst.capture").setup()
  end
  require("zettypst.titles").setup()
  require("zettypst.lsp").setup()
end
return M
