-- lib/unified/rehype_document/init.lua
-- rehype plugin: wrap hast content in a full HTML document skeleton.
-- Port of rehype-document.
--
-- Wraps the tree's children in <body>, adds a <head> with title, meta, link,
-- and script elements, and prepends a <!doctype html> raw node.
--
-- Options:
--   opts.title   string        page title (default "")
--   opts.lang    string        html[lang] attribute (default nil → omit)
--   opts.css     table|string  stylesheet href(s) — added as <link rel="stylesheet">
--   opts.js      table|string  script src(s)      — added as <script src>
--   opts.meta    table         list of attribute-maps for <meta> elements
--                              e.g. { {charset="utf-8"}, {name="viewport", content="..."} }
--
-- Plugin signature (unified):
--   function(processor, opts)
--
-- Usage:
--   local rehype = require("lib.unified.rehype")
--   local doc    = require("lib.unified.rehype_document")
--   local p = rehype():use(doc, {
--     title = "My Page",
--     lang  = "en",
--     css   = { "style.css" },
--     js    = { "app.js" },
--     meta  = { {charset = "utf-8"} },
--   })

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- ── Node constructors ─────────────────────────────────────────────────────────

--: (string, any, any) -> any
local function el(tag, props, children)
  return { type = "element", tag = tag, props = props or {}, children = children or {} }
end

--: (string) -> any
local function text(value)
  return { type = "text", value = value }
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Normalize a string-or-table option to a flat list of strings.
--: (any) -> any
local function to_list(v)
  if v == nil then return {} end
  if type(v) == "string" then return { v } end
  return v
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (any, any) -> nil
function M.plugin(processor, opts)
  opts = opts or {}
  local title = opts.title or ""
  local lang  = opts.lang
  local css   = to_list(opts.css)
  local js    = to_list(opts.js)
  local meta  = opts.meta or {}

  processor:use_transformer(function(tree)
    -- Build <head> children.
    local head_children = {}

    -- <meta> elements first.
    for _, attrs in ipairs(meta) do
      local props = {}
      for k, v in pairs(attrs) do props[k] = v end
      head_children[#head_children + 1] = el("meta", props, {})
    end

    -- <title>.
    head_children[#head_children + 1] = el("title", {}, { text(title) })

    -- <link rel="stylesheet"> for each CSS href.
    for _, href in ipairs(css) do
      head_children[#head_children + 1] = el("link", {
        rel  = "stylesheet",
        href = tostring(href),
      }, {})
    end

    -- <script src> for each JS href.
    for _, src in ipairs(js) do
      head_children[#head_children + 1] = el("script", {
        src = tostring(src),
      }, {})
    end

    -- Build <html> props.
    local html_props = {}
    if lang and lang ~= "" then
      html_props.lang = lang
    end

    -- Wrap original children in <body>.
    local body = el("body", {}, tree.children or {})

    -- Assemble <html>.
    local html_el = el("html", html_props, {
      el("head", {}, head_children),
      body,
    })

    -- Prepend doctype as a raw node.
    local doctype = { type = "raw", value = "<!doctype html>" }

    tree.children = { doctype, html_el }
    return tree
  end)
end

setmetatable(M, {
  __call = function(_self, processor, opts)
    M.plugin(processor, opts)
  end,
})

return M
