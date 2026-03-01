-- Params with explicit annotations are not warned about.
--: (number, number) -> number
local function add(a, b)
  return a + b
end

--: (string) -> string
local function greet(name)
  return "Hello, " .. name
end
