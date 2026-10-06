local M = {}
M.defaults = {
  autostart = false,
  entries = {},
  actions = {},
  timeout = 30000,
  titles = { enabled = true },
  picker = {
    views = {
      {
        name = "title",
        text = function(node)
          return node.title
        end,
        weight = 1,
      },
    },
    filters = {},
    display = {
      title = function(node)
        return node.title
      end,
      detail = function(node)
        return node.id
      end,
    },
  },
}
-- Merged only when `capture` is configured; capture is otherwise disabled.
M.capture = {
  fetch = { manual = true, paper = true },
  bibliography = {
    translators = {
      enabled = true,
      timeout = 12,
      arxiv = true,
      crossref = true,
      generic_html = true,
      pdf_text = true,
      pdf_text_pages = 3,
    },
  },
  -- Must match the bundled Chrome extension.
  browser = { host_name = "top.homeward_sky.zettypst_capture" },
  templates = {},
}
M.options = vim.deepcopy(M.defaults)
local function expect(ok, message)
  if not ok then
    error("zettypst: " .. message, 0)
  end
end
local function validate_capture(c)
  for _, name in ipairs({ "fetch", "bibliography", "browser", "templates" }) do
    expect(type(c[name]) == "table", "capture." .. name .. " must be a table")
  end
  for _, name in ipairs({ "manual", "paper" }) do
    expect(type(c.fetch[name]) == "boolean", "capture.fetch." .. name .. " must be a boolean")
  end
  local path = c.bibliography.path
  expect(path == nil or (type(path) == "string" and path ~= ""), "capture.bibliography.path must be a path")
  local t = c.bibliography.translators
  local prefix = "capture.bibliography.translators."
  expect(type(t) == "table", "capture.bibliography.translators must be a table")
  for _, name in ipairs({ "enabled", "arxiv", "crossref", "generic_html", "pdf_text" }) do
    expect(type(t[name]) == "boolean", prefix .. name .. " must be a boolean")
  end
  expect(type(t.timeout) == "number" and t.timeout > 0, prefix .. "timeout must be positive seconds")
  expect(
    type(t.pdf_text_pages) == "number" and t.pdf_text_pages > 0 and t.pdf_text_pages % 1 == 0,
    prefix .. "pdf_text_pages must be a positive integer"
  )
  for _, name in ipairs({ "arxiv_endpoint", "crossref_endpoint" }) do
    expect(
      t[name] == nil or (type(t[name]) == "string" and t[name]:match("^https?://")),
      prefix .. name .. " must be an HTTP(S) URL"
    )
  end
  local root = c.browser.root
  expect(root == nil or (type(root) == "string" and root ~= ""), "capture.browser.root must be a path")
  expect(
    type(c.browser.host_name) == "string" and c.browser.host_name:match("^[a-z0-9_.]+$"),
    "invalid capture.browser.host_name"
  )
  for kind, hook in pairs(c.templates) do
    expect(vim.is_callable(hook), "capture.templates." .. kind .. " must be a function")
  end
end
-- Validate merged options before publishing them to consumers.
local function validate(o)
  local callable = vim.is_callable
  expect(o.root_dir == nil or callable(o.root_dir), "root_dir must be a function")
  expect(type(o.autostart) == "boolean", "autostart must be a boolean")
  expect(type(o.timeout) == "number" and o.timeout > 0, "timeout must be a positive number of milliseconds")
  expect(type(o.titles.enabled) == "boolean", "titles.enabled must be a boolean")
  for name, entry in pairs(o.entries) do
    expect(type(entry) == "string", "entries." .. name .. " must be a project path")
  end
  for name, action in pairs(o.actions) do
    expect(
      type(action) == "table" and callable(action.collect),
      "actions." .. name .. ".collect must be a function"
    )
  end
  for i, view in ipairs(o.picker.views) do
    expect(type(view) == "table" and callable(view.text), "picker.views[" .. i .. "].text must be a function")
  end
  for name, filter in pairs(o.picker.filters) do
    expect(
      type(filter) == "table" and callable(filter.test),
      "picker.filters." .. name .. ".test must be a function"
    )
  end
  expect(
    callable(o.picker.display.title) and callable(o.picker.display.detail),
    "picker.display.title and picker.display.detail must be functions"
  )
  if o.capture then
    validate_capture(o.capture)
  end
end
function M.setup(options)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), options or {})
  -- Setting a preset filter to false removes it.
  for name, filter in pairs(merged.picker.filters) do
    if filter == false then
      merged.picker.filters[name] = nil
    end
  end
  if merged.capture then
    expect(type(merged.capture) == "table", "capture must be a table or false")
    merged.capture = vim.tbl_deep_extend("force", vim.deepcopy(M.capture), merged.capture)
  end
  validate(merged)
  M.options = merged
  return M.options
end
return M
