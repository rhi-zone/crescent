-- lib/fp/traversable/init.lua
-- Traversable typeclass: traverse + sequence
--   traverse :: Applicable f => (a -> f b) -> t a -> f (t b)
--   sequence :: Applicable f => t (f a) -> f (t a)
-- Extends Foldable.
--
-- Because Lua has no implicit typeclass resolution, traverse takes an explicit
-- applicative constructor (ctor) as a third argument. ctor must be a value
-- whose [Applicable] instance is the one to use for reconstruction — e.g.
-- Maybe.nothing or Maybe.just(x).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Applicable = require("lib.fp.applicable")

--:: TraversableKey = $Opaque

local Traversable = {}

-- The module itself is the dispatch key.
Traversable.key = Traversable

-- traverse :: Applicable f => (a -> f b) -> t a -> f (t b)
-- Dispatches to ta[Traversable.key].traverse(f, ta, ctor).
function Traversable.traverse(f, ta, ctor)
	return ta[Traversable.key].traverse(f, ta, ctor)
end

-- sequence :: Applicable f => t (f a) -> f (t a)
-- sequence(tfa, ctor) = traverse(id, tfa, ctor)
function Traversable.sequence(tfa, ctor)
	return Traversable.traverse(function(x) return x end, tfa, ctor)
end

return Traversable
