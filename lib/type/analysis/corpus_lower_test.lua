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

T.describe("corpus e2e: fixture_boolean_narrowing — arithmetic operator boundary", function()
	T.it("`1 / n < 0` hits the operator-arith boundary (v1 has no numeric operator synth, §1.4)", function()
		local o = lower_fixture("boolean_narrowing")
		T.eq(o.expected, "OUT-OF-SUBSET", "the `/` operator is outside §5's checked syntax")
		T.ok(has_construct(o, "operator-arith"), "marked operator-arith (the `1/n` division)")
		assert_sound(o)
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

T.describe("corpus e2e: fixture_pairs_return_leak — dynamic-key write + arithmetic", function()
	T.it("`merged[k] = v` (dynamic-index-assign) and `s + v` (arith) are outside §5", function()
		local o = lower_fixture("pairs_return_leak")
		T.eq(o.expected, "OUT-OF-SUBSET", "dynamic-key field write and `+` are outside §5")
		T.ok(has_construct(o, "dynamic-index-assign") or has_construct(o, "operator-arith"),
			"marked the dynamic-key write / arithmetic boundary")
		assert_sound(o)
		-- the in-subset part DID work: the `for _, v in pairs(t)` loop-var binding
		-- emitted accepted synth_loop_var claims.
		T.ok(o.requested > 0, "the pairs loop-var claims were emitted and accepted")
	end)
end)

T.describe("corpus e2e: fixture_coinductive_recursive_types — field-path narrowing + arith", function()
	T.it("`if node.left then` (field-path narrow) and `s + ...` are the §5 boundary", function()
		local o = lower_fixture("coinductive_recursive_types")
		T.eq(o.expected, "OUT-OF-SUBSET", "field-path narrowing and `+` are outside §5")
		assert_sound(o)
	end)
end)

T.describe("corpus e2e: fixture_table_construction_widening — dynamic-key write boundary", function()
	T.it("`insns[1] = {...}` (dynamic-index-assign) is the §5 boundary", function()
		local o = lower_fixture("table_construction_widening")
		T.eq(o.expected, "OUT-OF-SUBSET", "integer-key sequential writes use the dynamic-key form")
		T.ok(has_construct(o, "dynamic-index-assign"), "marked dynamic-index-assign")
		assert_sound(o)
	end)
end)

T.describe("corpus e2e: fixture_hamt_recursion — forward alias + named params", function()
	T.it("`node: HamtNode` (named param) and the forward alias ref are the §5 boundary", function()
		local o = lower_fixture("hamt_recursion")
		T.eq(o.expected, "OUT-OF-SUBSET", "named parameters + forward-referenced alias are outside §5")
		T.ok(has_construct(o, "named-param") or has_construct(o, "unknown-type-name"),
			"marked the named-param / unresolved-alias boundary")
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

T.describe("corpus e2e: fixture_cross_module_type_alias — named params", function()
	T.it("`cb: () -> nil, epoll: Epoll | nil` (named params) is the §5 boundary", function()
		local o = lower_fixture("cross_module_type_alias")
		T.eq(o.expected, "OUT-OF-SUBSET", "named parameters are outside §5 (v1 params are positional)")
		T.ok(has_construct(o, "named-param"), "marked named-param")
		assert_sound(o)
	end)
end)

T.describe("corpus e2e: fixture_closure_param_typing — unannotated closures", function()
	T.it("the inner `function(s) ... end` closures (unannotated) are the §5 boundary", function()
		local o = lower_fixture("closure_param_typing")
		T.eq(o.expected, "OUT-OF-SUBSET", "unannotated closures are outside §5 (function synth needs a declared fn type)")
		T.ok(has_construct(o, "unannotated-closure"), "marked unannotated-closure")
		assert_sound(o)
	end)
end)

-- ── The headline assertion: the honest split ─────────────────────────────────

T.describe("corpus e2e: the honest 11-fixture split under real lowering", function()
	T.it("2 CLEAN, 9 OUT-OF-SUBSET, 0 rejections anywhere (Pass 5's load-bearing finding)", function()
		local names = {
			"boolean_narrowing", "local_return_narrowing", "union_alias_over_named_types",
			"tonumber_return_type", "pairs_return_leak", "coinductive_recursive_types",
			"table_construction_widening", "hamt_recursion", "cast_not_inference_source",
			"cross_module_type_alias", "closure_param_typing",
		}
		local clean, oos, total_rej = 0, 0, 0
		for _, n in ipairs(names) do
			local o = lower_fixture(n)
			if o.expected == "CLEAN" then clean = clean + 1
			elseif o.expected == "OUT-OF-SUBSET" then oos = oos + 1 end
			total_rej = total_rej + o.rej
		end
		T.eq(clean, 2, "2 fixtures are fully within §5 (local_return_narrowing, union_alias)")
		T.eq(oos, 9, "9 fixtures hit a real §5 boundary the hand-built graphs assumed away")
		T.eq(total_rej, 0, "ZERO rejections across all 11 — every in-subset claim the lowering emits is sound")
	end)
end)
