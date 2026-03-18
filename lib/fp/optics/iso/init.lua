-- lib/fp/optics/iso/init.lua
-- Iso s a — isomorphism (bijection) between s and a.
-- Concrete representation: { get: s->a, review: a->s }

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Iso = {}

-- Iso.new(get, review) -> Iso s a
-- get    : s -> a   (forward direction)
-- review : a -> s   (backward direction)
function Iso.new(get, review)
	return { get = get, review = review }
end

-- Iso.get(iso, s) -> a
function Iso.get(iso, s)
	return iso.get(s)
end

-- Iso.review(iso, a) -> s
function Iso.review(iso, a)
	return iso.review(a)
end

-- Iso.flip(iso) -> Iso a s
-- Swap the two directions.
function Iso.flip(iso)
	return Iso.new(iso.review, iso.get)
end

-- Iso.compose(iso1, iso2) -> Iso s c
-- Given Iso s a and Iso a c, produce Iso s c.
function Iso.compose(iso1, iso2)
	return Iso.new(
		function(s) return iso2.get(iso1.get(s)) end,
		function(c) return iso1.review(iso2.review(c)) end
	)
end

-- Iso.to_lens(iso) -> Lens s a
-- An Iso is a special Lens where set reconstructs via review.
-- Returns a plain { get, set } table compatible with lib/fp/optics/lens.
function Iso.to_lens(iso)
	return {
		get = iso.get,
		set = function(s, a)
			-- The set direction of an Iso ignores s (it's an iso, not just a lens):
			-- the new value fully determines the result via review.
			-- This matches the Haskell Law: set l (get l s) s == s
			-- For an Iso, review(a) discards the original s entirely.
			return iso.review(a)
		end,
	}
end

return Iso
