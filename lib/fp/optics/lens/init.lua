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

-- Lens.get(lens, s) -> a
function Lens.get(lens, s)
	return lens.get(s)
end

-- Lens.set(lens, s, a) -> s
function Lens.set(lens, s, a)
	return lens.set(s, a)
end

-- Lens.over(lens, s, f) -> s
-- Modify the focus in-place with f.
function Lens.over(lens, s, f)
	return lens.set(s, f(lens.get(s)))
end

-- Lens.compose(lens1, lens2) -> Lens s c
-- Given Lens s a and Lens a c, produce Lens s c.
function Lens.compose(lens1, lens2)
	return Lens.new(
		function(s)
			return lens2.get(lens1.get(s))
		end,
		function(s, c)
			local a = lens1.get(s)
			local a2 = lens2.set(a, c)
			return lens1.set(s, a2)
		end
	)
end

-- Lens.from_iso(iso) -> Lens s a
-- Promote an Iso to a Lens.
function Lens.from_iso(iso)
	return Lens.new(
		iso.get,
		function(_s, a) return iso.review(a) end
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
