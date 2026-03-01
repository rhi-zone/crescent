-- Type mismatch nested inside a struct (exercises path + annotated-tree format).
--:: Address = { street: string, zip: number }
--:: User = { name: string, address: Address }

--: (User) -> string
local function format_user(u)
  return u.name
end

format_user({ name = "alice", address = { street = "Main St", zip = "90210" } })
