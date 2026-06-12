-- End-to-end corpus runner for crescent.slice.v1 — Pass 5 (the lowering frontend).
--
-- docs/agnostic-static-analysis-crescent-slice.md §8 Pass 5: the LOAD-BEARING
-- corpus assertion is now the LOWERED path — every fixture goes
--   source text → crescent_slice_lower.lower → substrate A.check → verdict
-- rather than a hand-built derivation. corpus_test.lua keeps the hand-built
-- derivations as unit tests of the evidence methods (they assert the methods
-- accept the IDEALIZED graph); THIS file asserts what real lowering from source
-- actually produces.
--
-- THE FINDING (the point of the pass). Under real lowering, only the fixtures
-- whose CHECKED SYNTAX sits entirely inside §5's subset are CLEAN. The rest are
-- OUT-OF-SUBSET because their source uses forms the hand-built graphs silently
-- assumed away — stdlib calls (`tonumber`/`string.sub`/`math.floor`/`pairs`),
-- arithmetic/concat operators (`1/n`, `s+v`, `..`), named parameters
-- (`node: HamtNode`), `t[e] = v` dynamic-key writes, unannotated closures, and
-- field-path narrowing (`if node.left then`). Each is a real §5 boundary, not a
-- checker soundness gap: in EVERY fixture the in-subset claims the lowering DOES
-- emit are 0-rejection / 0-unknown (the substrate accepts every generated claim).
-- The divergence is the honest data Pass 5 exists to surface (§9.8).
--
-- Each fixture asserts (a) the verdict class the lowering assigns, and (b) that
-- every requested claim ACCEPTS (no rejection, no unknown) — the soundness
-- invariant that holds across all 11 regardless of subset coverage.

local T = require("lib.test.assert")
local A = require("lib.type.analysis")
local S = require("lib.type.analysis.crescent_slice")
local L = require("lib.type.analysis.crescent_slice_lower")

--: () -> SemanticsRegistry
local function reg()
	local r = A.new_registry()
	S.register(r)
	return r
end

-- A measured fixture outcome: the verdict class, the requested-claim count, the
-- accepted/rejected/unknown counts, the diagnostic count, and the marker tags.
-- This is the only data the assertions read — restated locally so the test
-- typechecks without the deep alias chain (Ty/AliasEnv) the LowerResult rides.
--:: Outcome = { expected: string, requested: integer, acc: integer, rej: integer, unk: integer, diags: integer, constructs: { [integer]: string } }

-- Lower a corpus fixture from source, run it through the substrate, and reduce
-- both to a plain Outcome (counts + verdict + marker tags).
--: (string) -> Outcome
local function lower_fixture(name)
	local path = "lib/type/analysis/corpus/fixture_" .. name .. ".lua"
	local fh = assert(io.open(path, "r"))
	local src = fh:read("*a") --[[: string ]]
	fh:close()
	-- The LowerResult and CheckResult both ride cross-module aliases (Ty, Id,
	-- Claim, …) whose deep resolution this file does not import; the test reads
	-- only verdict/counts/markers, so it narrows both to local `unknown`-element
	-- views at the seam (the substrate has already type-checked the real shapes).
	local res = L.lower(src, path) --[[: { state: AnalysisState, requested: { [integer]: { space: string, key: string } }, expected: string, markers: { [integer]: { construct: string } } } | nil ]]
	if not res then error("lower failed for " .. name) end
	local requested = res.requested
	local chk = A.check({ state = res.state, requested_claims = requested,
		semantics_registry = reg(), trust_policy = nil }) --[[: { accepted_claims: { [string]: unknown }, rejected_claims: { [string]: unknown }, unknown_claims: { [string]: unknown }, diagnostics: { [integer]: unknown } } | nil ]]
	if not chk then error("check returned nil") end
	local acc, rej, unk = 0, 0, 0
	for _ in pairs(chk.accepted_claims) do acc = acc + 1 end
	for _ in pairs(chk.rejected_claims) do rej = rej + 1 end
	for _ in pairs(chk.unknown_claims) do unk = unk + 1 end
	local constructs = {} --[[: { [integer]: string } ]]
	for _, m in ipairs(res.markers) do constructs[#constructs + 1] = m.construct end
	return {
		expected = res.expected, requested = #requested,
		acc = acc, rej = rej, unk = unk, diags = #chk.diagnostics, constructs = constructs,
	}
end

-- Does the outcome's marker set contain a construct tag (exact or prefix)?
--: (Outcome, string) -> boolean
local function has_construct(o, tag)
	for _, c in ipairs(o.constructs) do
		if c == tag or c:find(tag, 1, true) == 1 then return true end
	end
	return false
end

-- The soundness invariant common to every fixture: every requested claim accepts;
-- none is rejected or left unknown. (A rejection would be a real lowering bug —
-- the lowering only emits a claim it has already verified is in-subset and sound.)
--: (Outcome) -> nil
local function assert_sound(o)
	T.eq(o.rej, 0, "no requested claim is rejected (the lowering only emits verified-sound claims)")
	T.eq(o.unk, 0, "no requested claim is left unknown (the graph is complete)")
	T.eq(o.acc, o.requested, "every requested claim accepts")
	T.eq(o.diags, 0, "the substrate reports no diagnostics")
end

-- ── In-subset fixtures: CLEAN ────────────────────────────────────────────────

T.describe("corpus e2e: fixture_local_return_narrowing — CLEAN from source", function()
	T.it("nil-guard post-exit narrowing (if not task then return) lowers and checks clean", function()
		local o = lower_fixture("local_return_narrowing")
		T.eq(o.expected, "CLEAN", "fully within §5 (unannotated-local synth + nil-guard narrowing)")
		T.eq(#o.constructs, 0, "no out-of-subset markers")
		assert_sound(o)
		T.ok(o.requested > 0, "the lowering emitted load-bearing claims (not a vacuous CLEAN)")
	end)
end)

T.describe("corpus e2e: fixture_union_alias_over_named_types — CLEAN from source", function()
	T.it("union alias + common-field access on AnyCmd lowers and checks clean", function()
		local o = lower_fixture("union_alias_over_named_types")
		T.eq(o.expected, "CLEAN", "fully within §5 (union Ty + synth_index distribution)")
		assert_sound(o)
		T.ok(o.requested > 0, "emitted load-bearing claims")
	end)
end)

-- ── Out-of-subset fixtures: OUT-OF-SUBSET, with the specific §5 boundary ──────
-- These are the Pass-5 FINDINGS: the hand-built corpus_test graphs assumed away
-- exactly these constructs. Each assertion names the construct the lowering hit.

T.describe("corpus e2e: fixture_boolean_narrowing — operator typing (v2.3) makes it CLEAN", function()
	T.it("`n == 0 and 1 / n < 0` now types as boolean (operator front, §6.7.1) — CLEAN", function()
		local o = lower_fixture("boolean_narrowing")
		-- v2.3: operator typing landed (§6.7.1). `1 / n` synthesizes `number`,
		-- `1 / n < 0` and `n == 0` synthesize `boolean`, and `boolean and boolean`
		-- is `boolean` (the existing synth_and_or_not rule), checking against the
		-- declared `(number) -> boolean`. The fixture is now fully within §5.
		T.eq(o.expected, "CLEAN", "operator typing closes the `/` and `<` boundary")
		T.eq(#o.constructs, 0, "no out-of-subset markers")
		assert_sound(o)
		T.ok(o.requested > 0, "emitted load-bearing claims")
	end)
end)

T.describe("corpus e2e: fixture_tonumber_return_type — stdlib-call boundary", function()
	T.it("tonumber/string.sub/math.floor are unbound (no stdlib model in the lowering)", function()
		local o = lower_fixture("tonumber_return_type")
		T.eq(o.expected, "OUT-OF-SUBSET", "stdlib callees are not modeled as values in Γ")
		T.ok(has_construct(o, "unbound-name:tonumber")
			or has_construct(o, "unbound-name:string")
			or has_construct(o, "unbound-name:math"), "marked unbound stdlib name")
		assert_sound(o)
	end)
end)

T.describe("corpus e2e: fixture_pairs_return_leak — empty-fresh-table dynamic write (§6.10) — CLEAN", function()
	T.it("`merged = {}; merged[k] = v` now lowers (empty-rec write target = unknown)", function()
		local o = lower_fixture("pairs_return_leak")
		-- §6.10: the fresh-table build idiom `local merged = {}` then a dynamic write
		-- `merged[k] = v` is now IN subset. `index_write_target` over an EMPTY closed
		-- rec returns `unknown` (no declared field ⇒ no constraint; sound because the
		-- empty-rec READ rule never admits a value, so the write licenses no unsound
		-- read). With `+` already in subset (§6.7.1) and `sum_values(merged)` typing
		-- (the empty rec `<: { [string]: integer }` holds — the arg check accepts), the
		-- fixture is now fully within §5. Its own header requires "Accepts with 0
		-- errors"; CLEAN is the correct verdict.
		T.eq(o.expected, "CLEAN", "the empty-fresh-table dynamic write closes the last boundary")
		T.eq(#o.constructs, 0, "no out-of-subset markers")
		assert_sound(o)
		T.ok(o.requested > 0, "the pairs loop-var + write claims were emitted and accepted")
	end)
end)

T.describe("corpus e2e: fixture_coinductive_recursive_types — field-path narrowing CLEAN (§6.11)", function()
	T.it("v2.7: `if node.left then tree_sum(node.left)` narrows the PATH — the fixture is whole-file CLEAN", function()
		local o = lower_fixture("coinductive_recursive_types")
		-- v2.7 (§6.11, field-path narrowing): `if node.left then` now refines the
		-- PATH `node.left : TreeNode | nil` → `TreeNode` (the opaque-name truthy
		-- decomposition over the μ-unfolded field type). `tree_sum(node.left)` reads
		-- the refined `TreeNode` (the path read inside the call argument, before any
		-- invalidation), so `TreeNode <: TreeNode` holds. The §9.8 deferral whose
		-- trigger fired on this exact fixture is closed: FINDINGS → CLEAN, 0 markers,
		-- 0 rejections. The soundness boundary (the refinement dies after any
		-- call/write) is the §9.18 invalidation fence; here the guarded read precedes
		-- the call within the same statement, so it reads the live refinement.
		T.eq(o.expected, "CLEAN", "field-path narrowing closes the boundary — whole-file CLEAN")
		T.eq(#o.constructs, 0, "no out-of-subset markers")
		assert_sound(o)
	end)
end)

T.describe("corpus e2e: fixture_table_construction_widening — empty-fresh-table write (§6.10) — CLEAN", function()
	T.it("`insns = {}; insns[i] = {...}` now lowers (empty-rec write target = unknown)", function()
		local o = lower_fixture("table_construction_widening")
		-- §6.10: the integer-keyed sequential build into a fresh `{}` is the same
		-- empty-fresh-table dynamic-write idiom; `index_write_target` returns `unknown`
		-- for the empty closed rec, so each `insns[i] = {...}` write accepts. The
		-- fixture is now fully within §5 and its header requires acceptance.
		T.eq(o.expected, "CLEAN", "the empty-fresh-table dynamic write closes the boundary")
		T.eq(#o.constructs, 0, "no out-of-subset markers")
		assert_sound(o)
	end)
end)

T.describe("corpus e2e: fixture_hamt_recursion — forward alias boundary", function()
	T.it("named param `node: HamtNode` now lowers (v2.1); the forward-alias ref is the §5 boundary", function()
		local o = lower_fixture("hamt_recursion")
		-- v2.1: `node: HamtNode` (named param) is now IN subset (§6.5.1). The fixture
		-- remains OUT-OF-SUBSET on the FORWARD-referenced alias: `Interior`
		-- references `HamtNode` before its own `--::` line, and the per-file alias
		-- env is built top-to-bottom, so the name is unresolved at that point. A
		-- two-pass alias env is increment-2 work, not this increment.
		T.eq(o.expected, "OUT-OF-SUBSET", "a forward-referenced alias is outside §5 (single-pass alias env)")
		T.ok(has_construct(o, "unknown-type-name"), "marked the unresolved forward-alias boundary")
		assert_sound(o)
	end)
end)

T.describe("corpus e2e: fixture_cast_not_inference_source — concat operator boundary", function()
	T.it("`tostring(n) .. \":\"` (concat + unbound tostring) is the §5 boundary", function()
		local o = lower_fixture("cast_not_inference_source")
		T.eq(o.expected, "OUT-OF-SUBSET", "string concatenation is outside §5")
		T.ok(has_construct(o, "operator-concat") or has_construct(o, "unbound-name:tostring"),
			"marked the concat / unbound boundary")
		assert_sound(o)
	end)
end)

T.describe("corpus e2e: fixture_cross_module_type_alias — field-path-narrow boundary", function()
	T.it("v2.4: closures lower; the next §5 boundary is field-path narrowing", function()
		local o = lower_fixture("cross_module_type_alias")
		-- v2.4 (§6.8): the inner `wait = function() end` closure now lowers
		-- (expression-position closure synthesis). The fixture remains OUT-OF-SUBSET
		-- on the NEXT boundary: `ep = epoll` rebinds, the nil-guard narrows the
		-- VARIABLE `ep`, and after the assignment-inside-if `ep.wait()` reads `wait`
		-- off a binding the v1 flow layer does not refine to the post-assignment
		-- record (field-path / assignment-in-branch narrowing, §9.8). An honest
		-- `no-such-field` boundary, NOT a soundness bug — every requested claim holds.
		T.eq(o.expected, "OUT-OF-SUBSET", "field-path / assignment-in-branch narrowing is outside §5")
		T.ok(has_construct(o, "no-such-field") or has_construct(o, "unbound-name"),
			"marked the field-path-narrow boundary, NOT unannotated-closure")
		T.ok(not has_construct(o, "unannotated-closure"), "the inner closure now lowers (v2.4)")
		T.ok(not has_construct(o, "named-param"), "named-param is no longer a boundary (v2.1 lowers it)")
		assert_sound(o)
	end)
end)

T.describe("corpus e2e: fixture_closure_param_typing — multi-return lowers to CLEAN", function()
	T.it("v2.5: `return node, function() end` lowers (the §6.5.5 tuple) — the fixture is now CLEAN", function()
		local o = lower_fixture("closure_param_typing")
		-- v2.5 (§6.9): the `return node, function() end` multi-return statement now
		-- lowers (the §6.5.5 tuple built at the return site, §6.9.3) — `multi-return`
		-- was the LAST out-of-subset boundary, so with it gone the fixture goes
		-- whole-file CLEAN. `with_scope` is unannotated (capture path, no return check),
		-- and v1's flow-insensitive synthesis types the closure args loosely (`unknown`
		-- params), so no claim rejects. The documented "typing w causes c1 nil" gap is
		-- a PRECISION limitation of the loose synthesis (c1 binds the call result, a
		-- single slot), not a soundness error — every requested claim accepts.
		T.eq(o.expected, "CLEAN", "the multi-return was the last boundary; the fixture is now whole-file CLEAN")
		T.ok(not has_construct(o, "multi-return"), "the multi-return now lowers (v2.5)")
		T.ok(not has_construct(o, "unannotated-closure"), "the closures lower (v2.4)")
		assert_sound(o)
	end)
end)

-- ── The headline assertion: the honest split ─────────────────────────────────

T.describe("corpus e2e: the honest 11-fixture split under real lowering (v2.7)", function()
	T.it("7 CLEAN, 0 FINDINGS, 4 OUT-OF-SUBSET, 0 rejections anywhere", function()
		-- v2.7 (§6.11, field-path narrowing): coinductive moved FINDINGS → CLEAN —
		-- `if node.left then tree_sum(node.left)` now refines the PATH (the opaque-name
		-- truthy decomposition), closing the §9.8 deferral. With it gone there are zero
		-- findings.
		-- v2.6 (§6.10, the empty-fresh-table dynamic write): pairs_return_leak and
		-- table_construction_widening BOTH moved OUT-OF-SUBSET → CLEAN — the
		-- `merged = {}; merged[k] = v` / `insns = {}; insns[i] = {...}` fresh-table
		-- build idiom now lowers (`index_write_target` over an empty closed rec returns
		-- `unknown`, no constraint to violate; sound because the empty-rec READ rule
		-- never admits a value). Both fixtures' headers require acceptance.
		-- v2.5 had moved closure_param_typing → CLEAN (the §6.5.5 return-site tuple);
		-- v2.3 had moved boolean_narrowing → CLEAN (operators).
		-- These fixtures lower WITHOUT the injected stdlib cap (no `{ stdlib = true }`),
		-- so tonumber/cast_not_inference_source stay OUT-OF-SUBSET on unbound stdlib
		-- names — the caps-first posture (the cap is the survey's, not a default global).
		local names = {
			"boolean_narrowing", "local_return_narrowing", "union_alias_over_named_types",
			"tonumber_return_type", "pairs_return_leak", "coinductive_recursive_types",
			"table_construction_widening", "hamt_recursion", "cast_not_inference_source",
			"cross_module_type_alias", "closure_param_typing",
		}
		local clean, oos, findings, total_rej = 0, 0, 0, 0
		for _, n in ipairs(names) do
			local o = lower_fixture(n)
			if o.expected == "CLEAN" then clean = clean + 1
			elseif o.expected == "OUT-OF-SUBSET" then oos = oos + 1
			elseif o.expected == "FINDINGS" then findings = findings + 1 end
			total_rej = total_rej + o.rej
		end
		T.eq(clean, 7, "7 fixtures fully within §5 (the v2.6 six + coinductive via field-path narrowing, §6.11)")
		T.eq(findings, 0, "0 findings — the coinductive field-path-narrow finding closed (§6.11)")
		T.eq(oos, 4, "4 fixtures hit a real §5 boundary (stdlib/forward-alias/cast/assignment-in-branch)")
		T.eq(total_rej, 0, "ZERO rejections across all 11 — every in-subset claim the lowering emits is sound")
	end)
end)

-- ── §6.7 increment v2.3 statement-form tests (inline sources) ────────────────

local S2 = require("lib.type.analysis.crescent_slice")

-- Lower an inline source and reduce to an Outcome (with optional stdlib cap).
--: (string, boolean) -> Outcome
local function lower_src(src, with_stdlib)
	local opts --[[: { stdlib: boolean } | nil ]]
	if with_stdlib then opts = { stdlib = true } end
	local res = L.lower(src, "inline.lua", opts) --[[: { state: AnalysisState, requested: { [integer]: { space: string, key: string } }, expected: string, markers: { [integer]: { construct: string } } } | nil ]]
	if not res then error("lower failed") end
	local chk = A.check({ state = res.state, requested_claims = res.requested,
		semantics_registry = reg(), trust_policy = nil }) --[[: { accepted_claims: { [string]: unknown }, rejected_claims: { [string]: unknown }, unknown_claims: { [string]: unknown }, diagnostics: { [integer]: unknown } } | nil ]]
	if not chk then error("check nil") end
	local acc, rej, unk = 0, 0, 0
	for _ in pairs(chk.accepted_claims) do acc = acc + 1 end
	for _ in pairs(chk.rejected_claims) do rej = rej + 1 end
	for _ in pairs(chk.unknown_claims) do unk = unk + 1 end
	local constructs = {} --[[: { [integer]: string } ]]
	for _, m in ipairs(res.markers) do constructs[#constructs + 1] = m.construct end
	return { expected = res.expected, requested = #res.requested,
		acc = acc, rej = rej, unk = unk, diags = #chk.diagnostics, constructs = constructs }
end

T.describe("slice v2.3: operator typing lowers and checks", function()
	T.it("a function over arithmetic + concat + comparison is CLEAN", function()
		local o = lower_src([[
--: (integer, integer) -> boolean
local function both_positive(a, b)
  return a > 0 and b > 0
end
return { both_positive = both_positive }
]], false)
		T.eq(o.expected, "CLEAN", "comparisons and `and` over integers type as boolean")
		assert_sound(o)
	end)
end)

T.describe("slice v2.3: unannotated function (params unknown, return body-synth)", function()
	T.it("an unannotated local function lowers (no `unannotated-function` marker)", function()
		local o = lower_src([[
local function ident(x)
  return x
end
return { ident = ident }
]], false)
		T.eq(o.expected, "CLEAN", "unannotated function types (params unknown, return synthesized)")
		assert_sound(o)
	end)
end)

T.describe("slice v2.3: multi-assignment / swap (parallel binding)", function()
	T.it("`local a, b = e1, e2` and swap `a, b = b, a` lower clean", function()
		local o = lower_src([[
--: (integer, integer) -> integer
local function f(p, q)
  local a, b = p, q
  a, b = b, a
  return a + b
end
return { f = f }
]], false)
		T.eq(o.expected, "CLEAN", "multi-assign + swap + arithmetic all in subset")
		assert_sound(o)
	end)
end)

T.describe("slice v2.3: stdlib cap (caps-first, injected)", function()
	T.it("with the stdlib cap, tonumber/string.sub/math.floor type; without it, they are unbound", function()
		local src = [[
--: (string) -> integer
local function parse(s)
  local n = tonumber(string.sub(s, 1, 2))
  if not n then return 0 end
  return math.floor(n)
end
return { parse = parse }
]]
		local with_cap = lower_src(src, true)
		T.eq(with_cap.expected, "CLEAN", "the injected stdlib cap types tonumber/string.sub/math.floor")
		assert_sound(with_cap)
		local without = lower_src(src, false)
		T.eq(without.expected, "OUT-OF-SUBSET", "absent the cap, stdlib names stay unbound (no silent global)")
	end)
end)

T.describe("slice v2.3: method call desugars to o.m(o, args)", function()
	T.it("`o:m(a)` checks against the method's self-first signature", function()
		local o = lower_src([[
--:: Counter = { add: (self: Counter, n: integer) -> integer }
--: (Counter) -> integer
local function use(c)
  return c:add(5)
end
return { use = use }
]], false)
		T.eq(o.expected, "CLEAN", "o:add(5) desugars to o.add(o, 5), checking o ⇐ self")
		assert_sound(o)
	end)
end)

-- ── §6.8 increment v2.4: expression-position closures ────────────────────────

T.describe("slice v2.4: synthesis-mode closure (params unknown, return synthesized)", function()
	T.it("an anonymous `function() return 1 end` in expression position lowers clean", function()
		local o = lower_src([[
local mk = function() return 1 end
return { mk = mk }
]], false)
		T.eq(o.expected, "CLEAN", "a bare anonymous closure synthesizes (params unknown, return body-synthesized)")
		T.ok(not has_construct(o, "unannotated-closure"), "no unannotated-closure marker (v2.4)")
		assert_sound(o)
	end)
end)

T.describe("slice v2.4: check-mode closure (expected param types pushed inward)", function()
	T.it("a closure flowing into an annotated callback slot checks under the pushed param types", function()
		-- the higher-order call `apply(function(n) return n end)` flows the closure
		-- into the `(integer) -> integer` callback param; check-mode pushes `integer`
		-- onto the closure's `n`, and the body `return n` checks against the return.
		local o = lower_src([[
--: ((integer) -> integer) -> integer
local function apply(cb)
  return cb(2)
end
--: () -> integer
local function run()
  return apply(function(n) return n end)
end
return { run = run }
]], false)
		T.eq(o.expected, "CLEAN", "check-mode pushes the callback param type onto the closure")
		T.ok(not has_construct(o, "unannotated-closure"), "no unannotated-closure marker")
		assert_sound(o)
	end)
end)

T.describe("slice v2.4: a closure bound to an annotated local checks under check-mode", function()
	T.it("`local f --: (integer) -> integer = function(x) return x end` checks", function()
		local o = lower_src([[
--: () -> integer
local function run()
  --: (integer) -> integer
  local f = function(x) return x end
  return f(3)
end
return { run = run }
]], false)
		T.eq(o.expected, "CLEAN", "the annotated-local boundary routes the closure through check-mode")
		assert_sound(o)
	end)
end)

-- ── §6.7.2 increment v2.4: stdlib globals model (injected cap) ────────────────

T.describe("slice v2.4: extended stdlib globals (type/setmetatable/pcall/table/package)", function()
	T.it("with the cap, type/pcall/table.insert/package.loaded resolve; without it, unbound", function()
		local src = [[
--: (unknown) -> string
local function describe(v)
  local t = type(v)
  local ok, _ = pcall(describe, v)
  if ok then return t end
  return t
end
return { describe = describe }
]]
		local with_cap = lower_src(src, true)
		T.eq(with_cap.expected, "CLEAN", "type/pcall resolve via the injected stdlib cap")
		assert_sound(with_cap)
		local without = lower_src(src, false)
		T.eq(without.expected, "OUT-OF-SUBSET", "absent the cap, type/pcall stay unbound (caps-first)")
	end)
end)

-- ── §6.7.2 increment v2.4: require returns the module's value type ────────────

-- Lower an entry source with a read_file cap that serves a fixed map of module
-- sources (the cross-module require test harness).
--: (string, { [string]: string }, boolean) -> Outcome
local function lower_with_modules(entry, modules, with_stdlib)
	--: (string) -> (string | nil, string | nil)
	local function read_file(path)
		local s = modules[path]
		if s == nil then return nil, "no such module" end
		return s, nil
	end
	local opts --[[: { read_file: (string) -> (string | nil, string | nil), stdlib?: boolean } ]] = { read_file = read_file }
	if with_stdlib then opts.stdlib = true end
	local res = L.lower(entry, "entry.lua", opts) --[[: { state: AnalysisState, requested: { [integer]: { space: string, key: string } }, expected: string, markers: { [integer]: { construct: string } } } | nil ]]
	if not res then error("lower failed") end
	local chk = A.check({ state = res.state, requested_claims = res.requested,
		semantics_registry = reg(), trust_policy = nil }) --[[: { accepted_claims: { [string]: unknown }, rejected_claims: { [string]: unknown }, unknown_claims: { [string]: unknown }, diagnostics: { [integer]: unknown } } | nil ]]
	if not chk then error("check nil") end
	local acc, rej, unk = 0, 0, 0
	for _ in pairs(chk.accepted_claims) do acc = acc + 1 end
	for _ in pairs(chk.rejected_claims) do rej = rej + 1 end
	for _ in pairs(chk.unknown_claims) do unk = unk + 1 end
	local constructs = {} --[[: { [integer]: string } ]]
	for _, m in ipairs(res.markers) do constructs[#constructs + 1] = m.construct end
	return { expected = res.expected, requested = #res.requested,
		acc = acc, rej = rej, unk = unk, diags = #chk.diagnostics, constructs = constructs }
end

T.describe("slice v2.4: require(\"lib.x\") binds the module's synthesized value type", function()
	T.it("`x.f(...)` cross-module is checkable against the M-table rec", function()
		local exp = [[
local M = {}
--: (integer) -> integer
function M.add(x) return x + 1 end
--: (integer) -> integer
function M.dbl(x) return x * 2 end
return M
]]
		local entry = [[
--: () -> integer
local function run()
  local lib = require("lib.mathx")
  return lib.add(lib.dbl(3))
end
return { run = run }
]]
		local o = lower_with_modules(entry, { ["lib/mathx.lua"] = exp }, false)
		T.eq(o.expected, "CLEAN", "the M-table fields add/dbl flow across the require boundary")
		assert_sound(o)
	end)

	T.it("a require to a module whose field does NOT exist is an honest no-such-field", function()
		local exp = [[
local M = {}
--: (integer) -> integer
function M.add(x) return x + 1 end
return M
]]
		local entry = [[
--: () -> integer
local function run()
  local lib = require("lib.mathx")
  return lib.missing(3)
end
return { run = run }
]]
		local o = lower_with_modules(entry, { ["lib/mathx.lua"] = exp }, false)
		T.eq(o.expected, "OUT-OF-SUBSET", "reading an absent module field is an honest boundary")
		T.ok(has_construct(o, "no-such-field"), "marked no-such-field on the missing member")
		assert_sound(o)
	end)

	T.it("a require to a non-readable / non-lib module falls through (no silent success)", function()
		local entry = [[
local lib = require("lib.absent")
return {}
]]
		local o = lower_with_modules(entry, {}, false)
		-- `lib.absent` is unreadable → the require does not resolve to a module type;
		-- `local lib = require(...)` binds nothing (the call stays unbound-name:require).
		T.ok(o.expected ~= "CLEAN" or o.requested == 0,
			"an unresolved require never silently types as a module value")
		assert_sound(o)
	end)

	T.it("M.f = expr assignment accumulates into the module type too", function()
		local exp = [[
local M = {}
--: (integer) -> integer
M.inc = function(x) return x + 1 end
return M
]]
		local entry = [[
--: () -> integer
local function run()
  local lib = require("lib.assignmod")
  return lib.inc(7)
end
return { run = run }
]]
		local o = lower_with_modules(entry, { ["lib/assignmod.lua"] = exp }, false)
		T.eq(o.expected, "CLEAN", "M.f = function(...) accumulates field f into the module rec")
		assert_sound(o)
	end)
end)

-- ── §9.14 audit-round-3 regression tests ────────────────────────────────────

-- F1: module-table reassignment must reset the accumulated rec (was: stale fields
-- cross the require boundary as phantom fields — unsound).

T.describe("audit-round-3 F1: module-table rebind resets accumulation", function()
	T.it("M = {} after M.f accumulation: consumer call on phantom field is NOT CLEAN", function()
		-- The exporting module rebinds M to a fresh empty table AFTER accumulating f.
		-- At runtime lib.f does not exist; the checker must not accept lib.f(1).
		-- Post-fix: the module value type is {} (the rebound table), not {f: ...}.
		local exp = [[
local M = {}
--: (integer) -> integer
function M.f(x) return x + 1 end
M = {}
return M
]]
		local entry = [[
--: () -> integer
local function run()
  local lib = require("lib.re")
  return lib.f(1)
end
return { run = run }
]]
		local o = lower_with_modules(entry, { ["lib/re.lua"] = exp }, false)
		-- Post-fix: either FINDINGS (type-mismatch on phantom call) or OUT-OF-SUBSET
		-- (no-such-field honest boundary). CLEAN is the unsound pre-fix behaviour.
		T.ok(o.expected ~= "CLEAN", "phantom-field cross-require is NOT CLEAN after F1 fix")
		assert_sound(o)
	end)

	T.it("M = N (rebind to another table): consumer reads N's fields, not M's accumulated ones", function()
		-- M accumulates f; then M is rebound to N which has g. The export has g only.
		local exp = [[
local M = {}
--: (integer) -> integer
function M.f(x) return x + 1 end
--: { g: integer }
local N = { g = 5 }
M = N
return M
]]
		local entry = [[
--: () -> integer
local function run()
  local lib = require("lib.re2")
  return lib.f(1)
end
return { run = run }
]]
		local o = lower_with_modules(entry, { ["lib/re2.lua"] = exp }, false)
		T.ok(o.expected ~= "CLEAN", "phantom-field f is NOT CLEAN when M was rebound to N (which has g, not f)")
		assert_sound(o)
	end)

	T.it("M = {} before ANY accumulation: module exports empty table (no fields)", function()
		-- Rebind before accumulation — module truly has no fields.
		local exp = [[
local M = {}
M = {}
--: (integer) -> integer
function M.f(x) return x + 1 end
return M
]]
		-- Here f IS added after the rebind, so it should be present.
		local entry = [[
--: () -> integer
local function run()
  local lib = require("lib.re3")
  return lib.f(1)
end
return { run = run }
]]
		local o = lower_with_modules(entry, { ["lib/re3.lua"] = exp }, false)
		-- f is added AFTER the rebind, so it should accumulate onto the new M.
		T.eq(o.expected, "CLEAN", "f accumulated AFTER rebind IS present in the module type")
		assert_sound(o)
	end)

	T.it("no reassignment: plain M.f accumulation still yields CLEAN (regression guard)", function()
		local exp = [[
local M = {}
--: (integer) -> integer
function M.f(x) return x + 1 end
return M
]]
		local entry = [[
--: () -> integer
local function run()
  local lib = require("lib.mathx2")
  return lib.f(1)
end
return { run = run }
]]
		local o = lower_with_modules(entry, { ["lib/mathx2.lua"] = exp }, false)
		T.eq(o.expected, "CLEAN", "plain accumulation without rebind still works (F1 fix does not regress)")
		assert_sound(o)
	end)
end)

-- F2: fewer-param closure flowing into a wider fn slot must be CLEAN (not rejected).
-- A closure with FEWER declared params than the expected fn type is valid Lua —
-- extra call args are discarded at runtime. check_func_expr must accept it.

T.describe("audit-round-3 F2: fewer-param closure into wider fn slot is valid Lua", function()
	T.it("1-param closure into (integer,integer)->nil slot: valid — must be CLEAN", function()
		local src = [[
--: ((integer, integer) -> nil) -> nil
local function apply(f) return nil end
--: () -> nil
local function main()
  return apply(function(a) return nil end)
end
return { main = main }
]]
		local o = lower_src(src, false)
		T.eq(o.expected, "CLEAN", "1-param closure into 2-param slot is valid Lua (extra args discarded)")
		assert_sound(o)
	end)

	T.it("0-param closure into (integer)->nil slot: valid — must be CLEAN", function()
		local src = [[
--: ((integer) -> nil) -> nil
local function call_f(f) return nil end
--: () -> nil
local function main()
  return call_f(function() return nil end)
end
return { main = main }
]]
		local o = lower_src(src, false)
		T.eq(o.expected, "CLEAN", "0-param closure into 1-param slot is valid Lua")
		assert_sound(o)
	end)

	T.it("exact-arity closure still CLEAN (F2 fix must not break exact case)", function()
		local src = [[
--: ((integer) -> nil) -> nil
local function apply(f) return nil end
--: () -> nil
local function main()
  return apply(function(a) return nil end)
end
return { main = main }
]]
		local o = lower_src(src, false)
		T.eq(o.expected, "CLEAN", "exact-arity closure still CLEAN after F2 fix")
		assert_sound(o)
	end)

	T.it("MORE-params closure into (integer)->nil: rejected (closure needs a param the slot doesn't supply)", function()
		local src = [[
--: ((integer) -> nil) -> nil
local function apply(f) return nil end
--: () -> nil
local function main()
  return apply(function(a, b) return nil end)
end
return { main = main }
]]
		local o = lower_src(src, false)
		-- The closure declares MORE params than the expected type supplies.
		-- This stays a type-mismatch finding (the spec rejection).
		T.ok(o.expected == "FINDINGS" or o.expected == "OUT-OF-SUBSET",
			"more-params closure is correctly rejected (not a CLEAN false-accept)")
	end)
end)

-- F3: simple direct alias `local A = M; A.f = …` propagates into M's rec.

T.describe("audit-round-3 F3: simple alias A = M propagates field accumulation to M", function()
	T.it("local A = M; A.f = …; return M — f is accessible cross-module", function()
		local exp = [[
local M = {}
local A = M
--: (integer) -> integer
function A.f(x) return x + 1 end
return M
]]
		local entry = [[
--: () -> integer
local function run()
  local lib = require("lib.aliasmod")
  return lib.f(1)
end
return { run = run }
]]
		local o = lower_with_modules(entry, { ["lib/aliasmod.lua"] = exp }, false)
		T.eq(o.expected, "CLEAN", "field added via a direct alias propagates to M (F3 trivial case)")
		assert_sound(o)
	end)

	T.it("direct alias A = M; A.f assignment form too", function()
		local exp = [[
local M = {}
local A = M
--: (integer) -> integer
A.inc = function(x) return x + 1 end
return M
]]
		local entry = [[
--: () -> integer
local function run()
  local lib = require("lib.aliasmod2")
  return lib.inc(7)
end
return { run = run }
]]
		local o = lower_with_modules(entry, { ["lib/aliasmod2.lua"] = exp }, false)
		T.eq(o.expected, "CLEAN", "A.f = fn assignment via direct alias propagates to M (F3 trivial case)")
		assert_sound(o)
	end)
end)

-- ── §6.9 increment v2.5: the multi-return / dynamic-index family ──────────────

T.describe("slice v2.5: dynamic-index READ over an indexer", function()
	T.it("`t[k]` over `{ [string]: integer }` yields the element type — CLEAN", function()
		local o = lower_src([[
--: ({ [string]: integer }, string) -> integer
local function get(t, k)
  return t[k]
end
return { get = get }
]], false)
		T.eq(o.expected, "CLEAN", "indexer read `t[k]` resolves to the value type V (no dynamic-index marker)")
		T.ok(not has_construct(o, "dynamic-index"), "the dynamic-index read is now in subset")
		assert_sound(o)
	end)
end)

T.describe("slice v2.5: dynamic-index READ over a closed rec (union | nil)", function()
	T.it("`r[k]` over a closed rec yields union(field types) | nil — CLEAN against unknown", function()
		local o = lower_src([[
--: ({ a: integer, b: integer }, string) -> integer | nil
local function pick(r, k)
  return r[k]
end
return { pick = pick }
]], false)
		-- r[k] : (integer | integer) | nil = integer | nil <: integer | nil.
		T.eq(o.expected, "CLEAN", "closed-rec dynamic read is union(fields)|nil (the closed-row promise)")
		T.ok(not has_construct(o, "dynamic-index"), "closed-rec dynamic read is in subset")
		assert_sound(o)
	end)
end)

T.describe("slice v2.5: multi-return STATEMENT — check against the declared return", function()
	T.it("`return v, nil` against `(integer, string | nil)` lowers (the §6.5.5 tuple) — CLEAN", function()
		local o = lower_src([[
--: (integer) -> (integer, string | nil)
local function ok_pair(v)
  return v, nil
end
return { ok_pair = ok_pair }
]], false)
		T.eq(o.expected, "CLEAN", "the joint tuple (integer, nil) <: (integer, string | nil)")
		T.ok(not has_construct(o, "multi-return"), "the multi-return statement is now in subset")
		assert_sound(o)
	end)
	T.it("`return nil, msg` against a union-of-tuples return member lowers — CLEAN", function()
		local o = lower_src([[
--: (integer) -> (integer, boolean) | (nil, string)
local function maybe(v)
  return nil, "boom"
end
return { maybe = maybe }
]], false)
		T.eq(o.expected, "CLEAN", "(nil, lit\"boom\") <: the (nil, string) union member (§6.5.5 exists-forall)")
		assert_sound(o)
	end)
end)

T.describe("slice v2.5: multi-assign with a CALL last value spreading its tuple", function()
	T.it("`local a, b = f()` over a 2-return f binds both slots — CLEAN", function()
		local o = lower_src([[
--: () -> (integer, string)
local function f()
  return 1, "x"
end
--: () -> integer
local function use()
  local a, b = f()
  return a
end
return { f = f, use = use }
]], false)
		T.eq(o.expected, "CLEAN", "f()'s (integer, string) return spreads into a, b")
		T.ok(not has_construct(o, "multi-assign"), "the multi-assign-from-call is in subset")
		assert_sound(o)
	end)
end)

T.describe("slice v2.5: multi-assign with a METHOD-CALL last value (the dominant idiom)", function()
	T.it("`n, err = r:read()` spreads the method's return tuple — CLEAN", function()
		local o = lower_src([[
--:: Reader = { read: (self: Reader) -> (integer, string | nil) }
--: (Reader) -> integer
local function consume(r)
  local n, err = r:read()
  return n
end
return { consume = consume }
]], false)
		T.eq(o.expected, "CLEAN", "the methodcall's (integer, string | nil) return spreads into n, err")
		T.ok(not has_construct(o, "multi-assign"), "the methodcall-last multi-assign is in subset")
		assert_sound(o)
	end)
end)

T.describe("slice v2.5: dynamic-index WRITE over a homogeneous closed rec", function()
	T.it("`t[k] = v` over a closed rec whose fields share one type checks v ⇐ V — CLEAN", function()
		local o = lower_src([[
--: ({ a: integer, b: integer }, string, integer) -> ()
local function set(t, k, v)
  t[k] = v
end
return { set = set }
]], false)
		T.eq(o.expected, "CLEAN", "homogeneous closed-rec dynamic write checks v ⇐ the common field type")
		T.ok(not has_construct(o, "dynamic-index-assign"), "the homogeneous closed-rec write is in subset")
		assert_sound(o)
	end)
	T.it("`out = {}; out[k] = v` over an EMPTY fresh table now lowers (§6.10) — CLEAN", function()
		-- §6.10: the fresh-table build idiom. An empty closed rec has no declared
		-- field, so `index_write_target` returns `unknown` (no constraint to violate).
		-- Sound: the empty-rec READ rule never admits a value, so the accepted write
		-- licenses no unsound read. This was the dominant real shape behind the §9.15.4
		-- "empty" deferral (2548 corpus markers).
		local o = lower_src([[
local function build(s)
  local out = {}
  out[s] = 1
  return out
end
return { build = build }
]], false)
		T.eq(o.expected, "CLEAN", "the empty-fresh-table dynamic write target is unknown (accepts)")
		T.ok(not has_construct(o, "dynamic-index-assign"), "the empty-rec write is in subset")
		assert_sound(o)
	end)
	T.it("`t[k] = v` over a HETEROGENEOUS closed rec stays out-of-subset (the §9.16 deferral)", function()
		local o = lower_src([[
--: ({ a: integer, b: string }, string, integer) -> ()
local function set(t, k, v)
  t[k] = v
end
return { set = set }
]], false)
		T.eq(o.expected, "OUT-OF-SUBSET", "a heterogeneous closed-rec dynamic write is the recorded deferral")
		T.ok(has_construct(o, "dynamic-index-assign"), "marked the heterogeneous-rec write boundary")
		assert_sound(o)
	end)
end)

-- ── Audit round 4 fixes (§9.17) ──────────────────────────────────────────────

T.describe("audit round 4 — A-F1: rec_with_indexer dynamic-key READ (e2e soundness)", function()
	T.it("fixture_rec_with_indexer_dynamic_read: sound annotation (string|integer) lowers CLEAN", function()
		local o = lower_fixture("rec_with_indexer_dynamic_read")
		-- After the fix: t[k] over { a: string, [string]: integer } with k: string
		-- synthesizes string|integer (field union ∪ indexer val). The fixture's
		-- only function declares `-> (string | integer)`, which must ACCEPT.
		T.eq(o.expected, "CLEAN", "sound return annotation string|integer is accepted")
		T.eq(#o.constructs, 0, "no out-of-subset markers")
		assert_sound(o)
		T.ok(o.requested > 0, "load-bearing claims were emitted and accepted")
	end)

	T.it("asserting integer alone for a rec_with_indexer DISAGREE dynamic read is FINDINGS", function()
		local o = lower_src([[
--:: RWI = { a: string, [string]: integer }
--: (RWI, string) -> integer
local function f(t, k) return t[k] end
return { f = f }
]], false)
		-- The return type `integer` is too narrow: the dynamic read may yield `string`
		-- (the listed field `a`). This must produce a type-mismatch finding.
		T.eq(o.expected, "FINDINGS", "integer-only return rejected: field `a: string` is also possible")
		T.ok(has_construct(o, "type-mismatch"), "marked the type-mismatch")
		assert_sound(o)
	end)
end)

T.describe("audit round 4 — and-guard narrowing: `if x and <expr>` narrows x (e2e)", function()
	T.it("fixture_and_guard_narrows_left: `x and x ~= \"\"` narrows x to string — CLEAN", function()
		local o = lower_fixture("and_guard_narrows_left")
		-- After the fix: `if title and fallback ~= ""` and `if s and s ~= ""`
		-- both narrow their first operand (a truthy bare-variable left operand of
		-- `and`). The fixtures use the narrowed string inside the branch; they must
		-- be CLEAN (0 rejections).
		T.eq(o.expected, "CLEAN", "and-guard left-operand narrowing accepted")
		T.eq(#o.constructs, 0, "no out-of-subset markers")
		assert_sound(o)
		T.ok(o.requested > 0, "load-bearing claims were emitted and accepted")
	end)

	T.it("`if x and <call>` narrows x: inline CLEAN", function()
		local o = lower_src([[
--: (string | nil, boolean) -> string
local function f(x, flag)
  if x and flag then
    return x
  end
  return ""
end
return { f = f }
]], false)
		-- `x and flag` — `flag` is a boolean variable, a recognized truthy guard.
		-- Both sides are recognized; the and-guard narrows x to string.
		T.eq(o.expected, "CLEAN", "x and flag (both recognized) narrows x to string")
		assert_sound(o)
	end)
end)

-- ── Field-path narrowing (§6.11, the §9.8 deferral) ──────────────────────────

T.describe("slice v2.7: field-path narrowing — the positive cases", function()
	T.it("bare truthy path `if o.title then return o.title` is CLEAN", function()
		local o = lower_src([[
--:: O = { title: string | nil }
--: (O) -> string
local function f(o)
  if o.title then return o.title end
  return ""
end
return { f = f }
]], false)
		-- `if o.title then` refines the PATH `o.title : string | nil` → `string`; the
		-- guarded read `o.title` synthesizes `string`, so `<: string` (the return) holds.
		T.eq(o.expected, "CLEAN", "bare-truthy field-path narrowing accepted")
		T.eq(#o.constructs, 0, "no out-of-subset markers")
		assert_sound(o)
	end)

	T.it("and-guard path `if o.title and o.title ~= \"\"` (the rehype_meta idiom) is CLEAN", function()
		local o = lower_src([[
--:: O = { title: string | nil }
--: (O) -> string
local function f(o)
  if o.title and o.title ~= "" then return o.title end
  return ""
end
return { f = f }
]], false)
		-- The dominant round-4 corpus idiom: the truthy `o.title` conjunct (the and-left)
		-- narrows the path; the `~= ""` conjunct is unrecognized but the and-relaxation
		-- (§9.17) keeps the recognized side.
		T.eq(o.expected, "CLEAN", "and-guard field-path narrowing accepted (rehype_meta idiom)")
		assert_sound(o)
	end)

	T.it("path narrowed inside a call argument (the coinductive shape) is CLEAN", function()
		local o = lower_src([[
--:: N = { left: N | nil }
--: (N) -> integer
local function sz(n)
  local s = 1
  if n.left then s = s + sz(n.left) end
  return s
end
return { sz = sz }
]], false)
		-- `if n.left then s = s + sz(n.left)` — the path read `n.left` is the call
		-- argument, synthesized as the refined `N` BEFORE the call's invalidation
		-- applies (the read happens-before the call). `sz(n.left)` accepts.
		T.eq(o.expected, "CLEAN", "field-path read inside a call argument reads the live refinement")
		assert_sound(o)
	end)
end)

T.describe("slice v2.7: field-path narrowing — the INVALIDATION fence (§6.11.2 soundness)", function()
	-- These tests make the soundness boundary EXECUTABLE: a path refinement DIES
	-- after any call / write / alias-write, so a read AFTER such a statement falls
	-- back to the declared (wider) field type and the program is correctly rejected.

	T.it("refinement DIES after a call: read of o.f after a call re-widens (FINDINGS)", function()
		local o = lower_src([[
--:: O = { f: string | nil }
--: (O, (string) -> nil) -> string
local function g(o, emit)
  if o.f then
    emit("x")
    return o.f
  end
  return ""
end
return { g = g }
]], false)
		-- `emit("x")` is a call that may mutate `o.f` (no escape analysis); the path
		-- refinement dies, so `return o.f` re-reads `string | nil`, which is NOT a
		-- subtype of the `-> string` return: a type-mismatch (the sound rejection).
		T.eq(o.expected, "FINDINGS", "the refinement dies after a call — the post-call read is correctly rejected")
		T.ok(has_construct(o, "type-mismatch"), "the soundness fence rejects the re-widened read")
	end)

	T.it("refinement DIES after a write-through (o.f = ...) — the post-write read re-widens (FINDINGS)", function()
		local o = lower_src([[
--:: O = { f: string | nil, g: string | nil }
--: (O) -> string
local function h(o)
  if o.f then
    o.g = nil
    return o.f
  end
  return ""
end
return { h = h }
]], false)
		-- `o.g = nil` is a write through the base; v1 cannot prove it leaves `o.f`
		-- unchanged (a write-through-any-lvalue invalidates all path refinements), so
		-- `return o.f` re-reads `string | nil` and is correctly rejected.
		T.eq(o.expected, "FINDINGS", "the refinement dies after a write-through — post-write read rejected")
		T.ok(has_construct(o, "type-mismatch"), "the soundness fence rejects the re-widened read")
	end)

	T.it("refinement DIES after an alias write (local y = o; y.f = nil) — §6.11.3 worked example (FINDINGS)", function()
		local o = lower_src([[
--:: O = { f: string | nil }
--: (O) -> string
local function k(o)
  local y = o
  if o.f then
    y.f = nil
    return o.f
  end
  return ""
end
return { k = k }
]], false)
		-- The §6.11.3 aliasing worked example: `y` aliases `o`, so `y.f = nil` mutates
		-- `o.f`. v1 cannot decide `y == o`; the conservative any-write-through-any-lvalue
		-- rule covers it — `y.f = nil` drops the `o.f` refinement, and `return o.f`
		-- re-reads `string | nil`, correctly rejecting the unsound `-> string`.
		T.eq(o.expected, "FINDINGS", "the refinement dies after an alias write — the unsound read is rejected")
		T.ok(has_construct(o, "type-mismatch"), "the alias-write soundness fence rejects the re-widened read")
	end)
end)

T.describe("slice v2.9: sub-statement happens-before invalidation fence (§6.11.2, audit round 5 F1)", function()
	-- These tests make the SUB-STATEMENT soundness boundary EXECUTABLE: a call that is
	-- syntactically a sibling evaluated BEFORE a path read within the SAME statement
	-- fires before the read and may mutate the field. Lua evaluates arguments and
	-- connectives left-to-right. The sound rule: if `lc.path_call_fired` is set (any
	-- call has been evaluated earlier in the current expression tree), subsequent path
	-- reads skip the live refinement and fall back to the declared field type.

	T.it("call-before-read (arg order): id2(emit(o), o.f) is FINDINGS (the call fires before o.f is read)", function()
		local o = lower_src([[
--:: O = { f: string | nil }
--: (string, string) -> string
local function id2(a, b) return b end
--: (O) -> string
local function emit(o) return "x" end
--: (O) -> string
local function g(o)
  if o.f then return id2(emit(o), o.f) end
  return ""
end
]], false)
		-- `emit(o)` is arg1 and fires before `o.f` (arg2) is read.
		-- The sub-statement fence rejects: `o.f` falls back to `string | nil` (not a
		-- subtype of the `string` return), correctly FINDINGS.
		T.eq(o.expected, "FINDINGS", "call-before-read in argument position: o.f falls back to string|nil")
		T.ok(has_construct(o, "type-mismatch"), "the sub-statement fence rejects the re-widened read")
	end)

	T.it("call-before-read (`or` connective): emit('x') or o.f is FINDINGS", function()
		local o = lower_src([[
--:: O = { f: string | nil }
--: (O) -> string
local function emit(o) return "x" end
--: (O) -> string
local function g(o)
  if o.f then return emit("x") or o.f end
  return ""
end
]], false)
		-- `or` evaluates the left operand first: `emit("x")` fires before `o.f` is read.
		T.eq(o.expected, "FINDINGS", "or-left call fires before o.f on the right: correctly FINDINGS")
		T.ok(has_construct(o, "type-mismatch"), "the sub-statement fence rejects the re-widened read")
	end)

	T.it("call-before-read (`and` connective over μ-typed base): touch(n) and id(n.left) is FINDINGS", function()
		local o = lower_src([[
--:: N = { left: N | nil }
--: (N) -> N
local function id(n) return n end
--: (N) -> nil
local function touch(n) end
--: (N) -> N
local function g(n)
  if n.left then
    local r = touch(n) and id(n.left)
    return n
  end
  return n
end
]], false)
		-- `and` evaluates the left operand first: `touch(n)` fires before `n.left` (arg
		-- to `id`) is read. The μ-typed base interaction (§6.11.2 + §3) is covered.
		T.eq(o.expected, "FINDINGS", "and-left call fires before n.left on the right: correctly FINDINGS")
	end)

	T.it("read-before-call (the argument IS the call's arg): f(o.f) stays CLEAN", function()
		local o = lower_src([[
--:: O = { f: string | nil }
--: (string) -> string
local function id(s) return s end
--: (O) -> string
local function g(o)
  if o.f then return id(o.f) end
  return ""
end
]], false)
		-- `o.f` is the ARGUMENT to `id` — it is synthesized LEFT-TO-RIGHT BEFORE the
		-- call fires, so the live refinement is correctly consumed. CLEAN.
		T.eq(o.expected, "CLEAN", "read is the call argument (happens-before the call): refinement is sound")
		assert_sound(o)
	end)
end)

T.describe("slice v2.9: post-exit guard narrows a field PATH (§6.11, audit round 5 F2)", function()
	-- `if not x.f then return end` is the dominant early-return guard idiom in lib/.
	-- The block_exits arm must narrow the PATH x.f by the guard's FALSY refinement
	-- (the not-guard's falsy branch = the value IS truthy) for subsequent statements.
	-- This mirrors the if-then arm's path_pre_type handling.

	T.it("post-exit guard on a field path narrows x.f (CLEAN — was wrong-rejection)", function()
		local o = lower_src([[
--:: Box = { f: string | nil }
--: (string) -> string
local function id(s) return s end
--: (Box) -> string
local function g(x)
  if not x.f then return "n" end
  return id(x.f)
end
]], false)
		-- `if not x.f then return "n" end` is a post-exit guard: the block_exits arm
		-- must bind x.f to its non-nil refinement so `id(x.f)` sees `string`, not
		-- `string | nil`. Before the fix this was FINDINGS (wrong-rejection).
		T.eq(o.expected, "CLEAN", "post-exit guard narrows the path x.f to non-nil")
		assert_sound(o)
	end)

	T.it("post-exit guard on a bare variable still narrows (regression guard — CLEAN)", function()
		local o = lower_src([[
--: (string | nil) -> string
local function g(v)
  if not v then return "n" end
  return v
end
]], false)
		-- Pre-existing behavior: bare-variable post-exit guard. Must stay CLEAN.
		T.eq(o.expected, "CLEAN", "bare-var post-exit guard still narrows (no regression)")
		assert_sound(o)
	end)
end)
