-- lib/fp/monoid/init.lua
-- Monoid typeclass: extends Semigroup with empty :: () -> a

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Semigroup = require("lib.fp.semigroup")

--:: MonoidKey = $Opaque

local Monoid = {}

-- A fresh table used purely as an identity token for dispatch.
Monoid.key = ({} --[[: any]]) --[[:! MonoidKey]]

-- empty: return the identity element for the monoid instance of `a`
function Monoid.empty(a)
	return a[Monoid.key].empty()
end

-- fold: combine all elements of a non-empty list using the Monoid instance
-- dispatches via the first element; starts from empty and appends each value
function Monoid.fold(list)
	assert(#list > 0, "Monoid.fold: empty list (no instance to dispatch on)")
	local impl = list[1][Monoid.key]
	local acc = impl.empty()
	for _, v in ipairs(list) do
		acc = Semigroup.append(acc, v)
	end
	return acc
end

return Monoid
