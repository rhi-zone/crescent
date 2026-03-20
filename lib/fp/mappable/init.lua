-- lib/fp/mappable/init.lua
-- Mappable typeclass: map :: (a -> b) -> f a -> f b

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Mappable = {}

-- map: apply f to the value(s) inside fa
function Mappable.map(f, fa)
	return fa[Mappable].map(f, fa)
end

return Mappable
