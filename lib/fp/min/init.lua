-- lib/fp/min/init.lua
-- Min(n): Semigroup instance that returns the minimum on append.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Semigroup = require("lib.fp.semigroup")

local Min  -- forward declaration

local impl = {
	append = function(a, b)
		return Min(a.value <= b.value and a.value or b.value)
	end,
}

local mt = {
	__index = { [Semigroup] = impl },
	__tostring = function(self)
		return "Min(" .. tostring(self.value) .. ")"
	end,
}

Min = function(n)
	return setmetatable({ value = n }, mt)
end

return Min
