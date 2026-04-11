-- lib/pipeline: lazy data pipeline — chain transforms, filters, and sinks on data sources.
-- Think Unix pipes but for Lua data.
--
-- LIMITATION: pipelines cannot contain nil values — nil signals end-of-stream.
-- Use a sentinel table (e.g. { value = nil }) if nil values are needed in data.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- Pipeline metatable — all transforms and sinks live here.
local Pipeline = {}
Pipeline.__index = Pipeline

local function new_pipeline(source_fn)
  return setmetatable({ _source = source_fn }, Pipeline)
end

-- ---------------------------------------------------------------------------
-- Sources
-- ---------------------------------------------------------------------------

-- Pipeline from an array (sequential, 1-based).
function M.from(arr)
  local i = 0
  local n = #arr
  return new_pipeline(function()
    i = i + 1
    if i > n then return nil end
    return arr[i]
  end)
end

-- Pipeline from an iterator function (called repeatedly; nil terminates).
function M.from_iter(iter_fn)
  return new_pipeline(iter_fn)
end

-- Pipeline from a numeric range [from, to] with optional step (default 1).
-- Supports negative step for descending ranges.
function M.range(from, to, step)
  step = step or 1
  local cur = from - step
  return new_pipeline(function()
    cur = cur + step
    if step > 0 and cur > to then return nil end
    if step < 0 and cur < to then return nil end
    return cur
  end)
end

-- Pipeline from a generator function called up to n times.
-- Terminates early if fn returns nil. If n is nil, runs until fn returns nil.
function M.generate(fn, n)
  local count = 0
  return new_pipeline(function()
    if n and count >= n then return nil end
    count = count + 1
    return fn()
  end)
end

-- Repeat a value n times. If n is nil, repeats forever.
function M.repeat_val(v, n)
  local count = 0
  return new_pipeline(function()
    if n and count >= n then return nil end
    count = count + 1
    return v
  end)
end

-- Concatenate two pipelines — exhaust p1, then p2.
function M.concat_sources(p1, p2)
  local src1 = p1._source
  local src2 = p2._source
  local done1 = false
  return new_pipeline(function()
    if not done1 then
      local v = src1()
      if v ~= nil then return v end
      done1 = true
    end
    return src2()
  end)
end

-- Empty pipeline (zero elements).
function M.empty()
  return new_pipeline(function() return nil end)
end

-- ---------------------------------------------------------------------------
-- Transforms
-- ---------------------------------------------------------------------------

-- Transform each element with fn.
function Pipeline:map(fn)
  local src = self._source
  return new_pipeline(function()
    local v = src()
    if v == nil then return nil end
    return fn(v)
  end)
end

-- Keep elements where fn(x) is truthy.
function Pipeline:filter(fn)
  local src = self._source
  return new_pipeline(function()
    while true do
      local v = src()
      if v == nil then return nil end
      if fn(v) then return v end
    end
  end)
end

-- fn(x) returns an array; flatten all arrays into the stream.
function Pipeline:flat_map(fn)
  local src = self._source
  local inner = nil
  local inner_i = 0
  local inner_n = 0
  return new_pipeline(function()
    while true do
      if inner and inner_i < inner_n then
        inner_i = inner_i + 1
        return inner[inner_i]
      end
      local v = src()
      if v == nil then return nil end
      inner = fn(v)
      inner_i = 0
      inner_n = inner and #inner or 0
    end
  end)
end

-- Take first n elements.
function Pipeline:take(n)
  local src = self._source
  local count = 0
  return new_pipeline(function()
    if count >= n then return nil end
    local v = src()
    if v == nil then return nil end
    count = count + 1
    return v
  end)
end

-- Drop first n elements.
function Pipeline:drop(n)
  local src = self._source
  local dropped = 0
  return new_pipeline(function()
    while dropped < n do
      local v = src()
      if v == nil then return nil end
      dropped = dropped + 1
    end
    return src()
  end)
end

-- Take elements while fn(x) is true.
function Pipeline:take_while(fn)
  local src = self._source
  local done = false
  return new_pipeline(function()
    if done then return nil end
    local v = src()
    if v == nil then return nil end
    if not fn(v) then
      done = true
      return nil
    end
    return v
  end)
end

-- Drop elements while fn(x) is true, then pass through remainder.
function Pipeline:drop_while(fn)
  local src = self._source
  local dropping = true
  return new_pipeline(function()
    while dropping do
      local v = src()
      if v == nil then return nil end
      if not fn(v) then
        dropping = false
        return v
      end
    end
    return src()
  end)
end

-- Each element becomes {index, value}, 1-based.
function Pipeline:enumerate()
  local src = self._source
  local i = 0
  return new_pipeline(function()
    local v = src()
    if v == nil then return nil end
    i = i + 1
    return {i, v}
  end)
end

-- Zip with another pipeline — emit {a, b} pairs; stops when either exhausts.
function Pipeline:zip(other)
  local src_a = self._source
  local src_b = other._source
  return new_pipeline(function()
    local a = src_a()
    if a == nil then return nil end
    local b = src_b()
    if b == nil then return nil end
    return {a, b}
  end)
end

-- Group elements into arrays of size n. Last batch may be smaller.
function Pipeline:batch(n)
  local src = self._source
  local done = false
  return new_pipeline(function()
    if done then return nil end
    local batch = {}
    for _ = 1, n do
      local v = src()
      if v == nil then
        done = true
        break
      end
      batch[#batch + 1] = v
    end
    if #batch == 0 then return nil end
    return batch
  end)
end

-- Flatten one level of nested arrays (each element is expected to be an array).
function Pipeline:flatten()
  local src = self._source
  local inner = nil
  local inner_i = 0
  local inner_n = 0
  return new_pipeline(function()
    while true do
      if inner and inner_i < inner_n then
        inner_i = inner_i + 1
        return inner[inner_i]
      end
      local v = src()
      if v == nil then return nil end
      inner = v
      inner_i = 0
      inner_n = #v
    end
  end)
end

-- Deduplicate consecutive equal elements (streaming; only adjacent duplicates removed).
function Pipeline:unique()
  local src = self._source
  local sentinel = {} -- unique table, never equal to any user value
  local last = sentinel
  return new_pipeline(function()
    while true do
      local v = src()
      if v == nil then return nil end
      if v ~= last then
        last = v
        return v
      end
    end
  end)
end

-- Call fn(x) for side effects, pass element through unchanged.
function Pipeline:tap(fn)
  local src = self._source
  return new_pipeline(function()
    local v = src()
    if v == nil then return nil end
    fn(v)
    return v
  end)
end

-- Running accumulation — like reduce but emits each intermediate result.
-- The first emitted value is fn(init, first_element).
function Pipeline:scan(fn, init)
  local src = self._source
  local acc = init
  return new_pipeline(function()
    local v = src()
    if v == nil then return nil end
    acc = fn(acc, v)
    return acc
  end)
end

-- Sliding window of size n — each emission is an array of exactly n consecutive elements.
-- Emits only when the window is full (starts emitting after the first n elements are seen).
-- Each emission is a fresh copy of the current n-element window.
function Pipeline:window(n)
  local src = self._source
  -- Circular buffer of the last n elements.
  local buf = {}
  local count = 0
  return new_pipeline(function()
    while true do
      local v = src()
      if v == nil then return nil end
      count = count + 1
      buf[count] = v
      if count >= n then
        -- copy the last n elements in order
        local win = {}
        for i = count - n + 1, count do
          win[#win + 1] = buf[i]
        end
        return win
      end
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Sinks
-- ---------------------------------------------------------------------------

-- Collect all elements into an array.
function Pipeline:collect()
  local result = {}
  local src = self._source
  while true do
    local v = src()
    if v == nil then break end
    result[#result + 1] = v
  end
  return result
end

-- Fold to a single value. fn(acc, x) called for each element.
function Pipeline:reduce(fn, init)
  local acc = init
  local src = self._source
  while true do
    local v = src()
    if v == nil then break end
    acc = fn(acc, v)
  end
  return acc
end

-- Call fn(x) for each element. Returns total count.
function Pipeline:each(fn)
  local count = 0
  local src = self._source
  while true do
    local v = src()
    if v == nil then break end
    fn(v)
    count = count + 1
  end
  return count
end

-- Count all elements.
function Pipeline:count()
  local n = 0
  local src = self._source
  while true do
    local v = src()
    if v == nil then break end
    n = n + 1
  end
  return n
end

-- Return first element or nil if empty.
function Pipeline:first()
  return self._source()
end

-- Return last element or nil if empty.
function Pipeline:last()
  local last = nil
  local src = self._source
  while true do
    local v = src()
    if v == nil then break end
    last = v
  end
  return last
end

-- Sum all elements (assumes numeric).
function Pipeline:sum()
  local total = 0
  local src = self._source
  while true do
    local v = src()
    if v == nil then break end
    total = total + v
  end
  return total
end

-- Minimum element (assumes comparable via <). Returns nil for empty pipeline.
function Pipeline:min()
  local src = self._source
  local result = src()
  if result == nil then return nil end
  while true do
    local v = src()
    if v == nil then break end
    if v < result then result = v end
  end
  return result
end

-- Maximum element (assumes comparable via >). Returns nil for empty pipeline.
function Pipeline:max()
  local src = self._source
  local result = src()
  if result == nil then return nil end
  while true do
    local v = src()
    if v == nil then break end
    if v > result then result = v end
  end
  return result
end

-- Return true if any element satisfies fn.
function Pipeline:any(fn)
  local src = self._source
  while true do
    local v = src()
    if v == nil then return false end
    if fn(v) then return true end
  end
end

-- Return true if all elements satisfy fn (true for empty pipeline).
function Pipeline:all(fn)
  local src = self._source
  while true do
    local v = src()
    if v == nil then return true end
    if not fn(v) then return false end
  end
end

-- Return first element satisfying fn, or nil.
function Pipeline:find(fn)
  local src = self._source
  while true do
    local v = src()
    if v == nil then return nil end
    if fn(v) then return v end
  end
end

-- Build a map from pipeline elements. key_fn(x) → key, val_fn(x) → value.
-- If val_fn is nil, the value is the element itself.
function Pipeline:to_map(key_fn, val_fn)
  local result = {}
  local src = self._source
  while true do
    local v = src()
    if v == nil then break end
    local k = key_fn(v)
    result[k] = val_fn and val_fn(v) or v
  end
  return result
end

-- Group elements into a map of arrays by key_fn(x).
function Pipeline:group_by(key_fn)
  local result = {}
  local src = self._source
  while true do
    local v = src()
    if v == nil then break end
    local k = key_fn(v)
    if result[k] == nil then result[k] = {} end
    local g = result[k]
    g[#g + 1] = v
  end
  return result
end

-- Join elements as strings with separator. Returns a string.
function Pipeline:join(sep)
  local parts = {}
  local src = self._source
  while true do
    local v = src()
    if v == nil then break end
    parts[#parts + 1] = tostring(v)
  end
  return table.concat(parts, sep)
end

-- Consume all elements (for side effects). Returns nothing.
function Pipeline:drain()
  local src = self._source
  while true do
    local v = src()
    if v == nil then break end
  end
end

return M
