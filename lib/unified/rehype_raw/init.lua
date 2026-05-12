-- lib/rehype_raw/init.lua
-- rehype plugin: parse raw HTML nodes into proper hast elements.
-- Port of rehype-raw.
--
-- When remark parses markdown with embedded HTML such as:
--   <div class="note">some **markdown** here</div>
-- it produces { type = "html", value = "<div class=\"note\">..." } nodes.
-- This plugin replaces those raw nodes with parsed hast element trees.
--
-- Also processes { type = "raw", value = "..." } nodes which the hast layer
-- uses for the same purpose (see hast/init.lua transform_node for "html").
--
-- Parser capabilities:
--   - Self-closing void elements: <br>, <hr>, <img>, etc.
--   - Open tags with attributes: <div class="foo" id="bar">
--   - Closing tags: </div>
--   - Comments: <!-- ... --> (preserved as raw nodes)
--   - Text nodes between tags
--   - Quoted and unquoted attribute values
--   - Boolean attributes (no value)
--
-- Nested element content (the innerHTML) is recursively parsed. This handles
-- the most common case where remark emits an entire element as a single raw
-- string.
--
-- Usage:
--   local rehype    = require("lib.unified.rehype")
--   local rehypeRaw = require("lib.unified.rehype_raw")
--   local p = rehype():use(rehypeRaw)

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

--:: HastNode = { type: string, tag?: string, children?: { [integer]: HastNode }, props?: { [string]: unknown }, value?: string, _splice?: { [integer]: HastNode }, ... }

-- ── Void elements ─────────────────────────────────────────────────────────────

local VOID = {
  area=true, base=true, br=true, col=true, embed=true,
  hr=true, img=true, input=true, link=true, meta=true,
  param=true, source=true, track=true, wbr=true,
}

-- ── Minimal HTML parser ───────────────────────────────────────────────────────

-- Tokenizer: returns a list of tokens from an HTML string.
-- Token types: { type="open", tag=, attrs={} }
--              { type="close", tag= }
--              { type="comment", value= }
--              { type="text", value= }
--:: HtmlToken = { type: string, value?: string, tag?: string, attrs?: { [string]: string }, void?: boolean }
--: (string) -> { [integer]: HtmlToken }
local function tokenize(html)
  local tokens = {} --[[: { [integer]: HtmlToken }]]
  local i = 1
  local len = #html

  while i <= len do
    if html:sub(i, i) == "<" then
      -- Comment
      if html:sub(i, i+3) == "<!--" then
        local close = html:find("-->", i+4, true)
        if close then
          local value = html:sub(i+4, close-1)
          tokens[#tokens + 1] = { type = "comment", value = value }
          i = close + 3
        else
          -- Unclosed comment — treat rest as comment.
          tokens[#tokens + 1] = { type = "comment", value = html:sub(i+4) }
          i = len + 1
        end

      -- Closing tag
      elseif html:sub(i, i+1) == "</" then
        local close = html:find(">", i+2, true)
        if close then
          local tag = html:sub(i+2, close-1):match("^%s*([%a][%w%-]*)%s*$") or
                      html:sub(i+2, close-1):match("^%s*([%a][%w%-]*)")
          if tag then
            tokens[#tokens + 1] = { type = "close", tag = tag:lower() }
          end
          i = close + 1
        else
          i = len + 1
        end

      -- Open tag
      elseif html:sub(i, i+1) == "<!" then
        -- DOCTYPE or similar — skip to >
        local close = html:find(">", i+2, true)
        i = close and close + 1 or len + 1

      else
        local close = html:find(">", i+1, true)
        if not close then
          -- Malformed — treat as text.
          tokens[#tokens + 1] = { type = "text", value = html:sub(i) }
          i = len + 1
        else
          -- Find the inner of <...>
          local close_i = close --[[:! integer]]
          local inner = html:sub(i+1, close_i-1)
          -- Self-closing? (e.g. <br/>)
          local self_close = inner:sub(-1) == "/"
          if self_close then inner = inner:sub(1, -2) end

          -- Parse tag name and attributes.
          local inner_s = inner  --: string
          local j = 1  --: integer
          local ilen = #inner_s
          -- Skip whitespace
          while j <= ilen and inner_s:sub(j,j):match("%s") do j = j + 1 end
          -- Read tag name
          local tag_start = j
          while j <= ilen and inner_s:sub(j,j):match("[%a%d%-%.%:]") do j = j + 1 end
          local tag = inner_s:sub(tag_start, j-1):lower()
          if tag == "" then
            -- Not a valid tag — treat as text.
            tokens[#tokens + 1] = { type = "text", value = html:sub(i, close_i) }
            i = close_i + 1
          else
            -- Parse attributes.
            local attrs = {}
            while j <= ilen do
              -- Skip whitespace
              while j <= ilen and inner_s:sub(j,j):match("%s") do j = j + 1 end
              if j > ilen then break end

              -- Read attribute name
              local name_start = j
              while j <= ilen and inner_s:sub(j,j):match("[^%s=/>]") do j = j + 1 end
              local attr_name = inner_s:sub(name_start, j-1)
              if attr_name == "" then j = j + 1; break end

              -- Skip whitespace
              while j <= ilen and inner_s:sub(j,j):match("%s") do j = j + 1 end

              if j <= ilen and inner_s:sub(j,j) == "=" then
                j = j + 1  -- skip =
                -- Skip whitespace
                while j <= ilen and inner_s:sub(j,j):match("%s") do j = j + 1 end
                -- Read value
                local val
                if j <= ilen and (inner_s:sub(j,j) == '"' or inner_s:sub(j,j) == "'") then
                  local quote = inner_s:sub(j,j)
                  j = j + 1
                  local val_start = j
                  while j <= ilen and inner_s:sub(j,j) ~= quote do j = j + 1 end
                  val = inner_s:sub(val_start, j-1)
                  j = j + 1  -- skip closing quote
                else
                  -- Unquoted value
                  local val_start = j
                  while j <= ilen and inner_s:sub(j,j):match("[^%s>]") do j = j + 1 end
                  val = inner_s:sub(val_start, j-1)
                end
                attrs[attr_name] = val
              else
                -- Boolean attribute
                attrs[attr_name] = true
              end
            end

            local is_void = VOID[tag] or self_close
            tokens[#tokens + 1] = {
              type = "open",
              tag = tag,
              attrs = attrs,
              void = is_void,
            }
            if is_void then
              tokens[#tokens + 1] = { type = "close", tag = tag }
            end
            i = close_i + 1
          end
        end
      end
    else
      -- Text: accumulate until next <
      local next_lt = html:find("<", i, true)
      local text_val
      if next_lt then
        text_val = html:sub(i, next_lt - 1)
        i = next_lt
      else
        text_val = html:sub(i)
        i = len + 1
      end
      if text_val ~= "" then
        tokens[#tokens + 1] = { type = "text", value = text_val }
      end
    end
  end

  return tokens
end

-- Build a hast tree from a token list.
-- Returns a list of top-level hast nodes.
--: ({ [integer]: HtmlToken }) -> { [integer]: HastNode }
local function tokens_to_hast(tokens)
  -- Stack of open elements. Each entry: { node = hast_element }.
  local stack = {} --[[: { [integer]: { node: HastNode } | nil }]]
  local root_children = {} --[[: { [integer]: HastNode }]]

  --: () -> { [integer]: HastNode }
  local function current_children()
    if #stack == 0 then
      return root_children
    end
    local top_ = stack[#stack]
    if not top_ then return root_children end
    local ch = top_.node.children
    if ch then return ch --[[:! { [integer]: HastNode }]] end
    return root_children
  end

  for _, tok in ipairs(tokens) do
    if tok.type == "text" then
      local children = current_children()
      children[#children + 1] = { type = "text", value = tok.value or "" } --[[:! HastNode]]

    elseif tok.type == "comment" then
      -- Preserve as raw HTML comment.
      local children = current_children()
      children[#children + 1] = { type = "raw", value = "<!--" .. (tok.value or "") .. "-->" } --[[:! HastNode]]

    elseif tok.type == "open" then
      local node_children = {} --[[: { [integer]: HastNode }]]
      local node = {
        type = "element",
        tag = tok.tag,
        props = tok.attrs --[[:! { [string]: unknown } | nil]],
        children = node_children,
      } --[[:! HastNode]]
      if tok.void then
        -- Void elements are immediately appended (no push/pop).
        local children = current_children()
        children[#children + 1] = node
      else
        -- Push onto stack.
        stack[#stack + 1] = { node = node }
      end

    elseif tok.type == "close" then
      -- Pop matching open tag from stack.
      local pop_idx = nil
      for k = #stack, 1, -1 do
        local se_ = stack[k]
        if se_ and se_.node.tag == tok.tag then
          pop_idx = k
          break
        end
      end
      if pop_idx then
        -- Close all tags from top down to pop_idx (handles implicit close).
        while #stack >= pop_idx do
          local entry_ = stack[#stack]
          stack[#stack] = nil
          if entry_ then
            -- Append the now-complete node to its parent (or root).
            local children = current_children()
            children[#children + 1] = entry_.node
          end
        end
      end
      -- Unmatched close tags are silently ignored.
    end
  end

  -- Close any unclosed elements (append to parent as-is).
  while #stack > 0 do
    local entry_ = stack[#stack]
    stack[#stack] = nil
    if entry_ then
      local children = current_children()
      children[#children + 1] = entry_.node
    end
  end

  return root_children
end

--: (string) -> { [integer]: HastNode }
local function parse_html(html)
  local trimmed = html:match("^%s*(.-)%s*$")
  if trimmed == "" then return {} end
  local tokens = tokenize(trimmed)
  return tokens_to_hast(tokens)
end

-- ── Tree transformer ──────────────────────────────────────────────────────────

-- Replace raw/html nodes with parsed hast subtrees.
-- Returns a (possibly different) node, or a list marker table when a raw node
-- expands to multiple nodes. The caller is responsible for splicing lists.
--: (HastNode) -> HastNode
local function transform_node(node)
  if node.type == "html" or node.type == "raw" then
    local parsed = parse_html(node.value or "")
    if #parsed == 0 then
      -- Empty — drop the node by returning a sentinel.
      return { type = "raw", _splice = {} }
    elseif #parsed == 1 then
      return parsed[1]
    else
      return { type = "raw", _splice = parsed }
    end
  end
  if node.children then
    local new_children = {} --: { [integer]: HastNode }
    for _, child in ipairs((node.children --[[:! { [integer]: HastNode }]])) do
      local result = transform_node(child)
      if result and result._splice then
        for _, spliced in ipairs((result._splice --[[:! { [integer]: HastNode }]])) do
          new_children[#new_children + 1] = spliced
        end
      else
        new_children[#new_children + 1] = result
      end
    end
    node.children = new_children
  end
  return node
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (unknown, unknown) -> nil
function M.plugin(processor, _opts)
  local processor_t = processor --[[:! { use_transformer: (unknown, (unknown) -> unknown) -> nil }]]
  processor_t:use_transformer(function(tree)
    local tree_node = tree --[[:! HastNode]]
    return transform_node(tree_node)
  end)
end

setmetatable(M, {
  __call = function(_self, processor, opts)
    M.plugin(processor, opts)
  end,
})

-- Expose internals for testing.
M._parse_html = parse_html
M._tokenize   = tokenize

return M
