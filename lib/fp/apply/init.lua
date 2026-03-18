-- lib/fp/apply/init.lua
-- Apply typeclass: ap :: f (a -> b) -> f a -> f b
-- Extends Functor.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Apply = {}

-- ap: apply a wrapped function to a wrapped value
function Apply.ap(ff, fa)
	return ff[Apply].ap(ff, fa)
end

return Apply
