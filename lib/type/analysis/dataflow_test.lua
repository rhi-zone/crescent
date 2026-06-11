local T = require("lib.test.assert")
local A = require("lib.type.analysis")
local D = require("lib.type.analysis.dataflow")
local P = require("lib.type.analysis.prop")

--: ({ [string]: Claim }, Claim) -> boolean
local function has(map, claim) return map[A.claim_key(claim)] ~= nil end
--: ({ [string]: Claim }) -> integer
local function count(map)
	local n = 0
	for _ in pairs(map) do n = n + 1 end
	return n
end

-- Add a graph artifact and return its Id.
--: (AnalysisState, string, ReachGraph) -> Id
local function add_graph(state, key, graph)
	local id = A.id("artifact", key)
	A.add_artifact(state, A.artifact({ id = id, kind = "cfg", content_ref = graph }))
	return id
end

-- A cyclic graph:  s -> a -> b -> a  (s is the sole source).
-- Reachable fixpoint: { s=true, a=true, b=true }.
-- Node `c` is isolated, unreachable: c=false.
--: () -> ReachGraph
local function cyclic_graph()
	return D.graph(
		{ "s", "a", "b", "c" },
		{ { from = "s", to = "a" }, { from = "a", to = "b" }, { from = "b", to = "a" } },
		{ "s" }
	)
end

local FULL_ASSIGN = { s = true, a = true, b = true, c = false }

T.describe("dataflow: fixpoint acceptance over a cyclic graph", function()
	T.it("the consistent assignment over a->b->a cycle is accepted as a fixpoint", function()
		local state = A.new_state()
		local registry = A.new_registry(); D.register(registry)
		local g = add_graph(state, "g", cyclic_graph())
		local cfp = D.fixpoint_claim(A.id("claim", "cfp"), g, FULL_ASSIGN)
		A.add_claim(state, cfp)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "efp"), claim = cfp.id, method = "fixpoint_witness" }))
		local res = A.check({ state = state, requested_claims = { cfp.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, cfp), "cyclic-graph fixpoint accepted")
		T.eq(count(res.rejected_claims), 0, "nothing rejected")
		-- The witness depends only on the graph artifact; NO claim->claim edge.
		local saw_artifact, saw_claim = false, false
		for _, d in ipairs(res.dependency_graph) do
			if d.kind == A.DEP_ARTIFACT_CONTENT then saw_artifact = true end
			if d.kind == A.DEP_ACCEPTED_CLAIM then saw_claim = true end
		end
		T.ok(saw_artifact, "fixpoint depends on graph artifact content")
		T.fail(saw_claim, "fixpoint has NO accepted-claim dependency (no A->B->A edge)")
	end)

	T.it("per-node reachable/not_reachable project off the single accepted witness", function()
		local state = A.new_state()
		local registry = A.new_registry(); D.register(registry)
		local g = add_graph(state, "g", cyclic_graph())
		local cfp = D.fixpoint_claim(A.id("claim", "cfp"), g, FULL_ASSIGN)
		local rA = D.reachable_claim(A.id("claim", "rA"), g, "a")
		local rB = D.reachable_claim(A.id("claim", "rB"), g, "b")
		local nrC = D.not_reachable_claim(A.id("claim", "nrC"), g, "c")
		A.add_claim(state, cfp); A.add_claim(state, rA); A.add_claim(state, rB); A.add_claim(state, nrC)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "efp"), claim = cfp.id, method = "fixpoint_witness" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eA"), claim = rA.id, method = "witness_projection", inputs = { cfp.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eB"), claim = rB.id, method = "witness_projection", inputs = { cfp.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eC"), claim = nrC.id, method = "witness_projection", inputs = { cfp.id } }))
		local res = A.check({ state = state, requested_claims = { rA.id, rB.id, nrC.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, rA), "reachable(a) accepted via projection")
		T.ok(has(res.accepted_claims, rB), "reachable(b) accepted via projection (cyclic node)")
		T.ok(has(res.accepted_claims, nrC), "not_reachable(c) accepted via projection")
		-- Every per-node claim depends on the FIXPOINT claim, never on a neighbour.
		local fp_key = A.claim_key(cfp)
		for _, d in ipairs(res.dependency_graph) do
			if d.kind == A.DEP_ACCEPTED_CLAIM then
				local tc = state.claims[A.idk(d.target)]
				T.ok(tc and A.claim_key(tc) == fp_key,
					"every accepted-claim dependency points at the witness, not a neighbour")
			end
		end
	end)
end)

T.describe("dataflow: unknown propagation under a fixpoint", function()
	-- A witness over a claim set where one member is UNDETERMINED (absent key).
	-- The witness is not a TOTAL fixpoint, so it is not accepted; projections that
	-- depend on it stay unknown, never accepted. Order-independent: the missing
	-- member is intrinsic to the assignment, not to scheduling.
	--: () -> (AnalysisState, SemanticsRegistry, Claim, Claim)
	local function build_partial()
		local state = A.new_state()
		local registry = A.new_registry(); D.register(registry)
		local g = add_graph(state, "g", cyclic_graph())
		-- `b` is absent => undetermined. is_fixpoint reports incompleteness at b.
		local partial = { s = true, a = true, c = false }
		local cfp = D.fixpoint_claim(A.id("claim", "cfp"), g, partial)
		local rA = D.reachable_claim(A.id("claim", "rA"), g, "a")
		A.add_claim(state, cfp); A.add_claim(state, rA)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "efp"), claim = cfp.id, method = "fixpoint_witness" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eA"), claim = rA.id, method = "witness_projection", inputs = { cfp.id } }))
		return state, registry, cfp, rA
	end

	T.it("an undetermined member makes the witness not a total fixpoint => rejected", function()
		local state, registry, cfp, _ = build_partial()
		local res = A.check({ state = state, requested_claims = { cfp.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.rejected_claims, cfp), "partial witness rejected (not a total fixpoint)")
		local mentioned = false
		for _, d in ipairs(res.diagnostics) do if d:find("node b") or d:find("consistent") then mentioned = true end end
		T.ok(mentioned, "diagnostic names the undetermined node")
	end)

	T.it("projections off a non-accepted partial witness stay unknown, not accepted", function()
		local state, registry, _, rA = build_partial()
		local res = A.check({ state = state, requested_claims = { rA.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.fail(has(res.accepted_claims, rA), "reachable(a) NOT accepted: its witness was not accepted")
		T.ok(has(res.unknown_claims, rA), "reachable(a) unknown (witness unavailable)")
	end)

	T.it("unknown-member outcome is order-independent across shuffled evidence", function()
		-- Submit the two evidence objects in both orders; the result is identical.
		--: (boolean) -> CheckResult | nil
		local function run(witness_first)
			local state, registry, cfp, rA = build_partial()
			-- build_partial already added both; re-add fresh state in chosen order.
			state = A.new_state(); registry = A.new_registry(); D.register(registry)
			local g = add_graph(state, "g", cyclic_graph())
			local partial = { s = true, a = true, c = false }
			cfp = D.fixpoint_claim(A.id("claim", "cfp"), g, partial)
			rA = D.reachable_claim(A.id("claim", "rA"), g, "a")
			A.add_claim(state, cfp); A.add_claim(state, rA)
			local efp = A.evidence({ id = A.id("ev", "efp"), claim = cfp.id, method = "fixpoint_witness" })
			local eA = A.evidence({ id = A.id("ev", "eA"), claim = rA.id, method = "witness_projection", inputs = { cfp.id } })
			if witness_first then A.add_evidence(state, efp); A.add_evidence(state, eA)
			else A.add_evidence(state, eA); A.add_evidence(state, efp) end
			return A.check({ state = state, requested_claims = { cfp.id, rA.id }, semantics_registry = registry })
		end
		local r1 = run(true)
		local r2 = run(false)
		if not r1 or not r2 then T.fail(true, "no result"); return end
		T.eq(count(r1.accepted_claims), count(r2.accepted_claims), "accepted count order-independent")
		T.eq(count(r1.rejected_claims), count(r2.rejected_claims), "rejected count order-independent")
		T.eq(count(r1.unknown_claims), count(r2.unknown_claims), "unknown count order-independent")
		T.eq(count(r1.accepted_claims), 0, "neither accepted (partial witness)")
	end)
end)

T.describe("dataflow: broken witness rejection", function()
	T.it("a locally-inconsistent member rejects the witness even though it claims consistency", function()
		-- The producer asserts b=false, but b has predecessor a=true, so the
		-- transfer rule expects b=true. Locally inconsistent at b => REJECT.
		local state = A.new_state()
		local registry = A.new_registry(); D.register(registry)
		local g = add_graph(state, "g", cyclic_graph())
		local broken = { s = true, a = true, b = false, c = false }
		local cfp = D.fixpoint_claim(A.id("claim", "cfp"), g, broken)
		A.add_claim(state, cfp)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "efp"), claim = cfp.id, method = "fixpoint_witness" }))
		local res = A.check({ state = state, requested_claims = { cfp.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.rejected_claims, cfp), "broken witness rejected")
		T.fail(has(res.accepted_claims, cfp), "broken witness NOT accepted")
		local named = false
		for _, d in ipairs(res.diagnostics) do if d:find("node b") then named = true end end
		T.ok(named, "diagnostic names the inconsistent node b")
	end)

	T.it("an over-asserting witness (false source claimed unreachable) rejects", function()
		-- Assert s=false, but s is a source => expected true. Inconsistent at s.
		local state = A.new_state()
		local registry = A.new_registry(); D.register(registry)
		local g = add_graph(state, "g", cyclic_graph())
		local broken = { s = false, a = false, b = false, c = false }
		local cfp = D.fixpoint_claim(A.id("claim", "cfp"), g, broken)
		A.add_claim(state, cfp)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "efp"), claim = cfp.id, method = "fixpoint_witness" }))
		local res = A.check({ state = state, requested_claims = { cfp.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.rejected_claims, cfp), "source-denying witness rejected")
	end)

	T.it("a projection contradicting an accepted witness rejects", function()
		-- Accept the true fixpoint, but request not_reachable(a) -- the witness
		-- says a=true, so the projection contradicts it and rejects.
		local state = A.new_state()
		local registry = A.new_registry(); D.register(registry)
		local g = add_graph(state, "g", cyclic_graph())
		local cfp = D.fixpoint_claim(A.id("claim", "cfp"), g, FULL_ASSIGN)
		local nrA = D.not_reachable_claim(A.id("claim", "nrA"), g, "a")
		A.add_claim(state, cfp); A.add_claim(state, nrA)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "efp"), claim = cfp.id, method = "fixpoint_witness" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "enrA"), claim = nrA.id, method = "witness_projection", inputs = { cfp.id } }))
		local res = A.check({ state = state, requested_claims = { nrA.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.rejected_claims, nrA), "not_reachable(a) rejected: contradicts the witness")
	end)
end)

T.describe("dataflow: shuffled-order equivalence (acceptance)", function()
	-- The full acceptance example (witness + three projections) submitted in
	-- several evidence orders yields identical accepted sets.
	--: ({ [integer]: integer }) -> CheckResult | nil
	local function run(order)
		local state = A.new_state()
		local registry = A.new_registry(); D.register(registry)
		local g = add_graph(state, "g", cyclic_graph())
		local cfp = D.fixpoint_claim(A.id("claim", "cfp"), g, FULL_ASSIGN)
		local rA = D.reachable_claim(A.id("claim", "rA"), g, "a")
		local rB = D.reachable_claim(A.id("claim", "rB"), g, "b")
		local nrC = D.not_reachable_claim(A.id("claim", "nrC"), g, "c")
		A.add_claim(state, cfp); A.add_claim(state, rA); A.add_claim(state, rB); A.add_claim(state, nrC)
		local evs = {
			A.evidence({ id = A.id("ev", "efp"), claim = cfp.id, method = "fixpoint_witness" }),
			A.evidence({ id = A.id("ev", "eA"), claim = rA.id, method = "witness_projection", inputs = { cfp.id } }),
			A.evidence({ id = A.id("ev", "eB"), claim = rB.id, method = "witness_projection", inputs = { cfp.id } }),
			A.evidence({ id = A.id("ev", "eC"), claim = nrC.id, method = "witness_projection", inputs = { cfp.id } }),
		}
		for _, idx in ipairs(order) do A.add_evidence(state, evs[idx]) end
		return A.check({ state = state, requested_claims = { cfp.id, rA.id, rB.id, nrC.id }, semantics_registry = registry })
	end

	T.it("projections-before-witness still accept (worklist retries)", function()
		-- Order with all projections submitted before the witness.
		local orders = { { 1, 2, 3, 4 }, { 4, 3, 2, 1 }, { 2, 3, 4, 1 }, { 3, 1, 4, 2 } }
		local baseline --[[: integer | nil ]]
		for _, ord in ipairs(orders) do
			local res = run(ord)
			if not res then T.fail(true, "no result"); return end
			local n = count(res.accepted_claims)
			T.eq(n, 4, "all four accepted regardless of submission order")
			if baseline then T.eq(n, baseline, "consistent across orders") end
			baseline = n
		end
	end)
end)

T.describe("dataflow: cyclic dependency declaration terminates", function()
	-- HONEST FINDING (recorded in the design-pressure doc): under the witness
	-- model, dataflow.reach.min CANNOT construct a claim->claim evidence cycle.
	-- Projections depend only on the witness (a sink); the witness depends on no
	-- claims. The structural acyclicity is the design's bet realized: graph
	-- cyclicity lives entirely inside the assignment the witness certifies, never
	-- as substrate dependency edges. These tests confirm that and confirm that an
	-- adversarial attempt to wire a cycle still terminates.

	T.it("an adversarial reachable<->reachable input wiring is rejected, terminates", function()
		-- Hand-wire each projection's input at the OTHER reachable claim instead of
		-- a fixpoint. The checker validates the input IS a fixpoint claim before
		-- consulting acceptance, so each is rejected (checked and refused) rather
		-- than entering a stuck cycle. The run terminates; nothing accepts.
		local state = A.new_state()
		local registry = A.new_registry(); D.register(registry)
		local g = add_graph(state, "g", cyclic_graph())
		local rA = D.reachable_claim(A.id("claim", "rA"), g, "a")
		local rB = D.reachable_claim(A.id("claim", "rB"), g, "b")
		A.add_claim(state, rA); A.add_claim(state, rB)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eA"), claim = rA.id, method = "witness_projection", inputs = { rB.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eB"), claim = rB.id, method = "witness_projection", inputs = { rA.id } }))
		local res = A.check({ state = state, requested_claims = { rA.id, rB.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.fail(has(res.accepted_claims, rA), "rA not accepted")
		T.fail(has(res.accepted_claims, rB), "rB not accepted")
		T.ok(has(res.rejected_claims, rA), "rA rejected: input is not a fixpoint claim")
		T.ok(has(res.rejected_claims, rB), "rB rejected: input is not a fixpoint claim")
	end)

	T.it("the substrate's existing cycle-detection-as-error is unchanged (prop probe)", function()
		-- The cyclic/fixpoint rung does NOT change cycle-detection-as-error. The
		-- prop semantics still exercises a genuine evidence cycle that the substrate
		-- detects and settles with a diagnostic (see substrate_test.lua). Here we
		-- re-assert the contract holds: a mutually-blocked prop cycle terminates,
		-- accepts nothing, and emits a cycle diagnostic -- proving the dataflow rung
		-- needed no change to that behaviour.
		local state = A.new_state()
		local registry = A.new_registry(); P.register(registry)
		local cP = P.holds_claim(A.id("claim", "cP"), P.p_and(P.atom("Q"), P.atom("Z")))
		local cQ = P.holds_claim(A.id("claim", "cQ"), P.p_and(P.atom("P"), P.atom("Z")))
		local cZ = P.holds_claim(A.id("claim", "cZ"), P.atom("Z"))
		local cQi = P.holds_claim(A.id("claim", "cQi"), P.atom("Q"))
		local cPi = P.holds_claim(A.id("claim", "cPi"), P.atom("P"))
		A.add_claim(state, cP); A.add_claim(state, cQ); A.add_claim(state, cZ)
		A.add_claim(state, cQi); A.add_claim(state, cPi)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eP"), claim = cP.id, method = "and_intro", inputs = { cQi.id, cZ.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eQ"), claim = cQ.id, method = "and_intro", inputs = { cPi.id, cZ.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eQi"), claim = cQi.id, method = "and_elim_left", inputs = { cP.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ePi"), claim = cPi.id, method = "and_elim_left", inputs = { cQ.id } }))
		local res = A.check({ state = state, requested_claims = { cP.id, cQ.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.eq(count(res.accepted_claims), 0, "cyclic evidence accepts nothing")
		local cyc = false
		for _, d in ipairs(res.diagnostics) do if d:find("[Cc]ycle") then cyc = true end end
		T.ok(cyc, "cycle diagnostic emitted -- detection-as-error unchanged by this rung")
	end)
end)
