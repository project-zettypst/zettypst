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
local executor = require("zettypst.executor")
local function fixture()
  local disk = { ["a.typ"] = "old", ["b.typ"] = "old" }
  local stats = { evaluations = 0, locks = 0, unlocks = 0, writes = 0, finished = 0 }
  local io = {
    read = function(path)
      return disk[path] or vim.NIL
    end,
    lock = function()
      stats.locks = stats.locks + 1
      return true
    end,
    unlock = function()
      stats.unlocks = stats.unlocks + 1
    end,
    clean = function() end,
    apply = function(effect)
      stats.writes = stats.writes + 1
      disk[effect.path] = effect.kind ~= "delete" and effect.content or nil
    end,
    finish = function()
      stats.finished = stats.finished + 1
    end,
  }
  local function evaluate(entry, inputs, sources)
    stats.evaluations = stats.evaluations + 1
    if entry == "plan.typ" then
      eq(sources, vim.empty_dict())
      local req = vim.json.decode(inputs["host.request"])
      assert(req.now.year)
      return {
        revision = stats.evaluations,
        reads = { ["a.typ"] = vim.fn.sha256(disk["a.typ"]) },
        output = {
          ["host.plan"] = {
            {
              effects = {
                { kind = "replace", path = "a.typ", before = disk["a.typ"], content = "new" },
                { kind = "replace", path = "b.typ", before = "old", content = "new" },
              },
              verify = { entry = "verify.typ", inputs = {} },
              result = { generation = stats.evaluations },
            },
          },
        },
      }
    end
    eq(sources, { ["a.typ"] = "new", ["b.typ"] = "new" })
    return { revision = stats.evaluations, reads = {}, output = {} }
  end
  return disk, stats, io, evaluate
end
test("snapshot conflict replans, then commits exactly once", function()
  local disk, stats, io, evaluate = fixture()
  local lock = io.lock
  io.lock = function()
    if stats.locks == 0 then
      disk["a.typ"] = "changed"
    end
    return lock()
  end
  local result = executor.run({}, "plan.typ", {}, { io = io, evaluate = evaluate })
  assert(result.ok, result.error)
  eq(result.attempts, 2)
  eq(result.result, { generation = 3 })
  eq(stats.evaluations, 4)
  eq(stats.writes, 2)
  eq(stats.locks, stats.unlocks)
  eq(stats.finished, 1)
end)
test("verify panic prevents locking and writing", function()
  local _, stats, io, evaluate = fixture()
  local result = executor.run({}, "plan.typ", {}, {
    io = io,
    evaluate = function(entry, ...)
      if entry == "verify.typ" then
        error("verify panic")
      end
      return evaluate(entry, ...)
    end,
  })
  assert(not result.ok and result.error:find("verify panic"))
  assert(result.result == nil)
  eq(stats.writes, 0)
  eq(stats.locks, 0)
end)
test("IO failure rolls back completed effects in reverse order", function()
  local disk, stats, io, evaluate = fixture()
  local apply = io.apply
  io.apply = function(effect)
    if effect.path == "b.typ" then
      error("IO failure")
    end
    apply(effect)
  end
  local result = executor.run({}, "plan.typ", {}, { io = io, evaluate = evaluate })
  assert(not result.ok)
  assert(result.result == nil)
  eq(result.undo, {})
  eq(disk["a.typ"], "old")
  eq(stats.unlocks, 1)
end)
test("rollback conflict stops and returns remaining executable undo log", function()
  local disk, stats, io, evaluate = fixture()
  local apply = io.apply
  io.apply = function(effect)
    if effect.path == "b.typ" then
      disk["a.typ"] = "external"
      error("IO failure")
    end
    apply(effect)
  end
  local result = executor.run({}, "plan.typ", {}, { io = io, evaluate = evaluate })
  assert(not result.ok)
  eq(#result.undo, 1)
  eq(result.undo[1].content, "old")
  eq(disk["a.typ"], "external")
  eq(stats.writes, 1)
  eq(stats.unlocks, 1)
end)
test("unlock failure does not publish a successful result", function()
  local _, _, io, evaluate = fixture()
  io.unlock = function()
    error("unlock failure")
  end
  local result = executor.run({}, "plan.typ", {}, { io = io, evaluate = evaluate })
  assert(not result.ok and result.result == nil)
end)
test("conflicting read hashes retry exactly three times", function()
  local _, stats, io, evaluate = fixture()
  local result = executor.run({}, "plan.typ", {}, {
    io = io,
    evaluate = function(entry, ...)
      local output = evaluate(entry, ...)
      if entry == "verify.typ" then
        output.reads["a.typ"] = vim.fn.sha256("other")
      end
      return output
    end,
  })
  assert(not result.ok)
  eq(stats.evaluations, 6)
  eq(stats.writes, 0)
  eq(stats.unlocks, 3)
end)
test("all effect preconditions checked before any write", function()
  local disk, stats, io, evaluate = fixture()
  disk["b.typ"] = "changed"
  local result = executor.run({}, "plan.typ", {}, { io = io, evaluate = evaluate })
  assert(not result.ok)
  eq(stats.writes, 0)
end)
test("modified footprint blocks writing and unlocks", function()
  local _, stats, io, evaluate = fixture()
  io.clean = function(paths)
    assert(paths["b.typ"])
    error("unsaved buffer")
  end
  local result = executor.run({}, "plan.typ", {}, { io = io, evaluate = evaluate })
  assert(not result.ok)
  eq(stats.writes, 0)
  eq(stats.unlocks, 1)
end)
test("unsaved buffers outside the write set do not block", function()
  local _, stats, io, evaluate = fixture()
  io.clean = function(paths)
    eq(paths, { ["a.typ"] = true, ["b.typ"] = true })
  end
  local result = executor.run({}, "plan.typ", {}, {
    io = io,
    evaluate = function(entry, ...)
      local output = evaluate(entry, ...)
      output.reads["read-only.typ"] = vim.NIL
      if entry == "plan.typ" then
        output.output["host.plan"][1].result = nil
      end
      return output
    end,
  })
  assert(result.ok, result.error)
  eq(result.result, vim.empty_dict())
  eq(stats.writes, 2)
end)
test("malformed and duplicate effects are rejected", function()
  for _, path in ipairs({ "", "../a", "/a", "a//b", "a/./b", ".zettypst/host.lock" }) do
    assert(not pcall(executor.path, path))
  end
  local _, _, _, evaluate = fixture()
  local result = evaluate("plan.typ", { ["host.request"] = '{"now":{"year":2026}}' }, vim.empty_dict())
  result.output["host.plan"][1].effects[2].path = "a.typ"
  assert(not pcall(executor.plan, result.output))
end)
print(("passed %d tests"):format(count))
