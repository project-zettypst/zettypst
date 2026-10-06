local M = {}
-- The server cancels waiting evaluations whenever a project file changes.
M.CONTENT_MODIFIED = -32801
function M.client(buf)
  local clients = vim.lsp.get_clients({ bufnr = buf or 0, name = "zettyp-lsp" })
  if #clients == 0 then
    local root = require("zettypst").root_dir(buf)
    if root then
      clients = vim.tbl_filter(function(client)
        return not client:is_stopped() and M.root(client) == root
      end, vim.lsp.get_clients({ name = "zettyp-lsp" }))
    end
  end
  assert(#clients == 1, "Zet requires exactly one zettyp-lsp client for this project")
  return clients[1]
end
function M.root(client)
  local root = assert(client.config.root_dir or client.root_dir, "zettyp-lsp has no project root")
  return vim.uv.fs_realpath(root) or root
end
function M.context(buf)
  local client = M.client(buf)
  return { client = client, root = M.root(client), bufnr = buf or 0 }
end
function M.eval(ctx, entry, inputs, sources, detached)
  local params = { entry = entry, inputs = inputs or vim.empty_dict() }
  if detached then
    params.sources = sources or vim.empty_dict()
  end
  local request = {
    command = detached and "zettyp.evalDetached" or "zettyp.eval",
    arguments = { params },
  }
  local response, failure
  for _ = 1, 3 do
    response, failure =
      ctx.client:request_sync("workspace/executeCommand", request, require("zettypst.config").options.timeout)
    assert(response, failure or "evaluation request failed")
    if not (response.err and response.err.code == M.CONTENT_MODIFIED) then
      break
    end
  end
  assert(not response.err, response.err and response.err.message)
  local result = response.result
  assert(
    type(result) == "table" and type(result.revision) == "number" and type(result.output) == "table",
    "invalid evaluation response"
  )
  return result
end
function M.detached(ctx, entry, inputs, sources)
  return M.eval(ctx, entry, inputs, sources, true)
end
-- Title refreshes must not block editor input while Typst evaluates.
-- Neither form names a buffer: the client then flushes edits from every buffer,
-- all of which the evaluation reads.
function M.eval_async(ctx, entry, done)
  return ctx.client:request("workspace/executeCommand", {
    command = "zettyp.eval",
    arguments = { { entry = entry } },
  }, function(err, result)
    if err then
      done(err.message, nil, err.code)
      return
    end
    if type(result) ~= "table" or type(result.revision) ~= "number" or type(result.output) ~= "table" then
      done("invalid evaluation response", nil)
      return
    end
    done(nil, result)
  end)
end
return M
