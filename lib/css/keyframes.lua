if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Construct a @keyframes rule.
-- name: AnimationName (a string, e.g. "slide-in")
-- stops: table with string keys ("from", "to", "0%", "50%", etc.) mapping to decl tables
--: (name: string, stops: { [string]: { [string]: string } }) -> { _type: string, name: string, stops: { [string]: { [string]: string } } }
function M.keyframes(name, stops)
  return { _type = "keyframes", name = name, stops = stops }
end

return M
