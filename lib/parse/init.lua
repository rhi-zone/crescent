if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

local M = {}

-- Parser protocol:
--   success: (result, new_pos)        — result may be nil (e.g. optional)
--   failure: (nil, err_pos, errmsg)   — errmsg is always a non-nil string
-- Failure is detected by the presence of a third return value (errmsg),
-- NOT by result == nil. This allows parsers like optional() to return
-- nil as a valid result.

--:: parser = (input: string, pos: integer) -> (unknown | nil, integer, string | nil)

-- ── Primitives ──────────────────────────────────────────────────────────


function M.literal(s)
  local len = #s
  return function(input, pos)
    input = input --[[:! string]]
    if input:sub(pos, pos + len - 1) == s then
      return s, pos + len, nil
    end
    return nil, pos, "expected '" .. s .. "'"
  end
end


function M.char(c)
  local cs = c --[[:! string]]
  local b = cs:byte(1)
  return function(input, pos)
    input = input --[[:! string]]
    pos = pos --[[:! integer]]
    if input:byte(pos) == b then
      return c, pos + 1, nil
    end
    return nil, pos, "expected '" .. cs .. "'"
  end
end


function M.any_char()
  return function(input, pos)
    input = input --[[:! string]]
    if pos <= #input then
      return input:sub(pos, pos), pos + 1, nil
    end
    return nil, pos, "unexpected end of input"
  end
end


function M.eof()
  return function(input, pos)
    if pos > #input then
      return true, pos, nil
    end
    return nil, pos, "expected end of input"
  end
end


function M.satisfy(fn)
  return function(input, pos)
    input = input --[[:! string]]
    if pos > #input then
      return nil, pos, "unexpected end of input"
    end
    local c = input:sub(pos, pos)
    if (fn(c) --[[:! boolean]]) then
      return c, pos + 1, nil
    end
    return nil, pos, "unexpected character '" .. c .. "'"
  end
end


function M.range(lo, hi)
  local lo_s = lo --[[:! string]]; local hi_s = hi --[[:! string]]
  local lo_b = lo_s:byte(1) or 0
  local hi_b = hi_s:byte(1) or 0
  return function(input, pos)
    input = input --[[:! string]]
    local b_raw = input:byte(pos)
    if b_raw and b_raw >= lo_b and b_raw <= hi_b then
      return input:sub(pos, pos), pos + 1, nil
    end
    return nil, pos, "expected character in range '" .. lo_s .. "'-'" .. hi_s .. "'"
  end
end


function M.one_of(chars)
  local chars_s = chars --[[:! string]]
  local set = {}
  for i = 1, #chars_s do
    set[chars_s:byte(i)] = true
  end
  return function(input, pos)
    input = input --[[:! string]]
    local b = input:byte(pos)
    if b and set[b] then
      return input:sub(pos, pos), pos + 1, nil
    end
    return nil, pos, "expected one of '" .. chars_s .. "'"
  end
end


function M.none_of(chars)
  local chars_s = chars --[[:! string]]
  local set = {}
  for i = 1, #chars_s do
    set[chars_s:byte(i)] = true
  end
  return function(input, pos)
    input = input --[[:! string]]
    if pos > #input then
      return nil, pos, "unexpected end of input"
    end
    local b = input:byte(pos)
    if not set[b] then
      return input:sub(pos, pos), pos + 1, nil
    end
    return nil, pos, "unexpected character '" .. input:sub(pos, pos) .. "'"
  end
end


function M.pattern(pat)
  local anchored = "^(" .. pat .. ")"
  return function(input, pos)
    input = input --[[:! string]]
    local m = input:match(anchored, pos) --[[:! string | nil]]
    if m then
      return m, pos + #m, nil
    end
    return nil, pos, "expected pattern '" .. pat .. "'"
  end
end

-- ── Combinators ─────────────────────────────────────────────────────────


function M.seq(...)
  local parsers = { ... } --: { [integer]: parser }
  local n = #parsers
  return function(input, pos)
    local results = {}
    for i = 1, n do
      local r, npos_u, err = parsers[i](input, pos)
      local npos = npos_u --[[:! integer]]
      if err then
        return nil, npos, err --[[:! string]]
      end
      results[i] = r
      pos = npos
    end
    return results, pos, nil
  end
end


function M.alt(...)
  local parsers = { ... } --: { [integer]: parser }
  local n = #parsers
  return function(input, pos)
    local best_err_pos = pos
    local best_err_msg = "no alternatives matched"
    for i = 1, n do
      local r, npos_u, err = parsers[i](input, pos)
      local npos = npos_u --[[:! integer]]
      if not err then
        return r, npos, nil
      end
      if npos > best_err_pos then
        best_err_pos = npos
        best_err_msg = err --[[:! string]]
      end
    end
    return nil, best_err_pos, best_err_msg
  end
end


function M.many(p)
  return function(input, pos)
    local results = {}
    local count = 0
    while true do
      local r, npos, err = p(input, pos)
      if err then
        return results, pos, nil
      end
      count = count + 1
      results[count] = r
      pos = npos
    end
  end
end


function M.many1(p)
  local many_p = M.many(p)
  return function(input, pos)
    local results_u, npos_u = many_p(input, pos)
    local results = results_u --[[:! { [integer]: unknown }]]
    local npos = npos_u --[[:! integer]]
    if #results == 0 then
      local _, epos_u, err = p(input, pos)
      return nil, epos_u --[[:! integer]], err
    end
    return results, npos, nil
  end
end


function M.optional(p)
  return function(input, pos)
    local r, npos, err = p(input, pos)
    if err then
      return nil, pos, nil
    end
    return r, npos, nil
  end
end


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
    return results, pos, nil
  end
end


function M.sep_by(p, sep)
  return function(input, pos)
    local r, npos, err = p(input, pos)
    if err then
      return {}, pos, nil
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
    return results, pos, nil
  end
end


function M.sep_by1(p, sep)
  local sb = M.sep_by(p, sep)
  return function(input, pos)
    local results, npos = sb(input, pos)
    if #results == 0 then
      local _, epos, err = p(input, pos)
      return nil, epos, err
    end
    return results, npos, nil
  end
end


function M.between(open, p, close)
  return function(input, pos)
    local _, npos, err = open(input, pos)
    if err then return nil, npos, err end
    local r, npos2, err2 = p(input, npos)
    if err2 then return nil, npos2, err2 end
    local _, npos3, err3 = close(input, npos2)
    if err3 then return nil, npos3, err3 end
    return r, npos3, nil
  end
end

-- ── Transformers ────────────────────────────────────────────────────────


function M.map(p, fn)
  return function(input, pos)
    local r, npos, err = p(input, pos)
    if err then return nil, npos, err end
    return fn(r --[[:! unknown]]), npos, nil
  end
end


function M.flat_map(p, fn)
  return function(input, pos)
    local r, npos, err = p(input, pos)
    if err then return nil, npos, err end
    return fn(r --[[:! unknown]])(input, npos)
  end
end


function M.const(p, value)
  return function(input, pos)
    local r, npos, err = p(input, pos)
    if err then return nil, npos, err end
    return value, npos, nil
  end
end


function M.concat(p)
  return function(input, pos)
    local r, npos, err = p(input, pos)
    if err then return nil, npos, err end
    return table.concat(r --[[:! { [integer]: string }]]), npos, nil
  end
end


function M.peek(p)
  return function(input, pos)
    local r, _, err = p(input, pos)
    if err then return nil, pos, err end
    return r, pos, nil
  end
end


function M.not_followed_by(p)
  return function(input, pos)
    local _, _, err = p(input, pos)
    if not err then
      return nil, pos, "unexpected match"
    end
    return true, pos, nil
  end
end

-- ── Whitespace / lexing helpers ─────────────────────────────────────────

local function is_ws(b)
  return b == 32 or b == 9 or b == 10 or b == 13
end


function M.ws()
  return function(input, pos)
    input = input --[[:! string]]
    local len = #input
    local start = pos
    while pos <= len and is_ws(input:byte(pos)) do
      pos = pos + 1
    end
    return input:sub(start, pos - 1), pos, nil
  end
end


function M.ws1()
  return function(input, pos)
    input = input --[[:! string]]
    if pos > #input or not is_ws(input:byte(pos)) then
      return nil, pos, "expected whitespace"
    end
    local start = pos
    local len = #input
    pos = pos + 1
    while pos <= len and is_ws(input:byte(pos)) do
      pos = pos + 1
    end
    return input:sub(start, pos - 1), pos, nil
  end
end


function M.lexeme(p)
  local skip_ws = M.ws()
  return function(input, pos)
    local r, npos, err = p(input, pos)
    if err then return nil, npos, err end
    local _, npos2 = skip_ws(input, npos)
    return r, npos2, nil
  end
end


function M.token(s)
  return M.lexeme(M.literal(s))
end

-- ── Recursion ───────────────────────────────────────────────────────────


function M.lazy(fn)
  local fn_typed = fn --[[:! () -> parser]]
  local resolved --: parser | nil
  return function(input, pos)
    input = input --[[:! string]]
    pos = pos --[[:! integer]]
    if not resolved then
      resolved = fn_typed()
    end
    return (resolved --[[:! parser]])(input, pos)
  end
end

-- ── Running ─────────────────────────────────────────────────────────────

--: (string, integer, string | nil) -> string
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

--: (parser: parser, input: string) -> (unknown | nil, string | nil)
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

--: (parser: parser, input: string) -> (unknown | nil, string | nil)
function M.parse_partial(parser, input)
  local r, npos, err = parser(input, 1)
  if err then
    return nil, format_error(input, npos, err)
  end
  return r, input:sub(npos)
end

return M
