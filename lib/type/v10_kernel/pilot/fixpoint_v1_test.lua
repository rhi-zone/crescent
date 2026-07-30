-- lib/type/v10_kernel/pilot/fixpoint_v1_test.lua
--
-- Tests for the fixpoint-certificate theory (pilot/fixpoint_v1.lua) over
-- the canonical v10 core: the signature declares cleanly (v3); each rule
-- replays a hand-built certificate to its expected conclusion; a malformed
-- variant of each is rejected at replay; and — the milestone's acceptance
-- gate — a FULL loop-invariant certificate over a synthetic loop
-- ROOT-ACCEPTS via `rl.replay` (not merely `rl.observe`).
--
-- ── The root-accepting loop certificate, hand-traced ─────────────────────────
--
-- Synthetic loop (not tied to any real file — a hand-built shape chosen to
-- stay honestly within this pilot's declared scope, per the proposal's own
-- §5's finding that a REAL loop body overwhelmingly reassigns via a call
-- expression, categorically out of scope):
--
--   -- (some statement establishes x's declared union before the loop)
--   while <test> do
--       noop()   -- does not touch x
--       x = x    -- self-copy; body's LAST statement
--   end
--
-- `x : nil|number` is the invariant (`Tinv`). The four milestone
-- ingredients map onto four distinct sub-derivations:
--   - "entry fact via initial-facts axiom": `pilot-initial-facts-v1`
--     (pilot/pilot_initial_facts_v1.lua) cited directly for `PreLoop`,
--     `T0 = Tinv` exactly (the hypothetically-annotated-declaration
--     reading the proposal's own §5.2 worked example uses).
--   - "body transfer via assignment rules": `assign-copy-transfer`,
--     citing a self-copy `assign_copies(BE, x, x)` fact.
--   - "persistence stitching statements": `seq-persist`, citing
--     `stmt_seq(LH, BE)` + `stmt_preserves(LH, BE, x)` for the `noop()`
--     statement, carrying the ASSUMED invariant hypothesis forward.
--   - "discharge closing the invariant hypothesis": the root
--     `loop-invariant-discharge` citation's slot 1 (targeting premise
--     index 2 — the back-edge subderivation) discharges exactly that
--     hypothesis leaf.
--
-- Addressing choices made once, documented (not tied to prover_addr.lua's
-- real conventions — that correspondence is pilot step 4/prover territory,
-- not this theory-level test's job):
--   `LH := entry_of(body_path)` (the loop body's own entry — sidesteps the
--   entry_of(test_path)-vs-entry_of(body_path) coincidence question, which
--   only matters once a real prover emits real certificates).
--   `BE := exit_of(child(body_path, 0))` — exit of the FIRST statement
--   (`noop()`). Since `x = x` is the body's last statement and a bare-
--   identifier RHS has no sub-steps, its own `assign_copies` transfer
--   point (§2.1: `exit_of(rhs_expr_path)`) is the SAME real control point
--   as "exit of the block's last statement" (§4.1's reading) — both are
--   represented by this one term rather than two structurally-different-
--   but-semantically-coincident path terms.
--
-- Why `assign_copies(BE, x, x)` (self-copy) rather than a literal
-- reassignment: `assign-literal-transfer` has exactly one premise slot
-- (`assign_literal(Pa,X,Tag)`) and never reads a prior fact, so a literal
-- reassignment's back-edge fact could never be made to depend on the
-- assumed invariant hypothesis at all — discharge would be VACUOUS (no
-- hypothesis leaf anywhere in the cited premise's tree, hence nothing for
-- the discharge slot to legitimately close). `assign-copy-transfer` DOES
-- read a prior fact (`holds_at(Pa,Y,T)`), so citing it with `X=Y=x` lets
-- the back-edge fact be genuinely produced FROM the persisted hypothesis
-- (`seq-persist`'s conclusion), making the discharge non-vacuous: `H1` is
-- traceably present in premise 2's own open-hypothesis set, not merely
-- assumed to be by construction.
--
-- Hand-traced validity (recorded so a reviewer does not have to re-derive
-- it from scratch): `H1`'s open set = `{H1}`; `seq-persist`'s citation
-- open set = `{H1}` (its own axiom premises contribute `{}`);
-- `assign-copy-transfer`'s citation open set = `{H1}` (its own axiom
-- premise contributes `{}`) — this IS "premise 2" of the root citation.
-- The root's discharge slot 1 cites `{H1}` against premise 2's open set
-- (`{H1}` — contains it, so the citation is valid) and checks
-- `H1`'s judgment (`holds_at(LH,x,Tinv)`) equals
-- `instantiate(slot_pattern, bindings)` where the shared bindings come
-- from matching all 5 premises (`LH`/`BE` from `loop_edge`; `X`/`Tp` from
-- premise 2, `Tp` binding to the ACTUAL `Tinv` term since premise 2's real
-- conclusion is `holds_at(BE,x,Tinv)`; `Tinv` from premise 3's
-- `ty_sub(Tinv,Tinv)`, a ty-sub-refl citation over `Tinv`; `PreLoop`/`T0`
-- from premise 4, `T0` binding to the actual `Tinv` term since the
-- initial-facts axiom is cited with `T=Tinv`; premise 5 re-checks
-- `ty_sub(T0,Tinv)` = `ty_sub(Tinv,Tinv)`, consistent) — every premise's
-- ACTUAL conclusion agrees with what the shared metavariables already
-- forced, so `match_into` never rejects. Root open set = union of all 5
-- premises' opens (`{H1}` from premise 2, `{}` from the rest) MINUS
-- discharged (`{H1}`) = `{}`. `M.replay` accepts.

local T = require("lib.test.assert")
local ta = require("lib.type.v10_cleanroom.term_algebra")
local rl = require("lib.type.v10_cleanroom.replayer")
local addr_v1 = require("lib.type.v10_kernel.pilot.addr_v1")
local fixpoint_v1 = require("lib.type.v10_kernel.pilot.fixpoint_v1")
local pilot_initial_facts_v1 = require("lib.type.v10_kernel.pilot.pilot_initial_facts_v1")

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

--: (v: FixpointVocab | nil, err: string | nil) -> FixpointVocab
local function must_vocab(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

--: (v: AxiomDecl | nil, err: string | nil) -> AxiomDecl
local function must_axiom(v, err)
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

local var_path = path({ 5 })
local other_path = path({ 6 })

--:: Setup = { vocab: FixpointVocab, rp: Replayer, ax_initial: AxiomDecl }

--: () -> Setup
local function setup()
	local reg = rl.new_registry()
	local vocab_raw, vocab_err = fixpoint_v1.declare_vocabulary(reg, addr_sig)
	local vocab = must_vocab(vocab_raw, vocab_err)
	local ax_initial_raw, ax_initial_err = pilot_initial_facts_v1.declare(reg, vocab)
	local ax_initial = must_axiom(ax_initial_raw, ax_initial_err)
	local rp_raw, rp_err = rl.new_replayer({ registry = reg })
	local rp = must_rp(rp_raw, rp_err)
	return { vocab = vocab, rp = rp, ax_initial = ax_initial }
end

T.describe("fixpoint-v1", function()
	T.it("declares with no errors, given an already-declared addr-v1", function()
		local reg = rl.new_registry()
		local vocab, err = fixpoint_v1.declare_vocabulary(reg, addr_sig)
		T.ok(vocab, err)
		if vocab == nil then return end
		T.eq(vocab.signature.name, "narrow-pilot-v1")
		T.eq(vocab.signature.version, 4)
		T.eq(vocab.signature.sorts.point, addr_sig.sorts.point)
		T.eq(vocab.signature.sorts.path, addr_sig.sorts.path)
	end)

	T.describe("ty_sub theory", function()
		local s = setup()
		local vocab, rp = s.vocab, s.rp
		local ty_nil = must_term(vocab.TyOf(must_term(vocab.tag_nil())))
		local ty_number = must_term(vocab.TyOf(must_term(vocab.tag_number())))
		local ty_string = must_term(vocab.TyOf(must_term(vocab.tag_string())))
		local union_nil_number = must_term(vocab.TyUnion(ty_nil, ty_number))

		T.it("ty-sub-refl replays: ty_sub(nil, nil)", function()
			local node = { kind = "axiom", axiom = vocab.ax_ty_sub_refl, bindings = { A = ty_nil } } --[[: CertNode ]]
			local result, err = rl.replay(rp, node)
			T.ok(result, err)
			if result == nil then return end
			T.ok(ta.equal(result.conclusion, must_term(vocab.TySub(ty_nil, ty_nil))))
		end)

		T.it("ty-sub-union-here-left replays: ty_sub(nil, nil|number)", function()
			local node = { kind = "axiom", axiom = vocab.ax_ty_sub_union_here_left,
				bindings = { A = ty_nil, Rest = ty_number } } --[[: CertNode ]]
			local result, err = rl.replay(rp, node)
			T.ok(result, err)
			if result == nil then return end
			T.ok(ta.equal(result.conclusion, must_term(vocab.TySub(ty_nil, union_nil_number))))
		end)

		T.it("ty-sub-union-here-right replays: ty_sub(number, nil|number)", function()
			local node = { kind = "axiom", axiom = vocab.ax_ty_sub_union_here_right,
				bindings = { X = ty_nil, B = ty_number } } --[[: CertNode ]]
			local result, err = rl.replay(rp, node)
			T.ok(result, err)
			if result == nil then return end
			T.ok(ta.equal(result.conclusion, must_term(vocab.TySub(ty_number, union_nil_number))))
		end)

		T.it("ty-sub-trans replays: ty_sub(nil, nil|number) from two axiom citations chained", function()
			-- nil <: nil|number <: (nil|number)|string
			local ab = { kind = "axiom", axiom = vocab.ax_ty_sub_union_here_left,
				bindings = { A = ty_nil, Rest = ty_number } } --[[: CertNode ]]
			local union_all = must_term(vocab.TyUnion(union_nil_number, ty_string))
			local bc = { kind = "axiom", axiom = vocab.ax_ty_sub_union_here_left,
				bindings = { A = union_nil_number, Rest = ty_string } } --[[: CertNode ]]
			local node = { kind = "rule", rule = vocab.rule_ty_sub_trans, premises = { ab, bc } } --[[: CertNode ]]
			local result, err = rl.replay(rp, node)
			T.ok(result, err)
			if result == nil then return end
			T.ok(ta.equal(result.conclusion, must_term(vocab.TySub(ty_nil, union_all))))
		end)

		T.it("ty-sub-trans rejects when the two premises don't chain (B mismatch)", function()
			local ab = { kind = "axiom", axiom = vocab.ax_ty_sub_refl, bindings = { A = ty_nil } } --[[: CertNode ]]
			local bc = { kind = "axiom", axiom = vocab.ax_ty_sub_refl, bindings = { A = ty_number } } --[[: CertNode ]]
			local node = { kind = "rule", rule = vocab.rule_ty_sub_trans, premises = { ab, bc } } --[[: CertNode ]]
			local result, err = rl.replay(rp, node)
			T.eq(result, nil)
			T.ok(err)
		end)

		T.it("ty-sub-union-of-subsets replays: ty_sub(nil|number, nil|number)", function()
			local ac = { kind = "axiom", axiom = vocab.ax_ty_sub_refl, bindings = { A = ty_nil } } --[[: CertNode ]]
			-- ty_sub(nil, nil) doesn't chain to nil|number directly; use
			-- union-here-left/right against the SAME target union for both.
			local ac2 = { kind = "axiom", axiom = vocab.ax_ty_sub_union_here_left,
				bindings = { A = ty_nil, Rest = ty_number } } --[[: CertNode ]]
			local bc2 = { kind = "axiom", axiom = vocab.ax_ty_sub_union_here_right,
				bindings = { X = ty_nil, B = ty_number } } --[[: CertNode ]]
			local node = { kind = "rule", rule = vocab.rule_ty_sub_union_of_subsets, premises = { ac2, bc2 } } --[[: CertNode ]]
			local result, err = rl.replay(rp, node)
			T.ok(result, err)
			if result == nil then return end
			T.ok(ta.equal(result.conclusion, must_term(vocab.TySub(union_nil_number, union_nil_number))))
			T.eq(ac, ac) -- silence unused-local warning for `ac` (kept for doc symmetry)
		end)

		T.it("ty-sub-union-of-subsets rejects when both premises don't share the same C", function()
			local ac = { kind = "axiom", axiom = vocab.ax_ty_sub_refl, bindings = { A = ty_nil } } --[[: CertNode ]]
			local bc = { kind = "axiom", axiom = vocab.ax_ty_sub_refl, bindings = { A = ty_number } } --[[: CertNode ]]
			local node = { kind = "rule", rule = vocab.rule_ty_sub_union_of_subsets, premises = { ac, bc } } --[[: CertNode ]]
			local result, err = rl.replay(rp, node)
			T.eq(result, nil)
			T.ok(err)
		end)
	end)

	T.describe("assignment transfer", function()
		local s = setup()
		local vocab, rp = s.vocab, s.rp
		local ty_nil = must_term(vocab.TyOf(must_term(vocab.tag_nil())))
		local p_assign = exit({ 10 })

		T.it("assign-literal-transfer replays: x : nil at the assign point", function()
			local fact = { kind = "axiom", axiom = vocab.ax_assign_literal_facts,
				bindings = { Pa = p_assign, X = var_path, Tag = must_term(vocab.tag_nil()) } } --[[: CertNode ]]
			local node = { kind = "rule", rule = vocab.rule_assign_literal_transfer, premises = { fact } } --[[: CertNode ]]
			local result, err = rl.replay(rp, node)
			T.ok(result, err)
			if result == nil then return end
			T.ok(ta.equal(result.conclusion, must_term(vocab.HoldsAt(p_assign, var_path, ty_nil))))
		end)

		T.it("assign-literal-transfer rejects a malformed premise citation (wrong judgment shape)", function()
			-- Cite the copy-facts axiom (wrong judgment op) as if it were
			-- the literal-facts premise the rule declares.
			local fact = { kind = "axiom", axiom = vocab.ax_assign_copy_facts,
				bindings = { Pa = p_assign, X = var_path, Y = other_path } } --[[: CertNode ]]
			local node = { kind = "rule", rule = vocab.rule_assign_literal_transfer, premises = { fact } } --[[: CertNode ]]
			local result, err = rl.replay(rp, node)
			T.eq(result, nil)
			T.ok(err)
		end)

		T.it("assign-copy-transfer replays: x : nil at the assign point, copied from y", function()
			local hyp = { kind = "hypothesis", judgment = must_term(vocab.HoldsAt(p_assign, other_path, ty_nil)) } --[[: CertNode ]]
			local fact = { kind = "axiom", axiom = vocab.ax_assign_copy_facts,
				bindings = { Pa = p_assign, X = var_path, Y = other_path } } --[[: CertNode ]]
			local node = { kind = "rule", rule = vocab.rule_assign_copy_transfer, premises = { fact, hyp } } --[[: CertNode ]]
			local result, err = rl.observe(rp, node)
			T.ok(result, err)
			if result == nil then return end
			T.ok(ta.equal(result.conclusion, must_term(vocab.HoldsAt(p_assign, var_path, ty_nil))))
			T.eq(#result.open, 1)
		end)

		T.it("assign-copy-transfer rejects when the copy fact names a different point than the source fact", function()
			local hyp = { kind = "hypothesis", judgment = must_term(vocab.HoldsAt(exit({ 11 }), other_path, ty_nil)) } --[[: CertNode ]]
			local fact = { kind = "axiom", axiom = vocab.ax_assign_copy_facts,
				bindings = { Pa = p_assign, X = var_path, Y = other_path } } --[[: CertNode ]]
			local node = { kind = "rule", rule = vocab.rule_assign_copy_transfer, premises = { fact, hyp } } --[[: CertNode ]]
			local result, err = rl.observe(rp, node)
			T.eq(result, nil)
			T.ok(err)
		end)

		-- v4: assignment transfer from an annotated-call RHS (module header).
		T.it("assign-call-transfer replays: x : string|nil at the assign point", function()
			local ty_string = must_term(vocab.TyOf(must_term(vocab.tag_string())))
			local ret_ty = must_term(vocab.TyUnion(ty_string, ty_nil))
			local fact = { kind = "axiom", axiom = vocab.ax_assign_call_facts,
				bindings = { Pa = p_assign, X = var_path, T = ret_ty } } --[[: CertNode ]]
			local node = { kind = "rule", rule = vocab.rule_assign_call_transfer, premises = { fact } } --[[: CertNode ]]
			local result, err = rl.replay(rp, node)
			T.ok(result, err)
			if result == nil then return end
			T.ok(ta.equal(result.conclusion, must_term(vocab.HoldsAt(p_assign, var_path, ret_ty))))
		end)

		T.it("assign-call-transfer rejects a malformed premise citation (wrong judgment shape)", function()
			-- Cite the literal-facts axiom (wrong judgment op, and wrong sort
			-- for its third argument -- prim_tag, not ty) as if it were the
			-- call-facts premise the rule declares.
			local fact = { kind = "axiom", axiom = vocab.ax_assign_literal_facts,
				bindings = { Pa = p_assign, X = var_path, Tag = must_term(vocab.tag_nil()) } } --[[: CertNode ]]
			local node = { kind = "rule", rule = vocab.rule_assign_call_transfer, premises = { fact } } --[[: CertNode ]]
			local result, err = rl.replay(rp, node)
			T.eq(result, nil)
			T.ok(err)
		end)
	end)

	T.describe("narrow-join", function()
		local s = setup()
		local vocab, rp = s.vocab, s.rp
		local ty_nil = must_term(vocab.TyOf(must_term(vocab.tag_nil())))
		local ty_number = must_term(vocab.TyOf(must_term(vocab.tag_number())))
		local pa = exit({ 1, 0 })
		local pb = exit({ 1, 1 })
		local pj = exit({ 1 })

		T.it("replays: x : nil|number at the join point", function()
			local hyp_a = { kind = "hypothesis", judgment = must_term(vocab.HoldsAt(pa, var_path, ty_nil)) } --[[: CertNode ]]
			local hyp_b = { kind = "hypothesis", judgment = must_term(vocab.HoldsAt(pb, var_path, ty_number)) } --[[: CertNode ]]
			local fact = { kind = "axiom", axiom = vocab.ax_cf_join_facts, bindings = { Pa = pa, Pb = pb, Pj = pj } } --[[: CertNode ]]
			local node = { kind = "rule", rule = vocab.rule_narrow_join, premises = { hyp_a, hyp_b, fact } } --[[: CertNode ]]
			local result, err = rl.observe(rp, node)
			T.ok(result, err)
			if result == nil then return end
			T.ok(ta.equal(result.conclusion, must_term(vocab.HoldsAt(pj, var_path, must_term(vocab.TyUnion(ty_nil, ty_number))))))
			T.eq(#result.open, 2)
		end)

		T.it("rejects when the join fact's points don't match the two branch facts' own points", function()
			local hyp_a = { kind = "hypothesis", judgment = must_term(vocab.HoldsAt(pa, var_path, ty_nil)) } --[[: CertNode ]]
			local hyp_b = { kind = "hypothesis", judgment = must_term(vocab.HoldsAt(pb, var_path, ty_number)) } --[[: CertNode ]]
			-- cf_join names the WRONG Pb (swapped), so replay's shared Pb
			-- binding (forced by premise 2) disagrees with this axiom
			-- citation's own Pb argument.
			local fact = { kind = "axiom", axiom = vocab.ax_cf_join_facts, bindings = { Pa = pa, Pb = pa, Pj = pj } } --[[: CertNode ]]
			local node = { kind = "rule", rule = vocab.rule_narrow_join, premises = { hyp_a, hyp_b, fact } } --[[: CertNode ]]
			local result, err = rl.observe(rp, node)
			T.eq(result, nil)
			T.ok(err)
		end)
	end)

	T.describe("seq-persist", function()
		local s = setup()
		local vocab, rp = s.vocab, s.rp
		local ty_nil = must_term(vocab.TyOf(must_term(vocab.tag_nil())))
		local pa = exit({ 2 })
		local pb = exit({ 3 })

		T.it("replays: the fact at A persists to B given adjacency + non-interference", function()
			local hyp = { kind = "hypothesis", judgment = must_term(vocab.HoldsAt(pa, var_path, ty_nil)) } --[[: CertNode ]]
			local seq = { kind = "axiom", axiom = vocab.ax_stmt_seq_facts, bindings = { A = pa, B = pb } } --[[: CertNode ]]
			local pres = { kind = "axiom", axiom = vocab.ax_stmt_preserves_facts,
				bindings = { A = pa, B = pb, X = var_path } } --[[: CertNode ]]
			local node = { kind = "rule", rule = vocab.rule_seq_persist, premises = { hyp, seq, pres } } --[[: CertNode ]]
			local result, err = rl.observe(rp, node)
			T.ok(result, err)
			if result == nil then return end
			T.ok(ta.equal(result.conclusion, must_term(vocab.HoldsAt(pb, var_path, ty_nil))))
			T.eq(#result.open, 1)
		end)

		T.it("rejects when stmt_preserves names a different variable than the persisted fact", function()
			local hyp = { kind = "hypothesis", judgment = must_term(vocab.HoldsAt(pa, var_path, ty_nil)) } --[[: CertNode ]]
			local seq = { kind = "axiom", axiom = vocab.ax_stmt_seq_facts, bindings = { A = pa, B = pb } } --[[: CertNode ]]
			local pres = { kind = "axiom", axiom = vocab.ax_stmt_preserves_facts,
				bindings = { A = pa, B = pb, X = other_path } } --[[: CertNode ]]
			local node = { kind = "rule", rule = vocab.rule_seq_persist, premises = { hyp, seq, pres } } --[[: CertNode ]]
			local result, err = rl.observe(rp, node)
			T.eq(result, nil)
			T.ok(err)
		end)

		T.it("rejects when stmt_preserves names a different span than stmt_seq (the soundness point the addendum flags)", function()
			local pc = exit({ 4 })
			local hyp = { kind = "hypothesis", judgment = must_term(vocab.HoldsAt(pa, var_path, ty_nil)) } --[[: CertNode ]]
			local seq = { kind = "axiom", axiom = vocab.ax_stmt_seq_facts, bindings = { A = pa, B = pb } } --[[: CertNode ]]
			-- stmt_preserves cites a DIFFERENT span (pa,pc) than stmt_seq's
			-- own (pa,pb) — this is exactly the untrusted-prover attack the
			-- addendum's shared-(A,B)-metavariable design rules out.
			local pres = { kind = "axiom", axiom = vocab.ax_stmt_preserves_facts,
				bindings = { A = pa, B = pc, X = var_path } } --[[: CertNode ]]
			local node = { kind = "rule", rule = vocab.rule_seq_persist, premises = { hyp, seq, pres } } --[[: CertNode ]]
			local result, err = rl.observe(rp, node)
			T.eq(result, nil)
			T.ok(err)
		end)
	end)

	-- ── The milestone's acceptance gate ──────────────────────────────────────
	T.describe("loop-invariant-discharge: full certificate over a synthetic loop", function()
		local s = setup()
		local vocab, rp, ax_initial = s.vocab, s.rp, s.ax_initial
		local ty_nil = must_term(vocab.TyOf(must_term(vocab.tag_nil())))
		local ty_number = must_term(vocab.TyOf(must_term(vocab.tag_number())))
		local tinv = must_term(vocab.TyUnion(ty_nil, ty_number))

		-- Synthetic loop: `while <test> do noop(); x = x end`, preceded by
		-- `local x --: nil|number` (the hypothetically-annotated-declaration
		-- reading, matching proposal §5.2's own worked example). Addressing
		-- per this file's header note (LH/BE choices are this test's own,
		-- documented simplification — not tied to prover_addr.lua).
		local while_path = { 1 }
		local body_path = { 1, 1 } -- WHILE_BODY_INDEX = 1
		local lh = entry(body_path)
		local be = exit({ 1, 1, 0 }) -- exit of the body's first statement (`noop()`)
		local pre_loop = exit({ 0 }) -- the preceding `local x --: nil|number` decl

		--: () -> CertNode
		local function build_root()
			local h1 = { kind = "hypothesis", judgment = must_term(vocab.HoldsAt(lh, var_path, tinv)) } --[[: CertNode ]]
			local a_seq = { kind = "axiom", axiom = vocab.ax_stmt_seq_facts, bindings = { A = lh, B = be } } --[[: CertNode ]]
			local a_pres = { kind = "axiom", axiom = vocab.ax_stmt_preserves_facts,
				bindings = { A = lh, B = be, X = var_path } } --[[: CertNode ]]
			local r1 = { kind = "rule", rule = vocab.rule_seq_persist, premises = { h1, a_seq, a_pres } } --[[: CertNode ]]

			local a_copy = { kind = "axiom", axiom = vocab.ax_assign_copy_facts,
				bindings = { Pa = be, X = var_path, Y = var_path } } --[[: CertNode ]]
			local r2 = { kind = "rule", rule = vocab.rule_assign_copy_transfer, premises = { a_copy, r1 } } --[[: CertNode ]]

			local p0 = { kind = "axiom", axiom = vocab.ax_loop_facts, bindings = { LH = lh, BE = be } } --[[: CertNode ]]
			local p2 = { kind = "axiom", axiom = vocab.ax_ty_sub_refl, bindings = { A = tinv } } --[[: CertNode ]]
			local p3 = { kind = "axiom", axiom = ax_initial, bindings = { P = pre_loop, X = var_path, T = tinv } } --[[: CertNode ]]
			local p4 = { kind = "axiom", axiom = vocab.ax_ty_sub_refl, bindings = { A = tinv } } --[[: CertNode ]]

			return {
				kind = "rule", rule = vocab.rule_loop_invariant_discharge,
				premises = { p0, r2, p2, p3, p4 },
				discharge = { [1] = { h1 } },
			} --[[: CertNode ]]
		end

		T.it("ROOT-ACCEPTS via M.replay: x : nil|number holds at the loop head", function()
			local root = build_root()
			local result, err = rl.replay(rp, root)
			T.ok(result, err)
			if result == nil then return end
			T.ok(ta.equal(result.conclusion, must_term(vocab.HoldsAt(lh, var_path, tinv))))
		end)

		T.it("taint carries exactly the axioms actually cited (structural-truth + reality-boundary, all priced)", function()
			local root = build_root()
			local result, err = rl.replay(rp, root)
			T.ok(result, err)
			if result == nil then return end
			local expect = {
				[rl.citation_key("pilot-stmt-seq-facts-v1", 1)] = true,
				[rl.citation_key("pilot-stmt-preserves-facts-v1", 1)] = true,
				[rl.citation_key("pilot-assign-copy-facts-v1", 1)] = true,
				[rl.citation_key("pilot-loop-facts-v1", 1)] = true,
				[rl.citation_key("ty-sub-refl", 1)] = true,
				[rl.citation_key("pilot-initial-facts-v1", 1)] = true,
			}
			local n = 0
			for key in pairs(result.taint) do
				n = n + 1
				T.ok(expect[key], "unexpected taint key: " .. tostring(key))
			end
			T.eq(n, 6)
		end)

		T.it("rejects (undischarged hypothesis) when the discharge citation is omitted (vacuous, as a negative control)", function()
			local h1 = { kind = "hypothesis", judgment = must_term(vocab.HoldsAt(lh, var_path, tinv)) } --[[: CertNode ]]
			local a_seq = { kind = "axiom", axiom = vocab.ax_stmt_seq_facts, bindings = { A = lh, B = be } } --[[: CertNode ]]
			local a_pres = { kind = "axiom", axiom = vocab.ax_stmt_preserves_facts,
				bindings = { A = lh, B = be, X = var_path } } --[[: CertNode ]]
			local r1 = { kind = "rule", rule = vocab.rule_seq_persist, premises = { h1, a_seq, a_pres } } --[[: CertNode ]]
			local a_copy = { kind = "axiom", axiom = vocab.ax_assign_copy_facts,
				bindings = { Pa = be, X = var_path, Y = var_path } } --[[: CertNode ]]
			local r2 = { kind = "rule", rule = vocab.rule_assign_copy_transfer, premises = { a_copy, r1 } } --[[: CertNode ]]
			local p0 = { kind = "axiom", axiom = vocab.ax_loop_facts, bindings = { LH = lh, BE = be } } --[[: CertNode ]]
			local p2 = { kind = "axiom", axiom = vocab.ax_ty_sub_refl, bindings = { A = tinv } } --[[: CertNode ]]
			local p3 = { kind = "axiom", axiom = ax_initial, bindings = { P = pre_loop, X = var_path, T = tinv } } --[[: CertNode ]]
			local p4 = { kind = "axiom", axiom = vocab.ax_ty_sub_refl, bindings = { A = tinv } } --[[: CertNode ]]
			local root = {
				kind = "rule", rule = vocab.rule_loop_invariant_discharge,
				premises = { p0, r2, p2, p3, p4 },
				-- no `discharge` field at all: H1 stays open
			} --[[: CertNode ]]
			local result, err = rl.replay(rp, root)
			T.eq(result, nil)
			T.ok(err and err:find("undischarged"))
		end)

		T.it("rejects when the discharge citation names a hypothesis with a mismatched judgment", function()
			local h1 = { kind = "hypothesis", judgment = must_term(vocab.HoldsAt(lh, var_path, tinv)) } --[[: CertNode ]]
			local a_seq = { kind = "axiom", axiom = vocab.ax_stmt_seq_facts, bindings = { A = lh, B = be } } --[[: CertNode ]]
			local a_pres = { kind = "axiom", axiom = vocab.ax_stmt_preserves_facts,
				bindings = { A = lh, B = be, X = var_path } } --[[: CertNode ]]
			local r1 = { kind = "rule", rule = vocab.rule_seq_persist, premises = { h1, a_seq, a_pres } } --[[: CertNode ]]
			local a_copy = { kind = "axiom", axiom = vocab.ax_assign_copy_facts,
				bindings = { Pa = be, X = var_path, Y = var_path } } --[[: CertNode ]]
			local r2 = { kind = "rule", rule = vocab.rule_assign_copy_transfer, premises = { a_copy, r1 } } --[[: CertNode ]]
			local p0 = { kind = "axiom", axiom = vocab.ax_loop_facts, bindings = { LH = lh, BE = be } } --[[: CertNode ]]
			local p2 = { kind = "axiom", axiom = vocab.ax_ty_sub_refl, bindings = { A = tinv } } --[[: CertNode ]]
			-- Cite the initial-facts axiom with a DIFFERENT T (just ty_nil,
			-- not tinv) — T0 will bind to ty_nil, and premise 5 (ty_sub(T0,
			-- Tinv)) must then be ty_sub(ty_nil, tinv), NOT a ty-sub-refl
			-- citation over tinv.
			local p3 = { kind = "axiom", axiom = ax_initial, bindings = { P = pre_loop, X = var_path, T = ty_nil } } --[[: CertNode ]]
			local p4 = { kind = "axiom", axiom = vocab.ax_ty_sub_union_here_left,
				bindings = { A = ty_nil, Rest = ty_number } } --[[: CertNode ]]
			local root = {
				kind = "rule", rule = vocab.rule_loop_invariant_discharge,
				premises = { p0, r2, p2, p3, p4 },
				discharge = { [1] = { h1 } },
			} --[[: CertNode ]]
			-- This variant is actually VALID (T0=ty_nil, ty_sub(ty_nil,tinv)
			-- via union-here-left) — included to confirm the theory accepts
			-- an entry fact narrower than the invariant, not only an exact
			-- match. Real malformed variant: swap p4 to cite refl over
			-- ty_nil instead (mismatches the required ty_sub(T0,Tinv) shape).
			local ok_result, ok_err = rl.replay(rp, root)
			T.ok(ok_result, ok_err)

			local bad_p4 = { kind = "axiom", axiom = vocab.ax_ty_sub_refl, bindings = { A = ty_nil } } --[[: CertNode ]]
			local bad_root = {
				kind = "rule", rule = vocab.rule_loop_invariant_discharge,
				premises = { p0, r2, p2, p3, bad_p4 },
				discharge = { [1] = { h1 } },
			} --[[: CertNode ]]
			local result, err = rl.replay(rp, bad_root)
			T.eq(result, nil)
			T.ok(err)
		end)
	end)

	-- v4 mutation-class certificate: the loop body genuinely REASSIGNS the
	-- tracked variable via a call-RHS (not merely persisting it untouched,
	-- unlike every one of run 3/4's real-corpus certificates —
	-- docs/typechecker-v10-pilot-measurement.md's own reported finding this
	-- extension targets). Synthetic loop:
	--   local x --: nil|number       -- pre_loop decl at exit({0})
	--   while <test> do
	--       x = get_num()             -- body's ONLY statement; `get_num`'s
	--                                 -- declared return type is `number`
	--                                 -- (a same-file, statically/locally
	--                                 -- resolvable callee, per the brief's
	--                                 -- scope) -- assign-call-transfer,
	--                                 -- no seq-persist stitch needed (the
	--                                 -- rule is single-premise, same as
	--                                 -- assign-literal-transfer -- it never
	--                                 -- reads a prior fact).
	--   end
	-- `h1` (the assumed invariant hypothesis) is intentionally NOT built at
	-- all here: since assign-call-transfer never depends on a prior
	-- `holds_at` fact, the back-edge subderivation (premise 2, P1) never
	-- traces back to any hypothesis leaf -- discharge would be VACUOUS
	-- (exactly the `h1_live = false` reading fixpoint_prover.lua's own real
	-- code documents for every reassigning statement, literal or call
	-- alike) -- so the root certificate below OMITS the `discharge` field
	-- entirely, mirroring that module's own vacuous-discharge shape.
	T.describe("loop-invariant-discharge: mutation-class certificate with a call-RHS (v4)", function()
		local s = setup()
		local vocab, rp, ax_initial = s.vocab, s.rp, s.ax_initial
		local ty_nil = must_term(vocab.TyOf(must_term(vocab.tag_nil())))
		local ty_number = must_term(vocab.TyOf(must_term(vocab.tag_number())))
		local ty_string = must_term(vocab.TyOf(must_term(vocab.tag_string())))
		local tinv = must_term(vocab.TyUnion(ty_nil, ty_number))

		local while_path = { 1 }
		local body_path = { 1, 1 } -- WHILE_BODY_INDEX = 1
		local lh = entry(body_path)
		local be = exit({ 1, 1, 0 }) -- exit of the body's only statement (`x = get_num()`)
		local pre_loop = exit({ 0 }) -- the preceding `local x --: nil|number` decl

		--: () -> CertNode
		local function build_root()
			local a_call = { kind = "axiom", axiom = vocab.ax_assign_call_facts,
				bindings = { Pa = be, X = var_path, T = ty_number } } --[[: CertNode ]]
			local p1 = { kind = "rule", rule = vocab.rule_assign_call_transfer, premises = { a_call } } --[[: CertNode ]]

			local p0 = { kind = "axiom", axiom = vocab.ax_loop_facts, bindings = { LH = lh, BE = be } } --[[: CertNode ]]
			-- ty_sub(number, nil|number) via ty-sub-union-here-right: `number`
			-- is the union's own literal SECOND operand (Tinv = ty_union(nil,
			-- number)), matching the "ty-sub-union-here-right" theory test
			-- above verbatim (same bindings shape).
			local p2 = { kind = "axiom", axiom = vocab.ax_ty_sub_union_here_right,
				bindings = { X = ty_nil, B = ty_number } } --[[: CertNode ]]
			local p3 = { kind = "axiom", axiom = ax_initial, bindings = { P = pre_loop, X = var_path, T = tinv } } --[[: CertNode ]]
			local p4 = { kind = "axiom", axiom = vocab.ax_ty_sub_refl, bindings = { A = tinv } } --[[: CertNode ]]

			return {
				kind = "rule", rule = vocab.rule_loop_invariant_discharge,
				premises = { p0, p1, p2, p3, p4 },
				-- no `discharge` field: h1 was never introduced at all (see
				-- note above) -- vacuous, legal per the theory.
			} --[[: CertNode ]]
		end

		T.it("ROOT-ACCEPTS via M.replay: x : nil|number holds at the loop head, body reassigns via a call", function()
			local root = build_root()
			local result, err = rl.replay(rp, root)
			T.ok(result, err)
			if result == nil then return end
			T.ok(ta.equal(result.conclusion, must_term(vocab.HoldsAt(lh, var_path, tinv))))
		end)

		T.it("rejects (malformed) when the callee's declared return type is not a member of the invariant", function()
			-- `get_num`'s declared return retargeted to `string` (not a
			-- member of `nil|number`) -- no `ty_sub(string, nil|number)`
			-- citation exists (neither union-here axiom's pattern matches:
			-- `string` is neither the union's own first nor second literal
			-- operand), so the malformed root cannot even be built with a
			-- VALID p2 -- demonstrated here by citing the WRONG axiom
			-- (union-here-right over the actual members, which forces
			-- `B = ty_number`, not `ty_string`) so replay's own `match_into`
			-- rejects the mismatch between what P1 actually concluded
			-- (`Tp = ty_string`) and what P2 was cited to assert.
			local a_call = { kind = "axiom", axiom = vocab.ax_assign_call_facts,
				bindings = { Pa = be, X = var_path, T = ty_string } } --[[: CertNode ]]
			local p1 = { kind = "rule", rule = vocab.rule_assign_call_transfer, premises = { a_call } } --[[: CertNode ]]
			local p0 = { kind = "axiom", axiom = vocab.ax_loop_facts, bindings = { LH = lh, BE = be } } --[[: CertNode ]]
			local p2 = { kind = "axiom", axiom = vocab.ax_ty_sub_union_here_right,
				bindings = { X = ty_nil, B = ty_number } } --[[: CertNode ]]
			local p3 = { kind = "axiom", axiom = ax_initial, bindings = { P = pre_loop, X = var_path, T = tinv } } --[[: CertNode ]]
			local p4 = { kind = "axiom", axiom = vocab.ax_ty_sub_refl, bindings = { A = tinv } } --[[: CertNode ]]
			local bad_root = {
				kind = "rule", rule = vocab.rule_loop_invariant_discharge,
				premises = { p0, p1, p2, p3, p4 },
			} --[[: CertNode ]]
			local result, err = rl.replay(rp, bad_root)
			T.eq(result, nil)
			T.ok(err)
		end)
	end)
end)

return {}
