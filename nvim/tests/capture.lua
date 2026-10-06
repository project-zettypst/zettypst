vim.opt.rtp:prepend(vim.fn.getcwd())
local root = assert(vim.env.ZETTYPST_TEST_ROOT)
local endpoint = assert(vim.env.CAPTURE_TEST_URL)
local pdf = assert(vim.env.CAPTURE_TEST_PDF)
local options = vim.deepcopy(require("zettypst.presets.kickstart"))
options.titles = { enabled = false }
options.capture.bibliography.translators = {
  arxiv_endpoint = endpoint .. "/arxiv",
  crossref_endpoint = endpoint .. "/crossref",
}
vim.lsp.config("zettyp-lsp", {
  cmd = { vim.env.ZETTYPST_TEST_LSP, "--ignore-system-fonts" },
  filetypes = { "typst" },
  init_options = { entry = "lsp.typ" },
})
vim.api.nvim_set_current_dir(root)
require("zettypst").setup(options)
local capture = require("zettypst.capture")
local assets = require("zettypst.capture.assets")
local bib = require("zettypst.capture.bib")
local config = require("zettypst.config")
local function ctx()
  return require("zettypst.commands").context()
end
local function run(kind, payload)
  local result = capture.run(kind, payload, ctx())
  assert(result.ok, vim.inspect(result))
  assert(not result.buffer_error, result.buffer_error)
  return result
end
local web = run("web", { url = endpoint .. "/page", selection = '#panic("not code") $math$' })
assert(web.status == "created")
assert(web.result.created and web.result.key == vim.NIL)
local content = assert(assets.read(web.note_path))
assert(content:find("Fixture Web Page", 1, true) and content:find("#text(", 1, true))
assert(run("web", { url = endpoint .. "/page" }).note_id == web.note_id)
assert(
  run("web", { url = "https://browser.test/item", title = "Browser-only metadata", from_browser = true }).ok
)
local invalid = root .. "/invalid.pdf"
vim.fn.writefile({ "<html>not a PDF</html>" }, invalid)
local before_bib = assets.read(root .. "/ref.bib")
local ok = pcall(capture.run, "paper", { path = invalid }, ctx())
assert(not ok and assets.read(root .. "/ref.bib") == before_bib)
local paper = run(
  "paper",
  { path = pdf, bibtex = "@article{fixture, title={Fixture Paper}, doi={10.1234/fixture}, year={2026}}" }
)
assert(paper.translator == "bibtex" and paper.key == "fixture")
assert(paper.result.created and paper.result.key == "fixture")
assert(assets.read(paper.asset_path) == assets.read(pdf))
assert(paper.asset_path:match("assets/[0-9a-f]+%.pdf$"))
local repeated = run("paper", {
  path = pdf,
  bibtex = "@article{different, title={Fixture Paper}, doi={10.1234/fixture}, author={Ada Lovelace}}",
})
assert(repeated.note_id == paper.note_id and repeated.status == "exists")
assert(not repeated.result.created and repeated.result.key == "fixture")
assert(assert(assets.read(root .. "/ref.bib")):find("Ada Lovelace", 1, true))
assert(run("paper-note", { key = "fixture" }).note_id == paper.note_id)
local remote =
  run("paper", { url = endpoint .. "/paper.pdf", metadata = { citation_title = "Downloaded paper" } })
assert(remote.asset_path == paper.asset_path and remote.note_id == paper.note_id)
local translator = require("zettypst.capture.translator")
local crossref = translator.resolve({ file = pdf })
assert(crossref and crossref.translator == "crossref", vim.inspect(crossref))
assert(crossref.entry.fields.doi == "10.1234/pdftext")
local arxiv = translator.resolve({ url = "https://arxiv.org/abs/2401.12345" })
assert(arxiv and arxiv.translator == "arxiv")
assert(arxiv.entry.fields.author == "Fixture Author")
local generic = translator.resolve({
  metadata = { citation_title = "Publisher paper", citation_author = { "First Author", "Second Author" } },
})
assert(generic and generic.translator == "generic_html")
config.options.capture.bibliography.translators.crossref = false
local keywords = capture.prepare(ctx(), "paper", {
  path = pdf,
  page_metadata = { citation_title = "Publisher paper", citation_keywords = "alpha; beta" },
})
config.options.capture.bibliography.translators.crossref = true
assert(vim.deep_equal(keywords.keywords, { "alpha", "beta" }))
local parsed = bib.parse_text(assert(assets.read(root .. "/ref.bib")))
assert(#parsed >= 1)
-- A prepared request cannot overwrite bibliography edits made afterwards.
local context = ctx()
local pending = capture.prepare(context, "paper", {
  path = pdf,
  bibtex = "@article{fixture, title={Fixture Paper}, doi={10.1234/fixture}, journal={New journal}}",
})
local bibpath = root .. "/ref.bib"
local original = assert(assets.read(bibpath))
local changed_fd = assert(vim.uv.fs_open(bibpath, "w", 384))
assert(vim.uv.fs_write(changed_fd, original .. "\n% concurrent writer\n", 0))
vim.uv.fs_close(changed_fd)
local changed = assert(assets.read(bibpath))
local rejected = require("zettypst.executor").run(context, config.options.entries.capture, pending)
assert(not rejected.ok and rejected.error:find("bibliography changed"), vim.inspect(rejected))
assert(assets.read(bibpath) == changed)
-- A failed textual plan leaves only its already-validated immutable asset.
local manifest = assert(assets.read(root .. "/.zettypst/source.toml"))
local unique_pdf = root .. "/unique.pdf"
local fd = assert(vim.uv.fs_open(unique_pdf, "w", 384))
assert(vim.uv.fs_write(fd, assert(assets.read(pdf)) .. "\n% different attachment\n", 0))
vim.uv.fs_close(fd)
local rejected_request = capture.prepare(
  ctx(),
  "paper",
  { path = unique_pdf, title = "Rejected metadata", bibtex = "@misc{rejected,title={Rejected metadata}}" }
)
rejected_request.metadata = { unknown_field = true }
local failed = require("zettypst.executor").run(ctx(), config.options.entries.capture, rejected_request)
assert(not failed.ok)
assert(assets.read(root .. "/.zettypst/source.toml") == manifest)
assert(assets.read(paper.asset_path) == assets.read(pdf))
for _, client in ipairs(vim.lsp.get_clients({ name = "zettyp-lsp" })) do
  client:stop(true)
end
print(
  "PASS capture: web, browser payload, PDF, URL, bibliography reuse/enrichment, translators, immutable assets and failed commits"
)
