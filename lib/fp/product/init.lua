-- lib/fp/product/init.lua
-- Product(n): Semigroup instance that multiplies numbers on append.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Semigroup = require("lib.fp.semigroup")

local Product  -- forward declaration

local impl = {
	append = function(a, b) return Product(a.value * b.value) end,
}

local mt = {
	__index = { [Semigroup] = impl },
	__tostring = function(self)
		return "Product(" .. tostring(self.value) .. ")"
	end,
}

Product = function(n)
	return setmetatable({ value = n }, mt)
end

return Product
