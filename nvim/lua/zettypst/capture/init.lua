local M = {}
local bib = require("zettypst.capture.bib")
local assets = require("zettypst.capture.assets")
local config = require("zettypst.config")
local function text(value)
  return type(value) == "string" and vim.trim(value) or ""
end
local function url(value)
  value = text(value)
  assert(value:match("^https?://"), "capture requires an HTTP(S) URL")
  return value
end
local function optional_read(path)
  if not vim.uv.fs_stat(path) then
    return nil
  end
  return assert(assets.read(path))
end
-- A failed lookup falls back to weaker metadata; say so instead of guessing silently.
local function resolve(context)
  local resolved, warnings = require("zettypst.capture.translator").resolve(context)
  for _, warning in ipairs(warnings) do
    vim.notify("Zet capture: " .. warning, vim.log.levels.WARN)
  end
  return resolved
end
local function bibliography_path()
  local path = assert(config.options.capture.bibliography.path, "configure capture.bibliography.path")
  return require("zettypst.executor").path(path)
end
local function dictionary(value)
  return next(value) and value or vim.empty_dict()
end

-- Parsing is mechanical; the project's Typst plan decides identity, keys and merging.
local function bibliography(ctx, entry)
  local path = bibliography_path()
  local before = optional_read(ctx.root .. "/" .. path)
  local entries = {}
  for _, old in ipairs(bib.parse_text(before or "")) do
    entries[#entries + 1] = {
      key = old.key,
      fields = dictionary(old.fields),
      start = old.start_offset - 1,
      ["end"] = old.end_offset,
    }
  end
  return {
    path = path,
    before = before or vim.NIL,
    entries = entries,
    entry = { type = entry.type or "misc", key = entry.key, fields = dictionary(entry.fields) },
  }
end

-- Returns the host request and, for papers, the metadata translator that filled it.
function M.prepare(ctx, kind, payload)
  payload = payload or {}
  local translator
  local opts = assert(config.options.capture, "capture is not enabled")
  local req = {
    kind = kind,
    title = text(payload.title),
    abstract = text(payload.abstract),
    keywords = {},
    selection = text(payload.selection),
    url = "",
    metadata = payload.note_metadata or vim.empty_dict(),
  }
  if kind == "web" then
    req.url = url(payload.url)
    local meta = payload.metadata or {}
    local html = payload.html
    if not payload.from_browser and opts.fetch.manual and not html then
      local err
      html, err = require("zettypst.capture.http").text(req.url)
      assert(html, err)
    end
    local resolved = resolve({ url = req.url, html = html, metadata = meta })
    local fields = resolved and resolved.entry.fields or {}
    req.url = text(meta.canonicalUrl) ~= "" and url(meta.canonicalUrl) or req.url
    req.title = req.title ~= "" and req.title or text(fields.title or meta.title)
    if req.title == "" and html then
      req.title = text(html:match("<title[^>]*>(.-)</title>"))
    end
    if req.title == "" then
      req.title = req.url
    end
    req.abstract = req.abstract ~= "" and req.abstract or text(fields.abstract or meta.description)
    req.selection = req.selection ~= "" and req.selection or text(meta.selection)
    req.keywords = bib.split_words(payload.keywords or meta.keywords)
    if payload.keywords == nil and #req.keywords == 0 and resolved then
      req.keywords = resolved.keywords
    end
  else
    assert(kind == "paper" or kind == "paper-note", "unknown capture kind")
    local entry, resolved
    if kind == "paper-note" then
      local key = text(payload.key):gsub("^@", "")
      local path = bibliography_path()
      for _, candidate in ipairs(bib.parse_text(optional_read(ctx.root .. "/" .. path) or "")) do
        if candidate.key == key then
          entry = candidate
          break
        end
      end
      assert(entry, "No bibliography entry for @" .. key)
      local file = text(entry.fields.file)
      if file ~= "" then
        local source = file:match("^/") and file or ctx.root .. "/" .. file
        if vim.uv.fs_stat(source) then
          req.asset = assets.store(ctx.root, source)
        end
      end
    else
      local source = text(payload.path)
      local source_url = text(payload.source_url or payload.sourceUrl or payload.url)
      if source == "" then
        assert(opts.fetch.paper, "paper URL fetch is disabled")
        source_url = url(source_url)
        local temp = vim.fn.tempname() .. ".pdf"
        local ok, err = pcall(function()
          assert(require("zettypst.capture.http").download(source_url, temp, { timeout = 60 }))
          req.asset = assets.store(ctx.root, temp)
        end)
        vim.uv.fs_unlink(temp)
        assert(ok, err)
        source = ctx.root .. "/" .. req.asset.path
      else
        req.asset = assets.store(ctx.root, source)
      end
      resolved = resolve({
        file = vim.fn.expand(source),
        url = source_url,
        title = req.title,
        bibtex = payload.bibtex,
        metadata = payload.page_metadata or payload.metadata,
        html = payload.html,
      })
      entry = resolved and resolved.entry or { type = "misc", fields = {} }
      entry.fields.title = text(entry.fields.title) ~= "" and entry.fields.title
        or (req.title ~= "" and req.title or vim.fn.fnamemodify(source, ":t:r"))
      if source_url ~= "" and text(entry.fields.url) == "" then
        entry.fields.url = source_url
      end
      entry.key = text(payload.key) ~= "" and payload.key or entry.key or bib.derive_key(entry.fields)
    end
    if req.title == "" then
      req.title = bib.clean_title(entry.fields.title or entry.key)
    end
    req.abstract = req.abstract ~= "" and req.abstract or text(entry.fields.abstract)
    req.keywords =
      bib.split_words(payload.keywords or (resolved and resolved.keywords) or entry.fields.keywords)
    req.bibliography = bibliography(ctx, entry)
    req.url = text(entry.fields.url)
    translator = resolved and resolved.translator
  end
  local hook = opts.templates[kind]
  if hook then
    req = vim.tbl_deep_extend("force", req, hook(vim.deepcopy(req), ctx) or {})
  end
  return req, translator
end

function M.run(kind, payload, ctx)
  ctx = ctx or require("zettypst.commands").context()
  local req, translator = M.prepare(ctx, kind, payload)
  local result = require("zettypst.executor").run(
    ctx,
    assert(config.options.entries.capture, "configure entries.capture"),
    req
  )
  if result.ok then
    local node = result.nodes.list[1]
    local outcome = result.result
    result.kind, result.translator = kind, translator
    result.key = outcome.key ~= vim.NIL and outcome.key or nil
    result.status = outcome.created and "created" or "exists"
    result.note_path, result.note_id = node and node.origin.source, node and node.id
    result.asset_path = req.asset and ctx.root .. "/" .. req.asset.path
  end
  return result
end

function M.collect(ctx, done)
  local args = ctx.args or {}
  local function prepare(kind, source)
    if not source or source == "" then
      return
    end
    local payload = kind == "web" and { url = source }
      or kind == "paper-note" and { key = source }
      or (source:match("^https?://") and { url = source } or { path = source })
    local ok, req = pcall(M.prepare, ctx, kind, payload)
    if ok then
      done(req)
    else
      vim.notify(tostring(req), vim.log.levels.ERROR)
    end
  end
  local function choose(kind)
    if not kind then
      return
    end
    if args[2] then
      prepare(kind, table.concat(args, " ", 2))
    else
      vim.ui.input(
        { prompt = kind == "paper-note" and "BibTeX key: " or "Source URL or PDF path: " },
        function(value)
          prepare(kind, value)
        end
      )
    end
  end
  if args[1] then
    choose(args[1])
  else
    vim.ui.select({ "web", "paper", "paper-note" }, { prompt = "Capture" }, choose)
  end
end

function M.setup()
  require("zettypst.commands").register(
    "capture",
    M.dispatch,
    { "web", "paper", "paper-note", "extension-path", "install-native-host" }
  )
end

function M.dispatch(args)
  if args[1] == "extension-path" then
    local path = require("zettypst.capture.install").extension_path()
    vim.fn.setreg("+", path)
    vim.notify(path)
  elseif args[1] == "install-native-host" then
    local result = require("zettypst.capture.install").install(args[2])
    vim.notify("Installed native host: " .. result.manifest_path)
  else
    assert(
      not args[1] or vim.tbl_contains({ "web", "paper", "paper-note" }, args[1]),
      "unknown capture subcommand"
    )
    require("zettypst.commands").dispatch("capture", args)
  end
end

return M
