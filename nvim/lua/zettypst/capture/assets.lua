local M = {}
local uv = vim.uv

function M.read(path)
  local fd, err = uv.fs_open(path, "r", 0)
  if not fd then
    return nil, err
  end
  local stat = uv.fs_fstat(fd)
  if not stat or stat.type ~= "file" or stat.size > 256 * 1024 * 1024 then
    uv.fs_close(fd)
    return nil, "expected a regular file of at most 256 MiB"
  end
  local data, failure = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return data, failure
end

-- Publish immutable bytes before the text transaction. An unsuccessful capture
-- may leave an unreferenced asset; it never removes the user's original PDF.
function M.store(root, source)
  local data = assert(M.read(vim.fn.expand(source)))
  assert(data:sub(1, 5) == "%PDF-", "capture requires PDF content, not an HTML download")
  local digest = vim.fn.sha256(data)
  local dir = root .. "/assets"
  local stat = uv.fs_lstat(dir)
  if not stat then
    local ok = uv.fs_mkdir(dir, 448)
    assert(ok or uv.fs_lstat(dir), "could not create assets directory")
    stat = uv.fs_lstat(dir)
  end
  assert(stat.type == "directory", "assets must be a real directory, not a symlink")
  local relative = "assets/" .. digest .. ".pdf"
  local target = root .. "/" .. relative
  local function existing()
    local item = uv.fs_lstat(target)
    if not item then
      return false
    end
    assert(item.type == "file", "asset target must be a regular file")
    local bytes = assert(M.read(target))
    assert(vim.fn.sha256(bytes) == digest, "existing asset hash mismatch")
    return true
  end
  if not existing() then
    local temporary = dir .. "/.capture-" .. uv.os_getpid() .. "-" .. uv.hrtime()
    local fd = assert(uv.fs_open(temporary, "wx", 384))
    local ok, err = pcall(function()
      assert(uv.fs_write(fd, data, 0) == #data, "short PDF write")
      assert(uv.fs_fsync(fd))
      assert(uv.fs_close(fd))
      fd = nil
      local linked = uv.fs_link(temporary, target)
      assert(linked or existing(), "could not publish PDF asset")
    end)
    if fd then
      uv.fs_close(fd)
    end
    uv.fs_unlink(temporary)
    assert(ok, err)
  end
  return { path = relative, sha256 = digest, size = #data }
end

return M
