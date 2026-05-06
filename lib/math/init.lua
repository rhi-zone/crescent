if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--: (unknown) -> integer | nil
M.tointeger = function(x)
  local n = tonumber(x)
  if n == nil then return nil end
  local i = math.floor(n)
  if i == n then return i end
  return nil
end

return M
