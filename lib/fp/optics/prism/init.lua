-- lib/fp/optics/prism/init.lua
-- Prism s a — focus on a constructor branch (zero or one target).
-- Concrete representation: { preview: s->Maybe a, review: a->s }

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Maybe  = require("lib.fp.maybe")
local Either = require("lib.fp.either")

local Prism = {}

-- Prism.new(preview, review) -> Prism s a
-- preview : s -> Maybe a   (extract if present)
-- review  : a -> s         (construct)
function Prism.new(preview, review)
	return { preview = preview, review = review }
end

-- Prism.preview(prism, s) -> Maybe a
function Prism.preview(prism, s)
	return prism.preview(s)
end

-- Prism.review(prism, a) -> s
function Prism.review(prism, a)
	return prism.review(a)
end

-- Prism.matching(prism, s) -> Either s a
-- Left s  if the prism does not match (miss)
-- Right a if the prism matches (hit)
function Prism.matching(prism, s)
	local m = prism.preview(s)
	if Maybe.is_nothing(m) then
		return Either.left(s)
	else
		return Either.right(m.value)
	end
end

-- Prism.over(prism, s, f) -> s
-- Apply f to the focus if present; return s unchanged on miss.
function Prism.over(prism, s, f)
	local m = prism.preview(s)
	if Maybe.is_nothing(m) then
		return s
	else
		return prism.review(f(m.value))
	end
end

-- Prism.compose(prism1, prism2) -> Prism s c
-- Given Prism s a and Prism a c, produce Prism s c.
function Prism.compose(prism1, prism2)
	return Prism.new(
		function(s)
			local ma = prism1.preview(s)
			if Maybe.is_nothing(ma) then
				return Maybe.nothing
			end
			return prism2.preview(ma.value)
		end,
		function(c)
			return prism1.review(prism2.review(c))
		end
	)
end

return Prism
