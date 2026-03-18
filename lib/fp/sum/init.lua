-- lib/fp/sum/init.lua
-- Sum(n): Semigroup instance that adds numbers on append.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Semigroup = require("lib.fp.semigroup")

local Sum  -- forward declaration

local impl = {
	append = function(a, b) return Sum(a.value + b.value) end,
}

local mt = {
	__index = { [Semigroup] = impl },
	__tostring = function(self)
		return "Sum(" .. tostring(self.value) .. ")"
	end,
}

Sum = function(n)
	return setmetatable({ value = n }, mt)
end

return Sum
