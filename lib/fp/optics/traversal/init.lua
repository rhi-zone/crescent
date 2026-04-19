-- lib/fp/optics/traversal/init.lua
-- Traversal s a — focus on zero or more targets within s.
-- Concrete representation: { traverseOf: (ctor, f: a -> f a) -> s -> f s }
--
-- A Traversal generalises traverse over an arbitrary focus, not just the
-- structure's natural element type.  Where Traversable.traverse visits every
-- element of a container, a Traversal visits whichever elements are selected
-- by the optic.
--
-- traverseOf(traversal, ctor, f, s)
--   ctor : an applicative constructor value (e.g. Maybe.nothing) used for
--          Applicable.pure dispatch
--   f    : a -> f a
--   s    : the source structure
--   Returns: f s  (the structure rebuilt inside the applicative)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Applicable = require("lib.fp.applicable")
local Mappable   = require("lib.fp.mappable")
local Lens       = require("lib.fp.optics.lens")
local Prism      = require("lib.fp.optics.prism")
local Maybe      = require("lib.fp.maybe")

-- ── Identity applicative (local, used by over) ────────────────────────────────
-- Identity wraps a value; map/ap act directly on the wrapped value.
-- Implements [Mappable] and [Applicable] so that Mappable.map / Applicable.pure
-- dispatch correctly when traverseOf implementations call them on Identity values.

local Identity_mt

local function Identity(a)
	return setmetatable({ value = a }, Identity_mt)
end

local identity_mappable_impl = {
	map = function(f, fa)
		return Identity(f(fa.value))
	end,
}

local identity_applicable_impl = {
	ap = function(ff, fa)
		return Identity(ff.value(fa.value))
	end,
	pure = function(a)
		return Identity(a)
	end,
}

Identity_mt = {
	__index = {
		[Mappable.key]   = identity_mappable_impl,
		[Applicable.key] = identity_applicable_impl,
	},
}

-- ── Const applicative (local, used by toList) ─────────────────────────────────
-- Const wraps a list; map ignores the function (phantom b); ap concatenates
-- lists; pure produces an empty list.  The monoid is list concatenation.
-- Implements [Mappable] and [Applicable] for the same reason as Identity.

local Const_mt

local function Const(xs)
	return setmetatable({ value = xs }, Const_mt)
end

local const_mappable_impl = {
	-- map ignores f — Const is phantom in b
	map = function(_f, fa)
		return fa
	end,
}

local const_applicable_impl = {
	-- ap: Const(xs) <*> Const(ys) = Const(xs ++ ys)
	ap = function(ff, fa)
		local result = {}
		local n = 0
		for _, v in ipairs(ff.value) do
			n = n + 1
			result[n] = v
		end
		for _, v in ipairs(fa.value) do
			n = n + 1
			result[n] = v
		end
		return Const(result)
	end,
	-- pure: Const([])  — no element contributed
	pure = function(_a)
		return Const({})
	end,
}

Const_mt = {
	__index = {
		[Mappable.key]   = const_mappable_impl,
		[Applicable.key] = const_applicable_impl,
	},
}

-- ── Traversal ─────────────────────────────────────────────────────────────────

local Traversal = {}

-- Traversal.new(traverseOf) -> Traversal s a
-- traverseOf : (ctor, f, s) -> f s
--   ctor provides Applicable dispatch for the applicative being threaded;
--   f : a -> f a  maps each focus;
--   s : the source structure.
function Traversal.new(traverseOf)
	return { traverseOf = traverseOf }
end

-- Traversal.traverseOf(traversal, ctor, f, s) -> f s
-- Sequence f over each focus of s inside applicative ctor.
function Traversal.traverseOf(traversal, ctor, f, s)
	return traversal.traverseOf(ctor, f, s)
end

-- Traversal.sequenceOf(traversal, ctor, s) -> f s
-- s is a structure whose foci are already wrapped in f.
-- sequenceOf = traverseOf with identity as f.
function Traversal.sequenceOf(traversal, ctor, s)
	return traversal.traverseOf(ctor, function(x) return x end, s)
end

-- Traversal.over(traversal, s, f) -> s
-- Modify all foci with a pure function f.
-- Uses the local Identity applicative; no external applicative required.
function Traversal.over(traversal, s, f)
	-- Identity.pure is used by implementations that call Applicable.pure(ctor, v).
	-- We provide Identity.nothing as ctor — any Identity value will do for dispatch.
	local ctor = Identity(nil)
	local function f_id(a)
		return Identity(f(a))
	end
	local result = traversal.traverseOf(ctor, f_id, s)
	return result.value
end

-- Traversal.toList(traversal, s) -> list of a
-- Collect all foci into a plain Lua array.
-- Uses the local Const applicative internally.
function Traversal.toList(traversal, s)
	-- Const.pure is used by implementations that call Applicable.pure(ctor, v).
	local ctor = Const({})
	local function f_const(a)
		return Const({ a })
	end
	local result = traversal.traverseOf(ctor, f_const, s)
	return result.value
end

-- Traversal.set(traversal, s, a) -> s
-- Replace all foci with the constant value a.
function Traversal.set(traversal, s, a)
	return Traversal.over(traversal, s, function(_) return a end)
end

-- ── Conversions ───────────────────────────────────────────────────────────────

-- Traversal.from_lens(lens) -> Traversal s a
-- A Lens has exactly one focus; promote it to a Traversal.
function Traversal.from_lens(lens)
	return Traversal.new(function(ctor, f, s)
		local fa = f(Lens.get(lens, s))
		-- map (\a -> Lens.set(lens, s, a)) over fa
		return Mappable.map(function(a) return Lens.set(lens, s, a) end, fa)
	end)
end

-- Traversal.from_prism(prism) -> Traversal s a
-- A Prism has zero or one focus; promote it to a Traversal.
function Traversal.from_prism(prism)
	return Traversal.new(function(ctor, f, s)
		local ma = Prism.preview(prism, s)
		if ma == Maybe.nothing then
			-- No focus: lift s unchanged into the applicative
			return Applicable.pure(ctor, s)
		else
			local fa = f(ma.value)
			-- map (\a -> Prism.review(prism, a)) over fa
			return Mappable.map(function(a) return Prism.review(prism, a) end, fa)
		end
	end)
end

-- ── Composition ───────────────────────────────────────────────────────────────

-- Traversal.compose(t1, t2) -> Traversal s c
-- Given Traversal s a and Traversal a c, traverse each a inside s,
-- and within each a traverse each c.
function Traversal.compose(t1, t2)
	return Traversal.new(function(ctor, f, s)
		-- For each a in s, traverse all c in a using t2.
		-- t1 sequences the per-a results inside the applicative.
		return t1.traverseOf(ctor, function(a)
			return t2.traverseOf(ctor, f, a)
		end, s)
	end)
end

return Traversal
