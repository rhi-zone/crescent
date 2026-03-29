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

local LIT_INTEGER = defs.LIT_INTEGER
local LIT_STRING  = defs.LIT_STRING
local LIT_BOOLEAN = defs.LIT_BOOLEAN

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
			fids[#fids + 1] = types_mod.make_field(ctx, nid, tid, 0)
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

return {}
