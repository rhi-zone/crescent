-- lib/unified/remark_math/init.lua
-- remark plugin that parses math syntax into mdast nodes:
--   $...$   → { type = "inlineMath", value = "..." }
--   $$...$$ → { type = "math",       value = "...", meta = nil }
--
-- Block math ($$...$$) is extracted BEFORE mdast parses the source to preserve
-- backslashes and other special characters that mdast's inline parser would
-- otherwise interpret as escape sequences.  Extracted blocks are replaced with
-- a placeholder paragraph that the transformer later converts to math nodes.
--
-- Inline math ($...$) is processed in a post-parse transformer that splits
-- text nodes containing $ delimiters.  Because mdast's inline parser strips
-- backslashes only in inline context, and $ is not a CommonMark escape
-- sequence, inline backslashes in math content survive intact.
--
-- Usage:
--   local remark      = require("lib.unified.remark")
--   local math_plugin = require("lib.unified.remark_math")
--   local processor   = remark():use(math_plugin)
--   local ast         = processor:parse("Inline $E=mc^2$.\n\n$$\n\\frac{a}{b}\n$$")
--   ast = processor:run(ast)
--
-- Options:
--   opts.single_dollar_tex_math_equation  (bool, default true)
--     When false, $...$ inline math is disabled; only $$...$$ block math works.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

local str_sub   = string.sub
local str_find  = string.find
local str_match = string.match

-- ── Unique placeholder prefix ─────────────────────────────────────────────────
-- Used to mark extracted block math positions in the source.  Unlikely to
-- appear in real Markdown content.
local PLACEHOLDER_PREFIX = "CRESCENT_MATH_BLOCK_"
--:: MdastNode = { type: string, value?: string, children?: { [integer]: MdastNode }, ... }

-- ── Source preprocessor ───────────────────────────────────────────────────────

-- Extract all top-level block math spans from source.  A block math span is a
-- paragraph-level construct:
--   $$
--   content
--   $$
-- or the single-line form $$content$$ on its own line.
--
-- Returns:
--   cleaned_source : source with block math replaced by placeholder paragraphs
--   blocks         : ordered array of { value = string } (content of each block)
local function extract_block_math(source)
  local blocks = {}
  local out = {}
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

    -- Check for opening $$ at start of line (optionally leading whitespace ≤ 3).
    local indent_end = str_find(clean, "[^ \t]") or (#clean + 1)
    local indent_count = indent_end - 1
    local rest = str_sub(clean, indent_end)

    if indent_count <= 3 and str_sub(rest, 1, 2) == "$$" then
      local after_open = str_sub(rest, 3)

      if after_open == "" then
        -- Multi-line block: scan for closing "$$" line.
        local block_start = line_end + 1
        local close_pos = nil
        local scan = block_start
        while scan <= len do
          local snl = str_find(source, "\n", scan, true)
          local send = snl or (len + 1)
          local sline = str_sub(source, scan, send - 1)
          if sline:sub(-1) == "\r" then sline = sline:sub(1, -2) end
          if sline == "$$" then
            close_pos = scan
            -- Content is everything between line_end+1 and scan-1, minus trailing newline.
            local content = str_sub(source, block_start, scan - 1)
            if content:sub(-2) == "\r\n" then
              content = content:sub(1, -3)
            elseif content:sub(-1) == "\n" then
              content = content:sub(1, -2)
            end
            local idx = #blocks + 1
            blocks[idx] = { value = content }
            -- Emit a placeholder paragraph (two blank lines wrap it for block separation).
            out[#out + 1] = "\n" .. PLACEHOLDER_PREFIX .. tostring(idx) .. "\n"
            pos = (snl and snl + 1) or (len + 1)
            break
          end
          scan = send + 1
        end
        if not close_pos then
          -- No closing $$: treat as normal line.
          out[#out + 1] = line .. (nl and "\n" or "")
          pos = line_end + 1
        end
      else
        -- Possible single-line form: $$content$$
        if str_sub(after_open, -2) == "$$" and #after_open > 2 then
          local content = str_sub(after_open, 1, -3)
          if not str_find(content, "$$", 1, true) then
            local idx = #blocks + 1
            blocks[idx] = { value = content }
            out[#out + 1] = "\n" .. PLACEHOLDER_PREFIX .. tostring(idx) .. "\n"
            pos = line_end + 1
          else
            out[#out + 1] = line .. (nl and "\n" or "")
            pos = line_end + 1
          end
        else
          -- $$ followed by inline content — not a block math fence.
          out[#out + 1] = line .. (nl and "\n" or "")
          pos = line_end + 1
        end
      end
    else
      out[#out + 1] = line .. (nl and "\n" or "")
      pos = line_end + 1
    end
  end

  return table.concat(out), blocks
end

-- ── Inline math splitting ─────────────────────────────────────────────────────

-- Scan a text value and split it into text / inlineMath nodes.
-- $$ is left as literal text (block math delimiter).
-- Returns an array of nodes.
local function split_inline_math(value, allow_single)
  local result = {} --: { [integer]: { type: string, value: string } }
  local pos = 1
  local len = #value

  while pos <= len do
    local dollar = str_find(value, "$", pos, true)
    if not dollar then
      if pos <= len then
        result[#result + 1] = { type = "text", value = str_sub(value, pos) }
      end
      break
    end

    local is_double = str_sub(value, dollar, dollar + 1) == "$$"

    if is_double then
      -- $$ at inline level: emit as literal text.
      result[#result + 1] = { type = "text", value = str_sub(value, pos, dollar + 1) }
      pos = dollar + 2
    elseif allow_single then
      -- Find a closing $ that is not part of $$.
      local close = str_find(value, "$", dollar + 1, true)
      while close and str_sub(value, close, close + 1) == "$$" do
        close = str_find(value, "$", close + 2, true)
      end

      if not close then
        result[#result + 1] = { type = "text", value = str_sub(value, pos) }
        break
      end

      if dollar > pos then
        result[#result + 1] = { type = "text", value = str_sub(value, pos, dollar - 1) }
      end
      result[#result + 1] = { type = "inlineMath", value = str_sub(value, dollar + 1, close - 1) }
      pos = close + 1
    else
      -- Single dollar disabled.
      result[#result + 1] = { type = "text", value = str_sub(value, pos, dollar) }
      pos = dollar + 1
    end
  end

  return result
end

-- Expand inline nodes in a children list, replacing text nodes containing
-- $...$ with inlineMath nodes.
local function expand_inline(children, allow_single)
  local result = {}
  for i = 1, #children do
    local node = children[i]
    if node.type == "text" then
      local expanded = split_inline_math(node.value or "", allow_single)
      for j = 1, #expanded do
        result[#result + 1] = expanded[j]
      end
    else
      if node.children then
        node.children = expand_inline(node.children, allow_single)
      end
      result[#result + 1] = node
    end
  end
  return result
end

-- ── Block placeholder detection ───────────────────────────────────────────────

-- Check if a paragraph is a math placeholder.  Returns the block index or nil.
--: (MdastNode) -> number | nil
local function para_placeholder_index(para)
  local pchildren = para.children --[[:! { [integer]: MdastNode } | nil]]
  if not pchildren then return nil end
  local pchildren2 = pchildren --[[:! { [integer]: MdastNode }]]
  if #pchildren2 ~= 1 then return nil end
  local child = pchildren2[1]
  if child.type ~= "text" then return nil
  else
    local v = child.value or ""
    local idx = str_match(v, "^" .. PLACEHOLDER_PREFIX .. "(%d+)$")
    return idx and tonumber(idx) or nil
  end -- else (type == "text")
end

-- ── Tree transformer ──────────────────────────────────────────────────────────

local function transform(node, allow_single, blocks)
  if node.type == "root" or node.type == "blockquote" then
    local children = node.children --[[:! { [integer]: MdastNode }]]
    local new_children = {}
    for i = 1, #children do
      local child = children[i]
      if child.type == "paragraph" then
        local idx = para_placeholder_index(child)
        if idx and blocks[idx] then
          new_children[#new_children + 1] = {
            type  = "math",
            value = blocks[idx].value,
            meta  = nil,
          }
        else
          if child.children then
            child.children = expand_inline(child.children, allow_single)
          end
          new_children[#new_children + 1] = child
        end
      else
        transform(child, allow_single, blocks)
        if child.type == "heading" and child.children then
          child.children = expand_inline(child.children, allow_single)
        end
        new_children[#new_children + 1] = child
      end
    end
    node.children = new_children
  end
  return node
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

local function remark_math(processor, opts)
  local allow_single = true
  if opts and opts.single_dollar_tex_math_equation == false then
    allow_single = false
  end

  local proc_ = processor --[[: any]]
  local inner_parser = proc_._parser

  proc_:parser(function(source)
    local cleaned, blocks = extract_block_math(source)

    local ast, err
    if inner_parser then
      ast, err = inner_parser(cleaned)
    else
      return nil, "remark_math: no base parser registered"
    end
    if not ast then return nil, err end

    -- Attach blocks to ast for the transformer to pick up.
    ast._math_blocks = blocks
    return ast
  end)

  proc_:use_transformer(function(ast)
    local blocks = ast._math_blocks or {}
    ast._math_blocks = nil
    transform(ast, allow_single, blocks)
    return ast
  end)
end

setmetatable(M, { __call = function(_, proc, opts) return remark_math(proc, opts) end })

M.plugin = remark_math

return M
