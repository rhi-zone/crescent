-- Type mismatch through an optional (T | nil) field — union in the middle of the path.
--:: Address = { street: string, zip: number }
--:: User = { name: string, address: Address | nil }

--: (User) -> string
local function format_user(u)
  return u.name
end

format_user({ name = "alice", address = { street = "Main St", zip = "90210" } })
