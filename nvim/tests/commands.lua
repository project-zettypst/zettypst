vim.opt.rtp:prepend(vim.fn.getcwd())
local config = require("zettypst.config")
local function complete(line)
  return vim.fn.getcompletion(line, "cmdline")
end

require("zettypst").setup({})
assert(config.options.capture == nil, "capture must be opt-in")
assert(vim.deep_equal(complete("Zet "), { "delete", "new", "search" }))

require("zettypst").setup(require("zettypst.presets.kickstart"))
local capture = config.options.capture
assert(capture.bibliography.path == "ref.bib" and capture.bibliography.translators.arxiv, "defaults merge")
assert(vim.tbl_contains(complete("Zet "), "capture"))
assert(vim.tbl_contains(complete("Zet capture pa"), "paper-note"))

local notified
local notify = vim.notify
vim.notify = function(message)
  notified = message
end
vim.cmd("Zet nonsense")
vim.notify = notify
assert(notified == "use :Zet capture|delete|new|search", notified)

local preset = vim.deepcopy(require("zettypst.presets.kickstart"))
preset.picker.filters = { active = false }
require("zettypst").setup(preset)
assert(next(config.options.picker.filters) == nil, "false removes a preset filter")
local published = config.options
for _, invalid in ipairs({
  { actions = { new = {} } },
  { entries = { nodes = 1 } },
  { picker = { views = { { name = "title" } } } },
  { timeout = 0 },
  { capture = true },
  { capture = { fetch = { manual = "yes" } } },
  { capture = { bibliography = { translators = { timeout = 0 } } } },
  { capture = { bibliography = { translators = { pdf_text_pages = 1.5 } } } },
  { capture = { templates = { web = false } } },
}) do
  local ok, err = pcall(config.setup, invalid)
  assert(not ok and err:find("^zettypst: "), vim.inspect(invalid))
  assert(config.options == published, "invalid options must not replace the current configuration")
end

require("zettypst").setup({ capture = false })
assert(not vim.tbl_contains(complete("Zet "), "capture"), "setup must drop optional subcommands")
print("passed subcommand registration and optional capture")
