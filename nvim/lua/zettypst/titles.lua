-- Inline reference titles rendered from the live node snapshot.
local M = {}
local snapshot = require("zettypst.snapshot")
local surfaces, spans, free = {}, {}, {}
local labels = setmetatable({}, { __mode = "k" })
local reported = {}
local query

local function titles_of(index)
  if not labels[index] then
    local titles = {}
    for id, node in pairs(index.by_id) do
      titles[id] = (node.title:gsub("%c", " "))
    end
    labels[index] = titles
  end
  return labels[index]
end

local function ranges(buf, titles)
  -- Missing parsers are reported by :checkhealth zettypst.
  if not query and #vim.api.nvim_get_runtime_file("parser/typst.*", false) == 0 then
    return {}
  end
  query = query or vim.treesitter.query.parse("typst", "(ref) @reference")
  local tree = vim.treesitter.get_parser(buf, "typst"):parse()[1]
  local rows = {}
  for _, node in query:iter_captures(tree:root(), buf, 0, -1) do
    local text = vim.treesitter.get_node_text(node, buf)
    local title = titles[text:sub(2)]
    local row, col, last, finish = node:range()
    if title and text:sub(1, 1) == "@" and row == last then
      rows[row] = rows[row] or {}
      table.insert(rows[row], { col = col, finish = finish, title = title })
    end
  end
  return rows
end

local function remove(surface, mark)
  if vim.api.nvim_buf_is_valid(surface.buf) then
    vim.api.nvim_buf_del_extmark(surface.buf, surface.ns, mark.conceal)
    vim.api.nvim_buf_del_extmark(surface.buf, surface.ns, mark.text)
  end
end

local function reconcile(surface, desired)
  -- Read actual positions: Neovim already moved surviving marks with text edits.
  local existing = {}
  for _, mark in pairs(surface.marks) do
    local a = vim.api.nvim_buf_get_extmark_by_id(surface.buf, surface.ns, mark.conceal, { details = true })
    local b = vim.api.nvim_buf_get_extmark_by_id(surface.buf, surface.ns, mark.text, {})
    if #a > 0 and #b > 0 and a[3].end_row == a[1] and b[1] == a[1] and b[2] == a[3].end_col then
      local key = a[1] .. ":" .. a[2] .. ":" .. b[2]
      if existing[key] then
        remove(surface, existing[key])
      end
      existing[key] = mark
    else
      remove(surface, mark)
    end
  end
  local next_marks = {}
  for key, span in pairs(desired) do
    local mark = existing[key]
    existing[key] = nil
    if not mark then
      mark = {
        conceal = vim.api.nvim_buf_set_extmark(surface.buf, surface.ns, span.row, span.col, {
          end_col = span.finish,
          conceal = "",
        }),
      }
    end
    if mark.title ~= span.title then
      mark.text = vim.api.nvim_buf_set_extmark(surface.buf, surface.ns, span.row, span.finish, {
        id = mark.text,
        virt_text = { { "@" .. span.title, "@markup.link" } },
        virt_text_pos = "inline",
        hl_mode = "combine",
      })
      mark.title = span.title
    end
    next_marks[key] = mark
  end
  for _, mark in pairs(existing) do
    remove(surface, mark)
  end
  surface.marks = next_marks
end

-- Window-scoped namespaces cannot be deleted, so closed windows return theirs to a pool.
local function release(win, surface)
  if vim.api.nvim_buf_is_valid(surface.buf) then
    vim.api.nvim_buf_clear_namespace(surface.buf, surface.ns, 0, -1)
  end
  surfaces[win] = nil
  free[#free + 1] = surface.ns
end

local function acquire(win, buf)
  local ns = table.remove(free) or vim.api.nvim_create_namespace("")
  vim.api.nvim__ns_set(ns, { wins = { win } })
  surfaces[win] = { ns = ns, buf = buf, marks = {} }
  return surfaces[win]
end

function M.namespace(win)
  return surfaces[win] and surfaces[win].ns
end

function M.supported()
  return vim.api.nvim__ns_set ~= nil
end

function M.redraw()
  for win, surface in pairs(surfaces) do
    if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= surface.buf then
      release(win, surface)
    end
  end
  if not M.supported() then
    return
  end
  local enabled = require("zettypst.config").options.titles.enabled
  local focused = vim.api.nvim_get_current_win()
  local mode = vim.api.nvim_get_mode().mode:sub(1, 1)
  if mode == "V" or mode == "\22" then
    mode = "v"
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local index = enabled
      and vim.wo[win].conceallevel >= 2
      and vim.api.nvim_buf_is_loaded(buf)
      and snapshot.get(buf)
    local desired = {}
    if index then
      local tick = vim.api.nvim_buf_get_changedtick(buf)
      local cached = spans[buf]
      if not cached or cached.tick ~= tick or cached.index ~= index then
        local ok, rows = pcall(ranges, buf, titles_of(index))
        if not ok then
          local message = tostring(rows)
          if not reported[message] then
            reported[message] = true
            vim.notify("Zet titles: " .. message, vim.log.levels.WARN)
          end
        end
        cached = { tick = tick, index = index, rows = ok and rows or {} }
        spans[buf] = cached
      end
      local cursor = vim.api.nvim_win_get_cursor(win)
      for row, line in pairs(cached.rows) do
        local cursor_row = win == focused and cursor[1] - 1 == row
        if not cursor_row or vim.wo[win].concealcursor:find(mode, 1, true) then
          for _, span in ipairs(line) do
            if not (cursor_row and cursor[2] >= span.col and cursor[2] < span.finish) then
              desired[row .. ":" .. span.col .. ":" .. span.finish] = {
                row = row,
                col = span.col,
                finish = span.finish,
                title = span.title,
              }
            end
          end
        end
      end
      if not surfaces[win] then
        acquire(win, buf)
      end
    end
    if surfaces[win] then
      reconcile(surfaces[win], desired)
    end
  end
end

function M.setup()
  for win, surface in pairs(surfaces) do
    release(win, surface)
  end
  spans = {}
  local group = vim.api.nvim_create_augroup("ZetTypstTitles", { clear = true })
  local function later()
    vim.schedule(M.redraw)
  end
  vim.api.nvim_create_autocmd({
    "BufWinEnter",
    "CursorMoved",
    "CursorMovedI",
    "TextChanged",
    "TextChangedI",
    "ModeChanged",
    "WinEnter",
    "WinClosed",
  }, { group = group, callback = later })
  vim.api.nvim_create_autocmd("User", { group = group, pattern = "ZetNodesChanged", callback = M.redraw })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = { "conceallevel", "concealcursor" },
    callback = M.redraw,
  })
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    callback = function(args)
      spans[args.buf] = nil
    end,
  })
  M.redraw()
end
return M
