local T = require("lib.test.assert")
local A = require("lib.type.analysis")
local S = require("lib.type.analysis.stlc")

--: () -> SemanticsRegistry
local function reg()
	local r = A.new_registry()
	S.register(r)
	return r
end

--: ({ [string]: Claim }, Claim) -> boolean
local function has(map, claim)
	return map[A.claim_key(claim)] ~= nil
end

--: ({ [string]: Claim }) -> integer
local function count(map)
	local n = 0
	for _ in pairs(map) do n = n + 1 end
	return n
end

-- Add a term artifact and return its Id.
--: (AnalysisState, string, StTerm) -> Id
local function add_term(state, key, term)
	local id = A.id("artifact", key)
	A.add_artifact(state, A.artifact({ id = id, kind = "syntax_tree", content_ref = term }))
	return id
end

-- Does the dependency graph contain an edge from `claim` to target key?
--: (CheckResult, Claim, string) -> boolean
local function dep_to(res, claim, target_key)
	for _, d in ipairs(res.dependency_graph) do
		if d.from_claim.key == claim.id.key and d.target.key == target_key then
			return true
		end
	end
	return false
end

T.describe("stlc.min: identity rule (var/abs)", function()
	-- WORKED EXAMPLE 1 (acceptance): ⊢ (λx:A. x) : A→A.
	-- Two-level derivation: abs over a var premise.
	--   premise:    x:A ⊢ x : A             (var_rule)
	--   conclusion: ⊢ (λx:A. x) : A→A       (abs_rule, input = premise)
	T.it("⊢ (λx:A. x) : A→A  via abs over var (two-level derivation)", function()
		local state = A.new_state()
		local registry = reg()
		local A_t = S.base("A")
		-- body artifact: var x ; identity artifact: λx:A. x
		local body = add_term(state, "body", S.var("x"))
		local ident = add_term(state, "ident", S.lam("x", A_t, S.var("x")))
		-- premise claim: (x:A) ⊢ x : A
		local gamma_x = S.extend(S.empty_ctx(), "x", A_t)
		local cprem = S.has_type_claim(A.id("claim", "cprem"), gamma_x, body, A_t)
		-- conclusion claim: ⊢ (λx:A. x) : A→A
		local concl = S.has_type_claim(A.id("claim", "concl"), S.empty_ctx(), ident, S.arrow(A_t, A_t))
		A.add_claim(state, cprem); A.add_claim(state, concl)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eprem"), claim = cprem.id, method = "var_rule" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "econcl"), claim = concl.id, method = "abs_rule", inputs = { cprem.id } }))
		local res = A.check({ state = state, requested_claims = { cprem.id, concl.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, cprem), "x:A ⊢ x : A accepted (var)")
		T.ok(has(res.accepted_claims, concl), "⊢ (λx:A. x) : A→A accepted (abs over var)")
		-- The deep-evidence edge is visible: conclusion depends on the premise claim.
		T.ok(dep_to(res, concl, "cprem"), "conclusion depends on the var premise claim (deep evidence)")
		T.ok(dep_to(res, concl, "ident"), "conclusion depends on its term artifact")
	end)
end)

T.describe("stlc.min: application (three-level derivation)", function()
	-- WORKED EXAMPLE 2 (acceptance): f:A→B, a:A ⊢ (f a) : B.
	-- app over two var premises (a two-level tree; combined with abs below it
	-- becomes three-level).
	T.it("f:A→B, a:A ⊢ (f a) : B  via app over two vars", function()
		local state = A.new_state()
		local registry = reg()
		local A_t, B_t = S.base("A"), S.base("B")
		local AB = S.arrow(A_t, B_t)
		local tf = add_term(state, "tf", S.var("f"))
		local ta = add_term(state, "ta", S.var("a"))
		local tapp = add_term(state, "tapp", S.app(S.var("f"), S.var("a")))
		local gamma = S.extend(S.extend(S.empty_ctx(), "f", AB), "a", A_t)
		local cf = S.has_type_claim(A.id("claim", "cf"), gamma, tf, AB)
		local ca = S.has_type_claim(A.id("claim", "ca"), gamma, ta, A_t)
		local capp = S.has_type_claim(A.id("claim", "capp"), gamma, tapp, B_t)
		A.add_claim(state, cf); A.add_claim(state, ca); A.add_claim(state, capp)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ef"), claim = cf.id, method = "var_rule" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ea"), claim = ca.id, method = "var_rule" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eapp"), claim = capp.id, method = "app_rule", inputs = { cf.id, ca.id } }))
		local res = A.check({ state = state, requested_claims = { cf.id, ca.id, capp.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, capp), "f:A→B, a:A ⊢ (f a) : B accepted")
		T.ok(dep_to(res, capp, "cf"), "app depends on fn premise")
		T.ok(dep_to(res, capp, "ca"), "app depends on arg premise")
	end)

	-- A genuinely three-level derivation: ⊢ (λf:A→B. λa:A. f a) : (A→B)→A→B.
	T.it("⊢ (λf:A→B. λa:A. f a) : (A→B)→(A→B)  three-level abs/abs/app", function()
		local state = A.new_state()
		local registry = reg()
		local A_t, B_t = S.base("A"), S.base("B")
		local AB = S.arrow(A_t, B_t)
		-- innermost premises under Γ = f:A→B, a:A
		local g2 = S.extend(S.extend(S.empty_ctx(), "f", AB), "a", A_t)
		local tf = add_term(state, "tf", S.var("f"))
		local ta = add_term(state, "ta", S.var("a"))
		local tapp = add_term(state, "tapp", S.app(S.var("f"), S.var("a")))
		local cf = S.has_type_claim(A.id("claim", "cf"), g2, tf, AB)
		local ca = S.has_type_claim(A.id("claim", "ca"), g2, ta, A_t)
		local capp = S.has_type_claim(A.id("claim", "capp"), g2, tapp, B_t)
		-- middle: Γ1 = f:A→B ⊢ (λa:A. f a) : A→B
		local g1 = S.extend(S.empty_ctx(), "f", AB)
		local tinner = add_term(state, "tinner", S.lam("a", A_t, S.app(S.var("f"), S.var("a"))))
		local cinner = S.has_type_claim(A.id("claim", "cinner"), g1, tinner, AB)
		-- outer: ⊢ (λf:A→B. λa:A. f a) : (A→B)→(A→B)
		local touter = add_term(state, "touter", S.lam("f", AB, S.lam("a", A_t, S.app(S.var("f"), S.var("a")))))
		local couter = S.has_type_claim(A.id("claim", "couter"), S.empty_ctx(), touter, S.arrow(AB, AB))
		A.add_claim(state, cf); A.add_claim(state, ca); A.add_claim(state, capp)
		A.add_claim(state, cinner); A.add_claim(state, couter)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ef"), claim = cf.id, method = "var_rule" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ea"), claim = ca.id, method = "var_rule" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eapp"), claim = capp.id, method = "app_rule", inputs = { cf.id, ca.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "einner"), claim = cinner.id, method = "abs_rule", inputs = { capp.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eouter"), claim = couter.id, method = "abs_rule", inputs = { cinner.id } }))
		local res = A.check({ state = state, requested_claims = { couter.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, couter), "three-level derivation accepted")
	end)
end)

T.describe("stlc.min: rejection of ill-typed terms", function()
	-- WORKED EXAMPLE 3 (rejection): self-application (λx:A. x x) is ill-typed —
	-- x:A is applied to x:A, but A is not an arrow. app_rule must reject.
	T.it("x:A ⊢ (x x) : ? rejected — applying a non-arrow", function()
		local state = A.new_state()
		local registry = reg()
		local A_t = S.base("A")
		local tx = add_term(state, "tx", S.var("x"))
		local txx = add_term(state, "txx", S.app(S.var("x"), S.var("x")))
		local gamma = S.extend(S.empty_ctx(), "x", A_t)
		local cx = S.has_type_claim(A.id("claim", "cx"), gamma, tx, A_t)
		-- Claim x x : A (arbitrary) — app_rule should reject because fn premise type A is not an arrow.
		local cxx = S.has_type_claim(A.id("claim", "cxx"), gamma, txx, A_t)
		A.add_claim(state, cx); A.add_claim(state, cxx)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ex"), claim = cx.id, method = "var_rule" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "exx"), claim = cxx.id, method = "app_rule", inputs = { cx.id, cx.id } }))
		local res = A.check({ state = state, requested_claims = { cxx.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.fail(has(res.accepted_claims, cxx), "self-application not accepted")
		T.ok(has(res.rejected_claims, cxx), "self-application rejected (function premise is not an arrow)")
	end)

	T.it("abs_rule rejects when the asserted arrow domain ≠ binder annotation", function()
		local state = A.new_state()
		local registry = reg()
		local A_t, B_t = S.base("A"), S.base("B")
		local body = add_term(state, "body", S.var("x"))
		local ident = add_term(state, "ident", S.lam("x", A_t, S.var("x")))
		local gamma_x = S.extend(S.empty_ctx(), "x", A_t)
		local cprem = S.has_type_claim(A.id("claim", "cprem"), gamma_x, body, A_t)
		-- Assert the WRONG arrow B→A (domain B ≠ binder annotation A).
		local concl = S.has_type_claim(A.id("claim", "concl"), S.empty_ctx(), ident, S.arrow(B_t, A_t))
		A.add_claim(state, cprem); A.add_claim(state, concl)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eprem"), claim = cprem.id, method = "var_rule" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "econcl"), claim = concl.id, method = "abs_rule", inputs = { cprem.id } }))
		local res = A.check({ state = state, requested_claims = { concl.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.rejected_claims, concl), "wrong arrow domain rejected")
	end)

	T.it("var_rule rejects an unbound variable", function()
		local state = A.new_state()
		local registry = reg()
		local A_t = S.base("A")
		local ty = add_term(state, "ty", S.var("y"))
		-- Γ binds x, not y.
		local gamma = S.extend(S.empty_ctx(), "x", A_t)
		local cy = S.has_type_claim(A.id("claim", "cy"), gamma, ty, A_t)
		A.add_claim(state, cy)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ey"), claim = cy.id, method = "var_rule" }))
		local res = A.check({ state = state, requested_claims = { cy.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.rejected_claims, cy), "unbound variable rejected")
	end)

	T.it("app_rule rejects an argument-type mismatch", function()
		local state = A.new_state()
		local registry = reg()
		local A_t, B_t, C_t = S.base("A"), S.base("B"), S.base("C")
		local AB = S.arrow(A_t, B_t)
		local tf = add_term(state, "tf", S.var("f"))
		local ta = add_term(state, "ta", S.var("a"))
		local tapp = add_term(state, "tapp", S.app(S.var("f"), S.var("a")))
		-- a is bound to C, but f expects A.
		local gamma = S.extend(S.extend(S.empty_ctx(), "f", AB), "a", C_t)
		local cf = S.has_type_claim(A.id("claim", "cf"), gamma, tf, AB)
		local ca = S.has_type_claim(A.id("claim", "ca"), gamma, ta, C_t)
		local capp = S.has_type_claim(A.id("claim", "capp"), gamma, tapp, B_t)
		A.add_claim(state, cf); A.add_claim(state, ca); A.add_claim(state, capp)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ef"), claim = cf.id, method = "var_rule" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ea"), claim = ca.id, method = "var_rule" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eapp"), claim = capp.id, method = "app_rule", inputs = { cf.id, ca.id } }))
		local res = A.check({ state = state, requested_claims = { capp.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.rejected_claims, capp), "argument-type mismatch rejected")
	end)
end)

T.describe("stlc.min: unknown propagation through a deep derivation", function()
	-- WORKED EXAMPLE 4 (unknown propagation): the innermost var premise has NO
	-- evidence, so it is unknown; the abs above it cannot fire, and the whole
	-- chain stays unknown — never rejected (unknown ≠ refused).
	T.it("missing var evidence => abs and any chain above stay unknown, nothing rejected", function()
		local state = A.new_state()
		local registry = reg()
		local A_t = S.base("A")
		local body = add_term(state, "body", S.var("x"))
		local ident = add_term(state, "ident", S.lam("x", A_t, S.var("x")))
		local gamma_x = S.extend(S.empty_ctx(), "x", A_t)
		local cprem = S.has_type_claim(A.id("claim", "cprem"), gamma_x, body, A_t)
		local concl = S.has_type_claim(A.id("claim", "concl"), S.empty_ctx(), ident, S.arrow(A_t, A_t))
		A.add_claim(state, cprem); A.add_claim(state, concl)
		-- cprem has NO evidence => unknown. abs_rule for concl depends on it.
		A.add_evidence(state, A.evidence({ id = A.id("ev", "econcl"), claim = concl.id, method = "abs_rule", inputs = { cprem.id } }))
		local res = A.check({ state = state, requested_claims = { cprem.id, concl.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.unknown_claims, cprem), "var premise unknown (no evidence)")
		T.ok(has(res.unknown_claims, concl), "abs conclusion unknown (premise unavailable)")
		T.eq(count(res.rejected_claims), 0, "nothing rejected — unavailable is not refused")
	end)
end)

T.describe("stlc.min: shuffled-order convergence", function()
	-- The three-level derivation, with evidence submitted in every order. The
	-- worklist fixpoint must converge to the same accepted set regardless of
	-- submission order (deep evidence trees were the new pressure this rung adds).
	--: () -> (AnalysisState, SemanticsRegistry, { [integer]: Evidence }, Claim)
	local function build()
		local state = A.new_state()
		local registry = reg()
		local A_t, B_t = S.base("A"), S.base("B")
		local AB = S.arrow(A_t, B_t)
		local g2 = S.extend(S.extend(S.empty_ctx(), "f", AB), "a", A_t)
		local tf = add_term(state, "tf", S.var("f"))
		local ta = add_term(state, "ta", S.var("a"))
		local tapp = add_term(state, "tapp", S.app(S.var("f"), S.var("a")))
		local cf = S.has_type_claim(A.id("claim", "cf"), g2, tf, AB)
		local ca = S.has_type_claim(A.id("claim", "ca"), g2, ta, A_t)
		local capp = S.has_type_claim(A.id("claim", "capp"), g2, tapp, B_t)
		local g1 = S.extend(S.empty_ctx(), "f", AB)
		local tinner = add_term(state, "tinner", S.lam("a", A_t, S.app(S.var("f"), S.var("a"))))
		local cinner = S.has_type_claim(A.id("claim", "cinner"), g1, tinner, AB)
		local touter = add_term(state, "touter", S.lam("f", AB, S.lam("a", A_t, S.app(S.var("f"), S.var("a")))))
		local couter = S.has_type_claim(A.id("claim", "couter"), S.empty_ctx(), touter, S.arrow(AB, AB))
		A.add_claim(state, cf); A.add_claim(state, ca); A.add_claim(state, capp)
		A.add_claim(state, cinner); A.add_claim(state, couter)
		local evs = {
			A.evidence({ id = A.id("ev", "eouter"), claim = couter.id, method = "abs_rule", inputs = { cinner.id } }),
			A.evidence({ id = A.id("ev", "einner"), claim = cinner.id, method = "abs_rule", inputs = { capp.id } }),
			A.evidence({ id = A.id("ev", "eapp"), claim = capp.id, method = "app_rule", inputs = { cf.id, ca.id } }),
			A.evidence({ id = A.id("ev", "ef"), claim = cf.id, method = "var_rule" }),
			A.evidence({ id = A.id("ev", "ea"), claim = ca.id, method = "var_rule" }),
		}
		return state, registry, evs, couter
	end

	T.it("every submission order accepts the full derivation", function()
		-- a few representative permutations: reverse, leaves-first, conclusion-first.
		local orders = { { 1, 2, 3, 4, 5 }, { 5, 4, 3, 2, 1 }, { 4, 5, 3, 2, 1 }, { 1, 3, 2, 5, 4 }, { 3, 1, 5, 2, 4 } }
		for _, ord in ipairs(orders) do
			local state, registry, evs, couter = build()
			for _, idx in ipairs(ord) do A.add_evidence(state, evs[idx]) end
			local res = A.check({ state = state, requested_claims = { couter.id }, semantics_registry = registry })
			if not res then T.fail(true, "no result"); return end
			T.ok(has(res.accepted_claims, couter), "three-level derivation accepted regardless of evidence order")
		end
	end)
end)

T.describe("stlc.min: claim identity under context", function()
	-- THE LOAD-BEARING PROBE for open question 4. Γ is part of structural claim
	-- identity. has_type(Γ1, t, T) and has_type(Γ2, t, T) must be DISTINCT claims.
	T.it("has_type(Γ1, t, T) and has_type(Γ2, t, T) are distinct claims when Γ differs", function()
		local A_t, B_t = S.base("A"), S.base("B")
		local tref = A.id("artifact", "x")
		local g1 = S.extend(S.empty_ctx(), "x", A_t)
		local g2 = S.extend(S.empty_ctx(), "x", B_t)
		local c1 = S.has_type_claim(A.id("claim", "c1"), g1, tref, A_t)
		local c2 = S.has_type_claim(A.id("claim", "c2"), g2, tref, A_t)
		T.neq(A.claim_key(c1), A.claim_key(c2), "different Γ => different claim key (context is in structural identity)")
	end)

	T.it("same Γ contents in same order => same claim key (identity stable)", function()
		local A_t = S.base("A")
		local tref = A.id("artifact", "x")
		local g1 = S.extend(S.empty_ctx(), "x", A_t)
		local g2 = S.extend(S.empty_ctx(), "x", A_t)
		local c1 = S.has_type_claim(A.id("claim", "c1"), g1, tref, A_t)
		local c2 = S.has_type_claim(A.id("claim", "c2"), g2, tref, A_t)
		T.eq(A.claim_key(c1), A.claim_key(c2), "structurally identical Γ => same claim key")
	end)

	T.it("binding ORDER is part of identity (Γ is a list, shadowing matters)", function()
		local A_t, B_t = S.base("A"), S.base("B")
		local tref = A.id("artifact", "x")
		-- [x:A, x:B]  vs  [x:B, x:A] : different lookup result for x, distinct claims.
		local g1 = S.extend(S.extend(S.empty_ctx(), "x", A_t), "x", B_t)
		local g2 = S.extend(S.extend(S.empty_ctx(), "x", B_t), "x", A_t)
		local c1 = S.has_type_claim(A.id("claim", "c1"), g1, tref, B_t)
		local c2 = S.has_type_claim(A.id("claim", "c2"), g2, tref, A_t)
		T.neq(A.claim_key(c1), A.claim_key(c2), "binding order distinguishes claims")
	end)

	-- Context extension across separately-evidenced claims really works: the abs
	-- premise's context is Γ,x:A produced by a SEPARATE has_type claim, and the
	-- abs_rule checks the structural match. This is the cross-claim context test.
	T.it("context extension Γ,x:A links abs conclusion to a separately-evidenced premise", function()
		local state = A.new_state()
		local registry = reg()
		local A_t = S.base("A")
		local body = add_term(state, "body", S.var("x"))
		local ident = add_term(state, "ident", S.lam("x", A_t, S.var("x")))
		-- premise lives under the extended context, evidenced by its own var_rule.
		local gamma_x = S.extend(S.empty_ctx(), "x", A_t)
		local cprem = S.has_type_claim(A.id("claim", "cprem"), gamma_x, body, A_t)
		local concl = S.has_type_claim(A.id("claim", "concl"), S.empty_ctx(), ident, S.arrow(A_t, A_t))
		A.add_claim(state, cprem); A.add_claim(state, concl)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eprem"), claim = cprem.id, method = "var_rule" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "econcl"), claim = concl.id, method = "abs_rule", inputs = { cprem.id } }))
		local res = A.check({ state = state, requested_claims = { concl.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, concl), "abs accepted via correctly-extended premise context")
	end)

	T.it("abs_rule rejects a premise under the WRONG context (extension mismatch)", function()
		local state = A.new_state()
		local registry = reg()
		local A_t, B_t = S.base("A"), S.base("B")
		local body = add_term(state, "body", S.var("x"))
		local ident = add_term(state, "ident", S.lam("x", A_t, S.var("x")))
		-- premise context wrongly binds x:B (should be x:A from the binder annotation).
		local wrong = S.extend(S.empty_ctx(), "x", B_t)
		local cprem = S.has_type_claim(A.id("claim", "cprem"), wrong, body, B_t)
		local concl = S.has_type_claim(A.id("claim", "concl"), S.empty_ctx(), ident, S.arrow(A_t, A_t))
		A.add_claim(state, cprem); A.add_claim(state, concl)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eprem"), claim = cprem.id, method = "var_rule" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "econcl"), claim = concl.id, method = "abs_rule", inputs = { cprem.id } }))
		local res = A.check({ state = state, requested_claims = { concl.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.rejected_claims, concl), "premise under wrong context rejected (Γ,x:A required)")
	end)
end)

T.describe("stlc.min: alpha interaction with types (arg-schema finding)", function()
	-- The position inherited from prior rungs: substrate claim identity is purely
	-- STRUCTURAL; alpha-equivalence of terms is hosted business. has_type(Γ, λx:A.x,
	-- A→A) and its alpha-variant has_type(Γ, λy:A.y, A→A) are DISTINCT substrate
	-- claims. STLC does NOT need them unified — each is derived independently with
	-- its own var premise, and both succeed. Structural identity does not block STLC.
	T.it("has_type(λx:A.x, A→A) and has_type(λy:A.y, A→A) are distinct claims, both derivable", function()
		local state = A.new_state()
		local registry = reg()
		local A_t = S.base("A")
		local AA = S.arrow(A_t, A_t)
		-- variant 1: λx:A. x
		local bx = add_term(state, "bx", S.var("x"))
		local ix = add_term(state, "ix", S.lam("x", A_t, S.var("x")))
		local gx = S.extend(S.empty_ctx(), "x", A_t)
		local cpx = S.has_type_claim(A.id("claim", "cpx"), gx, bx, A_t)
		local ccx = S.has_type_claim(A.id("claim", "ccx"), S.empty_ctx(), ix, AA)
		-- variant 2: λy:A. y
		local by = add_term(state, "by", S.var("y"))
		local iy = add_term(state, "iy", S.lam("y", A_t, S.var("y")))
		local gy = S.extend(S.empty_ctx(), "y", A_t)
		local cpy = S.has_type_claim(A.id("claim", "cpy"), gy, by, A_t)
		local ccy = S.has_type_claim(A.id("claim", "ccy"), S.empty_ctx(), iy, AA)
		-- The two conclusions are distinct substrate claims (different term args).
		T.neq(A.claim_key(ccx), A.claim_key(ccy), "alpha-variant conclusions are distinct substrate claims")
		A.add_claim(state, cpx); A.add_claim(state, ccx); A.add_claim(state, cpy); A.add_claim(state, ccy)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "epx"), claim = cpx.id, method = "var_rule" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ecx"), claim = ccx.id, method = "abs_rule", inputs = { cpx.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "epy"), claim = cpy.id, method = "var_rule" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ecy"), claim = ccy.id, method = "abs_rule", inputs = { cpy.id } }))
		local res = A.check({ state = state, requested_claims = { ccx.id, ccy.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, ccx), "λx:A.x : A→A derivable")
		T.ok(has(res.accepted_claims, ccy), "λy:A.y : A→A derivable independently (no unification needed)")
	end)
end)

T.describe("stlc.min: trust boundary", function()
	T.it("trusted_type_axiom admits a typing under a visible trust boundary", function()
		local state = A.new_state()
		local registry = reg()
		local A_t = S.base("A")
		local tb = A.trust_boundary({ id = A.id("trust", "ffi"), kind = "ffi_signature", issuer = "test" })
		A.add_trust_boundary(state, tb)
		local ext = add_term(state, "ext", S.var("extern"))
		local c = S.has_type_claim(A.id("claim", "c"), S.empty_ctx(), ext, A_t)
		A.add_claim(state, c)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "e"), claim = c.id, method = "trusted_type_axiom", result = { trust = tb.id } }))
		local res = A.check({ state = state, requested_claims = { c.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c), "typing admitted under trust boundary")
		local ts = res.trust_summary[A.claim_key(c)]
		T.ok(ts ~= nil, "trust summary records the boundary")
	end)
end)

T.describe("stlc.min: adversarial — substrate stays agnostic", function()
	-- (1) Reject promoting type_of/subtype/context/binder to claim predicates.
	T.it("type_of is not a claim predicate => registry rejects the request", function()
		local state = A.new_state()
		local registry = reg()
		local bad = A.claim({ id = A.id("claim", "bad"), semantics = S.ID, predicate = "type_of",
			args = { term = { space = "artifact", key = "t" } } })
		A.add_claim(state, bad)
		local res, err = A.check({ state = state, requested_claims = { bad.id }, semantics_registry = registry })
		T.fail(res, "ill-formed: type_of not a claim predicate")
		T.ok(err and err:find("type_of"), "error names type_of")
	end)

	T.it("subtype is not a claim predicate => registry rejects", function()
		local state = A.new_state()
		local registry = reg()
		local bad = A.claim({ id = A.id("claim", "bad"), semantics = S.ID, predicate = "subtype",
			args = { a = S.base("A"), b = S.base("B") } })
		A.add_claim(state, bad)
		local res, err = A.check({ state = state, requested_claims = { bad.id }, semantics_registry = registry })
		T.fail(res, "ill-formed: subtype not a claim predicate")
		T.ok(err and err:find("subtype"), "error names subtype")
	end)

	-- (2) Reject evidence methods not in the registry contract.
	T.it("an evidence method not in the contract is rejected by the registry", function()
		local state = A.new_state()
		local registry = reg()
		local A_t = S.base("A")
		local tx = add_term(state, "tx", S.var("x"))
		local gamma = S.extend(S.empty_ctx(), "x", A_t)
		local c = S.has_type_claim(A.id("claim", "c"), gamma, tx, A_t)
		A.add_claim(state, c)
		-- 'unification' is not an admitted evidence method for stlc.min.
		A.add_evidence(state, A.evidence({ id = A.id("ev", "e"), claim = c.id, method = "unification" }))
		local res, err = A.check({ state = state, requested_claims = { c.id }, semantics_registry = registry })
		T.fail(res, "ill-formed: unification not an admitted method")
		T.ok(err and err:find("unification"), "error names the rejected method")
	end)

	-- (3) The substrate stores NO Type/Context/Judgment objects — walk the state.
	T.it("substrate stores no Type/Context/binder objects — every Id space is substrate-owned", function()
		local state = A.new_state()
		local registry = reg()
		local A_t = S.base("A")
		local body = add_term(state, "body", S.var("x"))
		local ident = add_term(state, "ident", S.lam("x", A_t, S.var("x")))
		local gamma_x = S.extend(S.empty_ctx(), "x", A_t)
		local cprem = S.has_type_claim(A.id("claim", "cprem"), gamma_x, body, A_t)
		local concl = S.has_type_claim(A.id("claim", "concl"), S.empty_ctx(), ident, S.arrow(A_t, A_t))
		A.add_claim(state, cprem); A.add_claim(state, concl)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eprem"), claim = cprem.id, method = "var_rule" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "econcl"), claim = concl.id, method = "abs_rule", inputs = { cprem.id } }))
		A.check({ state = state, requested_claims = { cprem.id, concl.id }, semantics_registry = registry })
		local allowed = { artifact = true, claim = true, ev = true, trust = true, observation = true }
		--: ({ [string]: unknown }) -> nil
		local function check_spaces(store)
			for k in pairs(store) do
				local space = k:match("^([^/]+)/") or "?"
				T.ok(allowed[space], "stored id space '" .. space .. "' is substrate-owned, not type/context/binder")
			end
		end
		check_spaces(state.artifacts)
		check_spaces(state.claims)
		check_spaces(state.evidence)
		check_spaces(state.trust_boundaries)
		check_spaces(state.observations)
		-- And: no claim or artifact carries a "Type"/"Context"/"Judgment" kind field
		-- that the substrate interprets. Artifacts are kind="syntax_tree"; the type
		-- and context live inside opaque claim args only.
		for _, art in pairs(state.artifacts) do
			T.eq(art.kind, "syntax_tree", "artifact kind is descriptive syntax_tree, not a substrate Type/Context kind")
		end
	end)
end)
