local T = require("lib.test.assert")
local A = require("lib.type.analysis")
local P = require("lib.type.analysis.prop")
local L = require("lib.type.analysis.lambda")

--: ({ [string]: Claim }, Claim) -> boolean
local function has(map, claim) return map[A.claim_key(claim)] ~= nil end
--: ({ [string]: Claim }) -> integer
local function count(map)
	local n = 0
	for _ in pairs(map) do n = n + 1 end
	return n
end

T.describe("substrate: claim identity", function()
	T.it("structural identity: same args => same claim key", function()
		local a = A.claim({ id = A.id("claim", "a"), semantics = "s", predicate = "p", args = { x = 1, y = { 2, 3 } } })
		local b = A.claim({ id = A.id("claim", "b"), semantics = "s", predicate = "p", args = { y = { 2, 3 }, x = 1 } })
		T.eq(A.claim_key(a), A.claim_key(b), "key is order-insensitive over record fields")
	end)

	T.it("DECISION: alpha_eq(t1,t2) is a DISTINCT claim from alpha_eq(t2,t1) at the substrate", function()
		-- Structural identity of args, NOT hosted (alpha) identity. Symmetry is
		-- the hosted semantics' business, not the substrate's. Recorded in the
		-- object-model doc's arg-schema open item.
		local t1 = A.id("artifact", "t1")
		local t2 = A.id("artifact", "t2")
		local c12 = L.alpha_eq_claim(A.id("claim", "c12"), t1, t2)
		local c21 = L.alpha_eq_claim(A.id("claim", "c21"), t2, t1)
		T.neq(A.claim_key(c12), A.claim_key(c21),
			"swapped args are structurally distinct claims (substrate does not impose symmetry)")
	end)

	T.it("different predicate => different key even with identical args", function()
		local a = A.claim({ id = A.id("claim", "a"), semantics = "s", predicate = "free_in", args = { 1 } })
		local b = A.claim({ id = A.id("claim", "b"), semantics = "s", predicate = "not_free_in", args = { 1 } })
		T.neq(A.claim_key(a), A.claim_key(b), "predicate participates in identity")
	end)
end)

T.describe("substrate: unknown propagation", function()
	-- A multi-level chain A <- B <- C, where the deepest premise has no evidence.
	-- The dependent evidence must resolve UNKNOWN (input unavailable), distinct
	-- from REJECTED (evidence checked and refused).
	T.it("unknown intermediate => dependents unknown, not rejected", function()
		local state = A.new_state()
		local registry = A.new_registry(); P.register(registry)
		-- cBase has NO evidence (unknown). cMid via and_elim needs cConj which
		-- itself is built from cBase by and_intro -- but cBase is unknown, so the
		-- whole chain is unknown, never rejected.
		local cBase = P.holds_claim(A.id("claim", "cBase"), P.atom("A"))
		local cConj = P.holds_claim(A.id("claim", "cConj"), P.p_and(P.atom("A"), P.atom("B")))
		local cMid  = P.holds_claim(A.id("claim", "cMid"), P.atom("A"))
		A.add_claim(state, cBase); A.add_claim(state, cConj); A.add_claim(state, cMid)
		-- and_intro for cConj needs cBase (unknown) and a cB (also no evidence).
		local cB = P.holds_claim(A.id("claim", "cB"), P.atom("B"))
		A.add_claim(state, cB)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eConj"), claim = cConj.id, method = "and_intro", inputs = { cBase.id, cB.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eMid"), claim = cMid.id, method = "and_elim_left", inputs = { cConj.id } }))
		local res = A.check({ state = state, requested_claims = { cBase.id, cConj.id, cMid.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.unknown_claims, cBase), "cBase unknown (no evidence)")
		T.ok(has(res.unknown_claims, cConj), "cConj unknown (premise unavailable)")
		T.ok(has(res.unknown_claims, cMid), "cMid unknown (chain unavailable)")
		T.eq(count(res.rejected_claims), 0, "nothing rejected -- unavailable is not refused")
	end)

	T.it("rejected path is distinct: refused evidence => rejected, not unknown", function()
		local state = A.new_state()
		local registry = A.new_registry(); P.register(registry)
		local t1 = A.trust_boundary({ id = A.id("trust", "t1"), kind = "axiom", issuer = "test" })
		A.add_trust_boundary(state, t1)
		-- cConj = and(A,B) accepted by axiom; cWrong = holds(C) via and_elim_left
		-- on cConj -- but C is not the left conjunct, so the evidence is REFUSED.
		local cConj = P.holds_claim(A.id("claim", "cConj"), P.p_and(P.atom("A"), P.atom("B")))
		local cWrong = P.holds_claim(A.id("claim", "cWrong"), P.atom("C"))
		A.add_claim(state, cConj); A.add_claim(state, cWrong)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eConj"), claim = cConj.id, method = "trusted_axiom", result = { trust = t1.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eWrong"), claim = cWrong.id, method = "and_elim_left", inputs = { cConj.id } }))
		local res = A.check({ state = state, requested_claims = { cWrong.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.rejected_claims, cWrong), "cWrong rejected (evidence checked and refused)")
		T.fail(has(res.unknown_claims, cWrong), "cWrong is NOT unknown")
	end)
end)

T.describe("substrate: scheduling", function()
	-- Build the pure-acceptance prop example and submit its evidence in many
	-- shuffled orders; the result must be identical every time.
		--: () -> (AnalysisState, SemanticsRegistry, { [integer]: Evidence }, { [integer]: Id })
	local function build()
		local state = A.new_state()
		local registry = A.new_registry(); P.register(registry)
		local t1 = A.trust_boundary({ id = A.id("trust", "t1"), kind = "axiom", issuer = "test" })
		local t2 = A.trust_boundary({ id = A.id("trust", "t2"), kind = "axiom", issuer = "test" })
		A.add_trust_boundary(state, t1); A.add_trust_boundary(state, t2)
		local cA = P.holds_claim(A.id("claim", "cA"), P.atom("A"))
		local cB = P.holds_claim(A.id("claim", "cB"), P.atom("B"))
		local cAB = P.holds_claim(A.id("claim", "cAB"), P.p_and(P.atom("A"), P.atom("B")))
		A.add_claim(state, cA); A.add_claim(state, cB); A.add_claim(state, cAB)
		local evs = {
			A.evidence({ id = A.id("ev", "eAB"), claim = cAB.id, method = "and_intro", inputs = { cA.id, cB.id } }),
			A.evidence({ id = A.id("ev", "eA"), claim = cA.id, method = "trusted_axiom", result = { trust = t1.id } }),
			A.evidence({ id = A.id("ev", "eB"), claim = cB.id, method = "trusted_axiom", result = { trust = t2.id } }),
		}
		return state, registry, evs, { cA.id, cB.id, cAB.id }
	end

	T.it("shuffled evidence orders yield identical accepted sets", function()
		-- The substrate iterates pairs(evidence) (insertion-independent), so we
		-- explicitly add evidence in several orders and compare results.
		local orders = { { 1, 2, 3 }, { 3, 2, 1 }, { 2, 3, 1 }, { 1, 3, 2 } }
		local baseline_n
		for _, ord in ipairs(orders) do
			local state, registry, evs, req = build()
			for _, idx in ipairs(ord) do A.add_evidence(state, evs[idx]) end
			local res = A.check({ state = state, requested_claims = req, semantics_registry = registry })
			if not res then T.fail(true, "no result"); return end
			local n = count(res.accepted_claims)
			T.eq(n, 3, "all three accepted regardless of submission order")
			if baseline_n then T.eq(n, baseline_n, "consistent across orders") end
			baseline_n = n
		end
	end)

	T.it("dependency cycle terminates with a diagnostic, not nontermination", function()
		-- Two claims whose evidence each depends on the other. No accepted base
		-- exists, so the worklist settles and a cycle diagnostic is emitted.
		local state = A.new_state()
		local registry = A.new_registry(); P.register(registry)
		local cX = P.holds_claim(A.id("claim", "cX"), P.atom("X"))
		local cY = P.holds_claim(A.id("claim", "cY"), P.atom("Y"))
		A.add_claim(state, cX); A.add_claim(state, cY)
		-- eX accepts cX via and_elim from cY-derived conj; we fake mutual reliance
		-- by making each elim depend on the other (and_elim_left needs a conj, but
		-- we point them at each other to force the cycle path).
		-- Simpler: use and_intro where each input is the other claim.
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eX"), claim = cX.id, method = "and_elim_left", inputs = { cY.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eY"), claim = cY.id, method = "and_elim_left", inputs = { cX.id } }))
		local res = A.check({ state = state, requested_claims = { cX.id, cY.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		-- Neither can be accepted (no base); both rejected or unknown, never hang.
		T.fail(has(res.accepted_claims, cX), "cX not accepted")
		T.fail(has(res.accepted_claims, cY), "cY not accepted")
	end)

	T.it("genuine evidence cycle yields a cycle diagnostic", function()
		-- Construct evidence that is mutually blocked: each evidence's input is the
		-- other's produced claim, and neither's method can fire without the other.
		-- Use and_intro: eP produces P from inputs {Q}, eQ produces Q from {P}.
		-- (and_intro needs two inputs, so pad with a never-accepted claim.)
		local state = A.new_state()
		local registry = A.new_registry(); P.register(registry)
		local cP = P.holds_claim(A.id("claim", "cP"), P.p_and(P.atom("Q"), P.atom("Z")))
		local cQ = P.holds_claim(A.id("claim", "cQ"), P.p_and(P.atom("P"), P.atom("Z")))
		local cZ = P.holds_claim(A.id("claim", "cZ"), P.atom("Z"))
		local cQinner = P.holds_claim(A.id("claim", "cQi"), P.atom("Q"))
		local cPinner = P.holds_claim(A.id("claim", "cPi"), P.atom("P"))
		A.add_claim(state, cP); A.add_claim(state, cQ); A.add_claim(state, cZ)
		A.add_claim(state, cQinner); A.add_claim(state, cPinner)
		-- eQinner gets Q by elim from cP; ePinner gets P by elim from cQ. cP needs
		-- cQinner; cQ needs cPinner. Mutual block.
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eP"), claim = cP.id, method = "and_intro", inputs = { cQinner.id, cZ.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eQ"), claim = cQ.id, method = "and_intro", inputs = { cPinner.id, cZ.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eQi"), claim = cQinner.id, method = "and_elim_left", inputs = { cP.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ePi"), claim = cPinner.id, method = "and_elim_left", inputs = { cQ.id } }))
		local res = A.check({ state = state, requested_claims = { cP.id, cQ.id, cQinner.id, cPinner.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.eq(count(res.accepted_claims), 0, "cyclic evidence accepts nothing")
		local cyc = false
		for _, d in ipairs(res.diagnostics) do if d:find("[Cc]ycle") then cyc = true end end
		T.ok(cyc, "a dependency-cycle diagnostic was emitted")
	end)
end)

T.describe("substrate: trust obligation", function()
	T.it("hosted-checker verdict is itself a visible trusted boundary", function()
		local note = A.unverified_checker_trust("prop.logic.min", "0")
		T.eq(note.kind, "unverified_hosted_checker", "trust slot kind")
		T.ok(note.note:find("unverified"), "note flags the unverified verdict")
		T.ok(note.semantics:find("prop.logic.min"), "names the semantics")
	end)

	T.it("substrate refuses unknown-as-proof: an unknown premise cannot accept a dependent", function()
		-- modus_ponens whose implication premise is unknown (no evidence) cannot
		-- accept the consequent.
		local state = A.new_state()
		local registry = A.new_registry(); P.register(registry)
		local t1 = A.trust_boundary({ id = A.id("trust", "t1"), kind = "axiom", issuer = "test" })
		A.add_trust_boundary(state, t1)
		local cA = P.holds_claim(A.id("claim", "cA"), P.atom("A"))
		local cImp = P.holds_claim(A.id("claim", "cImp"), P.p_implies(P.atom("A"), P.atom("B")))
		local cB = P.holds_claim(A.id("claim", "cB"), P.atom("B"))
		A.add_claim(state, cA); A.add_claim(state, cImp); A.add_claim(state, cB)
		-- cA accepted by axiom; cImp has NO evidence (unknown).
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eA"), claim = cA.id, method = "trusted_axiom", result = { trust = t1.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eB"), claim = cB.id, method = "modus_ponens", inputs = { cA.id, cImp.id } }))
		local res = A.check({ state = state, requested_claims = { cB.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.fail(has(res.accepted_claims, cB), "cB not accepted -- unknown implication is not proof")
		T.ok(has(res.unknown_claims, cB), "cB unknown (premise unavailable)")
	end)

	T.it("adversarial: lambda semantics never asks the substrate to store binder/scope objects", function()
		-- Run the alpha example and assert every Id stored in the state lives in a
		-- substrate-owned space (artifact/claim/ev/trust), never 'binder'/'scope'.
		local state = A.new_state()
		local registry = A.new_registry(); L.register(registry)
		--: (string, LamTerm) -> Id
		local function add_term(key, term)
			local id = A.id("artifact", key)
			A.add_artifact(state, A.artifact({ id = id, kind = "syntax_tree", content_ref = term }))
			return id
		end
		local t1 = add_term("t1", L.lam("x", L.var("x")))
		local c1 = L.well_formed_claim(A.id("claim", "c1"), t1)
		A.add_claim(state, c1)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "e1"), claim = c1.id, method = "artifact_shape_check" }))
		A.check({ state = state, requested_claims = { c1.id }, semantics_registry = registry })
		local allowed = { artifact = true, claim = true, ev = true, trust = true, observation = true }
		--: ({ [string]: unknown }) -> nil
		local function check_spaces(store)
			for k in pairs(store) do
				local space = k:match("^([^/]+)/") or "?"
				T.ok(allowed[space], "stored id space '" .. space .. "' is substrate-owned, not a binder/scope")
			end
		end
		check_spaces(state.artifacts)
		check_spaces(state.claims)
		check_spaces(state.evidence)
		check_spaces(state.trust_boundaries)
		check_spaces(state.observations)
	end)
end)
