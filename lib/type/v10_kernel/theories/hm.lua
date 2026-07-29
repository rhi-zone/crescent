-- lib/type/v10_kernel/theories/hm.lua
-- Shared Hindley-Milner judgment vocabulary for the ported Algorithm W /
-- Algorithm J theory entries (docs/decisions/typechecker-v10-core-design.md,
-- docs/decisions/typechecker-v10-core-charter.md). Built over the canonical
-- v10 core, lib/type/v10_cleanroom/ (term_algebra + replayer), per the
-- owner-ratified canon swap (design doc, "Canon swap: cleanroom core");
-- the prior lib/type/v10_kernel/term_algebra/ + replayer/ are retired.
--
-- This is the ONE vocabulary both algorithm_w.lua and algorithm_j.lua build
-- against: rule/axiom identity is the declared object itself (replay cites
-- the object directly), so "sharing a rule" is simply "both theories hold a
-- reference to the same declared object." Under the canonical core,
-- declarations live in a caller-supplied REGISTRY (F11: (name, version)
-- unique per registry; citations resolve only against the registry the
-- replayer instance is bound to), so a caller creates one registry, calls
-- `hm.declare_vocabulary(registry)` ONCE on it, builds a replayer over the
-- same registry, and hands the vocabulary to BOTH `algorithm_w.certify`
-- and `algorithm_j.certify`. Calling declare_vocabulary twice on one
-- registry rejects (duplicate (name, version)) — one vocabulary per
-- registry, by construction.
--
-- Term construction is via the canonical term algebra's module-level
-- primitives (reference tier — the canonical core implements exactly the
-- reference tier; the fast tier retired with the old core and will be
-- rebuilt against the canonical reference as a separate effort). There is
-- no per-tier instance parameter any more.
--
-- Judgment grammar (`hm-judgment` signature):
--   sorts: ty (a Hindley-Milner monotype), jud (a typing judgment)
--   int_ty, bool_ty  : ty                    -- the two base types the ported
--                                                theories' test terms use
--   arrow_ty(ty, ty) : ty                    -- function type, non-binding
--   has_type(ty)     : jud                   -- "this occurrence has type T"
--
-- Rule/axiom design (see algorithm_w.lua's header for the port
-- correspondence and findings 1-3, unchanged in meaning by the canon swap):
--   hm-ax-lit : axiom, schematic pattern has_type(meta A).
--   hm-abs    : rule, premises { has_type(meta A) [param hypothesis, cited
--     AS a premise], has_type(meta B) [body] }, conclusion
--     has_type(arrow_ty(A,B)), discharge slot (premise=1,
--     hypothesis=has_type(meta A)).
--   hm-app    : rule, premises { has_type(arrow_ty(meta A, meta B)) [fn],
--     has_type(meta A) [arg, same A — non-linear metavariable] },
--     conclusion has_type(meta B), no discharge.
--   hm-let    : rule, premises { has_type(meta A) [value], has_type(meta A)
--     [let-bound hypothesis, same A], has_type(meta B) [body] }, conclusion
--     has_type(meta B), discharge slot (premise=2,
--     hypothesis=has_type(meta A)).

local ta = require("lib.type.v10_cleanroom.term_algebra")
local replayer = require("lib.type.v10_cleanroom.replayer")

local M = {}

--:: Vocab = { signature: Signature, int_ty: Term, bool_ty: Term, H: (t: Term) -> (Term | nil, string | nil), Arrow: (a: Term, b: Term) -> (Term | nil, string | nil), ax_lit: AxiomDecl, rule_abs: RuleDecl, rule_app: RuleDecl, rule_let: RuleDecl }

-- Declare the hm-judgment signature and its rule/axiom vocabulary into the
-- given registry. Call once per registry; share the result between
-- algorithm_w.certify and algorithm_j.certify (per the header's genericity
-- note). The registry is caps-first injected — the caller owns it and binds
-- its replayer instance to the same one.
--: (registry: Registry) -> (Vocab | nil, string | nil)
function M.declare_vocabulary(registry)
	local sig, sig_err = ta.declare_signature({
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

	--: (t: Term) -> (Term | nil, string | nil)
	local function H(t) return ta.build(ops.has_type, { t }) end
	--: (a: Term, b: Term) -> (Term | nil, string | nil)
	local function Arrow(a, b) return ta.build(ops.arrow_ty, { a, b }) end
	--: (id: string) -> (Term | nil, string | nil)
	local function meta_ty(id) return ta.meta(id, sig.sorts.ty) end

	local int_ty = ta.build(ops.int_ty, {})
	local bool_ty = ta.build(ops.bool_ty, {})
	if not int_ty or not bool_ty then return nil, "declare_vocabulary: failed to build base type terms" end

	local meta_a = meta_ty("A")
	local meta_b = meta_ty("B")
	if not meta_a or not meta_b then return nil, "declare_vocabulary: failed to build metavariables" end

	local h_a = H(meta_a)
	local h_b = H(meta_b)
	if not h_a or not h_b then return nil, "declare_vocabulary: failed to build has_type(meta) patterns" end

	local ax_lit, ax_err = replayer.declare_axiom(registry, {
		name = "hm-ax-lit", version = 1,
		pattern = h_a,
	})
	if not ax_lit then return nil, ax_err end

	local arrow_ab = Arrow(meta_a, meta_b)
	if not arrow_ab then return nil, "declare_vocabulary: failed to build arrow_ty(A,B)" end
	local h_arrow_ab = H(arrow_ab)
	if not h_arrow_ab then return nil, "declare_vocabulary: failed to build has_type(arrow_ty(A,B))" end

	local rule_abs, abs_err = replayer.declare_rule(registry, {
		name = "hm-abs", version = 1,
		premises = { h_a, h_b },
		conclusion = h_arrow_ab,
		discharges = { { premise = 1, hypothesis = h_a } },
	})
	if not rule_abs then return nil, abs_err end

	local h_b_for_app = H(meta_b)
	if not h_b_for_app then return nil, "declare_vocabulary: failed to build hm-app conclusion" end
	local rule_app, app_err = replayer.declare_rule(registry, {
		name = "hm-app", version = 1,
		premises = { h_arrow_ab, h_a },
		conclusion = h_b_for_app,
	})
	if not rule_app then return nil, app_err end

	local rule_let, let_err = replayer.declare_rule(registry, {
		name = "hm-let", version = 1,
		premises = { h_a, h_a, h_b },
		conclusion = h_b,
		discharges = { { premise = 2, hypothesis = h_a } },
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
