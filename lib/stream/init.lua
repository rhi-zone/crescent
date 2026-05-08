if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: Stream = {
--::   next: () -> unknown,
--::   map: (self: Stream, fn: (unknown) -> unknown) -> Stream,
--::   filter: (self: Stream, fn: (unknown) -> boolean) -> Stream,
--::   take: (self: Stream, n: integer) -> Stream,
--::   drop: (self: Stream, n: integer) -> Stream,
--::   take_while: (self: Stream, fn: (unknown) -> boolean) -> Stream,
--::   drop_while: (self: Stream, fn: (unknown) -> boolean) -> Stream,
--::   flat_map: (self: Stream, fn: (unknown) -> Stream) -> Stream,
--::   flatten: (self: Stream) -> Stream,
--::   zip: (self: Stream, other: Stream) -> Stream,
--::   chain: (self: Stream, other: Stream) -> Stream,
--::   enumerate: (self: Stream) -> Stream,
--::   unique: (self: Stream) -> Stream,
--::   dedup: (self: Stream) -> Stream,
--::   scan: (self: Stream, init: unknown, fn: (unknown, unknown) -> unknown) -> Stream,
--::   chunks: (self: Stream, n: integer) -> Stream,
--::   intersperse: (self: Stream, sep: unknown) -> Stream,
--::   tap: (self: Stream, fn: (unknown) -> nil) -> Stream,
--::   to_array: (self: Stream) -> unknown[],
--::   reduce: (self: Stream, init: unknown, fn: (unknown, unknown) -> unknown) -> unknown,
--::   for_each: (self: Stream, fn: (unknown) -> nil) -> nil,
--::   count: (self: Stream) -> integer,
--::   sum: (self: Stream) -> number,
--::   min: (self: Stream) -> (unknown | nil),
--::   max: (self: Stream) -> (unknown | nil),
--::   find: (self: Stream, fn: (unknown) -> boolean) -> (unknown | nil),
--::   any: (self: Stream, fn: (unknown) -> boolean) -> boolean,
--::   all: (self: Stream, fn: (unknown) -> boolean) -> boolean,
--::   none: (self: Stream, fn: (unknown) -> boolean) -> boolean,
--::   first: (self: Stream) -> (unknown | nil),
--::   last: (self: Stream) -> (unknown | nil),
--::   nth: (self: Stream, n: integer) -> (unknown | nil),
--::   join: (self: Stream, sep: string | nil) -> string,
--::   to_map: (self: Stream, key_fn: (unknown) -> unknown) -> { [unknown]: unknown },
--::   partition: (self: Stream, fn: (unknown) -> boolean) -> (unknown[], unknown[]),
--::   group_by: (self: Stream, fn: (unknown) -> unknown) -> { [unknown]: unknown[] },
--::   ...
--:: }

-- Stream metatable: all combinators are methods
local Stream = {}
Stream.__index = Stream

--: (next_fn: () -> (unknown | nil)) -> Stream
local function wrap(next_fn)
  local s = setmetatable({ next = next_fn }, Stream) --[[: any]]
  return s --[[:! Stream]]
end

-- ============================================================
-- Source constructors
-- ============================================================

--: (unknown[]) -> Stream
function M.from_array(arr)
  local i = 0
  local n = #arr
  return wrap(function()
    i = i + 1
    if i <= n then return arr[i] end
    return nil
  end)
end

--: ((() -> unknown, unknown, unknown)) -> Stream
function M.from_iter(iter_fn, state, init)
  local ctrl = init
  return wrap(function()
    local v
    ctrl, v = iter_fn(state, ctrl)
    if ctrl == nil then return nil end
    return v
  end)
end

--: (number, number, (number | nil)) -> Stream
function M.range(start, stop, step)
  step = step or 1
  local i = start - step
  if step > 0 then
    return wrap(function()
      i = i + step
      if i <= stop then return i end
      return nil
    end)
  else
    return wrap(function()
      i = i + step
      if i >= stop then return i end
      return nil
    end)
  end
end

--: (...unknown) -> Stream
function M.of(...)
  local args = { ... }
  local n = select("#", ...)
  local i = 0
  return wrap(function()
    i = i + 1
    if i <= n then return args[i] end
    return nil
  end)
end

--: () -> Stream
function M.empty()
  return wrap(function() return nil end)
end

--: (unknown) -> Stream
function M.repeat_(x)
  return wrap(function() return x end)
end

--: ((() -> unknown)) -> Stream
function M.generate(fn)
  return wrap(function() return fn() end)
end

--: (unknown, ((unknown) -> unknown)) -> Stream
function M.iterate(seed, fn)
  local val = seed
  local first = true
  return wrap(function()
    if first then
      first = false
      return val
    end
    val = fn(val)
    return val
  end)
end

--: (string) -> Stream
function M.from_string(str)
  local i = 0
  local n = #str
  return wrap(function()
    i = i + 1
    if i <= n then return str:sub(i, i) end
    return nil
  end)
end

-- ============================================================
-- Transformation combinators (lazy, return new Stream)
-- ============================================================

--: (self: Stream, fn: (unknown) -> unknown) -> Stream
function Stream:map(fn)
  local next_fn = self.next
  return wrap(function()
    local v = next_fn()
    if v == nil then return nil end
    return fn(v)
  end)
end

--: (self: Stream, fn: (unknown) -> boolean) -> Stream
function Stream:filter(fn)
  local next_fn = self.next
  return wrap(function()
    while true do
      local v = next_fn()
      if v == nil then return nil end
      if fn(v) then return v end
    end
  end)
end

--: (self: Stream, n: integer) -> Stream
function Stream:take(n)
  local next_fn = self.next
  local i = 0
  return wrap(function()
    if i >= n then return nil end
    i = i + 1
    return next_fn()
  end)
end

--: (self: Stream, n: integer) -> Stream
function Stream:drop(n)
  local next_fn = self.next
  local dropped = false
  return wrap(function()
    if not dropped then
      for _ = 1, n do
        if next_fn() == nil then return nil end
      end
      dropped = true
    end
    return next_fn()
  end)
end

--: (self: Stream, fn: (unknown) -> boolean) -> Stream
function Stream:take_while(fn)
  local next_fn = self.next
  local done = false
  return wrap(function()
    if done then return nil end
    local v = next_fn()
    if v == nil or not fn(v) then
      done = true
      return nil
    end
    return v
  end)
end

--: (self: Stream, fn: (unknown) -> boolean) -> Stream
function Stream:drop_while(fn)
  local next_fn = self.next
  local dropping = true
  return wrap(function()
    while dropping do
      local v = next_fn()
      if v == nil then return nil end
      if not fn(v) then
        dropping = false
        return v
      end
    end
    return next_fn()
  end)
end

--: (self: Stream, fn: (unknown) -> unknown[] | Stream) -> Stream
function Stream:flat_map(fn)
  local next_fn = self.next
  local inner = nil -- current inner stream or array iterator
  local inner_arr = nil
  local inner_idx = 0
  local inner_len = 0
  return wrap(function()
    while true do
      -- try to get from inner source
      if inner then
        local v = inner()
        if v ~= nil then return v end
        inner = nil
      end
      if inner_arr then
        inner_idx = inner_idx + 1
        if inner_idx <= inner_len then
          return inner_arr[inner_idx]
        end
        inner_arr = nil
      end
      -- get next outer element
      local v = next_fn()
      if v == nil then return nil end
      local result = fn(v)
      if result == nil then
        -- skip
      elseif getmetatable(result) == Stream then
        inner = result.next
        -- immediately try to get first element
        local first = inner()
        if first ~= nil then return first end
        inner = nil
      elseif type(result) == "table" then
        inner_arr = result
        inner_idx = 1
        inner_len = #result
        if inner_len >= 1 then return result[1] end
        inner_arr = nil
      end
    end
  end)
end

--: (self: Stream) -> Stream
function Stream:flatten()
  return self:flat_map(function(x) return x end)
end

--: (self: Stream, other: Stream) -> Stream
function Stream:zip(other)
  local next_a = self.next
  local next_b = other.next
  return wrap(function()
    local a = next_a()
    local b = next_b()
    if a == nil or b == nil then return nil end
    return { a, b }
  end)
end

--: (self: Stream, other: Stream) -> Stream
function Stream:chain(other)
  local next_a = self.next
  local next_b = other.next
  local first_done = false
  return wrap(function()
    if not first_done then
      local v = next_a()
      if v ~= nil then return v end
      first_done = true
    end
    return next_b()
  end)
end

--: (self: Stream) -> Stream
function Stream:enumerate()
  local next_fn = self.next
  local i = 0
  return wrap(function()
    local v = next_fn()
    if v == nil then return nil end
    i = i + 1
    return { i, v }
  end)
end

--: (self: Stream) -> Stream
function Stream:unique()
  local next_fn = self.next
  local prev = {} -- unique sentinel
  return wrap(function()
    while true do
      local v = next_fn()
      if v == nil then return nil end
      if v ~= prev then
        prev = v
        return v
      end
    end
  end)
end

--: (self: Stream) -> Stream
function Stream:dedup()
  local next_fn = self.next
  local seen = {}
  return wrap(function()
    while true do
      local v = next_fn()
      if v == nil then return nil end
      local key = v
      if type(v) ~= "string" and type(v) ~= "number" and type(v) ~= "boolean" then
        key = tostring(v)
      end
      if not seen[key] then
        seen[key] = true
        return v
      end
    end
  end)
end

--: (self: Stream, init: unknown, fn: (unknown, unknown) -> unknown) -> Stream
function Stream:scan(init, fn)
  local next_fn = self.next
  local acc = init
  return wrap(function()
    local v = next_fn()
    if v == nil then return nil end
    acc = fn(acc, v)
    return acc
  end)
end

--: (self: Stream, n: integer) -> Stream
function Stream:chunks(n)
  local next_fn = self.next
  local done = false
  return wrap(function()
    if done then return nil end
    local chunk = {}
    for i = 1, n do
      local v = next_fn()
      if v == nil then
        done = true
        if i == 1 then return nil end
        return chunk
      end
      chunk[i] = v
    end
    return chunk
  end)
end

--: (self: Stream, sep: unknown) -> Stream
function Stream:intersperse(sep)
  local next_fn = self.next
  local first = true
  local pending = nil
  local has_pending = false
  return wrap(function()
    if has_pending then
      has_pending = false
      return pending
    end
    local v = next_fn()
    if v == nil then return nil end
    if first then
      first = false
      return v
    end
    -- emit sep now, save v for next call
    pending = v
    has_pending = true
    return sep
  end)
end

--: (self: Stream, fn: (unknown) -> nil) -> Stream
function Stream:tap(fn)
  local next_fn = self.next
  return wrap(function()
    local v = next_fn()
    if v == nil then return nil end
    fn(v)
    return v
  end)
end

-- ============================================================
-- Terminal operations (consume the stream)
-- ============================================================

--: (self: Stream) -> unknown[]
function Stream:to_array()
  local result = {}
  local n = 0
  while true do
    local v = self.next()
    if v == nil then return result end
    n = n + 1
    result[n] = v
  end
end

--: (self: Stream, init: unknown, fn: (unknown, unknown) -> unknown) -> unknown
function Stream:reduce(init, fn)
  local acc = init
  while true do
    local v = self.next()
    if v == nil then return acc end
    acc = fn(acc, v)
  end
end

--: (self: Stream, fn: (unknown) -> nil) -> nil
function Stream:for_each(fn)
  while true do
    local v = self.next()
    if v == nil then return end
    fn(v)
  end
end

--: () -> integer
function Stream:count()
  local n = 0
  while true do
    local v = self.next()
    if v == nil then return n end
    n = n + 1
  end
end

--: () -> number
function Stream:sum()
  local s = 0
  while true do
    local v = self.next()
    if v == nil then return s end
    s = s + v
  end
end

--: (self: Stream) -> number | nil
function Stream:min()
  local m = nil
  while true do
    local v = self.next()
    if v == nil then return m end
    if m == nil or v < m then m = v end
  end
end

--: (self: Stream) -> number | nil
function Stream:max()
  local m = nil
  while true do
    local v = self.next()
    if v == nil then return m end
    if m == nil or v > m then m = v end
  end
end

--: (self: Stream, fn: (unknown) -> boolean) -> unknown | nil
function Stream:find(fn)
  while true do
    local v = self.next()
    if v == nil then return nil end
    if fn(v) then return v end
  end
end

--: ((unknown) -> boolean) -> boolean
function Stream:any(fn)
  while true do
    local v = self.next()
    if v == nil then return false end
    if fn(v) then return true end
  end
end

--: ((unknown) -> boolean) -> boolean
function Stream:all(fn)
  while true do
    local v = self.next()
    if v == nil then return true end
    if not fn(v) then return false end
  end
end

--: ((unknown) -> boolean) -> boolean
function Stream:none(fn)
  while true do
    local v = self.next()
    if v == nil then return true end
    if fn(v) then return false end
  end
end

--: (self: Stream) -> unknown | nil
function Stream:first()
  return self.next()
end

--: (self: Stream) -> unknown | nil
function Stream:last()
  local last = nil
  while true do
    local v = self.next()
    if v == nil then return last end
    last = v
  end
end

--: (self: Stream, n: integer) -> unknown | nil
function Stream:nth(n)
  for _ = 1, n - 1 do
    if self.next() == nil then return nil end
  end
  return self.next()
end

--: (self: Stream, sep: string | nil) -> string
function Stream:join(sep)
  sep = sep or ""
  local parts = self:to_array()
  return table.concat(parts, sep)
end

--: (self: Stream, key_fn: (unknown) -> unknown) -> { [unknown]: unknown }
function Stream:to_map(key_fn)
  local result = {}
  while true do
    local v = self.next()
    if v == nil then return result end
    result[key_fn(v)] = v
  end
end

--: (self: Stream, fn: (unknown) -> boolean) -> (unknown[], unknown[])
function Stream:partition(fn)
  local pass, fail = {}, {}
  local np, nf = 0, 0
  while true do
    local v = self.next()
    if v == nil then return pass, fail end
    if fn(v) then
      np = np + 1
      pass[np] = v
    else
      nf = nf + 1
      fail[nf] = v
    end
  end
end

--: (self: Stream, fn: (unknown) -> unknown) -> { [unknown]: unknown[] }
function Stream:group_by(fn)
  local result = {}
  while true do
    local v = self.next()
    if v == nil then return result end
    local key = fn(v)
    local group = result[key]
    if not group then
      group = {}
      result[key] = group
    end
    group[#group + 1] = v
  end
end

M._Stream = Stream

return M
