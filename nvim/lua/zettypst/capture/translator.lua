-- Adapted from zk-lsp.nvim metadata translators.
local bib = require("zettypst.capture.bib")
local config = require("zettypst.config")
local http = require("zettypst.capture.http")

local M = {}

local function trim(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function collapse_ws(value)
  return trim(tostring(value or ""):gsub("%s+", " "))
end

local entities = {
  amp = "&",
  lt = "<",
  gt = ">",
  quot = '"',
  apos = "'",
  nbsp = " ",
  ndash = "–",
  mdash = "—",
  hellip = "…",
  lsquo = "‘",
  rsquo = "’",
  ldquo = "“",
  rdquo = "”",
}
local function codepoint(number)
  if not number or number < 1 or number > 0x10FFFF or (number >= 0xD800 and number <= 0xDFFF) then
    return " "
  end
  return vim.fn.nr2char(number, true)
end
local function decode_entities(value)
  value = tostring(value or "")
  value = value:gsub("&#[xX](%x+);", function(code)
    return codepoint(tonumber(code, 16))
  end)
  value = value:gsub("&#(%d+);", function(code)
    return codepoint(tonumber(code))
  end)
  value = value:gsub("&(%a+);", function(name)
    return entities[name] or " "
  end)
  return collapse_ws(value)
end

local function strip_tags(value)
  return decode_entities(tostring(value or ""):gsub("<[^>]+>", " "))
end

local function url_encode(value)
  return tostring(value or ""):gsub("([^%w%-%._~])", function(ch)
    return string.format("%%%02X", ch:byte())
  end)
end

local function as_list(value)
  if value == nil or value == "" then
    return {}
  end
  if type(value) == "table" then
    if vim.islist(value) then
      return value
    end
    return { value }
  end
  return { value }
end

local function first_value(meta, ...)
  for _, key in ipairs({ ... }) do
    local values = meta[key:lower()]
    if values then
      for _, value in ipairs(as_list(values)) do
        value = collapse_ws(value)
        if value ~= "" then
          return value
        end
      end
    end
  end
  return ""
end

local function add_meta(meta, key, value)
  key = trim(key):lower()
  if key == "" or value == nil then
    return
  end
  if type(value) == "table" and vim.islist(value) then
    for _, item in ipairs(value) do
      add_meta(meta, key, item)
    end
    return
  end
  if type(value) == "table" then
    return
  end
  value = decode_entities(value)
  if value == "" then
    return
  end
  if meta[key] == nil then
    meta[key] = value
  elseif type(meta[key]) == "table" and vim.islist(meta[key]) then
    meta[key][#meta[key] + 1] = value
  else
    meta[key] = { meta[key], value }
  end
end

local function collect_jsonld_item(meta, item)
  if type(item) ~= "table" then
    return
  end
  if type(item["@graph"]) == "table" then
    for _, child in ipairs(item["@graph"]) do
      collect_jsonld_item(meta, child)
    end
  end
  add_meta(meta, "schema.title", item.headline or item.name)
  add_meta(meta, "schema.date", item.datePublished or item.dateCreated or item.dateModified)
  add_meta(meta, "schema.doi", item.doi)
  if type(item.identifier) == "string" then
    add_meta(meta, "schema.identifier", item.identifier)
  elseif type(item.identifier) == "table" then
    add_meta(meta, "schema.identifier", item.identifier.value or item.identifier.name)
  end
  if type(item.isPartOf) == "table" then
    add_meta(meta, "schema.container", item.isPartOf.name)
  end
  if type(item.author) == "table" then
    if vim.islist(item.author) then
      for _, author in ipairs(item.author) do
        if type(author) == "table" then
          add_meta(meta, "schema.author", author.name)
        else
          add_meta(meta, "schema.author", author)
        end
      end
    else
      add_meta(meta, "schema.author", item.author.name)
    end
  else
    add_meta(meta, "schema.author", item.author)
  end
end

local function collect_jsonld(meta, values)
  for _, value in ipairs(as_list(values)) do
    if type(value) == "string" then
      local ok, decoded = pcall(vim.json.decode, value)
      if ok then
        collect_jsonld(meta, decoded)
      end
    elseif type(value) == "table" and vim.islist(value) then
      for _, item in ipairs(value) do
        collect_jsonld_item(meta, item)
      end
    else
      collect_jsonld_item(meta, value)
    end
  end
end

local function collect_context_metadata(context)
  local meta = {}
  local function collect_table(tbl)
    for key, value in pairs(tbl or {}) do
      if key == "meta" and type(value) == "table" then
        collect_table(value)
      elseif type(value) == "table" and vim.islist(value) then
        for _, item in ipairs(value) do
          add_meta(meta, key, item)
        end
      else
        add_meta(meta, key, value)
      end
    end
  end
  collect_table(context.metadata)
  if type(context.metadata) == "table" then
    collect_jsonld(meta, context.metadata.jsonLd or context.metadata.jsonld)
  end

  local html = context.html or ""
  for attrs in html:gmatch("<meta%s+([^>]-)>") do
    local name = attrs:match('name%s*=%s*"([^"]+)"') or attrs:match("name%s*=%s*'([^']+)'")
    local property = attrs:match('property%s*=%s*"([^"]+)"') or attrs:match("property%s*=%s*'([^']+)'")
    local itemprop = attrs:match('itemprop%s*=%s*"([^"]+)"') or attrs:match("itemprop%s*=%s*'([^']+)'")
    local content = attrs:match('content%s*=%s*"([^"]*)"') or attrs:match("content%s*=%s*'([^']*)'")
    add_meta(meta, name or property or itemprop, content)
  end
  local title = html:match("<title[^>]*>(.-)</title>")
  add_meta(meta, "title", title and strip_tags(title) or "")
  local canonical = html:match('<link[^>]-rel%s*=%s*"canonical"[^>]-href%s*=%s*"([^"]+)"')
    or html:match("<link[^>]-rel%s*=%s*'canonical'[^>]-href%s*=%s*'([^']+)'")
  add_meta(meta, "canonical", canonical)
  for script in html:gmatch("<script[^>]-application/ld%+json[^>]*>(.-)</script>") do
    collect_jsonld(meta, script)
  end
  return meta
end

local function extract_doi(value)
  value = tostring(value or "")
  local doi = value:match("10%.%d%d%d%d+/%S+")
  if not doi then
    return nil
  end
  doi = doi:gsub("[\"'<>%[%]{}]+$", "")
  doi = doi:gsub("[%.,;:]+$", "")
  return bib.normalize_doi(doi)
end

local function add_identifier(ids, kind, value)
  value = trim(value)
  if value == "" then
    return
  end
  if kind == "doi" then
    value = bib.normalize_doi(value)
  elseif kind == "arxiv" then
    value = bib.normalize_arxiv_id(value)
  end
  if value ~= "" then
    ids[kind] = ids[kind] or value
  end
end

local function pdf_text(context, opts)
  if not opts.pdf_text then
    return ""
  end
  local path = trim(context.file)
  if path == "" or vim.fn.filereadable(path) == 0 or vim.fn.executable("pdftotext") ~= 1 then
    return ""
  end
  local result = vim
    .system({
      "pdftotext",
      "-f",
      "1",
      "-l",
      tostring(opts.pdf_text_pages),
      path,
      "-",
    }, { text = true })
    :wait(opts.timeout * 1000)
  if result.code ~= 0 then
    return ""
  end
  return result.stdout or ""
end

local function extract_identifiers(context, opts)
  local ids = {}
  local meta = collect_context_metadata(context)
  for _, value in ipairs({
    context.url or "",
    context.final_url or "",
    context.source_url or "",
    context.title or "",
    context.file or "",
    context.html or "",
    pdf_text(context, opts),
    first_value(
      meta,
      "citation_doi",
      "dc.identifier",
      "dc.identifier.doi",
      "prism.doi",
      "doi",
      "schema.doi",
      "schema.identifier"
    ),
  }) do
    local doi = extract_doi(value)
    if doi then
      add_identifier(ids, "doi", doi)
    end
    local arxiv_id = bib.extract_arxiv_id(value)
    if arxiv_id then
      add_identifier(ids, "arxiv", arxiv_id)
    end
  end
  add_identifier(ids, "arxiv", first_value(meta, "citation_arxiv_id", "arxiv", "eprint"))
  return ids, meta
end

local function year_from_date(value)
  return tostring(value or ""):match("%d%d%d%d") or ""
end

local function creator_name(item)
  if type(item) == "string" then
    return collapse_ws(item)
  end
  if type(item) ~= "table" then
    return ""
  end
  local literal = item.literal or item.name
  if literal then
    return collapse_ws(literal)
  end
  local family = collapse_ws(item.family)
  local given = collapse_ws(item.given)
  if family ~= "" and given ~= "" then
    return family .. ", " .. given
  end
  return family ~= "" and family or given
end

local function author_field(authors)
  local result = {}
  for _, author in ipairs(as_list(authors)) do
    local name = creator_name(author)
    if name ~= "" then
      result[#result + 1] = name
    end
  end
  return table.concat(result, " and ")
end

local function bibtex_candidate(context)
  local parsed = context.bibtex and bib.parse_entry(context.bibtex) or nil
  if not parsed then
    return nil
  end
  return {
    translator = "bibtex",
    entry = parsed,
    keywords = bib.split_words(bib.field(parsed, "keywords")),
  }
end

local function arxiv_candidate(_, opts, identifiers)
  if not opts.arxiv then
    return nil
  end
  local arxiv_id = identifiers.arxiv
  if not arxiv_id or arxiv_id == "" then
    return nil
  end
  local endpoint = opts.arxiv_endpoint or "https://export.arxiv.org/api/query"
  local xml, err = http.text(endpoint .. "?id_list=" .. url_encode(arxiv_id), { timeout = opts.timeout })
  if not xml then
    return nil, err
  end
  local entry_xml = xml:match("<entry>(.-)</entry>")
  if not entry_xml then
    return nil, "arXiv returned no entry for " .. arxiv_id
  end

  local authors = {}
  for author in entry_xml:gmatch("<author>(.-)</author>") do
    local name = strip_tags(author:match("<name>(.-)</name>") or "")
    if name ~= "" then
      authors[#authors + 1] = name
    end
  end

  local published = strip_tags(entry_xml:match("<published>(.-)</published>") or "")
  local normalized_id = bib.normalize_arxiv_id(arxiv_id)
  local primary = entry_xml:match('<arxiv:primary_category[^>]-term="([^"]+)"')
    or entry_xml:match('<category[^>]-term="([^"]+)"')
    or ""
  local fields = {
    author = author_field(authors),
    title = strip_tags(entry_xml:match("<title>(.-)</title>") or ""),
    year = year_from_date(published),
    url = "https://arxiv.org/abs/" .. normalized_id,
    eprint = normalized_id,
    archiveprefix = "arXiv",
    primaryclass = primary,
    abstract = strip_tags(entry_xml:match("<summary>(.-)</summary>") or ""),
    doi = strip_tags(entry_xml:match("<arxiv:doi[^>]*>(.-)</arxiv:doi>") or ""),
    journal = strip_tags(entry_xml:match("<arxiv:journal_ref[^>]*>(.-)</arxiv:journal_ref>") or ""),
  }
  local entry_type = fields.journal ~= "" and "article" or "misc"
  return {
    translator = "arxiv",
    entry = {
      type = entry_type,
      key = bib.derive_key(fields),
      fields = fields,
    },
    keywords = primary ~= "" and { primary } or {},
  }
end

local function date_parts_year(value)
  if type(value) ~= "table" then
    return nil
  end
  local parts = value["date-parts"]
  if type(parts) == "table" and type(parts[1]) == "table" and parts[1][1] then
    return tostring(parts[1][1])
  end
  return nil
end

local crossref_types = {
  ["book-chapter"] = "incollection",
  book = "book",
  ["journal-article"] = "article",
  ["proceedings-article"] = "inproceedings",
}

local function crossref_candidate(_, opts, identifiers)
  if not opts.crossref then
    return nil
  end
  local doi = identifiers.doi
  if not doi or doi == "" then
    return nil
  end
  local endpoint = opts.crossref_endpoint or "https://api.crossref.org/works"
  local json, err = http.text(endpoint .. "/" .. url_encode(doi), {
    timeout = opts.timeout,
    headers = { "Accept: application/json" },
  })
  if not json then
    return nil, err
  end
  local ok, decoded = pcall(vim.json.decode, json)
  local message = ok and decoded and decoded.message or nil
  if type(message) ~= "table" then
    return nil, "Crossref returned an invalid response"
  end
  local title = type(message.title) == "table" and message.title[1] or message.title
  local container = type(message["container-title"]) == "table" and message["container-title"][1]
    or message["container-title"]
  local fields = {
    author = author_field(message.author),
    title = strip_tags(title or ""),
    year = date_parts_year(message.issued) or date_parts_year(message.published) or date_parts_year(
      message["published-print"]
    ) or date_parts_year(message["published-online"]) or "",
    doi = bib.normalize_doi(message.DOI or doi),
    url = collapse_ws(message.URL or ("https://doi.org/" .. doi)),
    journal = message.type == "journal-article" and collapse_ws(container) or "",
    booktitle = message.type == "proceedings-article" and collapse_ws(container) or "",
    publisher = collapse_ws(message.publisher),
    volume = collapse_ws(message.volume),
    number = collapse_ws(message.issue),
    pages = collapse_ws(message.page),
    abstract = strip_tags(message.abstract or ""),
  }
  return {
    translator = "crossref",
    entry = {
      type = crossref_types[message.type] or "misc",
      key = bib.derive_key(fields),
      fields = fields,
    },
    keywords = {},
  }
end

local function generic_html_candidate(context, _, identifiers, meta)
  local authors = meta.citation_author or meta["dc.creator"] or meta.author
  local fields = {
    author = author_field(authors or meta["schema.author"]),
    title = first_value(
      meta,
      "citation_title",
      "dc.title",
      "schema.title",
      "og:title",
      "ogtitle",
      "twitter:title",
      "twittertitle",
      "title"
    ),
    year = year_from_date(
      first_value(meta, "citation_publication_date", "citation_date", "dc.date", "schema.date", "date")
    ),
    doi = identifiers.doi or "",
    url = first_value(meta, "citation_abstract_html_url", "canonical", "canonicalurl", "og:url", "url"),
    journal = first_value(meta, "citation_journal_title", "prism.publicationname", "schema.container"),
    booktitle = first_value(meta, "citation_conference_title"),
    abstract = first_value(
      meta,
      "citation_abstract",
      "dc.description",
      "description",
      "og:description",
      "ogdescription",
      "twitter:description",
      "twitterdescription"
    ),
  }
  if fields.url == "" then
    fields.url = context.url or context.final_url or context.source_url or ""
  end
  if identifiers.arxiv and identifiers.arxiv ~= "" then
    fields.eprint = identifiers.arxiv
    fields.archiveprefix = "arXiv"
  end
  if fields.title == "" and fields.author == "" and fields.doi == "" and fields.eprint == nil then
    return nil
  end
  local entry_type = fields.booktitle ~= "" and "inproceedings"
    or (fields.journal ~= "" and "article" or "misc")
  return {
    translator = "generic_html",
    entry = {
      type = entry_type,
      key = bib.derive_key(fields),
      fields = fields,
    },
    keywords = bib.split_words(first_value(meta, "citation_keywords", "keywords")),
  }
end

-- The first successful translator returns { translator, entry, keywords }, plus lookup warnings.
function M.resolve(context)
  context = context or {}
  local opts = config.options.capture.bibliography.translators
  if not opts.enabled then
    return nil, {}
  end
  local identifiers, meta = extract_identifiers(context, opts)
  local warnings = {}
  local resolvers = {
    bibtex_candidate,
    arxiv_candidate,
    crossref_candidate,
  }
  if opts.generic_html then
    resolvers[#resolvers + 1] = generic_html_candidate
  end
  for _, resolver in ipairs(resolvers) do
    local candidate, err = resolver(context, opts, identifiers, meta)
    if candidate then
      return candidate, warnings
    end
    if err and err ~= "" then
      warnings[#warnings + 1] = err
    end
  end
  return nil, warnings
end

return M
