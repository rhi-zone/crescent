-- lib/fp/alt/init.lua
-- Alt typeclass: alt :: f a -> f a -> f a
--
-- Alt extends Mappable. The key operation is a choice/fallback combinator:
-- alt(fa, fb) returns fa if it is "successful", otherwise fb.
--
-- Instances:
--   Maybe: alt(Just(a), _) = Just(a)   alt(Nothing, fb) = fb
--   Either: alt(Right(a), _) = Right(a)  alt(Left(_), fb) = fb  (right-biased)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

--:: AltKey = $Opaque

local Alt = {}

-- The module itself is the dispatch key.
Alt.key = Alt

-- alt: choose fa if available, otherwise fall back to fb
function Alt.alt(fa, fb)
	return fa[Alt.key].alt(fa, fb)
end

return Alt
