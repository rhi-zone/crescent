-- Passing a record that is missing a required field.
--: ({ name: string, role: string }) -> string
local function greet(user)
  return "Hello, " .. user.name
end

greet({ name = "alice" })
