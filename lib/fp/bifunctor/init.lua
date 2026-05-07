-- lib/fp/bifunctor/init.lua
-- Bifunctor typeclass: bimap :: (a -> c) -> (b -> d) -> f a b -> f c d
--
-- A Bifunctor can map over both type parameters simultaneously.
-- lmap and rmap are derived from bimap using the identity function.
--
-- Instances:
--   Either: bimap(f, g, Left(e))  = Left(f(e))
--           bimap(f, g, Right(a)) = Right(g(a))

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

--:: BifunctorKey = $Opaque

local Bifunctor = {}

-- A fresh table used purely as an identity token for dispatch.
Bifunctor.key = ({} --[[: any]]) --[[:! BifunctorKey]]

local function id(x) return x end

-- bimap: map f over the first type parameter, g over the second
function Bifunctor.bimap(f, g, fab)
	return fab[Bifunctor.key].bimap(f, g, fab)
end

-- lmap: map over the first type parameter only (bimap(f, id, fab))
function Bifunctor.lmap(f, fab)
	return fab[Bifunctor.key].bimap(f, id, fab)
end

-- rmap: map over the second type parameter only (bimap(id, g, fab))
function Bifunctor.rmap(g, fab)
	return fab[Bifunctor.key].bimap(id, g, fab)
end

return Bifunctor
