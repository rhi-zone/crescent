-- lib/fp/applicative/init.lua
-- Applicative typeclass: pure :: a -> f a
-- Extends Apply.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Applicative = {}

-- pure: lift a plain value into the applicative functor.
-- constructor is an example value used to dispatch to the right instance.
function Applicative.pure(constructor, a)
	return constructor[Applicative].pure(a)
end

return Applicative
