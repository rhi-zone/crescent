-- lib/fp/first/init.lua
-- First(a): Semigroup instance that returns the left argument on append.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Semigroup = require("lib.fp.semigroup")

local impl = {
	append = function(a, b) return a end,
}

local mt = {
	__index = { [Semigroup] = impl },
	__tostring = function(self)
		return "First(" .. tostring(self.value) .. ")"
	end,
}

local function First(a)
	return setmetatable({ value = a }, mt)
end

return First
