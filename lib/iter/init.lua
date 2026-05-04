if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local iter = {}

--: (number, number, number | nil) -> () -> number | nil
function iter.range(start, stop, step)
  if step == 0 then error("iter.range: step cannot be 0") end
  step = step or (start <= stop and 1 or -1)
  local exhausted = (start < stop and step < 0) or (start > stop and step > 0)
  local current = start - step
  local ascending = step > 0
  return function()
    if exhausted then return nil end
    current = current + step
    if ascending and current <= stop then return current end
    if not ascending and current >= stop then return current end
  end, nil, nil
end

--- Iterate array values (like ipairs but yields only the value).
--: <T>(T[]) -> () -> T
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
--: ({ [unknown]: unknown }) -> () -> unknown
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
--: ((...unknown) -> unknown, unknown, unknown) -> () -> unknown
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
--: ((unknown) -> unknown, (...unknown) -> unknown, unknown, unknown) -> () -> unknown
function iter.map(fn, f, s, c)
  return function()
    local v = f(s, c)
    if v == nil then return nil end
    c = v
    return fn(v)
  end, nil, nil
end

--- Keep values where pred returns true.
--: ((unknown) -> boolean, (...unknown) -> unknown, unknown, unknown) -> () -> unknown
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
--: (number, (...unknown) -> unknown, unknown, unknown) -> () -> unknown
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
--: (number, (...unknown) -> unknown, unknown, unknown) -> () -> unknown
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
--: <V1, V2>((() -> V1), (() -> V2)) -> () -> (V1, V2)
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
--: <V>((() -> V), (() -> V)) -> () -> V
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
--: <S, V, W>((V) -> ((S, W) -> W, S, W), (S, V) -> V, S, V) -> () -> W
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
--: <S, V>((S, V) -> V, S, V) -> () -> (number | nil, V | nil)
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
--: <S, V, A>((A, V) -> A, A, (S, V) -> V, S, V) -> A
function iter.fold(fn, acc, f, s, c)
  while true do
    local v = f(s, c)
    if v == nil then return acc end
    c = v
    acc = fn(acc, v)
  end
  return acc
end

--- Sum of numbers.
--: <S>((S, number) -> number, S, number) -> number
function iter.sum(f, s, c)
  local result = 0 --: number
  while true do
    local v = f(s, c)
    if v == nil then return result end
    c = v
    result = result + v
  end
  return result
end

--- Count elements.
--: <S, V>((S, V) -> V, S, V) -> number
function iter.count(f, s, c)
  local n = 0
  while true do
    local v = f(s, c)
    if v == nil then return n end
    c = v
    n = n + 1
  end
  return n
end

--- Collect into array table.
--: <S, V>((S, V) -> V, S, V) -> V[]
function iter.to_array(f, s, c)
  local arr = {}
  local n = 0 --: number
  while true do
    local v = f(s, c)
    if v == nil then return arr end
    c = v
    n = n + 1
    arr[n] = v
  end
  return arr
end

--- Call fn on each value (for side effects).
--: <S, V>((V) -> (), (S, V) -> V, S, V) -> ()
function iter.each(fn, f, s, c)
  while true do
    local v = f(s, c)
    if v == nil then return end
    c = v
    fn(v)
  end
end

--- True if any value matches predicate. Short-circuits.
--: <S, V>((V) -> boolean, (S, V) -> V, S, V) -> boolean
function iter.any(pred, f, s, c)
  while true do
    local v = f(s, c)
    if v == nil then return false end
    c = v
    if pred(v) then return true end
  end
  return false
end

--- True if all values match predicate. Short-circuits.
--: <S, V>((V) -> boolean, (S, V) -> V, S, V) -> boolean
function iter.all(pred, f, s, c)
  while true do
    local v = f(s, c)
    if v == nil then return true end
    c = v
    if not pred(v) then return false end
  end
  return true
end

--- First value matching predicate, or nil.
--: ((unknown) -> boolean, (...unknown) -> unknown, unknown, unknown) -> unknown
function iter.find(pred, f, s, c)
  while true do
    local v = f(s, c)
    if v == nil then return nil end
    c = v
    if pred(v) then return v end
  end
  return nil
end

return iter
