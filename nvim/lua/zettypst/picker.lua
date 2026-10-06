local M = {}
function M.defaults(filters)
  local enabled = {}
  for name, filter in pairs(filters) do
    enabled[name] = filter.default == true
  end
  return enabled
end
function M.items(index, options, enabled)
  local items = {}
  for _, node in ipairs(index.list) do
    local keep = true
    for name, filter in pairs(options.filters) do
      if enabled[name] and not filter.test(node, index) then
        keep = false
        break
      end
    end
    if keep then
      local corpus, texts = {}, {}
      for _, view in ipairs(options.views) do
        local values = view.text(node, index)
        if type(values) == "string" then
          values = { values }
        end
        assert(type(values) == "table", "view.text must return a string or array")
        for _, text in ipairs(values) do
          assert(type(text) == "string", "view corpus must contain strings")
          if text ~= "" then
            corpus[#corpus + 1] = { text = text, weight = view.weight or 0 }
            texts[#texts + 1] = text
          end
        end
      end
      -- Identity determines rows. Views supply matching evidence for that row.
      items[#items + 1] = {
        text = table.concat(texts, "\n"),
        corpus = corpus,
        node = node,
        file = node.origin.source,
        pos = { node.origin["range-utf16"].start.line + 1, 0 },
      }
    end
  end
  return items
end
-- Weight only matching corpora; alias count cannot multiply the score.
function M.score(item, match)
  local best
  for _, corpus in ipairs(item.corpus) do
    local score = match({ text = corpus.text, file = item.file })
    if score > 0 then
      local weighted = math.max(1, score + corpus.weight)
      best = best and math.max(best, weighted) or weighted
    end
  end
  -- Multi-term queries may match across different corpora.
  return best or item.score
end

function M.open(index, options)
  local picker = require("snacks.picker")
  local enabled = M.defaults(options.filters)
  local query = ""
  local open
  local function filters(p)
    query = p.input.filter.pattern
    p:close()
    local choices = {}
    for _, name in ipairs(vim.tbl_keys(options.filters)) do
      choices[#choices + 1] = { text = (enabled[name] and "[x] " or "[ ] ") .. name, name = name }
    end
    table.sort(choices, function(a, b)
      return a.name < b.name
    end)
    local reopening = false
    picker.pick({
      title = "Zet filters",
      layout = "select",
      items = choices,
      format = "text",
      confirm = function(selection, item)
        if not item then
          return
        end
        enabled[item.name] = not enabled[item.name]
        reopening = true
        selection:close()
        vim.schedule(open)
      end,
      on_close = function()
        if not reopening then
          vim.schedule(open)
        end
      end,
    })
  end
  open = function()
    picker.pick({
      source = "zettypst",
      title = "Zet",
      pattern = query,
      items = M.items(index, options, enabled),
      sort = { fields = { "score:desc", "idx" } },
      matcher = {
        on_match = function(matcher, item)
          if not matcher:empty() then
            item.score = M.score(item, function(candidate)
              return matcher:match(candidate)
            end)
          end
        end,
      },
      format = function(item)
        return {
          { options.display.title(item.node, index), "Normal" },
          { "  " .. options.display.detail(item.node, index), "Comment" },
        }
      end,
      confirm = function(p, item)
        if item then
          p:close()
          require("zettypst.nodes").open(item.node.origin)
        end
      end,
      win = {
        input = {
          keys = { ["<C-f>"] = { "zet_filters", mode = { "i", "n" } }, f = { "zet_filters", mode = "n" } },
        },
        list = { keys = { f = "zet_filters" } },
      },
      actions = { zet_filters = filters },
    })
  end
  open()
end
return M
