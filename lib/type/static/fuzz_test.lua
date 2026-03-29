-- lib/type/static/fuzz_test.lua
-- Grammar-level (E2E) fuzz suite for the crescent typechecker.
-- Programs are run through check_string (parse + constrain + unify + error reporting).
-- Uses arb.it for structural generation with integrated shrinking.
--
-- Run with:
--   luajit lib/test/cli.lua lib/type/static/fuzz_test.lua
--   PROP_SEED=12345 luajit lib/test/cli.lua lib/type/static/fuzz_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local check = require("lib.type.static.check")
local arb   = require("lib.test.arb")
local T     = require("lib.test.assert")
local farb  = require("lib.type.static.fuzz_arb")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function typechecks(src)
	local err_ctx = check.check_string(src, "fuzz_test")
	return #err_ctx.errors == 0
end

local function rejects(src)
	local err_ctx = check.check_string(src, "fuzz_test")
	return #err_ctx.errors > 0
end

-- ── Invariant 1: Reflexivity (base) ──────────────────────────────────────────
-- A literal value of base type T is assignable where T is expected.

arb.it("subtyping: every base type is a subtype of itself",
	farb.arb_base_type,
	function(T_node)
		local TT  = farb.type_to_string(T_node)
		local v   = farb.canonical_value(T_node)
		local src = ("--: %s\nlocal x = %s"):format(TT, v)
		assert(typechecks(src), "base reflexivity failed: " .. src)
	end, { trials = 500 })

-- ── Invariant 2: Reflexivity (complex) ───────────────────────────────────────
-- For any type T: local x --[[: T]]; local y --[[: T]] = x must typecheck.
-- Uses the two-variable pattern — no literal value of T needed.

arb.it("subtyping: every type is a subtype of itself",
	farb.arb_type,
	function(T_node)
		local TT  = farb.type_to_string(T_node)
		-- If the type itself is ill-formed (e.g. intersection field conflict), skip.
		if rejects("local x --: " .. TT) then return end
		local src = ("local x --: %s\nlocal y --: %s = x"):format(TT, TT)
		assert(typechecks(src), "reflexivity failed: " .. src)
	end, { trials = 500 })

-- ── Invariant 3: Union introduction (base) ───────────────────────────────────
-- A literal value of type A is assignable to A | B.

arb.it("union intro: A assignable to A | B (base)",
	{ farb.arb_base_type, farb.arb_base_type },
	function(A_node, B_node)
		local A   = farb.type_to_string(A_node)
		local B   = farb.type_to_string(B_node)
		local v   = farb.canonical_value(A_node)
		local src = ("--: %s | %s\nlocal x = %s"):format(A, B, v)
		assert(typechecks(src), "union intro (base) failed: " .. src)
	end, { trials = 500 })

-- ── Invariant 4: Union introduction (complex) ────────────────────────────────
-- For any types A, B: a variable of type A is assignable to A | B.

arb.it("union intro: A assignable to A | B (complex)",
	{ farb.arb_type, farb.arb_type },
	function(A_node, B_node)
		local A   = farb.type_to_string(A_node)
		local B   = farb.type_to_string(B_node)
		-- If A or B is ill-formed (e.g. intersection field conflict, or deep type
		-- exceeds parser stack limit), skip.
		if rejects("local a --: " .. A) then return end
		if rejects("local b --: " .. B) then return end
		local src = ("local a --: %s\nlocal z --: %s | %s = a"):format(A, A, B)
		assert(typechecks(src), "union intro (complex) failed: " .. src)
	end, { trials = 500 })

-- ── Invariant 5: Function — correct argument accepted ────────────────────────
-- Calling a function with the correct arg type always typechecks.

arb.it("function: correct arg accepted",
	{ farb.arb_base_type, farb.arb_base_type },
	function(A_node, B_node)
		local A   = farb.type_to_string(A_node)
		local B   = farb.type_to_string(B_node)
		local v   = farb.canonical_value(A_node)
		local src = ("--: (%s) -> %s\nlocal f\nf(%s)"):format(A, B, v)
		assert(typechecks(src), "correct arg rejected: " .. src)
	end, { trials = 500 })

-- ── Invariant 6: Function — wrong argument rejected ───────────────────────────
-- Calling a function annotated (A)->nil with a value of type B (B not <: A)
-- must produce a type error.

arb.it("function: wrong arg rejected",
	farb.arb_distinct_base_types,
	function(pair)
		local A_node, B_node = pair[1], pair[2]
		local A   = farb.type_to_string(A_node)
		local v   = farb.canonical_value(B_node)
		local src = ("--: (%s) -> nil\nlocal f\nf(%s)"):format(A, v)
		assert(rejects(src), "wrong arg not rejected: " .. src)
	end, { trials = 500 })

-- ── Invariant 7: Narrowing ────────────────────────────────────────────────────
-- After `if x then`, the type of x excludes nil.

arb.it("narrowing: non-nil branch excludes nil",
	farb.arb_base_type,
	function(T_node)
		local TT  = farb.type_to_string(T_node)
		local src = table.concat({
			("local x --: %s | nil"):format(TT),
			"if x then",
			("    local y --: %s = x"):format(TT),
			"end",
		}, "\n")
		assert(typechecks(src), "narrowing failed: " .. src)
	end, { trials = 500 })

-- ── Invariant 8: Literal precision ────────────────────────────────────────────
-- A literal integer n has type n (not just integer).

arb.it("literal: assigned to specific literal type",
	arb.int(0, 99),
	function(n)
		local src_ok  = ("--: %d\nlocal x = %d"):format(n, n)
		local src_bad = ("--: %d\nlocal x = %d"):format(n, n + 1)
		assert(typechecks(src_ok),  "literal self-assignment rejected: " .. src_ok)
		assert(rejects(src_bad),    "literal mismatch not rejected: "    .. src_bad)
	end, { trials = 200 })

-- ── Invariant 9: Generic instantiation ───────────────────────────────────────
-- A generic identity function <T>(T) -> T called with a value of type A
-- returns a value of type A.

arb.it("generic: instantiation preserves type",
	farb.arb_base_type,
	function(T_node)
		local TT  = farb.type_to_string(T_node)
		local v   = farb.canonical_value(T_node)
		local src = table.concat({
			"--: <T>(T) -> T",
			"local id",
			("--: %s\nlocal x = id(%s)"):format(TT, v),
		}, "\n")
		assert(typechecks(src), "generic instantiation rejected: " .. src)
	end, { trials = 300 })

-- ── Invariant 10: No false positives on valid corpus ─────────────────────────

local valid_corpus = {
	"local x = 1",
	"local x = 1.5",
	"local x = true",
	"local x = false",
	'local x = "hello"',
	"local x = nil",
	"--: integer\nlocal x = 1",
	"--: number\nlocal x = 1.5",
	'--: string\nlocal x = "hello"',
	"--: boolean\nlocal x = true",
	"local function f(x) return x end",
	"local function f(x) return x + 1 end",
	"--: (integer) -> integer\nlocal function double(x) return x * 2 end",
	"local t = { x = 1, y = 2 }",
	"local t = { x = 1 }; local y = t.x",
	"local x = 1; local y = x + 2",
	"local x, y = 1, 2",
	"local x = 1 + 2",
	'local x = "a" .. "b"',
	"local x = not true",
	"--: string | nil\nlocal x",
	"local x --: string | nil\nif x then local y = x end",
	"--: integer | string\nlocal x = 1",
	"local function f(x, y) return x + y end",
	"local M = {}\nfunction M:greet(name) return name end",
}

arb.it("no false positives on valid corpus",
	arb.map(arb.int(1, #valid_corpus), function(i) return valid_corpus[i] end),
	function(src)
		assert(typechecks(src), "valid program rejected: " .. src)
	end, { trials = #valid_corpus * 10 })

-- ── Performance gate ──────────────────────────────────────────────────────────

T.it("performance: ≥500 programs/sec throughput", function()
	local gen_mod = require("lib.test.gen")
	local rng     = gen_mod.make_rng(0xc0ffee)
	local corpus  = {}
	for _ = 1, 1000 do
		local T_node = farb.arb_base_type.generate(rng, 4)
		local v      = farb.canonical_value(T_node)
		corpus[#corpus + 1] = ("--: %s\nlocal x = %s"):format(
			farb.type_to_string(T_node), v)
	end

	local t0 = os.clock()
	for _, src in ipairs(corpus) do
		check.check_string(src, "perf_test")
	end
	local t1 = os.clock()

	local elapsed    = t1 - t0
	local throughput = #corpus / elapsed
	T.ok(
		throughput >= 500,
		("throughput %.0f programs/sec (threshold: 500, elapsed: %.3fs)"):format(
			throughput, elapsed
		)
	)
end)
