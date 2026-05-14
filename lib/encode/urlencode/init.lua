if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local math2 = require("lib.math")

local mod = {}

local hex_alphabet = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f" } --: { [integer]: string }

--[[converts from string to urlencode]]
--: (string) -> string
mod.string_to_urlencode = function (str)
	-- FIXME
	local out = str:gsub("[^%w-._~:%[%]@!$'%(%)*+,;=]", function (char)
		local code = (string.byte(char, 1) or 0)
		local hi = math.floor(code / 16)
		return "%" .. hex_alphabet[hi + 1] .. hex_alphabet[code % 16 + 1]
	end)
	return out
end

--[[converts from urlencode to string]]
--: (string) -> string
mod.urlencode_to_string = function (urlencoded)
	-- TODO: error if invalid
	local out2 = urlencoded:gsub("%%([0-9a-fA-F][0-9a-fA-F])", function (code) return string.char(math2.tointeger(tonumber(code, 16)) or 0) end)
	-- The force cast pins the boundary type. Removing it surfaces a latent
	-- typechecker limitation: gsub's repl-callback parameter type does not
	-- flow from the function-type annotation onto the inline callback, so
	-- `tonumber(code, 16)` is checked with `code` as `unknown` and the
	-- chained return degrades to `number | nil`. Fixing that requires
	-- typechecker work (parameter-type flow into inline function literals)
	-- outside the scope of this directory.
	return (out2 --[[: unknown]]) --[[:! string]]
end

return mod
