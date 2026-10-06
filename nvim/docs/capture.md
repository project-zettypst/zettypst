# Capture

Capture is optional. The kickstart preset enables it, and new kickstart projects already contain the capture entries in `.zettypst/host/` and an empty `.zettypst/captures.json` registry. For other configurations, set `capture` (at least `capture.bibliography.path`), `entries.capture` and `actions.capture.collect`; `require("zettypst.capture").collect` provides the default prompts through `vim.ui`.

## Who decides what

Neovim gathers facts. It fetches pages with `curl`, stores PDFs, reads metadata from PDF text (`pdftotext`), DOI/Crossref, arXiv and HTML citation tags, and parses the existing bibliography into entries with their text spans.

The project's Typst entry makes every decision through `@preview/zettyp-capture`. It finds the existing BibTeX entry for the same work by DOI, arXiv ID, URL or stored file, or by the same key and title. It chooses the key, and a different work under a taken key receives `-2`, `-3`, and so on. Existing entries keep their text and only gain missing fields; explicitly empty fields stay empty. It decides whether a card already exists, using the capture registry, the same PDF, or the project's `existing(key, nodes)` callback. Finally it plans the note, manifest and registry effects. Verification then checks the resulting graph before anything is written, and the plan commits as one textual transaction.

PDF bytes are validated and stored once at `assets/<sha256>.pdf` before the transaction; existing files are verified before reuse. A failed transaction can leave an unreferenced immutable PDF, and it never removes the source PDF.

The plan's `result` dictionary carries `created` and `key` from Typst's capture decision. The executor exposes it as `result.result` only after a successful commit and unlock; capture uses it to report `created` or `exists`. Verification inputs remain private to verification. A reused card may still enrich the bibliography or update the registry, so the outcome is not inferred from the file effects.

## Typst package

The `capture/` directory is the source of `@preview/zettyp-capture:0.1.0`. It depends on `zettyp-host` and exports `plan`, `verify` and `merge-bibliography`. A project entry calls `capture.plan(request, ...)` with its nodes, a `settings` module (`bibliography-path`, `render`, `extra-effects`), and callbacks for file reading, ID allocation, note paths, manifest registration and verification. It may also pass `existing` to recognize cards that predate the registry. File reads go through the project's callback, so package code never resolves paths against its own package root.

To use a local checkout of the package (Python 3.11 or newer):

```sh
python3 scripts/package_capture.py --package-path <typst-package-path> --link
```

Point `TYPST_PACKAGE_PATH` at the same directory for both the editor LSP and the Chrome native host. Without arguments, the script assembles a copied package under `.dev/dist/preview/zettyp-capture/0.1.0/`; it does not publish anything.

## Commands

- `:Zet capture`: choose web, paper, or paper-note.
- `:Zet capture web https://example.org/article`: capture a web page.
- `:Zet capture paper /absolute/path/paper.pdf`: import a local PDF, leaving the original intact.
- `:Zet capture paper https://example.org/paper.pdf`: download and import a PDF.
- `:Zet capture paper-note existing-key`: create a card for an existing BibTeX entry, or reuse its card.

Omit the source to open an input prompt. Paths containing spaces are supported. Failed metadata lookups are reported as warnings, and capture continues with the remaining sources. `require("zettypst.capture").run(kind, payload)` accepts explicit metadata or BibTeX.

## Configuration

Extend the preset with Neovim's standard table merge:

```lua
local opts = vim.tbl_deep_extend("force", {}, require("zettypst.presets.kickstart"), {
  capture = {
    browser = { root = vim.fn.expand("~/notes") },
    bibliography = {
      path = "ref.bib",
      translators = { pdf_text = true, pdf_text_pages = 3 },
    },
  },
})
require("zettypst").setup(opts)
```

Keep `bibliography.path` equal to `bibliography-path` in `.zettypst/host/capture-config.typ`, which also owns note rendering, project metadata and extra effects. Project templates apply to both editor and browser captures. Optional `capture.templates[kind] = function(request, ctx) return patch end` hooks transform interactive requests; they are Lua functions and are not serialized into the browser host.

## Chrome

1. Run `:Zet capture extension-path` to copy the unpacked extension directory.
2. Load that directory in Chrome's extension manager with developer mode enabled.
3. Run `:Zet capture install-native-host` from the target project, or configure `capture.browser.root` first. The bundled extension has a stable ID, so no ID argument is needed.
4. Open the extension and use **Check native host**. `Done` confirms connectivity.

The popup supports automatic, page and PDF capture; page and linked-PDF context menus are also available. PDF detection covers direct URLs, citation metadata and embedded PDF elements. Chrome downloads PDFs with its browser session and passes the completed local path to Neovim; originals stay in Chrome's downloads directory. Browser pages supply their metadata and selection directly, without a second fetch.

The installer supports Google Chrome on macOS and Linux. Re-run it after changing the browser project or the serialized LSP configuration. Keep the default native host name unless you also change the extension's `HOST` constant, and reload the unpacked extension after updating its JavaScript.

## Verification

`python3 tests/capture.py` compiles the package's merge tests in `tests/capture_merge.typ`, then exercises real LSP capture, native message framing, translators, deduplication, failed commits, immutable assets and final document compilation. It uses temporary projects and a local HTTP fixture server. It expects a built ZetTypst checkout next to this repository; `ZETTYPST_REPO` and `ZETTYPST_TEST_LSP` override these locations.

`node tests/capture_browser.cjs` checks extension routing and the download lifecycle against mocked Chrome APIs. It does not replace a real Chrome and native-host connectivity check.
