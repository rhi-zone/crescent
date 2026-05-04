if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- A parser is a function: (string, pos) -> (result, new_pos) | (nil, errmsg)
-- pos is 1-based byte offset

-- Primitives

-- Match a literal string
function M.lit(s)
  local n = #s
  return function(input, pos)
    if input:sub(pos, pos + n - 1) == s then
      return s, pos + n
    end
    return nil, "expected " .. s .. " at position " .. pos
  end
end

-- Match a single specific character
function M.char(c)
  return function(input, pos)
    local ch = input:sub(pos, pos)
    if ch == c then
      return ch, pos + 1
    end
    return nil, "expected '" .. c .. "' at position " .. pos
  end
end

-- Match a character class (Lua pattern like "[a-z]" or "[^abc]")
-- The pattern is anchored at pos
function M.char_class(pattern)
  return function(input, pos)
    local input_ = input --[[:! string]]
    local local_pos = pos --[[:! integer]]
    local s, e = input_:find("^" .. pattern, local_pos)
    if s then
      local e_ = e --[[:! integer]]
      return input_:sub(s, e_), e_ + 1
    end
    return nil, "expected " .. pattern .. " at position " .. local_pos
  end
end

-- Match any single character
M.any_char = function(input, pos)
  if pos <= #input then
    return input:sub(pos, pos), pos + 1
  end
  return nil, "unexpected end of input at position " .. pos
end

-- Match a digit [0-9]
M.digit = function(input, pos)
  local ch = input:sub(pos, pos)
  if ch >= "0" and ch <= "9" then
    return ch, pos + 1
  end
  return nil, "expected digit at position " .. pos
end

-- Match a letter [a-zA-Z]
M.letter = function(input, pos)
  local input_ = input --[[:! string]]
  local pos_ = pos --[[:! integer]]
  local s, e = input_:find("^[a-zA-Z]", pos_)
  if s then
    local e_ = e --[[:! integer]]
    return input_:sub(s, e_), e_ + 1
  end
  return nil, "expected letter at position " .. pos_
end

-- Match whitespace (one character)
M.whitespace = function(input, pos)
  local input_ = input --[[:! string]]
  local pos_ = pos --[[:! integer]]
  local s, e = input_:find("^%s", pos_)
  if s then
    local e_ = e --[[:! integer]]
    return input_:sub(s, e_), e_ + 1
  end
  return nil, "expected whitespace at position " .. pos_
end

-- Match end of input
M.eof = function(input, pos)
  if pos > #input then
    return true, pos
  end
  return nil, "expected end of input at position " .. pos
end

-- Always succeed with value, consume nothing
function M.succeed(value)
  return function(input, pos)
    return value, pos
  end
end

-- Always fail with message
function M.fail(message)
  return function(input, pos)
    return nil, message .. " at position " .. pos
  end
end

-- Combinators

-- Sequence: all must match, returns array of results
function M.seq(...)
  local parsers = {...} --: { [integer]: (unknown, unknown) -> unknown }
  local n = #parsers
  return function(input, pos)
    local results = {}
    local cur = pos
    for i = 1, n do
      local r, np = parsers[i](input, cur)
      if r == nil then
        return nil, np
      end
      results[i] = r
      cur = np
    end
    return results, cur
  end
end

-- Ordered choice: first to succeed wins
function M.choice(...)
  local parsers = {...} --: { [integer]: (unknown, unknown) -> unknown }
  local n = #parsers
  return function(input, pos)
    local last_err
    for i = 1, n do
      local r, np = parsers[i](input, pos)
      if r ~= nil then
        return r, np
      end
      last_err = np
    end
    return nil, last_err
  end
end

-- Zero or more, returns array
function M.many(p)
  return function(input, pos)
    local results = {}
    local cur = pos
    while true do
      local r, np = p(input, cur)
      if r == nil then
        break
      end
      results[#results + 1] = r
      if np == cur then
        -- Prevent infinite loop on zero-width match
        break
      end
      cur = np
    end
    return results, cur
  end
end

-- One or more, returns array
function M.many1(p)
  return function(input, pos)
    local r, np = p(input, pos)
    if r == nil then
      return nil, np
    end
    local results = {r}
    local cur = np
    while true do
      local r2, np2 = p(input, cur)
      if r2 == nil then
        break
      end
      results[#results + 1] = r2
      if np2 == cur then
        break
      end
      cur = np2
    end
    return results, cur
  end
end

-- Zero or one, returns value or nil
function M.optional(p)
  return function(input, pos)
    local r, np = p(input, pos)
    if r ~= nil then
      return r, np
    end
    return false, pos  -- use false as "not present" sentinel (nil would be ambiguous)
  end
end

-- Match but discard result (returns true on success)
function M.skip(p)
  return function(input, pos)
    local r, np = p(input, pos)
    if r == nil then
      return nil, np
    end
    return true, np
  end
end

-- Transform result with fn
function M.map(p, fn)
  return function(input, pos)
    local r, np = p(input, pos)
    if r == nil then
      return nil, np
    end
    return fn(r), np
  end
end

-- Match open, p, close; return p's result
function M.between(open, p, close)
  return function(input, pos)
    local r1, p1 = open(input, pos)
    if r1 == nil then
      return nil, p1
    end
    local r2, p2 = p(input, p1)
    if r2 == nil then
      return nil, p2
    end
    local r3, p3 = close(input, p2)
    if r3 == nil then
      return nil, p3
    end
    return r2, p3
  end
end

-- Zero or more p separated by sep, returns array
function M.sep_by(p, sep)
  return function(input, pos)
    local r, np = p(input, pos)
    if r == nil then
      return {}, pos
    end
    local results = {r}
    local cur = np
    while true do
      local rs, nps = sep(input, cur)
      if rs == nil then
        break
      end
      local r2, np2 = p(input, nps)
      if r2 == nil then
        break
      end
      results[#results + 1] = r2
      cur = np2
    end
    return results, cur
  end
end

-- One or more p separated by sep
function M.sep_by1(p, sep)
  return function(input, pos)
    local r, np = p(input, pos)
    if r == nil then
      return nil, np
    end
    local results = {r}
    local cur = np
    while true do
      local rs, nps = sep(input, cur)
      if rs == nil then
        break
      end
      local r2, np2 = p(input, nps)
      if r2 == nil then
        break
      end
      results[#results + 1] = r2
      cur = np2
    end
    return results, cur
  end
end

-- Lazy parser for recursion (fn is called once and result is memoized)
function M.lazy(fn)
  local p = nil
  return function(input, pos)
    if p == nil then
      p = fn()
    end
    local p_fn = p --[[:! (unknown, unknown) -> unknown]]
    return p_fn(input, pos)
  end
end

-- Lookahead: succeed if p fails, consume nothing
function M.not_followed_by(p)
  return function(input, pos)
    local r, _ = p(input, pos)
    if r == nil then
      return true, pos
    end
    return nil, "unexpected match at position " .. pos
  end
end

-- Running parsers

-- Run a parser, returns (result, nil) or (nil, errmsg)
function M.parse(parser, input)
  local r, np = parser(input, 1)
  if r == nil then
    return nil, np
  end
  return r, nil
end

-- Like parse but requires full input consumed
function M.parse_all(parser, input)
  local r, np = parser(input, 1)
  if r == nil then
    return nil, np
  end
  if np <= #input then
    return nil, "unexpected input remaining at position " .. np
  end
  return r, nil
end

return M
