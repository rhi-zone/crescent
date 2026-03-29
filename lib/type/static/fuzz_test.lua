-- lib/type/static/fuzz_test.lua
-- Invariant-based fuzz suite for the crescent typechecker.
--
-- Run with:
--   luajit lib/test/cli.lua lib/type/static/fuzz_test.lua
--   FUZZ_SEED=12345 luajit lib/test/cli.lua lib/type/static/fuzz_test.lua
--
-- Each fuzz.it encodes a type system invariant that must hold for all inputs.
-- Programs are generated structurally (not by byte mutation) using a PRNG seeded
-- from the fuzz input bytes, so the mutation engine explores the seed space.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local check = require("lib.type.static.check")
local fuzz  = require("lib.test.fuzz")
local farb  = require("lib.type.static.fuzz_arb")

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Derive a 32-bit seed from a fuzz input string (mix bytes into a LCG state).
local function seed_from_input(input)
	local s = 0x12345678
	for i = 1, #input do
		s = (s * 1664525 + string.byte(input, i) + 1013904223) % (2^32)
	end
	if s == 0 then s = 0xdeadbeef end
	return s
end

-- Minimal LCG PRNG (same parameters as fuzz.lua / arb.lua).
local LCG_MOD = 2^32
local LCG_A   = 1664525
local LCG_C   = 1013904223

local function make_rng(seed)
	local state = math.floor(seed) % LCG_MOD
	if state == 0 then state = 12345 end
	local rng = {}
	function rng:next()
		state = (state * LCG_A + LCG_C) % LCG_MOD
		return state
	end
	function rng:float() return self:next() / LCG_MOD end
	function rng:int(lo, hi)
		if lo >= hi then return lo end
		return lo + (self:next() % (hi - lo + 1))
	end
	function rng:bool() return self:next() % 2 == 0 end
	return rng
end

-- Check a source string: returns true if 0 type errors, false otherwise.
local function typechecks(src)
	local err_ctx = check.check_string(src, "fuzz_test")
	return #err_ctx.errors == 0
end

-- Check a source string: returns true if ≥1 type errors, false otherwise.
local function rejects(src)
	local err_ctx = check.check_string(src, "fuzz_test")
	return #err_ctx.errors > 0
end

-- ── Seeds for the mutation engine ─────────────────────────────────────────────
-- Each seed encodes an integer (as decimal text) that will be used to drive
-- structural program generation. The mutation engine will flip bytes in these
-- strings, exploring the seed space without generating arbitrary Lua text.

local SEEDS = {}
for i = 1, 20 do SEEDS[i] = tostring(i * 997) end

-- ── Invariant 1: Subtyping reflexivity ───────────────────────────────────────
-- Every value of type T is accepted where T is expected.

fuzz.it("subtyping: every type is a subtype of itself", function(input)
	local rng = make_rng(seed_from_input(input))
	local T = farb.arb_base_type(rng)
	local v = farb.arb_value_of_type(rng, T)
	-- Use preceding-line annotation to avoid inline assignment parse issues.
	local src = ("--: %s\nlocal x = %s"):format(T, v)
	assert(typechecks(src), "value of type T rejected where T expected: " .. src)
end, { seeds = SEEDS, iters = 500 })

-- ── Invariant 2: Union introduction ──────────────────────────────────────────
-- A value of type A is assignable to A | B.

fuzz.it("union intro: A assignable to A | B", function(input)
	local rng = make_rng(seed_from_input(input))
	local A = farb.arb_base_type(rng)
	local B = farb.arb_base_type(rng)
	local v = farb.arb_value_of_type(rng, A)
	local src = ("--: %s | %s\nlocal x = %s"):format(A, B, v)
	assert(typechecks(src), "union intro failed: " .. src)
end, { seeds = SEEDS, iters = 500 })

-- ── Invariant 3a: Function type soundness — correct arg accepted ──────────────
-- Calling a function with the correct arg type always typechecks.

fuzz.it("function: correct arg accepted", function(input)
	local rng = make_rng(seed_from_input(input))
	local A = farb.arb_base_type(rng)
	local B = farb.arb_base_type(rng)
	local v = farb.arb_value_of_type(rng, A)
	local src = ("--: (%s) -> %s\nlocal f\nf(%s)"):format(A, B, v)
	assert(typechecks(src), "correct arg rejected: " .. src)
end, { seeds = SEEDS, iters = 500 })

-- ── Invariant 3b: Function type soundness — wrong arg rejected ────────────────
-- Calling a function annotated (A) -> nil with a value of type B (B ~= A)
-- must produce a type error. We use distinct types so there is no subtyping
-- relationship between A and B.

fuzz.it("function: wrong arg rejected", function(input)
	local rng = make_rng(seed_from_input(input))
	local A, B = farb.arb_distinct_types(rng)
	local v = farb.arb_value_of_type(rng, B)
	local src = ("--: (%s) -> nil\nlocal f\nf(%s)"):format(A, v)
	assert(rejects(src), "wrong arg not rejected: " .. src)
end, { seeds = SEEDS, iters = 500 })

-- ── Invariant 4: Narrowing correctness ───────────────────────────────────────
-- After `if x then`, the type of x excludes nil.
-- We declare x as T | nil and inside the truthy branch assign it to y: T.

fuzz.it("narrowing: non-nil branch excludes nil", function(input)
	local rng = make_rng(seed_from_input(input))
	local T = farb.arb_base_type(rng)
	local src = table.concat({
		("local x --: %s | nil"):format(T),
		"if x then",
		("    local y --: %s = x"):format(T),
		"end",
	}, "\n")
	assert(typechecks(src), "narrowing failed: " .. src)
end, { seeds = SEEDS, iters = 500 })

-- ── Invariant 5: Literal type precision ──────────────────────────────────────
-- A literal integer n has type n (not just integer).
-- Assigning n where n is expected: accepted.
-- Assigning n+1 where n is expected: rejected.

fuzz.it("literal: assigned to specific literal type", function(input)
	local rng = make_rng(seed_from_input(input))
	local n = rng:int(0, 99)  -- keep n+1 ≤ 100 for safety
	local src_ok  = ("--: %d\nlocal x = %d"):format(n, n)
	local src_bad = ("--: %d\nlocal x = %d"):format(n, n + 1)
	assert(typechecks(src_ok),  "literal self-assignment rejected: " .. src_ok)
	assert(rejects(src_bad),    "literal mismatch not rejected: "    .. src_bad)
end, { seeds = SEEDS, iters = 200 })

-- ── Invariant 6: Generic instantiation preserves type ────────────────────────
-- A generic identity function <T>(T) -> T called with a value of type A
-- returns a value of type A.

fuzz.it("generic: instantiation preserves type", function(input)
	local rng = make_rng(seed_from_input(input))
	local T = farb.arb_base_type(rng)
	local v = farb.arb_value_of_type(rng, T)
	local src = table.concat({
		"--: <T>(T) -> T",
		"local id",
		("--: %s\nlocal x = id(%s)"):format(T, v),
	}, "\n")
	assert(typechecks(src), "generic instantiation rejected: " .. src)
end, { seeds = SEEDS, iters = 300 })

-- ── Invariant 7: No false positives on valid corpus ───────────────────────────
-- A known set of valid programs must all typecheck with 0 errors.

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

fuzz.it("no false positives on valid corpus", function(input)
	local rng = make_rng(seed_from_input(input))
	local idx = rng:int(1, #valid_corpus)
	local src = valid_corpus[idx]
	assert(typechecks(src), "valid program rejected: " .. src)
end, { seeds = SEEDS, iters = #valid_corpus * 10 })

-- ── Performance gate ──────────────────────────────────────────────────────────
-- Run 1000 check_string calls on a fixed corpus and assert ≥ 500 programs/sec.

local T = require("lib.test.assert")
T.it("performance: ≥500 programs/sec throughput", function()
	local corpus = {}
	local rng = make_rng(0xc0ffee)
	for _ = 1, 1000 do
		local base = farb.arb_base_type(rng)
		local val  = farb.arb_value_of_type(rng, base)
		corpus[#corpus + 1] = ("--: %s\nlocal x = %s"):format(base, val)
	end

	local t0 = os.clock()
	for i = 1, #corpus do
		check.check_string(corpus[i], "perf_test")
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
