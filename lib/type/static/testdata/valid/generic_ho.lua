-- Higher-order function: return type flows from callback at each call site.
local function apply(fn, x)
  return fn(x)
end

local y = apply(function(n) return n + 1 end, 10)
local z = apply(function(s) return s .. "!" end, "hello")
