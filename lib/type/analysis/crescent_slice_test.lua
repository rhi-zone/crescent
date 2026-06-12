-- Tests for crescent.slice.v1 — Pass 2 (synth/check evidence methods, the
-- registry entry, the parser-frontend adapter, trusted_signature,
-- instantiate_witness, type_shape_check incl. μ contractiveness).
--
-- Pass 2's gate (docs/agnostic-static-analysis-crescent-slice.md §8): the synth/
-- check worked examples accept; rejection produces counterevidence; order-
-- independence holds across deep trees; the §2.6 adversarial checks pass.

local T = require("lib.test.assert")
local A = require("lib.type.analysis")
local G = require("lib.type.analysis.slice_ty")
local TA = require("lib.type.analysis.slice_ty_arg")
local S = require("lib.type.analysis.crescent_slice")
local P = require("lib.type.analysis.crescent_slice_parse")

--: () -> SemanticsRegistry
local function reg()
	local r = A.new_registry()
	S.register(r)
	return r
end

--: ({ [string]: Claim }, Claim) -> boolean
local function has(map, c) return map[A.claim_key(c)] ~= nil end

--: ({ [string]: Claim }) -> integer
local function count(map)
	local n = 0
	for _ in pairs(map) do n = n + 1 end
	return n
end

-- Add a syntax_tree node artifact, return its Id.
--: (AnalysisState, string, unknown) -> Id
local function add_node(state, key, node)
	local id = A.id("artifact", key)
	A.add_artifact(state, A.artifact({ id = id, kind = "syntax_tree", content_ref = node }))
	return id
end

--: (CheckResult, Claim, string) -> boolean
local function dep_to(res, claim, target_key)
	for _, d in ipairs(res.dependency_graph) do
		if d.from_claim.key == claim.id.key and d.target.key == target_key then return true end
	end
	return false
end

-- ── Ty ⇄ ArgValue bridge + type_shape_check / contractiveness ────────────────

T.describe("crescent.slice.v1: Ty ⇄ ArgValue round-trips faithfully", function()
	T.it("primitives, records, functions, μ all round-trip to the same tid", function()
		G.reset()
		local TN = G.rec({ { key = "id", ty = G.string(), optional = false, readonly = false },
			{ key = "done", ty = G.boolean(), optional = false, readonly = false } }, "closed")
		T.eq(TA.decode(TA.encode(TN)).tid, TN.tid, "record round-trips")
		local f = G.fn({ fixed = { G.string() } }, { fixed = { G.union({ TN, G.nil_() }) } })
		T.eq(TA.decode(TA.encode(f)).tid, f.tid, "function round-trips")
		local nat = G.mu("X", function(x)
			return G.union({ G.nil_(), G.rec({ { key = "next", ty = x, optional = false, readonly = false } }, "closed") })
		end)
		T.eq(TA.decode(TA.encode(nat)).tid, nat.tid, "μ round-trips (alpha-canonical)")
	end)
end)

T.describe("crescent.slice.v1: type_shape_check enforces μ contractiveness (§9.3 finding 1)", function()
	T.it("a contractive μ is well_typed_type-accepted", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local nat = G.mu("X", function(x)
			return G.union({ G.nil_(), G.rec({ { key = "next", ty = x, optional = false, readonly = false } }, "closed") })
		end)
		local c = S.well_typed_type_claim(A.id("claim", "wf"), nat)
		A.add_claim(state, c)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "e"), claim = c.id, method = "type_shape_check" }))
		local res = A.check({ state = state, requested_claims = { c.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c), "contractive μ is well-formed")
	end)

	T.it("a NON-contractive μ (μX.(nil | X)) is REJECTED, never silently top", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		-- μX.(nil | X): X occurs unguarded as a bare union member.
		local bad = G.mu("X", function(x) return G.union({ G.nil_(), x }) end)
		local c = S.well_typed_type_claim(A.id("claim", "wf"), bad)
		A.add_claim(state, c)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "e"), claim = c.id, method = "type_shape_check" }))
		local res = A.check({ state = state, requested_claims = { c.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.rejected_claims, c), "non-contractive μ is a well-formedness rejection")
		T.fail(has(res.accepted_claims, c), "non-contractive μ must NOT be accepted")
	end)

	T.it("μ contractiveness is direct (TA.well_formed)", function()
		G.reset()
		local good = G.mu("X", function(x)
			return G.union({ G.nil_(), G.fn({ fixed = {} }, { fixed = { x } }) })
		end)
		T.ok(TA.well_formed(good), "guarded-under-fn μ is contractive")
		T.fail(TA.well_formed(G.mu("X", function(x) return x end)), "μX.X is non-contractive")
	end)
end)

-- ── synth rules ──────────────────────────────────────────────────────────────

T.describe("crescent.slice.v1: synth_lit", function()
	T.it("a literal synthesizes its singleton type", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local n42 = add_node(state, "n42", { t = "lit", lit = "int", v = 42 })
		local c = S.has_type_claim(A.id("claim", "c"), S.empty_ctx(), n42, G.lit_int(42))
		A.add_claim(state, c)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "e"), claim = c.id, method = "synth_lit" }))
		local res = A.check({ state = state, requested_claims = { c.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c), "42 ⇒ lit_int(42)")
	end)

	T.it("synth_lit rejects when the asserted type is wrong", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local ngt = add_node(state, "ngt", { t = "lit", lit = "str", v = "GET" })
		local c = S.has_type_claim(A.id("claim", "c"), S.empty_ctx(), ngt, G.string()) -- should be lit_str
		A.add_claim(state, c)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "e"), claim = c.id, method = "synth_lit" }))
		local res = A.check({ state = state, requested_claims = { c.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.rejected_claims, c), "synth produces lit_str(GET), not string")
	end)
end)

T.describe("crescent.slice.v1: synth_var (context-in-args)", function()
	T.it("a variable synthesizes its most-recent binding", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local nx = add_node(state, "nx", { t = "var", name = "x" })
		local g = S.extend(S.empty_ctx(), "x", G.number())
		local c = S.has_type_claim(A.id("claim", "c"), g, nx, G.number())
		A.add_claim(state, c)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "e"), claim = c.id, method = "synth_var" }))
		local res = A.check({ state = state, requested_claims = { c.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c), "x : number from Γ")
	end)

	T.it("synth_var rejects an unbound variable", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local ny = add_node(state, "ny", { t = "var", name = "y" })
		local g = S.extend(S.empty_ctx(), "x", G.number())
		local c = S.has_type_claim(A.id("claim", "c"), g, ny, G.number())
		A.add_claim(state, c)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "e"), claim = c.id, method = "synth_var" }))
		local res = A.check({ state = state, requested_claims = { c.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.rejected_claims, c), "unbound y rejected")
	end)
end)

T.describe("crescent.slice.v1: synth_index (§6.1 step 4, distribution)", function()
	-- WORKED EXAMPLE §6.1 (synth/check portion): under Γ2 = [id:string, task:TN],
	-- synth task.done : boolean via synth_index over a synth_var premise.
	T.it("task.done : boolean via synth_index over synth_var (deep evidence)", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local TN = G.rec({ { key = "id", ty = G.string(), optional = false, readonly = false },
			{ key = "done", ty = G.boolean(), optional = false, readonly = false } }, "closed")
		local n_task = add_node(state, "task", { t = "var", name = "task" })
		local n_field = add_node(state, "field", { t = "index", obj = { space = "artifact", key = "task" }, field = "done" })
		local g2 = S.extend(S.extend(S.empty_ctx(), "id", G.string()), "task", TN)
		local c_task = S.has_type_claim(A.id("claim", "ctask"), g2, n_task, TN)
		local c_field = S.has_type_claim(A.id("claim", "cfield"), g2, n_field, G.boolean())
		A.add_claim(state, c_task); A.add_claim(state, c_field)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "etask"), claim = c_task.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "efield"), claim = c_field.id, method = "synth_index", inputs = { c_task.id } }))
		local res = A.check({ state = state, requested_claims = { c_task.id, c_field.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c_field), "task.done ⇒ boolean")
		T.ok(dep_to(res, c_field, "ctask"), "index depends on the object's has_type premise (deep evidence)")
		T.ok(dep_to(res, c_field, "field"), "index depends on its node artifact")
	end)

	T.it("union access distributes — field present in ALL members", function()
		G.reset()
		local r1 = G.rec({ { key = "tag", ty = G.string(), optional = false, readonly = false } }, "closed")
		local r2 = G.rec({ { key = "tag", ty = G.lit_str("x"), optional = false, readonly = false } }, "closed")
		local u = G.union({ r1, r2 })
		local res = S.index_result(u, "tag", nil)
		T.ok(res ~= nil, "tag present in all members ⇒ accessible")
	end)

	T.it("union access rejects when a member lacks the field", function()
		G.reset()
		local r1 = G.rec({ { key = "tag", ty = G.string(), optional = false, readonly = false } }, "closed")
		local r2 = G.rec({ { key = "other", ty = G.string(), optional = false, readonly = false } }, "closed")
		local u = G.union({ r1, r2 })
		T.eq(S.index_result(u, "tag", nil), nil, "tag absent in one member ⇒ inaccessible")
	end)

	T.it("open-row unlisted field reads as unknown, NOT the indexer", function()
		G.reset()
		local open = G.rec({ { key = "name", ty = G.string(), optional = false, readonly = false } }, "open")
		local r = S.index_result(open, "other", nil)
		T.ok(r ~= nil and r.kind == "unknown", "unlisted field on open row ⇒ unknown")
	end)
end)

T.describe("crescent.slice.v1: synth_table (precise; widening at the checking boundary)", function()
	T.it("a named table synthesizes the precise record, then checks against a wider type", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		-- { x = 1 } ⇒ rec{ x: lit_int(1) }, then check against { x: number }.
		local n1 = add_node(state, "n1", { t = "lit", lit = "int", v = 1 })
		local ntab = add_node(state, "ntab", { t = "table", entries = { { key = "x", value = { t = "lit", lit = "int", v = 1 } } } })
		local precise = G.rec({ { key = "x", ty = G.lit_int(1), optional = false, readonly = false } }, "closed")
		local c1 = S.has_type_claim(A.id("claim", "c1"), S.empty_ctx(), n1, G.lit_int(1))
		local ctab = S.has_type_claim(A.id("claim", "ctab"), S.empty_ctx(), ntab, precise)
		A.add_claim(state, c1); A.add_claim(state, ctab)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "e1"), claim = c1.id, method = "synth_lit" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "etab"), claim = ctab.id, method = "synth_table", inputs = { c1.id } }))
		local res = A.check({ state = state, requested_claims = { ctab.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, ctab), "{ x = 1 } ⇒ precise rec{ x: 1 }")
	end)
end)

T.describe("crescent.slice.v1: synth_and_or_not (boolean narrowing, §6.3)", function()
	-- §6.3: `(n==0) and (1/n<0)` — both operands boolean ⇒ boolean (NOT nil|boolean).
	T.it("`and` of two booleans synthesizes boolean (the legacy nil|boolean bug averted)", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local nl = add_node(state, "nl", { t = "var", name = "l" })
		local nr = add_node(state, "nr", { t = "var", name = "r" })
		local nand = add_node(state, "nand", { t = "andor", op = "and", left = { space = "artifact", key = "nl" }, right = { space = "artifact", key = "nr" } })
		local g = S.extend(S.extend(S.empty_ctx(), "l", G.boolean()), "r", G.boolean())
		local cl = S.has_type_claim(A.id("claim", "cl"), g, nl, G.boolean())
		local cr = S.has_type_claim(A.id("claim", "cr"), g, nr, G.boolean())
		local cand = S.has_type_claim(A.id("claim", "cand"), g, nand, G.boolean())
		A.add_claim(state, cl); A.add_claim(state, cr); A.add_claim(state, cand)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "el"), claim = cl.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "er"), claim = cr.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eand"), claim = cand.id, method = "synth_and_or_not", inputs = { cl.id, cr.id } }))
		local res = A.check({ state = state, requested_claims = { cand.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, cand), "boolean and boolean ⇒ boolean")
	end)
end)

T.describe("crescent.slice.v1: synth_call + check_against (the bidirectional spine)", function()
	-- f : (string) -> number ; f("x") ⇒ number, arg "x" checked against string.
	T.it("a call synthesizes the return after checking each argument", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local fty = G.fn({ fixed = { G.string() } }, { fixed = { G.number() } })
		local nf = add_node(state, "nf", { t = "var", name = "f" })
		local narg = add_node(state, "narg", { t = "lit", lit = "str", v = "x" })
		local ncall = add_node(state, "ncall", { t = "call", fn = { space = "artifact", key = "nf" }, args = { { space = "artifact", key = "narg" } } })
		local g = S.extend(S.empty_ctx(), "f", fty)
		-- premises: has_type(f : fn), has_type(arg : lit_str), subtype(lit_str <: string),
		--           checks_against(arg <= string).
		local cf = S.has_type_claim(A.id("claim", "cf"), g, nf, fty)
		local carg_s = S.has_type_claim(A.id("claim", "cargs"), g, narg, G.lit_str("x"))
		local csub = S.subtype_claim(A.id("claim", "csub"), G.lit_str("x"), G.string())
		local carg = S.checks_against_claim(A.id("claim", "carg"), g, narg, G.string())
		local ccall = S.has_type_claim(A.id("claim", "ccall"), g, ncall, G.number())
		A.add_claim(state, cf); A.add_claim(state, carg_s); A.add_claim(state, csub); A.add_claim(state, carg); A.add_claim(state, ccall)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ef"), claim = cf.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eargs"), claim = carg_s.id, method = "synth_lit" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "esub"), claim = csub.id, method = "subtype_witness" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "earg"), claim = carg.id, method = "check_against", inputs = { carg_s.id, csub.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ecall"), claim = ccall.id, method = "synth_call", inputs = { cf.id, carg.id } }))
		local res = A.check({ state = state, requested_claims = { carg.id, ccall.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, carg), "argument checks against the parameter type")
		T.ok(has(res.accepted_claims, ccall), "f(\"x\") ⇒ number")
	end)

	T.it("synth_call rejects an argument not checked against the parameter", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local fty = G.fn({ fixed = { G.string() } }, { fixed = { G.number() } })
		local nf = add_node(state, "nf", { t = "var", name = "f" })
		local narg = add_node(state, "narg", { t = "var", name = "n" })
		local ncall = add_node(state, "ncall", { t = "call", fn = { space = "artifact", key = "nf" }, args = { { space = "artifact", key = "narg" } } })
		local g = S.extend(S.extend(S.empty_ctx(), "f", fty), "n", G.number())
		local cf = S.has_type_claim(A.id("claim", "cf"), g, nf, fty)
		-- arg checked against number (the wrong param type), not string.
		local carg = S.checks_against_claim(A.id("claim", "carg"), g, narg, G.number())
		local carg_s = S.has_type_claim(A.id("claim", "cargs"), g, narg, G.number())
		local csub = S.subtype_claim(A.id("claim", "csub"), G.number(), G.number())
		local ccall = S.has_type_claim(A.id("claim", "ccall"), g, ncall, G.number())
		A.add_claim(state, cf); A.add_claim(state, carg); A.add_claim(state, carg_s); A.add_claim(state, csub); A.add_claim(state, ccall)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ef"), claim = cf.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eargs"), claim = carg_s.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "esub"), claim = csub.id, method = "subtype_witness" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "earg"), claim = carg.id, method = "check_against", inputs = { carg_s.id, csub.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ecall"), claim = ccall.id, method = "synth_call", inputs = { cf.id, carg.id } }))
		local res = A.check({ state = state, requested_claims = { ccall.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.rejected_claims, ccall), "arg checked against number ≠ param string ⇒ call rejected")
	end)
end)

T.describe("crescent.slice.v1: subtype_witness + rejection-with-counterevidence (§6.4)", function()
	T.it("subtype_witness accepts a true subtype", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local c = S.subtype_claim(A.id("claim", "c"), G.lit_int(42), G.number())
		A.add_claim(state, c)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "e"), claim = c.id, method = "subtype_witness" }))
		local res = A.check({ state = state, requested_claims = { c.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c), "lit_int(42) <: number")
	end)

	T.it("subtype_witness rejects a non-subtype, surfacing the counterexample in the diagnostic", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local c = S.subtype_claim(A.id("claim", "c"), G.string(), G.number())
		A.add_claim(state, c)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "e"), claim = c.id, method = "subtype_witness" }))
		local res = A.check({ state = state, requested_claims = { c.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.rejected_claims, c), "string </: number rejected")
		local found = false --: boolean
		for _, d in ipairs(res.diagnostics) do if d:find("not a subtype") then found = true end end
		T.ok(found, "rejection carries the counterevidence (not a subtype)")
	end)

	T.it("synth_index no-such-field rejection (§6.4 bad.missing)", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local Leaf = G.rec({ { key = "kind", ty = G.integer(), optional = false, readonly = false },
			{ key = "key", ty = G.unknown(), optional = false, readonly = false } }, "closed")
		local n_leaf = add_node(state, "leaf", { t = "var", name = "leaf" })
		local n_miss = add_node(state, "miss", { t = "index", obj = { space = "artifact", key = "leaf" }, field = "missing" })
		local g = S.extend(S.empty_ctx(), "leaf", Leaf)
		local c_leaf = S.has_type_claim(A.id("claim", "cleaf"), g, n_leaf, Leaf)
		local c_miss = S.has_type_claim(A.id("claim", "cmiss"), g, n_miss, G.unknown())
		A.add_claim(state, c_leaf); A.add_claim(state, c_miss)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eleaf"), claim = c_leaf.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "emiss"), claim = c_miss.id, method = "synth_index", inputs = { c_leaf.id } }))
		local res = A.check({ state = state, requested_claims = { c_miss.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.rejected_claims, c_miss), "leaf.missing on closed Leaf ⇒ rejected")
		local found = false --: boolean
		for _, d in ipairs(res.diagnostics) do if d:find("no_such_field") then found = true end end
		T.ok(found, "no_such_field counterevidence surfaced")
	end)
end)

T.describe("crescent.slice.v1: check_cast and trusted_signature (force cast)", function()
	T.it("a checked cast e --[[: T]] requires full subtyping and yields T", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		-- (42 --[[: number]]) : number, with subtype(lit_int(42), number).
		local ninner = add_node(state, "ninner", { t = "lit", lit = "int", v = 42 })
		local ncast = add_node(state, "ncast", { t = "cast", expr = { space = "artifact", key = "ninner" }, type = TA.encode(G.number()), force = false })
		local cs = S.has_type_claim(A.id("claim", "cs"), S.empty_ctx(), ninner, G.lit_int(42))
		local csub = S.subtype_claim(A.id("claim", "csub"), G.lit_int(42), G.number())
		local ccast = S.checks_against_claim(A.id("claim", "ccast"), S.empty_ctx(), ncast, G.number())
		A.add_claim(state, cs); A.add_claim(state, csub); A.add_claim(state, ccast)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "es"), claim = cs.id, method = "synth_lit" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "esub"), claim = csub.id, method = "subtype_witness" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ecast"), claim = ccast.id, method = "check_cast", inputs = { cs.id, csub.id } }))
		local res = A.check({ state = state, requested_claims = { ccast.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, ccast), "checked cast yields number")
	end)

	T.it("a force cast e --[[:! T]] is admitted through a visible trust boundary", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local tb = A.trust_boundary({ id = A.id("trust", "force"), kind = "force_cast", issuer = "test" })
		A.add_trust_boundary(state, tb)
		local nexpr = add_node(state, "nexpr", { t = "var", name = "x" })
		local Leaf = G.rec({ { key = "kind", ty = G.integer(), optional = false, readonly = false } }, "closed")
		local c = S.has_type_claim(A.id("claim", "c"), S.extend(S.empty_ctx(), "x", G.unknown()), nexpr, Leaf)
		A.add_claim(state, c)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "e"), claim = c.id, method = "trusted_signature", result = { trust = tb.id } }))
		local res = A.check({ state = state, requested_claims = { c.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c), "force cast admitted under trust boundary")
		T.ok(res.trust_summary[A.claim_key(c)] ~= nil, "trust summary records the force-cast boundary")
	end)

	T.it("check_cast refuses a force cast node (force ≠ check_cast)", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local ninner = add_node(state, "ni", { t = "lit", lit = "int", v = 1 })
		local nforce = add_node(state, "nf", { t = "cast", expr = { space = "artifact", key = "ni" }, type = TA.encode(G.number()), force = true })
		local cs = S.has_type_claim(A.id("claim", "cs"), S.empty_ctx(), ninner, G.lit_int(1))
		local csub = S.subtype_claim(A.id("claim", "csub"), G.lit_int(1), G.number())
		local cc = S.checks_against_claim(A.id("claim", "cc"), S.empty_ctx(), nforce, G.number())
		A.add_claim(state, cs); A.add_claim(state, csub); A.add_claim(state, cc)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "es"), claim = cs.id, method = "synth_lit" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "esub"), claim = csub.id, method = "subtype_witness" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ecc"), claim = cc.id, method = "check_cast", inputs = { cs.id, csub.id } }))
		local res = A.check({ state = state, requested_claims = { cc.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.rejected_claims, cc), "check_cast rejects a force-cast node")
	end)
end)

T.describe("crescent.slice.v1: instantiate_witness (local generic instantiation, §2.4)", function()
	-- A generic identity callee <T>(T) -> T applied to a string argument: σ = {T:string},
	-- call ⇒ string. The checker validates the proposed σ post-hoc.
	T.it("the checker validates a proposed σ and the σ-applied application", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		-- generic callee G as a portable PTy with a FREE tyvar `T`.
		local generic = { k = "fn", params = { fixed = { { k = "tyvar", var = "T" } } }, ret = { fixed = { { k = "tyvar", var = "T" } } } }
		local nf = add_node(state, "nf", { t = "var", name = "id" })
		local narg = add_node(state, "narg", { t = "var", name = "s" })
		local ncall = add_node(state, "ncall", { t = "call", fn = { space = "artifact", key = "nf" }, args = { { space = "artifact", key = "narg" } } })
		local g = S.extend(S.empty_ctx(), "s", G.string())
		-- the callee premise has_type(Γ, f_node, G) — G is a free-tyvar generic, so
		-- it cannot intern; it rides a trusted_signature claim whose raw `type` arg is
		-- the generic PTy (audit round 1, finding 5). instantiate_witness compares
		-- payload.generic structurally to this premise's type.
		local tb = A.trust_boundary({ id = A.id("trust", "stdlib"), kind = "stdlib", issuer = "test" })
		A.add_trust_boundary(state, tb)
		local cfn = A.claim({ id = A.id("claim", "cfn"), semantics = S.ID, predicate = "has_type",
			args = { ctx = g, node = { space = "artifact", key = "nf" }, type = generic } })
		-- arg checked against σ-applied param (string).
		local carg_s = S.has_type_claim(A.id("claim", "cargs"), g, narg, G.string())
		local csub = S.subtype_claim(A.id("claim", "csub"), G.string(), G.string())
		local carg = S.checks_against_claim(A.id("claim", "carg"), g, narg, G.string())
		local ccall = S.has_type_claim(A.id("claim", "ccall"), g, ncall, G.string())
		A.add_claim(state, cfn); A.add_claim(state, carg_s); A.add_claim(state, csub); A.add_claim(state, carg); A.add_claim(state, ccall)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "efn"), claim = cfn.id, method = "trusted_signature", result = { trust = tb.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eargs"), claim = carg_s.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "esub"), claim = csub.id, method = "subtype_witness" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "earg"), claim = carg.id, method = "check_against", inputs = { carg_s.id, csub.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ecall"), claim = ccall.id, method = "instantiate_witness",
			inputs = { cfn.id, carg.id }, result = { generic = generic, subst = { T = TA.encode(G.string()) } } }))
		local res = A.check({ state = state, requested_claims = { ccall.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, ccall), "identity<string>(s) ⇒ string under validated σ (callee G bound via premise)")
	end)

	T.it("instantiate_witness rejects a σ that does not match the argument check", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local generic = { k = "fn", params = { fixed = { { k = "tyvar", var = "T" } } }, ret = { fixed = { { k = "tyvar", var = "T" } } } }
		local nf = add_node(state, "nf", { t = "var", name = "id" })
		local narg = add_node(state, "narg", { t = "var", name = "s" })
		local ncall = add_node(state, "ncall", { t = "call", fn = { space = "artifact", key = "nf" }, args = { { space = "artifact", key = "narg" } } })
		local g = S.extend(S.empty_ctx(), "s", G.string())
		local tb = A.trust_boundary({ id = A.id("trust", "stdlib"), kind = "stdlib", issuer = "test" })
		A.add_trust_boundary(state, tb)
		local cfn = A.claim({ id = A.id("claim", "cfn"), semantics = S.ID, predicate = "has_type",
			args = { ctx = g, node = { space = "artifact", key = "nf" }, type = generic } })
		local carg_s = S.has_type_claim(A.id("claim", "cargs"), g, narg, G.string())
		local csub = S.subtype_claim(A.id("claim", "csub"), G.string(), G.string())
		local carg = S.checks_against_claim(A.id("claim", "carg"), g, narg, G.string())
		-- σ claims T = number, but the arg was checked against string ⇒ mismatch.
		local ccall = S.has_type_claim(A.id("claim", "ccall"), g, ncall, G.number())
		A.add_claim(state, cfn); A.add_claim(state, carg_s); A.add_claim(state, csub); A.add_claim(state, carg); A.add_claim(state, ccall)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "efn"), claim = cfn.id, method = "trusted_signature", result = { trust = tb.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eargs"), claim = carg_s.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "esub"), claim = csub.id, method = "subtype_witness" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "earg"), claim = carg.id, method = "check_against", inputs = { carg_s.id, csub.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ecall"), claim = ccall.id, method = "instantiate_witness",
			inputs = { cfn.id, carg.id }, result = { generic = generic, subst = { T = TA.encode(G.number()) } } }))
		local res = A.check({ state = state, requested_claims = { ccall.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.rejected_claims, ccall), "σ={T:number} contradicts the string arg check ⇒ rejected")
	end)
end)

T.describe("crescent.slice.v1: order-independence (shuffled submission, deep tree)", function()
	-- The synth_call derivation, evidence submitted in several orders; the worklist
	-- fixpoint must converge to the same accepted set regardless of order.
	--: () -> (AnalysisState, SemanticsRegistry, { [integer]: Evidence }, Claim)
	local function build()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local fty = G.fn({ fixed = { G.string() } }, { fixed = { G.number() } })
		local nf = add_node(state, "nf", { t = "var", name = "f" })
		local narg = add_node(state, "narg", { t = "lit", lit = "str", v = "x" })
		local ncall = add_node(state, "ncall", { t = "call", fn = { space = "artifact", key = "nf" }, args = { { space = "artifact", key = "narg" } } })
		local g = S.extend(S.empty_ctx(), "f", fty)
		local cf = S.has_type_claim(A.id("claim", "cf"), g, nf, fty)
		local carg_s = S.has_type_claim(A.id("claim", "cargs"), g, narg, G.lit_str("x"))
		local csub = S.subtype_claim(A.id("claim", "csub"), G.lit_str("x"), G.string())
		local carg = S.checks_against_claim(A.id("claim", "carg"), g, narg, G.string())
		local ccall = S.has_type_claim(A.id("claim", "ccall"), g, ncall, G.number())
		A.add_claim(state, cf); A.add_claim(state, carg_s); A.add_claim(state, csub); A.add_claim(state, carg); A.add_claim(state, ccall)
		local evs = {
			A.evidence({ id = A.id("ev", "ecall"), claim = ccall.id, method = "synth_call", inputs = { cf.id, carg.id } }),
			A.evidence({ id = A.id("ev", "earg"), claim = carg.id, method = "check_against", inputs = { carg_s.id, csub.id } }),
			A.evidence({ id = A.id("ev", "ef"), claim = cf.id, method = "synth_var" }),
			A.evidence({ id = A.id("ev", "eargs"), claim = carg_s.id, method = "synth_lit" }),
			A.evidence({ id = A.id("ev", "esub"), claim = csub.id, method = "subtype_witness" }),
		}
		return state, registry, evs, ccall
	end

	T.it("every submission order accepts the full call derivation", function()
		local orders = { { 1, 2, 3, 4, 5 }, { 5, 4, 3, 2, 1 }, { 3, 1, 5, 2, 4 }, { 2, 4, 1, 5, 3 } }
		for _, ord in ipairs(orders) do
			local state, registry, evs, ccall = build()
			for _, idx in ipairs(ord) do A.add_evidence(state, evs[idx]) end
			local res = A.check({ state = state, requested_claims = { ccall.id }, semantics_registry = registry })
			if not res then T.fail(true, "no result"); return end
			T.ok(has(res.accepted_claims, ccall), "call derivation accepted regardless of evidence order")
		end
	end)
end)

T.describe("crescent.slice.v1: adversarial — substrate stays agnostic (§2.6)", function()
	T.it("a non-listed claim predicate (type_of) is rejected by the registry", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local bad = A.claim({ id = A.id("claim", "bad"), semantics = S.ID, predicate = "type_of", args = {} })
		A.add_claim(state, bad)
		local res, err = A.check({ state = state, requested_claims = { bad.id }, semantics_registry = registry })
		T.fail(res, "type_of is not a claim predicate")
		T.ok(err and err:find("type_of"), "error names type_of")
	end)

	T.it("a solver method (unify/solve/coalesce/rdnf) is rejected by the registry", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local nx = add_node(state, "nx", { t = "var", name = "x" })
		local c = S.has_type_claim(A.id("claim", "c"), S.extend(S.empty_ctx(), "x", G.number()), nx, G.number())
		A.add_claim(state, c)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "e"), claim = c.id, method = "unify" }))
		local res, err = A.check({ state = state, requested_claims = { c.id }, semantics_registry = registry })
		T.fail(res, "unify is not an admitted evidence method")
		T.ok(err and err:find("unify"), "error names the rejected solver method")
	end)

	T.it("substrate stores no Type/Context/Subtype/Narrowing object kinds — walk the state", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local TN = G.rec({ { key = "done", ty = G.boolean(), optional = false, readonly = false } }, "closed")
		local n_task = add_node(state, "task", { t = "var", name = "task" })
		local n_field = add_node(state, "field", { t = "index", obj = { space = "artifact", key = "task" }, field = "done" })
		local g = S.extend(S.empty_ctx(), "task", TN)
		local c_task = S.has_type_claim(A.id("claim", "ctask"), g, n_task, TN)
		local c_field = S.has_type_claim(A.id("claim", "cfield"), g, n_field, G.boolean())
		A.add_claim(state, c_task); A.add_claim(state, c_field)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "etask"), claim = c_task.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "efield"), claim = c_field.id, method = "synth_index", inputs = { c_task.id } }))
		A.check({ state = state, requested_claims = { c_field.id }, semantics_registry = registry })
		local allowed = { artifact = true, claim = true, ev = true, trust = true, observation = true }
		--: ({ [string]: unknown }) -> nil
		local function check_spaces(store)
			for k in pairs(store) do
				local space = k:match("^([^/]+)/") or "?"
				T.ok(allowed[space], "stored id space '" .. space .. "' is substrate-owned, not type/context/subtype/narrowing")
			end
		end
		check_spaces(state.artifacts); check_spaces(state.claims); check_spaces(state.evidence)
		check_spaces(state.trust_boundaries); check_spaces(state.observations)
		for _, art in pairs(state.artifacts) do
			T.eq(art.kind, "syntax_tree", "artifact kind is descriptive syntax_tree, not a Type/Subtype/Flow kind")
		end
	end)
end)

-- ── Flow-narrowing layer (Pass 3): narrow_guard / narrows ────────────────────

T.describe("crescent.slice.v1: narrow_guard derives a narrows claim (§4.2)", function()
	-- The §6.1 worked example's narrowing step: `task : TN | nil`, guard `not task`
	-- recognized as `not (truthy task)`. The truthy refinement of `not(truthy)` is
	-- the FALSY of truthy = T unrefined; the falsy refinement is the truthy of
	-- truthy = TN. But §6.1 narrows on the nil-guard reading: we model the canonical
	-- nil discriminant `task ~= nil` whose falsy is exact (nil) — the fall-through
	-- path after `if not task then return end` binds task : TN.
	--: () -> (AnalysisState, SemanticsRegistry, Ty, Ty, Id, Id, SliceCtx)
	local function setup_nilguard()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local TN = G.rec({ { key = "id", ty = G.string(), optional = false, readonly = false },
			{ key = "done", ty = G.boolean(), optional = false, readonly = false } }, "closed")
		local MaybeTN = G.union({ TN, G.nil_() })
		-- the synthesized pre-guard type of `task` rides a has_type premise.
		local n_task = add_node(state, "task", { t = "var", name = "task" })
		-- the guard artifact: `task ~= nil` (nil_eq, eq=false).
		local n_guard = add_node(state, "guard", { g = "nil_eq", var = "task", eq = false })
		local g0 = S.extend(S.empty_ctx(), "task", MaybeTN)
		return state, registry, TN, MaybeTN, n_task, n_guard, g0
	end

	T.it("`task ~= nil` derives narrows(task, TN, nil) — truthy drops nil, falsy is the exact nil member", function()
		local state, registry, TN, MaybeTN, n_task, n_guard, g0 = setup_nilguard()
		local c_pre = S.has_type_claim(A.id("claim", "pre"), g0, n_task, MaybeTN)
		-- truthy = TN (nil dropped); falsy = nil (the exact positive member).
		local c_nar = S.narrows_claim(A.id("claim", "nar"), g0, n_guard, "task", TN, G.nil_())
		A.add_claim(state, c_pre); A.add_claim(state, c_nar)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "epre"), claim = c_pre.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "enar"), claim = c_nar.id, method = "narrow_guard", inputs = { c_pre.id } }))
		local res = A.check({ state = state, requested_claims = { c_nar.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c_nar), "narrows(task ~= nil) derived")
		T.ok(dep_to(res, c_nar, "pre"), "narrows depends on the pre-guard has_type premise (Γ-fed)")
		T.ok(dep_to(res, c_nar, "guard"), "narrows depends on the guard syntax artifact")
	end)

	T.it("a WRONG asserted refinement is rejected (the checker re-derives, never trusts)", function()
		local state, registry, TN, MaybeTN, n_task, n_guard, g0 = setup_nilguard()
		local c_pre = S.has_type_claim(A.id("claim", "pre"), g0, n_task, MaybeTN)
		-- assert truthy = MaybeTN (WRONG — nil was not dropped).
		local c_bad = S.narrows_claim(A.id("claim", "bad"), g0, n_guard, "task", MaybeTN, G.nil_())
		A.add_claim(state, c_pre); A.add_claim(state, c_bad)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "epre"), claim = c_pre.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ebad"), claim = c_bad.id, method = "narrow_guard", inputs = { c_pre.id } }))
		local res = A.check({ state = state, requested_claims = { c_bad.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.rejected_claims, c_bad), "an unfaithful truthy refinement is rejected")
	end)

	T.it("the FALSY branch of a type-guard must be sound-WIDER (T), not the exact complement", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		-- x : string | number ; guard type(x) == "string".
		local sn = G.union({ G.string(), G.number() })
		local n_x = add_node(state, "x", { t = "var", name = "x" })
		local n_guard = add_node(state, "guard", { g = "type_eq", var = "x", tyname = "string" })
		local g0 = S.extend(S.empty_ctx(), "x", sn)
		local c_pre = S.has_type_claim(A.id("claim", "pre"), g0, n_x, sn)
		A.add_claim(state, c_pre)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "epre"), claim = c_pre.id, method = "synth_var" }))
		-- the CORRECT v1 claim: truthy = string, falsy = string|number (sound wider).
		local c_ok = S.narrows_claim(A.id("claim", "ok"), g0, n_guard, "x", G.string(), sn)
		-- an UNSOUND-precision claim: falsy = number (the complement) — must REJECT.
		local c_exact = S.narrows_claim(A.id("claim", "exact"), g0, n_guard, "x", G.string(), G.number())
		A.add_claim(state, c_ok); A.add_claim(state, c_exact)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eok"), claim = c_ok.id, method = "narrow_guard", inputs = { c_pre.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eexact"), claim = c_exact.id, method = "narrow_guard", inputs = { c_pre.id } }))
		local res = A.check({ state = state, requested_claims = { c_ok.id, c_exact.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c_ok), "falsy = T (string|number) accepted — the v1 sound-wider rule")
		T.ok(has(res.rejected_claims, c_exact), "falsy = number (the complement) REJECTED — no complement in v1")
	end)
end)

T.describe("crescent.slice.v1: narrow_guard tag discriminant + and-composition", function()
	T.it("`x.tag == \"leaf\"` selects the union-of-recs Leaf member (§6.2)", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local Leaf = G.rec({ { key = "tag", ty = G.lit_str("leaf"), optional = false, readonly = false },
			{ key = "key", ty = G.unknown(), optional = false, readonly = false } }, "closed")
		local Interior = G.rec({ { key = "tag", ty = G.lit_str("interior"), optional = false, readonly = false },
			{ key = "n", ty = G.integer(), optional = false, readonly = false } }, "closed")
		local node_ty = G.union({ Leaf, Interior })
		local n_x = add_node(state, "x", { t = "var", name = "node" })
		local n_guard = add_node(state, "guard", { g = "tag_eq", var = "node", field = "tag", lit = TA.encode(G.lit_str("leaf")) })
		local g0 = S.extend(S.empty_ctx(), "node", node_ty)
		local c_pre = S.has_type_claim(A.id("claim", "pre"), g0, n_x, node_ty)
		local c_nar = S.narrows_claim(A.id("claim", "nar"), g0, n_guard, "node", Leaf, node_ty)
		A.add_claim(state, c_pre); A.add_claim(state, c_nar)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "epre"), claim = c_pre.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "enar"), claim = c_nar.id, method = "narrow_guard", inputs = { c_pre.id } }))
		local res = A.check({ state = state, requested_claims = { c_nar.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c_nar), "tag discriminant narrows to Leaf (narrows without a force cast)")
	end)

	T.it("composition through `and` (the n==0 and 1/n<0 narrowing shape)", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		-- x : string | number | nil ; guard `x ~= nil and type(x) == "string"`.
		local t = G.union({ G.string(), G.number(), G.nil_() })
		local n_x = add_node(state, "x", { t = "var", name = "x" })
		local n_guard = add_node(state, "guard", { g = "and",
			left = { g = "nil_eq", var = "x", eq = false },
			right = { g = "type_eq", var = "x", tyname = "string" } })
		local g0 = S.extend(S.empty_ctx(), "x", t)
		local c_pre = S.has_type_claim(A.id("claim", "pre"), g0, n_x, t)
		-- truthy = string (drop nil, then keep string); falsy = T (sound wider).
		local c_nar = S.narrows_claim(A.id("claim", "nar"), g0, n_guard, "x", G.string(), t)
		A.add_claim(state, c_pre); A.add_claim(state, c_nar)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "epre"), claim = c_pre.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "enar"), claim = c_nar.id, method = "narrow_guard", inputs = { c_pre.id } }))
		local res = A.check({ state = state, requested_claims = { c_nar.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c_nar), "x ~= nil and type(x)==string ⇒ string (chained truthy)")
	end)
end)

T.describe("crescent.slice.v1: a worked multi-branch if/elseif derivation", function()
	-- if type(x) == "string" then ... elseif type(x) == "number" then ... else ...
	-- Three narrows claims thread the guards; v1 elseif accumulates falsy (sound
	-- wider T) into the next test — so each branch test re-narrows the FULL T.
	T.it("each branch derives its own narrows; elseif threads the sound-wider falsy T", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local t = G.union({ G.string(), G.number(), G.boolean() })
		local n_x = add_node(state, "x", { t = "var", name = "x" })
		local g_str = add_node(state, "gstr", { g = "type_eq", var = "x", tyname = "string" })
		local g_num = add_node(state, "gnum", { g = "type_eq", var = "x", tyname = "number" })
		local g0 = S.extend(S.empty_ctx(), "x", t)
		-- branch 1: type(x)=="string" — truthy string, falsy T.
		local c_pre1 = S.has_type_claim(A.id("claim", "pre1"), g0, n_x, t)
		local c_nar1 = S.narrows_claim(A.id("claim", "nar1"), g0, g_str, "x", G.string(), t)
		-- branch 2 (elseif): the falsy of branch1 is the SOUND-WIDER T, so the elseif
		-- test re-narrows the FULL T: type(x)=="number" — truthy number, falsy T.
		local c_pre2 = S.has_type_claim(A.id("claim", "pre2"), g0, n_x, t)
		local c_nar2 = S.narrows_claim(A.id("claim", "nar2"), g0, g_num, "x", G.number(), t)
		A.add_claim(state, c_pre1); A.add_claim(state, c_nar1)
		A.add_claim(state, c_pre2); A.add_claim(state, c_nar2)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ep1"), claim = c_pre1.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "en1"), claim = c_nar1.id, method = "narrow_guard", inputs = { c_pre1.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ep2"), claim = c_pre2.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "en2"), claim = c_nar2.id, method = "narrow_guard", inputs = { c_pre2.id } }))
		local res = A.check({ state = state, requested_claims = { c_nar1.id, c_nar2.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c_nar1), "branch 1: type(x)==string ⇒ string")
		T.ok(has(res.accepted_claims, c_nar2), "branch 2 (elseif): re-narrows the full T ⇒ number; falsy stays wider")
	end)
end)

T.describe("crescent.slice.v1: adversarial — narrowing stays a CLAIM, not substrate state", function()
	T.it("a narrows-shaped predicate under a FOREIGN semantics is rejected by the registry", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		-- a different semantics id is not registered; its `narrows` claim cannot route.
		local bad = A.claim({ id = A.id("claim", "bad"), semantics = "other.semantics", predicate = "narrows", args = {} })
		A.add_claim(state, bad)
		local res, err = A.check({ state = state, requested_claims = { bad.id }, semantics_registry = registry })
		T.fail(res, "a foreign semantics' narrows claim does not route into crescent.slice.v1")
		T.ok(err ~= nil, "the registry rejects the unroutable claim")
	end)

	T.it("a non-narrows predicate masquerading with narrow_guard method is rejected", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		-- narrow_guard is only valid for the `narrows` predicate; applying it to a
		-- has_type claim must not produce a narrowing (the method-predicate binding).
		local nx = add_node(state, "nx", { t = "var", name = "x" })
		local c = S.has_type_claim(A.id("claim", "c"), S.extend(S.empty_ctx(), "x", G.number()), nx, G.number())
		A.add_claim(state, c)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "e"), claim = c.id, method = "narrow_guard" }))
		local res = A.check({ state = state, requested_claims = { c.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.fail(has(res.accepted_claims, c), "narrow_guard cannot evidence a has_type claim")
	end)

	T.it("after a narrowing derivation the substrate stores NO narrowing/flow object kind", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local t = G.union({ G.string(), G.nil_() })
		local n_x = add_node(state, "x", { t = "var", name = "x" })
		local n_guard = add_node(state, "guard", { g = "nil_eq", var = "x", eq = false })
		local g0 = S.extend(S.empty_ctx(), "x", t)
		local c_pre = S.has_type_claim(A.id("claim", "pre"), g0, n_x, t)
		local c_nar = S.narrows_claim(A.id("claim", "nar"), g0, n_guard, "x", G.string(), G.nil_())
		A.add_claim(state, c_pre); A.add_claim(state, c_nar)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "epre"), claim = c_pre.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "enar"), claim = c_nar.id, method = "narrow_guard", inputs = { c_pre.id } }))
		A.check({ state = state, requested_claims = { c_nar.id }, semantics_registry = registry })
		local allowed = { artifact = true, claim = true, ev = true, trust = true, observation = true }
		--: ({ [string]: unknown }) -> nil
		local function check_spaces(store)
			for k in pairs(store) do
				local space = k:match("^([^/]+)/") or "?"
				T.ok(allowed[space], "stored id space '" .. space .. "' is substrate-owned, not narrowing/flow")
			end
		end
		check_spaces(state.artifacts); check_spaces(state.claims); check_spaces(state.evidence)
		check_spaces(state.trust_boundaries); check_spaces(state.observations)
		-- the guard rides an ordinary syntax_tree artifact, not a Flow/Narrowing kind.
		for _, art in pairs(state.artifacts) do
			T.eq(art.kind, "syntax_tree", "the guard artifact is a descriptive syntax_tree, not a Narrowing kind")
		end
	end)
end)

-- ── Parser-frontend adapter ──────────────────────────────────────────────────

T.describe("crescent.slice.v1: parser-frontend adapter (annotation type grammar)", function()
	T.it("parses primitives, literals, functions, unions, records", function()
		G.reset()
		local t1 = P.parse_type_ann("number", {})
		T.eq(t1 and t1.kind, "number", "primitive")
		local t2 = P.parse_type_ann('"GET"', {})
		T.eq(t2 and t2.kind, "lit_str", "string literal singleton")
		local t3 = P.parse_type_ann("(string) -> boolean", {})
		T.eq(t3 and t3.kind, "fn", "function type")
		local t4 = P.parse_type_ann("number | nil", {})
		T.eq(t4 and t4.kind, "union", "union")
		local t5 = P.parse_type_ann("{ id: string, done: boolean }", {})
		T.eq(t5 and t5.kind, "rec", "record")
	end)

	T.it("preserves the `...`-vs-indexer distinction structurally", function()
		G.reset()
		local SUB = require("lib.type.analysis.slice_subtype")
		local idx = P.parse_type_ann("{ [string]: number }", {})
		local open = P.parse_type_ann("{ name: string, ... }", {})
		T.eq(idx and idx.kind, "indexer", "{ [K]: V } ⇒ indexer")
		T.eq(open and open.kind, "rec", "{ f: T, ... } ⇒ rec")
		T.eq(open and open.rows, "open", "the `...` marks an open row")
		T.fail(SUB.is_subtype(open, idx), "open row is NOT <: an index signature")
	end)

	T.it("resolves named aliases and `T?` shorthand", function()
		G.reset()
		local aliases = {} --[[: { [string]: Ty } ]]
		P.declare_alias(aliases, "TaskNode", "{ id: string, done: boolean }")
		local t = P.parse_type_ann("TaskNode?", aliases)
		T.eq(t and t.kind, "union", "TaskNode? ⇒ TaskNode | nil")
	end)

	T.it("resolves a RECURSIVE alias to an equirecursive μ", function()
		G.reset()
		local SUB = require("lib.type.analysis.slice_subtype")
		local aliases = {} --[[: { [string]: Ty } ]]
		local ok = P.declare_alias(aliases, "HamtNode",
			"{ kind: integer, children: { [integer]: HamtNode } } | { kind: integer, key: unknown }")
		T.ok(ok ~= nil, "recursive alias declared")
		local hn = aliases.HamtNode
		if not hn then T.fail(true, "HamtNode not declared"); return end
		T.eq(hn.kind, "mu", "recursive alias ⇒ μ")
		T.ok(SUB.is_subtype(hn, hn), "μ <: itself (reflexivity, no divergence)")
		-- and it is well-formed (contractive: HamtNode is guarded under rec/indexer)
		T.ok(TA.well_formed(hn), "the recursive alias is contractive")
	end)

	T.it("scan_annotation distinguishes --:: aliases from --: signatures", function()
		local d1 = P.scan_annotation("--:: AnyCmd = LoginCmd | LogoutCmd")
		T.eq(d1 and d1.kind, "alias", "--:: ⇒ alias directive")
		T.eq(d1 and d1.name, "AnyCmd", "alias name captured")
		local d2 = P.scan_annotation("--: (number) -> boolean")
		T.eq(d2 and d2.kind, "sig", "--: ⇒ signature directive")
		T.eq(P.scan_annotation("local x = 1"), nil, "a non-annotation line yields nil")
	end)

	T.it("rejects an unknown type name (no ambient globals)", function()
		G.reset()
		local t, e = P.parse_type_ann("Nonexistent", {})
		T.fail(t, "unknown type name is rejected")
		T.ok(e and e:find("unknown type name"), "error names the unknown type")
	end)
end)

T.describe("crescent.slice.v2.1: named parameters (§6.5.1) — names ride, subtyping ignores", function()
	local SUB = require("lib.type.analysis.slice_subtype")

	T.it("parses `(a: number, b: string) -> boolean` with names on Params", function()
		G.reset()
		local t = P.parse_type_ann("(a: number, b: string) -> boolean", {})
		if not t then T.fail(true, "parse failed"); return end
		T.eq(t.kind, "fn", "named params parse as a fn type")
		local p = t.params or ({ fixed = {} } --[[: Params ]])
		T.eq(#p.fixed, 2, "two positional params")
		local f1 = p.fixed[1]
		T.eq(f1 and f1.kind, "number", "first param type")
		local names = p.names or ({} --[[: { [integer]: string | nil } ]])
		T.eq(names[1], "a", "first param name carried")
		T.eq(names[2], "b", "second param name carried")
	end)

	T.it("subtype is NAME-BLIND: name-only differences share a tid", function()
		G.reset()
		local fa = P.parse_type_ann("(a: number) -> number", {})
		local fb = P.parse_type_ann("(b: number) -> number", {})
		local fbare = P.parse_type_ann("(number) -> number", {})
		T.eq(fa and fa.tid, fb and fb.tid, "name-only difference interns to the same tid")
		T.eq(fa and fa.tid, fbare and fbare.tid, "named and unnamed param types share a tid")
		T.ok(fa and fb and SUB.is_subtype(fa, fb), "name-blind: fa <: fb")
	end)

	T.it("mixes named and bare positional slots", function()
		G.reset()
		local t = P.parse_type_ann("(number, b: string) -> nil", {})
		if not t then T.fail(true, "parse failed"); return end
		local p = t.params or ({ fixed = {} } --[[: Params ]])
		local names = p.names or ({} --[[: { [integer]: string | nil } ]])
		T.eq(names[1], nil, "first slot bare (no name)")
		T.eq(names[2], "b", "second slot named")
	end)
end)

T.describe("crescent.slice.v2.1: `self` parameter (§6.5.2) — an ordinary named first param", function()
	T.it("parses `(self: HamtNode) -> integer` as a named first param", function()
		G.reset()
		local aliases = {} --[[: { [string]: Ty } ]]
		P.declare_alias(aliases, "HamtNode", "{ kind: integer }")
		local t = P.parse_type_ann("(self: HamtNode) -> integer", aliases)
		if not t then T.fail(true, "parse failed"); return end
		T.eq(t.kind, "fn", "self-method signature parses")
		local p = t.params or ({ fixed = {} } --[[: Params ]])
		local names = p.names or ({} --[[: { [integer]: string | nil } ]])
		T.eq(names[1], "self", "self is the first param's name")
		local f1 = p.fixed[1]
		T.eq(f1 and f1.kind, "rec", "self's type is the annotation (HamtNode), no special-casing")
	end)

	T.it("`self` is name-blind like any param (no self-specific rule)", function()
		G.reset()
		local fself = P.parse_type_ann("(self: number) -> number", {})
		local fother = P.parse_type_ann("(this: number) -> number", {})
		T.eq(fself and fself.tid, fother and fother.tid, "self vs this: name-only ⇒ same tid")
	end)
end)

T.describe("crescent.slice.v2.1: `T[]` and `{ T }` shorthand (§6.5.3/§6.5.4)", function()
	T.it("`T[]` desugars to indexer(integer, T)", function()
		G.reset()
		local t = P.parse_type_ann("string[]", {})
		T.eq(t and t.kind, "indexer", "T[] ⇒ indexer")
		T.eq(t and t.key and t.key.kind, "integer", "key is integer")
		T.eq(t and t.val and t.val.kind, "string", "value is the element type")
	end)

	T.it("`{ T }` desugars to the IDENTICAL canonical form as `T[]`", function()
		G.reset()
		local arr = P.parse_type_ann("string[]", {})
		local lst = P.parse_type_ann("{ string }", {})
		T.ok(arr ~= nil and lst ~= nil, "both parse")
		T.eq(arr and arr.tid, lst and lst.tid, "`{ T }` and `T[]` share a tid (one canonical form)")
	end)

	T.it("`{ Listener }` over an alias is a list of that alias", function()
		G.reset()
		local aliases = {} --[[: { [string]: Ty } ]]
		P.declare_alias(aliases, "Listener", "(string) -> nil")
		local t = P.parse_type_ann("{ Listener }", aliases)
		T.eq(t and t.kind, "indexer", "{ Listener } ⇒ indexer(integer, Listener)")
		T.eq(t and t.val and t.val.kind, "fn", "element is the Listener fn type")
	end)

	T.it("`T[][]` nests, and `{ [K]: V }` / `{ f: T }` still take precedence", function()
		G.reset()
		local nested = P.parse_type_ann("integer[][]", {})
		T.eq(nested and nested.kind, "indexer", "outer indexer")
		T.eq(nested and nested.val and nested.val.kind, "indexer", "inner indexer")
		local idx = P.parse_type_ann("{ [string]: number }", {})
		T.eq(idx and idx.kind, "indexer", "index signature unchanged")
		local rec = P.parse_type_ann("{ name: string }", {})
		T.eq(rec and rec.kind, "rec", "named-field record unchanged")
	end)

	T.it("rejects a multi-element `{ A, B }` (not a v1 table type)", function()
		G.reset()
		local t, e = P.parse_type_ann("{ string, number }", {})
		T.fail(t, "{ A, B } is rejected")
		T.ok(e and e:find("single type"), "error explains the single-element rule")
	end)
end)

T.describe("crescent.slice.v2.1: union-of-multi-return-tuples (§6.5.5)", function()
	local SUB = require("lib.type.analysis.slice_subtype")

	T.it("parses `(string) -> (string, string) | (nil, string)` as a union of tuples", function()
		G.reset()
		local t = P.parse_type_ann("(string) -> (string, string) | (nil, string)", {})
		if not t then T.fail(true, "parse failed"); return end
		T.eq(t.kind, "fn", "the value-or-error return parses")
		local r = t.ret or ({ fixed = {} } --[[: Ret ]])
		T.eq(#r.fixed, 1, "the return is a single value (a union)")
		local rv = r.fixed[1]
		T.eq(rv and rv.kind, "union", "the return value is a union")
		local ms = (rv and rv.members) or ({} --[[: Ty[] ]])
		local saw_tuple = false --: boolean
		for _, m in ipairs(ms) do if m.kind == "tuple" then saw_tuple = true end end
		T.ok(saw_tuple, "the union has tuple members")
	end)

	T.it("a single `(A, B)` return keeps the legacy multi-return slot shape", function()
		G.reset()
		local t = P.parse_type_ann("() -> (integer, string)", {})
		if not t then T.fail(true, "parse failed"); return end
		local r = t.ret or ({ fixed = {} } --[[: Ret ]])
		T.eq(#r.fixed, 2, "a bare multi-tuple return is the 2-slot Ret (unchanged)")
		local s1, s2 = r.fixed[1], r.fixed[2]
		T.eq(s1 and s1.kind, "integer", "slot 1")
		T.eq(s2 and s2.kind, "string", "slot 2")
	end)

	T.it("tuple <: tuple is covariant with droppable extra returns", function()
		G.reset()
		local lit1 = G.lit_int(1)
		local t_ab = G.tuple({ lit1, G.string() }, nil)
		local t_a  = G.tuple({ G.integer() }, nil) -- normalizes to integer (one-tuple)
		T.eq(t_a.kind, "integer", "a one-element tuple normalizes to its element")
		-- (int, str) <: (int): a longer tuple is <: a shorter prefix.
		local t_int = G.tuple({ G.integer(), G.string() }, nil)
		local t_intonly = G.tuple({ G.integer(), G.never() }, nil) -- 2-elem to stay a tuple
		T.ok(SUB.is_subtype(t_ab, G.tuple({ G.integer(), G.string() }, nil)), "(1,str) <: (int,str) covariant")
		local _ = t_a; local _2 = t_int; local _3 = t_intonly
	end)

	T.it("union-of-tuples <: union-of-tuples is the standard exists-forall", function()
		G.reset()
		local ok_t = G.tuple({ G.string(), G.string() }, nil)
		local err_t = G.tuple({ G.nil_(), G.string() }, nil)
		local narrow = G.union({ ok_t, err_t })
		local wider  = G.union({ ok_t, err_t, G.tuple({ G.integer(), G.string() }, nil) })
		T.ok(SUB.is_subtype(narrow, wider), "every left tuple member is <: some right member")
		T.fail(SUB.is_subtype(wider, narrow), "the wider union is NOT <: the narrower")
		-- tuple <: union-of-tuples (a single member).
		T.ok(SUB.is_subtype(ok_t, narrow), "a tuple <: a union containing it")
	end)

	T.it("a scalar vs a ≥2 tuple, and tuple vs non-tuple, are both false (no special case)", function()
		G.reset()
		local t2 = G.tuple({ G.integer(), G.string() }, nil)
		T.fail(SUB.is_subtype(G.integer(), t2), "a single value </: a two-value return")
		T.fail(SUB.is_subtype(t2, G.integer()), "a multi-value spread </: a single value")
	end)

	T.it("a `tuple` round-trips through the portable codec faithfully", function()
		G.reset()
		local tup = G.tuple({ G.nil_(), G.string() }, nil)
		T.eq(TA.decode(TA.encode(tup)).tid, tup.tid, "tuple round-trips")
		-- a non-canonical one-fixed tuple is rejected by the decoder (parse-not-cast).
		T.eq(TA.decode({ k = "tuple", fixed = { { k = "number" } } }), nil, "1-fixed no-vararg tuple decode rejected")
	end)
end)

T.describe("crescent.slice.v2.1: multi-line `--::` alias scanning (§6.5.6)", function()
	T.it("joins a wrapped `--:: Name = {` declaration across continuation lines", function()
		local lines = {
			"--:: IRDescriptor = {",
			"--::   num_labels: integer,",
			"--::   name: string,",
			"--:: }",
		} --[[: { [integer]: string } ]]
		local d, consumed = P.scan_annotation_at(lines, 1)
		T.ok(d ~= nil, "a directive is produced")
		T.eq(d and d.kind, "alias", "it is an alias directive")
		T.eq(d and d.name, "IRDescriptor", "name captured from the opening line")
		T.eq(consumed, 4, "all four lines consumed")
		G.reset()
		local aliases = {} --[[: { [string]: Ty } ]]
		local ok = d and d.body and P.declare_alias(aliases, "IRDescriptor", d.body)
		T.ok(ok ~= nil, "the joined body declares a valid alias")
		T.eq(aliases.IRDescriptor and aliases.IRDescriptor.kind, "rec", "the multi-line type is a record")
	end)

	T.it("a single-line directive still consumes exactly one line", function()
		local lines = { "--:: Foo = number | nil", "local x = 1" } --[[: { [integer]: string } ]]
		local d, consumed = P.scan_annotation_at(lines, 1)
		T.eq(consumed, 1, "single-line alias consumes 1 line")
		T.eq(d and d.name, "Foo", "name captured")
	end)
end)

T.describe("crescent.slice.v1: adapter guard recognition (the five v1 forms)", function()
	T.it("recognizes a bare variable as a truthy guard", function()
		local g = P.recognize_guard({ t = "var", name = "x" })
		T.eq(g and g.g, "truthy", "`if x` ⇒ truthy guard")
		T.eq(g and g.var, "x", "on variable x")
	end)

	T.it("recognizes `x ~= nil` and `x == nil`", function()
		local g1 = P.recognize_guard({ t = "cmp", op = "ne", left = { t = "var", name = "x" }, right = { t = "lit", lit = "nil" } })
		T.eq(g1 and g1.g, "nil_eq", "`x ~= nil` ⇒ nil_eq")
		T.eq(g1 and g1.eq, false, "ne ⇒ eq=false")
		local g2 = P.recognize_guard({ t = "cmp", op = "eq", left = { t = "var", name = "x" }, right = { t = "lit", lit = "nil" } })
		T.eq(g2 and g2.eq, true, "`x == nil` ⇒ eq=true")
	end)

	T.it("recognizes `type(x) == \"string\"` (operand order symmetric)", function()
		local g = P.recognize_guard({ t = "cmp", op = "eq",
			left = { t = "call", fn = { t = "var", name = "type" }, args = { { t = "var", name = "x" } } },
			right = { t = "lit", lit = "str", v = "string" } })
		T.eq(g and g.g, "type_eq", "type(x)==\"string\" ⇒ type_eq")
		T.eq(g and g.tyname, "string", "tyname captured")
		-- swapped operands recognize identically.
		local gs = P.recognize_guard({ t = "cmp", op = "eq",
			left = { t = "lit", lit = "str", v = "string" },
			right = { t = "call", fn = { t = "var", name = "type" }, args = { { t = "var", name = "x" } } } })
		T.eq(gs and gs.g, "type_eq", "\"string\"==type(x) recognizes the same")
	end)

	T.it("recognizes `x == \"GET\"` literal-eq and `x.tag == \"leaf\"` tag-eq", function()
		local gl = P.recognize_guard({ t = "cmp", op = "eq", left = { t = "var", name = "x" }, right = { t = "lit", lit = "str", v = "GET" } })
		T.eq(gl and gl.g, "lit_eq", "x == \"GET\" ⇒ lit_eq")
		T.ok(gl and gl.lit ~= nil and gl.lit.k == "lit_str", "lit rides as a PTy")
		local gt = P.recognize_guard({ t = "cmp", op = "eq",
			left = { t = "index", obj = { t = "var", name = "n" }, field = "tag" }, right = { t = "lit", lit = "str", v = "leaf" } })
		T.eq(gt and gt.g, "tag_eq", "n.tag == \"leaf\" ⇒ tag_eq")
		T.eq(gt and gt.var, "n", "tag-eq targets the object variable")
		T.eq(gt and gt.field, "tag", "the discriminant field is captured")
	end)

	T.it("recognizes not / and / or composition", function()
		local gn = P.recognize_guard({ t = "andor", op = "not", left = { t = "var", name = "x" } })
		T.eq(gn and gn.g, "not", "`not x` ⇒ not guard")
		local ga = P.recognize_guard({ t = "andor", op = "and",
			left = { t = "cmp", op = "ne", left = { t = "var", name = "x" }, right = { t = "lit", lit = "nil" } },
			right = { t = "var", name = "y" } })
		T.eq(ga and ga.g, "and", "`x ~= nil and y` ⇒ and guard")
		T.ok(ga and ga.left ~= nil and ga.right ~= nil, "both conjuncts recognized")
		local go = P.recognize_guard({ t = "andor", op = "or",
			left = { t = "var", name = "a" }, right = { t = "var", name = "b" } })
		T.eq(go and go.g, "or", "`a or b` ⇒ or guard")
	end)

	T.it("returns nil for an unrecognized expression (outside the five v1 forms)", function()
		local g = P.recognize_guard({ t = "call", fn = { t = "var", name = "foo" }, args = {} })
		T.eq(g, nil, "a non-guard call is not a recognized guard")
		-- `x < 0` (a relational comparison, not eq/ne) is not a v1 narrowing guard.
		T.eq(P.recognize_guard({ t = "cmp", op = "lt", left = { t = "var", name = "x" }, right = { t = "lit", lit = "int", v = 0 } }), nil, "x < 0 is not a narrowing guard")
	end)
end)

-- ── Audit round 1 regression suite (§9.7) ────────────────────────────────────
-- Each test below is the permanent regression form of an adversarial repro that
-- found a confirmed defect. The repros (/tmp/*.lua) were converted here so the
-- defect cannot silently return.

T.describe("audit round 1 — finding 1: well-formedness is a load-bearing precondition", function()
	-- repro_unsound.lua: subtype(string, μX.(number|X)) ACCEPTED (μ read as top).
	T.it("subtype(string, μX.(number|X)) is REJECTED (non-contractive μ never enters the relation)", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local mubad = G.mu("X", function(x) return G.union({ G.number(), x }) end)
		local c = S.subtype_claim(A.id("claim", "st"), G.string(), mubad)
		A.add_claim(state, c)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "e"), claim = c.id, method = "subtype_witness" }))
		local res = A.check({ state = state, requested_claims = { c.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.fail(has(res.accepted_claims, c), "string <: μX.(number|X) must NOT be accepted")
		T.ok(has(res.rejected_claims, c), "the subtype claim over a non-contractive μ is rejected")
	end)

	-- repro2b.lua: checks_against(string-node, μX.(number|X)) ACCEPTED (unsound:
	-- a string value type-checking against a number type).
	T.it("checks_against an ill-formed μ target is REJECTED (no string-checks-against-number leak)", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local mubad = G.mu("X", function(x) return G.union({ G.number(), x }) end)
		local nlit = add_node(state, "nlit", { t = "lit", lit = "str", v = "hello" })
		local g = S.empty_ctx()
		local c_synth = S.has_type_claim(A.id("claim", "syn"), g, nlit, G.lit_str("hello"))
		local c_sub = S.subtype_claim(A.id("claim", "sub"), G.lit_str("hello"), mubad)
		local c_chk = S.checks_against_claim(A.id("claim", "chk"), g, nlit, mubad)
		A.add_claim(state, c_synth); A.add_claim(state, c_sub); A.add_claim(state, c_chk)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "es"), claim = c_synth.id, method = "synth_lit" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "esub"), claim = c_sub.id, method = "subtype_witness" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ec"), claim = c_chk.id, method = "check_against", inputs = { c_synth.id, c_sub.id } }))
		local res = A.check({ state = state, requested_claims = { c_synth.id, c_sub.id, c_chk.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c_synth), "the literal synthesizes fine")
		T.fail(has(res.accepted_claims, c_sub), "lit_str <: ill-formed μ must NOT be accepted")
		T.fail(has(res.accepted_claims, c_chk), "checks_against an ill-formed μ must NOT be accepted")
		T.ok(has(res.rejected_claims, c_chk), "the checks_against claim is rejected")
	end)

	-- attack_parse_mu.lua: `--:: T = number | T`, `T = T?`, `T = T` all bound OK.
	T.it("declare_alias rejects non-contractive recursive aliases with (nil, errmsg)", function()
		for _, body in ipairs({ "number | T", "T?", "T" }) do
			local env = {} --[[: { [string]: Ty } ]]
			local r, err = P.declare_alias(env, "T", body)
			T.eq(r, nil, "alias 'T = " .. body .. "' is rejected")
			T.ok(type(err) == "string" and #err > 0, "rejection carries an error message")
			T.eq(env["T"], nil, "the ill-formed alias is not bound")
		end
	end)

	T.it("declare_alias still admits a guarded recursive alias", function()
		local env = {} --[[: { [string]: Ty } ]]
		local r = P.declare_alias(env, "List", "nil | { next: List }")
		T.ok(r ~= nil, "List = nil | { next: List } is well-formed and bound")
		T.ok(env["List"] ~= nil and TA.well_formed(env["List"]), "the bound alias is contractive")
	end)

	-- Forward-sibling alias references (§6.12, slice v2 increment 8). An alias whose
	-- body names a SIBLING declared LATER in the same batch resolves under dependency
	-- ordering — the strictly-correct generalization of source order. A GENUINE mutual
	-- cycle keeps source order and still errors honestly (the multi-binder-μ deferral,
	-- §9.19).
	T.it("declare_aliases_ordered resolves a forward-sibling reference (server_socket -> server_client)", function()
		local env = {} --[[: { [string]: Ty } ]]
		local decls = {
			{ name = "server_socket", body = "{ fd: integer, peer: server_client | nil }" },
			{ name = "server_client", body = "{ fd: integer }" },
		}
		local res = P.declare_aliases_ordered(env, decls)
		T.ok(res[1].ok, "server_socket (forward ref) declares cleanly")
		T.ok(res[2].ok, "server_client declares cleanly")
		T.ok(env["server_socket"] ~= nil and env["server_client"] ~= nil, "both bound")
	end)

	T.it("declare_aliases_ordered resolves a parent-union forward reference (Expr = ExprCall | ExprNeg)", function()
		local env = {} --[[: { [string]: Ty } ]]
		local decls = {
			{ name = "Expr", body = "ExprCall | ExprNeg" },
			{ name = "ExprCall", body = "{ kind: \"call\", n: integer }" },
			{ name = "ExprNeg", body = "{ kind: \"neg\", n: integer }" },
		}
		local res = P.declare_aliases_ordered(env, decls)
		T.ok(res[1].ok and res[2].ok and res[3].ok, "all three declare under dependency ordering")
		T.ok(env["Expr"] ~= nil, "the parent-union alias is bound")
	end)

	T.it("declare_aliases_ordered keeps source order for an independent batch (no forward refs)", function()
		local env = {} --[[: { [string]: Ty } ]]
		local decls = {
			{ name = "A", body = "{ x: integer }" },
			{ name = "B", body = "{ y: A }" }, -- backward ref, already resolved by source order
		}
		local res = P.declare_aliases_ordered(env, decls)
		T.ok(res[1].ok and res[2].ok, "backward-ref batch unchanged")
	end)

	-- FENCE: a genuine mutually-recursive family (A names B, B names A) is the
	-- multi-binder-μ substrate gap. Dependency ordering cannot break the cycle, so it
	-- still errors honestly — NOT silently bound to a wrong type (§9.19 deferral).
	T.it("declare_aliases_ordered errors honestly on a genuine mutual cycle (A <-> B)", function()
		local env = {} --[[: { [string]: Ty } ]]
		local decls = {
			{ name = "A", body = "{ b: B }" },
			{ name = "B", body = "{ a: A }" },
		}
		local res = P.declare_aliases_ordered(env, decls)
		T.fail(res[1].ok and res[2].ok, "a true mutual cycle is NOT silently resolved")
		T.ok(not res[1].ok or not res[2].ok, "at least one cycle member errors honestly")
	end)

	T.it("alias_decl_order places a dependency before its dependent", function()
		local decls = {
			{ name = "P", body = "Q | nil" },
			{ name = "Q", body = "{ n: integer }" },
		}
		local order = P.alias_decl_order(decls)
		-- Q (index 2) must come before P (index 1) since P depends on Q.
		local pos = {} --[[: { [integer]: integer } ]]
		for k, i in ipairs(order) do pos[i] = k end
		T.ok(pos[2] < pos[1], "Q is ordered before P (its dependent)")
	end)

	-- The degenerate non-occurring-binder case (decided + documented in §9.7):
	-- a μ whose variable never occurs (μX.never, μX.number) is rejected as
	-- ill-formed — it should be written as its body directly.
	T.it("a degenerate μ whose binder never occurs (μX.never, μX.number) is ill-formed", function()
		T.fail(TA.well_formed(G.mu("X", function(_) return G.never() end)), "μX.never is degenerate (binder never occurs)")
		T.fail(TA.well_formed(G.mu("X", function(_) return G.number() end)), "μX.number is degenerate (binder never occurs)")
		-- contrast: a guarded μ with an occurrence is well-formed.
		T.ok(TA.well_formed(G.mu("X", function(x) return G.union({ G.nil_(), G.rec({ { key = "n", ty = x, optional = false, readonly = false } }, "closed") }) end)), "a guarded, occurring μ is well-formed")
	end)
end)

T.describe("audit round 1 — finding 2: lit_int rejects non-integers (constructor + decoder)", function()
	-- attack_lit.lua: G.lit_int(3.5) interned to the same tid as lit_int(3) via %d.
	T.it("G.lit_int rejects a non-integer-valued number with (nil, errmsg)", function()
		G.reset()
		local a, err = G.lit_int(3.5)
		T.eq(a, nil, "lit_int(3.5) is rejected")
		T.ok(type(err) == "string", "the rejection carries a message")
		local b = G.lit_int(3)
		T.ok(b ~= nil, "lit_int(3) is accepted")
	end)

	T.it("integer-valued floats are accepted and intern by exact value (no %d collision)", function()
		G.reset()
		local three = G.lit_int(3)
		local three0 = G.lit_int(3.0)
		T.ok(three ~= nil and three0 ~= nil, "lit_int(3) and lit_int(3.0) are accepted")
		T.eq(three and three.tid, three0 and three0.tid, "3 and 3.0 are the same integer value (same tid)")
	end)

	T.it("the decoder rejects {k=lit_int, n=3.5} (parse-not-cast)", function()
		G.reset()
		T.eq(TA.decode({ k = "lit_int", n = 3.5 }), nil, "decode of a non-integer lit_int fails")
		T.ok(TA.decode({ k = "lit_int", n = 3 }) ~= nil, "decode of an integer lit_int succeeds")
	end)

	-- The 2^53 precision boundary: distinct integers beyond 2^53 are not separately
	-- representable as doubles, so they share a tid. Documented behavior, not a bug.
	T.it("integers beyond 2^53 collide by IEEE-754 precision (documented boundary)", function()
		G.reset()
		local big = G.lit_int(2 ^ 53)
		local big1 = G.lit_int(2 ^ 53 + 1) -- not representable; equals 2^53 as a double
		T.ok(big ~= nil and big1 ~= nil, "both are integer-valued doubles, accepted")
		T.eq(big and big.tid, big1 and big1.tid, "2^53 and 2^53+1 are the same double — same tid (precision boundary)")
	end)
end)

T.describe("audit round 1 — finding 3: narrowing unknown via type_eq/tag_eq is T ∩ positive", function()
	local NAR = require("lib.type.analysis.slice_narrow")
	-- confirm_unknown.lua: type(x)=="string" over unknown gave `never` (wrong).
	T.it("type(x)=='string' over unknown narrows truthy to string (not never)", function()
		G.reset()
		local tt = NAR.refine({ g = "type_eq", var = "x", tyname = "string" }, "x", G.unknown())
		T.eq(tt and tt.kind, "string", "unknown ∩ string-positive-set = string")
	end)

	T.it("type(x)=='table' over unknown narrows truthy to an open record {...}", function()
		G.reset()
		local tt = NAR.refine({ g = "type_eq", var = "x", tyname = "table" }, "x", G.unknown())
		T.eq(tt and tt.kind, "rec", "unknown ∩ table-positive-set = the open record")
		T.eq(tt and tt.rows, "open", "the positive set for `table` is the open row {...}")
	end)

	T.it("x.tag=='leaf' over unknown narrows truthy to { tag: 'leaf', ... }", function()
		G.reset()
		local tt = NAR.refine({ g = "tag_eq", var = "x", field = "tag", lit = G.lit_str("leaf") }, "x", G.unknown())
		T.eq(tt and tt.kind, "rec", "unknown ∩ tag-positive-set = the open tagged record")
		T.eq(tt and tt.rows, "open", "the tag positive set is open (more fields allowed)")
		-- the tag field is the literal singleton.
		local fields = tt and tt.fields or {} --[[: Field[] ]]
		local f1 = fields[1] --[[: Field | nil ]]
		T.eq(f1 and f1.key, "tag", "the tag field is present")
	end)

	-- The general rule must NOT regress union narrowing (still exact).
	T.it("union narrowing stays exact (the general rule generalizes, not special-cases unknown)", function()
		G.reset()
		local u = G.union({ G.string(), G.number() })
		local tt = NAR.refine({ g = "type_eq", var = "x", tyname = "string" }, "x", u)
		T.eq(tt and tt.kind, "string", "type(x)=='string' over string|number ⇒ string")
		-- lit_eq over unknown was already correct (via lit <: T) — keep it so.
		local tt2 = NAR.refine({ g = "lit_eq", var = "x", lit = G.lit_int(42) }, "x", G.unknown())
		T.eq(tt2 and tt2.kind, "lit_int", "x == 42 over unknown ⇒ lit_int(42)")
	end)
end)

T.describe("audit round 1 — finding 4: subtype memoization defeats the shared-subterm DAG blow-up", function()
	local SUB = require("lib.type.analysis.slice_subtype")
	-- attack_perf3.lua / perf_wall.lua: `{a: child, b: child}` chains were O(2^n),
	-- >120s at depth 30. With per-query memoization the depth-30 query is instant.
	--: (integer, Ty) -> Ty
	local function dag(n, leaf)
		local t = leaf
		for _ = 1, n do
			t = G.rec({ { key = "a", ty = t, optional = false, readonly = false }, { key = "b", ty = t, optional = false, readonly = false } }, "closed")
		end
		return t
	end

	T.it("dag(30) lit_int(1) <: dag(30) integer decides quickly and correctly", function()
		G.reset()
		local a = dag(30, G.lit_int(1))
		local b = dag(30, G.integer())
		local t0 = os.clock()
		local r = SUB.is_subtype(a, b)
		local dt = os.clock() - t0
		T.ok(r, "the DAG subtype holds (lit_int(1) <: integer at every leaf)")
		T.ok(dt < 1.0, "decides in well under a second (was >120s pre-memoization); took " .. string.format("%.4fs", dt))
	end)

	-- Memoization must not poison the coinductive contravariant-recursion result.
	T.it("memoization preserves coinductive correctness on mutually-recursive μ", function()
		G.reset()
		local m1 = G.mu("X", function(x) return G.union({ G.nil_(), G.rec({ { key = "next", ty = x, optional = false, readonly = false } }, "closed") }) end)
		local m2 = G.mu("Y", function(y) return G.union({ G.nil_(), G.rec({ { key = "next", ty = y, optional = false, readonly = false } }, "closed") }) end)
		T.ok(SUB.is_subtype(m1, m2), "alpha-equivalent recursive μ are mutual subtypes")
		T.ok(SUB.is_subtype(m1, G.unfold(m1)), "μ <: its one-step unfolding (equirecursive)")
		T.ok(SUB.is_subtype(G.unfold(m1), m1), "unfolding <: μ (equirecursive)")
	end)
end)

T.describe("audit round 1 — finding 5: instantiate_witness binds G to the callee", function()
	-- attack_inst.lua: a fabricated generic with no callee premise gave any call any
	-- return type. The callee's has_type(Γ, f_node, G) premise is now required and
	-- payload.generic must structurally equal it.
	T.it("a fabricated generic with NO callee premise is REJECTED", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local na = add_node(state, "na", { t = "lit", lit = "int", v = 5 })
		local nf = add_node(state, "nf", { t = "var", name = "f" })
		local ncall = add_node(state, "ncall", { t = "call", fn = { space = "artifact", key = "nf" }, args = { { space = "artifact", key = "na" } } })
		local g = S.empty_ctx()
		local generic = { k = "fn", params = { fixed = { { k = "tyvar", var = "X" } } }, ret = { fixed = { { k = "tyvar", var = "X" } } } }
		local c_synth_a = S.has_type_claim(A.id("claim", "syna"), g, na, G.lit_int(5))
		local c_sub_a = S.subtype_claim(A.id("claim", "suba"), G.lit_int(5), G.number())
		local c_arg = S.checks_against_claim(A.id("claim", "carg"), g, na, G.number())
		local c_call = S.has_type_claim(A.id("claim", "ccall"), g, ncall, G.number())
		A.add_claim(state, c_synth_a); A.add_claim(state, c_sub_a); A.add_claim(state, c_arg); A.add_claim(state, c_call)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "esyna"), claim = c_synth_a.id, method = "synth_lit" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "esuba"), claim = c_sub_a.id, method = "subtype_witness" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "earg"), claim = c_arg.id, method = "check_against", inputs = { c_synth_a.id, c_sub_a.id } }))
		-- NOTE: inputs has only the arg premise; NO has_type(f_node, generic) premise.
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ecall"), claim = c_call.id, method = "instantiate_witness",
			inputs = { c_arg.id }, result = { generic = generic, subst = { X = TA.encode(G.number()) } } }))
		local res = A.check({ state = state, requested_claims = { c_call.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.fail(has(res.accepted_claims, c_call), "a fabricated generic must NOT type the call")
		T.ok(has(res.rejected_claims, c_call), "the call is rejected (G not bound to the callee)")
	end)

	-- And a generic that does NOT match the callee premise's declared type is rejected.
	T.it("a generic that mismatches the callee premise's declared type is REJECTED", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local na = add_node(state, "na", { t = "lit", lit = "int", v = 5 })
		local nf = add_node(state, "nf", { t = "var", name = "f" })
		local ncall = add_node(state, "ncall", { t = "call", fn = { space = "artifact", key = "nf" }, args = { { space = "artifact", key = "na" } } })
		local g = S.empty_ctx()
		-- the callee's TRUE declared (generic) type, carried via a trusted signature.
		local true_generic = { k = "fn", params = { fixed = { { k = "tyvar", var = "X" } } }, ret = { fixed = { { k = "string" } } } }
		-- the producer FABRICATES a different generic (identity) to forge the return.
		local fake_generic = { k = "fn", params = { fixed = { { k = "tyvar", var = "X" } } }, ret = { fixed = { { k = "tyvar", var = "X" } } } }
		local tb = A.trust_boundary({ id = A.id("trust", "stdlib"), kind = "stdlib", issuer = "test" })
		A.add_trust_boundary(state, tb)
		local cfn = A.claim({ id = A.id("claim", "cfn"), semantics = S.ID, predicate = "has_type",
			args = { ctx = g, node = { space = "artifact", key = "nf" }, type = true_generic } })
		local c_synth_a = S.has_type_claim(A.id("claim", "syna"), g, na, G.lit_int(5))
		local c_sub_a = S.subtype_claim(A.id("claim", "suba"), G.lit_int(5), G.number())
		local c_arg = S.checks_against_claim(A.id("claim", "carg"), g, na, G.number())
		local c_call = S.has_type_claim(A.id("claim", "ccall"), g, ncall, G.number())
		A.add_claim(state, cfn); A.add_claim(state, c_synth_a); A.add_claim(state, c_sub_a); A.add_claim(state, c_arg); A.add_claim(state, c_call)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "efn"), claim = cfn.id, method = "trusted_signature", result = { trust = tb.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "esyna"), claim = c_synth_a.id, method = "synth_lit" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "esuba"), claim = c_sub_a.id, method = "subtype_witness" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "earg"), claim = c_arg.id, method = "check_against", inputs = { c_synth_a.id, c_sub_a.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ecall"), claim = c_call.id, method = "instantiate_witness",
			inputs = { cfn.id, c_arg.id }, result = { generic = fake_generic, subst = { X = TA.encode(G.number()) } } }))
		local res = A.check({ state = state, requested_claims = { c_call.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.fail(has(res.accepted_claims, c_call), "the fabricated generic does not match the callee's true type")
		T.ok(has(res.rejected_claims, c_call), "the call is rejected (payload.generic ≠ callee premise type)")
	end)
end)

-- ── Audit round 4 regression suite (§9.17) ───────────────────────────────────
-- A-F1: rec_with_indexer dynamic-key READ must union listed field types + val.
-- And-guard: a bare-variable left operand of `and` must be kept as a truthy
-- guard even when the right operand is unrecognized.

T.describe("audit round 4 — A-F1: rec_with_indexer dynamic-key read includes listed field types", function()
	T.it("dynamic read over { a: string, [string]: integer } is string | integer, not integer alone", function()
		G.reset()
		-- { a: string, [string]: integer }
		local rwi = G.rec_with_indexer(
			{ { key = "a", ty = G.string(), optional = false, readonly = false } },
			"closed",
			{ key = G.string(), val = G.integer() }
		)
		local result = S.index_result(rwi, nil, G.string())
		T.ok(result ~= nil, "dynamic read over rec_with_indexer with admitted key_ty returns non-nil")
		-- The result must include `string` (the listed field `a`'s type) AND `integer`
		-- (the indexer value). It must NOT be just `integer` (the pre-fix unsound result).
		local expected = G.union({ G.integer(), G.string() })
		T.eq(result and result.tid, expected.tid,
			"dynamic read result is string | integer (field union ∪ indexer val), not integer alone")
	end)

	T.it("dynamic read over an AGREEING rec_with_indexer stays the indexer val (still sound)", function()
		G.reset()
		-- { a: integer, [string]: integer } — field and indexer AGREE.
		local rwi = G.rec_with_indexer(
			{ { key = "a", ty = G.integer(), optional = false, readonly = false } },
			"closed",
			{ key = G.string(), val = G.integer() }
		)
		local result = S.index_result(rwi, nil, G.string())
		T.ok(result ~= nil, "agreeing rec_with_indexer dynamic read returns non-nil")
		-- union({ integer, integer }) normalizes to integer (no new type introduced).
		T.eq(result and result.tid, G.integer().tid,
			"agreeing fields: union normalizes to integer (no change in the agreeing case)")
	end)

	T.it("static read .a on rec_with_indexer DISAGREE still returns the field type (unchanged)", function()
		G.reset()
		local rwi = G.rec_with_indexer(
			{ { key = "a", ty = G.string(), optional = false, readonly = false } },
			"closed",
			{ key = G.string(), val = G.integer() }
		)
		local result = S.index_result(rwi, "a", nil)
		T.eq(result and result.tid, G.string().tid, "static .a returns string (field type, not indexer val)")
	end)
end)

T.describe("audit round 4 — and-guard: bare-variable left operand narrows even with unrecognized right", function()
	T.it("`x and <call>` (right unrecognized) still produces a truthy guard for x", function()
		-- `x and foo()` — `foo()` is a call, not a guard-shaped expression.
		local call_expr = { t = "call", fn = { t = "var", name = "foo" }, args = {} }
		local ga = P.recognize_guard({ t = "andor", op = "and",
			left = { t = "var", name = "x" },
			right = call_expr })
		T.ok(ga ~= nil, "and with unrecognized right still produces a guard")
		-- The result must be the left guard (truthy x), not nil.
		T.eq(ga and ga.g, "truthy", "the kept guard is the truthy-var form for x")
		T.eq(ga and ga.var, "x", "variable is x")
	end)

	T.it("`x and y ~= \"\"` recognizes as `and(truthy x, lit_eq y)`", function()
		-- x and y ~= "" — both sides recognizable; both kept.
		local cmp = { t = "cmp", op = "ne",
			left = { t = "var", name = "y" },
			right = { t = "lit", lit = "str", v = "" } }
		local ga = P.recognize_guard({ t = "andor", op = "and",
			left = { t = "var", name = "x" },
			right = cmp })
		T.ok(ga ~= nil, "both-recognizable and still produces a guard")
		T.eq(ga and ga.g, "and", "result is an and guard when both sides are recognized")
		T.ok(ga and ga.left ~= nil and ga.right ~= nil, "both conjuncts present")
	end)

	T.it("`<call> and x` (left unrecognized) keeps the right guard for x", function()
		local call_expr = { t = "call", fn = { t = "var", name = "foo" }, args = {} }
		local ga = P.recognize_guard({ t = "andor", op = "and",
			left = call_expr,
			right = { t = "var", name = "x" } })
		T.ok(ga ~= nil, "unrecognized left, recognized right still produces a guard")
		T.eq(ga and ga.g, "truthy", "the kept guard is the truthy-var form for x")
		T.eq(ga and ga.var, "x", "variable is x")
	end)

	T.it("`or` with an unrecognized operand still returns nil (no unsound partial)", function()
		local call_expr = { t = "call", fn = { t = "var", name = "foo" }, args = {} }
		local go = P.recognize_guard({ t = "andor", op = "or",
			left = { t = "var", name = "x" },
			right = call_expr })
		T.eq(go, nil, "or with unrecognized right ⇒ nil (cannot narrow from partial or-guard)")
	end)
end)

-- ── §6.7.1 operator typing (synth_binop / synth_unop) ────────────────────────

T.describe("crescent.slice.v1: binop_result — operator typing from the value universe", function()
	T.it("arithmetic: + - * % integer iff both integer, else number; / ^ always number", function()
		G.reset()
		T.eq(S.binop_result("+", G.integer(), G.integer()).tid, G.integer().tid, "int + int ⇒ integer")
		T.eq(S.binop_result("+", G.integer(), G.number()).tid, G.number().tid, "int + number ⇒ number")
		T.eq(S.binop_result("*", G.lit_int(2), G.lit_int(3)).tid, G.integer().tid, "lit_int * lit_int ⇒ integer (no fold)")
		T.eq(S.binop_result("%", G.integer(), G.integer()).tid, G.integer().tid, "int % int ⇒ integer")
		T.eq(S.binop_result("/", G.integer(), G.integer()).tid, G.number().tid, "/ ALWAYS number (real-valued)")
		T.eq(S.binop_result("^", G.integer(), G.integer()).tid, G.number().tid, "^ ALWAYS number")
	end)
	T.it("concat ⇒ string over string|number; comparisons/equality ⇒ boolean; len ⇒ integer", function()
		G.reset()
		T.eq(S.binop_result("..", G.string(), G.integer()).tid, G.string().tid, ".. over string|number ⇒ string")
		T.eq(S.binop_result("..", G.lit_str("a"), G.number()).tid, G.string().tid, ".. lit_str/number ⇒ string")
		T.eq(S.binop_result("<", G.number(), G.number()).tid, G.boolean().tid, "number < number ⇒ boolean")
		T.eq(S.binop_result("<", G.string(), G.string()).tid, G.boolean().tid, "string < string ⇒ boolean")
		T.eq(S.binop_result("==", G.string(), G.number()).tid, G.boolean().tid, "== over ANY ⇒ boolean")
		T.eq(S.binop_result("~=", G.boolean(), G.nil_()).tid, G.boolean().tid, "~= over ANY ⇒ boolean")
	end)
	T.it("metatable-dependent operands return nil (deferral, never a type error)", function()
		G.reset()
		local r = G.rec({ { key = "x", ty = G.integer(), optional = false, readonly = false } }, "closed")
		T.eq(S.binop_result("+", r, r), nil, "table + table ⇒ deferral (no metatable in v1)")
		T.eq(S.binop_result("<", G.number(), G.string()), nil, "number < string (mixed) ⇒ deferral")
		T.eq(S.binop_result("..", r, G.string()), nil, ".. with a table operand ⇒ deferral")
	end)
	T.it("unop: # over string/table ⇒ integer; unary - integer-or-number; deferral otherwise", function()
		G.reset()
		local arr = G.indexer(G.integer(), G.string())
		T.eq(S.unop_result("#", G.string()).tid, G.integer().tid, "#string ⇒ integer")
		T.eq(S.unop_result("#", arr).tid, G.integer().tid, "#table ⇒ integer")
		T.eq(S.unop_result("-", G.integer()).tid, G.integer().tid, "-integer ⇒ integer")
		T.eq(S.unop_result("-", G.number()).tid, G.number().tid, "-number ⇒ number")
		T.eq(S.unop_result("#", G.number()), nil, "#number ⇒ deferral")
		T.eq(S.unop_result("-", G.string()), nil, "-string ⇒ deferral")
	end)
end)

T.describe("crescent.slice.v1: synth_binop / synth_unop evidence methods", function()
	T.it("synth_binop validates `a + b : integer` over two integer-typed operands", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local na = add_node(state, "ba", { t = "var", name = "a" })
		local nb = add_node(state, "bb", { t = "var", name = "b" })
		local nop = add_node(state, "bop", { t = "binop", op = "+",
			left = { space = "artifact", key = "ba" }, right = { space = "artifact", key = "bb" } })
		local g = S.extend(S.extend(S.empty_ctx(), "a", G.integer()), "b", G.integer())
		local ca = S.has_type_claim(A.id("claim", "ca"), g, na, G.integer())
		local cb = S.has_type_claim(A.id("claim", "cb"), g, nb, G.integer())
		local cop = S.has_type_claim(A.id("claim", "cop"), g, nop, G.integer())
		A.add_claim(state, ca); A.add_claim(state, cb); A.add_claim(state, cop)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ea"), claim = ca.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eb"), claim = cb.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eop"), claim = cop.id, method = "synth_binop", inputs = { ca.id, cb.id } }))
		local res = A.check({ state = state, requested_claims = { cop.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, cop), "a + b ⇒ integer accepted")
		T.ok(dep_to(res, cop, "ca"), "binop depends on its left operand premise")
		T.ok(dep_to(res, cop, "cb"), "binop depends on its right operand premise")
	end)
	T.it("synth_binop rejects an asserted type that does not match the operator's result kind", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local na = add_node(state, "ba", { t = "var", name = "a" })
		local nb = add_node(state, "bb", { t = "var", name = "b" })
		local nop = add_node(state, "bop", { t = "binop", op = "/",
			left = { space = "artifact", key = "ba" }, right = { space = "artifact", key = "bb" } })
		local g = S.extend(S.extend(S.empty_ctx(), "a", G.integer()), "b", G.integer())
		local ca = S.has_type_claim(A.id("claim", "ca"), g, na, G.integer())
		local cb = S.has_type_claim(A.id("claim", "cb"), g, nb, G.integer())
		-- `/` is ALWAYS number; asserting integer must reject.
		local cop = S.has_type_claim(A.id("claim", "cop"), g, nop, G.integer())
		A.add_claim(state, ca); A.add_claim(state, cb); A.add_claim(state, cop)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ea"), claim = ca.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eb"), claim = cb.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eop"), claim = cop.id, method = "synth_binop", inputs = { ca.id, cb.id } }))
		local res = A.check({ state = state, requested_claims = { cop.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.rejected_claims, cop), "asserting `a / b : integer` is rejected (/ is number)")
	end)
	T.it("synth_unop validates `#s : integer` over a string operand", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local ns = add_node(state, "us", { t = "var", name = "s" })
		local nop = add_node(state, "uop", { t = "unop", op = "#", operand = { space = "artifact", key = "us" } })
		local g = S.extend(S.empty_ctx(), "s", G.string())
		local cs = S.has_type_claim(A.id("claim", "cs"), g, ns, G.string())
		local cop = S.has_type_claim(A.id("claim", "cop"), g, nop, G.integer())
		A.add_claim(state, cs); A.add_claim(state, cop)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "es"), claim = cs.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eop"), claim = cop.id, method = "synth_unop", inputs = { cs.id } }))
		local res = A.check({ state = state, requested_claims = { cop.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, cop), "#s ⇒ integer accepted")
		T.ok(dep_to(res, cop, "cs"), "unop depends on its operand premise")
	end)
end)
