-- lib/regex_builder/init.lua
-- Fluent builder DSL for constructing Lua pattern strings programmatically.
-- Output is a standard Lua pattern string usable with string.match/gmatch/gsub.
-- _tier = "pure"

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- Characters that need escaping in Lua patterns
local MAGIC_CHARS = "^$()%.[]*+-?"

-- Escape a literal string for use in a Lua pattern
local function escape_literal(s)
  return (s:gsub("([" .. MAGIC_CHARS:gsub("%]", "%%]"):gsub("%-", "%%-") .. "])", "%%%1"))
end

-- Actually, let's be more explicit for correctness
local function escape(s)
  return (s:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1"))
end

-- Resolve an element: either a string (already a pattern fragment) or a builder
local function resolve(elem)
  if type(elem) == "string" then
    return elem
  elseif type(elem) == "table" and elem._is_builder then
    return (elem --[[:! { build: (self: unknown) -> string, ... }]]):build()
  else
    return tostring(elem)
  end
end

-- Builder metatable
local Builder = {}
Builder.__index = Builder
Builder._is_builder = true

function Builder:build()
  return table.concat(self._parts)
end

function Builder:match(input)
  local pat = self:build()
  return string.match(input, pat)
end

function Builder:gmatch(input)
  local pat = self:build()
  return string.gmatch(input, pat)
end

function Builder:gsub(input, repl)
  local pat = self:build()
  return string.gsub(input, pat, repl)
end

-- Anchors
function Builder:start()
  self._parts[#self._parts + 1] = "^"
  return self
end

function Builder:finish()
  self._parts[#self._parts + 1] = "$"
  return self
end

-- Literal text (auto-escaped)
function Builder:literal(s)
  self._parts[#self._parts + 1] = escape(s)
  return self
end

-- Character class primitives (appended directly to builder)
function Builder:digit()
  self._parts[#self._parts + 1] = "%d"
  return self
end

function Builder:alpha()
  self._parts[#self._parts + 1] = "%a"
  return self
end

function Builder:alphanumeric()
  self._parts[#self._parts + 1] = "%w"
  return self
end

function Builder:whitespace()
  self._parts[#self._parts + 1] = "%s"
  return self
end

function Builder:lower()
  self._parts[#self._parts + 1] = "%l"
  return self
end

function Builder:upper()
  self._parts[#self._parts + 1] = "%u"
  return self
end

function Builder:punctuation()
  self._parts[#self._parts + 1] = "%p"
  return self
end

function Builder:any()
  self._parts[#self._parts + 1] = "."
  return self
end

function Builder:char_class(cls)
  -- cls should be like "[aeiou]" — used as-is
  self._parts[#self._parts + 1] = cls
  return self
end

function Builder:not_class(cls)
  -- cls is like "[aeiou]", convert to [^aeiou]
  -- strip outer brackets if present
  local inner = cls:match("^%[(.+)%]$") or cls
  self._parts[#self._parts + 1] = "[^" .. inner .. "]"
  return self
end

-- Quantifiers: accept a string element or a builder
function Builder:zero_or_more(elem)
  self._parts[#self._parts + 1] = resolve(elem) .. "*"
  return self
end

function Builder:one_or_more(elem)
  self._parts[#self._parts + 1] = resolve(elem) .. "+"
  return self
end

function Builder:maybe(elem)
  self._parts[#self._parts + 1] = resolve(elem) .. "?"
  return self
end

function Builder:exactly(n, elem)
  local frag = resolve(elem)
  local t = {}
  for _ = 1, n do
    t[#t + 1] = frag
  end
  self._parts[#self._parts + 1] = table.concat(t)
  return self
end

-- Capture: wrap in ()
function Builder:capture(elem)
  self._parts[#self._parts + 1] = "(" .. resolve(elem) .. ")"
  return self
end

-- Append a raw pattern fragment (escape handled by caller)
function Builder:raw(s)
  self._parts[#self._parts + 1] = s
  return self
end

-- Module-level element constructors (return pattern strings for use in quantifiers etc.)
function M.digit()       return "%d"  end
function M.alpha()       return "%a"  end
function M.alphanumeric() return "%w" end
function M.whitespace()  return "%s"  end
function M.lower()       return "%l"  end
function M.upper()       return "%u"  end
function M.punctuation() return "%p"  end
function M.any()         return "."   end

function M.literal(s)
  return escape(s)
end

function M.char_class(cls)
  return cls
end

function M.not_class(cls)
  local inner = cls:match("^%[(.+)%]$") or cls
  return "[^" .. inner .. "]"
end

-- Module-level quantifier helpers (standalone, not builder methods)
function M.zero_or_more_of(elem) return resolve(elem) .. "*" end
function M.one_or_more_of(elem)  return resolve(elem) .. "+" end
function M.maybe_of(elem)        return resolve(elem) .. "?" end

-- Anchors as plain strings
M.start_anchor = "^"
M.end_anchor   = "$"

-- Constructor
function M.new()
  return setmetatable({ _parts = {}, _is_builder = true }, Builder)
end

-- Sequence builder: concatenate elements
function M.sequence(...)
  local b = M.new()
  local args = {...}
  for i = 1, #args do
    local parts = b._parts --[[:! Arr<string>]]
    parts[#parts + 1] = resolve(args[i])
  end
  return b
end

-- Convenience wrappers
function M.test(pat, s)
  return string.match(s, pat) ~= nil
end

function M.extract(pat, s)
  return string.match(s, pat)
end

function M.extract_all(pat, s)
  local results = {}
  for m in string.gmatch(s, pat) do
    results[#results + 1] = m
  end
  return results
end

function M.replace(pat, s, repl)
  return string.gsub(s, pat, repl)
end

-- Named lookup
function M.named(name)
  return M.patterns[name]
end

-- Prebuilt patterns
M.patterns = {
  integer    = "-?%d+",
  float      = "-?%d+%.?%d*",
  word       = "%a+",
  identifier = "[%a_][%w_]*",
  -- simplified email: local@domain.tld
  email      = "[%w%._%+%-]+@[%w%.%-]+%.[%a][%a]+",
  -- simplified URL: http(s)://host/path
  url        = "https?://[%w%.%-_/?=&#%%]+",
  -- IPv4: four 1-3 digit groups separated by dots
  ipv4       = "%d%d?%d?%.%d%d?%d?%.%d%d?%d?%.%d%d?%d?",
  -- ISO date YYYY-MM-DD
  date_iso   = "%d%d%d%d%-%d%d%-%d%d",
  -- 24h time HH:MM:SS
  time_24    = "%d%d:%d%d:%d%d",
  -- hex color #RRGGBB or #RGB
  hex_color  = "#[%x][%x][%x][%x]?[%x]?[%x]?",
}

return M
