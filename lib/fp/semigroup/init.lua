-- lib/fp/semigroup/init.lua
-- Semigroup typeclass: append :: a -> a -> a

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

--:: SemigroupKey = $Opaque

local Semigroup = {}

-- A fresh table used purely as an identity token for dispatch.
Semigroup.key = {} --: SemigroupKey

-- append: combine two semigroup values
function Semigroup.append(a, b)
	return a[Semigroup.key].append(a, b)
end

return Semigroup
