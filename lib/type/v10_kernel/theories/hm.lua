-- lib/type/v10_kernel/theories/hm.lua
-- Shared Hindley-Milner judgment vocabulary for the ported Algorithm W /
-- Algorithm J theory entries (docs/decisions/typechecker-v10-core-design.md,
-- docs/decisions/typechecker-v10-core-charter.md). Cleanroom-built over
-- lib/type/v10_kernel/term_algebra/ and lib/type/v10_kernel/replayer/ only;
-- does not read or depend on the retired lib/type/v10_kernel/kernel.lua or
-- lib/type/v10_kernel/registry.lua.
--
-- This is the ONE vocabulary both algorithm_w.lua and algorithm_j.lua build
-- against — mirroring the retired prototype's "Algorithm J reuses Algorithm
-- W's rule schemas verbatim" genericity finding, now even more directly: in
-- the new core there is no separate per-theory registry to reuse INTO —
-- rule/axiom identity is the declared object itself (replay cites the
-- object directly, no name lookup), so "sharing a rule" is simply "both
-- theories hold a reference to the same declared object." A caller builds
-- one vocabulary per chosen term_algebra tier (`k`, from
-- `term_algebra.new({tier=...})`) and hands it to BOTH `algorithm_w.certify`
-- and `algorithm_j.certify` — rule/axiom patterns are tier-specific term
-- data (built via that tier's own `build`/`build_meta`), so a vocabulary is
-- always scoped to one tier instance, never shared across tiers.
--
-- Judgment grammar (`hm-judgment` signature):
--   sorts: ty (a Hindley-Milner monotype), jud (a typing judgment)
--   int_ty, bool_ty  : ty                    -- the two base types the ported
--                                                theories' test terms use
--                                                (the retired prototype's
--                                                `con(name)` took an
--                                                arbitrary string; term_algebra
--                                                operators carry no such
--                                                payload field, so each
--                                                concrete base type is its
--                                                own declared nullary
--                                                operator instead — see
--                                                README.md's port-notes
--                                                section for this as a named
--                                                finding, not a silent
--                                                narrowing)
--   arrow_ty(ty, ty) : ty                    -- function type, non-binding
--   has_type(ty)     : jud                   -- "this occurrence has type T"
--
-- Rule/axiom design (the actual port of what W-Lit/W-Var/W-Abs/W-App/W-Let
-- meant — see algorithm_w.lua's header for the full correspondence and the
-- two structural findings this forced):
--   hm-ax-lit : axiom, schematic pattern has_type(meta A) — a literal's
--     type is supplied directly via citation bindings (replaces W-Lit).
--   hm-abs    : rule, premises { has_type(meta A) [the param hypothesis,
--     cited AS a premise — see finding 1], has_type(meta B) [body] },
--     conclusion has_type(arrow_ty(A,B)), discharge slot (premise=1,
--     pattern=has_type(meta A)) (replaces W-Abs; W-Var's "assumes" for a
--     parameter reference is now just re-citing the same hypothesis node —
--     see finding 2, no rule needed).
--   hm-app    : rule, premises { has_type(arrow_ty(meta A, meta B)) [fn],
--     has_type(meta A) [arg, same A — non-linear metavariable] },
--     conclusion has_type(meta B), no discharge (replaces W-App; the
--     argument/domain type-consistency check that the retired prototype's
--     PRODUCER performed via `unify` is now ALSO independently verified by
--     the replayer itself, structurally, via non-linear pattern matching —
--     see finding 3).
--   hm-let    : rule, premises { has_type(meta A) [value], has_type(meta A)
--     [the let-bound hypothesis, same A, cited as a premise — same reason as
--     hm-abs's finding 1], has_type(meta B) [body] }, conclusion
--     has_type(meta B), discharge slot (premise=2, pattern=has_type(meta A))
--     (replaces W-Let).
--
-- Finding 1 (why the param/let-bound hypothesis must be an EXPLICIT rule
-- premise, not merely embedded wherever a var occurrence references it):
-- a rule's conclusion and discharge-slot patterns may only use metavariables
-- bound by MATCHING the rule's OWN declared premise patterns against the
-- actual premise results (docs/decisions/typechecker-v10-core-design.md,
-- "Schematic instantiation" + "Discharge: bottom-up open-hypothesis sets").
-- The retired prototype's W-Abs/W-Let recorded a fresh hypothesis's type
-- OUT OF BAND (Hypothesis.payload, fully opaque to kernel.lua) and referenced
-- it structurally only via `assumes`/`discharges` id lists with no pattern
-- check at all. The new core has no such out-of-band channel — a discharge
-- slot's pattern is checked structurally against the SAME shared bindings
-- environment every premise match contributes to — so the hypothesis's own
-- type must be exposed to the rule's bindings via an actual premise citing
-- it, not merely assumed to be "whatever the producer happened to record."
-- This is the standard natural-deduction shape (the hypothesis you introduce
-- and later discharge is itself a premise of the intro rule), not a
-- workaround.
--
-- Finding 2 (why W-Var needed no ported rule schema at all): a variable
-- reference's derivation, in the retired prototype, was a 0-premise node
-- whose ENTIRE content was "cite hypothesis H" (`assumes = {hyp_id}`) with a
-- conclusion payload that merely restated H's own type. Under the new core,
-- the hypothesis LEAF node's own conclusion (computed by replay) already IS
-- exactly that judgment — DAG-sharing (re-citing the same hypothesis-node
-- object wherever the bound name is referenced) is the direct, zero-overhead
-- port of "assumes," with no wrapping rule needed.
--
-- Finding 3 (a genuine strengthening, not a loss): the retired prototype's
-- kernel never checked that an App node's conclusion was actually consistent
-- with its premises' conclusions (`conclusion` was fully opaque structurally
-- to kernel.lua) — that consistency was entirely the untrusted producer's
-- own `unify` responsibility, unverified by the trust core. Because the new
-- core's rule replay COMPUTES conclusions from premises via pattern
-- matching (never trusts a producer-supplied one), hm-app's shared
-- metavariable A structurally FORCES the argument's actual type to equal
-- the function's actual domain type, or replay rejects — the "can't lie
-- about content" property named in
-- docs/decisions/typechecker-v10-core-design.md now applies to exactly the
-- kind of check the old kernel structurally could not perform.

local term_algebra = require("lib.type.v10_kernel.term_algebra")
local replayer = require("lib.type.v10_kernel.replayer")

local M = {}

--:: TermAlgebra = unknown
--:: Vocab = { signature: unknown, int_ty: unknown, bool_ty: unknown, H: (unknown) -> (unknown|nil,string|nil), Arrow: (unknown,unknown) -> (unknown|nil,string|nil), ax_lit: unknown, rule_abs: unknown, rule_app: unknown, rule_let: unknown }

-- Declare the hm-judgment signature and its rule/axiom vocabulary against a
-- specific term_algebra tier instance `k`. Call once per tier; share the
-- result between algorithm_w.certify and algorithm_j.certify (per the
-- header's genericity note).
--: (k: unknown) -> (Vocab | nil, string | nil)
function M.declare_vocabulary(k)
	if type(k) ~= "table" then return nil, "declare_vocabulary: k (a term_algebra instance) is required" end
	local kt = k --[[: { [string]: unknown } ]]
	if type(kt.build) ~= "function" or type(kt.build_meta) ~= "function" then
		return nil, "declare_vocabulary: k must be a term_algebra tier instance"
	end
	local kk = k --[[: { build: (unknown, unknown) -> (unknown | nil, string | nil), build_meta: (string, unknown) -> (unknown | nil, string | nil) } ]]
	local build = kk.build
	local build_meta = kk.build_meta

	local sig, sig_err = term_algebra.declare_signature({
		name = "hm-judgment",
		version = 1,
		sorts = { "ty", "jud" },
		ops = {
			int_ty = { result = "ty", args = {} },
			bool_ty = { result = "ty", args = {} },
			arrow_ty = { result = "ty", args = { { sort = "ty" }, { sort = "ty" } } },
			has_type = { result = "jud", args = { { sort = "ty" } } },
		},
	})
	if not sig then return nil, sig_err end
	local ops = sig.ops

	--: (t: unknown) -> (unknown | nil, string | nil)
	local function H(t) return build(ops.has_type, { t }) end
	--: (a: unknown, b: unknown) -> (unknown | nil, string | nil)
	local function Arrow(a, b) return build(ops.arrow_ty, { a, b }) end
	--: (id: string) -> (unknown | nil, string | nil)
	local function meta_ty(id) return build_meta(id, sig.sorts.ty) end

	local int_ty = build(ops.int_ty, {})
	local bool_ty = build(ops.bool_ty, {})
	if not int_ty or not bool_ty then return nil, "declare_vocabulary: failed to build base type terms" end

	local meta_a = meta_ty("A")
	local meta_b = meta_ty("B")
	if not meta_a or not meta_b then return nil, "declare_vocabulary: failed to build metavariables" end

	local h_a = H(meta_a)
	local h_b = H(meta_b)
	if not h_a or not h_b then return nil, "declare_vocabulary: failed to build has_type(meta) patterns" end

	local ax_lit, ax_err = replayer.declare_axiom({
		name = "hm-ax-lit", version = 1, signature = sig,
		pattern = h_a,
	})
	if not ax_lit then return nil, ax_err end

	local arrow_ab = Arrow(meta_a, meta_b)
	if not arrow_ab then return nil, "declare_vocabulary: failed to build arrow_ty(A,B)" end
	local h_arrow_ab = H(arrow_ab)
	if not h_arrow_ab then return nil, "declare_vocabulary: failed to build has_type(arrow_ty(A,B))" end

	local rule_abs, abs_err = replayer.declare_rule({
		name = "hm-abs", version = 1, signature = sig,
		premises = { h_a, h_b },
		conclusion = h_arrow_ab,
		discharges = { { premise = 1, pattern = h_a } },
	})
	if not rule_abs then return nil, abs_err end

	local h_arrow_for_app = H(Arrow(meta_ty("A"), meta_ty("B")))
	local h_a_for_app = H(meta_ty("A"))
	if not h_arrow_for_app or not h_a_for_app then return nil, "declare_vocabulary: failed to build hm-app patterns" end
	local rule_app, app_err = replayer.declare_rule({
		name = "hm-app", version = 1, signature = sig,
		premises = { h_arrow_for_app, h_a_for_app },
		conclusion = H(meta_ty("B")),
	})
	if not rule_app then return nil, app_err end

	local h_a_let1 = H(meta_ty("A"))
	local h_a_let2 = H(meta_ty("A"))
	local h_b_let = H(meta_ty("B"))
	if not h_a_let1 or not h_a_let2 or not h_b_let then return nil, "declare_vocabulary: failed to build hm-let patterns" end
	local rule_let, let_err = replayer.declare_rule({
		name = "hm-let", version = 1, signature = sig,
		premises = { h_a_let1, h_a_let2, h_b_let },
		conclusion = H(meta_ty("B")),
		discharges = { { premise = 2, pattern = h_a_let2 } },
	})
	if not rule_let then return nil, let_err end

	return {
		signature = sig,
		int_ty = int_ty, bool_ty = bool_ty,
		H = H, Arrow = Arrow,
		ax_lit = ax_lit, rule_abs = rule_abs, rule_app = rule_app, rule_let = rule_let,
	}
end

return M
