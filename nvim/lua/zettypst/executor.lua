local M = {}
local null = vim.NIL
local uv = vim.uv
function M.path(path)
  assert(
    type(path) == "string"
      and path ~= ""
      and not path:find("[\\:%z]")
      and path:sub(1, 1) ~= "/"
      and path:sub(-1) ~= "/"
      and not path:find("//", 1, true),
    "noncanonical project path"
  )
  for part in path:gmatch("[^/]+") do
    assert(part ~= "." and part ~= "..", "noncanonical project path")
  end
  assert(path ~= ".zettypst/host.lock", "effect cannot target the executor lock")
  return path
end
local function dictionary(value)
  return type(value) == "table" and (next(value) == nil or not vim.islist(value))
end
function M.plan(output)
  local plans = output["host.plan"]
  assert(type(plans) == "table" and vim.islist(plans) and #plans == 1, "expected exactly one host.plan")
  local plan = plans[1]
  assert(
    type(plan) == "table" and type(plan.effects) == "table" and vim.islist(plan.effects),
    "invalid effects"
  )
  local seen, overlay = {}, vim.empty_dict()
  for _, effect in ipairs(plan.effects) do
    assert(type(effect) == "table", "invalid effect")
    M.path(effect.path)
    assert(not seen[effect.path], "duplicate effect path: " .. effect.path)
    seen[effect.path] = true
    assert(
      effect.kind == "create" or effect.kind == "replace" or effect.kind == "delete",
      "invalid effect kind"
    )
    if effect.kind ~= "create" then
      assert(type(effect.before) == "string", "effect requires before text")
    end
    if effect.kind ~= "delete" then
      assert(type(effect.content) == "string", "effect requires content text")
    end
    overlay[effect.path] = effect.kind == "delete" and null or effect.content
  end
  assert(dictionary(plan.verify) and dictionary(plan.verify.inputs), "invalid verification")
  M.path(plan.verify.entry)
  for key, value in pairs(plan.verify.inputs) do
    assert(type(key) == "string" and type(value) == "string", "invalid verify input")
  end
  assert(plan.result == nil or dictionary(plan.result), "invalid plan result")
  return plan, overlay
end
local function before(effect)
  return effect.kind == "create" and null or effect.before
end
local function inverse(effect)
  if effect.kind == "create" then
    return { kind = "delete", path = effect.path, before = effect.content }
  end
  if effect.kind == "delete" then
    return { kind = "create", path = effect.path, content = effect.before }
  end
  return { kind = "replace", path = effect.path, before = effect.content, content = effect.before }
end
local function same(io, effect)
  return io.read(effect.path) == before(effect)
end
local function hash(content)
  return content == null and null or vim.fn.sha256(content)
end
local function reads(a, b)
  assert(dictionary(a) and dictionary(b), "evaluation omitted reads")
  local all, conflict = {}, false
  for _, set in ipairs({ a, b }) do
    for path, digest in pairs(set) do
      M.path(path)
      if all[path] ~= nil and all[path] ~= digest then
        conflict = true
      end
      all[path] = digest
    end
  end
  return all, conflict
end
local function rollback(io, undo)
  while #undo > 0 do
    local effect = undo[#undo]
    local ok, reason = pcall(function()
      assert(same(io, effect), "rollback conflict: " .. effect.path)
      io.apply(effect)
    end)
    if not ok then
      local remaining = {}
      for i = #undo, 1, -1 do
        remaining[#remaining + 1] = undo[i]
      end
      return remaining, tostring(reason)
    end
    table.remove(undo)
  end
  return {}
end
-- Dependencies are injectable so transaction behavior can be tested without LSP.
function M.run(ctx, entry, request, deps)
  deps = deps or {}
  local io = deps.io or M.io(ctx.root)
  local evaluate = deps.evaluate
    or function(e, inputs, sources)
      return require("zettypst.transport").detached(ctx, e, inputs, sources)
    end
  request = vim.deepcopy(request)
  assert(dictionary(request), "request must be a dictionary")
  local now = os.date("*t")
  request.now =
    { year = now.year, month = now.month, day = now.day, hour = now.hour, minute = now.min, second = now.sec }
  for attempt = 1, 3 do
    local ok, plan, announced, all, conflict = pcall(function()
      local result = evaluate(entry, { ["host.request"] = vim.json.encode(request) }, vim.empty_dict())
      local p, overlay = M.plan(result.output)
      local verification = evaluate(p.verify.entry, p.verify.inputs, overlay)
      local announced =
        require("zettypst.nodes").build(verification.output["host.node"] or {}, verification.revision)
      assert(#announced.list <= 1, "verification returned multiple target nodes")
      local r, c = reads(result.reads, verification.reads)
      return p, announced, r, c
    end)
    if not ok then
      return { ok = false, error = tostring(plan), attempts = attempt }
    end
    local token, busy = io.lock()
    if not token then
      return { ok = false, error = busy, attempts = attempt }
    end
    local undo, result = {}, nil
    local success, reason = pcall(function()
      -- Evaluation reads disk, so unsaved buffers only matter where we write.
      local footprint = {}
      for _, effect in ipairs(plan.effects) do
        footprint[effect.path] = true
      end
      io.clean(footprint)
      for path, digest in pairs(all) do
        if hash(io.read(path)) ~= digest then
          conflict = true
        end
      end
      -- The write set need not have been read by Typst (especially create).
      for _, effect in ipairs(plan.effects) do
        if not same(io, effect) then
          conflict = true
        end
      end
      if conflict then
        return
      end
      for _, effect in ipairs(plan.effects) do
        io.apply(effect) -- Rechecks its precondition immediately before publishing.
        undo[#undo + 1] = inverse(effect)
      end
      result = { ok = true, attempts = attempt, plan = plan, effects = plan.effects, nodes = announced }
    end)
    if not success then
      local remaining, failure = rollback(io, undo)
      result = {
        ok = false,
        error = tostring(reason),
        undo = remaining,
        rollback_error = failure,
        attempts = attempt,
      }
    end
    local unlocked, unlock_error = pcall(io.unlock, token)
    if not unlocked then
      result = result or { ok = false, attempts = attempt }
      result.ok = false
      result.error = (result.error or "operation completed") .. "; unlock failed: " .. tostring(unlock_error)
      return result
    end
    if result then
      if result.ok then
        result.result = plan.result or vim.empty_dict()
        local handled, failure = pcall(io.finish, result)
        if not handled then
          result.buffer_error = tostring(failure)
        end
      end
      return result
    end
  end
  return { ok = false, error = "snapshot conflict after 3 planning attempts", attempts = 3 }
end

-- Writes project text transactions and their locks; capture assets are published separately.
function M.io(root)
  root = assert(uv.fs_realpath(root), "project root does not exist")
  local io = {}
  -- Reads follow symlinks like Typst does; only writes refuse to traverse them.
  local function resolve(path, follow)
    M.path(path)
    if follow then
      return root .. "/" .. path
    end
    local current = root
    for part in path:gmatch("[^/]+") do
      current = current .. "/" .. part
      local stat, reason, code = uv.fs_lstat(current)
      assert(stat or code == "ENOENT", reason)
      assert(not stat or stat.type ~= "link", "symlink in transaction path: " .. path)
    end
    return current
  end
  function io.read(path)
    local full = resolve(path, true)
    local stat, reason, code = uv.fs_stat(full)
    if not stat and code == "ENOENT" then
      return null
    end
    assert(stat and stat.type == "file", reason or ("expected regular file: " .. path))
    local fd = assert(uv.fs_open(full, "r", 0))
    local data, failure = uv.fs_read(fd, stat.size, 0)
    uv.fs_close(fd)
    assert(data, failure)
    return data
  end
  function io.apply(effect)
    local full = resolve(effect.path)
    if effect.kind == "delete" then
      assert(same(io, effect), "CAS conflict: " .. effect.path)
      assert(uv.fs_unlink(full))
      return
    end
    local parent = vim.fs.dirname(full)
    -- Plans declare files; directories must already exist in the project.
    assert(uv.fs_stat(parent), "effect parent directory does not exist: " .. parent)
    local fd, temp = uv.fs_mkstemp(parent .. "/.zettypst-XXXXXX")
    assert(fd, temp)
    local ok, reason = pcall(function()
      local previous = uv.fs_stat(full)
      assert(uv.fs_fchmod(fd, previous and previous.mode % 512 or 420))
      local offset = 0
      while offset < #effect.content do
        local written = assert(uv.fs_write(fd, effect.content:sub(offset + 1), offset))
        assert(written > 0, "short write")
        offset = offset + written
      end
      assert(uv.fs_fsync(fd))
      assert(uv.fs_close(fd))
      fd = nil
      -- Recheck immediately before publication; create uses an exclusive link.
      assert(same(io, effect), "CAS conflict: " .. effect.path)
      if effect.kind == "create" then
        assert(uv.fs_link(temp, full))
      else
        assert(uv.fs_rename(temp, full))
      end
    end)
    if fd then
      uv.fs_close(fd)
    end
    uv.fs_unlink(temp)
    assert(ok, reason)
  end
  function io.lock()
    local dir = resolve(".zettypst")
    if not uv.fs_stat(dir) then
      assert(uv.fs_mkdir(dir, 448))
    end
    local path = dir .. "/host.lock"
    local fd, reason, code = uv.fs_open(path, "wx", 384)
    if not fd then
      assert(code == "EEXIST", reason)
      local owner = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path, "", 1)[1] or "released"
      return nil,
        ("another Zet operation holds %s (%s); delete it if that process has exited"):format(path, owner)
    end
    assert(uv.fs_write(fd, ("pid %d on %s\n"):format(uv.os_getpid(), uv.os_gethostname())))
    return { fd = fd, path = path, stat = uv.fs_fstat(fd) }
  end
  function io.unlock(token)
    local stat = uv.fs_lstat(token.path)
    uv.fs_close(token.fd)
    assert(stat and stat.ino == token.stat.ino and stat.dev == token.stat.dev, "lock ownership changed")
    assert(uv.fs_unlink(token.path))
  end
  function io.clean(footprint)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
        local name = vim.api.nvim_buf_get_name(buf)
        name = uv.fs_realpath(name) or vim.fs.normalize(name)
        local relative = name:sub(1, #root + 1) == root .. "/" and name:sub(#root + 2)
        assert(
          not relative or footprint[relative] == nil,
          "unsaved buffer in transaction footprint: " .. name
        )
      end
    end
  end
  function io.finish(result)
    require("zettypst.snapshot").refresh_root(root)
    local touched = {}
    for _, effect in ipairs(result.effects) do
      touched[root .. "/" .. effect.path] = effect.kind
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        local kind = touched[uv.fs_realpath(name) or name]
        if kind and not vim.bo[buf].modified then
          if kind == "delete" then
            vim.api.nvim_buf_delete(buf, {})
          else
            vim.api.nvim_buf_call(buf, function()
              vim.cmd("checktime")
            end)
          end
        end
      end
    end
  end
  return io
end
return M
