-- lib/unified/xast_util_to_xml/init.lua
-- xast-util-to-xml: standalone serializer for xast trees to XML strings.
-- Port of https://github.com/syntax-tree/xast-util-to-xml
--
-- Standalone from the spec module for vendorability.
--
-- Options:
--   opts.quote             string   attribute quote character ('"' default or "'")
--   opts.close_self_closing boolean  use <br/> vs <br> (default true)
--   opts.xml_declaration   boolean  prepend <?xml version="1.0" encoding="UTF-8"?> (default false)
--
-- API:
--   to_xml(node, opts) -> string

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local xast = require("lib.unified.xast")

local M = {}

-- ── Escaping helpers (duplicated so this module is vendorable standalone) ─────

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

-- ── Serializer ────────────────────────────────────────────────────────────────

local serialize_node  -- forward declaration

--: (any, string) -> string
local function serialize_attrs(attributes, quote)
  if not attributes then return "" end
  local keys = {}
  for k in pairs(attributes) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  local q = quote or '"'
  for _, k in ipairs(keys) do
    local v = attributes[k]
    parts[#parts + 1] = " " .. k .. "=" .. q .. escape_attr(tostring(v), q) .. q
  end
  return table.concat(parts)
end

--: (any, any) -> string
local function serialize_children(children, opts)
  if not children or #children == 0 then return "" end
  local parts = {}
  for _, child in ipairs(children) do
    parts[#parts + 1] = serialize_node(child, opts)
  end
  return table.concat(parts)
end

--: (any, any) -> string
serialize_node = function(node, opts)
  if not node then return "" end
  opts = opts or {}
  local quote = opts.quote or '"'
  local close_self = opts.close_self_closing
  if close_self == nil then close_self = true end

  local t = node.type

  if t == "root" then
    local prefix = ""
    if opts.xml_declaration then
      prefix = '<?xml version="1.0" encoding="UTF-8"?>'
    end
    return prefix .. serialize_children(node.children, opts)

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
          .. serialize_children(children, opts)
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

-- Serialize an xast node tree to an XML string.
-- opts.quote             ('"' | "'")   default '"'
-- opts.close_self_closing (boolean)     default true
-- opts.xml_declaration   (boolean)     default false
--: (any, any) -> string
function M.to_xml(node, opts)
  return serialize_node(node, opts or {})
end

-- Expose xast constructors for convenience.
M.root        = xast.root
M.element     = xast.element
M.text        = xast.text
M.comment     = xast.comment
M.doctype     = xast.doctype
M.instruction = xast.instruction
M.cdata       = xast.cdata

return M
