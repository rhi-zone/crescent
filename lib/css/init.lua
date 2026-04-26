if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Type declarations (nominal newtypes — all wrap string at runtime)
--:: newtype ClassName      = string
--:: newtype IdName         = string
--:: newtype CssVar         = string
--:: newtype AnimationName  = string
--:: newtype KeyframeName   = string
--:: newtype CssVarRef      = string
--:: CssValue = string | number

-- Constructors
-- All are identity at runtime; nominal protection is type-only.
-- The typechecker enforces nominals — these constructors are the cast points.

--: (name: string) -> string
M.class = function(name) return name end

--: (name: string) -> string
M.id = function(name) return name end

--: (name: string) -> string
M.var = function(name)
  if name:sub(1, 2) ~= "--" then
    error("css.var: variable name must start with '--', got: " .. tostring(name), 2)
  end
  return name
end

--: (name: string) -> string
M.anim = function(name) return name end

--: (name: string) -> string
M.keyframe = function(name) return name end

--: (v: string) -> string
M.varref = function(v) return "var(" .. v .. ")" end

--: (spec: { classes?: { [string]: string }, ids?: { [string]: string }, vars?: { [string]: string }, anims?: { [string]: string } }) -> { classes: { [string]: string }, ids: { [string]: string }, vars: { [string]: string }, anims: { [string]: string } }
M.declare = function(spec)
  local result = {}
  if spec.classes then
    result.classes = {}
    for k, v in pairs(spec.classes) do result.classes[k] = M.class(v) end
  else
    result.classes = {}
  end
  if spec.ids then
    result.ids = {}
    for k, v in pairs(spec.ids) do result.ids[k] = M.id(v) end
  else
    result.ids = {}
  end
  if spec.vars then
    result.vars = {}
    for k, v in pairs(spec.vars) do result.vars[k] = M.var(v) end
  else
    result.vars = {}
  end
  if spec.anims then
    result.anims = {}
    for k, v in pairs(spec.anims) do result.anims[k] = M.anim(v) end
  else
    result.anims = {}
  end
  return result
end

-- Selector DSL
local SelectorMeta = {}
SelectorMeta.__index = SelectorMeta

local function make_selector(str)
  return setmetatable({ _str = str }, SelectorMeta)
end

function SelectorMeta:desc(other) return make_selector(self._str .. " " .. other._str) end
function SelectorMeta:child(other) return make_selector(self._str .. " > " .. other._str) end
function SelectorMeta:adjacent(other) return make_selector(self._str .. " + " .. other._str) end
function SelectorMeta:sibling(other) return make_selector(self._str .. " ~ " .. other._str) end
function SelectorMeta:and_(other) return make_selector(self._str .. other._str) end
function SelectorMeta:pseudo(name) return make_selector(self._str .. ":" .. name) end
function SelectorMeta:attr(name) return make_selector(self._str .. "[" .. name .. "]") end
function SelectorMeta:attr_eq(name, value) return make_selector(self._str .. '[' .. name .. '="' .. value .. '"]') end

M.sel = {}

--: (c: ClassName) -> { _str: string, ... }
M.sel.class = function(c) return make_selector("." .. c) end

--: (i: IdName) -> { _str: string, ... }
M.sel.id = function(i) return make_selector("#" .. i) end

--: (t: string) -> { _str: string, ... }
M.sel.tag = function(t) return make_selector(t) end

--: () -> { _str: string, ... }
M.sel.universal = function() return make_selector("*") end

--: (...{ _str: string, ... }) -> { _str: string, ... }
M.sel.list = function(...)
  local parts = {}
  for _, s in ipairs({...}) do parts[#parts + 1] = s._str end
  return make_selector(table.concat(parts, ", "))
end

-- Rule and stylesheet builders

--: (selector: { _str: string, ... } | string, decls: { [string]: CssValue }) -> { _type: string, selector: { _str: string, ... } | string, decls: { [string]: CssValue } }
M.rule = function(selector, decls)
  return { _type = "rule", selector = selector, decls = decls }
end

--: (items: { [number]: { _type: string, selector: { _str: string, ... } | string, decls: { [string]: CssValue }, ... } }) -> { _type: string, items: { [number]: { _type: string, selector: { _str: string, ... } | string, decls: { [string]: CssValue }, ... } } }
M.stylesheet = function(items)
  return { _type = "stylesheet", items = items }
end

-- Renderer

--: (s: { _str: string, ... } | string) -> string
M.render_selector = function(s)
  if type(s) == "table" then return s._str or "" end
  return tostring(s)
end

-- CSS var keys (starting with "--") are not kebab-transformed.
-- Only snake_case string keys get the _ -> - transform.
--: (decls: { [string]: CssValue }) -> string
M.render_decls = function(decls)
  local parts = {}
  for k, v in pairs(decls) do
    local prop
    if type(k) == "string" and k:sub(1, 2) == "--" then
      prop = k
    elseif type(k) == "string" then
      prop = (k:gsub("_", "-"))
    else
      prop = tostring(k)
    end
    local val = tostring(v)
    parts[#parts + 1] = "  " .. prop .. ": " .. val .. ";"
  end
  table.sort(parts)
  return table.concat(parts, "\n")
end

--: (rule: { _type: string, selector: { _str: string, ... } | string, decls: { [string]: CssValue }, ... }) -> string
M.render_rule = function(rule)
  local sel = M.render_selector(rule.selector)
  local decls = M.render_decls(rule.decls)
  if decls == "" then return sel .. " {}" end
  return sel .. " {\n" .. decls .. "\n}"
end

--: (sheet: { _type: string, items: { [number]: { _type: string, selector: { _str: string, ... } | string, decls: { [string]: CssValue }, ... } } }) -> string
M.render = function(sheet)
  local parts = {}
  for _, item in ipairs(sheet.items) do
    if item._type == "rule" then
      parts[#parts + 1] = M.render_rule(item)
    end
  end
  return table.concat(parts, "\n\n")
end

return M
