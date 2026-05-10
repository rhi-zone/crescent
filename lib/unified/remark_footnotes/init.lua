-- lib/unified/remark_footnotes/init.lua
-- remark plugin that parses footnote syntax:
--
--   [^label]         → { type = "footnoteReference", identifier = "label", label = "label" }
--   [^label]: text   → { type = "footnoteDefinition", identifier = "label", label = "label",
--                         children = { { type = "paragraph", children = {...} } } }
--
-- Footnote references appear inline inside text nodes.
-- Footnote definitions look like link-reference definitions (`[label]: url`),
-- which mdast consumes and loses the content.  To preserve the content, this
-- plugin wraps the parser and extracts footnote definition lines BEFORE mdast
-- sees the source, then injects the definitions back as footnoteDefinition
-- nodes after parsing.
--
-- Usage:
--   local remark    = require("lib.unified.remark")
--   local footnotes = require("lib.unified.remark_footnotes")
--   local processor = remark():use(footnotes)
--   local ast       = processor:parse("See[^1].\n\n[^1]: The footnote text.")
--   ast = processor:run(ast)

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

local str_sub   = string.sub
local str_find  = string.find
local str_match = string.match

-- ── Source preprocessor ───────────────────────────────────────────────────────

-- Scan source for footnote definition lines of the form:
--   [^label]: content
-- These must appear at the start of a line (no leading indent beyond 3 spaces).
-- Returns:
--   cleaned_source : source with footnote definition lines replaced by blank lines
--                    (so mdast block structure is preserved)
--   defs           : array of { label = string, content = string }
local function extract_fn_defs(source)
  local defs = {} --: { label: string, content: string }[]
  local lines = {} --: { [integer]: string }
  local pos = 1
  local len = #source

  while pos <= len do
    local nl = str_find(source, "\n", pos, true)
    local line_end = nl or (len + 1)
    local line = str_sub(source, pos, line_end - 1)
    -- Strip trailing \r.
    local clean = line
    if #clean > 0 and str_sub(clean, -1) == "\r" then
      clean = str_sub(clean, 1, -2)
    end

    -- Match [^label]: content — up to 3 leading spaces allowed.
    local leading = str_match(clean, "^( *)")
    if leading and #leading <= 3 then
      local rest = str_sub(clean, #leading + 1)
      local label, content = str_match(rest, "^%[%^([^%]%[%s]+)%]:%s*(.*)")
      if label then
        defs[#defs + 1] = { label = label, content = content }
        -- Replace the definition line with a blank line to keep line numbers.
        lines[#lines + 1] = ""
        pos = line_end + 1
        goto next_line
      end
    end

    lines[#lines + 1] = line
    pos = line_end + 1
    ::next_line::
  end

  local cleaned = table.concat(lines, "\n")
  return cleaned, defs
end

-- ── Inline reference scanning ─────────────────────────────────────────────────

-- Scan a text value for [^label] patterns.
-- Returns an array of nodes (text / footnoteReference interleaved).
local function scan_footnote_refs(value)
  local result = {} --: { type: string, value?: string, identifier?: string, label?: string }[]
  local pos = 1
  local len = #value

  while pos <= len do
    -- Look for "[^".
    local open_or_nil = str_find(value, "[^", pos, true)
    if not open_or_nil then
      if pos <= len then
        result[#result + 1] = { type = "text", value = str_sub(value, pos) }
      end
      break
    end
    local open = open_or_nil --[[:! integer]]

    local close_or_nil = str_find(value, "]", open + 2, true)
    if not close_or_nil then
      result[#result + 1] = { type = "text", value = str_sub(value, pos) }
      break
    end
    local close = close_or_nil --[[:! integer]]

    local label = str_sub(value, open + 2, close - 1)

    -- Label must be non-empty and must not contain whitespace or brackets.
    if label == "" or str_find(label, "[ %[\n%]]") then
      result[#result + 1] = { type = "text", value = str_sub(value, pos, open) }
      pos = open + 1
    else
      if open > pos then
        result[#result + 1] = { type = "text", value = str_sub(value, pos, open - 1) }
      end
      result[#result + 1] = {
        type       = "footnoteReference",
        identifier = label,
        label      = label,
      }
      pos = close + 1
    end
  end

  return result
end

-- Expand inline nodes in a children list, finding footnote references.
local function expand_inline(children)
  local result = {}
  for i = 1, #children do
    local node = children[i]
    if node.type == "text" then
      local expanded = scan_footnote_refs(node.value or "")
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

-- ── Tree transformer ──────────────────────────────────────────────────────────

--: (node: { type: string, children: { [integer]: unknown, ... }, ... }) -> { type: string, children: { [integer]: unknown, ... }, ... }
local function transform(node)
  if node.type == "root" or node.type == "blockquote" then
    local children = node.children
    local new_children = {}
    for i = 1, #children do
      local child = children[i]
      if child.type == "paragraph" then
        if child.children then
          child.children = expand_inline(child.children)
        end
        new_children[#new_children + 1] = child
      else
        transform(child)
        if child.type == "heading" and child.children then
          child.children = expand_inline(child.children)
        end
        new_children[#new_children + 1] = child
      end
    end
    node.children = new_children
  end
  return node
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (processor: { _parser: ((string) -> ({ children: { [integer]: unknown, ... }, ... } | nil, string | nil)) | nil, parser: (self: unknown, fn: unknown) -> unknown, use_transformer: (self: unknown, fn: unknown) -> unknown, ... }, _opts: unknown) -> nil
local function remark_footnotes(processor, _opts)
  -- Capture the existing parser.
  local inner_parser = processor._parser

  -- Wrap the parser to preprocess footnote definitions.
  processor:parser(function(source)
    local cleaned, defs = extract_fn_defs(source)

    local ast, err
    if inner_parser then
      ast, err = inner_parser(cleaned)
    else
      return nil, "remark_footnotes: no base parser registered"
    end
    if not ast then return nil, err end

    -- Remove blank children inserted for definition lines
    -- (mdast may produce empty paragraphs from blank lines at the end).
    -- Then append footnoteDefinition nodes.
    for _, def in ipairs(defs) do
      local content_text = def.content
      local def_node = {
        type       = "footnoteDefinition",
        identifier = def.label,
        label      = def.label,
        children   = {
          {
            type     = "paragraph",
            children = content_text ~= "" and { { type = "text", value = content_text } } or {},
          },
        },
      }
      ast.children[#ast.children + 1] = def_node
    end

    return ast
  end)

  -- Register transformer to expand inline footnote references.
  processor:use_transformer(function(ast)
    transform(ast)
    return ast
  end)
end

setmetatable(M, { __call = function(_, ...) return remark_footnotes(...) end })

M.plugin = remark_footnotes

return M
