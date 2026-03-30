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
]]

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- typechecks: returns true iff the program produces no errors.
local function typechecks(src)
	local ec = check_mod.check_string(src, "fuzz_eval")
	return #ec.errors == 0
end

-- check_sub: build a program asserting A <: B via assignment; returns true iff 0 errors.
local function check_sub(a_str, b_str)
	local src = FIXED_SCOPE
		.. "local _fuzz_a --: " .. a_str .. "\n"
		.. "local _fuzz_b --: " .. b_str .. " = _fuzz_a\n"
	return typechecks(src)
end

-- check_eq: assert A == B (bidirectional subtype check).
local function check_eq(a_str, b_str)
	return check_sub(a_str, b_str) and check_sub(b_str, a_str)
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

-- ── EachField invariants (500 trials each) ────────────────────────────────────

-- 1. KeepAll identity: $EachField<T, KeepAll> == T (bidirectional)
arb.it("[eval] EachField KeepAll identity: EachField<T, KeepAll> == T",
	arb_table_type,
	function(t_str)
		local ef_str = "$EachField<" .. t_str .. ", KeepAll>"
		assert(check_sub(t_str, ef_str),
			"T <: EachField<T,KeepAll> failed for T = " .. t_str)
		assert(check_sub(ef_str, t_str),
			"EachField<T,KeepAll> <: T failed for T = " .. t_str)
	end, { trials = 500 })

-- 2. DropAll: $EachField<T, DropAll> <: {} (empty closed table)
arb.it("[eval] EachField DropAll: EachField<T, DropAll> <: {}",
	arb_table_type,
	function(t_str)
		local ef_str = "$EachField<" .. t_str .. ", DropAll>"
		assert(check_sub(ef_str, "{}"),
			"EachField<T,DropAll> <: {} failed for T = " .. t_str)
	end, { trials = 500 })

-- 3. MakeOptional→MakeRequired round-trip == T (bidirectional)
arb.it("[eval] EachField MakeOptional->MakeRequired round-trip == T",
	arb_table_type,
	function(t_str)
		local rt_str = "$EachField<$EachField<" .. t_str .. ", MakeOptional>, MakeRequired>"
		assert(check_sub(t_str, rt_str),
			"T <: MakeRequired(MakeOptional(T)) failed for T = " .. t_str)
		assert(check_sub(rt_str, t_str),
			"MakeRequired(MakeOptional(T)) <: T failed for T = " .. t_str)
	end, { trials = 500 })

-- 4. MakeReadonly→MakeWritable round-trip == T (bidirectional)
arb.it("[eval] EachField MakeReadonly->MakeWritable round-trip == T",
	arb_table_type,
	function(t_str)
		local rt_str = "$EachField<$EachField<" .. t_str .. ", MakeReadonly>, MakeWritable>"
		assert(check_sub(t_str, rt_str),
			"T <: MakeWritable(MakeReadonly(T)) failed for T = " .. t_str)
		assert(check_sub(rt_str, t_str),
			"MakeWritable(MakeReadonly(T)) <: T failed for T = " .. t_str)
	end, { trials = 500 })

-- 5. KeepAll union distributivity: $EachField<T1 | T2, KeepAll> == T1 | T2
arb.it("[eval] EachField KeepAll distributivity over union",
	arb_union_table,
	function(t_str)
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
	function(t_str)
		local ci_str = "CaptureId<" .. t_str .. ">"
		assert(check_sub(t_str, ci_str),
			"T <: CaptureId<T> failed for T = " .. t_str)
		assert(check_sub(ci_str, t_str),
			"CaptureId<T> <: T failed for T = " .. t_str)
	end, { trials = 500 })

-- 7. Wildcard constant: WildConst<T> <: integer (wildcard always gives integer)
arb.it("[eval] match WildConst<T> <: integer for any T",
	arb_base_type,
	function(t_str)
		local wc_str = "WildConst<" .. t_str .. ">"
		assert(check_sub(wc_str, "integer"),
			"WildConst<T> <: integer failed for T = " .. t_str)
	end, { trials = 500 })

-- 8. Union capture round-trip: CaptureId<T1 | T2> == T1 | T2
arb.it("[eval] match CaptureId<T1 | T2> == T1 | T2",
	{ arb_base_type, arb_base_type },
	function(t1, t2)
		local union_str = t1 .. " | " .. t2
		local ci_str = "CaptureId<" .. union_str .. ">"
		assert(check_sub(union_str, ci_str),
			"T1|T2 <: CaptureId<T1|T2> failed for T = " .. union_str)
		assert(check_sub(ci_str, union_str),
			"CaptureId<T1|T2> <: T1|T2 failed for T = " .. union_str)
	end, { trials = 500 })

-- ── Oracle invariants (2000 trials each, algebra-level type construction) ─────

-- Bare typing context for oracle tests (no prelude, no parsing).
local function make_ctx()
	local pool = intern_mod.new()
	local ctx  = types_mod.new_ctx(pool)
	ctx.err               = { errors = {} }
	ctx.lit_cache         = {}
	ctx.declared_subtypes = {}
	return ctx
end

local function make_named_tid(ctx, name_str)
	local nid = intern_mod.intern(ctx.pool, name_str)
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
		local a_tid, a_nid = make_named_tid(ctx, "OracleA" .. tostring(i % 20))
		local b_tid, b_nid = make_named_tid(ctx, "OracleB" .. tostring(i % 20))
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
	local NAMES = { "TypeA", "TypeB", "TypeC", "TypeD", "TypeE" }
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
		local a_tid = make_named_tid(ctx, "PlaceholderA" .. tostring(i % 30))
		local b_tid = make_named_tid(ctx, "PlaceholderB" .. tostring(i % 30))
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
local x --: TResult
local _e1a --: integer = x
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E1a")
	T.eq(#ec.errors, 0, "EachField<never,KeepAll>|integer == integer: expected 0 errors, got " .. tostring(#ec.errors))
end)

-- E1b: $EachField<never, KeepAll> resolves without crashing (no errors in
-- a program that simply declares and uses the type as never).
T.it("[eval] E1: EachField<never, KeepAll> used as never — no crash", function()
	local src = FIXED_SCOPE .. [[
--:: TNever = $EachField<never, KeepAll>
local x --: TNever
local _e1b --: never = x
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E1b")
	T.eq(#ec.errors, 0, "EachField<never,KeepAll> as never: expected 0 errors, got " .. tostring(#ec.errors))
end)

-- ── E6: $Throw/$Catch interaction ────────────────────────────────────────────

-- E6a: $Catch returns default when $Throw is present
T.it("[eval] E6a: $Catch<$Throw<msg>, integer> == integer (0 errors)", function()
	local src = FIXED_SCOPE .. [[
--:: Caught = $Catch<$Throw<"test error">, integer>
local x --: Caught
local _e6a --: integer = x
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E6a")
	T.eq(#ec.errors, 0, "Catch<Throw<msg>,integer>==integer: expected 0 errors, got " .. tostring(#ec.errors))
end)

-- E6b: $Catch passes through non-throw types
T.it("[eval] E6b: $Catch<string, integer> == string (0 errors)", function()
	local src = FIXED_SCOPE .. [[
--:: NotCaught = $Catch<string, integer>
local x --: NotCaught
local _e6b --: string = x
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E6b")
	T.eq(#ec.errors, 0, "Catch<string,integer>==string: expected 0 errors, got " .. tostring(#ec.errors))
end)

-- E6c: $Throw without $Catch produces exactly 1 diagnostic containing the message
T.it("[eval] E6c: $Throw<msg> without catch produces 1 error with the message", function()
	local src = FIXED_SCOPE .. [[
--:: Bad = $Throw<"this is wrong">
local x --: Bad
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
local x --: WithDefault<integer>
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
local x --: WithDefault<integer, boolean>
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
local x --: WithDefault<integer>
--: () -> { a: integer, b: boolean }
local function f() return x end
]]
	local ec = check_mod.check_string(src, "fuzz_eval_E7c")
	T.eq(#ec.errors, 1, "WithDefault<integer> b mismatch: expected 1 error, got " .. tostring(#ec.errors))
end)

-- ── E4: all-fields pattern correctness ───────────────────────────────────────
-- Fixed tests for { ...[%K]: %V } distribution over named-field and indexer tables.
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

return {}
