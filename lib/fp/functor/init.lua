-- lib/fp/functor/init.lua
-- Functor typeclass: map :: (a -> b) -> f a -> f b

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Functor = {}

-- map: apply f to the value(s) inside fa
function Functor.map(f, fa)
	return fa[Functor].map(f, fa)
end

return Functor
