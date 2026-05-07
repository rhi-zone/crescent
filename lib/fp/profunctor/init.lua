-- lib/fp/profunctor/init.lua
-- Profunctor typeclass: dimap :: (a -> b) -> (c -> d) -> f b c -> f a d
--
-- A Profunctor is contravariant in its first type parameter and covariant in
-- its second. dimap pre-maps the input with f and post-maps the output with g.
-- lmap and rmap are derived from dimap using the identity function.
--
-- Instances:
--   Fn: dimap(f, g, Fn(h)) = Fn(function(...) return g(h(f(...))) end)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

--:: ProfunctorKey = $Opaque

local Profunctor = {}

-- A fresh table used purely as an identity token for dispatch.
Profunctor.key = ({} --[[: any]]) --[[:! ProfunctorKey]]

local function id(x) return x end

-- dimap: contramap input with f, map output with g
function Profunctor.dimap(f, g, fbc)
	return fbc[Profunctor.key].dimap(f, g, fbc)
end

-- lmap: contramap input only (dimap(f, id, fbc))
function Profunctor.lmap(f, fbc)
	return fbc[Profunctor.key].dimap(f, id, fbc)
end

-- rmap: map output only (dimap(id, g, fbc))
function Profunctor.rmap(g, fbc)
	return fbc[Profunctor.key].dimap(id, g, fbc)
end

return Profunctor
