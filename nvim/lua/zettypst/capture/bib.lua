-- Adapted from zk-lsp.nvim: pure BibTeX parsing and rendering.
local M = {}

local function trim(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function collapse_ws(value)
  return trim((value or ""):gsub("%s+", " "))
end

local function strip_wrapping_braces(value)
  value = trim(value)
  while value:match("^{.*}$") do
    local depth = 0
    local balanced = true
    for index = 1, #value do
      local ch = value:sub(index, index)
      if ch == "{" then
        depth = depth + 1
      elseif ch == "}" then
        depth = depth - 1
        if depth == 0 and index < #value then
          balanced = false
          break
        end
      end
      if depth < 0 then
        balanced = false
        break
      end
    end
    if not balanced or depth ~= 0 then
      break
    end
    value = trim(value:sub(2, -2))
  end
  return value
end

local function normalize_field_value(value)
  value = strip_wrapping_braces(value or "")
  value = value:gsub("\\\n%s*", " ")
  return collapse_ws(value)
end

local function read_braced_value(text, pos)
  local depth = 1
  local index = pos + 1
  while index <= #text do
    local ch = text:sub(index, index)
    if ch == "{" then
      depth = depth + 1
    elseif ch == "}" then
      depth = depth - 1
      if depth == 0 then
        return text:sub(pos + 1, index - 1), index + 1
      end
    end
    index = index + 1
  end
  return text:sub(pos + 1), #text + 1
end

local function read_quoted_value(text, pos)
  local index = pos + 1
  while index <= #text do
    local ch = text:sub(index, index)
    local prev = index > 1 and text:sub(index - 1, index - 1) or ""
    if ch == '"' and prev ~= "\\" then
      return text:sub(pos + 1, index - 1), index + 1
    end
    index = index + 1
  end
  return text:sub(pos + 1), #text + 1
end

local function read_bare_value(text, pos)
  local index = pos
  while index <= #text do
    local ch = text:sub(index, index)
    if ch == "," or ch == "\n" or ch == "}" or ch == ")" then
      break
    end
    index = index + 1
  end
  return text:sub(pos, index - 1), index
end

local function parse_fields(body)
  local fields = {}
  local pos = 1
  while pos <= #body do
    local start_idx, eq_idx, name = body:find("([%a][%w_%-%:]*)%s*=", pos)
    if not start_idx then
      break
    end
    pos = eq_idx + 1
    while pos <= #body and body:sub(pos, pos):match("%s") do
      pos = pos + 1
    end
    local ch = body:sub(pos, pos)
    local value
    if ch == "{" then
      value, pos = read_braced_value(body, pos)
    elseif ch == '"' then
      value, pos = read_quoted_value(body, pos)
    else
      value, pos = read_bare_value(body, pos)
    end
    fields[name:lower()] = normalize_field_value(value)
  end
  return fields
end

function M.parse_text(text)
  local entries = {}
  local pos = 1
  while true do
    local entry_start, type_end, entry_type, open_char = text:find("@([%a][%w%-]*)%s*([%{%(%[])", pos)
    if not entry_start then
      break
    end

    local close_char = open_char == "{" and "}" or (open_char == "(" and ")" or "]")
    local depth = 1
    local index = type_end + 1
    local in_quote = false
    local entry_end
    while index <= #text do
      local ch = text:sub(index, index)
      local prev = index > 1 and text:sub(index - 1, index - 1) or ""
      if ch == '"' and prev ~= "\\" then
        in_quote = not in_quote
      end
      if not in_quote then
        if ch == open_char then
          depth = depth + 1
        elseif ch == close_char then
          depth = depth - 1
        end
        if depth == 0 then
          entry_end = index
          break
        end
      end
      index = index + 1
    end
    if not entry_end then
      break
    end

    local entry_text = text:sub(entry_start, entry_end)
    local first_comma = entry_text:find(",", 1, true)
    local key = first_comma and trim(entry_text:sub(entry_text:find(open_char, 1, true) + 1, first_comma - 1))
      or ""
    key = key:match("[%s=]") and "" or key
    local body = first_comma and entry_text:sub(first_comma + 1, -2) or ""
    entries[#entries + 1] = {
      type = entry_type:lower(),
      key = key,
      fields = parse_fields(body),
      start_offset = entry_start,
      end_offset = entry_end,
    }
    pos = entry_end + 1
  end
  return entries
end

function M.parse_entry(text)
  return M.parse_text(text or "")[1]
end

function M.field(entry, name)
  if not entry or type(entry.fields) ~= "table" then
    return ""
  end
  return entry.fields[(name or ""):lower()] or ""
end

function M.normalize_doi(value)
  value = trim(value or "")
  value = value:gsub("^https?://dx%.doi%.org/", "")
  value = value:gsub("^https?://doi%.org/", "")
  return value:lower()
end

function M.normalize_arxiv_id(value)
  value = trim(value or "")
  value = value:gsub("^arXiv:", "")
  value = value:gsub("^https?://arxiv%.org/abs/", "")
  value = value:gsub("^https?://arxiv%.org/pdf/", "")
  value = value:gsub("%.pdf$", "")
  value = value:gsub("^https?://doi%.org/10%.48550/arXiv%.", "")
  value = value:gsub("^10%.48550/arXiv%.", "")
  value = value:gsub("v%d+$", "")
  return value:lower()
end

function M.extract_arxiv_id(value)
  value = trim(value or "")
  local id = value:match("arxiv%.org/abs/([^?#%s]+)")
    or value:match("arxiv%.org/pdf/([^?#%s]+)")
    or value:match("^arXiv:(.+)$")
    or value:match("^arxiv:(.+)$")
    or value:match("10%.48550/arXiv%.([^%s}%]%)>,]+)")
  if not id then
    return nil
  end
  id = id:gsub("%.pdf$", "")
  return id
end

local stopwords = {
  a = true,
  an = true,
  ["and"] = true,
  ["for"] = true,
  ["in"] = true,
  of = true,
  on = true,
  the = true,
  to = true,
  with = true,
}

local function slug(value, max_words)
  local words = {}
  value = (value or ""):lower():gsub("['’]", ""):gsub("[^%w]+", " ")
  for word in value:gmatch("[%w]+") do
    if not stopwords[word] or #words == 0 then
      words[#words + 1] = word
    end
    if #words >= max_words then
      break
    end
  end
  return table.concat(words)
end

function M.derive_key(fields)
  fields = fields or {}
  local title = fields.title or fields.url or fields.file or "source"
  local year = tostring(fields.year or fields.date or ""):match("%d%d%d%d") or ""
  local base = slug(title, 4)
  if base == "" then
    base = "source"
  end
  return base .. (year ~= "" and year or vim.fn.sha256(title):sub(1, 6))
end

function M.clean_title(value)
  value = collapse_ws(value or "")
  value = value:gsub("^%{", ""):gsub("%}$", "")
  return value
end

function M.split_words(value)
  if type(value) == "table" then
    local result = {}
    for _, item in ipairs(value) do
      if trim(tostring(item)) ~= "" then
        result[#result + 1] = collapse_ws(tostring(item))
      end
    end
    return result
  end

  local result = {}
  for word in tostring(value or ""):gmatch("[^,;]+") do
    word = collapse_ws(word)
    if word ~= "" then
      result[#result + 1] = word
    end
  end
  return result
end

return M
