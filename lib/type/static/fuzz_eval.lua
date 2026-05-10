-- lib/type/static/fuzz_eval.lua
-- Eval-tier fuzz suite: tests type-level computation contracts.
-- Uses a fixed pre-declared scope with EachField/match aliases and a simple
-- table type string generator to check type-level computation contracts.
--
-- Invariants tested:
--   EachField: KeepAll identity, DropAll empty, round-trips, distributivity
--   Match: capture identity, wildcard constant, union capture round-trip
--   Oracle: soundness (algebra-level), same-name reflexivity, placeholder semantics
--
-- Run with:
--   luajit lib/test/cli.lua lib/type/static/fuzz_eval.lua
--   PROP_SEED=12345 luajit lib/test/cli.lua lib/type/static/fuzz_eval.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local check_mod  = require("lib.type.static.check")
local types_mod  = require("lib.type.static.types")
local unify_mod  = require("lib.type.static.unify")
local intern_mod = require("lib.type.static.intern")
local defs       = require("lib.type.static.defs")
local arb        = require("lib.test.arb")
local T          = require("lib.test.assert")
local earb       = require("lib.type.static.fuzz_eval_arb")

local TAG_NAMED = defs.TAG_NAMED

-- ── Fixed scope ───────────────────────────────────────────────────────────────
-- Declared at the top of every eval program.

local FIXED_SCOPE = [[
--:: KeepAll<D>      = match D { _ => { D } }
--:: DropAll<D>      = match D { _ => {} }
--:: MakeOptional<D> = match D { { optional: _, ...%Rest } => { { optional: true,  ...Rest } } }
--:: MakeRequired<D> = match D { { optional: _, ...%Rest } => { { optional: false, ...Rest } } }
--:: MakeReadonly<D> = match D { { readonly: _, ...%Rest } => { { readonly: true,  ...Rest } } }
--:: MakeWritable<D> = match D { { readonly: _, ...%Rest } => { { readonly: false, ...Rest } } }
--:: CaptureId<T>    = match T { %R => R }
--:: WildConst<T>    = match T { _ => integer }
--:: Parameters<F>   = match F { (...%P) -> unknown => P }
--:: First<F>        = match F { (%A, ...%Rest) -> unknown => A }
--:: Tail<F>         = match F { (%A, ...%Rest) -> unknown => Rest }
--:: ReturnType<F>   = match F { () -> %R => R }
]]

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- typechecks: returns true iff the program produces no errors.
--: (src: string) -> boolean
local function typechecks(src)
	local ec = check_mod.check_string(src, "fuzz_eval")
	return #ec.errors == 0
end

-- check_sub: build a program asserting A <: B via assignment; returns true iff 0 errors.
--: (a_str: string, b_str: string) -> boolean
local function check_sub(a_str, b_str)
	local src = FIXED_SCOPE
		.. "local _fuzz_a --: " .. a_str .. "\n"
		.. "local _fuzz_b = _fuzz_a --: " .. b_str .. "\n"
	return typechecks(src)
end

-- check_eq: assert A == B (bidirectional subtype check).
--: (a_str: string, b_str: string) -> boolean
local function check_eq(a_str, b_str)
	if not check_sub(a_str, b_str) then return false end
	return check_sub(b_str, a_str)
end

-- check_sub_ext: like check_sub but prepends extra_scope before FIXED_SCOPE.
-- Used when the test needs inline alias declarations not in FIXED_SCOPE.
--: (a_str: string, b_str: string, extra_scope: string) -> boolean
local function check_sub_ext(a_str, b_str, extra_scope)
	local src = extra_scope .. FIXED_SCOPE
		.. "local _fuzz_a --: " .. a_str .. "\n"
		.. "local _fuzz_b = _fuzz_a --: " .. b_str .. "\n"
	return typechecks(src)
end

-- arb generator for a table type string (uses earb, wraps with arb.generate protocol).
local arb_table_type = {
	generate = function(rng, sz)
		return earb.arb_table_type(rng, sz), nil
	end,
	shrink = function(_, _) return function() return nil end end,
}

-- arb generator for a union table type string.
local arb_union_table = {
	generate = function(rng, sz)
		return earb.arb_union_table(rng, sz), nil
	end,
	shrink = function(_, _) return function() return nil end end,
}

-- arb generator for a base type string.
local arb_base_type = {
	generate = function(rng, _)
		return earb.arb_base_type(rng), nil
	end,
	shrink = function(_, _) return function() return nil end end,
}

-- arb generator for function parts { params, ret, type_str }.
local arb_function_parts = {
	generate = function(rng, sz)
		return earb.arb_function_parts(rng, sz), nil
	end,
	shrink = function(_, _) return function() return nil end end,
}

-- arb generator for union-of-base-types: { lhs, rhs, type_str }.
local arb_union_base = {
	generate = function(rng, sz)
		return earb.arb_union_base(rng, sz), nil
	end,
	shrink = function(_, _) return function() return nil end end,
}

-- ── EachField invariants (500 trials each) ────────────────────────────────────

-- 1. KeepAll identity: $EachField<T, KeepAll> == T (bidirectional)
arb.it("[eval] EachField KeepAll identity: EachField<T, KeepAll> == T",
	arb_table_type,
	function(t_str_arg)
		local t_str = t_str_arg --[[:! string]]
		local ef_str = "$EachField<" .. t_str .. ", KeepAll>"
		assert(check_sub(t_str, ef_str),
			"T <: EachField<T,KeepAll> failed for T = " .. t_str)
		assert(check_sub(ef_str, t_str),
			"EachField<T,KeepAll> <: T failed for T = " .. t_str)
	end, { trials = 500 })

-- 2. DropAll: $EachField<T, DropAll> <: {} (empty closed table)
arb.it("[eval] EachField DropAll: EachField<T, DropAll> <: {}",
	arb_table_type,
	function(t_str_arg)
		local t_str = t_str_arg --[[:! string]]
		local ef_str = "$EachField<" .. t_str .. ", DropAll>"
		assert(check_sub(ef_str, "{}"),
			"EachField<T,DropAll> <: {} failed for T = " .. t_str)
	end, { trials = 500 })

-- 3. MakeOptional→MakeRequired round-trip == T (bidirectional)
arb.it("[eval] EachField MakeOptional->MakeRequired round-trip == T",
	arb_table_type,
	function(t_str_arg)
		local t_str = t_str_arg --[[:! string]]
		local rt_str = "$EachField<$EachField<" .. t_str .. ", MakeOptional>, MakeRequired>"
		assert(check_sub(t_str, rt_str),
			"T <: MakeRequired(MakeOptional(T)) failed for T = " .. t_str)
		assert(check_sub(rt_str, t_str),
			"MakeRequired(MakeOptional(T)) <: T failed for T = " .. t_str)
	end, { trials = 500 })

-- 4. MakeReadonly→MakeWritable round-trip == T (bidirectional)
arb.it("[eval] EachField MakeReadonly->MakeWritable round-trip == T",
	arb_table_type,
	function(t_str_arg)
		local t_str = t_str_arg --[[:! string]]
		local rt_str = "$EachField<$EachField<" .. t_str .. ", MakeReadonly>, MakeWritable>"
		assert(check_sub(t_str, rt_str),
			"T <: MakeWritable(MakeReadonly(T)) failed for T = " .. t_str)
		assert(check_sub(rt_str, t_str),
			"MakeWritable(MakeReadonly(T)) <: T failed for T = " .. t_str)
	end, { trials = 500 })

-- 5. KeepAll union distributivity: $EachField<T1 | T2, KeepAll> == T1 | T2
arb.it("[eval] EachField KeepAll distributivity over union",
	arb_union_table,
	function(t_str_arg)
		local t_str = t_str_arg --[[:! string]]
		local ef_str = "$EachField<" .. t_str .. ", KeepAll>"
		assert(check_sub(t_str, ef_str),
			"T1|T2 <: EachField<T1|T2,KeepAll> failed for T = " .. t_str)
		assert(check_sub(ef_str, t_str),
			"EachField<T1|T2,KeepAll> <: T1|T2 failed for T = " .. t_str)
	end, { trials = 500 })

-- ── Match invariants (500 trials each) ────────────────────────────────────────

-- 6. Capture identity: CaptureId<T> <: T and T <: CaptureId<T>
arb.it("[eval] match CaptureId<T> == T for base types",
	arb_base_type,
	function(t_str_arg)
		local t_str = t_str_arg --[[:! string]]
		local ci_str = "CaptureId<" .. t_str .. ">"
		assert(check_sub(t_str, ci_str),
			"T <: CaptureId<T> failed for T = " .. t_str)
		assert(check_sub(ci_str, t_str),
			"CaptureId<T> <: T failed for T = " .. t_str)
	end, { trials = 500 })

-- 7. Wildcard constant: WildConst<T> <: integer (wildcard always gives integer)
arb.it("[eval] match WildConst<T> <: integer for any T",
	arb_base_type,
	function(t_str_arg)
		local t_str = t_str_arg --[[:! string]]
		local wc_str = "WildConst<" .. t_str .. ">"
		assert(check_sub(wc_str, "integer"),
			"WildConst<T> <: integer failed for T = " .. t_str)
	end, { trials = 500 })

-- 8. Union capture round-trip: CaptureId<T1 | T2> == T1 | T2
arb.it("[eval] match CaptureId<T1 | T2> == T1 | T2",
	{ arb_base_type, arb_base_type },
	function(t1_arg, t2_arg)
		local t1 = t1_arg --[[:! string]]
		local t2 = t2_arg --[[:! string]]
		local union_str = t1 .. " | " .. t2
		local ci_str = "CaptureId<" .. union_str .. ">"
		assert(check_sub(union_str, ci_str),
			"T1|T2 <: CaptureId<T1|T2> failed for T = " .. union_str)
		assert(check_sub(ci_str, union_str),
			"CaptureId<T1|T2> <: T1|T2 failed for T = " .. union_str)
	end, { trials = 500 })

-- 6b. CaptureId identity for table types: CaptureId<T> == T for random table T
arb.it("[eval] match CaptureId<T> == T for table types",
	arb_table_type,
	function(t_str_arg)
		local t_str = t_str_arg --[[:! string]]
		local ci_str = "CaptureId<" .. t_str .. ">"
		assert(check_sub(t_str, ci_str),
			"T <: CaptureId<T> failed for table T = " .. t_str)
		assert(check_sub(ci_str, t_str),
			"CaptureId<T> <: T failed for table T = " .. t_str)
	end, { trials = 500 })

-- 6c. CaptureId identity for function types: CaptureId<F> == F for random function F
arb.it("[eval] match CaptureId<F> == F for function types",
	arb_function_parts,
	function(fp_arg)
		local fp = fp_arg --[[:! { type_str: string, params: { [integer]: string }, ret: string }]]
		local ci_str = "CaptureId<" .. fp.type_str .. ">"
		assert(check_sub(fp.type_str, ci_str),
			"F <: CaptureId<F> failed for F = " .. fp.type_str)
		assert(check_sub(ci_str, fp.type_str),
			"CaptureId<F> <: F failed for F = " .. fp.type_str)
	end, { trials = 500 })

-- 7b. WildConst for table types: WildConst<T> <: integer for any table T
arb.it("[eval] match WildConst<T> <: integer for table types",
	arb_table_type,
	function(t_str_arg)
		local t_str = t_str_arg --[[:! string]]
		local wc_str = "WildConst<" .. t_str .. ">"
		assert(check_sub(wc_str, "integer"),
			"WildConst<T> <: integer failed for table T = " .. t_str)
	end, { trials = 500 })

-- 7c. WildConst for function types: WildConst<F> <: integer for any function F
arb.it("[eval] match WildConst<F> <: integer for function types",
	arb_function_parts,
	function(fp_arg)
		local fp = fp_arg --[[:! { type_str: string, params: { [integer]: string }, ret: string }]]
		local wc_str = "WildConst<" .. fp.type_str .. ">"
		assert(check_sub(wc_str, "integer"),
			"WildConst<F> <: integer failed for F = " .. fp.type_str)
	end, { trials = 500 })

-- 8b. CaptureId union round-trip for table union: CaptureId<T1 | T2> == T1 | T2
arb.it("[eval] match CaptureId<T1 | T2> == T1 | T2 for table union",
	{ arb_table_type, arb_table_type },
	function(t1_arg, t2_arg)
		local t1 = t1_arg --[[:! string]]
		local t2 = t2_arg --[[:! string]]
		local union_str = t1 .. " | " .. t2
		local ci_str = "CaptureId<" .. union_str .. ">"
		assert(check_sub(union_str, ci_str),
			"T1|T2 <: CaptureId<T1|T2> failed for tables T = " .. union_str)
		assert(check_sub(ci_str, union_str),
			"CaptureId<T1|T2> <: T1|T2 failed for tables T = " .. union_str)
	end, { trials = 500 })

-- ── Oracle invariants (2000 trials each, algebra-level type construction) ─────

-- Bare typing context for oracle tests (no prelude, no parsing).
-- See fuzz_alg.lua make_ctx for rationale on the `any` return: this is a
-- deliberately partial Ctx for algebra-level tests that only touch types/unify.
--: () -> any
local function make_ctx()
	local pool = intern_mod.new()
	local ctx  = types_mod.new_ctx(pool)
	ctx.err               = { errors = {} }
	ctx.lit_cache         = {}
	ctx.declared_subtypes = {}
	return ctx
end

-- Returns (tid, nid). Annotated as a tuple-returning function. The `ctx`
-- parameter is `any` because make_ctx returns a deliberately partial Ctx
-- (see make_ctx above for rationale).
--: (ctx: any, name_str: string) -> (integer, integer)
local function make_named_tid(ctx, name_str)
	local nid = intern_mod.intern(ctx.pool, name_str) --[[: integer]]
	local tid = types_mod.alloc_type(ctx, TAG_NAMED)
	local t   = ctx.types:get(tid)
	t.data[0] = nid
	t.data[1] = 0
	t.data[2] = 0
	return tid, nid
end

-- 9. Oracle soundness: when (A_name_id → B_name_id) is in declared_subtypes,
--    try_unify(A_named, B_named) returns true.
T.it("[eval] oracle soundness: declared subtype oracle hit returns true", function()
	local ok_count = 0
	for i = 1, 2000 do
		local ctx = make_ctx()
		local a_tid, a_nid = make_named_tid(ctx, "OracleA" .. (i % 20))
		local b_tid, b_nid = make_named_tid(ctx, "OracleB" .. (i % 20))
		-- Inject oracle: OracleA <: OracleB
		ctx.declared_subtypes[a_nid] = b_nid
		if unify_mod.try_unify(ctx, a_tid, b_tid) then
			ok_count = ok_count + 1
		end
	end
	T.eq(ok_count, 2000, "oracle soundness: all 2000 trials should return true")
end)

-- 10. Oracle same-name reflexivity: try_unify(A_named, A_named) always true.
T.it("[eval] oracle same-name reflexivity: try_unify(A, A) == true", function()
	local ok_count = 0
	local NAMES --[[: { [integer]: string }]] = { "TypeA", "TypeB", "TypeC", "TypeD", "TypeE" }
	for i = 1, 2000 do
		local ctx   = make_ctx()
		local name  = NAMES[(i % #NAMES) + 1]
		local t_tid = make_named_tid(ctx, name)
		if unify_mod.try_unify(ctx, t_tid, t_tid) then
			ok_count = ok_count + 1
		end
	end
	T.eq(ok_count, 2000, "oracle reflexivity: all 2000 trials should return true")
end)

-- 11. Oracle placeholder semantics: unresolved named aliases pass try_unify
--     (the blanket-pass at line ~848 in unify.lua for placeholder named types).
T.it("[eval] oracle placeholder: unresolved named aliases pass try_unify", function()
	local ok_count = 0
	for i = 1, 2000 do
		local ctx = make_ctx()
		local a_tid = make_named_tid(ctx, "PlaceholderA" .. (i % 30))
		local b_tid = make_named_tid(ctx, "PlaceholderB" .. (i % 30))
		-- No oracle entry; these are unresolved placeholders
		if unify_mod.try_unify(ctx, a_tid, b_tid) then
			ok_count = ok_count + 1
		end
	end
	T.eq(ok_count, 2000, "placeholder semantics: all 2000 trials should return true")
end)

-- ── E1: EachField never propagation ──────────────────────────────────────────

-- E1a: $EachField<never, KeepAll> | integer == integer
-- If EachField<never, KeepAll> == never, then `never | integer` simplifies to
-- `integer`, so assigning x: (EachField<never,KeepAll> | integer) to integer
-- should produce 0 errors.
T.it("[eval] E1: EachField<never, KeepAll> | integer == integer (0 errors)", function()
	local src = FIXED_SCOPE .. [[
--:: TEachNever = $EachField<never, KeepAll>
--:: TResult = TEachNever | integer
--:: declare x = TResult
--:: declare _e1a = integer = x
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E1a")
	T.eq(#ec.errors, 0, "EachField<never,KeepAll>|integer == integer: expected 0 errors, got " .. tostring(#ec.errors))
end)

-- E1b: $EachField<never, KeepAll> resolves without crashing (no errors in
-- a program that simply declares and uses the type as never).
T.it("[eval] E1: EachField<never, KeepAll> used as never — no crash", function()
	local src = FIXED_SCOPE .. [[
--:: TNever = $EachField<never, KeepAll>
--:: declare x = TNever
--:: declare _e1b = never = x
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E1b")
	T.eq(#ec.errors, 0, "EachField<never,KeepAll> as never: expected 0 errors, got " .. tostring(#ec.errors))
end)

-- ── E6: $Throw/$Catch interaction ────────────────────────────────────────────

-- E6a: $Catch returns default when $Throw is present
T.it("[eval] E6a: $Catch<$Throw<msg>, integer> == integer (0 errors)", function()
	local src = FIXED_SCOPE .. [[
--:: Caught = $Catch<$Throw<"test error">, integer>
--:: declare x = Caught
--:: declare _e6a = integer = x
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E6a")
	T.eq(#ec.errors, 0, "Catch<Throw<msg>,integer>==integer: expected 0 errors, got " .. tostring(#ec.errors))
end)

-- E6b: $Catch passes through non-throw types
T.it("[eval] E6b: $Catch<string, integer> == string (0 errors)", function()
	local src = FIXED_SCOPE .. [[
--:: NotCaught = $Catch<string, integer>
--:: declare x = NotCaught
--:: declare _e6b = string = x
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E6b")
	T.eq(#ec.errors, 0, "Catch<string,integer>==string: expected 0 errors, got " .. tostring(#ec.errors))
end)

-- E6c: $Throw without $Catch produces exactly 1 diagnostic containing the message
T.it("[eval] E6c: $Throw<msg> without catch produces 1 error with the message", function()
	local src = FIXED_SCOPE .. [[
--:: Bad = $Throw<"this is wrong">
--:: declare x = Bad
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E6c")
	T.eq(#ec.errors, 1, "Throw without catch: expected 1 error, got " .. tostring(#ec.errors))
	if #ec.errors == 1 then
		local msg = ec.errors[1].msg or ""
		T.ok(msg:find("this is wrong", 1, true) ~= nil,
			"Throw error message should contain 'this is wrong', got: " .. msg)
	end
end)

-- ── E7: generic defaults ──────────────────────────────────────────────────────

-- E7a: default applied when second arg is omitted
-- Use function return annotation to enforce the type check.
T.it("[eval] E7a: WithDefault<integer> uses default U=string (0 errors)", function()
	local src = FIXED_SCOPE .. [[
--:: WithDefault<T, U = string> = { a: T, b: U }
--:: declare x = WithDefault<integer>
--: () -> { a: integer, b: string }
local function f() return x end
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E7a")
	T.eq(#ec.errors, 0, "WithDefault<integer>: expected 0 errors, got " .. tostring(#ec.errors))
end)

-- E7b: explicit second arg overrides the default
T.it("[eval] E7b: WithDefault<integer, boolean> overrides default (0 errors)", function()
	local src = FIXED_SCOPE .. [[
--:: WithDefault<T, U = string> = { a: T, b: U }
--:: declare x = WithDefault<integer, boolean>
--: () -> { a: integer, b: boolean }
local function f() return x end
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E7b")
	T.eq(#ec.errors, 0, "WithDefault<integer,boolean>: expected 0 errors, got " .. tostring(#ec.errors))
end)

-- E7c: default NOT used when arg provided — WithDefault<integer> gives b: string,
-- so returning it where b: boolean is expected must produce 1 error.
T.it("[eval] E7c: WithDefault<integer> b is string not boolean — 1 error", function()
	local src = FIXED_SCOPE .. [[
--:: WithDefault<T, U = string> = { a: T, b: U }
--:: declare x = WithDefault<integer>
--: () -> { a: integer, b: boolean }
local function f() return x end
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E7c")
	T.eq(#ec.errors, 1, "WithDefault<integer> b mismatch: expected 1 error, got " .. tostring(#ec.errors))
end)

-- ── E4: all-fields pattern correctness ───────────────────────────────────────
-- Fixed tests for { [%K]: %V } distribution over named-field and indexer tables.
-- Keys<T> and Values<T> are user-definable via the all-fields pattern.

-- Declarations used across E4 tests.
local E4_KEYS_DECL   = "--:: Keys<T>   = match T { { ...[%K]: %V } => K }\n"
local E4_VALUES_DECL = "--:: Values<T> = match T { { ...[%K]: %V } => V }\n"

-- Helper: check A == B (bidirectional) under a given prelude string.
local function check_eq_with_decl(decl, a_str, b_str)
	local function sub(x, y)
		local src = decl
			.. "local _e4a --: " .. x .. "\n"
			.. "local _e4b --: " .. y .. " = _e4a\n"
		return typechecks(src)
	end
	return sub(a_str, b_str) and sub(b_str, a_str)
end

-- E4a: Keys<{ x: integer, y: string }> == "x" | "y"
-- The all-fields pattern over a 2-field named table yields the union of its string
-- literal key names.
T.it('[eval] E4a: Keys<{ x: integer, y: string }> == "x" | "y" (bidirectional)', function()
	T.ok(
		check_eq_with_decl(
			E4_KEYS_DECL,
			'Keys<{ x: integer, y: string }>',
			'"x" | "y"'
		),
		'Keys<{ x: integer, y: string }> should equal "x" | "y" in both directions'
	)
end)

-- E4b: Values<{ x: integer, y: string }> == integer | string
-- The all-fields pattern over a 2-field table yields the union of value types.
T.it("[eval] E4b: Values<{ x: integer, y: string }> == integer | string (bidirectional)", function()
	T.ok(
		check_eq_with_decl(
			E4_VALUES_DECL,
			'Values<{ x: integer, y: string }>',
			'integer | string'
		),
		"Values<{ x: integer, y: string }> should equal integer | string in both directions"
	)
end)

-- E4c: Keys<{ [integer]: boolean }> == integer
-- Over an indexer table the all-fields pattern yields the indexer key type (not a
-- string literal — the key type is integer itself).
T.it("[eval] E4c: Keys<{ [integer]: boolean }> == integer (bidirectional)", function()
	T.ok(
		check_eq_with_decl(
			E4_KEYS_DECL,
			'Keys<{ [integer]: boolean }>',
			'integer'
		),
		"Keys<{ [integer]: boolean }> should equal integer in both directions"
	)
end)

-- ── E3: partial application round-trip ───────────────────────────────────────
-- Pick<T, Keys> == $EachField<T, PickKey<Keys>> — partial application vs full application.
-- Tests that F<A><B> and F<A, B> produce the same structural type.

-- Declarations shared across E3 tests.
local E3_PICK_DECL = table.concat({
	"--:: PickKey<Keys, D> = match D { { key: %K, ...%Rest } => match K { Keys => { D }, _ => {} }, _ => {} }",
	"--:: OmitKey<Keys, D> = match D { { key: %K, ...%Rest } => match K { Keys => {}, _ => { D } }, _ => { D } }",
	"--:: Pick<T, Keys>  = $EachField<T, PickKey<Keys>>",
	"--:: Omit<T, Keys>  = $EachField<T, OmitKey<Keys>>",
}, "\n") .. "\n"

-- E3a: Pick selects the right field — x.x accessible (0 errors).
-- Use function return annotation to enforce structural check (CLAUDE.md annotation gotcha).
T.it("[eval] E3a: Pick<{ x: integer, y: string }, \"x\">.x accessible — 0 errors", function()
	local src = E3_PICK_DECL .. [[
--:: declare x = Pick<{ x: integer, y: string }, "x">
--: () -> integer
local function get_x() return x.x end
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E3a")
	T.eq(#ec.errors, 0, "E3a: accessing .x on Pick result should produce 0 errors, got " .. tostring(#ec.errors))
end)

-- E3b: Pick removes the non-selected field — x.y is not accessible (1 error).
T.it("[eval] E3b: Pick<{ x: integer, y: string }, \"x\">.y not accessible — 1 error", function()
	local src = E3_PICK_DECL .. [[
--:: declare x = Pick<{ x: integer, y: string }, "x">
--: () -> string
local function get_y() return x.y end
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E3b")
	T.eq(#ec.errors, 1, "E3b: accessing .y on Pick result should produce 1 error, got " .. tostring(#ec.errors))
end)

-- E3c: Omit removes the named field — x.y accessible (0 errors).
T.it("[eval] E3c: Omit<{ x: integer, y: string }, \"x\">.y accessible — 0 errors", function()
	local src = E3_PICK_DECL .. [[
--:: declare x = Omit<{ x: integer, y: string }, "x">
--: () -> string
local function get_y() return x.y end
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E3c")
	T.eq(#ec.errors, 0, "E3c: accessing .y on Omit result should produce 0 errors, got " .. tostring(#ec.errors))
end)

-- E3d: PickDirect == PickAlias — partial application round-trip (bidirectional).
-- $EachField<T, PickKey<"x">> == Pick<T, "x">: the partial-application path and the
-- direct alias-application path must produce the same structural type.
T.it('[eval] E3d: $EachField<T, PickKey<"x">> == Pick<T, "x"> (bidirectional, 0 errors)', function()
	local src = E3_PICK_DECL .. [[
--:: PickDirect = $EachField<{ x: integer, y: string }, PickKey<"x">>
--:: PickAlias  = Pick<{ x: integer, y: string }, "x">
--:: declare pd = PickDirect
--:: declare pa = PickAlias
--: () -> PickAlias
local function f1() return pd end
--: () -> PickDirect
local function f2() return pa end
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E3d")
	T.eq(#ec.errors, 0, "E3d: PickDirect == PickAlias should produce 0 errors, got " .. tostring(#ec.errors))
end)

-- ── E2: EachField filter correctness ─────────────────────────────────────────
-- DropOptional: drops fields where optional==true, keeps required fields.
-- Declared inline (not in FIXED_SCOPE) since it's only used here.

local E2_DECL = "--:: DropOptional<D> = match D { { optional: true, ...%Rest } => {}, _ => { D } }\n"

-- E2a: DropOptional removes optional fields — { x?: integer, y: string } → { y: string }
-- The optional field x is dropped; y (required) survives.
-- Test: x.y is accessible (0 errors), x.x is NOT accessible (1 error).
T.it("[eval] E2a: DropOptional removes optional fields — .y accessible, .x dropped", function()
	-- E2a-pos: .y is accessible after DropOptional
	local src_pos = E2_DECL .. [[
--:: declare t = $EachField<{ x?: integer, y: string }, DropOptional>
--: () -> string
local function get_y() return t.y end
]]
	local ec_pos = check_mod.check_string(src_pos, "fuzz_eval_E2a_pos")
	T.eq(#ec_pos.errors, 0,
		"E2a-pos: .y should be accessible after DropOptional, got " .. tostring(#ec_pos.errors) .. " errors")

	-- E2a-neg: .x is NOT accessible after DropOptional (optional field was dropped)
	local src_neg = E2_DECL .. [[
--:: declare t = $EachField<{ x?: integer, y: string }, DropOptional>
--: () -> integer
local function get_x() return t.x end
]]
	local ec_neg = check_mod.check_string(src_neg, "fuzz_eval_E2a_neg")
	T.eq(#ec_neg.errors, 1,
		"E2a-neg: .x should be dropped by DropOptional (expected 1 error), got " .. tostring(#ec_neg.errors))
end)

-- E2b: DropOptional on a fully required table == identity (bidirectional)
-- $EachField<{ x: integer, y: string }, DropOptional> == { x: integer, y: string }
-- No optional fields means nothing is dropped.
T.it("[eval] E2b: DropOptional on all-required table == identity (bidirectional, 0 errors)", function()
	local src = E2_DECL .. FIXED_SCOPE .. [[
--:: AllRequired = { x: integer, y: string }
--:: Dropped     = $EachField<AllRequired, DropOptional>
--:: declare d = Dropped
--:: declare r = AllRequired
--: () -> AllRequired
local function f1() return d end
--: () -> Dropped
local function f2() return r end
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E2b")
	T.eq(#ec.errors, 0,
		"E2b: DropOptional on all-required table should equal original, got " .. tostring(#ec.errors) .. " errors")
end)

-- ── E9: match exhaustiveness on union ────────────────────────────────────────
-- match (A | B) { A => X, B => X } == X for concrete type pairs.
-- When all arms of a match on a union produce the same type X, the result is X.

-- E9a: Normalize<integer | string> == string (both arms → string, 0 errors).
T.it("[eval] E9a: Normalize<integer | string> == string (0 errors)", function()
	local src = [[
--:: Normalize<T> = match T { integer => string, string => string }
--:: declare x = Normalize<integer | string>
--:: declare _e9a = string = x
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E9a")
	T.eq(#ec.errors, 0, "E9a: Normalize<integer|string>==string: expected 0 errors, got " .. tostring(#ec.errors))
end)

-- E9b: MapTypes<integer | string> <: boolean | integer (both arm results present).
-- MapTypes maps integer→boolean and string→integer, so the union has both result types.
T.it("[eval] E9b: MapTypes<integer | string> == boolean | integer (0 errors)", function()
	local src = [[
--:: MapTypes<T> = match T { integer => boolean, string => integer }
--:: declare x = MapTypes<integer | string>
--:: declare _e9b = boolean | integer = x
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E9b")
	T.eq(#ec.errors, 0, "E9b: MapTypes<integer|string> <: boolean|integer: expected 0 errors, got " .. tostring(#ec.errors))
end)

-- E9c: never arm is ignored — Ignores<integer> == string (0 errors).
-- The never arm `never => boolean` can never match, so Ignores<integer> == string.
T.it("[eval] E9c: Ignores<integer> == string, never arm ignored (0 errors)", function()
	local src = [[
--:: Ignores<T> = match T { integer => string, never => boolean }
--:: declare x = Ignores<integer>
--:: declare _e9c = string = x
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E9c")
	T.eq(#ec.errors, 0, "E9c: Ignores<integer>==string (never arm ignored): expected 0 errors, got " .. tostring(#ec.errors))
end)

-- ── E8: oracle non-population on failed declaration ───────────────────────────
-- When --:: A: B fails the structural check, the oracle still registers the pair
-- (implementation always registers), BUT the resolved body of A (which is what
-- variable bindings carry) does NOT satisfy B structurally — so a call-site check
-- still fails.  The test asserts exactly 2 errors:
--   1. CONSTRAINT_MISMATCH at the --:: BadImpl: HasX declaration
--   2. Structural mismatch at the needs_x(bad) call site (BadImpl body { y: string }
--      has no field x, so the structural check fails independently of the oracle)

T.it("[eval] E8: failed --:: decl emits 2 errors (decl mismatch + call-site mismatch)", function()
	-- Build source as concatenated lines to avoid heredoc quoting issues.
	local src = table.concat({
		"--:: HasX = { x: integer }",
		"--:: BadImpl: HasX = { y: string }",  -- missing x → CONSTRAINT_MISMATCH (error 1)
		"--: (HasX) -> integer",
		"local function needs_x(v) return v.x end",
		"local bad --: BadImpl",
		"local _ = needs_x(bad)",  -- { y: string } doesn't satisfy { x: integer } (error 2)
	}, "\n") .. "\n"

	local ec = check_mod.check_string(src, "fuzz_eval_E8")
	T.eq(#ec.errors, 2,
		"E8: expected exactly 2 errors (decl mismatch + call-site mismatch), got " .. tostring(#ec.errors))

	-- First error must be the constraint-mismatch at the declaration (line 2).
	if #ec.errors >= 1 then
		local msg1 = ec.errors[1].msg or ""
		T.ok(msg1:find("does not satisfy constraint", 1, true) ~= nil,
			"E8 error[1] should be CONSTRAINT_MISMATCH, got: " .. msg1)
	end

	-- Second error must be a structural mismatch at the call site.
	if #ec.errors >= 2 then
		local msg2 = ec.errors[2].msg or ""
		T.ok(msg2:find("missing field", 1, true) ~= nil or msg2:find("cannot pass", 1, true) ~= nil,
			"E8 error[2] should be a structural mismatch at call site, got: " .. msg2)
	end
end)

-- ── E5: param capture invariants ─────────────────────────────────────────────

-- E5a (fixed): Parameters<(integer, string) -> boolean> == (integer, string)
T.it("[eval] E5a: Parameters<(integer, string) -> boolean> == (integer, string) (0 errors)", function()
	local src = FIXED_SCOPE .. [[
--:: P1 = Parameters<(integer, string) -> boolean>
--:: declare x = P1
--: () -> (integer, string)
local function f() return x[1], x[2] end
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E5a")
	T.eq(#ec.errors, 0, "E5a: expected 0 errors, got " .. tostring(#ec.errors))
end)

-- E5b (fixed): Tail<(integer, string, boolean) -> nil> == (string, boolean)
T.it("[eval] E5b: Tail<(integer, string, boolean) -> nil> == (string, boolean) (0 errors)", function()
	local src = FIXED_SCOPE .. [[
--:: TailTest = Tail<(integer, string, boolean) -> nil>
--:: declare x = TailTest
--: () -> (string, boolean)
local function f() return x[1], x[2] end
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E5b")
	T.eq(#ec.errors, 0, "E5b: expected 0 errors, got " .. tostring(#ec.errors))
end)

-- E5c (random): for a randomly generated function type (A, B, ...) -> C,
-- Parameters<(A, B, ...) -> C> should be bidirectionally assignable to (A, B, ...).
arb.it("[eval] E5c: Parameters<F> == param tuple for random function types",
	arb_function_parts,
	function(parts_arg)
		local parts = parts_arg --[[:! { type_str: string, params: { [integer]: string }, ret: string }]]
		local fn_str = parts.type_str
		local params = parts.params
		-- If no params, Parameters gives an empty tuple — skip (nothing interesting to assert)
		if #params == 0 then return end
		-- Build expected tuple type string: "(A, B, ...)"
		local tuple_str = "(" .. table.concat(params, ", ") .. ")"
		-- Parameters<fn_str> should == tuple_str bidirectionally
		local params_str = "Parameters<" .. fn_str .. ">"
		assert(check_sub(params_str, tuple_str),
			"Parameters<F> <: param-tuple failed for F = " .. fn_str)
		assert(check_sub(tuple_str, params_str),
			"param-tuple <: Parameters<F> failed for F = " .. fn_str)
	end, { trials = 500 })

-- ── E10: function return capture ──────────────────────────────────────────────

-- E10a (fixed): ReturnType<() -> integer> == integer
T.it("[eval] E10a: ReturnType<() -> integer> == integer (0 errors)", function()
	local src = FIXED_SCOPE .. [[
--:: declare x = ReturnType<() -> integer>
--:: declare _e10a = integer = x
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E10a")
	T.eq(#ec.errors, 0, "E10a: expected 0 errors, got " .. tostring(#ec.errors))
end)

-- E10b (fixed): ReturnType<() -> string> == string
T.it("[eval] E10b: ReturnType<() -> string> == string (0 errors)", function()
	local src = FIXED_SCOPE .. [[
--:: declare x = ReturnType<() -> string>
--:: declare _e10b = string = x
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E10b")
	T.eq(#ec.errors, 0, "E10b: expected 0 errors, got " .. tostring(#ec.errors))
end)

-- E10c (fixed): ReturnType<() -> (integer, string)> captures a tuple
-- The captured R is a tuple (integer, string); assign element-wise.
T.it("[eval] E10c: ReturnType<() -> (integer, string)> is a tuple (integer, string) (0 errors)", function()
	local src = FIXED_SCOPE .. [[
--:: declare x = ReturnType<() -> (integer, string)>
--: () -> (integer, string)
local function f() return x[1], x[2] end
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E10c")
	T.eq(#ec.errors, 0, "E10c: expected 0 errors, got " .. tostring(#ec.errors))
end)

-- E10b_rand (random): for arb_function_parts generating () -> C (0 params),
-- ReturnType<() -> C> == C.
arb.it("[eval] E10d: ReturnType<() -> C> == C for random 0-param function types",
	arb_function_parts,
	function(parts_arg)
		local parts = parts_arg --[[:! { type_str: string, params: { [integer]: string }, ret: string }]]
		-- Only test zero-param functions for this invariant (ReturnType uses () -> %R pattern)
		if #parts.params ~= 0 then return end
		local fn_str  = parts.type_str  -- "() -> C"
		local ret_str = parts.ret        -- "C"
		local rt_str  = "ReturnType<" .. fn_str .. ">"
		assert(check_sub(rt_str, ret_str),
			"ReturnType<() -> C> <: C failed for C = " .. ret_str)
		assert(check_sub(ret_str, rt_str),
			"C <: ReturnType<() -> C> failed for C = " .. ret_str)
	end, { trials = 500 })

-- ── E11: MakeOptional idempotent ─────────────────────────────────────────────
-- $EachField<$EachField<T, MakeOptional>, MakeOptional> == $EachField<T, MakeOptional>
-- Applying MakeOptional twice produces the same type as applying it once.

arb.it("[eval] E11: MakeOptional idempotent: applying twice == applying once",
	arb_table_type,
	function(t_str_arg)
		local t_str = t_str_arg --[[:! string]]
		local once_str  = "$EachField<" .. t_str .. ", MakeOptional>"
		local twice_str = "$EachField<$EachField<" .. t_str .. ", MakeOptional>, MakeOptional>"
		assert(check_sub(once_str, twice_str),
			"MakeOptional(T) <: MakeOptional(MakeOptional(T)) failed for T = " .. t_str)
		assert(check_sub(twice_str, once_str),
			"MakeOptional(MakeOptional(T)) <: MakeOptional(T) failed for T = " .. t_str)
	end, { trials = 500 })

-- ── G2a: capture on union round-trips ────────────────────────────────────────
-- CaptureId<A | B> == A | B where A and B are distinct base types.
-- Generating and re-emitting the union via a capture preserves the type.

arb.it("[eval] G2a: CaptureId<A | B> == A | B for union of distinct base types",
	arb_union_base,
	function(u_arg)
		local u = u_arg --[[:! { lhs: string, rhs: string, type_str: string }]]
		local union_str = u.type_str  -- "A | B"
		local cap_str   = "CaptureId<" .. union_str .. ">"
		assert(check_sub(cap_str, union_str),
			"CaptureId<A|B> <: A|B failed for A|B = " .. union_str)
		assert(check_sub(union_str, cap_str),
			"A|B <: CaptureId<A|B> failed for A|B = " .. union_str)
	end, { trials = 500 })

-- ── G2b: EachField distributivity over union of tables ───────────────────────
-- $EachField<T1 | T2, KeepAll> == $EachField<T1, KeepAll> | $EachField<T2, KeepAll>
-- == T1 | T2 (by KeepAll identity, invariant 1).
-- Tests that EachField distributes over a union of table types.

arb.it("[eval] G2b: EachField<T1|T2, KeepAll> == EachField<T1,KeepAll> | EachField<T2,KeepAll>",
	{ arb_table_type, arb_table_type },
	function(t1_str_arg, t2_str_arg)
		local t1_str = t1_str_arg --[[:! string]]
		local t2_str = t2_str_arg --[[:! string]]
		local union_str = t1_str .. " | " .. t2_str
		-- Dist1: EachField applied to the union directly
		local dist1 = "$EachField<" .. union_str .. ", KeepAll>"
		-- Dist2: EachField applied per-member then unioned
		local dist2 = "$EachField<" .. t1_str .. ", KeepAll> | $EachField<" .. t2_str .. ", KeepAll>"
		assert(check_sub(dist1, dist2),
			"EachField<T1|T2,KeepAll> <: EachField<T1,KeepAll>|EachField<T2,KeepAll> failed for T1=" .. t1_str .. " T2=" .. t2_str)
		assert(check_sub(dist2, dist1),
			"EachField<T1,KeepAll>|EachField<T2,KeepAll> <: EachField<T1|T2,KeepAll> failed for T1=" .. t1_str .. " T2=" .. t2_str)
	end, { trials = 500 })

-- ── MA8: EachField flag-alias distributivity over union ──────────────────────
-- For each flag-manipulating alias F, assert:
--   $EachField<T1 | T2, F> == $EachField<T1, F> | $EachField<T2, F>
-- (bidirectional subtype check, 500 trials each)

-- MA8a: MakeOptional distributes over union
arb.it("[eval] MA8a: EachField<T1|T2, MakeOptional> distributes over union",
	{ arb_table_type, arb_table_type },
	function(t1_arg, t2_arg)
		local t1 = t1_arg --[[:! string]]
		local t2 = t2_arg --[[:! string]]
		local lhs = "$EachField<" .. t1 .. " | " .. t2 .. ", MakeOptional>"
		local rhs = "$EachField<" .. t1 .. ", MakeOptional> | $EachField<" .. t2 .. ", MakeOptional>"
		assert(check_sub(lhs, rhs), lhs .. " should <: " .. rhs)
		assert(check_sub(rhs, lhs), rhs .. " should <: " .. lhs)
	end, { trials = 500 })

-- MA8b: MakeRequired distributes over union
arb.it("[eval] MA8b: EachField<T1|T2, MakeRequired> distributes over union",
	{ arb_table_type, arb_table_type },
	function(t1_arg, t2_arg)
		local t1 = t1_arg --[[:! string]]
		local t2 = t2_arg --[[:! string]]
		local lhs = "$EachField<" .. t1 .. " | " .. t2 .. ", MakeRequired>"
		local rhs = "$EachField<" .. t1 .. ", MakeRequired> | $EachField<" .. t2 .. ", MakeRequired>"
		assert(check_sub(lhs, rhs), lhs .. " should <: " .. rhs)
		assert(check_sub(rhs, lhs), rhs .. " should <: " .. lhs)
	end, { trials = 500 })

-- MA8c: MakeReadonly distributes over union
arb.it("[eval] MA8c: EachField<T1|T2, MakeReadonly> distributes over union",
	{ arb_table_type, arb_table_type },
	function(t1_arg, t2_arg)
		local t1 = t1_arg --[[:! string]]
		local t2 = t2_arg --[[:! string]]
		local lhs = "$EachField<" .. t1 .. " | " .. t2 .. ", MakeReadonly>"
		local rhs = "$EachField<" .. t1 .. ", MakeReadonly> | $EachField<" .. t2 .. ", MakeReadonly>"
		assert(check_sub(lhs, rhs), lhs .. " should <: " .. rhs)
		assert(check_sub(rhs, lhs), rhs .. " should <: " .. lhs)
	end, { trials = 500 })

-- MA8d: MakeWritable distributes over union
arb.it("[eval] MA8d: EachField<T1|T2, MakeWritable> distributes over union",
	{ arb_table_type, arb_table_type },
	function(t1_arg, t2_arg)
		local t1 = t1_arg --[[:! string]]
		local t2 = t2_arg --[[:! string]]
		local lhs = "$EachField<" .. t1 .. " | " .. t2 .. ", MakeWritable>"
		local rhs = "$EachField<" .. t1 .. ", MakeWritable> | $EachField<" .. t2 .. ", MakeWritable>"
		assert(check_sub(lhs, rhs), lhs .. " should <: " .. rhs)
		assert(check_sub(rhs, lhs), rhs .. " should <: " .. lhs)
	end, { trials = 500 })

-- ── MA: multi-arm match expression invariants ────────────────────────────────
-- Tests that the match evaluator correctly dispatches to the right arm,
-- distributes over unions, and produces `never` for non-matching inputs.

-- arb generator for a base-type quad: all 4 base types in a random order.
local arb_base_type_quad = {
	generate = function(rng, _) return earb.arb_base_type_quad(rng), nil end,
	shrink   = function(_, _) return function() return nil end end,
}

--:: BaseQuad = { a: string, b: string, c: string, d: string }

-- MA1: arm selectivity — correct arm fires (500 trials)
-- Declare match T { q.a => q.c, q.b => q.d }.
-- Assert MatchTwo<q.a> == q.c and MatchTwo<q.b> == q.d (bidirectional each).
arb.it("[eval] MA1: match arm selectivity — correct arm fires",
	arb_base_type_quad,
	function(q_arg)
		local q = q_arg --[[:! BaseQuad]]
		local decl = ("--:: MatchTwo<T> = match T { %s => %s, %s => %s }\n"):format(
			q.a, q.c, q.b, q.d)
		-- MatchTwo<q.a> == q.c
		assert(check_sub_ext("MatchTwo<" .. q.a .. ">", q.c, decl),
			"MatchTwo<" .. q.a .. "> should <: " .. q.c)
		assert(check_sub_ext(q.c, "MatchTwo<" .. q.a .. ">", decl),
			q.c .. " should <: MatchTwo<" .. q.a .. ">")
		-- MatchTwo<q.b> == q.d
		assert(check_sub_ext("MatchTwo<" .. q.b .. ">", q.d, decl),
			"MatchTwo<" .. q.b .. "> should <: " .. q.d)
		assert(check_sub_ext(q.d, "MatchTwo<" .. q.b .. ">", decl),
			q.d .. " should <: MatchTwo<" .. q.b .. ">")
	end, { trials = 500 })

-- MA2: distributivity over union (500 trials)
-- match (A | B) { A => C, B => D } == C | D
arb.it("[eval] MA2: match distributivity — match (A|B) { A => C, B => D } == C | D",
	arb_base_type_quad,
	function(q_arg)
		local q = q_arg --[[:! BaseQuad]]
		local decl     = ("--:: MatchTwo<T> = match T { %s => %s, %s => %s }\n"):format(
			q.a, q.c, q.b, q.d)
		local result   = "MatchTwo<" .. q.a .. " | " .. q.b .. ">"
		local expected = q.c .. " | " .. q.d
		assert(check_sub_ext(result, expected, decl),
			result .. " should <: " .. expected)
		assert(check_sub_ext(expected, result, decl),
			expected .. " should <: " .. result)
	end, { trials = 500 })

-- MA3: non-matching input gives never (500 trials)
-- match D { A => C, B => C } applied to D (not A, not B) == never
arb.it("[eval] MA3: match non-matching input == never",
	arb_base_type_quad,
	function(q_arg)
		local q = q_arg --[[:! BaseQuad]]
		-- Arms cover q.a and q.b; input is q.d (guaranteed ≠ q.a and ≠ q.b since all 4 distinct)
		local decl = ("--:: MatchNone<T> = match T { %s => %s, %s => %s }\n"):format(
			q.a, q.c, q.b, q.c)
		assert(check_sub_ext("MatchNone<" .. q.d .. ">", "never", decl),
			"MatchNone<" .. q.d .. "> should <: never (no arm matches)")
	end, { trials = 500 })

-- ── MA4–MA6: structural table-pattern arms ───────────────────────────────────
-- Tests that match arms with concrete structural patterns correctly extract
-- captured fields, return never for non-matching tables, and dispatch to the
-- correct arm when a pattern specifies an exact field type.

-- check_sub_fn: enforce A <: B via function-return annotation (not local assignment).
-- Local assignment does not enforce primitive type mismatches (annotation gotcha in CLAUDE.md).
-- Function-return annotation does: `--: () -> B / local function f() return a end` fails iff A </: B.
local function check_sub_fn(a_str, b_str, prelude)
	prelude = prelude or ""
	local src = prelude
		.. "local _ma_a --: " .. a_str .. "\n"
		.. "--: () -> " .. b_str .. "\n"
		.. "local function _ma_f() return _ma_a end\n"
	return typechecks(src)
end

-- check_eq_fn: bidirectional check_sub_fn.
local function check_eq_fn(a_str, b_str, prelude)
	return check_sub_fn(a_str, b_str, prelude) and check_sub_fn(b_str, a_str, prelude)
end

-- Shared declaration: FieldX<T> extracts the x field type (or never if no x).
local MA_FIELDX_DECL = "--:: FieldX<T> = match T { { x: %V } => V }\n"

-- MA4a (fixed): FieldX<{ x: integer, y: string }> == integer (bidirectional)
-- The pattern matches and captures the x field; y is ignored (open structural match).
T.it("[eval] MA4a: FieldX<{ x: integer, y: string }> == integer (bidirectional, fn-return)", function()
	T.ok(
		check_eq_fn("FieldX<{ x: integer, y: string }>", "integer", MA_FIELDX_DECL),
		"FieldX<{ x: integer, y: string }> should equal integer bidirectionally"
	)
end)

-- MA4b (fixed): FieldX<{ x: string }> == string (single-field table, fn-return)
T.it("[eval] MA4b: FieldX<{ x: string }> == string (bidirectional, fn-return)", function()
	T.ok(
		check_eq_fn("FieldX<{ x: string }>", "string", MA_FIELDX_DECL),
		"FieldX<{ x: string }> should equal string bidirectionally"
	)
end)

-- MA5 (fixed): non-matching table gives never (bidirectional)
-- { y: integer } has no x field; FieldX should produce never.
T.it("[eval] MA5: FieldX<{ y: integer }> == never (bidirectional, fn-return)", function()
	T.ok(
		check_eq_fn("FieldX<{ y: integer }>", "never", MA_FIELDX_DECL),
		"FieldX<{ y: integer }> should equal never bidirectionally"
	)
end)

-- MA5b (fixed): multi-field table with no x field also gives never.
T.it("[eval] MA5b: FieldX<{ y: string, z: boolean }> == never (bidirectional, fn-return)", function()
	T.ok(
		check_eq_fn("FieldX<{ y: string, z: boolean }>", "never", MA_FIELDX_DECL),
		"FieldX<{ y: string, z: boolean }> should equal never bidirectionally"
	)
end)

-- MA6a (fixed): exact type in pattern selects first arm
-- IsX<{ x: integer }> == boolean (x: integer matches the first arm)
local MA_ISX_DECL = "--:: IsX<T> = match T { { x: integer } => boolean, _ => never }\n"
T.it("[eval] MA6a: IsX<{ x: integer }> == boolean (exact type pattern, fn-return)", function()
	T.ok(
		check_eq_fn("IsX<{ x: integer }>", "boolean", MA_ISX_DECL),
		"IsX<{ x: integer }> should equal boolean bidirectionally"
	)
end)

-- MA6b (fixed): exact type pattern — wrong field type falls to wildcard
-- IsX<{ x: string }> == never (x: string doesn't match the x: integer pattern)
T.it("[eval] MA6b: IsX<{ x: string }> == never (exact type mismatch -> wildcard, fn-return)", function()
	T.ok(
		check_eq_fn("IsX<{ x: string }>", "never", MA_ISX_DECL),
		"IsX<{ x: string }> should equal never bidirectionally"
	)
end)

-- ── MA7: Intersection-type inputs to match ───────────────────────────────────
-- Intersection inputs: two classes of arm behaviour.
--
-- 1. TABLE structural patterns with captures (e.g. `{ x: %V }`):
--    The evaluator tries each member of the intersection independently via match_pattern.
--    The FIRST member that structurally matches fires its arm and contributes its bindings.
--    Basis: intersection elimination — A & B <: A, so if A matches the pattern, the arm fires.
--
-- 2. All other patterns (concrete types like `integer =>`, primitives, named types):
--    The intersection is treated as a unit via try_unify.
--    A specific-type arm (e.g. `integer =>`) does NOT fire for `integer & T` —
--    try_unify checks subtyping of the whole intersection, not per-member decomposition.
--    Only wildcard-style arms match:
--      - `%R => R`  (capture arm): captures the full intersection, returns it as-is
--      - `_ => X`   (wildcard arm): always fires, returns X

-- MA7a: CaptureId<A & B> == A & B (capture arm handles intersections, bidirectional)
T.it("[eval] MA7a: CaptureId<integer & string> == integer & string (bidirectional, fn-return)", function()
	local decl = "--:: CaptureId2<T> = match T { %R => R }\n"
	-- Forward: CaptureId<A&B> <: A&B
	local fwd_src = decl
		.. "local x --: CaptureId2<integer & string>\n"
		.. "--: () -> integer & string\n"
		.. "local function f() return x end\n"
	local ec_fwd = check_mod.check_string(fwd_src, "fuzz_eval_MA7a_fwd")
	T.eq(#ec_fwd.errors, 0, "MA7a-fwd: CaptureId<integer&string> <: integer&string: expected 0 errors, got " .. #ec_fwd.errors)
	-- Reverse: A&B <: CaptureId<A&B>
	local rev_src = decl
		.. "local x --: integer & string\n"
		.. "--: () -> CaptureId2<integer & string>\n"
		.. "local function f() return x end\n"
	local ec_rev = check_mod.check_string(rev_src, "fuzz_eval_MA7a_rev")
	T.eq(#ec_rev.errors, 0, "MA7a-rev: integer&string <: CaptureId<integer&string>: expected 0 errors, got " .. #ec_rev.errors)
end)

-- MA7b: WildConst<A & B> == integer (wildcard arm fires for intersection inputs)
-- _ always matches, so match T { _ => integer } gives integer even when T = A & B.
T.it("[eval] MA7b: WildConst<integer & string> == integer (wildcard arm, fn-return)", function()
	local decl = "--:: WildConst2<T> = match T { _ => integer }\n"
	-- Forward: WildConst<A&B> <: integer
	local fwd_src = decl
		.. "local x --: WildConst2<integer & string>\n"
		.. "--: () -> integer\n"
		.. "local function f() return x end\n"
	local ec_fwd = check_mod.check_string(fwd_src, "fuzz_eval_MA7b_fwd")
	T.eq(#ec_fwd.errors, 0, "MA7b-fwd: WildConst<integer&string> <: integer: expected 0 errors, got " .. #ec_fwd.errors)
	-- Reverse: integer <: WildConst<A&B>
	local rev_src = decl
		.. "local x --: integer\n"
		.. "--: () -> WildConst2<integer & string>\n"
		.. "local function f() return x end\n"
	local ec_rev = check_mod.check_string(rev_src, "fuzz_eval_MA7b_rev")
	T.eq(#ec_rev.errors, 0, "MA7b-rev: integer <: WildConst<integer&string>: expected 0 errors, got " .. #ec_rev.errors)
end)

-- MA7c: Specific-type arm FIRES for intersection input via intersection elimination.
-- match T { integer => boolean, _ => string } with T = integer & string gives boolean
-- because integer & string <: integer (intersection elimination), so the integer arm fires.
T.it("[eval] MA7c: specific arm fires for intersection via elimination — 0 errors", function()
	local decl = "--:: IntOrWild<T> = match T { integer => boolean, _ => string }\n"
	-- Forward: IntOrWild<integer & string> <: boolean  (integer arm fired via intersection elimination)
	local fwd_src = decl
		.. "local x --: IntOrWild<integer & string>\n"
		.. "--: () -> boolean\n"
		.. "local function f() return x end\n"
	local ec_fwd = check_mod.check_string(fwd_src, "fuzz_eval_MA7c_fwd")
	T.eq(#ec_fwd.errors, 0, "MA7c-fwd: IntOrWild<integer&string> <: boolean: expected 0, got " .. #ec_fwd.errors)
	-- Negative: string should NOT be <: IntOrWild<integer & string> (result is boolean, not string)
	local neg_src = decl
		.. "local x --: string\n"
		.. "--: () -> IntOrWild<integer & string>\n"
		.. "local function f() return x end\n"
	local ec_neg = check_mod.check_string(neg_src, "fuzz_eval_MA7c_neg")
	T.eq(#ec_neg.errors, 1, "MA7c-neg: string should NOT <: IntOrWild<integer&string> (expected 1 error, got " .. #ec_neg.errors .. ")")
end)

-- MA7d: Intersection with unrelated type still triggers the matching arm.
-- match (integer & { x: string }) { integer => boolean, _ => never } gives boolean
-- because integer & { x: string } <: integer via intersection elimination.
T.it("[eval] MA7d: integer & { x: string } triggers integer arm — boolean result", function()
	local decl = "--:: IntArmOnly<T> = match T { integer => boolean, _ => never }\n"
	-- Forward: IntArmOnly<integer & { x: string }> <: boolean
	local fwd_src = decl
		.. "local x --: IntArmOnly<integer & { x: string }>\n"
		.. "--: () -> boolean\n"
		.. "local function f() return x end\n"
	local ec_fwd = check_mod.check_string(fwd_src, "fuzz_eval_MA7d_fwd")
	T.eq(#ec_fwd.errors, 0, "MA7d-fwd: IntArmOnly<integer & {x:string}> <: boolean: expected 0, got " .. #ec_fwd.errors)
	-- Negative: integer should NOT be <: IntArmOnly<integer & { x: string }> (result is boolean, not integer)
	local neg_src = decl
		.. "local x --: integer\n"
		.. "--: () -> IntArmOnly<integer & { x: string }>\n"
		.. "local function f() return x end\n"
	local ec_neg = check_mod.check_string(neg_src, "fuzz_eval_MA7d_neg")
	T.eq(#ec_neg.errors, 1, "MA7d-neg: integer should NOT <: IntArmOnly<integer&{x:string}> (expected 1 error, got " .. #ec_neg.errors .. ")")
end)

-- MA7e: structural TABLE pattern with capture fires for intersection input
-- { x: %V } must match { x: integer } & { y: string } and bind V = integer.
-- Basis: intersection elimination — A & B <: A, so the pattern { x: %V } matches
-- member A = { x: integer } and V binds to integer.
T.it("[eval] MA7e: structural pattern { x: %V } matches intersection input (MA7e)", function()
	local src = [[
--:: FieldX_MA7e<T> = match T { { x: %V } => V }
--: () -> integer
local function f()
	--:: declare r = FieldX_MA7e<{ x: integer } & { y: string }>
	return r
end
]]
	local ec = check_mod.check_string(src, "fuzz_test_MA7e")
	T.eq(#ec.errors, 0, "MA7e: expected 0 errors, got " .. tostring(#ec.errors))
end)

-- MA7f: cross-member field capture after DNF flatten.
-- { x: integer } & { y: string } flattened to one merged table; pattern { x: %V, y: %W } => V
-- should bind V = integer (x comes from the first member).
T.it("[eval] MA7f: cross-member fields accessible after DNF flatten — { x:%V, y:%W } => V gives integer", function()
	local src = [[
--:: FieldXY_MA7f<T> = match T { { x: %V, y: %W } => V }
--: () -> integer
local function f()
	--:: declare r = FieldXY_MA7f<{ x: integer } & { y: string }>
	return r
end
]]
	local ec = check_mod.check_string(src, "fuzz_test_MA7f")
	T.eq(#ec.errors, 0, "MA7f: expected 0 errors, got " .. tostring(#ec.errors))
end)

-- MA7g: DNF handles A & (B | C) by distributing: (A & B) | (A & C).
-- match (integer & (string | boolean)) { integer => "yes", _ => "no" }:
-- to_dnf gives [integer & string, integer & boolean]; each term <: integer → "yes".
-- Result is "yes" | "yes" = "yes".
T.it("[eval] MA7g: A & (B|C) distributes via DNF — integer & (string|boolean) → integer arm fires", function()
	local src = [[
--:: IntOrWild_MA7g<T> = match T { integer => boolean, _ => string }
--: () -> boolean
local function f()
	--:: declare r = IntOrWild_MA7g<integer & (string | boolean)>
	return r
end
]]
	local ec = check_mod.check_string(src, "fuzz_test_MA7g")
	T.eq(#ec.errors, 0, "MA7g: expected 0 errors, got " .. tostring(#ec.errors))
end)

-- MX1: closed-member-lacks-field → never.
-- { x: integer } (closed) & { y: string } (closed) against pattern { x: %V } should give
-- integer (x comes from member 1; member 2 lacks x but member 1 has it — only
-- closed members that DON'T have the requested field short-circuit to never when
-- the intersection includes at least one member with it... wait, the semantics are:
-- if ANY closed member lacks the field, the field cannot exist in the intersection.
-- { x: integer } & { y: string }: member 2 is closed and lacks x → T_NEVER → pattern fails.
-- Result: FieldX_MX1<{ x: integer } & { y: string }> == never.
T.it("[eval] MX1: closed member lacking field makes intersection pattern fail → never", function()
	local src = [[
--:: FieldX_MX1<T> = match T { { x: %V } => V }
--: () -> never
local function f()
	--:: declare r = FieldX_MX1<{ x: integer } & { y: string }>
	return r
end
]]
	local ec = check_mod.check_string(src, "fuzz_test_MX1")
	T.eq(#ec.errors, 0, "MX1: expected 0 errors (result is never), got " .. tostring(#ec.errors))
end)

-- MX1b: open member lacking field is neutral (does not short-circuit).
-- { x: integer, ... } (open) & { y: string } (closed, lacks x): member 2 is closed and lacks x
-- → T_NEVER → pattern fails.
T.it("[eval] MX1b: closed member lacking field in mixed open/closed intersection → never", function()
	local src = [[
--:: FieldX_MX1b<T> = match T { { x: %V } => V }
--: () -> never
local function f()
	--:: declare r = FieldX_MX1b<{ x: integer, ...} & { y: string }>
	return r
end
]]
	local ec = check_mod.check_string(src, "fuzz_test_MX1b")
	T.eq(#ec.errors, 0, "MX1b: expected 0 errors (result is never), got " .. tostring(#ec.errors))
end)

-- MX1c: two open members, one has x → pattern succeeds.
-- { x: integer, ... } & { y: string, ... }: both open; member 1 has x → V = integer.
T.it("[eval] MX1c: open members — field from one open member succeeds", function()
	local src = [[
--:: FieldX_MX1c<T> = match T { { x: %V } => V }
--: () -> integer
local function f()
	--:: declare r = FieldX_MX1c<{ x: integer, ...} & { y: string, ...}>
	return r
end
]]
	local ec = check_mod.check_string(src, "fuzz_test_MX1c")
	T.eq(#ec.errors, 0, "MX1c: expected 0 errors (V=integer), got " .. tostring(#ec.errors))
end)

-- MA4r (random): for randomly generated tables, FieldX<T> == x-field-type when T has x,
-- or never when T lacks x.
-- Strategy: arb_table_type generates '{ x: T, ... }' strings from FIELD_NAMES = {x,y,z,n,s}.
-- We inspect the string for "x: <type>" to determine if x is present and what its base type is.
-- The match `{ x: %V }` is an open structural pattern — it matches any table with an x field.
--
-- Pattern for detection: look for "x: <base>" (not preceded by non-space, to avoid e.g. "nx:").
-- arb_table_type always produces "{ x: T, ... }" so "x: " can appear only at field boundaries.
-- Since field names are single chars (x,y,z,n,s) and format is "<name>: <type>", we match
-- the pattern "%f[%a]x: (%a+)" which matches "x" at a word boundary followed by ": <type>".
arb.it("[eval] MA4r: FieldX<T> == x-field-type (has x) or never (no x) for random tables",
	arb_table_type,
	function(t_str_arg)
		local t_str = t_str_arg --[[:! string]]
		-- Extract x-field base type from the string, if present.
		-- arb_table_type format: '{ [readonly ]<name>[?]: <base>, ... }'
		-- We look for "x[?]: <base>" — optional "?" before the colon.
		local x_type = string.match(t_str, "%f[%a]x%??:%s*(%a+)")
		local fieldx_str = "FieldX<" .. t_str .. ">"
		if x_type then
			-- T has field x: FieldX<T> must equal the x-field base type (bidirectional)
			assert(check_eq_fn(fieldx_str, x_type, MA_FIELDX_DECL),
				"FieldX<" .. t_str .. "> should equal " .. x_type .. " (x present), got mismatch")
		else
			-- T has no x field: FieldX<T> must equal never (bidirectional)
			assert(check_eq_fn(fieldx_str, "never", MA_FIELDX_DECL),
				"FieldX<" .. t_str .. "> should equal never (no x field), got mismatch")
		end
	end, { trials = 500 })

-- ── MA9: Composed match aliases ───────────────────────────────────────────────
-- Tests that a match alias whose result expression is another match alias
-- (Outer<T> = match T { %R => Inner<R> }) correctly defers and evaluates the
-- inner alias with the captured type.
-- Semantics verified: Inner is applied with the bound capture R; union inputs
-- distribute through the composition (since match distributes over union); and
-- three levels of nesting also work.

-- Declarations for MA9 tests.
local MA9_DECL = table.concat({
	"--:: Inner<T>  = match T { integer => string, string => integer }",
	"--:: Outer<T>  = match T { %R => Inner<R> }",
}, "\n") .. "\n"

-- MA9a: Outer<integer> == Inner<integer> == string (bidirectional, fn-return)
T.it("[eval] MA9a: Outer<integer> == string via Inner<integer> (bidirectional, fn-return)", function()
	T.ok(
		check_eq_fn("Outer<integer>", "string", MA9_DECL),
		"MA9a: Outer<integer> should equal string bidirectionally"
	)
end)

-- MA9b: Outer<string> == Inner<string> == integer (bidirectional, fn-return)
T.it("[eval] MA9b: Outer<string> == integer via Inner<string> (bidirectional, fn-return)", function()
	T.ok(
		check_eq_fn("Outer<string>", "integer", MA9_DECL),
		"MA9b: Outer<string> should equal integer bidirectionally"
	)
end)

-- MA9c: Outer<integer | string> == Inner<integer | string> == string | integer
-- Union distributes through the composed alias (outer match distributes over union,
-- then each member runs through Inner).
T.it("[eval] MA9c: Outer<integer | string> == string | integer (union distributes, fn-return)", function()
	local decl = table.concat({
		"--:: Inner2<T>  = match T { integer => string, string => boolean }",
		"--:: Outer2<T>  = match T { %R => Inner2<R> }",
	}, "\n") .. "\n"
	T.ok(
		check_eq_fn("Outer2<integer | string>", "string | boolean", decl),
		"MA9c: Outer2<integer|string> should equal string|boolean bidirectionally"
	)
end)

-- MA9d (negative): Outer<integer> != integer — the composition transforms the type.
-- If composition were a no-op, Outer<integer> would equal integer. It should not.
T.it("[eval] MA9d: Outer<integer> NOT integer — composition is not identity (1 error)", function()
	local src = MA9_DECL
		.. "local x --: Outer<integer>\n"
		.. "--: () -> integer\n"
		.. "local function f() return x end\n"
	local ec = check_mod.check_string(src, "fuzz_eval_MA9d")
	T.eq(#ec.errors, 1, "MA9d: Outer<integer> should NOT equal integer (expected 1 error, got " .. #ec.errors .. ")")
end)

return {}
