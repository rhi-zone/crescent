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

--:: PrismT = { preview: (unknown) -> unknown, review: (unknown) -> unknown }

-- Prism.preview(prism, s) -> Maybe a
function Prism.preview(prism, s)
	local p_ = prism --[[:! PrismT]]
	return p_.preview(s)
end

-- Prism.review(prism, a) -> s
function Prism.review(prism, a)
	local p_ = prism --[[:! PrismT]]
	return p_.review(a)
end

-- Prism.matching(prism, s) -> Either s a
-- Left s  if the prism does not match (miss)
-- Right a if the prism matches (hit)
function Prism.matching(prism, s)
	local p_ = prism --[[:! PrismT]]
	local m = p_.preview(s)
	if Maybe.is_nothing(m) then
		return Either.left(s)
	else
		local m_ = m --[[:! { value: unknown }]]
		local val_ = m_.value --[[:! { ... }]]
		return Either.right(val_)
	end
end

-- Prism.over(prism, s, f) -> s
-- Apply f to the focus if present; return s unchanged on miss.
function Prism.over(prism, s, f)
	local p_ = prism --[[:! PrismT]]
	local m = p_.preview(s)
	if Maybe.is_nothing(m) then
		return s
	else
		local m_ = m --[[:! { value: unknown }]]
		return p_.review(f(m_.value))
	end
end

-- Prism.compose(prism1, prism2) -> Prism s c
-- Given Prism s a and Prism a c, produce Prism s c.
function Prism.compose(prism1, prism2)
	local p1 = prism1 --[[:! PrismT]]
	local p2 = prism2 --[[:! PrismT]]
	return Prism.new(
		function(s)
			local ma = p1.preview(s)
			if Maybe.is_nothing(ma) then
				return Maybe.nothing
			end
			local ma_ = ma --[[:! { value: unknown }]]
			return p2.preview(ma_.value)
		end,
		function(c)
			return p1.review(p2.review(c))
		end
	)
end

return Prism
