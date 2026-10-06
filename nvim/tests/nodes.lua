vim.opt.rtp:prepend(vim.fn.getcwd())
local count = 0
local function test(name, f)
  local ok, reason = pcall(f)
  if not ok then
    error(name .. ": " .. tostring(reason))
  end
  count = count + 1
  print("ok " .. name)
end
local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect(a) .. " != " .. vim.inspect(b))
end
local nodes = require("zettypst.nodes")
local function node(id)
  return {
    id = id,
    title = "Title " .. id,
    metadata = {},
    origin = {
      source = "/project/shared.typ",
      ["range-utf16"] = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } },
    },
  }
end
test("node contract rejects duplicate identity and missing origins", function()
  assert(not pcall(nodes.build, { node("one"), node("one") }))
  local n = node("one")
  n.origin = { source = "/project/shared.typ" }
  assert(not pcall(nodes.build, { n }))
  n = node("one")
  n.metadata = { nested = { true, vim.NIL, { value = 4 } } }
  eq(nodes.build({ n }).by_id.one, n)
end)
test("current node uses explicit origins, never filenames", function()
  local a, b = node("one"), node("two")
  b.origin["range-utf16"] = { start = { line = 3, character = 0 }, ["end"] = { line = 3, character = 5 } }
  local index = nodes.build({ a, b })
  eq(nodes.current(index, "/project/shared.typ", { line = 3, character = 2 }), b)
  eq(nodes.current(index, "/project/shared.typ", { line = 2, character = 2 }), nil)
  eq(nodes.current(index, "/project/one.typ"), nil)
end)
test("picker corpus weights and toggleable filters use supplied functions", function()
  local picker = require("zettypst.picker")
  local options = {
    views = {
      {
        name = "title",
        text = function(n)
          return n.title
        end,
        weight = 9,
      },
    },
    filters = {
      chosen = {
        default = true,
        test = function(n)
          return n.id == "one"
        end,
      },
    },
  }
  local state = picker.defaults(options.filters)
  local index = nodes.build({ node("one"), node("two") })
  local items = picker.items(index, options, state)
  eq(#items, 1)
  eq(items[1].corpus[1].weight, 9)
  eq(items[1].text, "Title one")
  state.chosen = false
  eq(#picker.items(index, options, state), 2)
end)
test("multiple views and aliases produce one row per identity", function()
  local picker = require("zettypst.picker")
  local options = {
    filters = {},
    views = {
      {
        text = function(n)
          return n.title
        end,
        weight = 10,
      },
      {
        text = function()
          return { "alias", "alias", "second alias" }
        end,
        weight = 5,
      },
      {
        text = function()
          return ""
        end,
      },
    },
  }
  local a, b = node("one"), node("two")
  b.title = a.title -- Same titles with different identities remain distinct.
  local items = picker.items(nodes.build({ a, b }), options, {})
  eq(#items, 2)
  eq(#items[1].corpus, 4)
  assert(items[1].text:find("second alias", 1, true))
  local score = picker.score(items[1], function(candidate)
    return candidate.text == "alias" and 100 or 0
  end)
  eq(score, 105) -- Duplicate matching aliases do not accumulate bonuses.
  items[1].score = 42
  eq(
    picker.score(items[1], function()
      return 0
    end),
    42
  )
end)
print(("passed %d read tests"):format(count))
