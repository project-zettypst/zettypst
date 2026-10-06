local M = {}
local function plugin_root()
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))))
end
function M.extension_path()
  return plugin_root() .. "/chrome/zettypst-capture"
end
function M.extension_id()
  local manifest =
    vim.json.decode(table.concat(vim.fn.readfile(M.extension_path() .. "/manifest.json"), "\n"))
  local hash = vim.fn.sha256(vim.base64.decode(manifest.key)):sub(1, 32)
  return (hash:gsub(".", function(c)
    return string.char(97 + tonumber(c, 16))
  end))
end
local function write(path, value, mode)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = assert(vim.uv.fs_open(path, "w", mode or 384))
  local ok, err = pcall(function()
    assert(vim.uv.fs_write(fd, value, 0) == #value)
  end)
  vim.uv.fs_close(fd)
  assert(ok, err)
  assert(vim.uv.fs_chmod(path, mode or 384))
end
function M.install(extension_id)
  extension_id = extension_id or M.extension_id()
  assert(extension_id:match("^[a-p]+$") and #extension_id == 32, "invalid Chrome extension ID")
  local options = require("zettypst.config").options
  assert(options.capture, "capture is not enabled")
  local root = options.capture.browser.root or require("zettypst").root_dir()
  assert(root, "choose a capture project or configure capture.browser.root")
  root = assert(vim.uv.fs_realpath(vim.fn.expand(root)), "capture root does not exist")
  assert(
    vim.fn.filereadable(root .. "/" .. assert(options.entries.capture, "configure entries.capture")) == 1,
    "install capture host entries in the project first"
  )
  local native = assert(vim.lsp.config["zettyp-lsp"], "configure native zettyp-lsp first")
  assert(type(native.cmd) == "table", "native messaging needs an executable LSP command")
  local lsp = {}
  for _, key in ipairs({ "cmd", "cmd_env", "init_options", "settings", "capabilities", "offset_encoding" }) do
    lsp[key] = vim.deepcopy(native[key])
  end
  lsp.cmd[1] = vim.fn.exepath(vim.fn.expand(lsp.cmd[1]))
  assert(lsp.cmd[1] ~= "", "zettyp-lsp executable was not found")
  local capture = vim.deepcopy(options.capture)
  capture.templates = nil -- Lua hooks belong to interactive config; project templates run in both hosts.
  local dir = vim.fn.stdpath("data") .. "/zettypst-capture"
  local cfgpath = dir .. "/config.json"
  write(
    cfgpath,
    vim.json.encode({
      root = root,
      plugin_root = plugin_root(),
      lsp = lsp,
      options = {
        entries = options.entries,
        capture = capture,
        timeout = options.timeout,
        titles = { enabled = false },
      },
    })
  )
  local launcher = dir .. "/native-host"
  local nvim = vim.fn.exepath(vim.v.progpath)
  write(
    launcher,
    "#!/bin/sh\nexec "
      .. vim.fn.shellescape(nvim)
      .. " --headless -u NONE -i NONE -n -l "
      .. vim.fn.shellescape(plugin_root() .. "/lua/zettypst/capture/native_host.lua")
      .. " "
      .. vim.fn.shellescape(cfgpath)
      .. "\n",
    448
  )
  local system = vim.uv.os_uname().sysname
  local manifests = system == "Darwin"
      and vim.fn.expand("~/Library/Application Support/Google/Chrome/NativeMessagingHosts")
    or system == "Linux" and vim.fn.expand("~/.config/google-chrome/NativeMessagingHosts")
  assert(manifests, "native-host installer currently supports macOS and Linux")
  local name = options.capture.browser.host_name
  local path = manifests .. "/" .. name .. ".json"
  write(
    path,
    vim.json.encode({
      name = name,
      description = "ZetTypst Capture",
      path = launcher,
      type = "stdio",
      allowed_origins = { "chrome-extension://" .. extension_id .. "/" },
    })
  )
  return {
    manifest_path = path,
    config_path = cfgpath,
    launcher_path = launcher,
    extension_path = M.extension_path(),
    extension_id = extension_id,
  }
end
return M
