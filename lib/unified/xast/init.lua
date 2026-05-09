-- lib/unified/xast/init.lua
-- xast: XML Abstract Syntax Tree spec for the unified ecosystem.
-- Port of https://github.com/syntax-tree/xast
--
-- Node types:
--   { type = "root",        children = {...} }
--   { type = "element",     name = "tagName", attributes = {key="val"}, children = {...} }
--   { type = "text",        value = "..." }
--   { type = "comment",     value = "..." }
--   { type = "doctype",     name = "html", public = nil, system = nil }
--   { type = "instruction", name = "xml", value = "version=\"1.0\"" }
--   { type = "cdata",       value = "..." }
--
-- API:
--   xast.root(children)                        -> node
--   xast.element(name, attrs, children)        -> node
--   xast.text(value)                           -> node
--   xast.comment(value)                        -> node
--   xast.doctype(name, public, system)         -> node
--   xast.instruction(name, value)              -> node
--   xast.cdata(value)                          -> node
--   xast.to_xml(node)                          -> string

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: XastNode = { type: string, ... }
--:: XastOpts = { quote: string | nil, close_self_closing: boolean | nil, xml_declaration: boolean | nil, ... }

-- ── Escaping ──────────────────────────────────────────────────────────────────

--: (string) -> string
local function escape_text(s)
  s = s:gsub("&", "&amp;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  return s
end

--: (string, string) -> string
local function escape_attr(s, quote)
  s = s:gsub("&", "&amp;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  if quote == "'" then
    s = s:gsub("'", "&apos;")
  else
    s = s:gsub('"', "&quot;")
  end
  return s
end

-- ── Node constructors ─────────────────────────────────────────────────────────

--: (unknown) -> XastNode
function M.root(children)
  return { type = "root", children = children or {} }
end

--: (string, unknown, unknown) -> XastNode
function M.element(name, attrs, children)
  return { type = "element", name = name, attributes = attrs or {}, children = children or {} }
end

--: (string) -> XastNode
function M.text(value)
  return { type = "text", value = value }
end

--: (string) -> XastNode
function M.comment(value)
  return { type = "comment", value = value }
end

--: (string, unknown, unknown) -> XastNode
function M.doctype(name, public, system)
  return { type = "doctype", name = name, public = public, system = system }
end

--: (string, string) -> XastNode
function M.instruction(name, value)
  return { type = "instruction", name = name, value = value }
end

--: (string) -> XastNode
function M.cdata(value)
  return { type = "cdata", value = value }
end

-- ── Serializer ────────────────────────────────────────────────────────────────

local serialize_node  -- forward declaration

--: (unknown, string) -> string
local function serialize_attrs(attributes, quote)
  if not attributes then return "" end
  local attrs_ = attributes --[[:! { [string]: unknown }]]
  local keys = {} --: { [integer]: string }
  for k in pairs(attrs_) do keys[#keys + 1] = k --[[:! string]] end
  table.sort(keys)
  local parts = {}
  local q = quote or '"'
  for _, k in ipairs(keys) do
    local v = attrs_[k]
    parts[#parts + 1] = " " .. k .. "=" .. q .. escape_attr(tostring(v), q) .. q
  end
  return table.concat(parts)
end

--: (unknown, XastOpts | nil) -> string
local function serialize_children(children, opts)
  if not children then return "" end
  local children_ = children --[[:! { [integer]: XastNode }]]
  if #children_ == 0 then return "" end
  local parts = {}
  for _, child in ipairs(children_) do
    parts[#parts + 1] = serialize_node(child, opts)
  end
  return table.concat(parts)
end

--: (XastNode | nil, XastOpts | nil) -> string
serialize_node = function(node, opts)
  if not node then return "" end
  local opts_ = (opts or {}) --[[:! XastOpts]]
  local quote = opts_.quote or '"'
  local close_self = opts_.close_self_closing
  if close_self == nil then close_self = true end

  local t = node.type

  if t == "root" then
    local prefix = ""
    if opts_.xml_declaration then
      prefix = '<?xml version="1.0" encoding="UTF-8"?>'
    end
    return prefix .. serialize_children(node.children, opts_)

  elseif t == "element" then
    local name = tostring(node.name)
    local attrs = serialize_attrs(node.attributes, quote)
    local children = node.children or {}
    if #children == 0 then
      if close_self then
        return "<" .. name .. attrs .. "/>"
      else
        return "<" .. name .. attrs .. ">"
      end
    else
      return "<" .. name .. attrs .. ">"
          .. serialize_children(children, opts_)
          .. "</" .. name .. ">"
    end

  elseif t == "text" then
    return escape_text(tostring(node.value or ""))

  elseif t == "comment" then
    return "<!--" .. tostring(node.value or "") .. "-->"

  elseif t == "doctype" then
    local s = "<!DOCTYPE " .. tostring(node.name or "")
    if node.public then
      local q = quote or '"'
      s = s .. " PUBLIC " .. q .. tostring(node.public) .. q
      if node.system then
        s = s .. " " .. q .. tostring(node.system) .. q
      end
    elseif node.system then
      local q = quote or '"'
      s = s .. " SYSTEM " .. q .. tostring(node.system) .. q
    end
    s = s .. ">"
    return s

  elseif t == "instruction" then
    return "<?" .. tostring(node.name or "") .. " " .. tostring(node.value or "") .. "?>"

  elseif t == "cdata" then
    return "<![CDATA[" .. tostring(node.value or "") .. "]]>"

  else
    return ""
  end
end

--: (unknown) -> string
function M.to_xml(node)
  return serialize_node(node --[[:! XastNode]], nil)
end

return M
