-- lib/type/v10_kernel/pilot/flow_narrow_v1_test.lua
--
-- Tests for the flow-narrowing theory (pilot/flow_narrow_v1.lua) over the
-- canonical v10 core: the signature declares cleanly; each of the two rule
-- schemas replays a hand-built certificate to the expected conclusion; a
-- malformed variant of each is rejected at replay; a two-guard chain
-- (truthiness peel, then a type()-tag peel on the remainder) replays
-- end-to-end; taint from the syntax-facts axiom propagates and does not
-- grow across repeated citations of the same axiom declaration.
--
-- The positive-path cases here introduce the "type at the guard point"
-- fact as a HYPOTHESIS that deliberately stays open (neither narrowing
-- rule declares a discharge slot), so they go through the owner-ratified
-- READ-ONLY OBSERVATION entry point (`rl.observe` — design doc,
-- "Read-only observation entry point"), which returns the per-node
-- (conclusion, taint, open) triple without acceptance; root-strict
-- `rl.replay` would (correctly) reject these derivations as having
-- undischarged hypotheses, which is asserted once below.

local T = require("lib.test.assert")
local ta = require("lib.type.v10_cleanroom.term_algebra")
local rl = require("lib.type.v10_cleanroom.replayer")
local addr_v1 = require("lib.type.v10_kernel.pilot.addr_v1")
local flow_narrow_v1 = require("lib.type.v10_kernel.pilot.flow_narrow_v1")

--: (v: Term | nil, err: string | nil) -> Term
local function must_term(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

--: (v: Signature | nil, err: string | nil) -> Signature
local function must_sig(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

--: (v: NarrowVocab | nil, err: string | nil) -> NarrowVocab
local function must_vocab(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

--: (v: Replayer | nil, err: string | nil) -> Replayer
local function must_rp(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

local addr_sig_raw, addr_sig_err = addr_v1.declare()
local addr_sig = must_sig(addr_sig_raw, addr_sig_err)
local addr_ops = addr_sig.ops

-- A file identity and a handful of structural points/paths, built the
-- same way pilot/narrow_pilot_v1_test.lua builds its worked example.
--: () -> Term
local function fid()
	return must_term(ta.build(addr_ops.file_id_of, {
		must_term(ta.build(addr_ops.bs_cons, {
			must_term(ta.build(addr_ops.b1, {})), must_term(ta.build(addr_ops.bs_nil, {})),
		})),
	}))
end
--: (n: integer) -> Term
local function nat(n)
	local t = must_term(ta.build(addr_ops.zero, {}))
	for _ = 1, n do t = must_term(ta.build(addr_ops.succ, { t })) end
	return t
end
-- A path is a child-index chain from the chunk root.
--: (indices: integer[]) -> Term
local function path(indices)
	local p = must_term(ta.build(addr_ops.path_root, {}))
	for _, i in ipairs(indices) do
		p = must_term(ta.build(addr_ops.path_child, { p, nat(i) }))
	end
	return p
end
--: (indices: integer[]) -> Term
local function entry(indices) return must_term(ta.build(addr_ops.entry_of, { fid(), path(indices) })) end
--: (indices: integer[]) -> Term
local function exit(indices) return must_term(ta.build(addr_ops.exit_of, { fid(), path(indices) })) end
-- The variable being narrowed: identified by its declaration-site path
-- (pilot/narrow_pilot_v1's variable-identity choice, §2.3 of the
-- proposal), a fixed local at child 5 of the root for every test here.
local var_path = path({ 5 })

--:: NarrowSetup = { vocab: NarrowVocab, rp: Replayer }

-- One registry + vocabulary + replayer per describe block ((name, version)
-- unique per registry, F11).
--: () -> NarrowSetup
local function setup()
	local reg = rl.new_registry()
	local vocab_raw, vocab_err = flow_narrow_v1.declare_vocabulary(reg, addr_sig)
	local vocab = must_vocab(vocab_raw, vocab_err)
	local rp = must_rp(rl.new_replayer({ registry = reg }))
	return { vocab = vocab, rp = rp }
end

T.describe("flow-narrow-v1", function()
	T.it("declares with no errors, given an already-declared addr-v1", function()
		local reg = rl.new_registry()
		local vocab, err = flow_narrow_v1.declare_vocabulary(reg, addr_sig)
		T.ok(vocab, err)
		if vocab == nil then return end
		T.eq(vocab.signature.name, "narrow-pilot-v1")
		T.eq(vocab.signature.version, 2)
		T.eq(vocab.signature.sorts.point, addr_sig.sorts.point)
		T.eq(vocab.signature.sorts.path, addr_sig.sorts.path)
	end)

	T.describe("narrow-select-match", function()
		local s = setup()
		local vocab, rp = s.vocab, s.rp

		-- `type(x) == "string"` then-branch: x : string|nil at the guard
		-- point (exit of the test expr, child 0); then-branch entry is
		-- child 0 of child 1 (the if-statement), else-branch entry child 1.
		local pg = exit({ 1 })
		local pb_then = entry({ 1, 0 })
		local ty_string = must_term(vocab.TyOf(must_term(vocab.tag_string())))
		local ty_nil = must_term(vocab.TyOf(must_term(vocab.tag_nil())))
		local union_ty = must_term(vocab.TyUnion(ty_string, ty_nil))

		T.it("observes the expected conclusion: x : string at the then-branch entry", function()
			local hyp = { kind = "hypothesis", judgment = must_term(vocab.HoldsAt(pg, var_path, union_ty)) } --[[: CertNode ]]
			local fact_node = {
				kind = "axiom", axiom = vocab.ax_syntax_facts,
				bindings = { Pg = pg, Pb = pb_then, X = var_path, TA = ty_string },
			} --[[: CertNode ]]
			local node = { kind = "rule", rule = vocab.rule_match, premises = { hyp, fact_node } } --[[: CertNode ]]
			local result, err = rl.observe(rp, node)
			T.ok(result, err)
			if result == nil then return end
			T.ok(ta.equal(result.conclusion, must_term(vocab.HoldsAt(pb_then, var_path, ty_string))))
			-- the hypothesis deliberately stays open, so root-strict replay
			-- (the acceptance channel) rejects the same node
			local root, rerr = rl.replay(rp, node)
			T.eq(root, nil)
			T.ok(rerr and rerr:find("undischarged"))
		end)

		T.it("rejects when the syntax fact's target_ty does not match the union's first member", function()
			local hyp = { kind = "hypothesis", judgment = must_term(vocab.HoldsAt(pg, var_path, union_ty)) } --[[: CertNode ]]
			-- Claims the guard selects tag_number, but the actual type at
			-- the guard point has tag_string as its first union member.
			local ty_number = must_term(vocab.TyOf(must_term(vocab.tag_number())))
			local fact_node = {
				kind = "axiom", axiom = vocab.ax_syntax_facts,
				bindings = { Pg = pg, Pb = pb_then, X = var_path, TA = ty_number },
			} --[[: CertNode ]]
			local node = { kind = "rule", rule = vocab.rule_match, premises = { hyp, fact_node } } --[[: CertNode ]]
			local result, err = rl.observe(rp, node)
			T.eq(result, nil)
			T.ok(err)
		end)
	end)

	T.describe("narrow-select-rest", function()
		local s = setup()
		local vocab, rp = s.vocab, s.rp

		local pg = exit({ 1 })
		local pb_else = entry({ 1, 1 })
		local ty_string = must_term(vocab.TyOf(must_term(vocab.tag_string())))
		local ty_nil = must_term(vocab.TyOf(must_term(vocab.tag_nil())))
		local union_ty = must_term(vocab.TyUnion(ty_string, ty_nil))

		T.it("observes the expected conclusion: x : nil at the else-branch entry", function()
			local hyp = { kind = "hypothesis", judgment = must_term(vocab.HoldsAt(pg, var_path, union_ty)) } --[[: CertNode ]]
			local fact_node = {
				kind = "axiom", axiom = vocab.ax_syntax_facts,
				bindings = { Pg = pg, Pb = pb_else, X = var_path, TA = ty_string },
			} --[[: CertNode ]]
			local node = { kind = "rule", rule = vocab.rule_rest, premises = { hyp, fact_node } } --[[: CertNode ]]
			local result, err = rl.observe(rp, node)
			T.ok(result, err)
			if result == nil then return end
			T.ok(ta.equal(result.conclusion, must_term(vocab.HoldsAt(pb_else, var_path, ty_nil))))
		end)

		T.it("rejects when the syntax fact names a different guarded variable path", function()
			local other_path = path({ 6 })
			local hyp = { kind = "hypothesis", judgment = must_term(vocab.HoldsAt(pg, var_path, union_ty)) } --[[: CertNode ]]
			local fact_node = {
				kind = "axiom", axiom = vocab.ax_syntax_facts,
				bindings = { Pg = pg, Pb = pb_else, X = other_path, TA = ty_string },
			} --[[: CertNode ]]
			local node = { kind = "rule", rule = vocab.rule_rest, premises = { hyp, fact_node } } --[[: CertNode ]]
			local result, err = rl.observe(rp, node)
			T.eq(result, nil)
			T.ok(err)
		end)
	end)

	T.it("the syntax-facts axiom rejects a discharge form (grammar rule, no discharge on axiom nodes)", function()
		local s = setup()
		local vocab = s.vocab
		local reg2 = rl.new_registry()
		local sig = vocab.signature
		local pat = must_term(vocab.GuardSelects(
			must_term(ta.meta("Pg", sig.sorts.point)),
			must_term(ta.meta("Pb", sig.sorts.point)),
			must_term(ta.meta("X", sig.sorts.path)),
			must_term(ta.meta("TA", sig.sorts.ty))
		))
		local bad_ax, err = rl.declare_axiom(reg2, {
			name = "pilot-syntax-facts-v1-bad", version = 1,
			pattern = pat,
			discharges = { { premise = 1, hypothesis = must_term(ta.meta("X", sig.sorts.path)) } },
		})
		T.eq(bad_ax, nil)
		T.ok(err)
	end)

	T.describe("chained derivation: truthiness peel, then a type-tag peel on the remainder", function()
		local s = setup()
		local vocab, rp = s.vocab, s.rp

		-- x : (nil|false) | (string|table) at the outer guard's point.
		local ty_string = must_term(vocab.TyOf(must_term(vocab.tag_string())))
		local ty_table = must_term(vocab.TyOf(must_term(vocab.tag_table())))
		local falsy = must_term(vocab.falsy_ty())
		local truthy_remainder = must_term(vocab.TyUnion(ty_string, ty_table))
		local whole_ty = must_term(vocab.TyUnion(falsy, truthy_remainder))

		-- Guard 1: `if x then` at exit({0}); then-branch entry({0,0}).
		local pg1 = exit({ 0 })
		local pb1 = entry({ 0, 0 })
		-- Guard 2, nested inside guard 1's then-branch: `if type(x) ==
		-- "string" then` at exit({0,0,2}); its then-branch entry({0,0,2,0}).
		local pg2 = exit({ 0, 0, 2 })
		local pb2 = entry({ 0, 0, 2, 0 })

		--: () -> (CertNode, CertNode)
		local function build_chain()
			local hyp = { kind = "hypothesis", judgment = must_term(vocab.HoldsAt(pg1, var_path, whole_ty)) } --[[: CertNode ]]
			local fact1 = {
				kind = "axiom", axiom = vocab.ax_syntax_facts,
				bindings = { Pg = pg1, Pb = pb1, X = var_path, TA = falsy },
			} --[[: CertNode ]]
			-- Truthiness then-branch keeps the REST (the truthy remainder).
			local step1 = { kind = "rule", rule = vocab.rule_rest, premises = { hyp, fact1 } } --[[: CertNode ]]

			-- step1's conclusion is holds_at(pb1, var_path, truthy_remainder)
			-- — re-cite it as guard 2's own "type fact at the guard point"
			-- premise. Guard 2 evaluates at pb1 itself (same point the prior
			-- narrowing landed at, before descending into the nested if).
			local fact2 = {
				kind = "axiom", axiom = vocab.ax_syntax_facts,
				bindings = { Pg = pb1, Pb = pb2, X = var_path, TA = ty_string },
			} --[[: CertNode ]]
			local step2 = { kind = "rule", rule = vocab.rule_match, premises = { step1, fact2 } } --[[: CertNode ]]
			return hyp, step2
		end

		T.it("observes end-to-end: x : string at the innermost then-branch", function()
			local _, step2 = build_chain()
			local result, err = rl.observe(rp, step2)
			T.ok(result, err)
			if result == nil then return end
			T.ok(ta.equal(result.conclusion, must_term(vocab.HoldsAt(pb2, var_path, ty_string))))
		end)

		T.it("taint carries the syntax-facts axiom key, deduplicated across both citations", function()
			local hyp, step2 = build_chain()
			local result, err = rl.observe(rp, step2)
			T.ok(result, err)
			if result == nil then return end
			local n = 0
			local only_key = nil --[[: string | nil ]]
			for key in pairs(result.taint) do
				n = n + 1
				only_key = key
			end
			T.eq(n, 1)
			T.eq(only_key, rl.citation_key("pilot-syntax-facts-v1", 1))
			T.eq(result.taint[rl.citation_key("pilot-syntax-facts-v1", 1)], vocab.ax_syntax_facts)
			-- The hypothesis leaf itself stays open (no discharge slot in
			-- either narrowing rule — see module header) — confirm it is
			-- exactly the one open node (identity per F8), not silently
			-- dropped or duplicated.
			T.eq(#result.open, 1)
			T.eq(result.open[1], hyp)
		end)
	end)
end)

return {}
