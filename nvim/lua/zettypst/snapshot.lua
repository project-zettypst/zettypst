-- One live node index per LSP client and nodes entry.
--
-- Every edit bumps `changes`. A debounced request records the count it saw in
-- `sent`; its response installs `index` (and sets `fresh` to that count) only
-- if no edit arrived meanwhile. While `sent == changes` the latest state was
-- already requested, so a failed refresh waits for the next edit to retry.
--
-- Projects live as long as their client, not their buffers: closing every note
-- or regaining focus still refreshes the index that dashboard commands use.
local M = {}
local transport = require("zettypst.transport")
local nodes = require("zettypst.nodes")
local config = require("zettypst.config")
local DEBOUNCE = 200
local projects, owners, watched = {}, {}, {}

local function changed()
  vim.api.nvim_exec_autocmds("User", { pattern = "ZetNodesChanged", modeline = false })
end

local function alive(p)
  return projects[p.key] == p
    and vim.lsp.get_client_by_id(p.client.id) == p.client
    and not p.client:is_stopped()
end

local function discard(p)
  projects[p.key] = nil
  p.timer:stop()
  p.timer:close()
  if p.inflight then
    p.client:cancel_request(p.inflight)
  end
  for buf, owner in pairs(owners) do
    if owner == p then
      owners[buf] = nil
    end
  end
end

local function prune()
  for _, p in pairs(projects) do
    if not alive(p) then
      discard(p)
    end
  end
  changed()
end

function M.drop(client_id)
  for _, p in pairs(projects) do
    if p.client.id == client_id then
      discard(p)
    end
  end
  changed()
end

local function report(p, message)
  if p.error ~= message then
    p.error = message
    vim.notify("Zet nodes: " .. message, vim.log.levels.WARN)
  end
end

local request
local function schedule(p)
  if not p.timer:is_closing() then
    p.timer:stop()
    p.timer:start(
      DEBOUNCE,
      0,
      vim.schedule_wrap(function()
        request(p)
      end)
    )
  end
end

local function invalidate(p)
  p.changes = p.changes + 1
  schedule(p)
end

local function accept(p, tag, err, result, code)
  if tag ~= p.changes then
    schedule(p) -- Superseded responses, including failures, cannot settle newer edits.
  elseif err then
    if code == transport.CONTENT_MODIFIED then
      invalidate(p)
    else
      report(p, err) -- Keep the last successful index.
    end
  else
    local ok, index = pcall(nodes.build, result.output["host.node"] or {}, result.revision)
    if not ok then
      report(p, tostring(index))
      return
    end
    p.index, p.fresh, p.error = index, tag, nil
    changed()
  end
end

request = function(p)
  if not alive(p) then
    return prune()
  end
  if p.inflight or p.sent == p.changes then
    return
  end
  local tag, id = p.changes, nil
  local accepted
  accepted, id = transport.eval_async({ client = p.client }, p.entry, function(err, result, code)
    if alive(p) and p.inflight == id then
      p.inflight = nil
      accept(p, tag, err, result, code)
    end
  end)
  if not accepted then
    return report(p, "evaluation request could not be sent")
  end
  p.sent, p.inflight = tag, id
  vim.defer_fn(function()
    if alive(p) and p.inflight == id then
      p.inflight = nil
      p.client:cancel_request(id)
      report(p, "evaluation timed out; keeping the last index")
      if tag ~= p.changes then
        schedule(p)
      end
    end
  end, config.options.timeout)
end

local function project(ctx)
  local entry = config.options.entries.nodes
  if not entry then
    return
  end
  local key = ctx.client.id .. ":" .. entry
  local p = projects[key]
  if not p then
    p = {
      key = key,
      client = ctx.client,
      root = ctx.root,
      entry = entry,
      changes = 0,
      timer = vim.uv.new_timer(),
    }
    projects[key] = p
  end
  return p
end

function M.warm(client)
  local p = project({ client = client, root = transport.root(client) })
  if p then
    request(p)
  end
end

function M.attach(buf, refresh)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  if not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  local ok, ctx = pcall(transport.context, buf)
  if not ok or not ctx.client.attached_buffers[buf] then
    return
  end
  local p = project(ctx)
  if not p then
    return
  end
  local previous = owners[buf]
  owners[buf] = p
  if previous ~= p and vim.bo[buf].modified then
    invalidate(p) -- A newly attached unsaved overlay can supersede a disk-only index.
  end
  if not watched[buf] then
    watched[buf] = true
    local function touched()
      if owners[buf] then
        invalidate(owners[buf])
      end
    end
    vim.api.nvim_buf_attach(buf, false, {
      on_lines = touched,
      on_reload = touched,
      on_detach = function()
        touched() -- Removing an overlay can change the project.
        watched[buf], owners[buf] = nil, nil
      end,
    })
  end
  if refresh ~= false and p.sent ~= p.changes then
    schedule(p)
  end
  return p
end

function M.get(buf)
  return owners[buf] and owners[buf].index
end

-- Commands need the current index; reuse the live one unless edits outran it.
function M.current(ctx)
  local entry = assert(config.options.entries.nodes, "configure entries.nodes first")
  M.attach(ctx.bufnr or 0, false)
  local p = project(ctx)
  if p and p.index and p.fresh == p.changes then
    return p.index
  end
  local tag = p and p.changes
  if p then
    p.timer:stop()
    local pending = p.inflight
    p.inflight = nil
    if pending then
      p.client:cancel_request(pending)
    end
  end
  local result = transport.eval(ctx, entry)
  local index = nodes.build(result.output["host.node"] or {}, result.revision)
  if p and alive(p) and tag == p.changes then
    p.index, p.fresh, p.sent, p.error = index, tag, tag, nil
    changed()
  end
  return index
end

function M.refresh(buf)
  if owners[buf] then
    invalidate(owners[buf])
  end
end

-- Committed transactions change files without buffer events.
function M.refresh_root(root)
  for _, p in pairs(projects) do
    if p.root == root then
      invalidate(p)
    end
  end
end

function M.setup()
  for _, p in pairs(projects) do
    discard(p)
  end
  changed()
  local group = vim.api.nvim_create_augroup("ZetTypstSnapshot", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "LspAttach" }, {
    group = group,
    callback = function(args)
      M.attach(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      for _, p in pairs(projects) do
        invalidate(p)
      end
    end,
  })
  vim.api.nvim_create_autocmd("LspDetach", {
    group = group,
    callback = function(args)
      local p = owners[args.buf]
      if p and p.client.id == args.data.client_id then
        owners[args.buf] = nil
        invalidate(p)
        vim.schedule(prune)
      end
    end,
  })
  for _, client in ipairs(vim.lsp.get_clients({ name = "zettyp-lsp" })) do
    for buf in pairs(client.attached_buffers) do
      M.attach(buf)
    end
  end
end
return M
