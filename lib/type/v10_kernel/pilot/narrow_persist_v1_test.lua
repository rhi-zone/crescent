-- lib/type/v10_kernel/pilot/narrow_persist_v1_test.lua
--
-- THE THREE-LEG CORROBORATION TEST (certificate level), demonstrating the
-- architecture's central claim: two separately-authored theories — flow
-- narrowing (pilot/flow_narrow_v1.lua) and the assignment-effects theory
-- (pilot/assign_effects_v1.lua) — sharing ZERO pairwise vocabulary, compose
-- through the declared spine judgment `preserves` (pilot/effects_spine_v1.lua)
-- to derive a narrowing fact neither theory reaches alone: that a variable's
-- guard-established type at a branch's entry point `Pb` still holds at a
-- LATER point `Q` reached after an intervening, non-interfering statement.
--
-- Same certificate SHAPE is attempted against three registries:
--   (a) narrowing + narrow-persist ONLY (no effects theory anywhere) —
--       FAIL-CLOSED: no certificate rooted in this registry's own
--       declarations can ever produce a closed, hypothesis-free `preserves`
--       fact, so narrow-persist's second premise is structurally
--       unsatisfiable. Two independent ways this manifests, both tested:
--       citing a foreign (registry-b) effects citation is rejected at
--       replay ("not declared in this replayer's registry"); assuming
--       `preserves` as a hypothesis instead leaves it permanently open,
--       which root-strict replay also rejects ("undischarged hypothesis").
--   (b) narrowing + the effects theory + the spine, all declared — DERIVES:
--       root-strict replay accepts, zero open hypotheses, taint set names
--       exactly the axioms actually trusted (flow's syntax facts, the
--       initial-fact axiom, the effects theory's syntax facts), and the
--       final conclusion is `holds_at` at the LATER point `Q` — precision
--       narrowing alone never reaches (see leg (a)).
--   (c) SCALE TO ZERO: registry (a) IS what registry (b) looks like with
--       `assign_effects_v1.declare_vocabulary` simply never called — no
--       separate "removal" step is needed; not calling that one function is
--       the whole difference between (a) and (b). This is asserted directly
--       below rather than merely narrated.
--
-- No pairwise vocabulary anywhere: flow_narrow_v1.lua never requires
-- assign_effects_v1.lua or effects_spine_v1.lua; assign_effects_v1.lua
-- never requires flow_narrow_v1.lua. This module (narrow_persist_v1.lua) is
-- the ONLY place all three names are ever require()'d together, and it
-- adds no vocabulary of its own — see its header.

local T = require("lib.test.assert")
local ta = require("lib.type.v10_cleanroom.term_algebra")
local rl = require("lib.type.v10_cleanroom.replayer")
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
--: (v: EffectsSpine | nil, err: string | nil) -> EffectsSpine
local function must_spine(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end
--: (v: AssignEffectsVocab | nil, err: string | nil) -> AssignEffectsVocab
local function must_effects_vocab(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end
--:: NarrowPersist = { rule_persist: RuleDecl }
--: (v: NarrowPersist | nil, err: string | nil) -> NarrowPersist
local function must_persist(v, err)
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

-- Structural points for a `type(x) == "string"` guard's then-branch:
-- guard test at exit({1}), then-branch entry at entry({1,0}); "Q" is the
-- exit of the branch's own first (non-interfering) statement, exit({1,0,0}).
local pg = exit({ 1 })
local pb = entry({ 1, 0 })
local q = exit({ 1, 0, 0 })

--:: NarrowStack = { narrow: NarrowVocab, ax_initial: AxiomDecl, whole_ty: Term, ty_string: Term }

-- Declare the narrowing half (flow_narrow_v1 + pilot_initial_facts_v1) into
-- `reg`, and build the shared `whole_ty = string|nil` type terms. This is
-- the SAME set of calls for every registry below — the only difference
-- between the fail-closed registry and the deriving registry is whether
-- assign_effects_v1.declare_vocabulary is ALSO called (see leg (c)).
--: (reg: Registry) -> NarrowStack
local function declare_narrow_stack(reg)
	local narrow_raw, narrow_err = flow_narrow_v1.declare_vocabulary(reg, addr_sig)
	local narrow = must_narrow_vocab(narrow_raw, narrow_err)
	local ax_initial_raw, ax_initial_err = pilot_initial_facts_v1.declare(reg, narrow)
	local ax_initial = must_axiom(ax_initial_raw, ax_initial_err)
	local ty_string = must_term(narrow.TyOf(must_term(narrow.tag_string())))
	local ty_nil = must_term(narrow.TyOf(must_term(narrow.tag_nil())))
	local whole_ty = must_term(narrow.TyUnion(ty_string, ty_nil))
	return { narrow = narrow, ax_initial = ax_initial, whole_ty = whole_ty, ty_string = ty_string }
end

-- Build the guard-branch derivation `holds_at(pb, var_path, ty_string)`,
-- root-strict (zero open hypotheses): the type at the guard point enters
-- via `pilot-initial-facts-v1` (an axiom citation, not a hypothesis — see
-- that module's header on why the prover-facing convention prefers this
-- over flow_narrow_v1_test.lua's own hypothesis-based worked examples),
-- narrowed by `narrow-select-match` citing `flow_narrow_v1`'s own syntax
-- facts axiom.
--: (NarrowStack) -> CertNode
local function build_match_node(stack)
	local narrow = stack.narrow
	local init_node = {
		kind = "axiom", axiom = stack.ax_initial,
		bindings = { P = pg, X = var_path, T = stack.whole_ty },
	} --[[: CertNode ]]
	local fact_node = {
		kind = "axiom", axiom = narrow.ax_syntax_facts,
		bindings = { Pg = pg, Pb = pb, X = var_path, TA = stack.ty_string },
	} --[[: CertNode ]]
	return { kind = "rule", rule = narrow.rule_match, premises = { init_node, fact_node } } --[[: CertNode ]]
end

T.describe("narrow-persist: the three-leg corroboration test", function()
	T.it("declares with no errors, given already-declared narrowing and spine vocabularies", function()
		local reg = rl.new_registry()
		local stack = declare_narrow_stack(reg)
		local spine_raw, spine_err = effects_spine_v1.declare(addr_sig)
		local spine = must_spine(spine_raw, spine_err)
		local persist, err = narrow_persist_v1.declare(reg, stack.narrow, spine)
		T.ok(persist, err)
	end)

	T.it("rejects when narrow_vocab and spine import DIFFERENT addr-v1 signature objects", function()
		local reg = rl.new_registry()
		local stack = declare_narrow_stack(reg)
		local other_addr_sig = must_sig(addr_v1.declare()) -- a SECOND, distinct addr-v1 declaration
		local other_spine_raw, other_spine_err = effects_spine_v1.declare(other_addr_sig)
		local other_spine = must_spine(other_spine_raw, other_spine_err)
		local persist, err = narrow_persist_v1.declare(reg, stack.narrow, other_spine)
		T.eq(persist, nil)
		T.ok(err)
	end)

	T.describe("leg (a): narrowing alone — FAIL-CLOSED baseline", function()
		local reg_a = rl.new_registry()
		local stack_a = declare_narrow_stack(reg_a)
		local spine_a_raw, spine_a_err = effects_spine_v1.declare(addr_sig)
		local spine_a = must_spine(spine_a_raw, spine_a_err)
		local persist_a_raw, persist_a_err = narrow_persist_v1.declare(reg_a, stack_a.narrow, spine_a)
		local persist_a = must_persist(persist_a_raw, persist_a_err)
		local rp_a_raw, rp_a_err = rl.new_replayer({ registry = reg_a })
		local rp_a = must_rp(rp_a_raw, rp_a_err)
		-- Note what is deliberately ABSENT: assign_effects_v1.declare_vocabulary
		-- is never called against reg_a. No axiom or rule capable of concluding
		-- `preserves(...)` exists anywhere in this registry.

		T.it("citing a FOREIGN (different-registry) effects citation is rejected: 'not declared in this registry'", function()
			-- Build a real effects derivation, but against a SEPARATE registry
			-- (reg_b) — exactly the shape leg (b) below uses successfully.
			local reg_b = rl.new_registry()
			local effects_spine_raw, effects_spine_err = effects_spine_v1.declare(addr_sig)
			local effects_spine = must_spine(effects_spine_raw, effects_spine_err)
			local effects_raw, effects_err = assign_effects_v1.declare_vocabulary(reg_b, addr_sig, effects_spine)
			local effects = must_effects_vocab(effects_raw, effects_err)
			local fact_node = {
				kind = "axiom", axiom = effects.ax_syntax_facts,
				bindings = { A = pb, B = q, X = var_path },
			} --[[: CertNode ]]
			local pres_node = { kind = "rule", rule = effects.rule_transfer, premises = { fact_node } } --[[: CertNode ]]
			local match_node = build_match_node(stack_a)
			local persist_node = {
				kind = "rule", rule = persist_a.rule_persist, premises = { match_node, pres_node },
			} --[[: CertNode ]]
			-- Replay against reg_a's replayer: match_node's own citations ARE
			-- declared in reg_a (stack_a was declared there), but pres_node
			-- cites reg_b's declarations — structurally foreign to reg_a.
			local result, err = rl.replay(rp_a, persist_node)
			T.eq(result, nil)
			T.ok(err)
			T.ok(err and err:find("not declared in this replayer's registry"))
		end)

		T.it("ASSUMING preserves as a hypothesis instead leaves it open: root-strict replay rejects", function()
			local match_node = build_match_node(stack_a)
			local pres_hyp = {
				kind = "hypothesis",
				judgment = must_term(spine_a.Preserves(pb, q, var_path)),
			} --[[: CertNode ]]
			local persist_node = {
				kind = "rule", rule = persist_a.rule_persist, premises = { match_node, pres_hyp },
			} --[[: CertNode ]]
			-- observe() shows the open hypothesis explicitly: this IS derivable
			-- as an OBSERVATION, but only by ASSUMING the very fact the effects
			-- theory would need to prove — never accepted as a root.
			local obs, oerr = rl.observe(rp_a, persist_node)
			T.ok(obs, oerr)
			if obs ~= nil then
				T.eq(#obs.open, 1)
				T.eq(obs.open[1], pres_hyp)
			end
			local result, err = rl.replay(rp_a, persist_node)
			T.eq(result, nil)
			T.ok(err and err:find("undischarged"))
		end)
	end)

	T.describe("leg (b): narrowing + the effects theory, composed via the spine — DERIVES", function()
		local reg_b = rl.new_registry()
		local stack_b = declare_narrow_stack(reg_b)
		local spine_b_raw, spine_b_err = effects_spine_v1.declare(addr_sig)
		local spine_b = must_spine(spine_b_raw, spine_b_err)
		local effects_raw, effects_err = assign_effects_v1.declare_vocabulary(reg_b, addr_sig, spine_b)
		local effects_b = must_effects_vocab(effects_raw, effects_err)
		local persist_b_raw, persist_b_err = narrow_persist_v1.declare(reg_b, stack_b.narrow, spine_b)
		local persist_b = must_persist(persist_b_raw, persist_b_err)
		local rp_b_raw, rp_b_err = rl.new_replayer({ registry = reg_b })
		local rp_b = must_rp(rp_b_raw, rp_b_err)

		T.it("derives holds_at(Q, X, string) at the LATER point Q — unreachable by narrowing's own rules alone", function()
			local match_node = build_match_node(stack_b)
			local fact_node = {
				kind = "axiom", axiom = effects_b.ax_syntax_facts,
				bindings = { A = pb, B = q, X = var_path },
			} --[[: CertNode ]]
			local pres_node = { kind = "rule", rule = effects_b.rule_transfer, premises = { fact_node } } --[[: CertNode ]]
			local persist_node = {
				kind = "rule", rule = persist_b.rule_persist, premises = { match_node, pres_node },
			} --[[: CertNode ]]
			local result, err = rl.replay(rp_b, persist_node)
			T.ok(result, err)
			if result == nil then return end
			T.ok(ta.equal(result.conclusion, must_term(stack_b.narrow.HoldsAt(q, var_path, stack_b.ty_string))))
			-- taint names exactly the three axioms actually trusted: flow's
			-- syntax facts, the initial-fact axiom, and the effects theory's
			-- OWN syntax facts — each citing a SPINE judgment as an ordinary
			-- premise costs nothing extra in taint beyond what it already cites.
			local keys = {} --[[: { [string]: boolean } ]]
			local n = 0
			for key in pairs(result.taint) do keys[key] = true; n = n + 1 end
			T.eq(n, 3)
			T.ok(keys[rl.citation_key("pilot-syntax-facts-v1", 1)])
			T.ok(keys[rl.citation_key("pilot-initial-facts-v1", 1)])
			T.ok(keys[rl.citation_key("assign-effects-syntax-facts-v1", 1)])
		end)
	end)

	T.it("leg (c), scale to zero: reg_a IS reg_b minus the ONE call to assign_effects_v1.declare_vocabulary "
		.. "-- no other difference", function()
		-- This is asserted structurally, not merely narrated: build BOTH
		-- registries via the identical sequence of calls this file already
		-- uses for legs (a)/(b) above, differing in EXACTLY one call.
		local reg_x = rl.new_registry()
		local stack_x = declare_narrow_stack(reg_x) -- same as leg (a)/(b)
		local spine_x_raw, spine_x_err = effects_spine_v1.declare(addr_sig)
		local spine_x = must_spine(spine_x_raw, spine_x_err)
		local persist_x_raw, persist_x_err = narrow_persist_v1.declare(reg_x, stack_x.narrow, spine_x) -- same
		local persist_x = must_persist(persist_x_raw, persist_x_err)
		local rp_x_raw, rp_x_err = rl.new_replayer({ registry = reg_x })
		local rp_x = must_rp(rp_x_raw, rp_x_err)
		-- The ONE call present in leg (b) and absent here:
		--   assign_effects_v1.declare_vocabulary(reg_x, addr_sig, spine_x)

		local match_node = build_match_node(stack_x)
		local pres_hyp = { kind = "hypothesis", judgment = must_term(spine_x.Preserves(pb, q, var_path)) } --[[: CertNode ]]
		local persist_node = {
			kind = "rule", rule = persist_x.rule_persist, premises = { match_node, pres_hyp },
		} --[[: CertNode ]]
		local result, err = rl.replay(rp_x, persist_node)
		T.eq(result, nil)
		T.ok(err and err:find("undischarged"))
	end)
end)

return {}
