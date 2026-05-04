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

--:: IsoT = { get: (unknown) -> unknown, review: (unknown) -> unknown }

-- Iso.get(iso, s) -> a
function Iso.get(iso, s)
	local iso_ = iso --[[:! IsoT]]
	return iso_.get(s)
end

-- Iso.review(iso, a) -> s
function Iso.review(iso, a)
	local iso_ = iso --[[:! IsoT]]
	return iso_.review(a)
end

-- Iso.flip(iso) -> Iso a s
-- Swap the two directions.
function Iso.flip(iso)
	local iso_ = iso --[[:! IsoT]]
	return Iso.new(iso_.review, iso_.get)
end

-- Iso.compose(iso1, iso2) -> Iso s c
-- Given Iso s a and Iso a c, produce Iso s c.
function Iso.compose(iso1, iso2)
	local i1 = iso1 --[[:! IsoT]]
	local i2 = iso2 --[[:! IsoT]]
	return Iso.new(
		function(s) return i2.get(i1.get(s)) end,
		function(c) return i1.review(i2.review(c)) end
	)
end

-- Iso.to_lens(iso) -> Lens s a
-- An Iso is a special Lens where set reconstructs via review.
-- Returns a plain { get, set } table compatible with lib/fp/optics/lens.
function Iso.to_lens(iso)
	local iso_ = iso --[[:! IsoT]]
	return {
		get = iso_.get,
		set = function(_s, a)
			-- The set direction of an Iso ignores s (it's an iso, not just a lens):
			-- the new value fully determines the result via review.
			-- This matches the Haskell Law: set l (get l s) s == s
			-- For an Iso, review(a) discards the original s entirely.
			return iso_.review(a)
		end,
	}
end

return Iso
