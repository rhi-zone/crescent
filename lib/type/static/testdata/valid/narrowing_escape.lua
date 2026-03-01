-- Narrowing-escape: assigning a value that's valid for the declared type
-- but not the narrowed type should be accepted.

local x --: string | integer
x = "hello"
if type(x) == "string" then
  x = 42  -- integer is valid for string | integer even though x is narrowed to string here
end

-- Union with nil: reassigning inside truthy check
local y = nil
y = "hello"  -- y: string | nil
if y then    -- narrowed to string
  y = nil    -- nil is valid for string | nil
end
