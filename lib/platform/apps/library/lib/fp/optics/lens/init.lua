-- lib/fp/optics/lens/init.lua
-- Lens s a — focus on a single field of s.
-- Concrete representation: { get: s->a, set: s->a->s }

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Lens = {}

-- Lens.new(get, set) -> Lens s a
-- get : s -> a
-- set : s -> a -> s   (returns modified copy of s)
function Lens.new(get, set)
	return { get = get, set = set }
end

--:: LensT = { get: (unknown) -> unknown, set: (unknown, unknown) -> unknown }

-- Lens.get(lens, s) -> a
function Lens.get(lens, s)
	--: LensT
	local lens_ = lens --[[:! LensT]]
	return lens_.get(s)
end

-- Lens.set(lens, s, a) -> s
function Lens.set(lens, s, a)
	local lens_ = lens --[[:! LensT]]
	return lens_.set(s, a)
end

-- Lens.over(lens, s, f) -> s
-- Modify the focus in-place with f.
function Lens.over(lens, s, f)
	local lens_ = lens --[[:! LensT]]
	return lens_.set(s, f(lens_.get(s)))
end

-- Lens.compose(lens1, lens2) -> Lens s c
-- Given Lens s a and Lens a c, produce Lens s c.
function Lens.compose(lens1, lens2)
	local l1 = lens1 --[[:! LensT]]
	local l2 = lens2 --[[:! LensT]]
	return Lens.new(
		function(s)
			return l2.get(l1.get(s))
		end,
		function(s, c)
			local a = l1.get(s)
			local a2 = l2.set(a, c)
			return l1.set(s, a2)
		end
	)
end

-- Lens.from_iso(iso) -> Lens s a
-- Promote an Iso to a Lens.
function Lens.from_iso(iso)
	local iso_ = iso --[[:! { get: (unknown) -> unknown, review: (unknown) -> unknown }]]
	return Lens.new(
		iso_.get,
		function(_s, a) return iso_.review(a) end
	)
end

-- Lens.field(name) -> Lens s s[name]
-- A lens that focuses on the field s[name].
-- set returns a shallow copy of s with that field replaced.
function Lens.field(name)
	return Lens.new(
		function(s)
			return s[name]
		end,
		function(s, a)
			local copy = {}
			for k, v in pairs(s) do
				copy[k] = v
			end
			copy[name] = a
			return copy
		end
	)
end

return Lens
