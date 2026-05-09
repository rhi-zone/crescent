-- lib/fp/maybe/init.lua
-- Maybe a = Nothing | Just a
-- Implements: Mappable, Applicable, Chainable, Foldable, Traversable,
--             Semigroup (when inner is Semigroup), Monoid

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Mappable   = require("lib.fp.mappable")
local Applicable = require("lib.fp.applicable")
local Chainable  = require("lib.fp.chainable")
local Foldable   = require("lib.fp.foldable")
local Semigroup  = require("lib.fp.semigroup")
local Monoid     = require("lib.fp.monoid")

-- Guard Alt — may not exist in all deployment configurations.
local Alt
do
	local ok, mod = pcall(require, "lib.fp.alt")
	if ok then Alt = mod end
end

-- Guard Traversable — may not exist in all deployment configurations.
local Traversable
do
	local ok, mod = pcall(require, "lib.fp.traversable")
	if ok then Traversable = mod end
end

local Maybe = {}

-- ── Nothing ───────────────────────────────────────────────────────────────────

-- Nothing is a singleton; its Semigroup append defers to the other value's
-- Semigroup instance when the other is a Just, or returns Nothing when both
-- are Nothing.
local nothing_sg_impl = {
	append = function(a, b)
		-- Nothing <> x = x
		return b
	end,
}

local nothing_m_impl = {
	empty = function()
		return Maybe.nothing
	end,
}

local nothing_f_impl = {
	map = function(_f, _fa)
		return Maybe.nothing
	end,
}

local nothing_ap_impl = {
	-- Nothing <*> _ = Nothing
	ap = function(_ff, _fa)
		return Maybe.nothing
	end,
	pure = function(a)
		return Maybe.just(a)
	end,
}

-- Foldable instance for Nothing:
-- foldr(f, z, Nothing) = z  (no elements to fold)
-- foldMap(f, Nothing) errors — no element to dispatch Monoid empty() on
-- fold(Nothing) errors — same reason
local nothing_foldable_impl = {
	foldr = function(_f, z, _ta)
		return z
	end,
	foldMap = function(_f, _ta)
		error("Foldable.foldMap: cannot foldMap over Nothing (no Monoid instance to produce empty)", 2)
	end,
	fold = function(_ta)
		error("Foldable.fold: cannot fold Nothing (no Monoid instance to produce empty)", 2)
	end,
}

local nothing_chainable_impl = {
	-- bind(Nothing, f) = Nothing
	bind = function(_ma, _f)
		return Maybe.nothing
	end,
}

-- Traversable instance for Nothing:
-- traverse(f, Nothing, ctor) = pure(ctor, Maybe.nothing)
local function make_nothing_traversable_impl()
	return {
		traverse = function(_f, _ta, ctor)
			return Applicable.pure(ctor, Maybe.nothing)
		end,
	}
end

-- Alt instance for Nothing: alt(Nothing, fb) = fb
local nothing_alt_impl = {
	alt = function(_fa, fb)
		return fb
	end,
}

local function make_nothing_mt()
	--: { [unknown]: unknown }
	local index = {
		[Mappable.key]   = nothing_f_impl,
		[Applicable.key] = nothing_ap_impl,
		[Chainable.key]  = nothing_chainable_impl,
		[Foldable.key]   = nothing_foldable_impl,
		[Semigroup.key]  = nothing_sg_impl,
		[Monoid.key]     = nothing_m_impl,
	}
	if Alt then
		index[Alt.key] = nothing_alt_impl
	end
	if Traversable then
		index[Traversable.key] = make_nothing_traversable_impl()
	end
	return {
		__index = index,
		__tostring = function(_self)
			return "Nothing"
		end,
	}
end

local nothing_mt = make_nothing_mt()

Maybe.nothing = setmetatable({}, nothing_mt)

-- ── Just ──────────────────────────────────────────────────────────────────────

local just_sg_impl = {
	append = function(a, b)
		-- Just(a) <> Nothing = Just(a)
		if b == Maybe.nothing then
			return a
		end
		-- Just(a) <> Just(b) = Just(a <> b)
		return Maybe.just(Semigroup.append(a.value, b.value))
	end,
}

local just_m_impl = {
	empty = function()
		return Maybe.nothing
	end,
}

local just_f_impl = {
	map = function(f, fa)
		return Maybe.just(f(fa.value))
	end,
}

local just_ap_impl = {
	-- Just(f) <*> Just(a) = Just(f(a))
	-- Just(f) <*> Nothing = Nothing
	ap = function(ff, fa)
		if fa == Maybe.nothing then
			return Maybe.nothing
		end
		return Maybe.just(ff.value(fa.value))
	end,
	pure = function(a)
		return Maybe.just(a)
	end,
}

-- Foldable instance for Just:
-- foldr(f, z, Just(a)) = f(a, z)   (single element, apply f then return)
-- foldMap(f, Just(a)) = f(a)        (single element, no combining needed)
-- fold(Just(a)) = a                 (element must already be a Monoid value)
local just_foldable_impl = {
	foldr = function(f, z, ta)
		return f(ta.value, z)
	end,
	foldMap = function(f, ta)
		return f(ta.value)
	end,
	fold = function(ta)
		return ta.value
	end,
}

local just_chainable_impl = {
	-- bind(Just(a), f) = f(a)
	bind = function(ma, f)
		return f(ma.value)
	end,
}

-- Traversable instance for Just:
-- traverse(f, Just(a), ctor) = map(Maybe.just, f(a))
local function make_just_traversable_impl()
	return {
		traverse = function(f, ta, _ctor)
			return Mappable.map(Maybe.just, f(ta.value))
		end,
	}
end

-- Alt instance for Just: alt(Just(a), _) = Just(a)
local just_alt_impl = {
	alt = function(fa, _fb)
		return fa
	end,
}

local function make_just_mt()
	--: { [unknown]: unknown }
	local index = {
		[Mappable.key]   = just_f_impl,
		[Applicable.key] = just_ap_impl,
		[Chainable.key]  = just_chainable_impl,
		[Foldable.key]   = just_foldable_impl,
		[Semigroup.key]  = just_sg_impl,
		[Monoid.key]     = just_m_impl,
	}
	if Alt then
		index[Alt.key] = just_alt_impl
	end
	if Traversable then
		index[Traversable.key] = make_just_traversable_impl()
	end
	return {
		__index = index,
		__tostring = function(self)
			return "Just(" .. tostring(self.value) .. ")"
		end,
	}
end

local just_mt = make_just_mt()

function Maybe.just(a)
	return setmetatable({ value = a }, just_mt)
end

-- ── Predicates ────────────────────────────────────────────────────────────────

--: (m: unknown) -> boolean
function Maybe.is_just(m)
	return m ~= Maybe.nothing
end

--: (m: unknown) -> boolean
function Maybe.is_nothing(m)
	return m == Maybe.nothing
end

-- ── Eliminators ───────────────────────────────────────────────────────────────

function Maybe.from_just(m)
	if m == Maybe.nothing then
		error("Maybe.from_just: Nothing", 2)
	end
	return m.value
end

function Maybe.from_maybe(default, m)
	if m == Maybe.nothing then
		return default
	end
	return m.value
end

return Maybe
