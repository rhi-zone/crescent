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
		local narg = add_node(state, "narg", { t = "var", name = "s" })
		local ncall = add_node(state, "ncall", { t = "call", fn = { space = "artifact", key = "nf" }, args = { { space = "artifact", key = "narg" } } })
		local g = S.extend(S.empty_ctx(), "s", G.string())
		-- arg checked against σ-applied param (string).
		local carg_s = S.has_type_claim(A.id("claim", "cargs"), g, narg, G.string())
		local csub = S.subtype_claim(A.id("claim", "csub"), G.string(), G.string())
		local carg = S.checks_against_claim(A.id("claim", "carg"), g, narg, G.string())
		local ccall = S.has_type_claim(A.id("claim", "ccall"), g, ncall, G.string())
		A.add_claim(state, carg_s); A.add_claim(state, csub); A.add_claim(state, carg); A.add_claim(state, ccall)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eargs"), claim = carg_s.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "esub"), claim = csub.id, method = "subtype_witness" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "earg"), claim = carg.id, method = "check_against", inputs = { carg_s.id, csub.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ecall"), claim = ccall.id, method = "instantiate_witness",
			inputs = { carg.id }, result = { generic = generic, subst = { T = TA.encode(G.string()) } } }))
		local res = A.check({ state = state, requested_claims = { ccall.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, ccall), "identity<string>(s) ⇒ string under validated σ")
	end)

	T.it("instantiate_witness rejects a σ that does not match the argument check", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local generic = { k = "fn", params = { fixed = { { k = "tyvar", var = "T" } } }, ret = { fixed = { { k = "tyvar", var = "T" } } } }
		local narg = add_node(state, "narg", { t = "var", name = "s" })
		local ncall = add_node(state, "ncall", { t = "call", fn = { space = "artifact", key = "nf" }, args = { { space = "artifact", key = "narg" } } })
		local g = S.extend(S.empty_ctx(), "s", G.string())
		local carg_s = S.has_type_claim(A.id("claim", "cargs"), g, narg, G.string())
		local csub = S.subtype_claim(A.id("claim", "csub"), G.string(), G.string())
		local carg = S.checks_against_claim(A.id("claim", "carg"), g, narg, G.string())
		-- σ claims T = number, but the arg was checked against string ⇒ mismatch.
		local ccall = S.has_type_claim(A.id("claim", "ccall"), g, ncall, G.number())
		A.add_claim(state, carg_s); A.add_claim(state, csub); A.add_claim(state, carg); A.add_claim(state, ccall)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eargs"), claim = carg_s.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "esub"), claim = csub.id, method = "subtype_witness" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "earg"), claim = carg.id, method = "check_against", inputs = { carg_s.id, csub.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ecall"), claim = ccall.id, method = "instantiate_witness",
			inputs = { carg.id }, result = { generic = generic, subst = { T = TA.encode(G.number()) } } }))
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
