-- lib/fp/last/init.lua
-- Last(a): Semigroup instance that returns the right argument on append.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Semigroup = require("lib.fp.semigroup")

local impl = {
	append = function(a, b) return b end,
}

local mt = {
	__index = { [Semigroup] = impl },
	__tostring = function(self)
		return "Last(" .. tostring(self.value) .. ")"
	end,
}

local function Last(a)
	return setmetatable({ value = a }, mt)
end

return Last
