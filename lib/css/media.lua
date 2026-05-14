if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Media query builder — produces a media query string.
-- Returns a table with a _q field (the query string) and combinator methods.
local Query = {}
Query.__index = Query

local function make_query(str)
  return setmetatable({ _q = str }, Query)
end

-- Logical combinators
function Query:and_(other) return make_query(self._q .. " and " .. other._q) end
function Query:or_(other)  return make_query(self._q .. ", " .. other._q) end
function Query:not_()      return make_query("not " .. self._q) end

-- Primitive query constructors
M.min_width            = function(v)      return make_query("(min-width: " .. v .. ")") end
M.max_width            = function(v)      return make_query("(max-width: " .. v .. ")") end
M.min_height           = function(v)      return make_query("(min-height: " .. v .. ")") end
M.max_height           = function(v)      return make_query("(max-height: " .. v .. ")") end
M.prefers_color_scheme = function(scheme) return make_query("(prefers-color-scheme: " .. scheme .. ")") end
M.orientation          = function(o)      return make_query("(orientation: " .. o .. ")") end
M.screen               = make_query("screen")
M.print                = make_query("print")
M.all                  = make_query("all")

-- Construct a @media rule block.
-- query: a Query object or a raw string
-- items: list of rule/keyframes/nested-media tables
--: (query: { _q: string, ... } | string, items: { [integer]: unknown }) -> { _type: string, query: string, items: { [integer]: unknown } }
function M.media(query, items)
  local q --: string
  if type(query) == "table" then q = query._q else q = query end
  return { _type = "media", query = q, items = items }
end

return M
