local M = {}

-- Runs curl restricted to HTTP(S), including redirects; returns stdout or nil, error.
local function curl(url, opts, extra)
  assert(type(url) == "string" and url:match("^https?://"), "expected an HTTP(S) URL")
  opts = opts or {}
  local args = {
    "curl",
    "--silent",
    "--show-error",
    "--fail",
    "--location",
    "--proto",
    "=http,https",
    "--proto-redir",
    "=http,https",
    "--max-time",
    tostring(opts.timeout or 20),
    "--user-agent",
    "zettypst.nvim/0.1",
  }
  for _, header in ipairs(opts.headers or {}) do
    vim.list_extend(args, { "--header", header })
  end
  vim.list_extend(args, extra or {})
  vim.list_extend(args, { "--", url })
  local result = vim.system(args, { text = true }):wait()
  if result.code ~= 0 then
    return nil, vim.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
  end
  return result.stdout or ""
end

function M.text(url, opts)
  return curl(url, opts)
end

function M.download(url, path, opts)
  local ok, err = curl(url, opts, { "--output", path })
  return ok and path, err
end

return M
