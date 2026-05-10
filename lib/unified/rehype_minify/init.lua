-- lib/unified/rehype_minify/init.lua
-- rehype plugin: minify HTML by collapsing whitespace in text nodes.
-- Simplified port of the rehype-minify monorepo's core whitespace transforms.
--
-- Transforms applied:
--   1. Collapse sequences of whitespace characters (including newlines by
--      default) in text nodes to a single space.
--   2. Trim leading and trailing whitespace from text nodes that are direct
--      children of block elements.
--   3. Remove text nodes that are pure whitespace and are direct children of
--      block elements (after trimming, empty strings are dropped).
--   4. Content inside <pre> elements is never altered.
--
-- Options:
--   opts.newlines  boolean  Whether to collapse newlines too (default true).
--                           When false, only non-newline whitespace sequences
--                           are collapsed, and newlines are preserved.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

--:: HastNode = { type: string, tag?: string, value?: string, children?: { [integer]: HastNode }, ... }

-- ── Block element set ─────────────────────────────────────────────────────────

local BLOCK = {
  html = true, head = true, body = true,
  div = true, p = true,
  h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
  ul = true, ol = true, li = true,
  table = true, thead = true, tbody = true, tr = true, th = true, td = true,
  blockquote = true, pre = true,
  figure = true, figcaption = true,
  section = true, article = true, header = true, footer = true,
  main = true, nav = true, aside = true,
  details = true, summary = true,
}

-- ── Whitespace collapse ───────────────────────────────────────────────────────

--: (string, boolean) -> string
local function collapse_whitespace(s, collapse_newlines)
  if collapse_newlines then
    -- Collapse any whitespace sequence (including newlines) to a single space.
    local r, _ = s:gsub("%s+", " "); return r
  else
    -- Collapse non-newline whitespace sequences; preserve newlines.
    return s:gsub("[^\n\r%s]+", function(w) return w end)
      -- actually collapse runs of spaces/tabs (not newlines)
      :gsub("[ \t]+", " ")
  end
end

-- ── Tree walker ───────────────────────────────────────────────────────────────

local minify_node  -- forward declaration

--: (HastNode, boolean, boolean, boolean) -> nil
local function minify_children(node, parent_is_block, in_pre, collapse_newlines)
  local children = node.children
  if not children then return end

  local new_children = {}
  for _, child in ipairs(children) do
    if child.type == "text" then
      local v = child.value or ""
      if not in_pre then
        v = collapse_whitespace(v, collapse_newlines)
        if parent_is_block then
          v = v:match("^%s*(.-)%s*$")  -- trim
        end
      end
      if v ~= "" then
        new_children[#new_children + 1] = { type = "text", value = v }
      end
    else
      minify_node(child, in_pre, collapse_newlines)
      new_children[#new_children + 1] = child
    end
  end
  node.children = new_children
end

--: (HastNode, boolean, boolean) -> nil
minify_node = function(node, in_pre, collapse_newlines)
  if node.type ~= "element" then return end
  local tag = node.tag or ""
  local is_pre = tag == "pre"
  local is_block = not not BLOCK[tag]
  minify_children(node, is_block, in_pre or is_pre, collapse_newlines)
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (unknown, { newlines?: boolean, ... } | nil) -> nil
function M.plugin(processor, opts)
  opts = opts or {}
  local collapse_newlines = (opts --[[:! { newlines?: boolean, ... }]]).newlines ~= false
  local proc = processor --[[:! { use_transformer: (unknown, (unknown) -> unknown) -> nil }]]
  proc:use_transformer(function(tree_raw)
    local tree = tree_raw --[[:! HastNode]]
    if tree.children then
      for _, child in ipairs(tree.children --[[:! { [integer]: HastNode }]]) do
        minify_node(child, false, collapse_newlines)
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
