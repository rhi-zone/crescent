local T = require("lib.test.assert")
local A = require("lib.type.analysis")
local L = require("lib.type.analysis.lambda")

--: () -> SemanticsRegistry
local function reg()
	local r = A.new_registry()
	L.register(r)
	return r
end

--: ({ [string]: Claim }, Claim) -> boolean
local function has(map, claim)
	return map[A.claim_key(claim)] ~= nil
end

-- Add a term artifact and return its Id.
--: (AnalysisState, string, LamTerm) -> Id
local function add_term(state, key, term)
	local id = A.id("artifact", key)
	A.add_artifact(state, A.artifact({ id = id, kind = "syntax_tree", content_ref = term }))
	return id
end

-- Does the dependency graph contain an edge from `claim` to target id?
--: (CheckResult, Claim, string) -> boolean
local function dep_to(res, claim, target_key)
	for _, d in ipairs(res.dependency_graph) do
		if d.from_claim.key == claim.id.key and d.target.key == target_key then
			return true
		end
	end
	return false
end

T.describe("lambda.untyped.min", function()
	T.it("alpha acceptance: lam x.x  vs  lam y.y", function()
		local state = A.new_state()
		local registry = reg()
		local t1 = add_term(state, "t1", L.lam("x", L.var("x")))
		local t2 = add_term(state, "t2", L.lam("y", L.var("y")))
		local c1 = L.well_formed_claim(A.id("claim", "c1"), t1)
		local c2 = L.well_formed_claim(A.id("claim", "c2"), t2)
		local c3 = L.alpha_eq_claim(A.id("claim", "c3"), t1, t2)
		A.add_claim(state, c1); A.add_claim(state, c2); A.add_claim(state, c3)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "e1"), claim = c1.id, method = "artifact_shape_check" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "e2"), claim = c2.id, method = "artifact_shape_check" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "e3"), claim = c3.id, method = "alpha_normal_form", inputs = { c1.id, c2.id } }))
		local res = A.check({ state = state, requested_claims = { c1.id, c2.id, c3.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c1), "c1 well_formed")
		T.ok(has(res.accepted_claims, c2), "c2 well_formed")
		T.ok(has(res.accepted_claims, c3), "c3 alpha_eq accepted")
		T.ok(dep_to(res, c3, "t1"), "c3 depends on artifact t1")
		T.ok(dep_to(res, c3, "t2"), "c3 depends on artifact t2")
	end)

	T.it("beta acceptance: (lam x.x) z  ->  z", function()
		local state = A.new_state()
		local registry = reg()
		local src = add_term(state, "src", L.app(L.lam("x", L.var("x")), L.var("z")))
		local tgt = add_term(state, "tgt", L.var("z"))
		local cs = L.well_formed_claim(A.id("claim", "cs"), src)
		local ct = L.well_formed_claim(A.id("claim", "ct"), tgt)
		local cstep = L.steps_to_claim(A.id("claim", "cstep"), src, tgt)
		A.add_claim(state, cs); A.add_claim(state, ct); A.add_claim(state, cstep)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "es"), claim = cs.id, method = "artifact_shape_check" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "et"), claim = ct.id, method = "artifact_shape_check" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "estep"), claim = cstep.id, method = "beta_step", inputs = { cs.id, ct.id } }))
		local res = A.check({ state = state, requested_claims = { cs.id, ct.id, cstep.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, cstep), "beta step accepted")
	end)

	T.it("beta with capture avoidance: (lam x. lam y. x) y  ->  lam y1. y, with cross-evidence not_free dependency", function()
		local state = A.new_state()
		local registry = reg()
		-- source = app(lam x (lam y x), var y); target = lam y1. y
		local src = add_term(state, "src", L.app(L.lam("x", L.lam("y", L.var("x"))), L.var("y")))
		local tgt = add_term(state, "tgt", L.lam("y1", L.var("y")))
		-- arg artifact (the var("y") subterm) for the free_in claim.
		local arg = add_term(state, "arg", L.var("y"))
		local cs = L.well_formed_claim(A.id("claim", "cs"), src)
		local ct = L.well_formed_claim(A.id("claim", "ct"), tgt)
		local carg = L.well_formed_claim(A.id("claim", "carg"), arg)
		local c_arg_fy = L.free_in_claim(A.id("claim", "c_arg_fy"), "y", arg)
		local cstep = L.steps_to_claim(A.id("claim", "cstep"), src, tgt)
		A.add_claim(state, cs); A.add_claim(state, ct); A.add_claim(state, carg)
		A.add_claim(state, c_arg_fy); A.add_claim(state, cstep)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "es"), claim = cs.id, method = "artifact_shape_check" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "et"), claim = ct.id, method = "artifact_shape_check" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "earg"), claim = carg.id, method = "artifact_shape_check" }))
		-- free_var_scan produces free_in("y", arg) as SEPARATE evidence.
		A.add_evidence(state, A.evidence({ id = A.id("ev", "e_arg_fy"), claim = c_arg_fy.id, method = "free_var_scan", inputs = { carg.id } }))
		-- beta_step consumes the cross-evidence free_in claim.
		A.add_evidence(state, A.evidence({ id = A.id("ev", "estep"), claim = cstep.id, method = "beta_step",
			inputs = { cs.id, ct.id, c_arg_fy.id } }))
		local res = A.check({ state = state, requested_claims = { cs.id, ct.id, carg.id, c_arg_fy.id, cstep.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c_arg_fy), "free_in(y, arg) accepted by free_var_scan")
		T.ok(has(res.accepted_claims, cstep), "capture-avoiding beta step accepted")
		-- The load-bearing point: the cross-evidence dependency is visible.
		T.ok(dep_to(res, cstep, "c_arg_fy"), "cstep depends on c_arg_fy (cross-evidence capture-avoidance dependency)")
	end)

	T.it("beta capture WITHOUT the discharge claim is rejected", function()
		local state = A.new_state()
		local registry = reg()
		local src = add_term(state, "src", L.app(L.lam("x", L.lam("y", L.var("x"))), L.var("y")))
		local tgt = add_term(state, "tgt", L.lam("y1", L.var("y")))
		local cs = L.well_formed_claim(A.id("claim", "cs"), src)
		local ct = L.well_formed_claim(A.id("claim", "ct"), tgt)
		local cstep = L.steps_to_claim(A.id("claim", "cstep"), src, tgt)
		A.add_claim(state, cs); A.add_claim(state, ct); A.add_claim(state, cstep)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "es"), claim = cs.id, method = "artifact_shape_check" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "et"), claim = ct.id, method = "artifact_shape_check" }))
		-- beta_step WITHOUT the free_in discharge input.
		A.add_evidence(state, A.evidence({ id = A.id("ev", "estep"), claim = cstep.id, method = "beta_step", inputs = { cs.id, ct.id } }))
		local res = A.check({ state = state, requested_claims = { cstep.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.fail(has(res.accepted_claims, cstep), "must not accept without discharge")
		T.ok(has(res.rejected_claims, cstep), "rejected for undischarged capture side condition")
	end)

	T.it("unknown is not negative: free_in with no evidence stays unknown, does not accept not_free_in", function()
		local state = A.new_state()
		local registry = reg()
		local t = add_term(state, "t", L.lam("z", L.var("z")))
		local cfree = L.free_in_claim(A.id("claim", "cfree"), "x", t)
		local cnfree = L.not_free_in_claim(A.id("claim", "cnfree"), "x", t)
		A.add_claim(state, cfree); A.add_claim(state, cnfree)
		-- No evidence supplied for either.
		local res = A.check({ state = state, requested_claims = { cfree.id, cnfree.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.unknown_claims, cfree), "free_in unknown")
		T.ok(has(res.unknown_claims, cnfree), "not_free_in unknown")
		T.fail(has(res.accepted_claims, cnfree), "absence of free_in does NOT accept not_free_in")
	end)

	T.it("rejected evidence: beta_step to a wrong target rejects, claim not accepted", function()
		local state = A.new_state()
		local registry = reg()
		-- (lam x.x) z  steps to z, but the claim names w.
		local src = add_term(state, "src", L.app(L.lam("x", L.var("x")), L.var("z")))
		local tgt = add_term(state, "tgt", L.var("w"))
		local cs = L.well_formed_claim(A.id("claim", "cs"), src)
		local ct = L.well_formed_claim(A.id("claim", "ct"), tgt)
		local cstep = L.steps_to_claim(A.id("claim", "cstep"), src, tgt)
		A.add_claim(state, cs); A.add_claim(state, ct); A.add_claim(state, cstep)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "es"), claim = cs.id, method = "artifact_shape_check" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "et"), claim = ct.id, method = "artifact_shape_check" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "estep"), claim = cstep.id, method = "beta_step", inputs = { cs.id, ct.id } }))
		local res = A.check({ state = state, requested_claims = { cstep.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.fail(has(res.accepted_claims, cstep), "wrong target not accepted")
		T.ok(has(res.rejected_claims, cstep), "wrong target rejected")
	end)

	T.it("not_free_in accepted by a positive free_var_scan", function()
		local state = A.new_state()
		local registry = reg()
		local t = add_term(state, "t", L.lam("z", L.var("z")))
		local cwf = L.well_formed_claim(A.id("claim", "cwf"), t)
		local cnf = L.not_free_in_claim(A.id("claim", "cnf"), "x", t)
		A.add_claim(state, cwf); A.add_claim(state, cnf)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ewf"), claim = cwf.id, method = "artifact_shape_check" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "enf"), claim = cnf.id, method = "free_var_scan", inputs = { cwf.id } }))
		local res = A.check({ state = state, requested_claims = { cnf.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, cnf), "not_free_in('x', lam z.z) accepted")
	end)

	T.it("adversarial: has_type is not a claim predicate => rejected", function()
		local state = A.new_state()
		local registry = reg()
		local bad = A.claim({ id = A.id("claim", "bad"), semantics = L.ID, predicate = "well_formed",
			args = { term = { space = "artifact", key = "nope" } } })
		-- malformed term artifact (a number, not a LamTerm).
		A.add_artifact(state, A.artifact({ id = A.id("artifact", "nope"), kind = "syntax_tree", content_ref = 42 }))
		A.add_claim(state, bad)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ebad"), claim = bad.id, method = "artifact_shape_check" }))
		local res = A.check({ state = state, requested_claims = { bad.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.fail(has(res.accepted_claims, bad), "malformed term not accepted")
	end)

	T.it("adversarial: a claim predicate not in the semantics is rejected by the registry", function()
		local state = A.new_state()
		local registry = reg()
		local bad = A.claim({ id = A.id("claim", "bad"), semantics = L.ID, predicate = "has_type",
			args = { term = { space = "artifact", key = "t" }, type = "Int" } })
		A.add_claim(state, bad)
		local res, err = A.check({ state = state, requested_claims = { bad.id }, semantics_registry = registry })
		T.fail(res, "ill-formed: has_type not a claim predicate")
		T.ok(err and err:find("has_type"), "error names has_type")
	end)
end)
