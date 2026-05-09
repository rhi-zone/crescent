-- lib/unified/rehype_meta/init.lua
-- rehype plugin: add <meta> and <title> elements to the <head>.
-- Port of https://github.com/rehypejs/rehype-meta
--
-- Finds or creates <html>/<head> in the hast tree and appends metadata elements.
-- Works on a bare root (no <html> wrapper) by inserting at the start.
--
-- Options:
--   title       string        page title
--   description string        meta[name=description]
--   keywords    table         list of strings → joined with ", "
--   author      string        meta[name=author]
--   canonical   string        link[rel=canonical]
--   og          boolean       add Open Graph meta tags
--   twitter     boolean       add Twitter card meta tags
--   og_type     string        og:type (default "website")
--   og_image    string        og:image URL
--   color       string        meta[name=theme-color]
--
-- Plugin signature (unified):
--   function(processor, opts)

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: HastNode = { type: string, tag?: string, children?: { [integer]: HastNode }, props?: { [string]: unknown }, value?: string, ... }
--:: MetaOpts = { title?: string, description?: string, keywords?: { [integer]: string }, author?: string, canonical?: string, og?: boolean, twitter?: boolean, og_type?: string, og_image?: string, color?: string }

-- ── Node helpers ──────────────────────────────────────────────────────────────

--: (string, { [string]: unknown }, { [integer]: HastNode }) -> HastNode
local function el(tag, props, children)
  return { type = "element", tag = tag, props = props or {}, children = children or {} }
end

--: (string) -> HastNode
local function text(value)
  return { type = "text", value = value }
end

-- ── Tree search ───────────────────────────────────────────────────────────────

-- Find the first child element with the given tag name (in a children list).
--: (unknown, string) -> HastNode | nil
local function find_child(children, tag)
  if not children then return nil end
  local children_t = children --[[:! { [integer]: HastNode }]]
  for _, child in ipairs(children_t) do
    if child.type == "element" and child.tag == tag then
      return child
    end
  end
  return nil
end

-- Find or create a <head> node within the hast tree.
-- Handles:
--   root → html → head
--   root → head  (direct)
--   root only    (inserts head as first child)
--: (HastNode) -> HastNode
local function find_or_create_head(tree)
  local children = tree.children or {} --[[:! { [integer]: HastNode }]]

  -- Look for <html>.
  local html_el = find_child(children, "html")
  if html_el then
    local head = find_child(html_el.children, "head")
    if not head then
      head = el("head", {}, {})
      table.insert(html_el.children, 1, head)
    end
    return head
  end

  -- Look for bare <head>.
  local head = find_child(children, "head")
  if head then
    return head
  end

  -- No html or head — insert a bare <head> as first child.
  head = el("head", {}, {})
  table.insert(tree.children, 1, head)
  return head
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (unknown, MetaOpts | nil) -> nil
function M.plugin(processor, opts)
  local opts_t = (opts or {}) --[[:! MetaOpts]]

  local processor_t = processor --[[:! { use_transformer: (unknown, (unknown) -> unknown) -> nil }]]
  processor_t:use_transformer(function(tree)
    local tree_node = tree --[[:! HastNode]]
    local head = find_or_create_head(tree_node)
    local append = (head.children or {}) --[[:! { [integer]: HastNode }]]

    -- <title>
    if opts_t.title and opts_t.title ~= "" then
      append[#append + 1] = el("title", {}, { text(opts_t.title) })
    end

    -- <meta name="description">
    if opts_t.description and opts_t.description ~= "" then
      append[#append + 1] = el("meta", {
        name    = "description",
        content = opts_t.description,
      }, {})
    end

    -- <meta name="keywords">
    if opts_t.keywords and #opts_t.keywords > 0 then
      local joined = table.concat(opts_t.keywords, ", ")
      append[#append + 1] = el("meta", {
        name    = "keywords",
        content = joined,
      }, {})
    end

    -- <meta name="author">
    if opts_t.author and opts_t.author ~= "" then
      append[#append + 1] = el("meta", {
        name    = "author",
        content = opts_t.author,
      }, {})
    end

    -- <meta name="theme-color">
    if opts_t.color and opts_t.color ~= "" then
      append[#append + 1] = el("meta", {
        name    = "theme-color",
        content = opts_t.color,
      }, {})
    end

    -- <link rel="canonical">
    if opts_t.canonical and opts_t.canonical ~= "" then
      append[#append + 1] = el("link", {
        rel  = "canonical",
        href = opts_t.canonical,
      }, {})
    end

    -- Open Graph tags.
    if opts_t.og then
      if opts_t.title and opts_t.title ~= "" then
        append[#append + 1] = el("meta", { property = "og:title",       content = opts_t.title }, {})
      end
      if opts_t.description and opts_t.description ~= "" then
        append[#append + 1] = el("meta", { property = "og:description", content = opts_t.description }, {})
      end
      local og_type = opts_t.og_type or "website"
      append[#append + 1] = el("meta", { property = "og:type",        content = og_type }, {})
      if opts_t.og_image and opts_t.og_image ~= "" then
        append[#append + 1] = el("meta", { property = "og:image",      content = opts_t.og_image }, {})
      end
      if opts_t.canonical and opts_t.canonical ~= "" then
        append[#append + 1] = el("meta", { property = "og:url",        content = opts_t.canonical }, {})
      end
    end

    -- Twitter card tags.
    if opts_t.twitter then
      append[#append + 1] = el("meta", { name = "twitter:card",        content = "summary" }, {})
      if opts_t.title and opts_t.title ~= "" then
        append[#append + 1] = el("meta", { name = "twitter:title",     content = opts_t.title }, {})
      end
      if opts_t.description and opts_t.description ~= "" then
        append[#append + 1] = el("meta", { name = "twitter:description", content = opts_t.description }, {})
      end
      if opts_t.og_image and opts_t.og_image ~= "" then
        append[#append + 1] = el("meta", { name = "twitter:image",     content = opts_t.og_image }, {})
      end
    end

    return tree
  end)
end

setmetatable(M, {
  __call = function(_self, processor, opts)
    M.plugin(processor, opts)
  end,
})

return M
