-- lib/type/v10_kernel/pilot/engine_test.lua
--
-- Engine build (corroboration line, iteration 3). Two independent things
-- are exercised here, deliberately kept apart:
--
-- 1. "Reproduces the flagship composition": drives the SAME narrow-persist
--    three-leg scenario `narrow_persist_v1_test.lua` proves at the
--    certificate level (leg (b), "DERIVES") through the generic engine
--    instead of a hand-built CertNode — seed two base facts, register the
--    existing (unmodified) rule objects from flow_narrow_v1/
--    assign_effects_v1/narrow_persist_v1, run to fixpoint, export the
--    derived fact via `to_certificate`, and replay it against the REAL
--    kernel replayer. This is the soundness-relevant check: the engine's
--    own provenance must produce a certificate the untrusted kernel
--    independently accepts, root-strict, with the identical taint set the
--    hand-built certificate produces — proving `to_certificate` is not a
--    trusted shortcut, just bookkeeping the replayer re-verifies anyway.
-- 2. A standalone exercise of the stratified-negation mechanism (engine.lua
--    §"Stratified negation"), over a tiny made-up signature local to this
--    file — NOT cited by any ported theory yet (recorded honestly in the
--    corroboration report as built-but-not-yet-load-bearing).

local T = require("lib.test.assert")
local ta = require("lib.type.v10_cleanroom.term_algebra")
local rl = require("lib.type.v10_cleanroom.replayer")
local engine = require("lib.type.v10_kernel.pilot.engine")
local addr_v1 = require("lib.type.v10_kernel.pilot.addr_v1")
local flow_narrow_v1 = require("lib.type.v10_kernel.pilot.flow_narrow_v1")
local pilot_initial_facts_v1 = require("lib.type.v10_kernel.pilot.pilot_initial_facts_v1")
local effects_spine_v1 = require("lib.type.v10_kernel.pilot.effects_spine_v1")
local assign_effects_v1 = require("lib.type.v10_kernel.pilot.assign_effects_v1")
local narrow_persist_v1 = require("lib.type.v10_kernel.pilot.narrow_persist_v1")

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
local function must_narrow_vocab(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end
--: (v: AxiomDecl | nil, err: string | nil) -> AxiomDecl
local function must_axiom(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end
--: (v: unknown, err: string | nil) -> unknown
local function must_spine(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end
--: (v: AssignEffectsVocab | nil, err: string | nil) -> AssignEffectsVocab
local function must_effects_vocab(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end
--: (v: NarrowPersist | nil, err: string | nil) -> NarrowPersist
local function must_persist(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end
--: (v: RuleDecl | nil, err: string | nil) -> RuleDecl
local function must_rule(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end
--: (v: Replayer | nil, err: string | nil) -> Replayer
local function must_rp(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end
--: (v: CertNode | nil, err: string | nil) -> CertNode
local function must_node(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end
--: (v: Fact | nil, err: string | nil) -> Fact
local function must_fact(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

local addr_sig_raw, addr_sig_err = addr_v1.declare()
local addr_sig = must_sig(addr_sig_raw, addr_sig_err)
local addr_ops = addr_sig.ops

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
--: () -> Term
local function fid()
	return must_term(ta.build(addr_ops.file_id_of, {
		must_term(ta.build(addr_ops.bs_cons, {
			must_term(ta.build(addr_ops.b1, {})), must_term(ta.build(addr_ops.bs_nil, {})),
		})),
	}))
end
--: (indices: integer[]) -> Term
local function entry(indices) return must_term(ta.build(addr_ops.entry_of, { fid(), path(indices) })) end
--: (indices: integer[]) -> Term
local function exit(indices) return must_term(ta.build(addr_ops.exit_of, { fid(), path(indices) })) end

local var_path = path({ 5 })
local pg = exit({ 1 })
local pb = entry({ 1, 0 })
local q = exit({ 1, 0, 0 })

T.describe("engine: reproduces the narrow-persist flagship composition (leg (b), engine-driven)", function()
	T.it("seeds + rules + run() derive the same holds_at(Q,X,string), replaying root-strict with matching taint", function()
		local reg = rl.new_registry()

		local narrow_raw, narrow_err = flow_narrow_v1.declare_vocabulary(reg, addr_sig)
		local narrow = must_narrow_vocab(narrow_raw, narrow_err)
		local ax_initial_raw, ax_initial_err = pilot_initial_facts_v1.declare(reg, narrow)
		local ax_initial = must_axiom(ax_initial_raw, ax_initial_err)
		local spine_raw, spine_err = effects_spine_v1.declare(addr_sig)
		local spine = must_spine(spine_raw, spine_err)
		local effects_raw, effects_err = assign_effects_v1.declare_vocabulary(reg, addr_sig, spine)
		local effects = must_effects_vocab(effects_raw, effects_err)
		local persist_raw, persist_err = narrow_persist_v1.declare(reg, narrow, spine)
		local persist = must_persist(persist_raw, persist_err)

		local ty_string = must_term(narrow.TyOf(must_term(narrow.tag_string())))
		local ty_nil = must_term(narrow.TyOf(must_term(narrow.tag_nil())))
		local whole_ty = must_term(narrow.TyUnion(ty_string, ty_nil))

		local store = engine.new_store()

		-- Base facts: exactly the two axiom citations the hand-built
		-- certificate in narrow_persist_v1_test.lua's leg (b) uses (plus the
		-- guard-syntax-fact citation), seeded through the engine's ONE
		-- reality-boundary entry point instead of assembled by hand.
		local f_initial, e1 = engine.seed(store, ax_initial, { P = pg, X = var_path, T = whole_ty })
		T.ok(f_initial, e1)
		local f_guard, e2 = engine.seed(store, narrow.ax_syntax_facts,
			{ Pg = pg, Pb = pb, X = var_path, TA = ty_string })
		T.ok(f_guard, e2)
		local f_stmt, e3 = engine.seed(store, effects.ax_syntax_facts, { A = pb, B = q, X = var_path })
		T.ok(f_stmt, e3)

		local r1, re1 = engine.add_rule(store, narrow.rule_match)
		T.ok(r1, re1)
		local r2, re2 = engine.add_rule(store, effects.rule_transfer)
		T.ok(r2, re2)
		local r3, re3 = engine.add_rule(store, persist.rule_persist)
		T.ok(r3, re3)

		local n, run_err = engine.run(store)
		T.ok(n, run_err)
		-- narrow-select-match fires once (holds_at at Pb), preserves-transfer
		-- fires once (preserves(Pb,Q,X)), narrow-persist fires once
		-- (holds_at at Q) — exactly 3 new derived facts, no more (semi-naive
		-- termination, not an approximate/overshooting fixpoint).
		T.eq(n, 3)

		local goal = must_term(narrow.HoldsAt(q, var_path, ty_string))
		local derived = engine.facts_of(store, "holds_at")
		local found = nil --[[: Fact | nil ]]
		for i = 1, #derived do
			if ta.equal(derived[i].term, goal) then found = derived[i] end
		end
		T.ok(found, "engine did not derive holds_at(Q, X, string)")
		if not found then return end

		local node, cert_err = engine.to_certificate(found)
		T.ok(node, cert_err)
		if not node then return end

		local rp_raw, rp_err = rl.new_replayer({ registry = reg })
		T.ok(rp_raw, rp_err)
		if not rp_raw then return end
		local rp = rp_raw --[[: Replayer ]]

		local result, replay_err = rl.replay(rp, node)
		T.ok(result, replay_err)
		if not result then return end
		T.ok(ta.equal(result.conclusion, goal))

		-- Same three axioms taint the engine-derived certificate as the
		-- hand-built one in narrow_persist_v1_test.lua's leg (b) — the
		-- engine adds no additional trust, only bookkeeping.
		local keys = {} --[[: { [string]: boolean } ]]
		local count = 0
		for key in pairs(result.taint) do keys[key] = true; count = count + 1 end
		T.eq(count, 3)
		T.ok(keys[rl.citation_key("pilot-syntax-facts-v1", 1)])
		T.ok(keys[rl.citation_key("pilot-initial-facts-v1", 1)])
		T.ok(keys[rl.citation_key("assign-effects-syntax-facts-v1", 1)])
	end)
end)

-- ── Stratified negation, standalone exercise ─────────────────────────────
--
-- A tiny made-up signature: `base(nat)` (facts) and `blocked(nat)` (facts
-- that veto a base value), with one negative rule `unblocked(X) :-
-- base(X), NOT blocked(X)`. Exercises the mechanism end-to-end (seed,
-- negated premise, run, to_certificate does NOT need to touch this rule
-- since it never fires from certificate-emitting provers yet — this test
-- checks engine-internal fact derivation only, not kernel replay, since no
-- kernel rule/axiom object models `unblocked` — a from-scratch registry
-- declares one for exactly this test).

T.describe("engine: stratified negation (standalone mechanism exercise, not yet theory-load-bearing)", function()
	T.it("`unblocked(X) :- base(X), NOT blocked(X)` fires only for the base value with no matching blocked fact", function()
		local sig, sig_err = ta.declare_signature({
			name = "engine-negation-test-v1", version = 1,
			sorts = { "nat", "judgment" },
			ops = {
				z = { result = "nat", args = {} },
				s = { result = "nat", args = { { sort = "nat" } } },
				base = { result = "judgment", args = { { sort = "nat" } } },
				blocked = { result = "judgment", args = { { sort = "nat" } } },
				unblocked = { result = "judgment", args = { { sort = "nat" } } },
			},
		})
		T.ok(sig, sig_err)
		if not sig then return end
		local ops = sig.ops
		local n0 = must_term(ta.build(ops.z, {}))
		local n1 = must_term(ta.build(ops.s, { n0 }))

		local reg = rl.new_registry()
		local ax_base, axb_err = rl.declare_axiom(reg, {
			name = "base-facts", version = 1, pattern = must_term(ta.build(ops.base, { ta.meta("X", sig.sorts.nat) })),
		})
		T.ok(ax_base, axb_err)
		local ax_blocked, axk_err = rl.declare_axiom(reg, {
			name = "blocked-facts", version = 1,
			pattern = must_term(ta.build(ops.blocked, { ta.meta("X", sig.sorts.nat) })),
		})
		T.ok(ax_blocked, axk_err)
		local x = ta.meta("X", sig.sorts.nat)
		local rule_unblocked, ru_err = rl.declare_rule(reg, {
			name = "unblocked-rule", version = 1,
			premises = { must_term(ta.build(ops.base, { x })), must_term(ta.build(ops.blocked, { x })) },
			conclusion = must_term(ta.build(ops.unblocked, { x })),
		})
		T.ok(rule_unblocked, ru_err)
		if not ax_base or not ax_blocked or not rule_unblocked then return end

		local store = engine.new_store()
		engine.seed(store, ax_base, { X = n0 })
		engine.seed(store, ax_base, { X = n1 })
		engine.seed(store, ax_blocked, { X = n1 }) -- n1 is blocked; n0 is not
		local er, er_err = engine.add_rule(store, rule_unblocked, { [1] = true }) -- premise index 1 (0-based) = blocked, negated
		T.ok(er, er_err)

		local n, run_err = engine.run(store)
		T.ok(n, run_err)
		T.eq(n, 1) -- only unblocked(n0)

		local unblocked_facts = engine.facts_of(store, "unblocked")
		T.eq(#unblocked_facts, 1)
		T.ok(ta.equal(unblocked_facts[1].term, must_term(ta.build(ops.unblocked, { n0 }))))
	end)
end)
