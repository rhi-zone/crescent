-- lib/fp/semigroup/init.lua
-- Semigroup typeclass: append :: a -> a -> a

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Semigroup = {}

-- append: combine two semigroup values
function Semigroup.append(a, b)
	return a[Semigroup].append(a, b)
end

return Semigroup
