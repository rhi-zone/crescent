-- lib/fp/fn/init.lua
-- Fn(f) — wrapper for Lua functions with Mappable, Applicable, Chainable instances.
--
-- Functions cannot have metatables in Lua, so Fn wraps them. __call is
-- installed so usage is transparent: Fn(f)(x) == f(x).
--
-- Mappable:   map(h, Fn(g))    = Fn(function(...) return h(g(...)) end)   -- composition
-- Applicable: ap(Fn(f), Fn(a)) = Fn(function(x) return f(x)(a(x)) end)   -- S combinator
--             pure(_, a)       = Fn(function() return a end)              -- const function
-- Chainable:  bind(Fn(f), k)   = Fn(function(x) return k(f(x))(x) end)  -- reader monad

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local Mappable   = require("lib.fp.mappable")
local Applicable = require("lib.fp.applicable")
local Chainable  = require("lib.fp.chainable")

-- Guard Profunctor — may not exist in all deployment configurations.
local Profunctor
do
	local ok, mod = pcall(require, "lib.fp.profunctor")
	if ok then Profunctor = mod end
end

local Fn = {}

-- ── Implementation tables ──────────────────────────────────────────────────────

local fn_mappable_impl = {
	-- map(h, Fn(g)) = Fn(h . g)   function composition
	map = function(h, fa)
		local g = fa._fn
		return Fn.new(function(...)
			return h(g(...))
		end)
	end,
}

local fn_applicable_impl = {
	-- ap(Fn(f), Fn(a)) = Fn(λx. f(x)(a(x)))   S combinator
	ap = function(ff, fa)
		local f = ff._fn
		local a = fa._fn
		return Fn.new(function(x)
			return f(x)(a(x))
		end)
	end,
	-- pure(_, a) = Fn(λ_. a)   constant function
	pure = function(a)
		return Fn.new(function() return a end)
	end,
}

local fn_chainable_impl = {
	-- bind(Fn(f), k) = Fn(λx. k(f(x))(x))   reader monad / function monad
	bind = function(ma, k)
		local f = ma._fn
		return Fn.new(function(x)
			return k(f(x))._fn(x)
		end)
	end,
}

-- Profunctor instance for Fn:
-- dimap(f, g, Fn(h)) = Fn(function(...) return g(h(f(...))) end)
-- Contramap input with f, map output with g.
local fn_profunctor_impl = {
	dimap = function(f, g, fbc)
		local h = fbc._fn
		return Fn.new(function(...)
			return g(h(f(...)))
		end)
	end,
}

-- ── Metatable ──────────────────────────────────────────────────────────────────

--: { [any]: any }
local fn_index = {
	[Mappable.key]   = fn_mappable_impl,
	[Applicable.key] = fn_applicable_impl,
	[Chainable.key]  = fn_chainable_impl,
}

if Profunctor then
	fn_index[Profunctor.key] = fn_profunctor_impl
end

local fn_mt = {
	__index = fn_index,
	-- Transparent call: Fn(f)(x) == f(x)
	__call = function(self, ...)
		return self._fn(...)
	end,
	__tostring = function(self)
		return "Fn(" .. tostring(self._fn) .. ")"
	end,
}

-- ── Constructor ───────────────────────────────────────────────────────────────

function Fn.new(f)
	return setmetatable({ _fn = f }, fn_mt)
end

-- Allow Fn(f) as sugar for Fn.new(f)
--: any
local fn_module_mt = {
	__call = function(_self, f)
		return Fn.new(f)
	end,
}
setmetatable(Fn, fn_module_mt)

return Fn
