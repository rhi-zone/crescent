-- lib/fp/mappable/init.lua
-- Mappable typeclass: map :: (a -> b) -> f a -> f b

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

--:: MappableKey = $Opaque

local Mappable = {}

-- The module itself is the dispatch key.
-- MappableKey gives it a named opaque type for the typechecker.
Mappable.key = Mappable

-- map: apply f to the value(s) inside fa
function Mappable.map(f, fa)
	return fa[Mappable.key].map(f, fa)
end

return Mappable
