if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- S-expression (Lisp-style) parser and serializer.
-- Supports atoms (symbols), strings, numbers, booleans, nil, and lists.
-- Atoms/symbols are represented as tables: {_sym = name}
-- Lists are plain Lua arrays.
-- Strings are plain Lua strings.
-- Numbers are Lua numbers.
-- #t/#f are Lua booleans.
-- nil keyword is Lua nil.

local M = {}
M._tier = "pure"

-- Symbol metatable for pretty tostring
local sym_mt = {}
sym_mt.__index = sym_mt
sym_mt.__tostring = function(s) return s._sym end
sym_mt.__eq = function(a, b)
  return type(a) == "table" and type(b) == "table" and a._sym ~= nil and a._sym == b._sym
end

--- Create a symbol (atom).
-- @param name string
-- @return table symbol
function M.sym(name)
  return setmetatable({ _sym = name }, sym_mt)
end

--- Check if a value is a symbol.
-- @param v any
-- @return boolean
function M.is_sym(v)
  return type(v) == "table" and type(v._sym) == "string"
end

-- ──────────────────────────────────────────────
-- Decoder / Parser
-- ──────────────────────────────────────────────

local function make_reader(src)
  return { src = src, pos = 1, len = #src }
end

local function peek(r)
  if r.pos > r.len then return nil end
  return r.src:sub(r.pos, r.pos)
end

local function advance(r, n)
  r.pos = r.pos + (n or 1)
end

-- Skip whitespace and comments
local function skip_ws(r)
  while r.pos <= r.len do
    local c = r.src:sub(r.pos, r.pos)
    if c == " " or c == "\t" or c == "\n" or c == "\r" then
      r.pos = r.pos + 1
    elseif c == ";" then
      -- comment: skip to end of line
      while r.pos <= r.len and r.src:sub(r.pos, r.pos) ~= "\n" do
        r.pos = r.pos + 1
      end
    else
      break
    end
  end
end

-- Parse a string literal (already consumed the opening quote)
local function parse_string(r)
  -- r.pos is just after the opening "
  local buf = {}
  while r.pos <= r.len do
    local c = r.src:sub(r.pos, r.pos)
    if c == '"' then
      r.pos = r.pos + 1
      return table.concat(buf)
    elseif c == "\\" then
      r.pos = r.pos + 1
      if r.pos > r.len then
        return nil, "unexpected end of string after backslash"
      end
      local esc = r.src:sub(r.pos, r.pos)
      if esc == "n" then
        buf[#buf + 1] = "\n"
      elseif esc == "t" then
        buf[#buf + 1] = "\t"
      elseif esc == "r" then
        buf[#buf + 1] = "\r"
      elseif esc == "\\" then
        buf[#buf + 1] = "\\"
      elseif esc == '"' then
        buf[#buf + 1] = '"'
      elseif esc == "0" then
        buf[#buf + 1] = "\0"
      else
        buf[#buf + 1] = esc
      end
      r.pos = r.pos + 1
    else
      buf[#buf + 1] = c
      r.pos = r.pos + 1
    end
  end
  return nil, "unterminated string"
end

-- Characters that terminate an atom
local atom_terminators = { [" "]=true, ["\t"]=true, ["\n"]=true, ["\r"]=true,
                           ["("]=true, [")"]=true, ['"']=true, [";"]=true }

local function parse_atom_text(r)
  local start = r.pos
  while r.pos <= r.len and not atom_terminators[r.src:sub(r.pos, r.pos)] do
    r.pos = r.pos + 1
  end
  return r.src:sub(start, r.pos - 1)
end

-- Forward declaration
local parse_value

-- Parse a list (opening paren already consumed)
local function parse_list(r)
  local list = {}
  while true do
    skip_ws(r)
    if r.pos > r.len then
      return nil, "unexpected end of input, expected ')'"
    end
    local c = r.src:sub(r.pos, r.pos)
    if c == ")" then
      r.pos = r.pos + 1
      return list
    end
    local v, err = parse_value(r)
    if err then return nil, err end
    list[#list + 1] = v
  end
end

-- Coerce atom text to a Lua value
local function coerce_atom(text)
  -- boolean literals
  if text == "#t" or text == "true" then return true end
  if text == "#f" or text == "false" then return false end
  -- nil
  if text == "nil" then return nil end
  -- try number
  local n = tonumber(text)
  if n ~= nil then return n end
  -- symbol
  return M.sym(text)
end

-- Special sentinel so we can distinguish nil-parse-result from error
local NIL_ATOM = {}  -- returned when atom is the nil keyword

parse_value = function(r)
  skip_ws(r)
  if r.pos > r.len then
    return nil, "unexpected end of input"
  end
  local c = r.src:sub(r.pos, r.pos)

  if c == "(" then
    r.pos = r.pos + 1
    return parse_list(r)
  elseif c == ")" then
    return nil, "unexpected ')'"
  elseif c == '"' then
    r.pos = r.pos + 1
    return parse_string(r)
  elseif c == "'" then
    -- quote shorthand: 'x -> (quote x)
    r.pos = r.pos + 1
    local v, err = parse_value(r)
    if err then return nil, err end
    return { M.sym("quote"), v }
  else
    local text = parse_atom_text(r)
    if text == "" then
      return nil, "unexpected character: " .. c
    end
    -- Special case: nil atom needs sentinel
    if text == "nil" then
      return NIL_ATOM
    end
    return coerce_atom(text)
  end
end

-- Unwrap NIL_ATOM sentinel to actual nil
local function unwrap(v)
  if v == NIL_ATOM then return nil end
  return v
end

--- Decode a single S-expression from a string.
-- Returns the parsed value (or nil for the nil atom).
-- On error returns (nil, errmsg) — but nil is also a valid result!
-- To distinguish, this function returns (value, nil, ok_flag).
-- @param str string
-- @return value, errmsg
-- For nil values: returns nil, nil (check second return is nil for success)
-- We use a slightly different convention: returns value, err
-- To handle nil atoms: decode returns (nil, nil) for nil, (nil, errmsg) for error.
function M.decode(str)
  local r = make_reader(str)
  skip_ws(r)
  if r.pos > r.len then
    return nil, "empty input"
  end
  local v, err = parse_value(r)
  if err then return nil, err end
  -- check for trailing garbage (ignoring whitespace/comments)
  skip_ws(r)
  if r.pos <= r.len then
    -- trailing content is allowed for single decode — just stop here
    -- (decode_all handles multiple)
  end
  return unwrap(v), nil
end

--- Decode all top-level S-expressions from a string.
-- Returns a table with an `.n` field for the true count (like table.pack),
-- since nil values create holes in Lua arrays.
-- @param str string
-- @return table array of values with .n count, or nil, errmsg
function M.decode_all(str)
  local r = make_reader(str)
  local results = {}
  local n = 0
  while true do
    skip_ws(r)
    if r.pos > r.len then break end
    local v, err = parse_value(r)
    if err then return nil, err end
    n = n + 1
    results[n] = unwrap(v)
  end
  results.n = n
  return results
end

M.parse = M.decode
M.read = M.decode

-- ──────────────────────────────────────────────
-- Encoder / Serializer
-- ──────────────────────────────────────────────

-- Check if a string needs quoting as an atom (can it be written bare?)
local function needs_quote(s)
  if #s == 0 then return true end
  for i = 1, #s do
    local c = s:sub(i, i)
    if atom_terminators[c] then return true end
  end
  return false
end

-- Escape a string for serialization
local function escape_string(s)
  local buf = { '"' }
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == '"' then
      buf[#buf + 1] = '\\"'
    elseif c == "\\" then
      buf[#buf + 1] = "\\\\"
    elseif c == "\n" then
      buf[#buf + 1] = "\\n"
    elseif c == "\t" then
      buf[#buf + 1] = "\\t"
    elseif c == "\r" then
      buf[#buf + 1] = "\\r"
    elseif c == "\0" then
      buf[#buf + 1] = "\\0"
    else
      buf[#buf + 1] = c
    end
  end
  buf[#buf + 1] = '"'
  return table.concat(buf)
end

local encode_value  -- forward decl

local function encode_list(t)
  local parts = { "(" }
  for i = 1, #t do
    if i > 1 then parts[#parts + 1] = " " end
    local s, err = encode_value(t[i])
    if err then return nil, err end
    parts[#parts + 1] = s
  end
  parts[#parts + 1] = ")"
  return table.concat(parts)
end

encode_value = function(v)
  local tv = type(v)
  if tv == "nil" then
    return "nil"
  elseif tv == "boolean" then
    return v and "#t" or "#f"
  elseif tv == "number" then
    -- integer formatting: avoid ".0" for whole numbers
    if v == math.floor(v) and math.abs(v) < 2^53 then
      return string.format("%d", v)
    else
      return tostring(v)
    end
  elseif tv == "string" then
    return escape_string(v)
  elseif tv == "table" then
    if M.is_sym(v) then
      -- symbol: write bare
      return v._sym
    else
      -- list/array
      return encode_list(v)
    end
  else
    return nil, "cannot encode value of type " .. tv
  end
end

--- Encode a Lua value as an S-expression string.
-- @param v any
-- @return string, errmsg
function M.encode(v)
  return encode_value(v)
end

--- Encode multiple values as top-level S-expressions (newline separated).
-- @param values table array
-- @return string, errmsg
function M.encode_all(values)
  local parts = {}
  for i = 1, #values do
    local s, err = encode_value(values[i])
    if err then return nil, err end
    parts[#parts + 1] = s
  end
  return table.concat(parts, "\n")
end

M.write = M.encode

return M
