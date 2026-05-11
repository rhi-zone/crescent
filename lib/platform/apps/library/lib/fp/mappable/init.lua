-- lib/fp/mappable/init.lua
-- Mappable typeclass: map :: (a -> b) -> f a -> f b

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

--:: MappableKey = $Opaque

local Mappable = {}

-- A fresh table used purely as an identity token for dispatch.
Mappable.key = ({} --[[: unknown]]) --[[:! MappableKey]]

-- map: apply f to the value(s) inside fa
function Mappable.map(f, fa)
	return fa[Mappable.key].map(f, fa)
end

return Mappable
