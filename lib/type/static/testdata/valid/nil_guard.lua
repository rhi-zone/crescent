-- A nil guard should suppress the nil method call error.
local x
if x then
  local result = x:match("pattern")  -- ok: narrowing clears nil_vars for x
end
