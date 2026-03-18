-- lib/fp/max/init.lua
-- Max(n): Semigroup instance that returns the maximum on append.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Semigroup = require("lib.fp.semigroup")

local Max  -- forward declaration

local impl = {
	append = function(a, b)
		return Max(a.value >= b.value and a.value or b.value)
	end,
}

local mt = {
	__index = { [Semigroup] = impl },
	__tostring = function(self)
		return "Max(" .. tostring(self.value) .. ")"
	end,
}

Max = function(n)
	return setmetatable({ value = n }, mt)
end

return Max
