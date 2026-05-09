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

--:: HastNode = { type: string, tag?: string, children?: { [integer]: HastNode }, props?: { [string]: unknown }, value?: string, ... }

-- ── Node constructors ─────────────────────────────────────────────────────────

--: (string, { [string]: unknown }, { [integer]: HastNode }) -> HastNode
local function el(tag, props, children)
  return { type = "element", tag = tag, props = props or {}, children = children or {} }
end

--: (string) -> HastNode
local function text(value)
  return { type = "text", value = value }
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Normalize a string-or-table option to a flat list of strings.
--: (unknown) -> { [integer]: string }
local function to_list(v)
  if v == nil then return {} end
  if type(v) == "string" then return { v } end
  return v --[[:! { [integer]: string }]]
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (unknown, { title?: string, lang?: string, css?: string | { [integer]: string }, js?: string | { [integer]: string }, meta?: { [integer]: { [string]: string } } } | nil) -> nil
function M.plugin(processor, opts)
  local opts_t = (opts or {}) --[[:! { title?: string, lang?: string, css?: unknown, js?: unknown, meta?: { [integer]: { [string]: string } } }]]
  local title = opts_t.title or ""
  local lang  = opts_t.lang
  local css   = to_list(opts_t.css)
  local js    = to_list(opts_t.js)
  local meta  = (opts_t.meta or {}) --[[:! { [integer]: { [string]: string } }]]

  local processor_t = processor --[[:! { use_transformer: (unknown, (unknown) -> unknown) -> nil }]]
  processor_t:use_transformer(function(tree)
    local tree_node = tree --[[:! HastNode]]
    -- Build <head> children.
    local head_children = {} --: { [integer]: HastNode }

    -- <meta> elements first.
    for _, attrs in ipairs(meta) do
      local props = {}
      for k, v in pairs(attrs) do props[k] = v end
      head_children[#head_children + 1] = el("meta", props, {})
    end

    -- <title>.
    head_children[#head_children + 1] = el("title", {}, { text(title) })

    -- <link rel="stylesheet"> for each CSS href.
    for i = 1, #css do
      local href = css[i] --[[:! string]]
      head_children[#head_children + 1] = el("link", {
        rel  = "stylesheet",
        href = href,
      } --[[:! { [string]: unknown }]], {})
    end

    -- <script src> for each JS href.
    for i = 1, #js do
      local src = js[i] --[[:! string]]
      head_children[#head_children + 1] = el("script", {
        src = src,
      } --[[:! { [string]: unknown }]], {})
    end

    -- Build <html> props.
    local html_props = {}
    if lang and lang ~= "" then
      html_props.lang = lang
    end

    -- Wrap original children in <body>.
    local body = el("body", {}, (tree_node.children or {}) --[[:! { [integer]: HastNode }]])

    -- Assemble <html>.
    local html_el = el("html", html_props, {
      el("head", {}, head_children),
      body,
    })

    -- Prepend doctype as a raw node.
    local doctype = { type = "raw", value = "<!doctype html>" } --: HastNode

    tree_node.children = { doctype, html_el }
    return tree_node
  end)
end

setmetatable(M, {
  __call = function(_self, processor, opts)
    M.plugin(processor, opts)
  end,
})

return M
