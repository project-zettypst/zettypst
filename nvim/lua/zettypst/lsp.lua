local M = {}
local last_error

-- Chains the native hook: a client started here is warmed once it can answer.
-- Reused clients keep their hooks; snapshot warms their buffers on LspAttach.
local function on_init(hook)
  return function(client, result)
    for _, f in ipairs(type(hook) == "table" and hook or { hook }) do
      f(client, result)
    end
    vim.schedule(function()
      require("zettypst.snapshot").warm(client)
    end)
  end
end

function M.ensure(buf)
  if not require("zettypst.config").options.autostart then
    return
  end
  buf = (not buf or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local root = require("zettypst").root_dir(buf)
  if not root then
    return
  end
  local native = vim.lsp.config["zettyp-lsp"]
  assert(native and native.cmd, "configure vim.lsp.config['zettyp-lsp'].cmd before enabling autostart")
  local cfg = vim.deepcopy(native)
  cfg.name, cfg.root_dir = "zettyp-lsp", root
  -- The discovered project, not any static workspace from the native config,
  -- owns this client and its evaluated node index.
  cfg.workspace_folders = { { uri = vim.uri_from_fname(root), name = root } }
  cfg.on_init = on_init(cfg.on_init)
  -- A dashboard client can exit without ever emitting LspDetach.
  cfg.on_exit = vim.list_extend({
    function(_, _, client_id)
      vim.schedule(function()
        require("zettypst.snapshot").drop(client_id)
      end)
    end,
  }, type(cfg.on_exit) == "table" and cfg.on_exit or { cfg.on_exit })
  local attach = vim.bo[buf].buftype == ""
    and vim.api.nvim_buf_get_name(buf) ~= ""
    and vim.tbl_contains(cfg.filetypes or { "typst" }, vim.bo[buf].filetype)
  local id = assert(
    vim.lsp.start(cfg, {
      bufnr = buf,
      attach = attach,
      reuse_client = function(client)
        local client_root = client.config.root_dir or client.root_dir
        return client.name == cfg.name
          and not client:is_stopped()
          and client_root ~= nil
          and (vim.uv.fs_realpath(client_root) or client_root) == root
      end,
    }),
    "could not start zettyp-lsp"
  )
  return assert(vim.lsp.get_client_by_id(id))
end

function M.setup()
  last_error = nil
  local group = vim.api.nvim_create_augroup("ZetTypstLsp", { clear = true })
  if not require("zettypst.config").options.autostart then
    return
  end
  local function start()
    local ok, err = pcall(M.ensure)
    if ok then
      last_error = nil
    elseif err ~= last_error then
      last_error = err
      vim.notify("Zet: " .. tostring(err), vim.log.levels.WARN)
    end
  end
  vim.api.nvim_create_autocmd({ "BufEnter", "FileType", "DirChanged" }, { group = group, callback = start })
  vim.schedule(start)
end

return M
