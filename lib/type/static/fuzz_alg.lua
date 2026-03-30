-- lib/type/static/fuzz_alg.lua
-- Algebra-level fuzz suite. Constructs type IDs directly via types.lua + unify.lua.
-- No parsing in the loop — higher trial counts, tests the type algebra in isolation.
--
-- Run with:
--   luajit lib/test/cli.lua lib/type/static/fuzz_alg.lua
--   PROP_SEED=12345 luajit lib/test/cli.lua lib/type/static/fuzz_alg.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local types_mod  = require("lib.type.static.types")
local unify_mod  = require("lib.type.static.unify")
local intern_mod = require("lib.type.static.intern")
local defs       = require("lib.type.static.defs")
local arb        = require("lib.test.arb")
local farb       = require("lib.type.static.fuzz_arb")

local LIT_INTEGER   = defs.LIT_INTEGER
local LIT_STRING    = defs.LIT_STRING
local LIT_BOOLEAN   = defs.LIT_BOOLEAN
local FLAG_OPTIONAL = defs.FLAG_OPTIONAL
local FLAG_READONLY = defs.FLAG_READONLY

-- ── Bare typing context ───────────────────────────────────────────────────────
-- Creates a minimal ctx sufficient for type construction and unification.
-- No scope, no annotations, no error reporting chain.

local function make_ctx()
	local pool = intern_mod.new()
	local ctx  = types_mod.new_ctx(pool)
	ctx.err       = { errors = {} }   -- required by operations that may report errors
	ctx.lit_cache = {}                -- enable literal type interning/dedup
	return ctx
end

-- ── AST → type ID ────────────────────────────────────────────────────────────
-- Converts a fuzz_arb.lua type AST node into a live type ID in a ctx.

local ast_to_tid   -- forward declaration for self-recursion

ast_to_tid = function(ctx, node)
	local tag = node.tag

	if     tag == "nil"      then return ctx.T_NIL
	elseif tag == "never"    then return ctx.T_NEVER
	elseif tag == "unknown"  then return ctx.T_UNKNOWN
	elseif tag == "base"     then
		local n = node.name
		if     n == "integer" then return ctx.T_INTEGER
		elseif n == "number"  then return ctx.T_NUMBER
		elseif n == "string"  then return ctx.T_STRING
		elseif n == "boolean" then return ctx.T_BOOLEAN
		end

	elseif tag == "lit_int"  then
		return types_mod.make_literal(ctx, LIT_INTEGER, node.value)

	elseif tag == "lit_str"  then
		-- Strip surrounding quotes to get the raw string, then intern it.
		local s  = node.value:sub(2, -2)
		local id = intern_mod.intern(ctx.pool, s)
		return types_mod.make_literal(ctx, LIT_STRING, id)

	elseif tag == "lit_bool" then
		return types_mod.make_literal(ctx, LIT_BOOLEAN, node.value and 1 or 0)

	elseif tag == "union" then
		local a = ast_to_tid(ctx, node.a)
		local b = ast_to_tid(ctx, node.b)
		return types_mod.make_union(ctx, { a, b })

	elseif tag == "inter" then
		local a = ast_to_tid(ctx, node.a)
		local b = ast_to_tid(ctx, node.b)
		return types_mod.make_intersection(ctx, { a, b })

	elseif tag == "func" then
		local params = {}
		for _, p in ipairs(node.params) do params[#params + 1] = ast_to_tid(ctx, p) end
		local rets = {}
		if node.ret.tag == "tuple" then
			for _, r in ipairs(node.ret.types) do rets[#rets + 1] = ast_to_tid(ctx, r) end
		else
			rets[1] = ast_to_tid(ctx, node.ret)
		end
		return types_mod.make_func(ctx, params, rets, -1)

	elseif tag == "record" then
		local fids = {}
		for _, f in ipairs(node.fields) do
			local nid = intern_mod.intern(ctx.pool, f.name)
			local tid = ast_to_tid(ctx, f.type)
			fids[#fids + 1] = types_mod.make_field(ctx, nid, tid, f.flags or 0)
		end
		return types_mod.make_table(ctx, fids, nil, -1)

	elseif tag == "indexer" then
		local key_tid = node.key == "string" and ctx.T_STRING or ctx.T_INTEGER
		local val_tid = ast_to_tid(ctx, node.val)
		return types_mod.make_table(ctx, {}, { key_tid, val_tid }, -1)
	end

	return ctx.T_UNKNOWN
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function subtype(ctx, a, b)
	return unify_mod.try_unify(ctx, a, b)
end

local function type_str(node)
	return farb.type_to_string(node)
end

-- ── Invariants ────────────────────────────────────────────────────────────────

-- 1. Reflexivity: T <: T
arb.it("[alg] reflexivity: T <: T",
	farb.arb_type,
	function(T_node)
		local ctx = make_ctx()
		local tid = ast_to_tid(ctx, T_node)
		assert(subtype(ctx, tid, tid),
			"reflexivity failed: " .. type_str(T_node))
	end, { trials = 2000 })

-- 2. Union introduction: A <: A | B
arb.it("[alg] union intro: A <: A | B",
	{ farb.arb_type, farb.arb_type },
	function(A_node, B_node)
		local ctx = make_ctx()
		local a   = ast_to_tid(ctx, A_node)
		local b   = ast_to_tid(ctx, B_node)
		local a_b = types_mod.make_union(ctx, { a, b })
		assert(subtype(ctx, a, a_b),
			"union intro failed: " .. type_str(A_node)
			.. " <: " .. type_str(A_node) .. " | " .. type_str(B_node))
	end, { trials = 2000 })

-- 3. Intersection elimination (left): A & B <: A
arb.it("[alg] inter elim left: A & B <: A",
	{ farb.arb_type, farb.arb_type },
	function(A_node, B_node)
		local ctx = make_ctx()
		local a   = ast_to_tid(ctx, A_node)
		local b   = ast_to_tid(ctx, B_node)
		local a_b = types_mod.make_intersection(ctx, { a, b })
		assert(subtype(ctx, a_b, a),
			"inter elim left failed: " .. type_str(A_node)
			.. " & " .. type_str(B_node)
			.. " should be <: " .. type_str(A_node))
	end, { trials = 2000 })

-- 4. Intersection elimination (right): A & B <: B
arb.it("[alg] inter elim right: A & B <: B",
	{ farb.arb_type, farb.arb_type },
	function(A_node, B_node)
		local ctx = make_ctx()
		local a   = ast_to_tid(ctx, A_node)
		local b   = ast_to_tid(ctx, B_node)
		local a_b = types_mod.make_intersection(ctx, { a, b })
		assert(subtype(ctx, a_b, b),
			"inter elim right failed: " .. type_str(A_node)
			.. " & " .. type_str(B_node)
			.. " should be <: " .. type_str(B_node))
	end, { trials = 2000 })

-- 5. Optional introduction: T <: T | nil
arb.it("[alg] optional intro: T <: T | nil",
	farb.arb_type,
	function(T_node)
		local ctx   = make_ctx()
		local tid   = ast_to_tid(ctx, T_node)
		local t_nil = types_mod.make_union(ctx, { tid, ctx.T_NIL })
		assert(subtype(ctx, tid, t_nil),
			"optional intro failed: " .. type_str(T_node))
	end, { trials = 2000 })

-- 6. nil <: T | nil (for any T)
arb.it("[alg] nil always <: T | nil",
	farb.arb_type,
	function(T_node)
		local ctx   = make_ctx()
		local tid   = ast_to_tid(ctx, T_node)
		local t_nil = types_mod.make_union(ctx, { tid, ctx.T_NIL })
		assert(subtype(ctx, ctx.T_NIL, t_nil),
			"nil <: T | nil failed for: " .. type_str(T_node))
	end, { trials = 1000 })

-- 7. Union symmetry of introduction: A <: B | A (not just A | B)
arb.it("[alg] union intro symmetric: A <: B | A",
	{ farb.arb_type, farb.arb_type },
	function(A_node, B_node)
		local ctx = make_ctx()
		local a   = ast_to_tid(ctx, A_node)
		local b   = ast_to_tid(ctx, B_node)
		local b_a = types_mod.make_union(ctx, { b, a })
		assert(subtype(ctx, a, b_a),
			"union intro symmetric failed: " .. type_str(A_node)
			.. " <: " .. type_str(B_node) .. " | " .. type_str(A_node))
	end, { trials = 2000 })

-- 8. Reflexivity of union: A | A =:= A  (A | A <: A and A <: A | A)
arb.it("[alg] union idempotent: A | A <: A",
	farb.arb_type,
	function(T_node)
		local ctx = make_ctx()
		local tid = ast_to_tid(ctx, T_node)
		local t_t = types_mod.make_union(ctx, { tid, tid })
		assert(subtype(ctx, t_t, tid),
			"union idempotent failed: " .. type_str(T_node) .. " | " .. type_str(T_node)
			.. " should be <: " .. type_str(T_node))
	end, { trials = 2000 })

-- 9. Transitivity via constructed union chain
-- A <: A|B (union intro) and A|B <: A|B|C (union intro again) implies A <: A|B|C
arb.it("[alg] transitivity: A <: A|B and A|B <: A|B|C implies A <: A|B|C",
	{ farb.arb_type, farb.arb_type, farb.arb_type },
	function(A_node, B_node, C_node)
		local ctx      = make_ctx()
		local a        = ast_to_tid(ctx, A_node)
		local b        = ast_to_tid(ctx, B_node)
		local c        = ast_to_tid(ctx, C_node)
		local a_or_b   = types_mod.make_union(ctx, { a, b })
		local a_or_b_c = types_mod.make_union(ctx, { a_or_b, c })
		-- middle step: A|B <: A|B|C
		assert(subtype(ctx, a_or_b, a_or_b_c),
			"union chain intro failed: "
			.. type_str(A_node) .. " | " .. type_str(B_node)
			.. " should be <: "
			.. type_str(A_node) .. " | " .. type_str(B_node) .. " | " .. type_str(C_node))
		-- transitivity: A <: A|B|C
		assert(subtype(ctx, a, a_or_b_c),
			"transitivity failed: "
			.. type_str(A_node)
			.. " should be <: "
			.. type_str(A_node) .. " | " .. type_str(B_node) .. " | " .. type_str(C_node))
	end, { trials = 2000 })

-- 10. Intersection intro: T <: T & T
arb.it("[alg] intersection intro: T <: T & T",
	farb.arb_type,
	function(T_node)
		local ctx   = make_ctx()
		local tid   = ast_to_tid(ctx, T_node)
		local t_and = types_mod.make_intersection(ctx, { tid, tid })
		assert(subtype(ctx, tid, t_and),
			"intersection intro failed: " .. type_str(T_node)
			.. " should be <: " .. type_str(T_node) .. " & " .. type_str(T_node))
	end, { trials = 2000 })

-- 11. Literal subtyping: lit <: base type
-- lit_int <: integer and <: number; lit_str <: string; lit_bool <: boolean
arb.it("[alg] literal subtyping: lit <: base type",
	farb.arb_type_leaf,
	function(leaf)
		local tag = leaf.tag
		-- Only test literal nodes; skip base types, nil, never, unknown (reflexivity covers those)
		if tag ~= "lit_int" and tag ~= "lit_str" and tag ~= "lit_bool" then return end
		local ctx = make_ctx()
		local tid = ast_to_tid(ctx, leaf)
		if tag == "lit_int" then
			assert(subtype(ctx, tid, ctx.T_INTEGER),
				"lit_int should be <: integer for value " .. tostring(leaf.value))
			assert(subtype(ctx, tid, ctx.T_NUMBER),
				"lit_int should be <: number for value " .. tostring(leaf.value))
		elseif tag == "lit_str" then
			assert(subtype(ctx, tid, ctx.T_STRING),
				"lit_str should be <: string for value " .. leaf.value)
		elseif tag == "lit_bool" then
			assert(subtype(ctx, tid, ctx.T_BOOLEAN),
				"lit_bool should be <: boolean for value " .. tostring(leaf.value))
		end
	end, { trials = 2000 })

-- 12. Literal asymmetry: integer is not <: lit_int(n)
-- Base types are supertypes of specific literals, not subtypes.
arb.it("[alg] literal asymmetry: integer is not <: lit_int(n)",
	arb.int(0, 99),
	function(n)
		local ctx     = make_ctx()
		local lit_tid = types_mod.make_literal(ctx, LIT_INTEGER, n)
		-- lit_int(n) <: integer (should hold)
		assert(subtype(ctx, lit_tid, ctx.T_INTEGER),
			"lit_int(" .. n .. ") should be <: integer")
		-- integer </: lit_int(n) (should NOT hold)
		assert(not subtype(ctx, ctx.T_INTEGER, lit_tid),
			"integer should NOT be <: lit_int(" .. n .. ")")
	end, { trials = 200 })

-- 13. Function subtyping: covariant return
-- (A) -> C  <:  (A) -> (C | B)   because C <: C | B
arb.it("[alg] function: covariant return",
	{ farb.arb_type, farb.arb_type, farb.arb_type },
	function(A_node, B_node, C_node)
		local ctx      = make_ctx()
		local a        = ast_to_tid(ctx, A_node)
		local b        = ast_to_tid(ctx, B_node)
		local c        = ast_to_tid(ctx, C_node)
		local c_or_b   = types_mod.make_union(ctx, { c, b })
		local f_narrow = types_mod.make_func(ctx, { a }, { c },     -1)
		local f_wide   = types_mod.make_func(ctx, { a }, { c_or_b }, -1)
		assert(subtype(ctx, f_narrow, f_wide),
			"covariant return failed: ("
			.. type_str(A_node) .. ") -> " .. type_str(C_node)
			.. " should be <: ("
			.. type_str(A_node) .. ") -> " .. type_str(C_node) .. " | " .. type_str(B_node))
	end, { trials = 2000 })

-- 14. Function subtyping: contravariant param
-- (A | B) -> C  <:  (A) -> C   because accepting more is a subtype of accepting less
arb.it("[alg] function: contravariant param",
	{ farb.arb_type, farb.arb_type, farb.arb_type },
	function(A_node, B_node, C_node)
		local ctx        = make_ctx()
		local a          = ast_to_tid(ctx, A_node)
		local b          = ast_to_tid(ctx, B_node)
		local c          = ast_to_tid(ctx, C_node)
		local a_or_b     = types_mod.make_union(ctx, { a, b })
		local f_wide_par = types_mod.make_func(ctx, { a_or_b }, { c }, -1)
		local f_narr_par = types_mod.make_func(ctx, { a },      { c }, -1)
		assert(subtype(ctx, f_wide_par, f_narr_par),
			"contravariant param failed: ("
			.. type_str(A_node) .. " | " .. type_str(B_node) .. ") -> " .. type_str(C_node)
			.. " should be <: ("
			.. type_str(A_node) .. ") -> " .. type_str(C_node))
	end, { trials = 2000 })

-- ── Deep-type stress invariants ───────────────────────────────────────────────
-- Use arb_type_deep for deeper intersection-of-union structures that arb_type
-- under-tests due to its halved sub_size. These are algebra-level only (no parsing).

-- 15. Deep reflexivity: T <: T at greater nesting depth
arb.it("[alg] deep reflexivity: deeply-nested T <: T",
	farb.arb_type_deep,
	function(T_node)
		local ctx = make_ctx()
		local tid = ast_to_tid(ctx, T_node)
		assert(subtype(ctx, tid, tid),
			"deep reflexivity failed: " .. type_str(T_node))
	end, { trials = 1000 })

-- 16. Deep union intro: A <: A | B with deep types
arb.it("[alg] deep union intro: A <: A | B (deep)",
	{ farb.arb_type_deep, farb.arb_type_deep },
	function(A_node, B_node)
		local ctx = make_ctx()
		local a   = ast_to_tid(ctx, A_node)
		local b   = ast_to_tid(ctx, B_node)
		local a_b = types_mod.make_union(ctx, { a, b })
		assert(subtype(ctx, a, a_b),
			"deep union intro failed: " .. type_str(A_node)
			.. " <: " .. type_str(A_node) .. " | " .. type_str(B_node))
	end, { trials = 1000 })

-- 17. Deep intersection elim: A & B <: A with deep types
arb.it("[alg] deep inter elim: A & B <: A (deep)",
	{ farb.arb_type_deep, farb.arb_type_deep },
	function(A_node, B_node)
		local ctx = make_ctx()
		local a   = ast_to_tid(ctx, A_node)
		local b   = ast_to_tid(ctx, B_node)
		local a_b = types_mod.make_intersection(ctx, { a, b })
		assert(subtype(ctx, a_b, a),
			"deep inter elim failed: " .. type_str(A_node)
			.. " & " .. type_str(B_node)
			.. " should be <: " .. type_str(A_node))
	end, { trials = 1000 })

-- 18. Deep intersection intro: T <: T & T with deep types
arb.it("[alg] deep intersection intro: T <: T & T (deep)",
	farb.arb_type_deep,
	function(T_node)
		local ctx   = make_ctx()
		local tid   = ast_to_tid(ctx, T_node)
		local t_and = types_mod.make_intersection(ctx, { tid, tid })
		assert(subtype(ctx, tid, t_and),
			"deep intersection intro failed: " .. type_str(T_node)
			.. " should be <: " .. type_str(T_node) .. " & " .. type_str(T_node))
	end, { trials = 1000 })

-- ── Optional/readonly field invariants ────────────────────────────────────────

-- 19. Required field satisfies optional slot: { x: T } <: { x?: T }
arb.it("[alg] required field <: optional field: { x: T } <: { x?: T }",
	farb.arb_base_type,
	function(T_node)
		local ctx  = make_ctx()
		local xid  = intern_mod.intern(ctx.pool, "x")
		local tid  = ast_to_tid(ctx, T_node)
		local req  = types_mod.make_table(ctx,
			{ types_mod.make_field(ctx, xid, tid, 0) }, nil, -1)
		local opt  = types_mod.make_table(ctx,
			{ types_mod.make_field(ctx, xid, tid, FLAG_OPTIONAL) }, nil, -1)
		assert(subtype(ctx, req, opt),
			"required <: optional failed for T = " .. type_str(T_node))
	end, { trials = 2000 })

-- 20. Optional field absent field is covered: {} <: { x?: T }
-- An optional field in the target means source can omit the field entirely.
arb.it("[alg] empty table <: optional-field table: {} <: { x?: T }",
	farb.arb_base_type,
	function(T_node)
		local ctx   = make_ctx()
		local xid   = intern_mod.intern(ctx.pool, "x")
		local tid   = ast_to_tid(ctx, T_node)
		local empty = types_mod.make_table(ctx, {}, nil, -1)
		local opt   = types_mod.make_table(ctx,
			{ types_mod.make_field(ctx, xid, tid, FLAG_OPTIONAL) }, nil, -1)
		assert(subtype(ctx, empty, opt),
			"{} should be <: { x?: T } for T = " .. type_str(T_node))
	end, { trials = 2000 })

-- 21. Optional field reflexivity: { x?: T } <: { x?: T }
arb.it("[alg] optional field reflexivity: { x?: T } <: { x?: T }",
	farb.arb_base_type,
	function(T_node)
		local ctx  = make_ctx()
		local xid  = intern_mod.intern(ctx.pool, "x")
		local tid  = ast_to_tid(ctx, T_node)
		local opt  = types_mod.make_table(ctx,
			{ types_mod.make_field(ctx, xid, tid, FLAG_OPTIONAL) }, nil, -1)
		local opt2 = types_mod.make_table(ctx,
			{ types_mod.make_field(ctx, xid, tid, FLAG_OPTIONAL) }, nil, -1)
		assert(subtype(ctx, opt, opt2),
			"optional reflexivity failed for T = " .. type_str(T_node))
	end, { trials = 2000 })

-- 22. Optional field NOT subtype of required: { x?: T } </: { x: T }
arb.it("[alg] optional field NOT <: required field: { x?: T } </: { x: T }",
	farb.arb_base_type,
	function(T_node)
		local ctx  = make_ctx()
		local xid  = intern_mod.intern(ctx.pool, "x")
		local tid  = ast_to_tid(ctx, T_node)
		local opt  = types_mod.make_table(ctx,
			{ types_mod.make_field(ctx, xid, tid, FLAG_OPTIONAL) }, nil, -1)
		local req  = types_mod.make_table(ctx,
			{ types_mod.make_field(ctx, xid, tid, 0) }, nil, -1)
		assert(not subtype(ctx, opt, req),
			"optional field should NOT be <: required field for T = " .. type_str(T_node))
	end, { trials = 2000 })

-- 24. Readonly field reflexivity: { readonly x: T } <: { readonly x: T }
arb.it("[alg] readonly field reflexivity: { readonly x: T } <: { readonly x: T }",
	farb.arb_base_type,
	function(T_node)
		local ctx  = make_ctx()
		local xid  = intern_mod.intern(ctx.pool, "x")
		local tid  = ast_to_tid(ctx, T_node)
		local ro   = types_mod.make_table(ctx,
			{ types_mod.make_field(ctx, xid, tid, FLAG_READONLY) }, nil, -1)
		local ro2  = types_mod.make_table(ctx,
			{ types_mod.make_field(ctx, xid, tid, FLAG_READONLY) }, nil, -1)
		assert(subtype(ctx, ro, ro2),
			"readonly reflexivity failed for T = " .. type_str(T_node))
	end, { trials = 2000 })

-- ── A1: never propagation ─────────────────────────────────────────────────────

-- 25. never | T <: T  (union with never collapses on the subtype side)
arb.it("[alg] never propagation: never | T <: T",
	farb.arb_type,
	function(T_node)
		local ctx    = make_ctx()
		local t_tid  = ast_to_tid(ctx, T_node)
		local nev_t  = types_mod.make_union(ctx, { ctx.T_NEVER, t_tid })
		assert(subtype(ctx, nev_t, t_tid),
			"never | T should be <: T, failed for T = " .. type_str(T_node))
	end, { trials = 2000 })

-- 26. T <: never | T  (union intro with never on left side)
arb.it("[alg] never propagation: T <: never | T",
	farb.arb_type,
	function(T_node)
		local ctx    = make_ctx()
		local t_tid  = ast_to_tid(ctx, T_node)
		local nev_t  = types_mod.make_union(ctx, { ctx.T_NEVER, t_tid })
		assert(subtype(ctx, t_tid, nev_t),
			"T should be <: never | T, failed for T = " .. type_str(T_node))
	end, { trials = 2000 })

-- 27. never & T <: never  (intersection with never collapses to never)
arb.it("[alg] never propagation: never & T <: never",
	farb.arb_type,
	function(T_node)
		local ctx    = make_ctx()
		local t_tid  = ast_to_tid(ctx, T_node)
		local nev_t  = types_mod.make_intersection(ctx, { ctx.T_NEVER, t_tid })
		assert(subtype(ctx, nev_t, ctx.T_NEVER),
			"never & T should be <: never, failed for T = " .. type_str(T_node))
	end, { trials = 2000 })

-- ── A2: readonly field semantics ──────────────────────────────────────────────

-- 28. Mutable satisfies readonly: { x: T } <: { readonly x: T }
-- A mutable field source can be used wherever a readonly field is expected.
arb.it("[alg] mutable satisfies readonly: { x: T } <: { readonly x: T }",
	farb.arb_base_type,
	function(T_node)
		local ctx  = make_ctx()
		local xid  = intern_mod.intern(ctx.pool, "x")
		local tid  = ast_to_tid(ctx, T_node)
		local mut  = types_mod.make_table(ctx,
			{ types_mod.make_field(ctx, xid, tid, 0) }, nil, -1)
		local ro   = types_mod.make_table(ctx,
			{ types_mod.make_field(ctx, xid, tid, FLAG_READONLY) }, nil, -1)
		assert(subtype(ctx, mut, ro),
			"{ x: T } should be <: { readonly x: T } for T = " .. type_str(T_node))
	end, { trials = 2000 })

-- 29. NOTE: { readonly x: T } </: { x: T } is NOT enforceable at the unify level.
-- FLAG_READONLY is a write-site constraint enforced in constrain.lua, not in unify.lua.
-- try_unify only checks structural shape; readonly does not affect structural subtyping.
-- The write-position rejection is tested at the grammar level (fuzz_test.lua A2 grammar variant).
-- This invariant is documented here as a known gap; see docs/fuzz-gaps.md A2.

-- ── A3: function arity invariants ─────────────────────────────────────────────

-- 30. Extra required param fails: (A, B) -> C </: (A) -> C
-- A function requiring 2 params does NOT satisfy a type expecting only 1 param.
-- Contravariant param check: target has 1 param; at position 2, target pads with T_NIL.
-- try_unify checks T_NIL <: B (i.e. nil <: B). For any base type B, nil is not a subtype.
-- Uses arb_base_type for B so B is always one of integer/number/string/boolean (no nil).
arb.it("[alg] A3: extra required param fails: (A, B) -> C </: (A) -> C",
	{ farb.arb_type, farb.arb_base_type, farb.arb_type },
	function(A_node, B_node, C_node)
		local ctx  = make_ctx()
		local a    = ast_to_tid(ctx, A_node)
		local b    = ast_to_tid(ctx, B_node)
		local c    = ast_to_tid(ctx, C_node)
		local f2   = types_mod.make_func(ctx, { a, b }, { c }, -1)
		local f1   = types_mod.make_func(ctx, { a },    { c }, -1)
		assert(not subtype(ctx, f2, f1),
			"(A, B) -> C should NOT be <: (A) -> C: ("
			.. type_str(A_node) .. ", " .. type_str(B_node) .. ") -> " .. type_str(C_node))
	end, { trials = 2000 })

-- 31. Fewer params OK: (A) -> C <: (A) -> C
-- A function with one param satisfies a type with one param (reflexivity sanity check).
arb.it("[alg] A3: fewer params OK: (A) -> C <: (A) -> C",
	{ farb.arb_type, farb.arb_type },
	function(A_node, C_node)
		local ctx = make_ctx()
		local a   = ast_to_tid(ctx, A_node)
		local c   = ast_to_tid(ctx, C_node)
		local f   = types_mod.make_func(ctx, { a }, { c }, -1)
		assert(subtype(ctx, f, f),
			"(A) -> C should be <: (A) -> C (reflexivity): ("
			.. type_str(A_node) .. ") -> " .. type_str(C_node))
	end, { trials = 2000 })

-- 32. A4: meta reflexivity: { #__add: T } <: { #__add: T }
arb.it("[alg] A4: meta reflexivity: { #__add: T } <: { #__add: T }",
	{ farb.arb_type },
	function(T_node)
		local ctx    = make_ctx()
		local tid    = ast_to_tid(ctx, T_node)
		local add_id = intern_mod.intern(ctx.pool, "__add")
		local mfid   = types_mod.make_field(ctx, add_id, tid, 0)
		local tbl    = types_mod.make_table(ctx, {}, nil, -1, { mfid })
		assert(subtype(ctx, tbl, tbl),
			"{ #__add: T } <: { #__add: T } (meta reflexivity) failed for T = "
			.. type_str(T_node))
	end, { trials = 2000 })

-- 33. A4: meta elimination: { #__add: T, #__sub: U } <: { #__add: T }
-- (source has more meta fields, satisfies fewer — width subtyping for meta slots)
arb.it("[alg] A4: meta elimination: { #__add: T, #__sub: U } <: { #__add: T }",
	{ farb.arb_type, farb.arb_type },
	function(T_node, U_node)
		local ctx    = make_ctx()
		local tid    = ast_to_tid(ctx, T_node)
		local uid    = ast_to_tid(ctx, U_node)
		local add_id = intern_mod.intern(ctx.pool, "__add")
		local sub_id = intern_mod.intern(ctx.pool, "__sub")
		local src    = types_mod.make_table(ctx, {}, nil, -1, {
			types_mod.make_field(ctx, add_id, tid, 0),
			types_mod.make_field(ctx, sub_id, uid, 0),
		})
		local tgt    = types_mod.make_table(ctx, {}, nil, -1, {
			types_mod.make_field(ctx, add_id, tid, 0),
		})
		assert(subtype(ctx, src, tgt),
			"{ #__add: T, #__sub: U } <: { #__add: T } (meta elimination) failed for T = "
			.. type_str(T_node) .. ", U = " .. type_str(U_node))
	end, { trials = 2000 })

-- 34. A4: missing required meta field fails: {} </: { #__add: T }
arb.it("[alg] A4: missing required meta field fails: {} </: { #__add: T }",
	{ farb.arb_type },
	function(T_node)
		local ctx    = make_ctx()
		local tid    = ast_to_tid(ctx, T_node)
		local add_id = intern_mod.intern(ctx.pool, "__add")
		local mfid   = types_mod.make_field(ctx, add_id, tid, 0)
		local empty  = types_mod.make_table(ctx, {}, nil, -1)
		local tgt    = types_mod.make_table(ctx, {}, nil, -1, { mfid })
		assert(not subtype(ctx, empty, tgt),
			"{} should NOT be <: { #__add: T } (missing required meta field) for T = "
			.. type_str(T_node))
	end, { trials = 2000 })

return {}
