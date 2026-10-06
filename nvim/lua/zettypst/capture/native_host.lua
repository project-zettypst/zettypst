-- Chrome native messaging: one bounded request per isolated headless Neovim.
local function read_exact(n)
  local chunks, size = {}, 0
  while size < n do
    local chunk = io.stdin:read(n - size)
    assert(chunk and #chunk > 0, "truncated native message")
    chunks[#chunks + 1], size = chunk, size + #chunk
  end
  return table.concat(chunks)
end
local function main()
  local b = { read_exact(4):byte(1, 4) }
  local length = b[1] + b[2] * 256 + b[3] * 65536 + b[4] * 16777216
  assert(length > 0 and length <= 8 * 1024 * 1024, "native message exceeds 8 MiB")
  local payload = vim.json.decode(read_exact(length))
  local cfg = vim.json.decode(table.concat(vim.fn.readfile(assert(arg[1], "missing native config")), "\n"))
  if payload.action == "ping" then
    return { ok = true, status = "pong", root = cfg.root }
  end
  assert(
    payload.action == "capturePage" or payload.action == "capturePdfFile",
    "unsupported native capture action"
  )
  vim.opt.rtp:prepend(cfg.plugin_root)
  vim.api.nvim_set_current_dir(cfg.root)
  vim.notify = function(message)
    io.stderr:write(tostring(message) .. "\n")
  end
  cfg.options.root_dir = function()
    return cfg.root
  end
  cfg.options.autostart = true
  vim.lsp.config("zettyp-lsp", cfg.lsp)
  require("zettypst").setup(cfg.options)
  payload.from_browser = true
  payload.source_url = payload.sourceUrl or payload.source_url or payload.url
  payload.page_metadata = payload.metadata
  payload.note_metadata = payload.noteMetadata or payload.note_metadata
  local result =
    require("zettypst.capture").run(payload.action == "capturePage" and "web" or "paper", payload)
  return {
    ok = result.ok,
    error = result.error,
    status = result.status,
    kind = result.kind,
    key = result.key,
    note_path = result.note_path,
    note_id = result.note_id,
    asset_path = result.asset_path,
  }
end
local ok, result = pcall(main)
if not ok then
  result = { ok = false, error = tostring(result) }
end
for _, client in ipairs(vim.lsp.get_clients()) do
  client:stop(true)
end
local body = vim.json.encode(result)
if #body > 1024 * 1024 then
  body = vim.json.encode({ ok = false, error = "native host response exceeds 1 MiB" })
end
local n = #body
io.stdout:write(
  string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256),
  body
)
io.stdout:flush()
