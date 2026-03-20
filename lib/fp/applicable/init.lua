-- lib/fp/applicable/init.lua
-- Applicable typeclass: ap + pure
--   ap   :: f (a -> b) -> f a -> f b
--   pure :: a -> f a
-- Merges Apply and Applicative. Extends Mappable.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Applicable = {}

-- ap: apply a wrapped function to a wrapped value
function Applicable.ap(ff, fa)
	return ff[Applicable].ap(ff, fa)
end

-- pure: lift a plain value into the applicable functor.
-- constructor is an example value used to dispatch to the right instance.
function Applicable.pure(constructor, a)
	return constructor[Applicable].pure(a)
end

return Applicable
