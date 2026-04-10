-- lib/hast/init.lua
-- HTML AST (hast) layer: mdast → hast transform + HTML serializer.
--
-- hast node types:
--   { type = "root",    children = {...} }
--   { type = "element", tag = "p", props = {}, children = {...} }
--   { type = "text",    value = "..." }
--   { type = "raw",     value = "<raw html>" }
--
-- API:
--   hast.from_mdast(mdast_node)  -> hast root
--   hast.to_html(hast_node)      -> string
--   hast.mdast_to_html(mdast_node) -> string
--   hast.md_to_html(source)      -> string
--
-- AST nodes are dynamic data with no static schema — we use `any` throughout
-- for node parameters because they are genuinely untyped trees. `any` is the
-- explicit type-system opt-out for dynamic data whose shape is guaranteed by
-- the caller (mdast.parse output).

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- ── Void elements ─────────────────────────────────────────────────────────────

local VOID = {
  area = true, base = true, br = true, col = true, embed = true,
  hr = true, img = true, input = true, link = true, meta = true,
  param = true, source = true, track = true, wbr = true,
}

-- ── HTML escaping ─────────────────────────────────────────────────────────────

--: (string) -> string
local function escape_text(s)
  s = s:gsub("&", "&amp;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  return s
end

--: (string) -> string
local function escape_attr(s)
  s = s:gsub("&", "&amp;")
  s = s:gsub('"', "&quot;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  return s
end

-- ── hast node constructors ────────────────────────────────────────────────────

-- Returns any: tree nodes are dynamic structures; the caller always knows the
-- shape and all downstream code treats them as any.

--: (string, any, any) -> any
local function el(tag, props, children)
  return { type = "element", tag = tag, props = props or {}, children = children or {} }
end

--: (string) -> any
local function text(value)
  return { type = "text", value = value }
end

--: (string) -> any
local function raw(value)
  return { type = "raw", value = value }
end

-- ── mdast → hast transform ────────────────────────────────────────────────────

local transform_node   -- forward declaration
local transform_children

--: (any) -> any
transform_children = function(mdast_node)
  if not mdast_node.children then return {} end
  local out = {}
  for _, child in ipairs(mdast_node.children) do
    local h = transform_node(child)
    if h then
      out[#out + 1] = h
    end
  end
  return out
end

-- Transform a table: handle thead/tbody for table rows.
--: (any) -> any
local function transform_table(node)
  local rows = node.children or {}
  local head_children = {}
  local body_children = {}
  for i, row in ipairs(rows) do
    local cells = {}
    for _, cell in ipairs(row.children or {}) do
      local tag = (i == 1) and "th" or "td"
      cells[#cells + 1] = el(tag, {}, transform_children(cell))
    end
    local tr = el("tr", {}, cells)
    if i == 1 then
      head_children[#head_children + 1] = tr
    else
      body_children[#body_children + 1] = tr
    end
  end
  local table_children = {}
  if #head_children > 0 then
    table_children[#table_children + 1] = el("thead", {}, head_children)
  end
  if #body_children > 0 then
    table_children[#table_children + 1] = el("tbody", {}, body_children)
  end
  return el("table", {}, table_children)
end

--: (any) -> any
transform_node = function(node)
  local t = node.type

  if t == "root" then
    return { type = "root", children = transform_children(node) }

  elseif t == "heading" then
    local tag = "h" .. tostring(node.depth or 1)
    return el(tag, {}, transform_children(node))

  elseif t == "paragraph" then
    return el("p", {}, transform_children(node))

  elseif t == "text" then
    return text(tostring(node.value or ""))

  elseif t == "softBreak" then
    return text(" ")

  elseif t == "hardBreak" then
    return el("br", {}, {})

  elseif t == "strong" then
    return el("strong", {}, transform_children(node))

  elseif t == "emphasis" then
    return el("em", {}, transform_children(node))

  elseif t == "inlineCode" then
    return el("code", {}, { text(tostring(node.value or "")) })

  elseif t == "code" then
    local code_props = {}
    if node.lang and node.lang ~= "" then
      code_props["class"] = "language-" .. tostring(node.lang)
    end
    local inner = el("code", code_props, { text(tostring(node.value or "")) })
    return el("pre", {}, { inner })

  elseif t == "blockquote" then
    return el("blockquote", {}, transform_children(node))

  elseif t == "list" then
    local tag = node.ordered and "ol" or "ul"
    local props = {}
    if node.ordered and node.start and node.start ~= 1 then
      props["start"] = tostring(node.start)
    end
    return el(tag, props, transform_children(node))

  elseif t == "listItem" then
    return el("li", {}, transform_children(node))

  elseif t == "thematicBreak" then
    return el("hr", {}, {})

  elseif t == "link" then
    local props = { href = tostring(node.url or "") }
    if node.title and node.title ~= "" then
      props["title"] = tostring(node.title)
    end
    return el("a", props, transform_children(node))

  elseif t == "image" then
    local props = { src = tostring(node.url or "") }
    -- alt text is stored in children as text nodes (mdast spec)
    local alt_parts = {}
    for _, child in ipairs(node.children or {}) do
      if child.value then alt_parts[#alt_parts + 1] = tostring(child.value) end
    end
    local alt_text = table.concat(alt_parts)
    if alt_text ~= "" then props["alt"] = alt_text end
    if node.title and node.title ~= "" then props["title"] = tostring(node.title) end
    return el("img", props, {})

  elseif t == "html" then
    return raw(tostring(node.value or ""))

  elseif t == "table" then
    return transform_table(node)

  elseif t == "tableRow" then
    -- Should only be reached via transform_table, but handle standalone.
    local cells = {}
    for _, cell in ipairs(node.children or {}) do
      cells[#cells + 1] = el("td", {}, transform_children(cell))
    end
    return el("tr", {}, cells)

  elseif t == "tableCell" then
    return el("td", {}, transform_children(node))

  elseif t == "definition" then
    -- Link definitions are metadata, not rendered.
    return nil

  else
    -- Unknown node type: render children if present, ignore otherwise.
    if node.children then
      local ch = transform_children(node)
      if #ch == 1 then return ch[1] end
      if #ch > 1 then return { type = "root", children = ch } end
    end
    return nil
  end
end

-- ── hast → HTML serializer ────────────────────────────────────────────────────

local serialize_node  -- forward declaration

--: (any) -> string
local function serialize_props(props)
  if not props then return "" end
  local parts = {}
  -- Sort for deterministic output.
  local keys = {}
  for k in pairs(props) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local ks = tostring(k)
    local v = props[k]
    if v == true then
      parts[#parts + 1] = " " .. ks
    elseif v and v ~= false then
      parts[#parts + 1] = " " .. ks .. '="' .. escape_attr(tostring(v)) .. '"'
    end
  end
  return table.concat(parts)
end

--: (any) -> string
local function serialize_children(children)
  if not children or #children == 0 then return "" end
  local parts = {}
  for _, child in ipairs(children) do
    parts[#parts + 1] = serialize_node(child)
  end
  return table.concat(parts)
end

--: (any) -> string
serialize_node = function(node)
  if not node then return "" end
  local t = node.type

  if t == "text" then
    return escape_text(tostring(node.value or ""))

  elseif t == "raw" then
    return tostring(node.value or "")

  elseif t == "root" then
    return serialize_children(node.children)

  elseif t == "element" then
    local tag = tostring(node.tag)
    local attrs = serialize_props(node.props)
    if VOID[tag] then
      return "<" .. tag .. attrs .. ">"
    else
      return "<" .. tag .. attrs .. ">" .. serialize_children(node.children) .. "</" .. tag .. ">"
    end

  else
    return ""
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

--: (any) -> any
M.from_mdast = function(mdast_node)
  return transform_node(mdast_node)
end

--: (any) -> string
M.to_html = function(hast_node)
  return serialize_node(hast_node)
end

--: (any) -> string
M.mdast_to_html = function(mdast_node)
  return M.to_html(M.from_mdast(mdast_node))
end

--: (string) -> string
M.md_to_html = function(source)
  local mdast = require("lib.mdast")
  local tree = mdast.parse(source)
  return M.mdast_to_html(tree)
end

return M
