-- lib/unified/remark_directive/init.lua
-- remark plugin that parses generic directives syntax:
--
--   Text directive  (inline):  :name[content]{key=val}
--   Leaf directive  (block):   ::name[content]{key=val}
--   Container directive:       :::name[content]{key=val}
--                              ...children...
--                              :::
--
-- Node types produced:
--   { type = "textDirective",      name = "name", attributes = {}, children = {...} }
--   { type = "leafDirective",      name = "name", attributes = {}, children = {} }
--   { type = "containerDirective", name = "name", attributes = {}, children = {...} }
--
-- mdast collapses lines within a paragraph into softBreak nodes when there are
-- no blank lines between them.  This plugin handles both cases:
--   • Tight form (no blank lines): :::name\nContent.\n::: → single paragraph
--     with text/softBreak children
--   • Loose form (blank lines): :::name\n\nContent.\n\n::: → separate
--     paragraph children at root level
--
-- Usage:
--   local remark    = require("lib.unified.remark")
--   local directive = require("lib.unified.remark_directive")
--   local processor = remark():use(directive)
--   local ast       = processor:parse(":tip[Read me]{color=red}")
--   ast = processor:run(ast)

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

local str_sub   = string.sub
local str_find  = string.find
local str_match = string.match

-- ── Attribute parser ──────────────────────────────────────────────────────────

-- Parse an attribute string: key=val key2="val2" bool_key ...
-- Returns a table of key → value (string or true for booleans).
--: (s: string | nil) -> unknown
local function parse_attrs(s)
  local attrs = {} --[[: unknown]]
  if not s or s == "" then return attrs end
  local pos = 1  --: integer
  local len = #s
  while pos <= len do
    local _, nws = str_find(s, "^%s*", pos)
    pos = (nws or (pos - 1)) + 1
    if pos > len then break end

    local key_s, key_e = str_find(s, "^[%w%-_]+", pos)
    if not key_s then break end
    local key = str_sub(s, key_s, key_e --[[:! integer]])
    pos = (key_e --[[:! integer]]) + 1

    if pos <= len and str_sub(s, pos, pos) == "=" then
      pos = pos + 1
      local val
      local qchar = str_sub(s, pos, pos)
      if qchar == '"' or qchar == "'" then
        pos = pos + 1
        local close = str_find(s, qchar, pos, true)
        if close then
          val = str_sub(s, pos, (close --[[:! integer]]) - 1)
          pos = (close --[[:! integer]]) + 1
        else
          val = str_sub(s, pos)
          pos = len + 1
        end
      else
        local v_s, v_e = str_find(s, "^[^%s]+", pos)
        if v_s then
          val = str_sub(s, v_s, v_e)
          pos = (v_e --[[:! integer]]) + 1
        else
          val = ""
        end
      end
      attrs[key] = val
    else
      attrs[key] = true
    end
  end
  return attrs
end

-- ── Directive head parser ─────────────────────────────────────────────────────

-- Parse `name[label]{attrs}` from `text` (colons already stripped).
-- Returns (name, label, attrs, consumed_bytes) or nil.
local function parse_directive_head(text)
  local pos = 1
  local len = #text

  local name_s, name_e = str_find(text, "^[%w%-_]+", pos)
  if not name_s then return nil end
  local name = str_sub(text, name_s, (name_e --[[:! integer]]))
  pos = (name_e --[[:! integer]]) + 1

  local label = ""
  if pos <= len and str_sub(text, pos, pos) == "[" then
    local close = str_find(text, "]", pos + 1, true)
    if close then
      label = str_sub(text, pos + 1, (close --[[:! integer]]) - 1)
      pos = (close --[[:! integer]]) + 1
    end
  end

  local attrs = {} --[[: unknown]]
  if pos <= len and str_sub(text, pos, pos) == "{" then
    local close = str_find(text, "}", pos + 1, true)
    if close then
      attrs = parse_attrs(str_sub(text, pos + 1, (close --[[:! integer]]) - 1))
      pos = (close --[[:! integer]]) + 1
    end
  end

  return name, label, attrs, pos - 1
end

-- ── Inline-text helpers ───────────────────────────────────────────────────────

-- Join inline children (text + softBreak) into a raw string.
local function inline_text(nodes)
  if not nodes then return "" end
  local parts = {}
  for i = 1, #nodes do
    local n = nodes[i]
    if n.type == "text" then
      parts[#parts + 1] = n.value or ""
    elseif n.type == "softBreak" then
      parts[#parts + 1] = "\n"
    elseif n.children then
      parts[#parts + 1] = inline_text(n.children)
    end
  end
  return table.concat(parts)
end

-- ── Text directive scanning ───────────────────────────────────────────────────

-- Scan a text value for :name[...]{...} patterns (single colon only).
-- Returns an array of replacement nodes.
local function scan_text_directives(value)
  local result = {} --[[: { [integer]: unknown }]]
  local pos = 1  --: integer
  local len = #value

  while pos <= len do
    local colon_raw = str_find(value, ":", pos, true)
    if not colon_raw then
      if pos <= len then
        result[#result + 1] = { type = "text", value = str_sub(value, pos) }
      end
      break
    end
    local colon = colon_raw  --: integer

    -- Skip :: (leaf/container markers used at block level).
    if str_sub(value, colon + 1, colon + 1) == ":" then
      result[#result + 1] = { type = "text", value = str_sub(value, pos, colon + 1) }
      pos = colon + 2
    else
      -- Try to parse a text directive at this colon.
      local rest = str_sub(value, colon + 1)
      local name, label, attrs, consumed = parse_directive_head(rest)
      if name then
        if colon > pos then
          result[#result + 1] = { type = "text", value = str_sub(value, pos, colon - 1) }
        end
        local children = label ~= "" and { { type = "text", value = label } } or {}
        result[#result + 1] = {
          type       = "textDirective",
          name       = name,
          attributes = attrs,
          children   = children,
        }
        pos = colon + 1 + (consumed or 0)
      else
        result[#result + 1] = { type = "text", value = str_sub(value, pos, colon) }
        pos = colon + 1
      end
    end
  end

  return result
end

-- Expand inline children, scanning text nodes for text directives.
local function expand_inline(children)
  local result = {} --[[: { [integer]: unknown }]]
  for i = 1, #children do
    local node = children[i]
    if node.type == "text" then
      local expanded = scan_text_directives(node.value or "")
      for j = 1, #expanded do
        result[#result + 1] = expanded[j]
      end
    else
      if node.children then
        node.children = expand_inline(node.children)
      end
      result[#result + 1] = node
    end
  end
  return result
end

-- ── Block directive detection ─────────────────────────────────────────────────

-- Check if a string starts with exactly N colons (not more).
local function count_leading_colons(s)
  local n = 0
  local len = #s
  while n < len and str_sub(s, n + 1, n + 1) == ":" do
    n = n + 1
  end
  return n
end

-- Get the first text value from a paragraph's children.
local function para_first_text(para)
  if not para.children or #para.children == 0 then return nil end
  local first = para.children[1] --[[: unknown]]
  if type(first) == "table" then
    local ft = first.type --[[: unknown]]
    if ft == "text" then return (first.value --[[: unknown]]) or "" end
  end
  return nil
end

-- Try to detect a tight (no-blank-line) container directive encoded in one
-- paragraph.  A tight container looks like:
--   :::name[...]{...}\n<content lines>\n:::
-- mdast represents this as a paragraph with alternating text/softBreak nodes.
-- Returns (name, label, attrs, content_children) or nil.
local function try_tight_container(para)
  local children = para.children
  if not children or #children < 3 then return nil end

  -- First child must be text starting with exactly ":::" + name.
  local first_val = children[1].type == "text" and (children[1].value or "") or nil
  if not first_val then return nil end
  local colons = count_leading_colons(first_val)
  if colons ~= 3 then return nil end

  -- Last text child must be exactly ":::".
  local last = children[#children]
  if last.type ~= "text" or last.value ~= ":::" then return nil end
  -- Second-to-last must be softBreak.
  if #children >= 2 and children[#children - 1].type ~= "softBreak" then return nil end

  local head = str_sub(first_val, 4)
  local name, label, attrs = parse_directive_head(head)
  if not name then return nil end

  -- Content is everything between the opening line's softBreak and the closing ":::".
  -- That is children[2] (softBreak), children[3..#-2] are the inner content inlines,
  -- children[#-1] (softBreak), children[#] ":::".
  -- Reconstruct the inner inline nodes as a paragraph.
  local inner_inlines = {}
  for i = 3, #children - 2 do
    inner_inlines[#inner_inlines + 1] = children[i]
  end

  local content_children = {}
  if #inner_inlines > 0 then
    content_children[#content_children + 1] = { type = "paragraph", children = inner_inlines }
  end

  return name, label, attrs, content_children
end

-- Try to detect a tight leaf directive in a paragraph (single text child "::name...").
local function try_tight_leaf(para)
  local children = para.children
  if not children or #children == 0 then return nil end
  -- All children must be text or softBreak; first text starts with "::".
  local first_val = children[1].type == "text" and (children[1].value or "") or nil
  if not first_val then return nil end
  local colons = count_leading_colons(first_val)
  if colons ~= 2 then return nil end

  -- Take only the first line (up to first softBreak or end).
  local first_line = str_match(first_val, "^([^\n]*)") or first_val
  local head = str_sub(first_line, 3)
  local name, label, attrs = parse_directive_head(head)
  if not name then return nil end

  local dir_children = label ~= "" and { { type = "text", value = label } } or {}
  return name, label, attrs, dir_children
end

-- ── Tree transformer ──────────────────────────────────────────────────────────

-- Forward declaration.
local transform_children

-- Transform a list of block children, detecting directives.
transform_children = function(children)
  local result = {} --[[: { [integer]: unknown }]]
  local i = 1
  local n = #children

  while i <= n do
    local child = children[i]

    if child.type == "paragraph" then
      local first_val = para_first_text(child)

      -- 1. Try tight container (:::name\ncontent\n::: in one paragraph).
      if first_val and count_leading_colons(first_val) >= 3 then
        local name, label, attrs, content = try_tight_container(child)
        if name then
          local dir_children = {}
          if label ~= "" then
            dir_children[#dir_children + 1] = { type = "text", value = label }
          end
          for _, c in ipairs(content) do
            dir_children[#dir_children + 1] = c
          end
          result[#result + 1] = {
            type       = "containerDirective",
            name       = name,
            attributes = attrs,
            children   = dir_children,
          }
          i = i + 1
          goto continue
        end
      end

      -- 2. Try loose container (:::name paragraph followed by ::: paragraph).
      if first_val and count_leading_colons(first_val) == 3 then
        local head = str_sub(first_val, 4)
        local name, label, attrs = parse_directive_head(head)
        if name then
          -- Collect paragraphs until a paragraph whose sole text is ":::".
          local inner = {}
          i = i + 1
          while i <= n do
            local c = children[i]
            if c.type == "paragraph" then
              local ct = para_first_text(c)
              if ct and ct == ":::" and #c.children == 1 then
                break  -- closing fence
              end
            end
            inner[#inner + 1] = c
            i = i + 1
          end
          local processed_inner = transform_children(inner)
          local dir_children = {}
          if label ~= "" then
            dir_children[#dir_children + 1] = { type = "text", value = label }
          end
          for _, c in ipairs(processed_inner) do
            dir_children[#dir_children + 1] = c
          end
          result[#result + 1] = {
            type       = "containerDirective",
            name       = name,
            attributes = attrs,
            children   = dir_children,
          }
          i = i + 1
          goto continue
        end
      end

      -- 3. Try leaf directive (::name).
      if first_val and count_leading_colons(first_val) == 2 then
        local name, label, attrs, dir_children = try_tight_leaf(child)
        if name then
          result[#result + 1] = {
            type       = "leafDirective",
            name       = name,
            attributes = attrs,
            children   = dir_children,
          }
          i = i + 1
          goto continue
        end
      end

      -- 4. Regular paragraph: expand inline text directives.
      if child.children then
        child.children = expand_inline(child.children)
      end
      result[#result + 1] = child

    else
      -- Recurse into other containers.
      if child.children then
        child.children = transform_children(child.children)
      end
      result[#result + 1] = child
    end

    i = i + 1
    ::continue::
  end

  return result
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

local function remark_directive(processor, _opts)
  processor:use_transformer(function(ast)
    if ast.children then
      ast.children = transform_children(ast.children)
    end
    return ast
  end)
end

setmetatable(M, { __call = function(_, ...) return remark_directive(...) end })

M.plugin = remark_directive

return M
