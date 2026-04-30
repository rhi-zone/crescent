-- lib/reactive_stream/init.lua
-- Lazy pull-based stream combinators (Rx-inspired).
-- A stream is a table with a _next() function and method combinators via metatable.
-- nil terminates a stream; streams cannot contain nil values.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: Stream = { _next: () -> unknown | nil }

-- ── Core ──────────────────────────────────────────────────────────────────────

local Stream = {}
Stream.__index = Stream

--: ((() -> unknown | nil)) -> Stream
local function make_stream(next_fn)
  return setmetatable({ _next = next_fn }, Stream)
end

-- Advance the stream by one step.
--: () -> unknown | nil
function Stream:next()
  return self._next()
end

-- ── Source constructors ───────────────────────────────────────────────────────

--: (unknown[]) -> Stream
function M.from_array(arr)
  local i = 0
  local n = #arr
  return make_stream(function()
    i = i + 1
    if i <= n then return arr[i] end
  end)
end

-- Wrap a Lua stateful iterator (ipairs/pairs style: iter_fn(state, ctrl) -> ctrl, v).
--: ((() -> unknown, unknown, unknown)) -> Stream
function M.from_iter(iter_fn, state, init)
  local ctrl = init
  return make_stream(function()
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
    return make_stream(function()
      i = i + step
      if i <= stop then return i end
    end)
  else
    return make_stream(function()
      i = i + step
      if i >= stop then return i end
    end)
  end
end

--: (...unknown) -> Stream
function M.of(...)
  local args = { ... }
  local n = select("#", ...)
  local i = 0
  return make_stream(function()
    i = i + 1
    if i <= n then return args[i] end
  end)
end

--: () -> Stream
function M.empty()
  return make_stream(function() return nil end)
end

-- Repeat val n times. n=nil means infinite.
--: (unknown, (number | nil)) -> Stream
function M.repeat_(val, n)
  if n == nil then
    return make_stream(function() return val end)
  end
  local i = 0
  return make_stream(function()
    i = i + 1
    if i <= n then return val end
  end)
end

-- Unfold: fn(state) -> value, new_state. Stops when fn returns nil.
--: (((unknown) -> unknown, unknown), unknown) -> Stream
function M.generate(fn, seed)
  local state = seed
  return make_stream(function()
    local val, new_state = fn(state)
    if val == nil then return nil end
    state = new_state
    return val
  end)
end

--: (string) -> Stream
function M.chars(str)
  local i = 0
  local n = #str
  return make_stream(function()
    i = i + 1
    if i <= n then return str:sub(i, i) end
  end)
end

--: (string) -> Stream
function M.lines(str)
  -- Find each line including the final line without trailing newline.
  local pos = 1
  local len = #str
  local done = false
  return make_stream(function()
    if done then return nil end
    local s, e = str:find("\n", pos, true)
    if s then
      local line = str:sub(pos, s - 1)
      pos = e + 1
      return line
    else
      done = true
      if pos <= len then
        return str:sub(pos)
      end
      return nil
    end
  end)
end

-- ── Transformers ──────────────────────────────────────────────────────────────

--: (((unknown) -> unknown)) -> Stream
function Stream:map(fn)
  local src = self
  return make_stream(function()
    local v = src:next()
    if v == nil then return nil end
    return fn(v)
  end)
end

--: (((unknown) -> boolean)) -> Stream
function Stream:filter(fn)
  local src = self
  return make_stream(function()
    while true do
      local v = src:next()
      if v == nil then return nil end
      if fn(v) then return v end
    end
  end)
end

-- fn(val) -> Stream; flatten the resulting streams.
--: (((unknown) -> Stream)) -> Stream
function Stream:flat_map(fn)
  local src = self
  local inner = nil
  return make_stream(function()
    while true do
      if inner then
        local v = inner:next()
        if v ~= nil then return v end
        inner = nil
      end
      local v = src:next()
      if v == nil then return nil end
      inner = fn(v)
    end
  end)
end

--: (number) -> Stream
function Stream:take(n)
  local src = self
  local count = 0
  return make_stream(function()
    if count >= n then return nil end
    local v = src:next()
    if v == nil then return nil end
    count = count + 1
    return v
  end)
end

--: (number) -> Stream
function Stream:drop(n)
  local src = self
  local dropped = false
  return make_stream(function()
    if not dropped then
      for _ = 1, n do
        if src:next() == nil then
          dropped = true
          return nil
        end
      end
      dropped = true
    end
    return src:next()
  end)
end

--: (((unknown) -> boolean)) -> Stream
function Stream:take_while(pred)
  local src = self
  local done = false
  return make_stream(function()
    if done then return nil end
    local v = src:next()
    if v == nil or not pred(v) then
      done = true
      return nil
    end
    return v
  end)
end

--: (((unknown) -> boolean)) -> Stream
function Stream:drop_while(pred)
  local src = self
  local dropping = true
  return make_stream(function()
    while dropping do
      local v = src:next()
      if v == nil then return nil end
      if not pred(v) then
        dropping = false
        return v
      end
    end
    return src:next()
  end)
end

-- Returns stream of {a, b} pairs.
--: (Stream) -> Stream
function Stream:zip(other)
  local src = self
  return make_stream(function()
    local a = src:next()
    local b = other:next()
    if a == nil or b == nil then return nil end
    return { a, b }
  end)
end

-- Returns stream of fn(a, b).
--: (Stream, ((unknown, unknown) -> unknown)) -> Stream
function Stream:zip_with(other, fn)
  local src = self
  return make_stream(function()
    local a = src:next()
    local b = other:next()
    if a == nil or b == nil then return nil end
    return fn(a, b)
  end)
end

-- Returns stream of {i, val} pairs (1-indexed).
--: () -> Stream
function Stream:enumerate()
  local src = self
  local i = 0
  return make_stream(function()
    local v = src:next()
    if v == nil then return nil end
    i = i + 1
    return { i, v }
  end)
end

-- Stream of streams → flat stream (one level deep).
--: () -> Stream
function Stream:flatten()
  return self:flat_map(function(x) return x end)
end

-- Groups values into arrays of size n. Last group may be smaller.
--: (number) -> Stream
function Stream:chunk(n)
  local src = self
  local done = false
  return make_stream(function()
    if done then return nil end
    local group = {}
    for i = 1, n do
      local v = src:next()
      if v == nil then
        done = true
        if i == 1 then return nil end
        return group
      end
      group[i] = v
    end
    return group
  end)
end

-- Sliding window of size n. Returns arrays.
--: (number) -> Stream
function Stream:window(n)
  local src = self
  local buf = {}
  local ready = false
  -- Prime the buffer
  local primed = false
  return make_stream(function()
    if not primed then
      primed = true
      for i = 1, n do
        local v = src:next()
        if v == nil then
          ready = false
          return nil
        end
        buf[i] = v
      end
      ready = true
      -- Return a copy
      local w = {}
      for i = 1, n do w[i] = buf[i] end
      return w
    end
    if not ready then return nil end
    local v = src:next()
    if v == nil then return nil end
    -- Shift left and append
    for i = 1, n - 1 do buf[i] = buf[i + 1] end
    buf[n] = v
    local w = {}
    for i = 1, n do w[i] = buf[i] end
    return w
  end)
end

-- Remove consecutive duplicate values.
--: () -> Stream
function Stream:distinct()
  local src = self
  local sentinel = {}  -- unique object to represent "no previous value"
  local prev = sentinel
  return make_stream(function()
    while true do
      local v = src:next()
      if v == nil then return nil end
      if v ~= prev then
        prev = v
        return v
      end
    end
  end)
end

-- Remove ALL duplicate values (tracks seen values in a table).
--: () -> Stream
function Stream:unique()
  local src = self
  local seen = {}
  return make_stream(function()
    while true do
      local v = src:next()
      if v == nil then return nil end
      if not seen[v] then
        seen[v] = true
        return v
      end
    end
  end)
end

-- Collect, sort, re-stream. cmp is optional comparator.
--: ((((unknown, unknown) -> boolean) | nil)) -> Stream
function Stream:sort(cmp)
  local arr = self:to_array()
  table.sort(arr, cmp)
  return M.from_array(arr)
end

-- Collect, reverse, re-stream.
--: () -> Stream
function Stream:reverse()
  local arr = self:to_array()
  local n = #arr
  local rev = {}
  for i = 1, n do rev[i] = arr[n - i + 1] end
  return M.from_array(rev)
end

-- self then other.
--: (Stream) -> Stream
function Stream:concat(other)
  local src = self
  local first_done = false
  return make_stream(function()
    if not first_done then
      local v = src:next()
      if v ~= nil then return v end
      first_done = true
    end
    return other:next()
  end)
end

-- ── Terminators ───────────────────────────────────────────────────────────────

--: () -> unknown[]
function Stream:to_array()
  local result = {}
  local n = 0
  while true do
    local v = self:next()
    if v == nil then return result end
    n = n + 1
    result[n] = v
  end
end

--: () -> { [unknown]: boolean }
function Stream:to_set()
  local result = {}
  while true do
    local v = self:next()
    if v == nil then return result end
    result[v] = true
  end
end

-- key_fn(val) -> key, val_fn(val) -> mapped_value (defaults to identity).
--: (((unknown) -> unknown), (((unknown) -> unknown) | nil)) -> { [unknown]: unknown }
function Stream:to_map(key_fn, val_fn)
  local result = {}
  while true do
    local v = self:next()
    if v == nil then return result end
    local k = key_fn(v)
    result[k] = val_fn and val_fn(v) or v
  end
end

--: (((unknown) -> nil)) -> nil
function Stream:each(fn)
  while true do
    local v = self:next()
    if v == nil then return end
    fn(v)
  end
end

--: (((unknown, unknown) -> unknown), unknown) -> unknown
function Stream:fold(fn, init)
  local acc = init
  while true do
    local v = self:next()
    if v == nil then return acc end
    acc = fn(acc, v)
  end
end

-- Like fold but uses first element as initial accumulator.
--: (((unknown, unknown) -> unknown)) -> unknown | nil
function Stream:reduce(fn)
  local acc = self:next()
  if acc == nil then return nil end
  while true do
    local v = self:next()
    if v == nil then return acc end
    acc = fn(acc, v)
  end
end

--: () -> number
function Stream:sum()
  local s = 0
  while true do
    local v = self:next()
    if v == nil then return s end
    s = s + v
  end
end

--: () -> number
function Stream:count()
  local n = 0
  while true do
    local v = self:next()
    if v == nil then return n end
    n = n + 1
  end
end

--: () -> unknown | nil
function Stream:first()
  return self:next()
end

--: () -> unknown | nil
function Stream:last()
  local last = nil
  while true do
    local v = self:next()
    if v == nil then return last end
    last = v
  end
end

--: ((((unknown, unknown) -> boolean) | nil)) -> unknown | nil
function Stream:min(cmp)
  local m = nil
  while true do
    local v = self:next()
    if v == nil then return m end
    if m == nil then
      m = v
    elseif cmp then
      if cmp(v, m) then m = v end
    else
      if v < m then m = v end
    end
  end
end

--: ((((unknown, unknown) -> boolean) | nil)) -> unknown | nil
function Stream:max(cmp)
  local m = nil
  while true do
    local v = self:next()
    if v == nil then return m end
    if m == nil then
      m = v
    elseif cmp then
      if cmp(v, m) then m = v end
    else
      if v > m then m = v end
    end
  end
end

--: (((unknown) -> boolean)) -> boolean
function Stream:any(pred)
  while true do
    local v = self:next()
    if v == nil then return false end
    if pred(v) then return true end
  end
end

--: (((unknown) -> boolean)) -> boolean
function Stream:all(pred)
  while true do
    local v = self:next()
    if v == nil then return true end
    if not pred(v) then return false end
  end
end

--: (((unknown) -> boolean)) -> unknown | nil
function Stream:find(pred)
  while true do
    local v = self:next()
    if v == nil then return nil end
    if pred(v) then return v end
  end
end

--: ((string | nil)) -> string
function Stream:join(sep)
  sep = sep or ""
  local parts = self:to_array()
  return table.concat(parts, sep)
end

-- Eager: returns two arrays (truthy, falsy).
--: (((unknown) -> boolean)) -> (unknown[], unknown[])
function Stream:partition(pred)
  local t, f = {}, {}
  local nt, nf = 0, 0
  while true do
    local v = self:next()
    if v == nil then return t, f end
    if pred(v) then
      nt = nt + 1
      t[nt] = v
    else
      nf = nf + 1
      f[nf] = v
    end
  end
end

--: (((unknown) -> unknown)) -> { [unknown]: unknown[] }
function Stream:group_by(key_fn)
  local result = {}
  while true do
    local v = self:next()
    if v == nil then return result end
    local k = key_fn(v)
    local group = result[k]
    if not group then
      group = {}
      result[k] = group
    end
    group[#group + 1] = v
  end
end

-- ── Combiners (module-level) ──────────────────────────────────────────────────

-- Round-robin interleave of N streams.
--: (...Stream) -> Stream
function M.merge(...)
  local streams = { ... }
  local n = #streams
  local active = n
  local idx = 0
  -- Track which streams are exhausted
  local exhausted = {}
  return make_stream(function()
    -- Scan forward from current position; at most n steps to find a live value.
    local steps = 0
    while active > 0 and steps < n do
      idx = (idx % n) + 1
      steps = steps + 1
      if not exhausted[idx] then
        local v = streams[idx]:next()
        if v ~= nil then return v end
        -- This stream is exhausted — mark it and keep scanning
        exhausted[idx] = true
        active = active - 1
        steps = 0  -- Reset scan so we search the full remaining set
      end
    end
    return nil
  end)
end

-- One stream after another (varargs).
--: (...Stream) -> Stream
function M.concat(...)
  local streams = { ... }
  local n = #streams
  local idx = 1
  return make_stream(function()
    while idx <= n do
      local v = streams[idx]:next()
      if v ~= nil then return v end
      idx = idx + 1
    end
    return nil
  end)
end

-- Parallel zip of N streams → array of one value from each.
--: (...Stream) -> Stream
function M.zip(...)
  local streams = { ... }
  local n = #streams
  return make_stream(function()
    local row = {}
    for i = 1, n do
      local v = streams[i]:next()
      if v == nil then return nil end
      row[i] = v
    end
    return row
  end)
end

M._Stream = Stream

return M
