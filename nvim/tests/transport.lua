vim.opt.rtp:prepend(vim.fn.getcwd())
local transport = require("zettypst.transport")
local ok = { result = { revision = 2, output = {} } }
local function client(responses)
  local calls = 0
  return {
    request_sync = function()
      calls = calls + 1
      return responses[calls]
    end,
    calls = function()
      return calls
    end,
  }
end
local modified = { err = { code = transport.CONTENT_MODIFIED, message = "source snapshot changed" } }

local retried = client({ modified, ok })
assert(transport.eval({ client = retried }, "nodes.typ").revision == 2)
assert(retried.calls() == 2, "ContentModified must re-run the evaluation")

local exhausted = client({ modified, modified, modified, ok })
assert(not pcall(transport.eval, { client = exhausted }, "nodes.typ"))
assert(exhausted.calls() == 3, "retries must be bounded")

local failed = client({ { err = { code = -32603, message = "panic" } }, ok })
assert(not pcall(transport.eval, { client = failed }, "nodes.typ"))
assert(failed.calls() == 1, "other errors must not retry")
print("passed transport retries")
