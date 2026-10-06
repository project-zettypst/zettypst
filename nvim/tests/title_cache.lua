vim.opt.rtp:prepend(vim.fn.getcwd())
local titles = require("zettypst.titles")
local config = require("zettypst.config")
local transport = require("zettypst.transport")
local snapshot = require("zettypst.snapshot")
local original = {
  context = transport.context,
  eval = transport.eval_async,
  sync = transport.eval,
  client = vim.lsp.get_client_by_id,
  clients = vim.lsp.get_clients,
  notify = vim.notify,
}
local pending, clients, owners, notices, created = {}, {}, {}, {}, {}
local function client(id)
  local c = { id = id, attached_buffers = {}, stopped = false, cancelled = {} }
  function c:is_stopped()
    return self.stopped
  end
  function c:cancel_request(request)
    self.cancelled[request] = true
  end
  clients[id] = c
  return c
end
local a, b = client(9001), client(9002)
vim.lsp.get_client_by_id = function(id)
  return clients[id]
end
vim.lsp.get_clients = function()
  return {}
end
vim.notify = function(message)
  notices[#notices + 1] = message
end
transport.context = function(buf)
  local c = assert(owners[buf], "unattached")
  return { client = c, root = "/project-" .. c.id, bufnr = buf }
end
transport.eval_async = function(ctx, entry, done)
  pending[#pending + 1] = { ctx = ctx, entry = entry, done = done }
  return true, #pending
end
local function pause()
  vim.wait(260, function()
    return false
  end, 10)
end
local function buffer(c)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "typst"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "See @one" })
  owners[buf] = c
  c.attached_buffers[buf] = true
  created[#created + 1] = buf
  return buf
end
local function show(buf)
  vim.api.nvim_set_current_buf(buf)
  vim.wo.conceallevel, vim.wo.concealcursor = 2, "niv"
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  snapshot.attach(buf)
  titles.redraw()
end
local function displayed(buf, win)
  win = win or vim.api.nvim_get_current_win()
  local ns = titles.namespace(win)
  local marks = ns and vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }) or {}
  for _, mark in ipairs(marks) do
    if mark[4].virt_text then
      return mark[4].virt_text[1][1]
    end
  end
end
local function deliver(title)
  pending[#pending].done(nil, {
    revision = #pending,
    output = {
      ["host.node"] = {
        {
          id = "one",
          title = title,
          metadata = {},
          origin = {
            source = "/project/one.typ",
            ["range-utf16"] = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } },
          },
        },
      },
    },
  })
end
local seen = 0
-- Asserts how many evaluations the preceding step issued after the debounce.
local function requested(n, why)
  pause()
  assert(#pending - seen == n, ("%s: expected %d requests, got %d"):format(why, n, #pending - seen))
  seen = #pending
end
local ok, err = pcall(function()
  config.setup({ entries = { nodes = "nodes.typ" } })
  snapshot.setup()
  titles.setup()
  local first, second = buffer(a), buffer(a)
  show(first)
  requested(1, "first buffer")
  show(second)
  requested(0, "new buffer must join the in-flight request")
  deliver("Original")
  assert(displayed(second) == "@Original")
  show(first)
  assert(displayed(first) == "@Original", "existing buffers share delivered titles immediately")
  local third = buffer(a)
  show(third)
  assert(displayed(third) == "@Original", "new buffer must use warm snapshot immediately")
  requested(0, "BufEnter must not evaluate a clean project")
  vim.cmd.vsplit()
  local split = vim.api.nvim_get_current_win()
  requested(0, "opening a split must not evaluate")

  vim.api.nvim_buf_set_lines(first, 0, 1, false, { "Changed @one" })
  vim.api.nvim_buf_set_lines(second, 0, 1, false, { "Also changed @one" })
  requested(1, "rapid changes across buffers coalesce")
  assert(displayed(third) == "@Original", "refresh must keep successful titles")
  vim.api.nvim_buf_set_lines(first, 0, 1, false, { "Latest @one" })
  requested(0, "only one request may be in flight")
  deliver("Stale")
  assert(displayed(third) == "@Original", "a superseded response must not install")
  requested(1, "a superseded response re-requests")
  deliver("Updated")
  assert(displayed(third) == "@Updated")
  show(first)
  assert(displayed(first) == "@Updated", "update must reach all buffers")

  snapshot.refresh(first)
  requested(1, "explicit refresh")
  pending[#pending].done("evaluation failed", nil, -32001)
  assert(displayed(first) == "@Updated" and #notices == 1, "failures keep titles and report once")
  show(second)
  assert(displayed(second) == "@Updated")
  requested(0, "failed refresh must not restart on window navigation")
  snapshot.refresh(second)
  requested(1, "explicit refresh after failure")
  pending[#pending].done("source changed", nil, transport.CONTENT_MODIFIED)
  requested(1, "ContentModified retries at project scope")
  deliver("Recovered")

  local other = buffer(b)
  show(other)
  requested(1, "another client evaluates its own project")
  assert(displayed(other) == nil, "another client must not inherit titles")
  deliver("Other project")
  show(second)
  assert(displayed(second) == "@Recovered")
  snapshot.refresh_root("/project-9001")
  requested(1, "a transaction invalidates only its project")
  deliver("After transaction")
  assert(displayed(second) == "@After transaction")
  vim.api.nvim_win_close(split, true)

  -- Live clients retain their snapshot after the last buffer closes.
  for _, buf in ipairs({ first, second, third }) do
    owners[buf] = nil
    a.attached_buffers[buf] = nil
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  requested(1, "removed overlays refresh the project without an attachment")
  local reopened = buffer(a)
  show(reopened)
  assert(displayed(reopened) == "@After transaction")
  requested(0, "reopening joins the overlay-removal refresh")
  -- Stopping the client drops its cache and ignores its pending response.
  a.stopped = true
  vim.api.nvim_exec_autocmds("LspDetach", { buffer = reopened, data = { client_id = a.id } })
  vim.wait(20, function()
    return false
  end)
  deliver("Too late")
  assert(displayed(reopened) == nil)

  -- A configuration switch must not reuse a different entry's snapshot.
  config.setup({ entries = { nodes = "other.typ" } })
  snapshot.setup()
  titles.setup()
  show(other)
  requested(1, "a new entry evaluates")
  assert(pending[#pending].entry == "other.typ" and displayed(other) == nil)
  deliver("Different entry")
  assert(displayed(other) == "@Different entry")

  -- Commands consume the same index, not a second revision cache.
  local ctx = transport.context(other)
  transport.eval = function()
    error("a warm command must not evaluate")
  end
  assert(snapshot.current(ctx) == snapshot.get(other))
  snapshot.refresh(other)
  requested(1, "refresh before a command")
  transport.eval = function()
    return {
      revision = 100,
      output = {
        ["host.node"] = {
          {
            id = "one",
            title = "Command result",
            metadata = {},
            origin = {
              source = "/project/one.typ",
              ["range-utf16"] = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } },
            },
          },
        },
      },
    }
  end
  local command_index = snapshot.current(ctx)
  assert(command_index == snapshot.get(other))
  assert(displayed(other) == "@Command result")
  deliver("Cancelled response")
  assert(snapshot.get(other) == command_index, "cancelled refresh must not overwrite the command result")

  -- Disabling titles must not disable command snapshot tracking.
  config.setup({ entries = { nodes = "other.typ" }, titles = { enabled = false } })
  snapshot.setup()
  titles.setup()
  assert(snapshot.current(ctx) == snapshot.get(other))
  vim.api.nvim_buf_set_lines(other, 0, -1, false, { "Unsaved edit @one" })
  local calls = 0
  local evaluate = transport.eval
  transport.eval = function(...)
    calls = calls + 1
    return evaluate(...)
  end
  snapshot.current(ctx)
  assert(calls == 1, "commands must refresh after edits even with titles disabled")
end)
config.setup({})
snapshot.setup()
titles.setup()
for _, buf in ipairs(created) do
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end
transport.context, transport.eval_async, transport.eval = original.context, original.eval, original.sync
vim.lsp.get_client_by_id, vim.lsp.get_clients, vim.notify = original.client, original.clients, original.notify
assert(ok, err)
print("passed shared snapshots, coalescing, stale rejection, failures, project isolation and lifecycle")
