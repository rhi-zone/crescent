if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- Iterator combinator utilities.
--
-- The primitive is the Lua iterator triple (fn, state, control).
-- All combinators accept and return iterators in this form, so they
-- work directly with `for ... in`.
--
-- Closures are used internally by combinators for convenience.
-- Callers who need zero-alloc hot paths should use the triple directly
-- (e.g. `for k, v in next, t do ... end`).

local iter = {}

----------------------------------------------------------------
-- Constructors
----------------------------------------------------------------

--- Integer range iterator. Infers direction from start/stop when step is nil.
--: (number, number, number | nil) -> () -> number | nil
function iter.range(start, stop, step)
  if step == 0 then error("iter.range: step cannot be 0") end
  step = step or (start <= stop and 1 or -1)
  if (start < stop and step < 0) or (start > stop and step > 0) then
    return function() return nil end, nil, nil
  end
  local current = start - step
  if step > 0 then
    return function()
      current = current + step
      if current <= stop then return current end
    end, nil, nil
  else
    return function()
      current = current + step
      if current >= stop then return current end
    end, nil, nil
  end
end

--- Iterate array values (like ipairs but yields only the value).
--: (any[]) -> () -> any
function iter.values(t)
  local i = 0
  local n = #t
  return function()
    i = i + 1
    if i <= n then return t[i] end
  end, nil, nil
end

--- Synonym for values.
iter.from = iter.values

--- Iterate table keys (unordered, like pairs but yields only keys).
--: (table) -> () -> any
function iter.keys(t)
  local k
  return function()
    k = next(t, k)
    return k
  end, nil, nil
end

--- Wrap an iterator triple (f, s, c) into a single stateful closure.
--- Useful for passing standard Lua iterators to zip/chain which accept
--- two closures. Our constructors already return closures, so wrap is
--- only needed for raw triples like pairs(t) or next, t.
--: ((any, any) -> any, any, any) -> () -> any
function iter.wrap(f, s, c)
  return function()
    local v = f(s, c)
    if v == nil then return nil end
    c = v
    return v
  end
end

----------------------------------------------------------------
-- Transformers (return new iterators)
----------------------------------------------------------------

--- Apply fn to each value.
--: ((any) -> any, (any, any) -> any, any, any) -> () -> any
function iter.map(fn, f, s, c)
  return function()
    local v = f(s, c)
    if v == nil then return nil end
    c = v
    return fn(v)
  end, nil, nil
end

--- Keep values where pred returns true.
--: ((any) -> boolean, (any, any) -> any, any, any) -> () -> any
function iter.filter(pred, f, s, c)
  return function()
    while true do
      local v = f(s, c)
      if v == nil then return nil end
      c = v
      if pred(v) then return v end
    end
  end, nil, nil
end

--- First n values.
--: (number, (any, any) -> any, any, any) -> () -> any
function iter.take(n, f, s, c)
  local remaining = n
  return function()
    if remaining <= 0 then return nil end
    remaining = remaining - 1
    local v = f(s, c)
    if v == nil then return nil end
    c = v
    return v
  end, nil, nil
end

--- Skip first n values, then yield the rest.
--: (number, (any, any) -> any, any, any) -> () -> any
function iter.skip(n, f, s, c)
  local skipped = false
  return function()
    if not skipped then
      skipped = true
      for _ = 1, n do
        local v = f(s, c)
        if v == nil then return nil end
        c = v
      end
    end
    local v = f(s, c)
    if v == nil then return nil end
    c = v
    return v
  end, nil, nil
end

--- Pair up values from two iterators. Stops at the shorter one.
--- Accepts two closures (not triples). Use iter.wrap() for raw triples.
--: ((() -> any), (() -> any)) -> () -> (any, any)
function iter.zip(it1, it2)
  return function()
    local v1 = it1()
    if v1 == nil then return nil end
    local v2 = it2()
    if v2 == nil then return nil end
    return v1, v2
  end, nil, nil
end

--- Concatenate two iterators.
--- Accepts two closures (not triples). Use iter.wrap() for raw triples.
--: ((() -> any), (() -> any)) -> () -> any
function iter.chain(it1, it2)
  local first = true
  return function()
    if first then
      local v = it1()
      if v ~= nil then return v end
      first = false
    end
    return it2()
  end, nil, nil
end

--- Map then flatten. fn must return an iterator triple (f, s, c).
--: ((any) -> ((any, any) -> any, any, any), (any, any) -> any, any, any) -> () -> any
function iter.flat_map(fn, f, s, c)
  local inner_f, inner_s, inner_c
  local outer_done = false
  return function()
    while true do
      -- Try the current inner iterator
      if inner_f then
        local v = inner_f(inner_s, inner_c)
        if v ~= nil then
          inner_c = v
          return v
        end
        inner_f = nil
      end
      -- Advance outer
      if outer_done then return nil end
      local v = f(s, c)
      if v == nil then
        outer_done = true
        return nil
      end
      c = v
      inner_f, inner_s, inner_c = fn(v)
    end
  end, nil, nil
end

--- Add index: returns i, value.
--: ((any, any) -> any, any, any) -> () -> (number, any)
function iter.enumerate(f, s, c)
  local i = 0
  return function()
    local v = f(s, c)
    if v == nil then return nil end
    c = v
    i = i + 1
    return i, v
  end, nil, nil
end

----------------------------------------------------------------
-- Consumers (consume the iterator, return a value)
----------------------------------------------------------------

--- Reduce with accumulator.
--: ((any, any) -> any, any, (any, any) -> any, any, any) -> any
function iter.fold(fn, acc, f, s, c)
  while true do
    local v = f(s, c)
    if v == nil then return acc end
    c = v
    acc = fn(acc, v)
  end
end

--- Sum of numbers.
--: ((any, any) -> any, any, any) -> number
function iter.sum(f, s, c)
  local result = 0
  while true do
    local v = f(s, c)
    if v == nil then return result end
    c = v
    result = result + v
  end
end

--- Count elements.
--: ((any, any) -> any, any, any) -> number
function iter.count(f, s, c)
  local n = 0
  while true do
    local v = f(s, c)
    if v == nil then return n end
    c = v
    n = n + 1
  end
end

--- Collect into array table.
--: ((any, any) -> any, any, any) -> any[]
function iter.to_array(f, s, c)
  local arr = {}
  local n = 0
  while true do
    local v = f(s, c)
    if v == nil then return arr end
    c = v
    n = n + 1
    arr[n] = v
  end
end

--- Call fn on each value (for side effects).
--: ((any) -> any, (any, any) -> any, any, any) -> nil
function iter.each(fn, f, s, c)
  while true do
    local v = f(s, c)
    if v == nil then return end
    c = v
    fn(v)
  end
end

--- True if any value matches predicate. Short-circuits.
--: ((any) -> boolean, (any, any) -> any, any, any) -> boolean
function iter.any(pred, f, s, c)
  while true do
    local v = f(s, c)
    if v == nil then return false end
    c = v
    if pred(v) then return true end
  end
end

--- True if all values match predicate. Short-circuits.
--: ((any) -> boolean, (any, any) -> any, any, any) -> boolean
function iter.all(pred, f, s, c)
  while true do
    local v = f(s, c)
    if v == nil then return true end
    c = v
    if not pred(v) then return false end
  end
end

--- First value matching predicate, or nil.
--: ((any) -> boolean, (any, any) -> any, any, any) -> any | nil
function iter.find(pred, f, s, c)
  while true do
    local v = f(s, c)
    if v == nil then return nil end
    c = v
    if pred(v) then return v end
  end
end

return iter
