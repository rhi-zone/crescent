-- lib/fp/min/init.lua
-- Min(n): Semigroup + Monoid instance that returns the minimum on append.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Semigroup = require("lib.fp.semigroup")
local Monoid    = require("lib.fp.monoid")

local Min  -- forward declaration

local sg_impl = {
	--: (a: { value: number, ... }, b: { value: number, ... }) -> { value: number, ... }
	append = function(a, b)
		return Min(a.value <= b.value and a.value or b.value)
	end,
}

local m_impl = {
	empty = function() return Min(math.huge) end,
}

local mt = {
	__index = { [Semigroup.key] = sg_impl, [Monoid.key] = m_impl },
	__tostring = function(self)
		return "Min(" .. tostring(self.value) .. ")"
	end,
}

Min = function(n)
	return setmetatable({ value = n }, mt)
end

return Min
