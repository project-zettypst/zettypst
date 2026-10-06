local M = {}
-- Records arrive as decoded JSON from Typst, so only the contract shape is checked.
function M.origin(origin)
  local range = type(origin) == "table" and origin["range-utf16"]
  assert(
    type(origin.source) == "string" and type(range) == "table" and range.start and range["end"],
    "invalid node origin"
  )
  return origin
end
function M.build(records, revision)
  assert(vim.islist(records), "host.node must be an array")
  local index = { list = {}, by_id = {}, by_source = {}, revision = revision }
  for _, node in ipairs(records) do
    assert(
      type(node.id) == "string" and type(node.title) == "string" and type(node.metadata) == "table",
      "invalid host.node"
    )
    M.origin(node.origin)
    assert(not index.by_id[node.id], "duplicate node id: " .. node.id)
    index.by_id[node.id] = node
    index.list[#index.list + 1] = node
    local path = node.origin.source
    index.by_source[path] = index.by_source[path] or {}
    table.insert(index.by_source[path], node)
  end
  return index
end
function M.current(index, path, position)
  local records = index.by_source[path] or {}
  if #records == 1 then
    return records[1]
  end
  local matched
  for _, node in ipairs(records) do
    local r = node.origin["range-utf16"]
    if
      position
      and (position.line > r.start.line or (position.line == r.start.line and position.character >= r.start.character))
      and (
        position.line < r["end"].line
        or (position.line == r["end"].line and position.character < r["end"].character)
      )
    then
      assert(not matched, "ambiguous current node")
      matched = node
    end
  end
  return matched
end
-- Jumps like a definition: the previous position stays on the jumplist.
function M.open(origin)
  M.origin(origin)
  local buf = vim.fn.bufadd(origin.source)
  vim.bo[buf].buflisted = true
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_buf(0, buf)
  local start = origin["range-utf16"].start
  local line = vim.api.nvim_buf_get_lines(buf, start.line, start.line + 1, false)[1] or ""
  local column =
    vim.str_byteindex(line, "utf-16", math.min(start.character, vim.str_utfindex(line, "utf-16")), false)
  vim.api.nvim_win_set_cursor(0, { math.min(start.line + 1, vim.api.nvim_buf_line_count(buf)), column })
end
return M
