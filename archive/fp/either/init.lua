-- lib/fp/either/init.lua
-- Either e a = Left e | Right a
-- Right-biased: all typeclass operations act on the Right value and
-- short-circuit on Left.
-- Implements: Mappable, Applicable, Chainable, Foldable, Semigroup

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Mappable   = require("lib.fp.mappable")
local Applicable = require("lib.fp.applicable")
local Foldable   = require("lib.fp.foldable")
local Semigroup  = require("lib.fp.semigroup")

-- Guard Chainable — may not exist in all deployment configurations.
local Chainable
do
	local ok, mod = pcall(require, "lib.fp.chainable")
	if ok then Chainable = mod end
end

-- Guard Traversable — may not exist in all deployment configurations.
local Traversable
do
	local ok, mod = pcall(require, "lib.fp.traversable")
	if ok then Traversable = mod end
end

-- Guard Alt — may not exist in all deployment configurations.
local Alt
do
	local ok, mod = pcall(require, "lib.fp.alt")
	if ok then Alt = mod end
end

-- Guard Bifunctor — may not exist in all deployment configurations.
local Bifunctor
do
	local ok, mod = pcall(require, "lib.fp.bifunctor")
	if ok then Bifunctor = mod end
end

local Either = {}

-- ── Left ──────────────────────────────────────────────────────────────────────

local left_f_impl = {
	map = function(_f, fa)
		-- map over Left is identity — short-circuit
		return fa
	end,
}

local left_ap_impl = {
	-- Left(e) <*> _ = Left(e)
	ap = function(ff, _fa)
		return ff
	end,
	pure = function(a)
		return Either.right(a)
	end,
}

local left_foldable_impl = {
	-- Left has no Right value — behave like an empty container
	foldr = function(_f, z, _ta)
		return z
	end,
	foldMap = function(_f, _ta)
		error("Foldable.foldMap: cannot foldMap over Left (no value to fold)", 2)
	end,
	fold = function(_ta)
		error("Foldable.fold: cannot fold Left (no value to fold)", 2)
	end,
}

-- Semigroup for Left(e):
--   Left <> Right  = Right
--   Left <> Left   = right Left (the second one)
local left_sg_impl = {
	append = function(_a, b)
		-- Left is always dominated by the right operand
		return b
	end,
}

local function make_left_chainable_impl()
	return {
		-- bind(Left(e), f) = Left(e)
		bind = function(ma, _f)
			return ma
		end,
	}
end

-- Alt instance for Left: alt(Left(_), fb) = fb
local left_alt_impl = {
	alt = function(_fa, fb)
		return fb
	end,
}

-- Bifunctor instance for Left: bimap(f, g, Left(e)) = Left(f(e))
local left_bifunctor_impl = {
	bimap = function(f, _g, fab)
		return Either.left(f(fab.value))
	end,
}

-- Traversable instance for Left:
-- traverse(f, Left(e), ctor) = pure(ctor, Either.left(e))
local function make_left_traversable_impl()
	return {
		traverse = function(_f, ta, ctor)
			return Applicable.pure(ctor, Either.left(ta.value))
		end,
	}
end

local function make_left_mt()
	local index = {
		[Mappable]   = left_f_impl,
		[Applicable] = left_ap_impl,
		[Foldable]   = left_foldable_impl,
		[Semigroup]  = left_sg_impl,
	}
	if Chainable then
		index[Chainable] = make_left_chainable_impl()
	end
	if Alt then
		index[Alt] = left_alt_impl
	end
	if Bifunctor then
		index[Bifunctor] = left_bifunctor_impl
	end
	if Traversable then
		index[Traversable] = make_left_traversable_impl()
	end
	return {
		__index = index,
		__tostring = function(self)
			return "Left(" .. tostring(self.value) .. ")"
		end,
	}
end

local left_mt = make_left_mt()

function Either.left(e)
	return setmetatable({ value = e, _tag = "left" }, left_mt)
end

-- ── Right ─────────────────────────────────────────────────────────────────────

local right_f_impl = {
	map = function(f, fa)
		return Either.right(f(fa.value))
	end,
}

local right_ap_impl = {
	-- Right(f) <*> Left(e)  = Left(e)
	-- Right(f) <*> Right(a) = Right(f(a))
	ap = function(ff, fa)
		if fa._tag == "left" then
			return fa
		end
		return Either.right(ff.value(fa.value))
	end,
	pure = function(a)
		return Either.right(a)
	end,
}

local right_foldable_impl = {
	-- foldr(f, z, Right(a)) = f(a, z)
	foldr = function(f, z, ta)
		return f(ta.value, z)
	end,
	-- foldMap(f, Right(a)) = f(a)
	foldMap = function(f, ta)
		return f(ta.value)
	end,
	-- fold(Right(a)) = a
	fold = function(ta)
		return ta.value
	end,
}

-- Semigroup for Right(a):
--   Right <> Left  = Right (self wins)
--   Right(a) <> Right(b) = Right(append(a, b))
local right_sg_impl = {
	append = function(a, b)
		if b._tag == "left" then
			return a
		end
		-- Both Right — combine inner values via their Semigroup instance
		return Either.right(Semigroup.append(a.value, b.value))
	end,
}

local function make_right_chainable_impl()
	return {
		-- bind(Right(a), f) = f(a)
		bind = function(ma, f)
			return f(ma.value)
		end,
	}
end

-- Alt instance for Right: alt(Right(a), _) = Right(a)
local right_alt_impl = {
	alt = function(fa, _fb)
		return fa
	end,
}

-- Bifunctor instance for Right: bimap(f, g, Right(a)) = Right(g(a))
local right_bifunctor_impl = {
	bimap = function(_f, g, fab)
		return Either.right(g(fab.value))
	end,
}

-- Traversable instance for Right:
-- traverse(f, Right(a), ctor) = map(Either.right, f(a))
local function make_right_traversable_impl()
	return {
		traverse = function(f, ta, _ctor)
			return Mappable.map(Either.right, f(ta.value))
		end,
	}
end

local function make_right_mt()
	local index = {
		[Mappable]   = right_f_impl,
		[Applicable] = right_ap_impl,
		[Foldable]   = right_foldable_impl,
		[Semigroup]  = right_sg_impl,
	}
	if Chainable then
		index[Chainable] = make_right_chainable_impl()
	end
	if Alt then
		index[Alt] = right_alt_impl
	end
	if Bifunctor then
		index[Bifunctor] = right_bifunctor_impl
	end
	if Traversable then
		index[Traversable] = make_right_traversable_impl()
	end
	return {
		__index = index,
		__tostring = function(self)
			return "Right(" .. tostring(self.value) .. ")"
		end,
	}
end

local right_mt = make_right_mt()

function Either.right(a)
	return setmetatable({ value = a, _tag = "right" }, right_mt)
end

-- ── Predicates ────────────────────────────────────────────────────────────────

function Either.is_left(e)
	return e._tag == "left"
end

function Either.is_right(e)
	return e._tag == "right"
end

-- ── Eliminators ───────────────────────────────────────────────────────────────

function Either.from_right(e)
	if e._tag ~= "right" then
		error("Either.from_right: Left", 2)
	end
	return e.value
end

function Either.from_left(e)
	if e._tag ~= "left" then
		error("Either.from_left: Right", 2)
	end
	return e.value
end

-- either(f, g, e) — eliminate: apply f for Left, g for Right
function Either.either(f, g, e)
	if e._tag == "left" then
		return f(e.value)
	else
		return g(e.value)
	end
end

return Either
