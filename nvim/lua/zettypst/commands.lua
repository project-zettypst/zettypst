local M = {}
function M.context()
  local buf = vim.api.nvim_get_current_buf()
  local client = require("zettypst.lsp").ensure(buf)
  if client and not client.initialized then
    local ready = vim.wait(require("zettypst.config").options.timeout, function()
      return client.initialized or client:is_stopped()
    end, 10)
    assert(ready and not client:is_stopped(), "zettyp-lsp initialization failed or timed out")
  end
  local transport = require("zettypst.transport")
  local nodes = require("zettypst.nodes")
  local ctx = transport.context(buf)
  ctx.index = require("zettypst.snapshot").current(ctx)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  local position = { line = cursor[1] - 1, character = vim.str_utfindex(line, "utf-16", cursor[2], false) }
  local name = vim.api.nvim_buf_get_name(0)
  ctx.current = nodes.current(ctx.index, vim.uv.fs_realpath(name) or name, position)
  return ctx
end
local function report(result)
  if result.ok then
    if result.buffer_error then
      vim.notify(result.buffer_error, vim.log.levels.WARN)
    end
    local node = result.nodes.list[1]
    local opened, err = pcall(function()
      return node and require("zettypst.nodes").open(node.origin)
    end)
    if not opened then
      vim.notify(tostring(err), vim.log.levels.WARN)
    end
    return
  end
  local message = result.error
  if result.undo and #result.undo > 0 then
    message = message
      .. "\n"
      .. (result.rollback_error or "rollback incomplete")
      .. "\nRemaining undo log (execution order):\n"
      .. vim.inspect(result.undo)
  end
  vim.notify(message, vim.log.levels.ERROR)
end
function M.dispatch(name, args)
  local options = require("zettypst.config").options
  local ok, reason = pcall(function()
    local ctx = M.context()
    ctx.args = args
    if name == "search" then
      require("zettypst.picker").open(ctx.index, options.picker)
      return
    end
    local action = assert(options.actions[name], "configure actions." .. name .. ".collect first")
    local entry = assert(options.entries[name], "configure entries." .. name .. " first")
    local collected = false
    action.collect(ctx, function(request)
      if collected then
        return
      end
      collected = true
      if request == nil then
        return
      end
      local success, result = pcall(require("zettypst.executor").run, ctx, entry, request)
      if success then
        report(result)
      else
        vim.notify(tostring(result), vim.log.levels.ERROR)
      end
    end)
  end)
  if not ok then
    vim.notify(tostring(reason), vim.log.levels.ERROR)
  end
end
local subcommands = {}
-- Optional modules add their own subcommands during setup.
function M.register(name, run, choices)
  subcommands[name] = { run = run, choices = choices or {} }
end
function M.setup()
  subcommands = {}
  for _, name in ipairs({ "search", "new", "delete" }) do
    M.register(name, function(args)
      M.dispatch(name, args)
    end)
  end
  vim.api.nvim_create_user_command("Zet", function(args)
    local subcommand = subcommands[args.fargs[1]]
    if not subcommand then
      local names = vim.tbl_keys(subcommands)
      table.sort(names)
      vim.notify("use :Zet " .. table.concat(names, "|"), vim.log.levels.ERROR)
      return
    end
    local ok, err = pcall(subcommand.run, vim.list_slice(args.fargs, 2))
    if not ok then
      vim.notify(tostring(err), vim.log.levels.ERROR)
    end
  end, {
    nargs = "+",
    force = true,
    complete = function(lead, line, position)
      local words = vim.split(line:sub(1, position), "%s+")
      local choices = #words == 2 and vim.tbl_keys(subcommands)
        or #words == 3 and subcommands[words[2]] and subcommands[words[2]].choices
        or {}
      table.sort(choices)
      return vim.tbl_filter(function(item)
        return vim.startswith(item, lead)
      end, choices)
    end,
  })
end
return M
