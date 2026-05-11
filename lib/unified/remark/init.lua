-- lib/remark/init.lua
-- Markdown processing preset: wires lib/mdast (parser + stringifier) into a
-- lib/unified processor. Mirrors the API of the JavaScript `remark` package.
--
-- Usage:
--   local remark = require("lib.unified.remark")
--   local processor = remark()
--   local ast = processor:parse("# Hello\n\nWorld.")
--   local md  = processor:process("# Hello\n\nWorld.")

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local unified = require("lib.unified")
local mdast   = require("lib.unified.mdast")

local M = {}

-- ── mdast → Markdown stringifier ─────────────────────────────────────────────
-- Implemented independently (does not delegate to mdast.stringify) so that
-- remark owns its output contract and callers can vendor/modify it freely.

local str_rep    = string.rep
local tbl_concat = table.concat

--: (s: string) -> string[]
local function split_lines(s)
  local lines = {}
  local pos = 1
  local len = #s
  while pos <= len do
    local nl = s:find("\n", pos, true)
    if nl then
      lines[#lines + 1] = s:sub(pos, nl - 1)
      pos = nl + 1
    else
      lines[#lines + 1] = s:sub(pos)
      break
    end
  end
  return lines
end

local serialize  -- forward declaration

--: (children: { [integer]: { type: string, ... } } | nil, sep: string | nil) -> string
local function serialize_children(children, sep)
  if not children then return "" end
  if #children == 0 then return "" end
  local parts = {}
  for i = 1, #children do
    parts[i] = serialize(children[i])
  end
  return tbl_concat(parts, sep or "")
end

--: (node: { type: string, children?: { [integer]: { type: string, ... } }, value?: string, depth?: integer, lang?: string, url?: string, title?: string, label?: string, ordered?: boolean, start?: integer, ... }) -> string
serialize = function(node)
  local t = node.type
  if t == "root" then
    return serialize_children(node.children, "\n\n")

  elseif t == "paragraph" then
    return serialize_children(node.children)

  elseif t == "heading" then
    return str_rep("#", node.depth or 1) .. " " .. serialize_children(node.children)

  elseif t == "text" then
    return node.value or ""

  elseif t == "inlineCode" then
    return "`" .. (node.value or "") .. "`"

  elseif t == "code" then
    local lang = node.lang or ""
    return "```" .. lang .. "\n" .. (node.value or "") .. "\n```"

  elseif t == "emphasis" then
    return "*" .. serialize_children(node.children) .. "*"

  elseif t == "strong" then
    return "**" .. serialize_children(node.children) .. "**"

  elseif t == "link" then
    local text  = serialize_children(node.children)
    local url   = node.url or ""
    local title = node.title and (' "' .. node.title .. '"') or ""
    return "[" .. text .. "](" .. url .. title .. ")"

  elseif t == "image" then
    local alt   = node.alt or serialize_children(node.children or {})
    local url   = node.url or ""
    local title = node.title and (' "' .. node.title .. '"') or ""
    return "![" .. alt .. "](" .. url .. title .. ")"

  elseif t == "thematicBreak" then
    return "---"

  elseif t == "blockquote" then
    local inner = serialize_children(node.children, "\n\n")
    local lines = split_lines(inner)
    local out   = {}
    for i = 1, #lines do
      out[i] = "> " .. lines[i]
    end
    return tbl_concat(out, "\n")

  elseif t == "list" then
    local parts = {}
    local start = node.start or 1
    local ch = node.children or {}
    for idx = 1, #ch do
      local item    = ch[idx]
      local prefix  = node.ordered and (tostring(start + idx - 1) .. ". ") or "- "
      local content = serialize_children(item.children, "\n\n")
      local indent  = str_rep(" ", #prefix)
      local ilines  = split_lines(content)
      local s       = prefix .. (ilines[1] or "")
      for k = 2, #ilines do
        s = s .. "\n" .. indent .. ilines[k]
      end
      parts[idx] = s
    end
    return tbl_concat(parts, "\n")

  elseif t == "listItem" then
    return serialize_children(node.children, "\n\n")

  elseif t == "hardBreak" or t == "break" then
    return "  \n"

  elseif t == "softBreak" then
    return "\n"

  else
    -- Unknown node: fall through to empty string rather than error.
    return ""
  end
end

-- Public serializer (callers may use directly).
M.mdast_to_md = serialize

-- ── Plugins ───────────────────────────────────────────────────────────────────

-- remark-parse plugin: registers mdast.parse as the processor's parser.
local function remark_parse(processor)
  processor:parser(function(source)
    return mdast.parse(source)
  end)
end

-- remark-stringify plugin: registers the mdast → Markdown serializer.
local function remark_stringify(processor)
  processor:compiler(function(ast)
    return serialize(ast)
  end)
end

M.remark_parse     = remark_parse
M.remark_stringify = remark_stringify

-- ── Factory ───────────────────────────────────────────────────────────────────

-- remark() returns a frozen unified processor pre-configured with both plugins.
-- Calling :use() on the returned processor automatically clones it (unified
-- semantics for frozen processors), so adding transformers is safe.
local function remark()
  return unified.new()
    :use(remark_parse)
    :use(remark_stringify)
    :freeze()
end

M.new = remark

-- Make the module callable: remark() == require("lib.unified.remark")()
setmetatable(M, { __call = function(_, ...) return remark(...) end })

return M
