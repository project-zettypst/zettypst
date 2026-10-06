vim.opt.rtp:prepend(vim.fn.getcwd())
local titles = require("zettypst.titles")
local config = require("zettypst.config")
local snapshot = require("zettypst.snapshot")
config.setup({ titles = { enabled = true } })
titles.setup()
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = "typst"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "中文 @one and @two", "// @one", "" })
vim.wo.conceallevel, vim.wo.concealcursor = 2, "niv"
local win = vim.api.nvim_get_current_win()
local index = { by_id = { one = { title = "第一项" }, two = { title = "Second" } } }
local function marks(window)
  local ns = titles.namespace(window)
  return ns and vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }) or {}
end
local function move(col)
  vim.api.nvim_win_set_cursor(0, { 1, col })
  titles.redraw()
end
snapshot.get = function()
  return index
end
move(0)
assert(#marks(win) == 4, "both references should have title overlays")
assert(marks(win)[2][4].virt_text[1][1] == "@第一项")
assert(marks(win)[2][4].virt_text[1][2] == "@markup.link")
-- UTF-8 byte boundaries: the @ is at byte 7, end-exclusive at byte 11.
for _, col in ipairs({ 7, 8, 10 }) do
  move(col)
  assert(#marks(win) == 2, "cursor inside first span must reveal only that reference")
  assert(marks(win)[2][4].virt_text[1][1] == "@Second")
end
move(11)
assert(#marks(win) == 4, "end-exclusive position should restore title")
-- Actual movement event, without an eval request.
vim.api.nvim_win_set_cursor(0, { 1, 8 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
assert(
  vim.wait(100, function()
    return #marks(win) == 2
  end, 5),
  "CursorMoved did not reveal source"
)
vim.cmd.vsplit()
local second = vim.api.nvim_get_current_win()
vim.wo.conceallevel, vim.wo.concealcursor = 3, "niv"
move(0)
assert(#marks(second) == 4 and #marks(win) == 4, "unfocused window should keep titles")
move(8)
assert(#marks(second) == 2 and #marks(win) == 4, "cursor state must be window-local")
vim.wo.conceallevel = 0
titles.redraw()
assert(#marks(second) == 0 and #marks(win) == 4, "conceallevel=0 must remove inline titles too")
vim.wo.conceallevel, vim.wo.concealcursor = 2, ""
move(0)
assert(#marks(second) == 0, "respect native cursor-line conceal policy")
vim.wo.concealcursor = "niv"
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "前缀 中文 @one and @two" })
move(0)
assert(#marks(second) == 4)
assert(marks(second)[1][3] == #"前缀 中文 ", "reparse shifted byte ranges after edits")
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "No references" })
titles.redraw()
assert(#marks(second) == 0 and #marks(win) == 0, "removed refs must not leave stale extmarks")
vim.api.nvim_win_close(second, true)
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "中文 @one and @two" })
move(0)
assert(#marks(win) == 4)
local get_parser, notify = vim.treesitter.get_parser, vim.notify
local warnings, failure = {}, "parse failure"
vim.treesitter.get_parser = function()
  error(failure, 0)
end
vim.notify = function(message)
  warnings[#warnings + 1] = message
end
local function redraw_failure()
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "中文 @one and @two" })
  titles.redraw()
end
redraw_failure()
redraw_failure()
failure = "another parse failure"
redraw_failure()
failure = "parse failure"
redraw_failure()
vim.treesitter.get_parser, vim.notify = get_parser, notify
assert(vim.deep_equal(warnings, { "Zet titles: parse failure", "Zet titles: another parse failure" }))
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "中文 @one and @two" })
titles.redraw()
assert(#marks(win) == 4, "titles must recover after a parse failure")
print("passed title spans, UTF-8, cursor events, split windows, conceal options and edits")
