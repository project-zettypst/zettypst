vim.opt.rtp:prepend(vim.fn.getcwd())
local snacks = vim.env.SNACKS_PATH or (vim.fn.stdpath("data") .. "/lazy/snacks.nvim")
assert(vim.uv.fs_stat(snacks), "set SNACKS_PATH to snacks.nvim")
vim.opt.rtp:append(snacks)
require("snacks").setup({ picker = { enabled = true } })
local origin = {
  source = vim.fn.getcwd() .. "/README.md",
  ["range-utf16"] = {
    start = { line = 0, character = 0 },
    ["end"] = { line = 0, character = 4 },
  },
}
local index = require("zettypst.nodes").build({
  { id = "example", title = "Example title", origin = origin, metadata = {} },
})
local options = vim.deepcopy(require("zettypst.config").defaults.picker)
options.views[#options.views + 1] = {
  name = "alternate",
  text = function()
    return { "aliasneedle", "aliasneedle", "other" }
  end,
  weight = 7,
}
options.views[#options.views + 1] = {
  name = "empty",
  text = function()
    return ""
  end,
}
local matcher = require("snacks.picker.core.matcher").new()
matcher:init("aliasneedle")
local candidate = require("zettypst.picker").items(index, options, {})[1]
assert(matcher:match(candidate) > 0, "aliases must remain searchable")
assert(require("zettypst.picker").score(candidate, function(item)
  return matcher:match(item)
end) == matcher:match({ text = "aliasneedle" }) + 7, "only the matching corpus gets its weight")
options.filters = { test = {
  default = true,
  test = function()
    return true
  end,
} }
require("zettypst.picker").open(index, options)
assert(vim.wait(2000, function()
  return #Snacks.picker.get() == 1
end, 20))
local p = Snacks.picker.get()[1]
assert(
  vim.wait(2000, function()
    return #p:items() == 1
  end, 20),
  "picker item missing"
)
assert(p:items()[1].node.id == "example")
p:action("zet_filters")
assert(vim.wait(2000, function()
  return #Snacks.picker.get() == 1 and Snacks.picker.get()[1].opts.title == "Zet filters"
end, 20))
Snacks.picker.get()[1]:close()
assert(vim.wait(2000, function()
  return #Snacks.picker.get() == 1 and Snacks.picker.get()[1].opts.title == "Zet"
end, 20))
Snacks.picker.get()[1]:close()
vim.wait(100, function()
  return false
end)
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(
  buf,
  0,
  -1,
  false,
  { "A reference @example and @unknown.", "// @example in comment" }
)
vim.bo[buf].filetype = "typst"
assert(pcall(vim.treesitter.get_parser, buf, "typst"), "install the Typst Tree-sitter parser for this test")
vim.api.nvim_set_current_buf(buf)
vim.wo.conceallevel = 2
vim.wo.concealcursor = "n"
require("zettypst.snapshot").get = function()
  return index
end
require("zettypst.titles").redraw()
local ns = require("zettypst.titles").namespace(vim.api.nvim_get_current_win())
local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
assert(#marks == 2, vim.inspect(marks))
assert(marks[2][4].virt_text[1][1] == "@Example title")
print("passed real Snacks picker/filter lifecycle and Tree-sitter title rendering")
