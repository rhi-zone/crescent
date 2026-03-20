-- lib/fp/product/init.lua
-- Product(n): Semigroup + Monoid instance that multiplies numbers on append.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Semigroup = require("lib.fp.semigroup")
local Monoid    = require("lib.fp.monoid")

local Product  -- forward declaration

local sg_impl = {
	append = function(a, b) return Product(a.value * b.value) end,
}

local m_impl = {
	empty = function() return Product(1) end,
}

local mt = {
	__index = { [Semigroup] = sg_impl, [Monoid] = m_impl },
	__tostring = function(self)
		return "Product(" .. tostring(self.value) .. ")"
	end,
}

Product = function(n)
	return setmetatable({ value = n }, mt)
end

return Product
