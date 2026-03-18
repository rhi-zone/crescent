-- lib/fp/maybe/init.lua
-- Maybe a = Nothing | Just a
-- Implements: Functor, Semigroup (when inner is Semigroup), Monoid

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Functor   = require("lib.fp.functor")
local Semigroup = require("lib.fp.semigroup")
local Monoid    = require("lib.fp.monoid")

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

local nothing_mt = {
	__index = {
		[Functor]   = nothing_f_impl,
		[Semigroup] = nothing_sg_impl,
		[Monoid]    = nothing_m_impl,
	},
	__tostring = function(_self)
		return "Nothing"
	end,
}

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

local just_mt = {
	__index = {
		[Functor]   = just_f_impl,
		[Semigroup] = just_sg_impl,
		[Monoid]    = just_m_impl,
	},
	__tostring = function(self)
		return "Just(" .. tostring(self.value) .. ")"
	end,
}

function Maybe.just(a)
	return setmetatable({ value = a }, just_mt)
end

-- ── Predicates ────────────────────────────────────────────────────────────────

function Maybe.is_just(m)
	return m ~= Maybe.nothing
end

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
