if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

local M = {}

-- Parser protocol:
--   success: (result, new_pos)        — result may be nil (e.g. optional)
--   failure: (nil, err_pos, errmsg)   — errmsg is always a non-nil string
-- Failure is detected by the presence of a third return value (errmsg),
-- NOT by result == nil. This allows parsers like optional() to return
-- nil as a valid result.

--:: Parser<T> = (input: string, pos: integer) -> (T, integer) | (nil, integer, string)
--:: parser = Parser<unknown>

-- ── Primitives ──────────────────────────────────────────────────────────

--: (s: string) -> (input: string, pos: integer) -> (string, integer) | (nil, integer, string)
function M.literal(s)
  local len = #s
  return function(input, pos)
    if input:sub(pos, pos + len - 1) == s then
      return s, pos + len
    end
    return nil, pos, "expected '" .. s .. "'"
  end
end

--: (c: string) -> (input: string, pos: integer) -> (string, integer) | (nil, integer, string)
function M.char(c)
  local b = c:byte(1)
  return function(input, pos)
    if input:byte(pos) == b then
      return c, pos + 1
    end
    return nil, pos, "expected '" .. c .. "'"
  end
end

--: () -> (input: string, pos: integer) -> (string, integer) | (nil, integer, string)
function M.any_char()
  return function(input, pos)
    if pos <= #input then
      return input:sub(pos, pos), pos + 1
    end
    return nil, pos, "unexpected end of input"
  end
end

--: () -> (input: string, pos: integer) -> (true, integer) | (nil, integer, string)
function M.eof()
  return function(input, pos)
    if pos > #input then
      return true, pos
    end
    return nil, pos, "expected end of input"
  end
end

--: (fn: (c: string) -> boolean) -> (input: string, pos: integer) -> (string, integer) | (nil, integer, string)
function M.satisfy(fn)
  return function(input, pos)
    if pos > #input then
      return nil, pos, "unexpected end of input"
    end
    local c = input:sub(pos, pos)
    if fn(c) then
      return c, pos + 1
    end
    return nil, pos, "unexpected character '" .. c .. "'"
  end
end

--: (lo: string, hi: string) -> (input: string, pos: integer) -> (string, integer) | (nil, integer, string)
function M.range(lo, hi)
  local lo_b = lo:byte(1) or 0
  local hi_b = hi:byte(1) or 0
  return function(input, pos)
    local b_raw = input:byte(pos)
    if b_raw and b_raw >= lo_b and b_raw <= hi_b then
      return input:sub(pos, pos), pos + 1
    end
    return nil, pos, "expected character in range '" .. lo .. "'-'" .. hi .. "'"
  end
end

--: (chars: string) -> (input: string, pos: integer) -> (string, integer) | (nil, integer, string)
function M.one_of(chars)
  local set = {}
  for i = 1, #chars do
    set[chars:byte(i)] = true
  end
  return function(input, pos)
    local b = input:byte(pos)
    if b and set[b] then
      return input:sub(pos, pos), pos + 1
    end
    return nil, pos, "expected one of '" .. chars .. "'"
  end
end

--: (chars: string) -> (input: string, pos: integer) -> (string, integer) | (nil, integer, string)
function M.none_of(chars)
  local set = {}
  for i = 1, #chars do
    set[chars:byte(i)] = true
  end
  return function(input, pos)
    if pos > #input then
      return nil, pos, "unexpected end of input"
    end
    local b = input:byte(pos)
    if not set[b] then
      return input:sub(pos, pos), pos + 1
    end
    return nil, pos, "unexpected character '" .. input:sub(pos, pos) .. "'"
  end
end

--: (pat: string) -> (input: string, pos: integer) -> (string, integer) | (nil, integer, string)
function M.pattern(pat)
  local anchored = "^(" .. pat .. ")"
  return function(input, pos)
    local m = input:match(anchored, pos)
    if m then
      return m, pos + #m
    end
    return nil, pos, "expected pattern '" .. pat .. "'"
  end
end

-- ── Combinators ─────────────────────────────────────────────────────────

--: (...parser) -> ((input: string, pos: integer) -> ({ unknown }, integer) | (nil, integer, string))
function M.seq(...)
  local parsers = { ... }
  local n = #parsers
  return function(input, pos)
    local results = {}
    for i = 1, n do
      local r, npos, err = parsers[i](input, pos)
      if err then
        return nil, npos, err
      end
      results[i] = r
      pos = npos
    end
    return results, pos
  end
end

--: <T>(...Parser<T>) -> Parser<T>
function M.alt(...)
  local parsers = { ... }
  local n = #parsers
  return function(input, pos)
    local best_err_pos = pos
    local best_err_msg = "no alternatives matched"
    for i = 1, n do
      local r, npos, err = parsers[i](input, pos)
      if not err then
        return r, npos
      end
      if npos > best_err_pos then
        best_err_pos = npos
        best_err_msg = err
      end
    end
    return nil, best_err_pos, best_err_msg
  end
end

--: (p: parser) -> (input: string, pos: integer) -> ({ unknown }, integer)
function M.many(p)
  return function(input, pos)
    local results = {}
    local count = 0
    while true do
      local r, npos, err = p(input, pos)
      if err then
        return results, pos
      end
      count = count + 1
      results[count] = r
      pos = npos
    end
  end
end

--: (p: parser) -> (input: string, pos: integer) -> ({ unknown }, integer) | (nil, integer, string)
function M.many1(p)
  local many_p = M.many(p)
  return function(input, pos)
    local results, npos = many_p(input, pos)
    if #results == 0 then
      local _, epos, err = p(input, pos)
      return nil, epos, err
    end
    return results, npos
  end
end

--: <T>(p: Parser<T>) -> Parser<T | nil>
function M.optional(p)
  return function(input, pos)
    local r, npos, err = p(input, pos)
    if err then
      return nil, pos
    end
    return r, npos
  end
end

--: (p: parser, n: integer) -> (input: string, pos: integer) -> ({ unknown }, integer) | (nil, integer, string)
function M.count(p, n)
  return function(input, pos)
    local results = {}
    for i = 1, n do
      local r, npos, err = p(input, pos)
      if err then
        return nil, npos, err
      end
      results[i] = r
      pos = npos
    end
    return results, pos
  end
end

--: (p: parser, sep: parser) -> (input: string, pos: integer) -> ({ unknown }, integer)
function M.sep_by(p, sep)
  return function(input, pos)
    local r, npos, err = p(input, pos)
    if err then
      return {}, pos
    end
    local results = { r }
    local count = 1
    pos = npos
    while true do
      local sr, spos, serr = sep(input, pos)
      if serr then break end
      local r2, npos2, err2 = p(input, spos)
      if err2 then break end
      count = count + 1
      results[count] = r2
      pos = npos2
    end
    return results, pos
  end
end

--: (p: parser, sep: parser) -> (input: string, pos: integer) -> ({ unknown }, integer) | (nil, integer, string)
function M.sep_by1(p, sep)
  local sb = M.sep_by(p, sep)
  return function(input, pos)
    local results, npos = sb(input, pos)
    if #results == 0 then
      local _, epos, err = p(input, pos)
      return nil, epos, err
    end
    return results, npos
  end
end

--: <T>(open: Parser<unknown>, p: Parser<T>, close: Parser<unknown>) -> Parser<T>
function M.between(open, p, close)
  return function(input, pos)
    local _, npos, err = open(input, pos)
    if err then return nil, npos, err end
    local r, npos2, err2 = p(input, npos)
    if err2 then return nil, npos2, err2 end
    local _, npos3, err3 = close(input, npos2)
    if err3 then return nil, npos3, err3 end
    return r, npos3
  end
end

-- ── Transformers ────────────────────────────────────────────────────────

--: <T, U>(p: Parser<T>, fn: (T) -> U) -> Parser<U>
function M.map(p, fn)
  return function(input, pos)
    local r, npos, err = p(input, pos)
    if err then return nil, npos, err end
    return fn(r), npos
  end
end

--: <T, U>(p: Parser<T>, fn: (T) -> Parser<U>) -> Parser<U>
function M.flat_map(p, fn)
  return function(input, pos)
    local r, npos, err = p(input, pos)
    if err then return nil, npos, err end
    return fn(r)(input, npos)
  end
end

--: <T, U>(p: Parser<T>, value: U) -> Parser<U>
function M.const(p, value)
  return function(input, pos)
    local r, npos, err = p(input, pos)
    if err then return nil, npos, err end
    return value, npos
  end
end

--: (p: parser) -> (input: string, pos: integer) -> (string, integer) | (nil, integer, string)
function M.concat(p)
  return function(input, pos)
    local r, npos, err = p(input, pos)
    if err then return nil, npos, err end
    return table.concat(r), npos
  end
end

--: <T>(p: Parser<T>) -> Parser<T>
function M.peek(p)
  return function(input, pos)
    local r, _, err = p(input, pos)
    if err then return nil, pos, err end
    return r, pos
  end
end

--: (p: parser) -> (input: string, pos: integer) -> (true, integer) | (nil, integer, string)
function M.not_followed_by(p)
  return function(input, pos)
    local _, _, err = p(input, pos)
    if not err then
      return nil, pos, "unexpected match"
    end
    return true, pos
  end
end

-- ── Whitespace / lexing helpers ─────────────────────────────────────────

local function is_ws(b)
  return b == 32 or b == 9 or b == 10 or b == 13
end

--: () -> (input: string, pos: integer) -> (string, integer)
function M.ws()
  return function(input, pos)
    local len = #input
    local start = pos
    while pos <= len and is_ws(input:byte(pos)) do
      pos = pos + 1
    end
    return input:sub(start, pos - 1), pos
  end
end

--: () -> (input: string, pos: integer) -> (string, integer) | (nil, integer, string)
function M.ws1()
  return function(input, pos)
    if pos > #input or not is_ws(input:byte(pos)) then
      return nil, pos, "expected whitespace"
    end
    local start = pos
    local len = #input
    pos = pos + 1
    while pos <= len and is_ws(input:byte(pos)) do
      pos = pos + 1
    end
    return input:sub(start, pos - 1), pos
  end
end

--: <T>(p: Parser<T>) -> Parser<T>
function M.lexeme(p)
  local skip_ws = M.ws()
  return function(input, pos)
    local r, npos, err = p(input, pos)
    if err then return nil, npos, err end
    local _, npos2 = skip_ws(input, npos)
    return r, npos2
  end
end

--: (s: string) -> (input: string, pos: integer) -> (string, integer) | (nil, integer, string)
function M.token(s)
  return M.lexeme(M.literal(s))
end

-- ── Recursion ───────────────────────────────────────────────────────────

--: <T>(fn: () -> Parser<T>) -> Parser<T>
function M.lazy(fn)
  local resolved
  return function(input, pos)
    if not resolved then
      resolved = fn()
    end
    return resolved(input, pos)
  end
end

-- ── Running ─────────────────────────────────────────────────────────────

local function format_error(input, err_pos, err_msg)
  local line = 1
  local col = 1
  for i = 1, err_pos - 1 do
    if input:byte(i) == 10 then
      line = line + 1
      col = 1
    else
      col = col + 1
    end
  end
  local context_start = err_pos
  local context_end = err_pos + 19
  if context_end > #input then context_end = #input end
  local snippet = input:sub(context_start, context_end)
  snippet = snippet:gsub("\n", "\\n")
  return string.format("parse error at line %d, col %d: %s (near '%s')", line, col, err_msg or "unknown error", snippet)
end

--: <T>(parser: Parser<T>, input: string) -> (T, nil) | (nil, string)
function M.parse(parser, input)
  local r, npos, err = parser(input, 1)
  if err then
    return nil, format_error(input, npos, err)
  end
  if npos <= #input then
    return nil, format_error(input, npos, "unexpected input at position " .. npos)
  end
  return r, nil
end

--: <T>(parser: Parser<T>, input: string) -> (T, string) | (nil, string)
function M.parse_partial(parser, input)
  local r, npos, err = parser(input, 1)
  if err then
    return nil, format_error(input, npos, err)
  end
  return r, input:sub(npos)
end

return M
