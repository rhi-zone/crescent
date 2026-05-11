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
		local char_ = char --[[:! string]]
		local code = (string.byte(char_, 1) or 0) --[[:! integer]]
		local hi = math.floor(code / 16) --[[:! integer]]
		return "%" .. hex_alphabet[hi + 1] .. hex_alphabet[code % 16 + 1]
	end)
	return (out --[[: unknown]]) --[[:! string]]
end

--[[converts from urlencode to string]]
--: (string) -> string
mod.urlencode_to_string = function (urlencoded)
	-- TODO: error if invalid
	local out2 = urlencoded:gsub("%%([0-9a-fA-F][0-9a-fA-F])", function (code) return string.char(math2.tointeger(tonumber(code, 16)) or 0) end)
	return (out2 --[[: unknown]]) --[[:! string]]
end

return mod
