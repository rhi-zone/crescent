-- lib/sem/prim.lua
-- PARTIAL primitive operations over the value algebra + store.
--
-- Each primitive is the per-primitive lemma unit for phase-2 (progress +
-- preservation prove per primitive). PARTIALITY IS THE POINT: an operation with
-- no rule for its operand kinds is STUCK — it returns a FAULT, not a Lua error
-- and not a silent coercion. e.g. arithmetic on a non-number faults; indexing a
-- non-table faults; raw_get of an absent key returns the nil-VALUE (that is
-- DEFINED, not a fault). The set of fault conditions here IS the catalogue of
-- stuck primitives, and each maps to one phase-2 progress lemma.
--
-- RESULT CONVENTION (matches docs/conventions.md `(nil, errmsg)`): every partial
-- primitive returns `(Value | nil, Fault | nil)`. Success → `(value, nil)`;
-- stuck → `(nil, fault)`. The nil-VALUE (a real Value with kind "nil") is
-- distinct from Lua `nil`, so the absent-key read returns `(nil_v, nil)`, never
-- ambiguous with a fault.
--
-- DISCIPLINE: this module observes values ONLY through the injected value
-- algebra `va` (kind_of / *_value / equal / number_*). It never inspects a raw
-- Lua type tag of a Value. The store is passed explicitly; nothing is global.

--:: require "lib.sem.value"
--:: require "lib.sem.config"

local config = require("lib.sem.config")

local M = {}

--:: PrimEnv = { va: ValueAlgebra, store: Store }

-- ── allocation (total) ──────────────────────────────────────────────────────

-- Allocate a fresh empty table; return its reference Value.
--: (PrimEnv) -> Value
function M.alloc_table(env)
	local addr = env.store.next_addr
	env.store.next_addr = addr + 1
	local cell = { entries = {} } --[[: TableCell]]
	env.store.objs[addr] = cell
	local ref = env.va.table_ref(addr) --: Value
	return ref
end

-- Allocate a closure descriptor; return its reference Value.
--: (PrimEnv, integer, boolean, Stmt[], integer, Value[]) -> Value
function M.alloc_closure(env, nparams, vararg, body, nslots, captured_env)
	local addr = env.store.next_addr
	env.store.next_addr = addr + 1
	local desc = {
		nparams = nparams, vararg = vararg, body = body,
		nslots = nslots, env = captured_env,
	}
	env.store.objs[addr] = desc
	return env.va.closure(addr)
end

-- ── store object accessors ──────────────────────────────────────────────────

-- Fetch the table cell behind a reference Value, or nil if not a live table.
--: (PrimEnv, Value) -> TableCell | nil
local function cell_of(env, ref)
	local obj = env.store.objs[env.va.addr_value(ref)]
	if obj == nil then return nil end
	local maybe = obj --[[: { entries?: { key: Value, val: Value }[] }]]
	if maybe.entries == nil then return nil end
	return obj --[[: TableCell]]
end

-- Fetch the closure descriptor behind a reference Value, or nil otherwise.
--: (PrimEnv, Value) -> ClosureDesc | nil
function M.closure_desc(env, ref)
	local obj = env.store.objs[env.va.addr_value(ref)]
	if obj == nil then return nil end
	local maybe = obj --[[: { nparams?: integer }]]
	if maybe.nparams == nil then return nil end
	return obj --[[: ClosureDesc]]
end

-- ── raw_get / raw_set (PARTIAL) ──────────────────────────────────────────────

-- raw_get(obj, key): obj must be a table reference. Absent key reads the
-- nil-VALUE (DEFINED). A nil key on read also reads nil (Lua: t[nil] == nil).
-- Indexing a non-table is a FAULT.
--: (PrimEnv, Value, Value) -> (Value | nil, Fault | nil)
function M.raw_get(env, obj, key)
	if env.va.kind_of(obj) ~= "table" then
		return nil, config.fault(config.FAULT_INDEX_NIL,
			"index of non-table (kind " .. env.va.kind_of(obj) .. ")")
	end
	local cell = cell_of(env, obj)
	if cell == nil then
		return nil, config.fault(config.FAULT_INDEX_NIL, "dangling table reference")
	end
	if env.va.kind_of(key) == "nil" then return env.va.nil_v, nil end
	for i = 1, #cell.entries do
		local e = cell.entries[i]
		if e ~= nil and env.va.equal(e.key, key) then return e.val, nil end
	end
	return env.va.nil_v, nil
end

-- raw_set(obj, key, val): obj must be a table reference; key must not be nil
-- (t[nil] = v is a FAULT). Setting a key to the nil-VALUE removes it.
--: (PrimEnv, Value, Value, Value) -> (boolean | nil, Fault | nil)
function M.raw_set(env, obj, key, val)
	if env.va.kind_of(obj) ~= "table" then
		return nil, config.fault(config.FAULT_INDEX_NIL,
			"newindex of non-table (kind " .. env.va.kind_of(obj) .. ")")
	end
	local cell = cell_of(env, obj)
	if cell == nil then
		return nil, config.fault(config.FAULT_INDEX_NIL, "dangling table reference")
	end
	if env.va.kind_of(key) == "nil" then
		return nil, config.fault(config.FAULT_KEY_NIL, "table index is nil")
	end
	for i = 1, #cell.entries do
		local e = cell.entries[i]
		if e ~= nil and env.va.equal(e.key, key) then
			if env.va.kind_of(val) == "nil" then
				-- Remove entry i by left-shifting the tail (avoids table.remove's
				-- integer-indexer signature; semantics are identical).
				local n = #cell.entries
				for j = i, n - 1 do cell.entries[j] = cell.entries[j + 1] end
				cell.entries[n] = nil
			else
				e.val = val
			end
			return true, nil
		end
	end
	if env.va.kind_of(val) ~= "nil" then
		cell.entries[#cell.entries + 1] = { key = key, val = val }
	end
	return true, nil
end

-- Lua length (#): border over integer keys 1..n with no nil hole; string length
-- for strings. Non-table/non-string is a FAULT.
--: (PrimEnv, Value) -> (Value | nil, Fault | nil)
function M.prim_len(env, obj)
	if env.va.kind_of(obj) == "string" then
		return env.va.number(#env.va.string_value(obj)), nil
	end
	if env.va.kind_of(obj) ~= "table" then
		return nil, config.fault(config.FAULT_INDEX_NIL,
			"length of non-table (kind " .. env.va.kind_of(obj) .. ")")
	end
	local n = 0
	while true do
		local got, f = M.raw_get(env, obj, env.va.number(n + 1))
		if got == nil then return nil, f end
		if env.va.kind_of(got) == "nil" then break end
		n = n + 1
	end
	return env.va.number(n), nil
end

-- ── arithmetic (PARTIAL: non-number operands fault) ─────────────────────────
-- op in {add, sub, mul, div, mod}.
--: (PrimEnv, string, Value, Value) -> (Value | nil, Fault | nil)
function M.prim_arith(env, op, a, b)
	local va = env.va
	if va.kind_of(a) ~= "number" or va.kind_of(b) ~= "number" then
		return nil, config.fault(config.FAULT_ARITH,
			"arithmetic on " .. va.kind_of(a) .. " and " .. va.kind_of(b))
	end
	local x, y = va.number_value(a), va.number_value(b)
	if op == "add" then return va.number(va.number_add(x, y)), nil end
	if op == "sub" then return va.number(va.number_sub(x, y)), nil end
	if op == "mul" then return va.number(va.number_mul(x, y)), nil end
	if op == "div" then return va.number(va.number_div(x, y)), nil end
	if op == "mod" then return va.number(va.number_mod(x, y)), nil end
	return nil, config.fault(config.FAULT_ARITH, "unknown arith op " .. op)
end

-- ── comparison (PARTIAL) ─────────────────────────────────────────────────────
-- eq: total (Lua == over all kinds). lt/le: numbers and strings only; mixed or
-- other kinds fault (Lua errors on e.g. number < table).
--: (PrimEnv, string, Value, Value) -> (Value | nil, Fault | nil)
function M.prim_compare(env, op, a, b)
	local va = env.va
	if op == "eq" then return va.bool(va.equal(a, b)), nil end
	local ka, kb = va.kind_of(a), va.kind_of(b)
	if ka == "number" and kb == "number" then
		local x, y = va.number_value(a), va.number_value(b)
		if op == "lt" then return va.bool(va.number_lt(x, y)), nil end
		if op == "le" then return va.bool(va.number_le(x, y)), nil end
	elseif ka == "string" and kb == "string" then
		local x, y = va.string_value(a), va.string_value(b)
		if op == "lt" then return va.bool(x < y), nil end
		if op == "le" then return va.bool(x <= y), nil end
	end
	return nil, config.fault(config.FAULT_COMPARE,
		"compare " .. op .. " on " .. ka .. " and " .. kb)
end

-- ── concatenation (PARTIAL: only string/number operands) ─────────────────────
--: (PrimEnv, Value, Value) -> (Value | nil, Fault | nil)
function M.prim_concat(env, a, b)
	local va = env.va
	--: (Value) -> string | nil
	local function as_str(v)
		local k = va.kind_of(v)
		if k == "string" then return va.string_value(v) end
		if k == "number" then return va.number_tostring(va.number_value(v)) end
		return nil
	end
	local sa, sb = as_str(a), as_str(b)
	if sa == nil or sb == nil then
		return nil, config.fault(config.FAULT_CONCAT,
			"concat of " .. va.kind_of(a) .. " and " .. va.kind_of(b))
	end
	return va.string(sa .. sb), nil
end

return M
