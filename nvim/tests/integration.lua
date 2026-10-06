vim.opt.rtp:prepend(vim.fn.getcwd())
local root = assert(vim.env.ZETTYPST_TEST_ROOT)
local binary = assert(vim.env.ZETTYPST_TEST_LSP)
local options = vim.deepcopy(require("zettypst.presets.kickstart"))
options.titles = { enabled = false }
options.autostart = false -- This scenario exercises an externally managed client.
require("zettypst").setup(options)
vim.cmd.edit(root .. "/note/welcome.typ")
vim.bo.filetype = "typst"
local id = assert(vim.lsp.start({
  name = "zettyp-lsp",
  cmd = { binary, "--root", root, "--ignore-system-fonts" },
  root_dir = root,
  init_options = { entry = "lsp.typ" },
}))
assert(
  vim.wait(15000, function()
    local c = vim.lsp.get_client_by_id(id)
    return c and c.initialized
  end, 20),
  "LSP did not initialize"
)
vim.wait(300, function()
  return false
end, 20)
local transport = require("zettypst.transport")
local ctx = transport.context()
local nodes = require("zettypst.nodes")
local function query()
  local result = transport.eval(ctx, options.entries.nodes)
  return nodes.build(result.output["host.node"] or {}, result.revision)
end
local original = query()
assert(#original.list == 1 and original.by_id.welcome)
local executor = require("zettypst.executor")
local created = executor.run(ctx, options.entries.new, { title = 'Integration 标题 "quoted"' })
assert(created.ok, vim.inspect(created))
assert(not created.buffer_error, created.buffer_error)
local new = assert(created.nodes.list[1])
nodes.open(new.origin)
assert(vim.api.nvim_buf_get_name(0) == new.origin.source, "new origin was not opened")
assert(vim.uv.fs_stat(new.origin.source), "new file absent")
ctx.bufnr = vim.api.nvim_get_current_buf()
local index = query()
assert(#index.list == 2 and index.by_id[new.id])
-- Detached world ignores unsaved documents, while executor protects the footprint.
vim.api.nvim_buf_set_lines(0, 0, -1, false, { '#panic("unsaved")' })
vim.lsp.get_client_by_id(id):notify("textDocument/didChange", {
  textDocument = { uri = vim.uri_from_fname(new.origin.source), version = 99 },
  contentChanges = { { text = '#panic("unsaved")' } },
})
vim.wait(300, function()
  return false
end, 20)
local detached = transport.detached(ctx, options.entries.nodes, nil, vim.empty_dict())
assert(#detached.output["host.node"] == 2)
local blocked = executor.run(ctx, options.entries.delete, { id = new.id })
assert(not blocked.ok and blocked.error:find("unsaved buffer"), vim.inspect(blocked))
assert(vim.uv.fs_stat(new.origin.source))
vim.cmd("edit!")
vim.wait(300, function()
  return false
end, 20)
local deleted = executor.run(ctx, options.entries.delete, { id = new.id })
assert(deleted.ok, vim.inspect(deleted))
assert(not deleted.buffer_error, deleted.buffer_error)
assert(not vim.uv.fs_stat(new.origin.source))
assert(not vim.uv.fs_stat(root .. "/.zettypst/host.lock"))
-- Query through the still-live client after delete closed its buffer.
ctx.bufnr = nil
local result = transport.eval(ctx, options.entries.nodes)
assert(#result.output["host.node"] == 1 and result.output["host.node"][1].id == "welcome")
vim.lsp.get_client_by_id(id):stop(true)
print("passed real LSP query/create/delete, detached overlay and dirty-buffer integration")
