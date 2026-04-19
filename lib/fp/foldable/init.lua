-- lib/fp/foldable/init.lua
-- Foldable typeclass: fold, foldMap, foldr

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

--:: FoldableKey = $Opaque

local Foldable = {}

-- A fresh table used purely as an identity token for dispatch.
Foldable.key = {} --: FoldableKey

-- foldr :: (a -> b -> b) -> b -> t a -> b
-- right-fold over the structure
function Foldable.foldr(f, z, ta)
	return ta[Foldable.key].foldr(f, z, ta)
end

-- foldMap :: Monoid m => (a -> m) -> t a -> m
-- map each element to a Monoid value, then combine
-- Note: foldMap on Nothing errors because there is no Monoid instance to
-- dispatch empty() on without an element. Pass Just(x) when the Monoid
-- instance is needed.
function Foldable.foldMap(f, ta)
	return ta[Foldable.key].foldMap(f, ta)
end

-- fold :: Monoid m => t m -> m
-- elements must already be Monoid values
-- Note: fold on Nothing errors for the same reason as foldMap — no instance
-- to dispatch empty() on without an element.
function Foldable.fold(ta)
	return ta[Foldable.key].fold(ta)
end

return Foldable
