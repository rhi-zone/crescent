-- Params used in arithmetic are constrained via #__add / #__sub / etc.
-- They are no longer unbound vars after inference, so no implicit-any warning.
local function add(a, b)
  return a + b
end

local function scale(x, factor)
  return x * factor
end

local function factorial(n)
  if n <= 0 then return 1 end
  return n * factorial(n - 1)
end
