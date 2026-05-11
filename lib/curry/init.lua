if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- Function composition, currying, and partial application.

local M = {}
M._tier = "pure"

-- arity(fn) -> number of declared parameters via debug.getinfo.
function M.arity(fn)
  local info = debug.getinfo(fn, "u")
  return info and info.nparams or 0
end

-- curry(fn, arity?) -> curried fn.
-- Converts fn(a,b,...) into fn(a)(b)(...).
-- Auto-detects arity from debug.getinfo when not supplied.
function M.curry(fn, n)
  if n == nil then n = M.arity(fn) end
  local n_ = n --[[:! integer]]
  if n_ <= 1 then return fn end
  local function step(collected, remaining)
    local remaining_ = remaining --[[:! integer]]
    return function(...)
      local args = {}
      for i = 1, #collected do args[i] = collected[i] end
      local added = select("#", ...) --[[:! integer]]
      for i = 1, added do args[#collected + i] = (select(i, ...) --[[:! nil]]) end
      local new_remaining = remaining_ - added
      if new_remaining <= 0 then
        local fn_ = fn --[[:! (...unknown) -> unknown]]
        return fn_(unpack(--[[:! { [integer]: unknown }]] args))
      else
        return step(args, new_remaining)
      end
    end
  end
  return step({}, n_)
end

-- partial(fn, ...) -> fn with leading args bound.
function M.partial(fn, ...)
  local bound = { ... }
  local nbound = select("#", ...)
  return function(...)
    local args = {}
    for i = 1, nbound do args[i] = bound[i] end
    local extra = select("#", ...)
    for i = 1, extra do args[nbound + i] = select(i, ...) end
    return fn(unpack(--[[:! { [integer]: unknown }]] args, 1, nbound + extra))
  end
end

-- compose(f, g, ...) -> right-to-left composition.
-- compose(f, g)(x) = f(g(x))
function M.compose(...)
  --: { [integer]: (...unknown) -> unknown }
  local fns = { ... }
  local n = #fns
  if n == 0 then return M.identity end
  if n == 1 then return fns[1] end
  return function(...)
    local result = { fns[n](...) }
    for i = n - 1, 1, -1 do
      result = { fns[i](unpack(--[[:! { [integer]: unknown }]] result)) }
    end
    return unpack(--[[:! { [integer]: unknown }]] result)
  end
end

-- pipe(f, g, ...) -> left-to-right composition.
-- pipe(f, g)(x) = g(f(x))
function M.pipe(...)
  --: { [integer]: (...unknown) -> unknown }
  local fns = { ... }
  local n = #fns
  if n == 0 then return M.identity end
  if n == 1 then return fns[1] end
  return function(...)
    local result = { fns[1](...) }
    for i = 2, n do
      result = { fns[i](unpack(--[[:! { [integer]: unknown }]] result)) }
    end
    return unpack(--[[:! { [integer]: unknown }]] result)
  end
end

-- memoize(fn) -> memoized fn (simple table cache, single arg key).
function M.memoize(fn)
  local cache = {}
  local MISS = {}  -- sentinel for cached nil
  return function(k)
    local v = cache[k]
    if v == nil then
      v = fn(k)
      if v == nil then
        cache[k] = MISS
      else
        cache[k] = v
      end
    elseif v == MISS then
      return nil
    end
    return cache[k] ~= MISS and cache[k] or nil
  end
end

-- flip(fn) -> fn with first two args swapped.
function M.flip(fn)
  return function(a, b, ...)
    return fn(b, a, ...)
  end
end

-- identity(x) -> x
function M.identity(x)
  return x
end

-- const(x) -> function that always returns x regardless of args.
function M.const(x)
  return function()
    return x
  end
end

-- once(fn) -> fn that runs exactly once; subsequent calls return cached result.
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

-- juxt(f, g, ...) -> fn that applies each function to the same args
-- and returns a table of all results.
function M.juxt(...)
  --: { [integer]: (...unknown) -> unknown }
  local fns = { ... }
  local n = #fns
  return function(...)
    local results = {}
    for i = 1, n do
      results[i] = fns[i](...)
    end
    return results
  end
end

-- apply(fn, arr) -> fn called with arr elements as arguments.
function M.apply(fn, arr)
  return fn(unpack(arr))
end

-- complement(pred) -> predicate that returns the boolean negation.
function M.complement(pred)
  return function(...)
    return not pred(...)
  end
end

-- thread(val, f1, f2, ...) -> pipes val through each function in order.
-- Equivalent to pipe(f1, f2, ...)(val).
function M.thread(val, ...)
  --: { [integer]: (unknown) -> unknown }
  local fns = { ... }
  local result = val
  for i = 1, #fns do
    result = fns[i](result)
  end
  return result
end

-- unary(fn) -> wrapper that accepts only 1 argument.
function M.unary(fn)
  return function(a)
    return fn(a)
  end
end

-- binary(fn) -> wrapper that accepts only 2 arguments.
function M.binary(fn)
  return function(a, b)
    return fn(a, b)
  end
end

-- spread(fn) -> fn that takes a single array and spreads it as args.
function M.spread(fn)
  return function(arr)
    return fn(unpack(arr))
  end
end

return M
