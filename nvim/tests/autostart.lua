vim.opt.rtp:prepend(vim.fn.getcwd())
local root = assert(vim.env.ZETTYPST_TEST_ROOT)
local other_root = assert(vim.env.ZETTYPST_TEST_OTHER_ROOT)
local binary = assert(vim.env.ZETTYPST_TEST_LSP)
local plugin = require("zettypst")
local transport = require("zettypst.transport")
local snapshot = require("zettypst.snapshot")
local commands = require("zettypst.commands")
local lsp = require("zettypst.lsp")
local options = vim.deepcopy(require("zettypst.presets.kickstart"))
options.titles = { enabled = false }
local inits, attaches, evaluations, exits = 0, 0, 0, 0
local evaluate = transport.eval_async
transport.eval_async = function(...)
  evaluations = evaluations + 1
  return evaluate(...)
end
vim.lsp.config("zettyp-lsp", {
  cmd = { binary, "--ignore-system-fonts" },
  filetypes = { "typst" },
  init_options = { entry = "lsp.typ" },
  on_init = function()
    inits = inits + 1
  end,
  on_attach = function()
    attaches = attaches + 1
  end,
  on_exit = function()
    exits = exits + 1
  end,
})
local function wait(check, message)
  assert(vim.wait(15000, check, 10), message)
end
local function context()
  local ok, ctx = pcall(transport.context)
  return ok and ctx or nil
end
local function settle()
  vim.wait(300, function()
    return false
  end, 10)
end

-- No matching project: no server, even with autostart enabled.
vim.api.nvim_set_current_dir(vim.fs.dirname(root))
plugin.setup(options)
settle()
assert(#vim.lsp.get_clients({ name = "zettyp-lsp" }) == 0)

-- DirChanged on an unnamed startup buffer starts a project, without didOpen.
vim.api.nvim_set_current_dir(root)
local starting = assert(lsp.ensure())
for _ = 1, 3 do
  assert(lsp.ensure().id == starting.id, "pending startup must reuse one client")
end
wait(function()
  return context() ~= nil and evaluations > 0
end, "project was not started and prewarmed")
local ctx = transport.context()
local first = ctx.client
assert(next(first.attached_buffers) == nil, "startup buffer must not attach")
assert(inits == 1 and attaches == 0, "native hooks must be preserved")
local index = snapshot.current(ctx) -- Supersedes a still-pending prewarm.
assert(index.by_id.welcome and evaluations == 1)

-- Once warm, search must read the project cache with no sync evaluation.
local sync = transport.eval
transport.eval = function()
  error("warm search unexpectedly evaluated")
end
local opened
local picker = require("zettypst.picker")
local open = picker.open
picker.open = function(nodes)
  opened = nodes
end
commands.dispatch("search")
assert(opened == index, "search on a startup buffer must use the warmed index")
picker.open = open
transport.eval = sync

-- Repeat setup/start while live; reuse one process and initialize hooks once.
for _ = 1, 3 do
  assert(lsp.ensure().id == first.id)
end
assert(evaluations == 1)
plugin.setup(options)
settle()
assert(lsp.ensure().id == first.id and inits == 1)

-- A real note attaches to the prestarted process. Later native start reuses it.
vim.cmd.edit(root .. "/note/welcome.typ")
vim.bo.filetype = "typst"
wait(function()
  return first.attached_buffers[vim.api.nvim_get_current_buf()]
end, "note did not attach")
local cfg = vim.deepcopy(vim.lsp.config["zettyp-lsp"])
cfg.name, cfg.root_dir = "zettyp-lsp", root
assert(vim.lsp.start(cfg) == first.id)
assert(attaches == 1 and #vim.lsp.get_clients({ name = "zettyp-lsp" }) == 1)
local project = snapshot.attach(vim.api.nvim_get_current_buf())

-- Switching projects on a dashboard selects the right client and cache.
local dashboard = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(dashboard, "zettyp-test-dashboard")
vim.api.nvim_set_current_buf(dashboard)
vim.api.nvim_set_current_dir(other_root)
local second = lsp.ensure()
assert(second.id ~= first.id)
local second_ctx = commands.context() -- An immediate command waits for initialization.
assert(second_ctx.client.id == second.id and second_ctx.root == other_root)
assert(second_ctx.index.by_id.welcome)
assert(next(second.attached_buffers) == nil)
vim.api.nvim_set_current_dir(root)
assert(commands.context().client.id == first.id)

-- Closing the last note keeps the client's workspace useful for dashboard search.
for buf in pairs(first.attached_buffers) do
  vim.api.nvim_buf_delete(buf, { force = true })
end
settle()
assert(commands.context().index.by_id.welcome)
assert(next(first.attached_buffers) == nil)

-- With no buffers left, on_exit must release the project without LspDetach or focus events.
first:stop(true)
wait(function()
  return project.timer:is_closing()
end, "unattached client's snapshot timer was not closed")
assert(exits == 1 and not second:is_stopped(), "exit hooks and other projects must be preserved")

-- Disabling autostart removes startup hooks; externally managed clients remain.
options.autostart = false
plugin.setup(options)
assert(lsp.ensure() == nil)
assert(not second:is_stopped())
second:stop(true)
wait(function()
  return #vim.lsp.get_clients({ name = "zettyp-lsp" }) == 0
end, "clients did not stop")
vim.api.nvim_set_current_dir(other_root)
settle()
assert(#vim.lsp.get_clients({ name = "zettyp-lsp" }) == 0)

-- A freshly enabled cold command starts the LSP and obtains its nodes.
options.autostart = true
plugin.setup(options)
local cold = commands.context()
assert(cold.root == other_root and cold.index.by_id.welcome)
assert(inits == 3)
cold.client:stop(true)
print("passed real LSP autostart, warm startup search, attachment reuse, project isolation and cold commands")
