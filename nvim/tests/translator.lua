vim.opt.rtp:prepend(vim.fn.getcwd())
local preset = vim.deepcopy(require("zettypst.presets.kickstart"))
preset.autostart = false
preset.capture.bibliography.translators =
  { crossref = false, arxiv_endpoint = "http://127.0.0.1:9/arxiv", timeout = 2 }
require("zettypst").setup(preset)

local warnings = {}
local notify = vim.notify
vim.notify = function(message)
  warnings[#warnings + 1] = message
end
local request = require("zettypst.capture").prepare({}, "web", {
  url = "https://arxiv.org/abs/2401.12345",
  from_browser = true,
  metadata = { citation_title = "Fallback title" },
})
vim.notify = notify
assert(request.title == "Fallback title", request.title)
assert(#warnings == 1 and warnings[1]:find("^Zet capture: "), vim.inspect(warnings))
local decoded = require("zettypst.capture.translator").resolve({
  html = "<title>Caf&#233; &#x2019;s &amp; &#20013;&#25991; &rsquo;</title>",
})
assert(decoded.entry.fields.title == "Café ’s & 中文 ’", decoded.entry.fields.title)
local capture = require("zettypst.capture")
local payload = {
  url = "https://example.test/article",
  from_browser = true,
  metadata = { title = "Article", keywords = "", meta = { citation_keywords = "alpha; beta" } },
}
assert(vim.deep_equal(capture.prepare({}, "web", payload).keywords, { "alpha", "beta" }))
payload.metadata.keywords = "page"
assert(vim.deep_equal(capture.prepare({}, "web", payload).keywords, { "page" }))
payload.keywords = { "explicit" }
assert(vim.deep_equal(capture.prepare({}, "web", payload).keywords, { "explicit" }))
local http = require("zettypst.capture.http")
local fetch = http.text
local opts = require("zettypst.config").options.capture.bibliography.translators
opts.crossref = true
local message = { title = { "Dated paper" } }
http.text = function()
  return vim.json.encode({ message = message })
end
local function year()
  return require("zettypst.capture.translator").resolve({ url = "https://doi.org/10.1234/test" }).entry.fields.year
end
assert(year() == "")
for i, field in ipairs({ "published-online", "published-print", "published", "issued" }) do
  message[field] = { ["date-parts"] = { { 2020 + i } } }
  assert(year() == tostring(2020 + i), field .. " must take precedence")
end
http.text, opts.crossref = fetch, false
print("passed translator fallback reporting, entity decoding and capture keywords")
