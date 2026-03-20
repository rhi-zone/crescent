-- lib/fp/sum/init.lua
-- Sum(n): Semigroup + Monoid instance that adds numbers on append.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Semigroup = require("lib.fp.semigroup")
local Monoid    = require("lib.fp.monoid")

local Sum  -- forward declaration

local sg_impl = {
	append = function(a, b) return Sum(a.value + b.value) end,
}

local m_impl = {
	empty = function() return Sum(0) end,
}

local mt = {
	__index = { [Semigroup] = sg_impl, [Monoid] = m_impl },
	__tostring = function(self)
		return "Sum(" .. tostring(self.value) .. ")"
	end,
}

Sum = function(n)
	return setmetatable({ value = n }, mt)
end

return Sum
