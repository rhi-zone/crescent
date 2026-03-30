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

-- ── Invariant 11: Function covariant return (grammar-level) ──────────────────
-- Assigning (A) -> A to (A) -> (A | B) must typecheck because A <: A | B.

arb.it("function: covariant return (grammar)",
	{ farb.arb_base_type, farb.arb_base_type },
	function(A_node, B_node)
		local A = farb.type_to_string(A_node)
		local B = farb.type_to_string(B_node)
		-- Pre-check: skip if either type annotation is ill-formed standalone
		if rejects("local x --: " .. A) then return end
		if rejects("local x --: " .. B) then return end
		-- (A) -> A is assignable to (A) -> (A | B)
		local src = table.concat({
			("--: (%s) -> %s"):format(A, A),
			"local f",
			("--: (%s) -> (%s | %s)"):format(A, A, B),
			"local g = f",
		}, "\n")
		assert(typechecks(src), "covariant return (grammar) failed: " .. src)
	end, { trials = 300 })

-- ── Invariant 12: Annotation soundness (positive) ────────────────────────────
-- A function annotated (T) -> T with body `return x` must always typecheck.
-- This catches regressions where the return-type check rejects a valid T.

arb.it("annotation soundness: (T)->T identity body typechecks",
	farb.arb_base_type,
	function(T_node)
		local TT  = farb.type_to_string(T_node)
		local src = table.concat({
			("--: (%s) -> %s"):format(TT, TT),
			"local function f(x) return x end",
		}, "\n")
		assert(typechecks(src), "identity body rejected: " .. src)
	end, { trials = 500 })

-- ── Invariant 13: Annotation soundness (negative) ────────────────────────────
-- A function annotated (A) -> B where A is not a subtype of B must reject
-- a body that returns its parameter directly.

arb.it("annotation soundness: (A)->B rejects when A not <: B",
	farb.arb_distinct_base_types,
	function(pair)
		-- arb_distinct_base_types guarantees pair[2] NOT <: pair[1].
		-- Use pair[2] as param (A) and pair[1] as return (B) so A NOT <: B.
		local A_node, B_node = pair[2], pair[1]
		local A = farb.type_to_string(A_node)
		local B = farb.type_to_string(B_node)
		-- Pre-check: skip ill-formed annotations
		if rejects("local x --: " .. A) then return end
		if rejects("local x --: " .. B) then return end
		-- (A) -> B with `return x` (x: A) should fail when A not <: B
		local src = table.concat({
			("--: (%s) -> %s"):format(A, B),
			"local function f(x) return x end",
		}, "\n")
		assert(rejects(src), "unsound annotation accepted: " .. src)
	end, { trials = 500 })

-- ── Invariant 16: Narrowing precision ────────────────────────────────────────
-- After `if type(x) == "T"`, x is exactly that primitive type, not a supertype.
-- Checks that narrowed type is usable AS the narrow type (not just as unknown/any).

arb.it("narrowing: type() guard gives exact primitive type",
	farb.arb_base_type,
	function(T_node)
		-- Only test types that type() can distinguish at runtime.
		local tag = T_node.tag
		local type_str_map = {
			["nil"]     = "nil",
			["boolean"] = "boolean",
			["number"]  = "number",
			["string"]  = "string",
			["integer"] = "number",  -- integer narrows to number via type()
		}
		local type_str = type_str_map[tag]
		if not type_str then return end  -- skip unsupported base types
		local TT = type_str  -- the narrowed-to type string
		-- x --: T | nil; after type(x)=="T", x should be usable as T
		local src = table.concat({
			("local x --: %s | nil"):format(farb.type_to_string(T_node)),
			('if type(x) == "%s" then'):format(type_str),
			("    local y --: %s = x"):format(TT),
			"end",
		}, "\n")
		assert(typechecks(src), "narrowing precision failed: " .. src)
	end, { trials = 300 })

-- ── Invariant 17: Generic constraint rejection ────────────────────────────────
-- <T: C>(T) -> T called with a value NOT assignable to C must be rejected.

arb.it("generic constraint: violating instantiation rejected",
	farb.arb_distinct_base_types,
	function(pair)
		local C_node, B_node = pair[1], pair[2]
		local C = farb.type_to_string(C_node)
		local v = farb.canonical_value(B_node)
		-- f: <T: C>(T) -> T; call with B value where B </: C → error
		local src = table.concat({
			("--: <T: %s>(T) -> T"):format(C),
			"local f",
			("f(%s)"):format(v),
		}, "\n")
		assert(rejects(src), "constraint violation not rejected: " .. src)
	end, { trials = 300 })

-- ── Invariant 18: Generic constraint acceptance ───────────────────────────────
-- <T: C>(T) -> T called with a value OF type C must typecheck.

arb.it("generic constraint: conforming instantiation accepted",
	farb.arb_base_type,
	function(T_node)
		local TT = farb.type_to_string(T_node)
		local v  = farb.canonical_value(T_node)
		-- f: <T: TT>(T) -> T; call with v of type TT → ok
		local src = table.concat({
			("--: <T: %s>(T) -> T"):format(TT),
			"local f",
			("f(%s)"):format(v),
		}, "\n")
		assert(typechecks(src), "conforming instantiation rejected: " .. src)
	end, { trials = 300 })

-- ── Invariant 19: Multi-return slot types ─────────────────────────────────────
-- Slot N of a multi-return is the declared type; extra slots are nil.

arb.it("multi-return: first slot has declared type",
	{ farb.arb_base_type, farb.arb_base_type },
	function(A_node, B_node)
		local A  = farb.type_to_string(A_node)
		local B  = farb.type_to_string(B_node)
		-- f: () -> (A, B); local x, y = f(); x should be A, y should be B
		local src = table.concat({
			("--: () -> (%s, %s)"):format(A, B),
			"local f",
			"local x, y = f()",
			("local _a --: %s = x"):format(A),
			("local _b --: %s = y"):format(B),
		}, "\n")
		if rejects("local _x --: " .. A) or rejects("local _y --: " .. B) then
			return  -- skip ill-formed types
		end
		assert(typechecks(src), "multi-return slot type failed: " .. src)
	end, { trials = 300 })

-- ── Invariant 20: Overload dispatch (acceptance) ─────────────────────────────
-- (A)->R1 & (B)->R2 called with a value of type A typechecks.

arb.it("overload: calling with first overload arg typechecks",
	farb.arb_distinct_base_types,
	function(pair)
		local A_node, B_node = pair[1], pair[2]
		local A = farb.type_to_string(A_node)
		local B = farb.type_to_string(B_node)
		local v = farb.canonical_value(A_node)
		-- f: (A)->nil & (B)->nil; call with A value → ok
		local src = table.concat({
			("--: ((%s) -> nil) & ((%s) -> nil)"):format(A, B),
			"local f",
			("f(%s)"):format(v),
		}, "\n")
		assert(typechecks(src), "overload acceptance failed: " .. src)
	end, { trials = 300 })

-- ── Invariant 21: Overload dispatch (rejection) ───────────────────────────────
-- (A)->R1 & (B)->R2 called with a value of type C (C not A and not B) is rejected.

arb.it("overload: calling with non-matching arg rejected",
	farb.arb_triple_distinct_base_types,
	function(triple)
		if not triple then return end
		local A_node, B_node, C_node = triple[1], triple[2], triple[3]
		local A = farb.type_to_string(A_node)
		local B = farb.type_to_string(B_node)
		local v = farb.canonical_value(C_node)
		local src = table.concat({
			("--: ((%s) -> nil) & ((%s) -> nil)"):format(A, B),
			"local f",
			("f(%s)"):format(v),
		}, "\n")
		assert(rejects(src), "overload non-match not rejected: " .. src)
	end, { trials = 300 })

-- ── Invariant 22: Enum table typechecks ──────────────────────────────────────
-- A table literal whose fields are all integer or all string literals is a
-- valid Lua expression the typechecker must accept without errors.

arb.it("enum: table with integer or string literal fields typechecks",
	farb.arb_enum_table,
	function(tbl_src)
		local src = "local E = " .. tbl_src
		assert(typechecks(src), "enum table rejected: " .. src)
	end, { trials = 200 })

-- ── Invariant 23: Interface oracle E2E ───────────────────────────────────────
-- Declaring `--:: A: B` makes A a declared subtype of B.
-- A is declared to implement B by having all B's fields plus extras.
-- A value of type A can be assigned to a variable of type B (oracle hit).

arb.it("interface oracle: A: B declaration allows A where B expected",
	farb.arb_base_type,
	function(T_node)
		local T = farb.type_to_string(T_node)
		-- HasB has a single field of type T.
		-- MyType: HasB is a subtype of HasB, adding an extra field y.
		-- This is structurally valid (MyType has fld:T which satisfies HasB).
		local src = table.concat({
			"--:: HasB = { fld: " .. T .. " }",
			"--:: MyType: HasB = { fld: " .. T .. ", extra: integer }",
			"local val --: MyType",
			"local z --: HasB = val",
		}, "\n")
		assert(typechecks(src), "interface oracle E2E failed: " .. src)
	end, { trials = 300 })

-- ── Invariant 24: EachField KeepAll partial program typechecks ────────────────
-- $EachField<{ x: T }, KeepAll> is assignable to { x: T } and vice versa.

arb.it("EachField KeepAll: $EachField<{x:T}, KeepAll> compatible with {x:T}",
	farb.arb_base_type,
	function(T_node)
		local TT = farb.type_to_string(T_node)
		local src = table.concat({
			"--:: KeepAll<D> = match D { _ => { D } }",
			"local x --: $EachField<{ x: " .. TT .. " }, KeepAll>",
			"local y --: { x: " .. TT .. " } = x",
		}, "\n")
		assert(typechecks(src), "EachField KeepAll partial program failed: " .. src)
	end, { trials = 300 })

-- ── P1: Pick/Omit correctness (grammar-tier) ─────────────────────────────────
-- Pick<T, Keys> contains only the named fields; accessing others is an error.

T.it("P1a: Pick<{name,age}, \"name\">.name accessible — 0 errors", function()
	local src = [[
--:: PickKey<Keys, D> = match D { { key: %K, ...%Rest } => match K { Keys => { D }, _ => {} }, _ => {} }
--:: Pick<T, Keys> = $EachField<T, PickKey<Keys>>
--: () -> string
local function get_name()
  local p --: Pick<{ name: string, age: integer }, "name">
  return p.name
end
]]
	local ec = check.check_string(src, "fuzz_test_P1a")
	T.eq(#ec.errors, 0, "P1a: expected 0 errors, got " .. #ec.errors)
end)

T.it("P1b: Pick<{name,age}, \"name\">.age not accessible — 1 error", function()
	local src = [[
--:: PickKey<Keys, D> = match D { { key: %K, ...%Rest } => match K { Keys => { D }, _ => {} }, _ => {} }
--:: Pick<T, Keys> = $EachField<T, PickKey<Keys>>
--: () -> integer
local function get_age()
  local p --: Pick<{ name: string, age: integer }, "name">
  return p.age
end
]]
	local ec = check.check_string(src, "fuzz_test_P1b")
	T.eq(#ec.errors, 1, "P1b: expected 1 error, got " .. #ec.errors)
end)

-- ── P4: $Throw inside match — only fires for selected arms ────────────────────

T.it("P4a: CheckedId<integer> — integer arm, no throw — 0 errors", function()
	local src = [[
--:: CheckedId<T> = match T {
--::   integer => integer,
--::   _ => $Throw<"expected integer">
--:: }
local x --: CheckedId<integer>
local _ok --: integer = x
]]
	local ec = check.check_string(src, "fuzz_test_P4a")
	T.eq(#ec.errors, 0, "P4a: expected 0 errors, got " .. #ec.errors)
end)

T.it("P4b: CheckedId<string> — _ arm, throw fires — 1 error", function()
	local src = [[
--:: CheckedId<T> = match T {
--::   integer => integer,
--::   _ => $Throw<"expected integer">
--:: }
local x --: CheckedId<string>
]]
	local ec = check.check_string(src, "fuzz_test_P4b")
	T.eq(#ec.errors, 1, "P4b: expected 1 error, got " .. #ec.errors)
end)

-- ── P5: generic defaults in programs ─────────────────────────────────────────

T.it("P5a: Wrap<integer> defaults U to string — 0 errors", function()
	local src = [[
--:: Wrap<T, U = string> = { value: T, label: U }
local x --: Wrap<integer>
local _a --: { value: integer, label: string } = x
]]
	local ec = check.check_string(src, "fuzz_test_P5a")
	T.eq(#ec.errors, 0, "P5a: expected 0 errors, got " .. #ec.errors)
end)

T.it("P5b: Wrap<integer, boolean> overrides default — 0 errors", function()
	local src = [[
--:: Wrap<T, U = string> = { value: T, label: U }
local x --: Wrap<integer, boolean>
local _a --: { value: integer, label: boolean } = x
]]
	local ec = check.check_string(src, "fuzz_test_P5b")
	T.eq(#ec.errors, 0, "P5b: expected 0 errors, got " .. #ec.errors)
end)

T.it("P5c: Wrap<integer> with wrong label type — 1 error", function()
	local src = [[
--:: Wrap<T, U = string> = { value: T, label: U }
local x --: Wrap<integer>
local _wrong --: { value: integer, label: integer } = x
]]
	local ec = check.check_string(src, "fuzz_test_P5c")
	T.eq(#ec.errors, 1, "P5c: expected 1 error, got " .. #ec.errors)
end)

-- ── A2c/A2d: Readonly field write rejection (grammar-level) ──────────────────
-- FLAG_READONLY is a write-site constraint enforced in constrain.lua.
-- Reading a readonly field is always fine; writing must be rejected.

T.it("A2c: writing to a readonly field is rejected — 1 error", function()
	local src = [[
local t --: { readonly x: integer }
t.x = 42
]]
	local ec = check.check_string(src, "fuzz_test_A2c")
	T.eq(#ec.errors, 1, "A2c: expected 1 error, got " .. #ec.errors)
end)

T.it("A2d: reading a readonly field is allowed — 0 errors", function()
	local src = [[
local t --: { readonly x: integer }
local _read --: integer = t.x
]]
	local ec = check.check_string(src, "fuzz_test_A2d")
	T.eq(#ec.errors, 0, "A2d: expected 0 errors, got " .. #ec.errors)
end)

-- ── P3: setmetatable meta slot programs ───────────────────────────────────────
-- setmetatable<T, MT>(t: T, mt: MT) -> T & { #...MT }
-- The result carries all meta slots from MT spread into the intersection type.

T.it("P3a: setmetatable result carries __index meta slot — 0 errors", function()
	local src = [[
local t = setmetatable({}, { __index = function(_, k) return k end })
]]
	local ec = check.check_string(src, "fuzz_test_P3a")
	T.eq(#ec.errors, 0, "P3a: expected 0 errors, got " .. #ec.errors)
end)

T.it("P3b: setmetatable with typed Vec and VecMeta — 0 errors", function()
	local src = [[
--:: Vec = { x: integer }
--:: VecMeta = { __add: (Vec, Vec) -> Vec }
local mt --: VecMeta
local v --: Vec
local result = setmetatable(v, mt)
]]
	local ec = check.check_string(src, "fuzz_test_P3b")
	T.eq(#ec.errors, 0, "P3b: expected 0 errors, got " .. #ec.errors)
end)

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
