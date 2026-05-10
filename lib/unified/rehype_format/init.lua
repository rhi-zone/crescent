-- lib/unified/rehype_format/init.lua
-- rehype plugin: pretty-print hast by inserting whitespace text nodes.
-- Port of rehype-format.
--
-- Block elements have newlines + indentation inserted between children and
-- around the element's content. Inline elements and text content are left
-- untouched. Content inside <pre> is never altered.
--
-- Options:
--   opts.indent  string  Indent string per nesting level (default "  ")
--
-- Plugin signature (unified):
--   function plugin(processor, opts)

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

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

--:: HastNode = { type: string, tag?: string, value?: string, children?: { [integer]: HastNode }, ... }

-- ── Helpers ───────────────────────────────────────────────────────────────────

--: (string) -> HastNode
local function text_node(value)
  return { type = "text", value = value }
end

--: (HastNode) -> boolean
local function is_whitespace_text(node)
  return (node.type == "text" and (node.value or ""):match("^%s*$") ~= nil) and true or false
end

-- ── Formatter ─────────────────────────────────────────────────────────────────

local format_node  -- forward declaration

--: (HastNode, integer, string, boolean) -> nil
local function format_children(node, depth, indent, in_pre)
  local children = node.children --[[:! { [integer]: HastNode }]]
  if not children or #children == 0 then return end

  local pad = string.rep(indent, depth)
  local pad_inner = string.rep(indent, depth + 1)
  local new_children = {}

  -- Leading newline + inner indent before first child.
  new_children[#new_children + 1] = text_node("\n" .. pad_inner)

  for i, child in ipairs(children) do
    -- Recurse first so child subtree is formatted.
    format_node(child, depth + 1, indent, in_pre)
    new_children[#new_children + 1] = child
    if i < #children then
      new_children[#new_children + 1] = text_node("\n" .. pad_inner)
    end
  end

  -- Trailing newline + outer indent before closing tag.
  new_children[#new_children + 1] = text_node("\n" .. pad)

  node.children = new_children
end

--: (HastNode, integer, string, boolean) -> nil
format_node = function(node, depth, indent, in_pre)
  if node.type ~= "element" then return
  else

  local tag = node.tag or ""
  local is_pre = tag == "pre"

  -- Never reformat inside <pre>.
  if in_pre then return end

  if BLOCK[tag] and node.children then
    local nc = node.children --[[:! { [integer]: HastNode }]]
    if #nc <= 0 then return end
    -- Only reformat if there's at least one non-whitespace child or a block child;
    -- skip elements whose only children are already-whitespace text nodes.
    local has_real = false
    for _, ch in ipairs(nc) do
      if not is_whitespace_text(ch) then
        has_real = true
        break
      end
    end
    if has_real then
      format_children(node, depth, indent, is_pre)
      return
    end
  end

  -- Non-block or empty block: recurse into children without inserting whitespace.
  if node.children then
    for _, child in ipairs(node.children) do
      format_node(child, depth + 1, indent, in_pre or is_pre)
    end
  end
  end -- else (node.type == "element")
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (unknown, { indent?: string, ... } | nil) -> nil
function M.plugin(processor, opts)
  opts = opts or {}
  local indent_str = (opts --[[:! { indent?: string, ... }]]).indent or "  "
  local proc = processor --[[:! { use_transformer: (unknown, (unknown) -> unknown) -> nil }]]
  proc:use_transformer(function(tree_raw)
    local tree = tree_raw --[[:! HastNode]]
    -- Walk the root's children; the root itself is not an element.
    if tree.children then
      for _, child in ipairs(tree.children --[[:! { [integer]: HastNode }]]) do
        format_node(child, 0, indent_str, false)
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
