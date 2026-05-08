if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- SVG document builder for programmatic vector graphics.
-- Builds an element tree and serializes to SVG XML.

local M = {}

M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------------------

local function escape_attr(s)
  s = tostring(s)
  s = s:gsub("&", "&amp;")
  s = s:gsub('"', "&quot;")
  return s
end

local function escape_text(s)
  s = tostring(s)
  s = s:gsub("&", "&amp;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  s = s:gsub('"', "&quot;")
  return s
end

-- Convert underscore keys to hyphenated attribute names.
--: (k: string) -> string
local function attr_name(k)
  local r = k:gsub("_", "-")
  return r
end

-- Serialize a points array {{x,y},...} to "x,y x,y ..." string.
local function points_to_string(points)
  local parts = {}
  for i, p in ipairs(points) do
    parts[i] = p[1] .. "," .. p[2]
  end
  return table.concat(parts, " ")
end

-- Serialize attrs table to XML attribute string (space-prefixed).
local function serialize_attrs(attrs)
  if not attrs then return "" end
  local parts = {}
  for k, v in pairs(attrs) do
    if type(k) == "string" then
      parts[#parts + 1] = attr_name(k) .. '="' .. escape_attr(v) .. '"'
    end
  end
  table.sort(parts)  -- deterministic output
  if #parts == 0 then return "" end
  return " " .. table.concat(parts, " ")
end

-- Serialize an element tree to a string, appending into `buf`.
local function serialize_element(el, buf, indent)
  indent = indent or ""
  local tag = el[1]
  local attrs = el[2]
  local children = el[3]

  if tag == "__text__" then
    buf[#buf + 1] = indent .. escape_text(attrs)
    return
  end

  local attr_str = serialize_attrs(attrs)

  -- svg, g, defs, and other container elements always use open/close tags
  local always_open = tag == "svg" or tag == "g" or tag == "defs"
    or tag == "linearGradient" or tag == "radialGradient"
    or tag == "pattern" or tag == "marker" or tag == "text"

  if not always_open and (not children or #children == 0) then
    buf[#buf + 1] = indent .. "<" .. tag .. attr_str .. "/>"
  else
    buf[#buf + 1] = indent .. "<" .. tag .. attr_str .. ">"
    local child_indent = indent .. "  "
    for _, child in ipairs(children) do
      serialize_element(child, buf, child_indent)
    end
    buf[#buf + 1] = indent .. "</" .. tag .. ">"
  end
end

-- ---------------------------------------------------------------------------
-- Element node helpers
-- ---------------------------------------------------------------------------

--:: SvgEl = { [integer]: unknown }
--: (tag: string, attrs: { [string]: unknown } | nil, children: { [integer]: unknown } | nil) -> SvgEl
local function make_element(tag, attrs, children)
  return {tag, attrs, children or {}}
end

local function make_text_node(content)
  return {"__text__", content, {}}
end

-- ---------------------------------------------------------------------------
-- Container mixin — adds shape/group methods to a target that has
-- target._children list and target._doc reference.
-- ---------------------------------------------------------------------------

local Container = {}
Container.__index = Container

local Group --: { new: (doc: unknown, attrs: unknown) -> { _el: unknown, ... }, ... } | nil

function Container:_add(el)
  self._children[#self._children + 1] = el
  return el
end

function Container:rect(x, y, w, h, attrs)
  local a = attrs and {} or nil
  if attrs then for k, v in pairs(attrs) do a[k] = v end end
  a = a or {}
  a.x = x; a.y = y; a.width = w; a.height = h
  return self:_add(make_element("rect", a))
end

function Container:circle(cx, cy, r, attrs)
  local a = attrs and {} or {}
  if attrs then for k, v in pairs(attrs) do a[k] = v end end
  a.cx = cx; a.cy = cy; a.r = r
  return self:_add(make_element("circle", a))
end

function Container:ellipse(cx, cy, rx, ry, attrs)
  local a = {}
  if attrs then for k, v in pairs(attrs) do a[k] = v end end
  a.cx = cx; a.cy = cy; a.rx = rx; a.ry = ry
  return self:_add(make_element("ellipse", a))
end

function Container:line(x1, y1, x2, y2, attrs)
  local a = {}
  if attrs then for k, v in pairs(attrs) do a[k] = v end end
  a.x1 = x1; a.y1 = y1; a.x2 = x2; a.y2 = y2
  return self:_add(make_element("line", a))
end

function Container:polyline(points, attrs)
  local a = {}
  if attrs then for k, v in pairs(attrs) do a[k] = v end end
  a.points = points_to_string(points)
  return self:_add(make_element("polyline", a))
end

function Container:polygon(points, attrs)
  local a = {}
  if attrs then for k, v in pairs(attrs) do a[k] = v end end
  a.points = points_to_string(points)
  return self:_add(make_element("polygon", a))
end

function Container:path(d, attrs)
  local a = {}
  if attrs then for k, v in pairs(attrs) do a[k] = v end end
  a.d = d
  return self:_add(make_element("path", a))
end

function Container:add_path(p, attrs)
  return self:path(p:to_string(), attrs)
end

function Container:text(x, y, content, attrs)
  local a = {}
  if attrs then for k, v in pairs(attrs) do a[k] = v end end
  a.x = x; a.y = y
  local el = make_element("text", a, {make_text_node(content)})
  return self:_add(el)
end

function Container:tspan(x, y, content, attrs)
  local a = {}
  if attrs then for k, v in pairs(attrs) do a[k] = v end end
  a.x = x; a.y = y
  local el = make_element("tspan", a, {make_text_node(content)})
  return self:_add(el)
end

-- group(attrs) → Group object (manual end_group required)
-- group(attrs, fn) → calls fn(g), auto-closed
--: (self: { _add: (unknown, unknown) -> unknown, _doc: unknown, _children: unknown, ... }, attrs: unknown, fn: ((unknown) -> nil) | nil) -> unknown
function Container:group(attrs, fn)
  if Group == nil then return nil end
  local g = Group.new(self._doc or self, attrs)
  self:_add(g._el)
  if fn then
    fn(g)
  end
  return g
end

-- ---------------------------------------------------------------------------
-- Group
-- ---------------------------------------------------------------------------

Group = {}
Group.__index = setmetatable(Group, {__index = Container})

function Group.new(doc, attrs)
  local a = {} --: { [string]: unknown }
  if attrs then for k, v in pairs(attrs) do a[k] = v end end
  local el = make_element("g", a, {})
  local self = setmetatable({ _doc = doc, _el = el, _children = el[3] }, Group)
  return self
end

function Group:end_group()
  -- No-op; children already added to _el[3] via _children reference
end

-- ---------------------------------------------------------------------------
-- Defs
-- ---------------------------------------------------------------------------

local Defs = {}
Defs.__index = setmetatable(Defs, {__index = Container})

function Defs.new(doc)
  local self = setmetatable({}, Defs)
  self._doc = doc
  self._el = make_element("defs", {}, {})
  self._children = self._el[3]
  return self
end

function Defs:linear_gradient(id, opts)
  local a = {id = id}
  if opts.x1 ~= nil then a.x1 = opts.x1 end
  if opts.y1 ~= nil then a.y1 = opts.y1 end
  if opts.x2 ~= nil then a.x2 = opts.x2 end
  if opts.y2 ~= nil then a.y2 = opts.y2 end
  if opts.gradientUnits then a.gradientUnits = opts.gradientUnits end
  local stops = {}
  if opts.stops then
    for _, s in ipairs(opts.stops) do
      local sa = {offset = s.offset, ["stop-color"] = s.color}
      if s.opacity ~= nil then sa["stop-opacity"] = s.opacity end
      stops[#stops + 1] = make_element("stop", sa)
    end
  end
  local el = make_element("linearGradient", a, stops)
  return self:_add(el)
end

function Defs:radial_gradient(id, opts)
  local a = {id = id}
  if opts.cx ~= nil then a.cx = opts.cx end
  if opts.cy ~= nil then a.cy = opts.cy end
  if opts.r  ~= nil then a.r  = opts.r  end
  if opts.fx ~= nil then a.fx = opts.fx end
  if opts.fy ~= nil then a.fy = opts.fy end
  if opts.gradientUnits then a.gradientUnits = opts.gradientUnits end
  local stops = {}
  if opts.stops then
    for _, s in ipairs(opts.stops) do
      local sa = {offset = s.offset, ["stop-color"] = s.color}
      if s.opacity ~= nil then sa["stop-opacity"] = s.opacity end
      stops[#stops + 1] = make_element("stop", sa)
    end
  end
  local el = make_element("radialGradient", a, stops)
  return self:_add(el)
end

--: (self: { _add: (unknown, unknown) -> unknown, _doc: unknown, ... }, id: unknown, opts: { width?: unknown, height?: unknown, patternUnits?: unknown, ... }, fn: ((unknown) -> nil) | nil) -> unknown
function Defs:pattern(id, opts, fn)
  local a = {id = id}
  if opts.width  ~= nil then a.width  = opts.width  end
  if opts.height ~= nil then a.height = opts.height end
  if opts.patternUnits then a.patternUnits = opts.patternUnits end
  local el = make_element("pattern", a, {})
  local proxy = setmetatable({_children = el[3], _doc = self._doc}, Container)
  self:_add(el)
  if fn then fn(proxy) end
  return el
end

--: (self: { _add: (unknown, unknown) -> unknown, _doc: unknown, ... }, id: unknown, opts: { refX?: unknown, refY?: unknown, markerWidth?: unknown, markerHeight?: unknown, orient?: unknown, ... }, fn: ((unknown) -> nil) | nil) -> unknown
function Defs:marker(id, opts, fn)
  local a = {id = id}
  if opts.refX        ~= nil then a.refX        = opts.refX        end
  if opts.refY        ~= nil then a.refY        = opts.refY        end
  if opts.markerWidth  ~= nil then a.markerWidth  = opts.markerWidth  end
  if opts.markerHeight ~= nil then a.markerHeight = opts.markerHeight end
  if opts.orient      then a.orient      = opts.orient      end
  local el = make_element("marker", a, {})
  local proxy = setmetatable({_children = el[3], _doc = self._doc}, Container)
  self:_add(el)
  if fn then fn(proxy) end
  return el
end

-- ---------------------------------------------------------------------------
-- SVG Document
-- ---------------------------------------------------------------------------

local Doc = {}
Doc.__index = setmetatable(Doc, {__index = Container})

function Doc.new(width, height, opts)
  local self = setmetatable({}, Doc)
  opts = opts or {}
  local add_xmlns = opts.xmlns ~= false  -- default true

  local a = {width = width, height = height}
  if add_xmlns then
    a.xmlns = "http://www.w3.org/2000/svg"
  end
  if opts.viewBox then
    a.viewBox = opts.viewBox
  end

  self._el = make_element("svg", a, {})
  self._children = self._el[3]
  self._doc = self
  return self
end

function Doc:defs()
  local d = Defs.new(self)
  self:_add(d._el)
  return d
end

function Doc:to_string()
  local buf = {'<?xml version="1.0" encoding="UTF-8"?>'}
  serialize_element(self._el, buf, "")
  return table.concat(buf, "\n")
end

function Doc:to_file(write_fn, path)
  if type(write_fn) ~= "function" then
    error("svg.Doc:to_file: write_fn function is required")
  end
  local s = self:to_string()
  return write_fn(path, s)
end

-- ---------------------------------------------------------------------------
-- Path builder
-- ---------------------------------------------------------------------------

local Path = {}
Path.__index = Path

function Path.new()
  local self = setmetatable({}, Path)
  self._cmds = {}
  return self
end

local function path_cmd(self, cmd, ...)
  local args = {...}
  local parts = {cmd}
  for i = 1, #args do
    parts[#parts + 1] = tostring(args[i])
  end
  self._cmds[#self._cmds + 1] = table.concat(parts, " ")
end

function Path:M(x, y)     path_cmd(self, "M", x, y) return self end
function Path:m(dx, dy)   path_cmd(self, "m", dx, dy) return self end
function Path:L(x, y)     path_cmd(self, "L", x, y) return self end
function Path:l(dx, dy)   path_cmd(self, "l", dx, dy) return self end
function Path:H(x)        path_cmd(self, "H", x) return self end
function Path:V(y)        path_cmd(self, "V", y) return self end
function Path:C(x1,y1, x2,y2, x,y) path_cmd(self, "C", x1, y1, x2, y2, x, y) return self end
function Path:c(x1,y1, x2,y2, x,y) path_cmd(self, "c", x1, y1, x2, y2, x, y) return self end
function Path:Q(x1,y1, x,y) path_cmd(self, "Q", x1, y1, x, y) return self end
function Path:q(x1,y1, x,y) path_cmd(self, "q", x1, y1, x, y) return self end
function Path:S(x2,y2, x,y) path_cmd(self, "S", x2, y2, x, y) return self end
function Path:s(x2,y2, x,y) path_cmd(self, "s", x2, y2, x, y) return self end
function Path:A(rx,ry, rot, large, sweep, x,y) path_cmd(self, "A", rx, ry, rot, large, sweep, x, y) return self end
function Path:a(rx,ry, rot, large, sweep, x,y) path_cmd(self, "a", rx, ry, rot, large, sweep, x, y) return self end
function Path:Z()         self._cmds[#self._cmds + 1] = "Z" return self end

function Path:to_string()
  return table.concat(self._cmds, " ")
end

-- ---------------------------------------------------------------------------
-- Transform helpers
-- ---------------------------------------------------------------------------

function M.translate(x, y)
  if y ~= nil then
    return "translate(" .. x .. "," .. y .. ")"
  end
  return "translate(" .. x .. ")"
end

function M.scale(sx, sy)
  if sy ~= nil then
    return "scale(" .. sx .. "," .. sy .. ")"
  end
  return "scale(" .. sx .. ")"
end

function M.rotate(angle, cx, cy)
  if cx ~= nil and cy ~= nil then
    return "rotate(" .. angle .. "," .. cx .. "," .. cy .. ")"
  end
  return "rotate(" .. angle .. ")"
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.new(width, height, opts)
  return Doc.new(width, height, opts)
end

function M.path()
  return Path.new()
end

return M
