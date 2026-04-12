-- lib/pipeline_dsl: composable lazy data pipeline DSL.
-- Pull-based: no work done until a terminal sink is called.
-- Each transform wraps the previous source's next() function.
--
-- LIMITATION: pipelines cannot contain nil values — nil signals end-of-stream.
-- Use a sentinel table (e.g. { value = nil }) if nil values are needed.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Pipeline builder
-- ---------------------------------------------------------------------------

local Pipeline = {}
Pipeline.__index = Pipeline

local function new_pipeline(source_fn)
  return setmetatable({ _source = source_fn }, Pipeline)
end

-- Create an empty pipeline builder (no source yet).
-- Call :source(s) to attach a source before transforming.
function M.pipeline()
  return setmetatable({ _source = nil }, Pipeline)
end

-- Attach a source to this pipeline builder.
-- source must be a pipeline (has ._source function) or any object with ._source.
function Pipeline:source(src)
  self._source = src._source
  return self
end

-- Apply a composed step (function: source_fn -> source_fn) to this pipeline.
function Pipeline:apply(step)
  self._source = step(self._source)
  return self
end

-- ---------------------------------------------------------------------------
-- Sources  (return pipeline objects)
-- ---------------------------------------------------------------------------

-- Array source (1-based sequential).
function M.from_array(arr)
  local i = 0
  local n = #arr
  return new_pipeline(function()
    i = i + 1
    if i > n then return nil end
    return arr[i]
  end)
end

-- Iterator source — fn() called repeatedly; nil terminates.
function M.from_iter(fn)
  return new_pipeline(fn)
end

-- Numeric range [from, to] with optional step (default 1).
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

-- Repeat value v exactly n times, or infinitely if n is nil.
function M.repeat_value(v, n)
  local count = 0
  return new_pipeline(function()
    if n and count >= n then return nil end
    count = count + 1
    return v
  end)
end

-- Concatenate two sources — exhaust s1 then s2.
function M.concat_sources(s1, s2)
  local src1 = s1._source
  local src2 = s2._source
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

-- Empty source (zero elements).
function M.empty()
  return new_pipeline(function() return nil end)
end

-- ---------------------------------------------------------------------------
-- Transforms  (chainable methods on Pipeline)
-- ---------------------------------------------------------------------------

function Pipeline:map(fn)
  local src = self._source
  return new_pipeline(function()
    local v = src()
    if v == nil then return nil end
    return fn(v)
  end)
end

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

-- fn(x) returns an array; flatten those arrays one level into the stream.
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

-- Pair with a second source; stops when either exhausts.
function Pipeline:zip(other_source)
  local src_a = self._source
  local src_b = other_source._source
  return new_pipeline(function()
    local a = src_a()
    if a == nil then return nil end
    local b = src_b()
    if b == nil then return nil end
    return {a, b}
  end)
end

-- Each element becomes {index, value}, 1-based index.
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

-- Group into arrays of size n. Last chunk may be smaller.
function Pipeline:chunk(n)
  local src = self._source
  local done = false
  return new_pipeline(function()
    if done then return nil end
    local ch = {}
    for _ = 1, n do
      local v = src()
      if v == nil then
        done = true
        break
      end
      ch[#ch + 1] = v
    end
    if #ch == 0 then return nil end
    return ch
  end)
end

-- Alias for chunk.
Pipeline.batch = Pipeline.chunk

-- Deduplicate by value (non-consecutive duplicates also removed — full dedup).
function Pipeline:unique()
  local src = self._source
  local seen = {}
  return new_pipeline(function()
    while true do
      local v = src()
      if v == nil then return nil end
      if not seen[v] then
        seen[v] = true
        return v
      end
    end
  end)
end

-- Sort (buffers entire stream). cmp optional comparator.
function Pipeline:sort(cmp)
  local src = self._source
  local buf = nil
  local i = 0
  return new_pipeline(function()
    if not buf then
      buf = {}
      while true do
        local v = src()
        if v == nil then break end
        buf[#buf + 1] = v
      end
      table.sort(buf, cmp)
    end
    i = i + 1
    return buf[i]
  end)
end

-- Reverse (buffers entire stream).
function Pipeline:reverse()
  local src = self._source
  local buf = nil
  local i = 0
  return new_pipeline(function()
    if not buf then
      buf = {}
      while true do
        local v = src()
        if v == nil then break end
        buf[#buf + 1] = v
      end
      -- reverse in-place
      local lo, hi = 1, #buf
      while lo < hi do
        buf[lo], buf[hi] = buf[hi], buf[lo]
        lo = lo + 1
        hi = hi - 1
      end
    end
    i = i + 1
    return buf[i]
  end)
end

-- Flatten one level of nested arrays (each element must be an array).
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

-- Running accumulation — emits fn(acc, x) for each element.
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

-- Side-effect without transforming.
function Pipeline:tap(fn)
  local src = self._source
  return new_pipeline(function()
    local v = src()
    if v == nil then return nil end
    fn(v)
    return v
  end)
end

-- ---------------------------------------------------------------------------
-- Sinks  (terminal — execute the pipeline)
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

-- First element or nil.
function Pipeline:first()
  return self._source()
end

-- Last element or nil.
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

-- Sum all elements (numeric).
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

-- Fold to a single value.
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

-- Call fn(x) for each element (side effects). Returns count.
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

-- Collect into a set: {value → true}.
function Pipeline:to_set()
  local result = {}
  local src = self._source
  while true do
    local v = src()
    if v == nil then break end
    result[v] = true
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

-- Partition into {truthy_array, falsy_array} by predicate.
function Pipeline:partition(fn)
  local yes, no = {}, {}
  local src = self._source
  while true do
    local v = src()
    if v == nil then break end
    if fn(v) then
      yes[#yes + 1] = v
    else
      no[#no + 1] = v
    end
  end
  return yes, no
end

-- ---------------------------------------------------------------------------
-- Step constructors for composition via P.compose / :apply
-- Each returns a function: source_fn -> source_fn
-- ---------------------------------------------------------------------------

M.steps = {}

function M.steps.map(fn)
  return function(src)
    return function()
      local v = src()
      if v == nil then return nil end
      return fn(v)
    end
  end
end

function M.steps.filter(fn)
  return function(src)
    return function()
      while true do
        local v = src()
        if v == nil then return nil end
        if fn(v) then return v end
      end
    end
  end
end

function M.steps.flat_map(fn)
  return function(src)
    local inner = nil
    local inner_i = 0
    local inner_n = 0
    return function()
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
    end
  end
end

function M.steps.take(n)
  return function(src)
    local count = 0
    return function()
      if count >= n then return nil end
      local v = src()
      if v == nil then return nil end
      count = count + 1
      return v
    end
  end
end

function M.steps.drop(n)
  return function(src)
    local dropped = 0
    return function()
      while dropped < n do
        local v = src()
        if v == nil then return nil end
        dropped = dropped + 1
      end
      return src()
    end
  end
end

function M.steps.take_while(fn)
  return function(src)
    local done = false
    return function()
      if done then return nil end
      local v = src()
      if v == nil then return nil end
      if not fn(v) then
        done = true
        return nil
      end
      return v
    end
  end
end

function M.steps.drop_while(fn)
  return function(src)
    local dropping = true
    return function()
      while dropping do
        local v = src()
        if v == nil then return nil end
        if not fn(v) then
          dropping = false
          return v
        end
      end
      return src()
    end
  end
end

function M.steps.enumerate()
  return function(src)
    local i = 0
    return function()
      local v = src()
      if v == nil then return nil end
      i = i + 1
      return {i, v}
    end
  end
end

function M.steps.chunk(n)
  return function(src)
    local done = false
    return function()
      if done then return nil end
      local ch = {}
      for _ = 1, n do
        local v = src()
        if v == nil then
          done = true
          break
        end
        ch[#ch + 1] = v
      end
      if #ch == 0 then return nil end
      return ch
    end
  end
end

M.steps.batch = M.steps.chunk

function M.steps.unique()
  return function(src)
    local seen = {}
    return function()
      while true do
        local v = src()
        if v == nil then return nil end
        if not seen[v] then
          seen[v] = true
          return v
        end
      end
    end
  end
end

function M.steps.tap(fn)
  return function(src)
    return function()
      local v = src()
      if v == nil then return nil end
      fn(v)
      return v
    end
  end
end

function M.steps.scan(fn, init)
  return function(src)
    local acc = init
    return function()
      local v = src()
      if v == nil then return nil end
      acc = fn(acc, v)
      return acc
    end
  end
end

-- ---------------------------------------------------------------------------
-- Composition: chain multiple steps into a single reusable step
-- Each argument is a step constructor: source_fn -> source_fn
-- Returns a step constructor that applies all in order (left to right).
-- ---------------------------------------------------------------------------

function M.compose(...)
  local steps = {...}
  return function(src)
    local s = src
    for _, step in ipairs(steps) do
      s = step(s)
    end
    return s
  end
end

return M
