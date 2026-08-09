-- lib/type/v10_kernel/pilot/assign_effects_v1.lua
--
-- Corroboration proof-of-concept, spine step 2 — the EFFECTS THEORY: rules
-- against the effects spine (pilot/effects_spine_v1.lua) that derive
-- `preserves` judgments from real crescent source. Declared over the
-- canonical v10 core (lib/type/v10_cleanroom/, per the owner-ratified canon
-- swap), importing `point`/`path` from addr-v1 directly (NOT from the
-- spine signature, and NOT from narrowing's own signature — this theory
-- never sees narrow-pilot-v1 at all; see effects_spine_v1.lua's header for
-- why that separation is the whole point).
--
-- fable-delegation-tier throughout (per the core design's pilot-execution
-- delegation note): every choice here is a delegated-execution decision,
-- re-openable on challenge, not an owner ratification.
--
-- ── This theory's OWN vocabulary: one reality-boundary judgment ────────────
--
-- `stmt_preserves_fact(from: point, to: point, x: path) : judgment` — "the
-- parser saw a single statement spanning `from`..`to` that does not write
-- to `x`." This is THIS THEORY's own private syntax-fact vocabulary
-- (analogous to flow_narrow_v1's `guard_selects` / fixpoint_v1's
-- `stmt_preserves` before this corroboration proof-of-concept split it out
-- of the jointly-owned signature) — narrowing never sees this operator,
-- only the spine's `preserves` conclusion the rule below produces from it.
-- Same reality-boundary idiom as every other pilot theory: asserted ONLY
-- via a single schematic axiom (fully-metavariable pattern; every concrete
-- instance is an untrusted-prover axiom CITATION, never a hypothesis),
-- tagging every derivation using it with that axiom key. "Never mind
-- (structurally verified) it does not write to x" is a NEGATIVE fact about
-- the statement — per the design brief's working default ("negation
-- internalized in the producing theory, spine stays positive"), that
-- negative check happens entirely on the PROVER side (pilot/
-- prover_effects.lua), structurally verifying non-interference from the
-- real AST before ever citing this axiom; nothing kernel- or rule-side ever
-- reasons about negation. The spine's own `preserves` judgment this
-- theory's rules conclude stays strictly positive.
--
-- ── Two rules: one grounding (axiom-tainted), one pure ─────────────────────
--
--   preserves-transfer : stmt_preserves_fact(From,To,X) |- preserves(From,To,X)
--   preserves-trans     : preserves(A,B,X), preserves(B,C,X) |- preserves(A,C,X)
--
-- `preserves-transfer`'s conclusion cites the SPINE's own `preserves` op
-- (effects_spine_v1.lua, injected as `spine`, never re-declared here) — the
-- one place this theory's vocabulary crosses into the spine's, exactly the
-- shape the corroboration note prescribes ("all cross-theory facts are
-- judgments in layer (spine) vocabulary"). `preserves-trans` is a genuine
-- RULE, not an axiom wrapper: transitivity of "survives unchanged from A to
-- B, and from B to C, therefore from A to C" needs no reality-boundary
-- trust at all — both its premises and its conclusion are already spine
-- judgments, so no additional axiom taints a chain built through it. This
-- is the "rules against that vocabulary" content the brief asks for beyond
-- pure axiom pass-through: a real, non-trivial (if small) inference over
-- the spine's own shape, usable by ANY future producer of `preserves`
-- facts, not just this theory's own `preserves-transfer`.
--
-- No side condition was needed for either rule — HALT was not triggered.

local ta = require("lib.type.v10_cleanroom.term_algebra")
local replayer = require("lib.type.v10_cleanroom.replayer")

local M = {}

--:: AssignEffectsVocab = {
--::   signature: Signature,
--::   StmtPreservesFact: (from: Term, to: Term, x: Term) -> (Term | nil, string | nil),
--::   Preserves: (from: Term, to: Term, x: Term) -> (Term | nil, string | nil),
--::   ax_syntax_facts: AxiomDecl,
--::   rule_transfer: RuleDecl,
--::   rule_trans: RuleDecl,
--:: }

-- Declare the effects theory (`assign-effects-v1` v1) into the given
-- registry, importing `point`/`path` from an already-declared addr-v1
-- signature, and citing (never re-declaring) an already-declared effects
-- spine's `preserves` op. Caps-clean: `registry`/`addr_sig`/`spine` are all
-- injected, never reached for ambiently. Call once per registry
-- ((name, version) unique per registry, F11).
-- `addr_sig`/`spine` are typed `unknown` and narrowed by hand: the same
-- typechecker gotcha every other pilot module in this directory documents
-- (a `type(x) ~= "table"` guard on an already-record-typed parameter widens
-- the else branch back to `unknown`), so the runtime guard runs on
-- `unknown` and a checked cast restores the shape.
--: (registry: Registry, addr_sig: unknown, spine: unknown) -> (AssignEffectsVocab | nil, string | nil)
function M.declare_vocabulary(registry, addr_sig, spine)
	if type(addr_sig) ~= "table" then
		return nil, "declare_vocabulary: addr_sig (a declared addr-v1 signature) is required"
	end
	local sig_in = addr_sig --[[: Signature ]]
	local addr_sorts = sig_in.sorts
	if type(addr_sorts) ~= "table" or not addr_sorts.point or not addr_sorts.path then
		return nil, "declare_vocabulary: addr_sig must declare point and path sorts"
	end
	if type(spine) ~= "table" then
		return nil, "declare_vocabulary: spine (a declared effects_spine_v1 spine) is required"
	end
	local spine_in = spine --[[: { signature: Signature, Preserves: (from: Term, to: Term, x: Term) -> (Term | nil, string | nil) } ]]
	if type(spine_in.signature) ~= "table" or type(spine_in.Preserves) ~= "function" then
		return nil, "declare_vocabulary: spine must be effects_spine_v1.declare's return value"
	end

	local sig, sig_err = ta.declare_signature({
		name = "assign-effects-v1",
		version = 1,
		sorts = { "judgment" },
		imports = { { from = sig_in, sorts = { "point", "path" } } },
		ops = {
			stmt_preserves_fact = {
				result = "judgment",
				args = { { sort = "point" }, { sort = "point" }, { sort = "path" } },
			},
		},
	})
	if not sig then return nil, sig_err end
	local ops = sig.ops

	--: (from: Term, to: Term, x: Term) -> (Term | nil, string | nil)
	local function StmtPreservesFact(from, to, x) return ta.build(ops.stmt_preserves_fact, { from, to, x }) end
	local Preserves = spine_in.Preserves

	local point_sort, path_sort = sig.sorts.point, sig.sorts.path

	local a = ta.meta("A", point_sort)
	local b = ta.meta("B", point_sort)
	local c = ta.meta("C", point_sort)
	local x = ta.meta("X", path_sort)
	if not a or not b or not c or not x then
		return nil, "declare_vocabulary: failed to build shared metavariables"
	end

	local fact_pat = StmtPreservesFact(a, b, x)
	if not fact_pat then return nil, "declare_vocabulary: failed to build stmt_preserves_fact pattern" end
	local ax_syntax_facts, ax_err = replayer.declare_axiom(registry, {
		name = "assign-effects-syntax-facts-v1", version = 1,
		pattern = fact_pat,
	})
	if not ax_syntax_facts then return nil, ax_err end

	local pres_ab = Preserves(a, b, x)
	if not pres_ab then return nil, "declare_vocabulary: failed to build preserves-transfer conclusion" end
	local rule_transfer, tr_err = replayer.declare_rule(registry, {
		name = "preserves-transfer", version = 1,
		premises = { fact_pat },
		conclusion = pres_ab,
	})
	if not rule_transfer then return nil, tr_err end

	local pres_ab2 = Preserves(a, b, x)
	local pres_bc = Preserves(b, c, x)
	local pres_ac = Preserves(a, c, x)
	if not pres_ab2 or not pres_bc or not pres_ac then
		return nil, "declare_vocabulary: failed to build preserves-trans patterns"
	end
	local rule_trans, tn_err = replayer.declare_rule(registry, {
		name = "preserves-trans", version = 1,
		premises = { pres_ab2, pres_bc },
		conclusion = pres_ac,
	})
	if not rule_trans then return nil, tn_err end

	return {
		signature = sig,
		StmtPreservesFact = StmtPreservesFact,
		Preserves = Preserves,
		ax_syntax_facts = ax_syntax_facts,
		rule_transfer = rule_transfer,
		rule_trans = rule_trans,
	}
end

return M
