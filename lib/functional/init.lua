if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- Comprehensive functional programming toolkit for LuaJIT.
-- All array functions work on 1-indexed Lua arrays and return new arrays.

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Core higher-order functions
-- ---------------------------------------------------------------------------

-- map(t, fn) -> new array with fn applied to each element.
function M.map(t, fn)
  local out = {}
  for i = 1, #t do out[i] = fn(t[i], i) end
  return out
end

-- filter(t, fn) -> new array of elements where fn returns truthy.
function M.filter(t, fn)
  local out = {}
  local j = 0
  for i = 1, #t do
    if fn(t[i], i) then
      j = j + 1
      out[j] = t[i]
    end
  end
  return out
end

-- reduce(t, fn, init) -> left fold.
function M.reduce(t, fn, init)
  local acc = init
  for i = 1, #t do acc = fn(acc, t[i], i) end
  return acc
end

-- reduce_right(t, fn, init) -> right fold.
function M.reduce_right(t, fn, init)
  local acc = init
  for i = #t, 1, -1 do acc = fn(acc, t[i], i) end
  return acc
end

-- each(t, fn) -> calls fn(v, i) for each element; returns nothing.
function M.each(t, fn)
  for i = 1, #t do fn(t[i], i) end
end

-- flat_map(t, fn) -> map then flatten one level.
function M.flat_map(t, fn)
  local out = {}
  local j = 0
  for i = 1, #t do
    local sub = fn(t[i], i)
    for k = 1, #sub do
      j = j + 1
      out[j] = sub[k]
    end
  end
  return out
end

-- zip(...) -> array of arrays, truncated to shortest input.
-- zip({1,2},{a,b}) = {{1,a},{2,b}}
function M.zip(...)
  local arrays = { ... } --: { [integer]: { [integer]: unknown } }
  local n = #arrays
  if n == 0 then return {} end
  local len = #arrays[1]
  for i = 2, n do
    local l = #arrays[i]
    if l < len then len = l end
  end
  local out = {}
  for i = 1, len do
    local row = {}
    for j = 1, n do row[j] = arrays[j][i] end
    out[i] = row
  end
  return out
end

-- zip_with(fn, ...) -> zip then apply fn to each tuple (as varargs).
function M.zip_with(fn, ...)
  local arrays = { ... } --: { [integer]: { [integer]: unknown } }
  local n = #arrays
  if n == 0 then return {} end
  local len = #arrays[1]
  for i = 2, n do
    local l = #arrays[i]
    if l < len then len = l end
  end
  local out = {}
  for i = 1, len do
    local row = {}
    for j = 1, n do row[j] = arrays[j][i] end
    out[i] = fn(unpack(row))
  end
  return out
end

-- unzip(pairs_arr) -> multiple arrays; inverse of zip.
-- unzip({{1,"a"},{2,"b"}}) = {{1,2},{"a","b"}}
function M.unzip(pairs_arr)
  local m = #pairs_arr
  if m == 0 then return {} end
  local width = #pairs_arr[1]
  local out = {}
  for j = 1, width do out[j] = {} end
  for i = 1, m do
    for j = 1, width do out[j][i] = pairs_arr[i][j] end
  end
  return out
end

-- take(t, n) -> first n elements.
function M.take(t, n)
  local out = {}
  local len = #t
  local stop = n < len and n or len
  for i = 1, stop do out[i] = t[i] end
  return out
end

-- drop(t, n) -> all but first n elements.
function M.drop(t, n)
  local out = {}
  local len = #t
  local j = 0
  for i = n + 1, len do
    j = j + 1
    out[j] = t[i]
  end
  return out
end

-- take_while(t, fn) -> elements from start while predicate holds.
function M.take_while(t, fn)
  local out = {}
  for i = 1, #t do
    if not fn(t[i], i) then break end
    out[i] = t[i]
  end
  return out
end

-- drop_while(t, fn) -> skip elements while predicate holds, return the rest.
function M.drop_while(t, fn)
  local out = {}
  local dropping = true
  local j = 0
  for i = 1, #t do
    if dropping and fn(t[i], i) then
      -- continue dropping
    else
      dropping = false
      j = j + 1
      out[j] = t[i]
    end
  end
  return out
end

-- chunk(t, n) -> split into consecutive chunks of size n; last may be smaller.
function M.chunk(t, n)
  local out = {}
  local len = #t
  local k = 0
  local i = 1
  while i <= len do
    k = k + 1
    local chunk = {}
    for j = 1, n do
      if i > len then break end
      chunk[j] = t[i]
      i = i + 1
    end
    out[k] = chunk
  end
  return out
end

-- window(t, n) -> sliding windows of size n.
function M.window(t, n)
  local out = {}
  local len = #t
  local k = 0
  for i = 1, len - n + 1 do
    k = k + 1
    local w = {}
    for j = 1, n do w[j] = t[i + j - 1] end
    out[k] = w
  end
  return out
end

-- flatten(t) -> deeply flatten nested arrays.
function M.flatten(t)
  local out = {}
  local function go(arr)
    for i = 1, #arr do
      local v = arr[i]
      if type(v) == "table" then go(v)
      else out[#out + 1] = v end
    end
  end
  go(t)
  return out
end

-- flatten1(t) -> flatten one level.
function M.flatten1(t)
  local out = {}
  local j = 0
  for i = 1, #t do
    local v = t[i]
    if type(v) == "table" then
      for k = 1, #v do j = j + 1; out[j] = v[k] end
    else
      j = j + 1; out[j] = v
    end
  end
  return out
end

-- unique(t, key_fn?) -> remove duplicates; key_fn(v)->key for equality.
function M.unique(t, key_fn)
  local seen = {}
  local out = {}
  local j = 0
  for i = 1, #t do
    local v = t[i]
    local key = key_fn and key_fn(v) or v
    if not seen[key] then
      seen[key] = true
      j = j + 1
      out[j] = v
    end
  end
  return out
end

-- group_by(t, fn) -> {[key]=[elements]} table.
function M.group_by(t, fn)
  local out = {}
  for i = 1, #t do
    local v = t[i]
    local key = fn(v, i)
    if out[key] == nil then out[key] = {} end
    out[key][#out[key] + 1] = v
  end
  return out
end

-- sort_by(t, fn) -> new array sorted by key function.
function M.sort_by(t, fn)
  local out = {}
  for i = 1, #t do out[i] = t[i] end
  table.sort(out, function(a, b) return fn(a) < fn(b) end)
  return out
end

-- count_by(t, fn) -> {[key]=count}.
function M.count_by(t, fn)
  local out = {}
  for i = 1, #t do
    local key = fn(t[i], i)
    out[key] = (out[key] or 0) + 1
  end
  return out
end

-- partition(t, fn) -> {trues, falses}.
function M.partition(t, fn)
  local yes, no = {}, {}
  local yj, nj = 0, 0
  for i = 1, #t do
    local v = t[i]
    if fn(v, i) then yj = yj + 1; yes[yj] = v
    else nj = nj + 1; no[nj] = v end
  end
  return yes, no
end

-- find(t, fn) -> first element matching predicate, or nil.
function M.find(t, fn)
  for i = 1, #t do
    if fn(t[i], i) then return t[i] end
  end
  return nil
end

-- find_index(t, fn) -> index of first match, or nil.
function M.find_index(t, fn)
  for i = 1, #t do
    if fn(t[i], i) then return i end
  end
  return nil
end

-- any(t, fn) -> true if any element matches.
function M.any(t, fn)
  for i = 1, #t do
    if fn(t[i], i) then return true end
  end
  return false
end

-- all(t, fn) -> true if all elements match.
function M.all(t, fn)
  for i = 1, #t do
    if not fn(t[i], i) then return false end
  end
  return true
end

-- none(t, fn) -> true if no elements match.
function M.none(t, fn)
  for i = 1, #t do
    if fn(t[i], i) then return false end
  end
  return true
end

-- sum(t) -> arithmetic sum.
function M.sum(t)
  local s = 0
  for i = 1, #t do s = s + t[i] end
  return s
end

-- product(t) -> arithmetic product.
function M.product(t)
  local p = 1
  for i = 1, #t do p = p * t[i] end
  return p
end

-- min(t, fn?) -> minimum element (by key fn or identity).
function M.min(t, fn)
  if #t == 0 then return nil end
  local best = t[1]
  local best_key = fn and fn(best) or best
  for i = 2, #t do
    local key = fn and fn(t[i]) or t[i]
    if key < best_key then best = t[i]; best_key = key end
  end
  return best
end

-- max(t, fn?) -> maximum element (by key fn or identity).
function M.max(t, fn)
  if #t == 0 then return nil end
  local best = t[1]
  local best_key = fn and fn(best) or best
  for i = 2, #t do
    local key = fn and fn(t[i]) or t[i]
    if key > best_key then best = t[i]; best_key = key end
  end
  return best
end

-- ---------------------------------------------------------------------------
-- Function combinators
-- ---------------------------------------------------------------------------

-- identity(x) -> x
function M.identity(x) return x end

-- constant(x) -> function that always returns x.
function M.constant(x)
  return function() return x end
end

-- compose(f, g, ...) -> right-to-left composition. compose(f,g)(x) = f(g(x))
function M.compose(...)
  local fns = { ... } --: { [integer]: function }
  local n = #fns
  if n == 0 then return M.identity end
  if n == 1 then return fns[1] end
  return function(...)
    local result = { fns[n](...) }
    for i = n - 1, 1, -1 do
      result = { fns[i](unpack(result)) }
    end
    return unpack(result)
  end
end

-- pipe(f, g, ...) -> left-to-right composition. pipe(f,g)(x) = g(f(x))
function M.pipe(...)
  local fns = { ... } --: { [integer]: function }
  local n = #fns
  if n == 0 then return M.identity end
  if n == 1 then return fns[1] end
  return function(...)
    local result = { fns[1](...) }
    for i = 2, n do
      result = { fns[i](unpack(result)) }
    end
    return unpack(result)
  end
end

-- memoize(fn) -> memoized fn (keyed by first argument).
function M.memoize(fn)
  local cache = {}
  local MISS = {}
  return function(k)
    local v = cache[k]
    if v == nil then
      v = fn(k)
      cache[k] = v == nil and MISS or v
    elseif v == MISS then
      return nil
    end
    return cache[k] ~= MISS and cache[k] or nil
  end
end

-- once(fn) -> fn that runs at most once; subsequent calls return cached result.
function M.once(fn)
  local called = false
  local result
  return function(...)
    if not called then
      called = true
      result = fn(...)
    end
    return result
  end
end

-- partial(fn, ...) -> fn with leading arguments bound.
function M.partial(fn, ...)
  local bound = { ... }
  local nbound = select("#", ...)
  return function(...)
    local args = {}
    for i = 1, nbound do args[i] = bound[i] end
    local extra = select("#", ...)
    for i = 1, extra do args[nbound + i] = select(i, ...) end
    return fn(unpack(args --[[:! { [integer]: any }]], 1, nbound + extra))
  end
end

-- curry(fn, n) -> curried fn accepting n arguments one at a time.
--: (function, integer | nil) -> function
function M.curry(fn, n)
  if n == nil then
    local info = debug.getinfo(fn, "u")
    n = (info and info.nparams or 0) --[[:! integer]]
  end
  if n <= 1 then return fn end
  --: ({ [integer]: unknown }, integer) -> function
  local function step(collected, remaining)
    return function(...)
      local args = {} --: { [integer]: unknown }
      for i = 1, #collected do args[i] = collected[i] end
      local added = select("#", ...)
      for i = 1, added do args[#collected + i] = select(i, ...) end
      local new_remaining = remaining - added
      if new_remaining <= 0 then
        return fn(unpack(args --[[:! { [integer]: any }]]))
      else
        return step(args, new_remaining)
      end
    end
  end
  return step({}, n)
end

-- flip(fn) -> fn with first two arguments swapped.
function M.flip(fn)
  return function(a, b, ...)
    return fn(b, a, ...)
  end
end

-- negate(fn) -> predicate that returns boolean negation of fn.
function M.negate(fn)
  return function(...)
    return not fn(...)
  end
end

-- juxt(f, g, ...) -> fn that applies each function to the same args.
-- Returns a table of results: {f(x), g(x), h(x)}.
function M.juxt(...)
  local fns = { ... } --: { [integer]: function }
  local n = #fns
  return function(...)
    local results = {}
    for i = 1, n do results[i] = fns[i](...) end
    return results
  end
end

-- apply(fn, args) -> fn called with args array as arguments.
function M.apply(fn, args)
  return fn(unpack(args))
end

-- tap(fn) -> returns a fn that calls fn(x) for side effects then returns x.
function M.tap(fn)
  return function(x)
    fn(x)
    return x
  end
end

-- ---------------------------------------------------------------------------
-- Transducers
-- ---------------------------------------------------------------------------
-- A transducer is a function: reducer -> reducer.
-- A reducer is a function: (acc, val) -> acc.
-- transduce composes transducers left-to-right (same direction as pipe).

-- transduce(xf, reducer, init, coll) -> apply transducer xf to collection.
function M.transduce(xf, reducer, init, coll)
  local xr = xf(reducer)
  local acc = init
  for i = 1, #coll do acc = xr(acc, coll[i]) end
  return acc
end

-- map_xf(fn) -> mapping transducer.
function M.map_xf(fn)
  return function(reducer)
    return function(acc, val)
      return reducer(acc, fn(val))
    end
  end
end

-- filter_xf(fn) -> filtering transducer.
function M.filter_xf(fn)
  return function(reducer)
    return function(acc, val)
      if fn(val) then return reducer(acc, val) end
      return acc
    end
  end
end

-- take_xf(n) -> taking transducer (takes first n elements).
function M.take_xf(n)
  return function(reducer)
    local count = 0
    return function(acc, val)
      if count >= n then return acc end
      count = count + 1
      return reducer(acc, val)
    end
  end
end

-- comp_xf(...) -> compose transducers left-to-right.
-- comp_xf(map_xf(f), filter_xf(g)) applies map then filter.
function M.comp_xf(...)
  local xfs = { ... } --: { [integer]: function }
  local n = #xfs
  if n == 0 then return M.identity end
  if n == 1 then return xfs[1] end
  return function(reducer)
    local r = reducer --: unknown
    for i = n, 1, -1 do r = xfs[i](r) end
    return r
  end
end

-- ---------------------------------------------------------------------------
-- Iteration helpers
-- ---------------------------------------------------------------------------

-- range(n) or range(start, stop) or range(start, stop, step).
function M.range(a, b, step)
  local start, stop
  if b == nil then
    start, stop = 1, a
  else
    start, stop = a, b
  end
  step = step or 1
  local out = {}
  local j = 0
  local i = start
  while (step > 0 and i <= stop) or (step < 0 and i >= stop) do
    j = j + 1
    out[j] = i
    i = i + step
  end
  return out
end

-- repeat_val(val, n) -> array of n copies of val.
function M.repeat_val(val, n)
  local out = {}
  for i = 1, n do out[i] = val end
  return out
end

-- iterate(fn, seed, n) -> {seed, fn(seed), fn(fn(seed)), ...} n+1 values.
function M.iterate(fn, seed, n)
  local out = {}
  out[1] = seed
  local v = seed
  for i = 2, n + 1 do
    v = fn(v)
    out[i] = v
  end
  return out
end

-- cycle(t, n) -> repeat elements of t for n total items.
function M.cycle(t, n)
  local len = #t
  if len == 0 then return {} end
  local out = {}
  for i = 1, n do
    out[i] = t[((i - 1) % len) + 1]
  end
  return out
end

return M
