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

-- ── Node helpers ──────────────────────────────────────────────────────────────

--: (string, any, any) -> any
local function el(tag, props, children)
  return { type = "element", tag = tag, props = props or {}, children = children or {} }
end

--: (string) -> any
local function text(value)
  return { type = "text", value = value }
end

-- ── Tree search ───────────────────────────────────────────────────────────────

-- Find the first child element with the given tag name (in a children list).
--: (any, string) -> any
local function find_child(children, tag)
  if not children then return nil end
  for _, child in ipairs(children) do
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
--: (any) -> any
local function find_or_create_head(tree)
  local children = tree.children or {}

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

--: (any, any) -> nil
function M.plugin(processor, opts)
  opts = opts or {}

  processor:use_transformer(function(tree)
    local head = find_or_create_head(tree)
    local append = head.children

    -- <title>
    if opts.title and opts.title ~= "" then
      append[#append + 1] = el("title", {}, { text(opts.title) })
    end

    -- <meta name="description">
    if opts.description and opts.description ~= "" then
      append[#append + 1] = el("meta", {
        name    = "description",
        content = opts.description,
      }, {})
    end

    -- <meta name="keywords">
    if opts.keywords and #opts.keywords > 0 then
      local joined = table.concat(opts.keywords, ", ")
      append[#append + 1] = el("meta", {
        name    = "keywords",
        content = joined,
      }, {})
    end

    -- <meta name="author">
    if opts.author and opts.author ~= "" then
      append[#append + 1] = el("meta", {
        name    = "author",
        content = opts.author,
      }, {})
    end

    -- <meta name="theme-color">
    if opts.color and opts.color ~= "" then
      append[#append + 1] = el("meta", {
        name    = "theme-color",
        content = opts.color,
      }, {})
    end

    -- <link rel="canonical">
    if opts.canonical and opts.canonical ~= "" then
      append[#append + 1] = el("link", {
        rel  = "canonical",
        href = opts.canonical,
      }, {})
    end

    -- Open Graph tags.
    if opts.og then
      if opts.title and opts.title ~= "" then
        append[#append + 1] = el("meta", { property = "og:title",       content = opts.title }, {})
      end
      if opts.description and opts.description ~= "" then
        append[#append + 1] = el("meta", { property = "og:description", content = opts.description }, {})
      end
      local og_type = opts.og_type or "website"
      append[#append + 1] = el("meta", { property = "og:type",        content = og_type }, {})
      if opts.og_image and opts.og_image ~= "" then
        append[#append + 1] = el("meta", { property = "og:image",      content = opts.og_image }, {})
      end
      if opts.canonical and opts.canonical ~= "" then
        append[#append + 1] = el("meta", { property = "og:url",        content = opts.canonical }, {})
      end
    end

    -- Twitter card tags.
    if opts.twitter then
      append[#append + 1] = el("meta", { name = "twitter:card",        content = "summary" }, {})
      if opts.title and opts.title ~= "" then
        append[#append + 1] = el("meta", { name = "twitter:title",     content = opts.title }, {})
      end
      if opts.description and opts.description ~= "" then
        append[#append + 1] = el("meta", { name = "twitter:description", content = opts.description }, {})
      end
      if opts.og_image and opts.og_image ~= "" then
        append[#append + 1] = el("meta", { name = "twitter:image",     content = opts.og_image }, {})
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
