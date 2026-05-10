-- lib/fp/adt/init.lua
-- General algebraic data type constructor.
--
-- ADT.define takes an ordered list of {name, arity} pairs and returns an ADT
-- table with:
--
--   ADT.<lowercased_name>(...)      — constructor functions
--   ADT.match(value, handlers)      — tag dispatch; errors on missing handler
--                                     unless a `_` catch-all is present
--   ADT.is(value)                   — true if value was produced by this ADT
--   ADT._constructors               — ordered array of lowercased constructor names
--
-- Typeclass instances are attached directly on the ADT table:
--
--   ADT[Mappable] = { map = ... }
--
-- Values produced by constructors delegate v[Typeclass] lookups to the ADT
-- table via metatable __index, so typeclass dispatch works transparently.
--
-- Constructor values store:
--   { _adt=ADT, tag=lowercased_name, n=arity, [1]=v1, [2]=v2, ... }
--
-- Convention: the last constructor in the definition is the Mappable focus for
-- `* -> *` instances (e.g. Right for Either, Just for Maybe). This is a
-- convention, not enforced by the library.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ADT = {}

-- ── ADT.define ────────────────────────────────────────────────────────────────

-- define({name, arity}, ...) → ADT table
--
-- Each argument is a two-element array: { "ConstructorName", arity }.
-- Constructors are accessible via the lowercased name.
function ADT.define(...)
	local specs = { ... }

	-- The ADT table returned to the caller. Typeclass instances are attached
	-- here directly (e.g. M[Mappable] = { map = ... }).
	local M = {}

	-- Metatable for the ADT table itself. Allows M[SomeTypeclass] to be read
	-- back transparently — no magic needed here; the ADT table is a plain
	-- table that callers index directly.
	--
	-- The value metatable delegates unknown keys to M so that:
	--   value[Typeclass]  →  M[Typeclass]  (typeclass dispatch)
	local value_mt = {
		__index = M,
	}

	M._constructors = {}

	for _, spec in ipairs(specs) do
		local name  = spec[1]
		local arity = spec[2]
		local tag   = name:lower()

		M._constructors[#M._constructors + 1] = tag

		if arity == 0 then
			-- 0-arity constructor: return a singleton value directly.
			-- We still make it a table so `is` and metatable dispatch work.
			local singleton = setmetatable(
				{ _adt = M, tag = tag, n = 0 },
				value_mt
			)
			M[tag] = singleton
		else
			-- n-arity constructor: closure that packs arguments.
			M[tag] = function(...)
				local v = { _adt = M, tag = tag, n = arity }
				for i = 1, arity do
					v[i] = select(i, ...)
				end
				return setmetatable(v, value_mt)
			end
		end
	end

	-- ── ADT.match ─────────────────────────────────────────────────────────────
	--
	-- match(value, handlers) → result of the matching handler
	--
	-- handlers is a table keyed by lowercased constructor name. A `_` key
	-- acts as a catch-all. Errors if no handler and no `_` are present.
	-- The matching handler receives the inner values as separate arguments
	-- (via unpack on value[1..n]).
	function M.match(value, handlers)
		local h = handlers[value.tag]
		if h == nil then
			h = handlers["_"]
		end
		if h == nil then
			error(
				"ADT.match: no handler for constructor '" .. tostring(value.tag) ..
				"' and no '_' catch-all provided",
				2
			)
		end
		if value.n == 0 then
			return h()
		else
			return h(unpack(value, 1, value.n --[[:! integer]]))
		end
	end

	-- ── ADT.is ────────────────────────────────────────────────────────────────
	--
	-- is(value) → boolean
	-- Returns true if value was produced by a constructor from this ADT.
	function M.is(value)
		return type(value) == "table" and value._adt == M
	end

	return M
end

return ADT
