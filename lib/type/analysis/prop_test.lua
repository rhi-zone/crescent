local T = require("lib.test.assert")
local A = require("lib.type.analysis")
local P = require("lib.type.analysis.prop")

-- Build a registry with prop.logic.min registered.
--: () -> SemanticsRegistry
local function reg()
	local r = A.new_registry()
	P.register(r)
	return r
end

-- Count entries in a {[string]:_} map.
--: ({ [string]: Claim }) -> integer
local function count(map)
	local n = 0
	for _ in pairs(map) do n = n + 1 end
	return n
end

-- Is a claim (by its claim-key) in a result class map?
--: ({ [string]: Claim }, Claim) -> boolean
local function has(map, claim)
	return map[A.claim_key(claim)] ~= nil
end

T.describe("prop.logic.min", function()
	T.it("pure acceptance: cA, cB trusted, cAB by and_intro", function()
		local state = A.new_state()
		local registry = reg()
		-- trust boundaries
		local t1 = A.trust_boundary({ id = A.id("trust", "t1"), kind = "axiom", issuer = "test" })
		local t2 = A.trust_boundary({ id = A.id("trust", "t2"), kind = "axiom", issuer = "test" })
		A.add_trust_boundary(state, t1)
		A.add_trust_boundary(state, t2)

		local cA = P.holds_claim(A.id("claim", "cA"), P.atom("A"))
		local cB = P.holds_claim(A.id("claim", "cB"), P.atom("B"))
		local cAB = P.holds_claim(A.id("claim", "cAB"), P.p_and(P.atom("A"), P.atom("B")))
		A.add_claim(state, cA); A.add_claim(state, cB); A.add_claim(state, cAB)

		A.add_evidence(state, A.evidence({ id = A.id("ev", "eA"), claim = cA.id, method = "trusted_axiom", result = { trust = t1.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eB"), claim = cB.id, method = "trusted_axiom", result = { trust = t2.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eAB"), claim = cAB.id, method = "and_intro", inputs = { cA.id, cB.id } }))

		local res = A.check({ state = state, requested_claims = { cA.id, cB.id, cAB.id }, semantics_registry = registry })
		T.ok(res, "check returned a result")
		if not res then return end
		T.ok(has(res.accepted_claims, cA), "cA accepted")
		T.ok(has(res.accepted_claims, cB), "cB accepted")
		T.ok(has(res.accepted_claims, cAB), "cAB accepted")
		T.eq(count(res.rejected_claims), 0, "nothing rejected")
		T.eq(count(res.unknown_claims), 0, "nothing unknown")
		-- trust summary for cAB carries both trust boundaries (transitive).
		local ts = res.trust_summary[A.claim_key(cAB)]
		T.ok(ts, "cAB has a trust summary")
	end)

	T.it("unknown is not accepted: no evidence => unknown, not accepted", function()
		local state = A.new_state()
		local registry = reg()
		local cA = P.holds_claim(A.id("claim", "cA"), P.atom("A"))
		A.add_claim(state, cA)
		local res = A.check({ state = state, requested_claims = { cA.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.unknown_claims, cA), "cA unknown")
		T.fail(has(res.accepted_claims, cA), "cA must not be accepted")
		T.eq(count(res.rejected_claims), 0, "not rejected")
	end)

	T.it("rejection: modus_ponens with mismatched antecedent rejects evidence, claim stays unknown", function()
		-- Per the doc, the offered evidence fails but the claim is not false; with
		-- only failing evidence and no accepting evidence, the claim is rejected
		-- (all its evidence rejected) -- but the diagnostic records WHY.
		local state = A.new_state()
		local registry = reg()
		-- premises: holds(atom A), holds(implies(atom C, atom B)); goal holds(atom B)
		local cPrem = P.holds_claim(A.id("claim", "cPrem"), P.atom("A"))
		local cImp = P.holds_claim(A.id("claim", "cImp"), P.p_implies(P.atom("C"), P.atom("B")))
		local cB = P.holds_claim(A.id("claim", "cB"), P.atom("B"))
		A.add_claim(state, cPrem); A.add_claim(state, cImp); A.add_claim(state, cB)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eB"), claim = cB.id, method = "modus_ponens", inputs = { cPrem.id, cImp.id } }))
		local res = A.check({ state = state, requested_claims = { cB.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.fail(has(res.accepted_claims, cB), "cB must not be accepted")
		-- cB's only evidence rejected => cB rejected (evidence outcome, not truth).
		T.ok(has(res.rejected_claims, cB), "cB rejected (all evidence rejected)")
		T.ok(#res.diagnostics >= 1, "a diagnostic was recorded")
		local found = false
		for _, d in ipairs(res.diagnostics) do
			if d:find("antecedent") then found = true end
		end
		T.ok(found, "diagnostic names the antecedent mismatch")
	end)

	T.it("contradiction is hosted policy, not explosion: rejects the goal, does NOT accept arbitrary B", function()
		local state = A.new_state()
		local registry = reg()
		local t1 = A.trust_boundary({ id = A.id("trust", "t1"), kind = "axiom", issuer = "test" })
		local t2 = A.trust_boundary({ id = A.id("trust", "t2"), kind = "axiom", issuer = "test" })
		A.add_trust_boundary(state, t1); A.add_trust_boundary(state, t2)
		-- accept holds(A) and holds(not A) by axiom.
		local cA = P.holds_claim(A.id("claim", "cA"), P.atom("A"))
		local cNA = P.holds_claim(A.id("claim", "cNA"), P.p_not(P.atom("A")))
		-- goal: an arbitrary claim cZ that contradiction is asked to reject.
		local cZ = P.holds_claim(A.id("claim", "cZ"), P.atom("Z"))
		A.add_claim(state, cA); A.add_claim(state, cNA); A.add_claim(state, cZ)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eA"), claim = cA.id, method = "trusted_axiom", result = { trust = t1.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eNA"), claim = cNA.id, method = "trusted_axiom", result = { trust = t2.id } }))
		-- contradiction evidence attached to cZ, citing the two incompatible inputs.
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eZ"), claim = cZ.id, method = "contradiction", inputs = { cA.id, cNA.id } }))
		local res = A.check({ state = state, requested_claims = { cA.id, cNA.id, cZ.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		-- A and not-A were independently accepted by axiom.
		T.ok(has(res.accepted_claims, cA), "cA accepted")
		T.ok(has(res.accepted_claims, cNA), "cNA accepted")
		-- cZ is NOT accepted from contradiction (no explosion).
		T.fail(has(res.accepted_claims, cZ), "cZ must NOT be accepted (no explosion)")
		T.ok(has(res.rejected_claims, cZ), "cZ rejected by contradiction policy")
		local found = false
		for _, d in ipairs(res.diagnostics) do if d:find("[Ii]nconsistent") then found = true end end
		T.ok(found, "inconsistency diagnostic recorded")
	end)

	T.it("and_elim_left extracts the left conjunct", function()
		local state = A.new_state()
		local registry = reg()
		local t1 = A.trust_boundary({ id = A.id("trust", "t1"), kind = "axiom", issuer = "test" })
		A.add_trust_boundary(state, t1)
		local cAB = P.holds_claim(A.id("claim", "cAB"), P.p_and(P.atom("A"), P.atom("B")))
		local cA = P.holds_claim(A.id("claim", "cA"), P.atom("A"))
		A.add_claim(state, cAB); A.add_claim(state, cA)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eAB"), claim = cAB.id, method = "trusted_axiom", result = { trust = t1.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eA"), claim = cA.id, method = "and_elim_left", inputs = { cAB.id } }))
		local res = A.check({ state = state, requested_claims = { cA.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, cA), "cA extracted via and_elim_left")
	end)

	T.it("adversarial: type_of is not a Prop form => rejected", function()
		local state = A.new_state()
		local registry = reg()
		-- A claim whose args are not a valid Prop (smuggling a typechecker concept).
		local bad = A.claim({
			id = A.id("claim", "bad"),
			semantics = P.ID,
			predicate = "holds",
			args = { prop = { tag = "type_of", expr = "x", type = "integer" } },
		})
		A.add_claim(state, bad)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ebad"), claim = bad.id, method = "and_intro", inputs = {} }))
		local res = A.check({ state = state, requested_claims = { bad.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.fail(has(res.accepted_claims, bad), "type_of must not be accepted")
		T.ok(has(res.rejected_claims, bad), "type_of-shaped prop rejected")
	end)

	T.it("adversarial: registry rejects evidence methods not listed for the semantics", function()
		local state = A.new_state()
		local registry = reg()
		local cA = P.holds_claim(A.id("claim", "cA"), P.atom("A"))
		A.add_claim(state, cA)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eA"), claim = cA.id, method = "telepathy" }))
		local res, err = A.check({ state = state, requested_claims = { cA.id }, semantics_registry = registry })
		T.fail(res, "ill-formed request returns nil")
		T.ok(err and err:find("telepathy"), "error names the disallowed method")
	end)
end)
