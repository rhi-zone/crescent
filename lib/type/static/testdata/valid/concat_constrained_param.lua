-- Params used in concatenation are constrained via #__concat.
local function greet(name)
  return "Hello, " .. name
end

local function join(a, b, sep)
  return a .. sep .. b
end
