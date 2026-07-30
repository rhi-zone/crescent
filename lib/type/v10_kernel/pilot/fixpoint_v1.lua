-- lib/type/v10_kernel/pilot/fixpoint_v1.lua
--
-- Fixpoint-certificate THEORY — pilot step 3, further theory content
-- (docs/typechecker-v10-fixpoint-proposal.md, accepted commit 141cf0cc,
-- amended commit a7823a55 — the sequential-flow + zero-premise-rule-
-- retraction addendum). Declares `{ name = "narrow-pilot-v1", version = 4 }`:
-- v3's op set (v2's tags/ty_of/ty_union/holds_at/guard_selects, plus v3's
-- assign_literal/assign_copies/loop_edge/cf_join/stmt_seq/stmt_preserves)
-- UNCHANGED, plus ONE additive operator (`assign_call`) — the same
-- v1->v2->v3 versioning discipline (additive-only, one signature per module
-- bump, object identity is name+version so v1/v2/v3's own modules and tests
-- are untouched).
--
-- ── v3->v4: assignment transfer from an annotated-call RHS ──────────────────
--
-- Per the orchestrating brief (assignment-transfer-from-annotated-call-RHS
-- extension — measured gap keeping mutation-class loop invariants at zero
-- on real code, docs/typechecker-v10-pilot-measurement.md runs 3-4): a NEW
-- reality-boundary fact, "the call at path P has a callee whose declared
-- return annotation is type T," entering via the SAME schematic-axiom idiom
-- as `assign_literal`/`assign_copies` (§2 of the proposal) — one new
-- operator, one new axiom, one new transfer rule, mirroring
-- `assign_literal`'s own shape as closely as possible.
--
-- `assign_call(assign_point: point, var: path, ret_ty: ty) : judgment` —
-- "the parser saw a call expression whose callee resolves, STATICALLY AND
-- LOCALLY (a directly-named same-file local/module function whose `--:`
-- return annotation parses within the pilot's six-tag-plus-union
-- vocabulary, single return value only), to declared return type `ret_ty`,
-- assigned to `var` at `assign_point`."
--
-- **Deliberate divergence from `assign_literal`'s own shape, documented, not
-- silent:** `assign_literal`'s third argument is sort `prim_tag` (a literal
-- has exactly one primitive tag); `assign_call`'s third argument is sort
-- `ty` directly (a callee's declared return annotation can itself be a
-- multi-member union, e.g. `string | nil` — not reducible to one
-- `prim_tag`). This is why the transfer rule below needs no `ty_of(...)`
-- wrapping in its conclusion (unlike `assign-literal-transfer`), the one
-- structural difference from mirroring `assign_literal` exactly.
--
-- Reality-boundary axiom: `pilot-assign-call-facts-v1`, pattern
-- `assign_call(Pa, X, T)`, fully schematic over all three — same idiom as
-- `pilot-assign-literal-facts-v1`/`pilot-assign-copy-facts-v1`, no
-- discharge form. Trust rationale, stated plainly per the brief: the
-- callee's OWN annotation is trusted as an axiom instance here exactly as
-- every other reality-boundary fact in this theory trusts what the parser
-- saw — it is what the eventual full checker would separately verify by
-- typechecking the callee's own body against its declared signature; this
-- pilot does not re-derive that, it cites it.
--
-- Transfer rule: `assign-call-transfer`, premises `{ assign_call(Pa,X,T) }`
-- ⊢ `holds_at(Pa,X,T)`. `declare_rule` validity: premise metas `{Pa,X,T}` ⊇
-- conclusion metas `{Pa,X,T}` — identical shape to `assign-literal-transfer`
-- (single-premise rule wrapping its own axiom fact), no point-binding gap
-- (`Pa` is the axiom's own first bound argument, same as every other
-- assign-*-transfer rule).
--
-- Prover-side callee resolution (walking the AST to decide whether an
-- `assign_call` axiom citation is even licensed — never guessed, always
-- structurally verified from the parse) is pilot step 4
-- (fixpoint_prover.lua), not this module's concern; this module declares
-- the theory only, exactly matching v3's own division of labor for
-- `assign_literal`/`assign_copies`.
--
-- fable-delegation-tier throughout, per the core design's pilot-execution
-- delegation note — every choice here is a delegated-execution decision,
-- re-openable on challenge, not an owner ratification.
--
-- ── Five theories, one signature bump ───────────────────────────────────────
--
-- 1. Subsumption `ty_sub(A,B)` — proposal §1.1 (as corrected by the
--    addendum's §8.1 retraction): THREE schematic axioms (`ty-sub-refl`,
--    `ty-sub-union-here-left`, `ty-sub-union-here-right`) plus TWO genuine
--    rules (`ty-sub-trans`, `ty-sub-union-of-subsets`). Reflexivity and
--    union-here CANNOT be zero-premise rules under the ratified kernel (a
--    rule's conclusion metavariables must be bound by matching a premise's
--    computed conclusion — `declare_rule`'s F11 subset check and
--    `replay_rule`'s binding loop both make this structural, not stylistic;
--    see the addendum for the full trace). The taint cost of citing these
--    three axioms is priced as part of the same trust object as this
--    theory's own soundness assumption (addendum §8.2) — not a separate,
--    additional cost.
-- 2. Assignment transfer — proposal §2: `assign_literal`/`assign_copies`,
--    two reality-boundary axioms, two transfer rules. Scope, unchanged from
--    the proposal: literal or bare-identifier-copy RHS only; everything
--    else (call expressions, binary/table expressions, an RHS whose own
--    type isn't independently established) is a counted skip AT THE PROVER
--    — no axiom is ever cited for it. This module declares the theory only;
--    the prover-side skip bookkeeping is pilot step 4 (fixpoint_prover.lua).
-- 3. Loop-invariant discharge — proposal §3: `loop_edge` point-binding
--    axiom (§3.3's generalized principle: a rule whose conclusion needs a
--    point not literally one of its premises' own point arguments needs an
--    explicit point-binding syntax-fact premise), one rule with one
--    discharge slot closing the assumed-invariant hypothesis at the
--    back-edge premise.
-- 4. Branch join — proposal §4: `cf_join` point-binding axiom (same §3.3
--    principle), one rule, no discharge slot (never opens/closes a
--    hypothesis).
-- 5. Sequential-flow persistence — addendum §8.3: `stmt_seq`/
--    `stmt_preserves` reality-boundary axioms (the latter sharing its
--    `(from_point, to_point)` pair with `stmt_seq` — see the addendum for
--    why an independent statement-path argument would be unsound: nothing
--    would force it to name the same span `stmt_seq` asserts adjacency
--    over), one persistence rule.
--
-- No side condition was needed anywhere in this set — HALT was not
-- triggered. Every rule's F11 validity (premise-metavariable-superset of
-- conclusion/discharge-slot metavariables) is worked by hand in the
-- proposal/addendum prose; this module's `declare_rule` calls are the
-- literal transcription of those worked shapes.

local ta = require("lib.type.v10_cleanroom.term_algebra")
local replayer = require("lib.type.v10_cleanroom.replayer")

local M = {}

--:: FixpointVocab = {
--::   signature: Signature,
--::   HoldsAt: (p: Term, x: Term, ty: Term) -> (Term | nil, string | nil),
--::   TySub: (a: Term, b: Term) -> (Term | nil, string | nil),
--::   TyOf: (tag: Term) -> (Term | nil, string | nil),
--::   TyUnion: (a: Term, b: Term) -> (Term | nil, string | nil),
--::   GuardSelects: (pg: Term, pb: Term, x: Term, ty: Term) -> (Term | nil, string | nil),
--::   AssignLiteral: (p: Term, x: Term, tag: Term) -> (Term | nil, string | nil),
--::   AssignCopies: (p: Term, x: Term, y: Term) -> (Term | nil, string | nil),
--::   LoopEdge: (lh: Term, be: Term) -> (Term | nil, string | nil),
--::   CfJoin: (pa: Term, pb: Term, pj: Term) -> (Term | nil, string | nil),
--::   StmtSeq: (a: Term, b: Term) -> (Term | nil, string | nil),
--::   StmtPreserves: (a: Term, b: Term, x: Term) -> (Term | nil, string | nil),
--::   tag_nil: () -> (Term | nil, string | nil),
--::   tag_boolean: () -> (Term | nil, string | nil),
--::   tag_true: () -> (Term | nil, string | nil),
--::   tag_false: () -> (Term | nil, string | nil),
--::   tag_number: () -> (Term | nil, string | nil),
--::   tag_string: () -> (Term | nil, string | nil),
--::   tag_table: () -> (Term | nil, string | nil),
--::   tag_function: () -> (Term | nil, string | nil),
--::   falsy_ty: () -> (Term | nil, string | nil),
--::   ax_syntax_facts: AxiomDecl,
--::   rule_match: RuleDecl,
--::   rule_rest: RuleDecl,
--::   ax_ty_sub_refl: AxiomDecl,
--::   ax_ty_sub_union_here_left: AxiomDecl,
--::   ax_ty_sub_union_here_right: AxiomDecl,
--::   rule_ty_sub_trans: RuleDecl,
--::   rule_ty_sub_union_of_subsets: RuleDecl,
--::   AssignCall: (p: Term, x: Term, t: Term) -> (Term | nil, string | nil),
--::   ax_assign_literal_facts: AxiomDecl,
--::   ax_assign_copy_facts: AxiomDecl,
--::   ax_assign_call_facts: AxiomDecl,
--::   rule_assign_literal_transfer: RuleDecl,
--::   rule_assign_copy_transfer: RuleDecl,
--::   rule_assign_call_transfer: RuleDecl,
--::   ax_loop_facts: AxiomDecl,
--::   rule_loop_invariant_discharge: RuleDecl,
--::   ax_cf_join_facts: AxiomDecl,
--::   rule_narrow_join: RuleDecl,
--::   ax_stmt_seq_facts: AxiomDecl,
--::   ax_stmt_preserves_facts: AxiomDecl,
--::   rule_seq_persist: RuleDecl,
--:: }

-- Declare the fixpoint-certificate theory's signature (`narrow-pilot-v1`
-- v3) into the given registry, importing `point`/`path` from an
-- already-declared addr-v1 signature. Caps-clean: both `registry` and
-- `addr_sig` are injected, never reached for ambiently. Call once per
-- registry ((name, version) unique per registry, F11).
-- `addr_sig` is typed `unknown` and narrowed by hand: same typechecker
-- gotcha `flow_narrow_v1.lua`'s own `declare_vocabulary` documents (a
-- `type(x) ~= "table"` guard on an already-record-typed parameter widens
-- the else branch back to `unknown`).
--: (registry: Registry, addr_sig: unknown) -> (FixpointVocab | nil, string | nil)
function M.declare_vocabulary(registry, addr_sig)
	if type(addr_sig) ~= "table" then
		return nil, "declare_vocabulary: addr_sig (a declared addr-v1 signature) is required"
	end
	local sig_in = addr_sig --[[: Signature ]]
	local addr_sorts = sig_in.sorts
	if type(addr_sorts) ~= "table" or not addr_sorts.point or not addr_sorts.path then
		return nil, "declare_vocabulary: addr_sig must declare point and path sorts"
	end

	local sig, sig_err = ta.declare_signature({
		name = "narrow-pilot-v1",
		version = 4,
		sorts = { "prim_tag", "ty", "judgment" },
		imports = { { from = sig_in, sorts = { "point", "path" } } },
		ops = {
			tag_nil      = { result = "prim_tag", args = {} },
			tag_boolean  = { result = "prim_tag", args = {} },
			tag_true     = { result = "prim_tag", args = {} },
			tag_false    = { result = "prim_tag", args = {} },
			tag_number   = { result = "prim_tag", args = {} },
			tag_string   = { result = "prim_tag", args = {} },
			tag_table    = { result = "prim_tag", args = {} },
			tag_function = { result = "prim_tag", args = {} },

			ty_of        = { result = "ty", args = { { sort = "prim_tag" } } },
			ty_union     = { result = "ty", args = { { sort = "ty" }, { sort = "ty" } } },

			holds_at     = { result = "judgment", args = { { sort = "point" }, { sort = "path" }, { sort = "ty" } } },
			guard_selects = {
				result = "judgment",
				args = { { sort = "point" }, { sort = "point" }, { sort = "path" }, { sort = "ty" } },
			},

			-- §1: subsumption judgment.
			ty_sub = { result = "judgment", args = { { sort = "ty" }, { sort = "ty" } } },

			-- §2: assignment-transfer syntax facts.
			assign_literal = {
				result = "judgment",
				args = { { sort = "point" }, { sort = "path" }, { sort = "prim_tag" } },
			},
			assign_copies = {
				result = "judgment",
				args = { { sort = "point" }, { sort = "path" }, { sort = "path" } },
			},
			-- v4: assignment transfer from an annotated-call RHS (`ret_ty` is
			-- sort `ty`, not `prim_tag` — see module header's documented
			-- divergence from `assign_literal`'s own shape).
			assign_call = {
				result = "judgment",
				args = { { sort = "point" }, { sort = "path" }, { sort = "ty" } },
			},

			-- §3: loop-invariant point-binding syntax fact.
			loop_edge = { result = "judgment", args = { { sort = "point" }, { sort = "point" } } },

			-- §4: join point-binding syntax fact.
			cf_join = {
				result = "judgment",
				args = { { sort = "point" }, { sort = "point" }, { sort = "point" } },
			},

			-- addendum §8.3: sequential-flow syntax facts.
			stmt_seq = { result = "judgment", args = { { sort = "point" }, { sort = "point" } } },
			stmt_preserves = {
				result = "judgment",
				args = { { sort = "point" }, { sort = "point" }, { sort = "path" } },
			},
		},
	})
	if not sig then return nil, sig_err end
	local ops = sig.ops

	--: (p: Term, x: Term, ty: Term) -> (Term | nil, string | nil)
	local function HoldsAt(p, x, ty) return ta.build(ops.holds_at, { p, x, ty }) end
	--: (tag: Term) -> (Term | nil, string | nil)
	local function TyOf(tag) return ta.build(ops.ty_of, { tag }) end
	--: (a: Term, b: Term) -> (Term | nil, string | nil)
	local function TyUnion(a, b) return ta.build(ops.ty_union, { a, b }) end
	--: (pg: Term, pb: Term, x: Term, ty: Term) -> (Term | nil, string | nil)
	local function GuardSelects(pg, pb, x, ty) return ta.build(ops.guard_selects, { pg, pb, x, ty }) end
	--: (a: Term, b: Term) -> (Term | nil, string | nil)
	local function TySub(a, b) return ta.build(ops.ty_sub, { a, b }) end
	--: (p: Term, x: Term, tag: Term) -> (Term | nil, string | nil)
	local function AssignLiteral(p, x, tag) return ta.build(ops.assign_literal, { p, x, tag }) end
	--: (p: Term, x: Term, y: Term) -> (Term | nil, string | nil)
	local function AssignCopies(p, x, y) return ta.build(ops.assign_copies, { p, x, y }) end
	--: (p: Term, x: Term, t: Term) -> (Term | nil, string | nil)
	local function AssignCall(p, x, t) return ta.build(ops.assign_call, { p, x, t }) end
	--: (lh: Term, be: Term) -> (Term | nil, string | nil)
	local function LoopEdge(lh, be) return ta.build(ops.loop_edge, { lh, be }) end
	--: (pa: Term, pb: Term, pj: Term) -> (Term | nil, string | nil)
	local function CfJoin(pa, pb, pj) return ta.build(ops.cf_join, { pa, pb, pj }) end
	--: (a: Term, b: Term) -> (Term | nil, string | nil)
	local function StmtSeq(a, b) return ta.build(ops.stmt_seq, { a, b }) end
	--: (a: Term, b: Term, x: Term) -> (Term | nil, string | nil)
	local function StmtPreserves(a, b, x) return ta.build(ops.stmt_preserves, { a, b, x }) end

	--: () -> (Term | nil, string | nil)
	local function tag_nil() return ta.build(ops.tag_nil, {}) end
	--: () -> (Term | nil, string | nil)
	local function tag_boolean() return ta.build(ops.tag_boolean, {}) end
	--: () -> (Term | nil, string | nil)
	local function tag_true() return ta.build(ops.tag_true, {}) end
	--: () -> (Term | nil, string | nil)
	local function tag_false() return ta.build(ops.tag_false, {}) end
	--: () -> (Term | nil, string | nil)
	local function tag_number() return ta.build(ops.tag_number, {}) end
	--: () -> (Term | nil, string | nil)
	local function tag_string() return ta.build(ops.tag_string, {}) end
	--: () -> (Term | nil, string | nil)
	local function tag_table() return ta.build(ops.tag_table, {}) end
	--: () -> (Term | nil, string | nil)
	local function tag_function() return ta.build(ops.tag_function, {}) end

	--: () -> (Term | nil, string | nil)
	local function falsy_ty()
		local tn = tag_nil()
		local tf = tag_false()
		if not tn or not tf then return nil, "falsy_ty: failed to build tags" end
		local ty_n = TyOf(tn)
		local ty_f = TyOf(tf)
		if not ty_n or not ty_f then return nil, "falsy_ty: failed to build ty_of terms" end
		return TyUnion(ty_n, ty_f)
	end

	local point_sort, path_sort, ty_sort = sig.sorts.point, sig.sorts.path, sig.sorts.ty

	-- ── narrow-select-match / narrow-select-rest (v2, unchanged shape) ──────
	local pg = ta.meta("Pg", point_sort)
	local pb = ta.meta("Pb", point_sort)
	local x_narrow = ta.meta("X", path_sort)
	local ta_meta = ta.meta("TA", ty_sort)
	local rest = ta.meta("Rest", ty_sort)
	if not pg or not pb or not x_narrow or not ta_meta or not rest then
		return nil, "declare_vocabulary: failed to build narrow-rule metavariables"
	end
	local union_ta_rest = TyUnion(ta_meta, rest)
	if not union_ta_rest then return nil, "declare_vocabulary: failed to build ty_union(TA,Rest) pattern" end
	local holds_guard = HoldsAt(pg, x_narrow, union_ta_rest)
	local fact = GuardSelects(pg, pb, x_narrow, ta_meta)
	if not holds_guard or not fact then return nil, "declare_vocabulary: failed to build shared premise patterns" end

	local ax_syntax_facts, ax_err = replayer.declare_axiom(registry, {
		name = "pilot-syntax-facts-v1", version = 1,
		pattern = fact,
	})
	if not ax_syntax_facts then return nil, ax_err end

	local holds_match = HoldsAt(pb, x_narrow, ta_meta)
	if not holds_match then return nil, "declare_vocabulary: failed to build narrow-select-match conclusion" end
	local rule_match, match_err = replayer.declare_rule(registry, {
		name = "narrow-select-match", version = 1,
		premises = { holds_guard, fact },
		conclusion = holds_match,
	})
	if not rule_match then return nil, match_err end

	local holds_rest = HoldsAt(pb, x_narrow, rest)
	if not holds_rest then return nil, "declare_vocabulary: failed to build narrow-select-rest conclusion" end
	local rule_rest, rest_err = replayer.declare_rule(registry, {
		name = "narrow-select-rest", version = 1,
		premises = { holds_guard, fact },
		conclusion = holds_rest,
	})
	if not rule_rest then return nil, rest_err end

	-- ── §1: subsumption ty_sub(A,B) — 3 axioms + 2 rules ────────────────────
	local sub_a = ta.meta("A", ty_sort)
	local sub_b = ta.meta("B", ty_sort)
	local sub_c = ta.meta("C", ty_sort)
	local sub_rest = ta.meta("Rest", ty_sort)
	local sub_x = ta.meta("X", ty_sort)
	if not sub_a or not sub_b or not sub_c or not sub_rest or not sub_x then
		return nil, "declare_vocabulary: failed to build ty_sub metavariables"
	end

	local refl_pat = TySub(sub_a, sub_a)
	if not refl_pat then return nil, "declare_vocabulary: failed to build ty-sub-refl pattern" end
	local ax_ty_sub_refl, refl_err = replayer.declare_axiom(registry, {
		name = "ty-sub-refl", version = 1, pattern = refl_pat,
	})
	if not ax_ty_sub_refl then return nil, refl_err end

	local union_a_rest = TyUnion(sub_a, sub_rest)
	if not union_a_rest then return nil, "declare_vocabulary: failed to build ty_union(A,Rest) pattern" end
	local here_left_pat = TySub(sub_a, union_a_rest)
	if not here_left_pat then return nil, "declare_vocabulary: failed to build ty-sub-union-here-left pattern" end
	local ax_ty_sub_union_here_left, hl_err = replayer.declare_axiom(registry, {
		name = "ty-sub-union-here-left", version = 1, pattern = here_left_pat,
	})
	if not ax_ty_sub_union_here_left then return nil, hl_err end

	local union_x_b = TyUnion(sub_x, sub_b)
	if not union_x_b then return nil, "declare_vocabulary: failed to build ty_union(X,B) pattern" end
	local here_right_pat = TySub(sub_b, union_x_b)
	if not here_right_pat then return nil, "declare_vocabulary: failed to build ty-sub-union-here-right pattern" end
	local ax_ty_sub_union_here_right, hr_err = replayer.declare_axiom(registry, {
		name = "ty-sub-union-here-right", version = 1, pattern = here_right_pat,
	})
	if not ax_ty_sub_union_here_right then return nil, hr_err end

	local sub_ab = TySub(sub_a, sub_b)
	local sub_bc = TySub(sub_b, sub_c)
	local sub_ac = TySub(sub_a, sub_c)
	if not sub_ab or not sub_bc or not sub_ac then
		return nil, "declare_vocabulary: failed to build ty-sub-trans patterns"
	end
	local rule_ty_sub_trans, trans_err = replayer.declare_rule(registry, {
		name = "ty-sub-trans", version = 1,
		premises = { sub_ab, sub_bc },
		conclusion = sub_ac,
	})
	if not rule_ty_sub_trans then return nil, trans_err end

	local sub_ac2 = TySub(sub_a, sub_c)
	local sub_bc2 = TySub(sub_b, sub_c)
	local union_ab = TyUnion(sub_a, sub_b)
	if not sub_ac2 or not sub_bc2 or not union_ab then
		return nil, "declare_vocabulary: failed to build ty-sub-union-of-subsets patterns"
	end
	local sub_unionab_c = TySub(union_ab, sub_c)
	if not sub_unionab_c then
		return nil, "declare_vocabulary: failed to build ty-sub-union-of-subsets conclusion"
	end
	local rule_ty_sub_union_of_subsets, uos_err = replayer.declare_rule(registry, {
		name = "ty-sub-union-of-subsets", version = 1,
		premises = { sub_ac2, sub_bc2 },
		conclusion = sub_unionab_c,
	})
	if not rule_ty_sub_union_of_subsets then return nil, uos_err end

	-- ── §2: assignment transfer ──────────────────────────────────────────────
	local pa_pt = ta.meta("Pa", point_sort)
	local x_assign = ta.meta("X", path_sort)
	local y_assign = ta.meta("Y", path_sort)
	local tag_meta = ta.meta("Tag", sig.sorts.prim_tag)
	local t_assign = ta.meta("T", ty_sort)
	if not pa_pt or not x_assign or not y_assign or not tag_meta or not t_assign then
		return nil, "declare_vocabulary: failed to build assignment-transfer metavariables"
	end

	local assign_literal_pat = AssignLiteral(pa_pt, x_assign, tag_meta)
	if not assign_literal_pat then return nil, "declare_vocabulary: failed to build assign_literal pattern" end
	local ax_assign_literal_facts, alf_err = replayer.declare_axiom(registry, {
		name = "pilot-assign-literal-facts-v1", version = 1, pattern = assign_literal_pat,
	})
	if not ax_assign_literal_facts then return nil, alf_err end

	local assign_copies_pat = AssignCopies(pa_pt, x_assign, y_assign)
	if not assign_copies_pat then return nil, "declare_vocabulary: failed to build assign_copies pattern" end
	local ax_assign_copy_facts, acf_err = replayer.declare_axiom(registry, {
		name = "pilot-assign-copy-facts-v1", version = 1, pattern = assign_copies_pat,
	})
	if not ax_assign_copy_facts then return nil, acf_err end

	local literal_concl = TyOf(tag_meta)
	if not literal_concl then return nil, "declare_vocabulary: failed to build ty_of(Tag) pattern" end
	local literal_holds = HoldsAt(pa_pt, x_assign, literal_concl)
	if not literal_holds then return nil, "declare_vocabulary: failed to build assign-literal-transfer conclusion" end
	local rule_assign_literal_transfer, alt_err = replayer.declare_rule(registry, {
		name = "assign-literal-transfer", version = 1,
		premises = { assign_literal_pat },
		conclusion = literal_holds,
	})
	if not rule_assign_literal_transfer then return nil, alt_err end

	local holds_y = HoldsAt(pa_pt, y_assign, t_assign)
	local holds_x = HoldsAt(pa_pt, x_assign, t_assign)
	if not holds_y or not holds_x then
		return nil, "declare_vocabulary: failed to build assign-copy-transfer patterns"
	end
	local rule_assign_copy_transfer, act_err = replayer.declare_rule(registry, {
		name = "assign-copy-transfer", version = 1,
		premises = { assign_copies_pat, holds_y },
		conclusion = holds_x,
	})
	if not rule_assign_copy_transfer then return nil, act_err end

	-- v4: assignment transfer from an annotated-call RHS (module header).
	-- Reuses `pa_pt`/`x_assign` (already bound above); `t_assign` (sort
	-- `ty`, already bound above for assign-copy-transfer) is reused
	-- unchanged as the shared metavariable here too — a fresh `ta.meta("T",
	-- ty_sort)` would be an equally-valid but redundant alternative (meta
	-- names are per-declaration-call, not globally namespaced — see this
	-- file's own repeated reuse of the string name "X" across unrelated
	-- rule sections).
	local assign_call_pat = AssignCall(pa_pt, x_assign, t_assign)
	if not assign_call_pat then return nil, "declare_vocabulary: failed to build assign_call pattern" end
	local ax_assign_call_facts, acaf_err = replayer.declare_axiom(registry, {
		name = "pilot-assign-call-facts-v1", version = 1, pattern = assign_call_pat,
	})
	if not ax_assign_call_facts then return nil, acaf_err end

	local call_holds_x = HoldsAt(pa_pt, x_assign, t_assign)
	if not call_holds_x then return nil, "declare_vocabulary: failed to build assign-call-transfer conclusion" end
	local rule_assign_call_transfer, act2_err = replayer.declare_rule(registry, {
		name = "assign-call-transfer", version = 1,
		premises = { assign_call_pat },
		conclusion = call_holds_x,
	})
	if not rule_assign_call_transfer then return nil, act2_err end

	-- ── §3: loop-invariant discharge ─────────────────────────────────────────
	local lh = ta.meta("LH", point_sort)
	local be = ta.meta("BE", point_sort)
	local x_loop = ta.meta("X", path_sort)
	local tp = ta.meta("Tp", ty_sort)
	local tinv = ta.meta("Tinv", ty_sort)
	local pre_loop = ta.meta("PreLoop", point_sort)
	local t0 = ta.meta("T0", ty_sort)
	if not lh or not be or not x_loop or not tp or not tinv or not pre_loop or not t0 then
		return nil, "declare_vocabulary: failed to build loop-invariant metavariables"
	end

	local loop_edge_pat = LoopEdge(lh, be)
	if not loop_edge_pat then return nil, "declare_vocabulary: failed to build loop_edge pattern" end
	local ax_loop_facts, lf_err = replayer.declare_axiom(registry, {
		name = "pilot-loop-facts-v1", version = 1, pattern = loop_edge_pat,
	})
	if not ax_loop_facts then return nil, lf_err end

	local p1_holds_be = HoldsAt(be, x_loop, tp)
	local p2_sub_tp_tinv = TySub(tp, tinv)
	local p3_holds_preloop = HoldsAt(pre_loop, x_loop, t0)
	local p4_sub_t0_tinv = TySub(t0, tinv)
	local loop_concl = HoldsAt(lh, x_loop, tinv)
	if not p1_holds_be or not p2_sub_tp_tinv or not p3_holds_preloop or not p4_sub_t0_tinv or not loop_concl then
		return nil, "declare_vocabulary: failed to build loop-invariant-discharge patterns"
	end
	-- Premise order per proposal §3.2: P0=loop_edge, P1=holds_at(BE,...)
	-- (the discharged subderivation, slot targets premise index 2),
	-- P2=ty_sub(Tp,Tinv), P3=holds_at(PreLoop,...), P4=ty_sub(T0,Tinv).
	local rule_loop_invariant_discharge, lid_err = replayer.declare_rule(registry, {
		name = "loop-invariant-discharge", version = 1,
		premises = { loop_edge_pat, p1_holds_be, p2_sub_tp_tinv, p3_holds_preloop, p4_sub_t0_tinv },
		conclusion = loop_concl,
		discharges = { { premise = 2, hypothesis = loop_concl } },
	})
	if not rule_loop_invariant_discharge then return nil, lid_err end

	-- ── §4: branch join ──────────────────────────────────────────────────────
	local pa_join = ta.meta("Pa", point_sort)
	local pb_join = ta.meta("Pb", point_sort)
	local pj = ta.meta("Pj", point_sort)
	local x_join = ta.meta("X", path_sort)
	local ty_a = ta.meta("A", ty_sort)
	local ty_b = ta.meta("B", ty_sort)
	if not pa_join or not pb_join or not pj or not x_join or not ty_a or not ty_b then
		return nil, "declare_vocabulary: failed to build join metavariables"
	end

	local cf_join_pat = CfJoin(pa_join, pb_join, pj)
	if not cf_join_pat then return nil, "declare_vocabulary: failed to build cf_join pattern" end
	local ax_cf_join_facts, cjf_err = replayer.declare_axiom(registry, {
		name = "pilot-cf-join-facts-v1", version = 1, pattern = cf_join_pat,
	})
	if not ax_cf_join_facts then return nil, cjf_err end

	local holds_a_join = HoldsAt(pa_join, x_join, ty_a)
	local holds_b_join = HoldsAt(pb_join, x_join, ty_b)
	local union_ab_join = TyUnion(ty_a, ty_b)
	if not holds_a_join or not holds_b_join or not union_ab_join then
		return nil, "declare_vocabulary: failed to build narrow-join patterns"
	end
	local join_concl = HoldsAt(pj, x_join, union_ab_join)
	if not join_concl then
		return nil, "declare_vocabulary: failed to build narrow-join patterns"
	end
	local rule_narrow_join, nj_err = replayer.declare_rule(registry, {
		name = "narrow-join", version = 1,
		premises = { holds_a_join, holds_b_join, cf_join_pat },
		conclusion = join_concl,
	})
	if not rule_narrow_join then return nil, nj_err end

	-- ── addendum §8.3: sequential-flow persistence ───────────────────────────
	local seq_a = ta.meta("A", point_sort)
	local seq_b = ta.meta("B", point_sort)
	local seq_x = ta.meta("X", path_sort)
	local seq_t = ta.meta("T", ty_sort)
	if not seq_a or not seq_b or not seq_x or not seq_t then
		return nil, "declare_vocabulary: failed to build sequential-flow metavariables"
	end

	local stmt_seq_pat = StmtSeq(seq_a, seq_b)
	if not stmt_seq_pat then return nil, "declare_vocabulary: failed to build stmt_seq pattern" end
	local ax_stmt_seq_facts, ssf_err = replayer.declare_axiom(registry, {
		name = "pilot-stmt-seq-facts-v1", version = 1, pattern = stmt_seq_pat,
	})
	if not ax_stmt_seq_facts then return nil, ssf_err end

	local stmt_preserves_pat = StmtPreserves(seq_a, seq_b, seq_x)
	if not stmt_preserves_pat then return nil, "declare_vocabulary: failed to build stmt_preserves pattern" end
	local ax_stmt_preserves_facts, spf_err = replayer.declare_axiom(registry, {
		name = "pilot-stmt-preserves-facts-v1", version = 1, pattern = stmt_preserves_pat,
	})
	if not ax_stmt_preserves_facts then return nil, spf_err end

	local holds_a_seq = HoldsAt(seq_a, seq_x, seq_t)
	local holds_b_seq = HoldsAt(seq_b, seq_x, seq_t)
	if not holds_a_seq or not holds_b_seq then
		return nil, "declare_vocabulary: failed to build seq-persist patterns"
	end
	local rule_seq_persist, sp_err = replayer.declare_rule(registry, {
		name = "seq-persist", version = 1,
		premises = { holds_a_seq, stmt_seq_pat, stmt_preserves_pat },
		conclusion = holds_b_seq,
	})
	if not rule_seq_persist then return nil, sp_err end

	return {
		signature = sig,
		HoldsAt = HoldsAt, TySub = TySub, TyOf = TyOf, TyUnion = TyUnion, GuardSelects = GuardSelects,
		AssignLiteral = AssignLiteral, AssignCopies = AssignCopies, AssignCall = AssignCall,
		LoopEdge = LoopEdge, CfJoin = CfJoin, StmtSeq = StmtSeq, StmtPreserves = StmtPreserves,
		tag_nil = tag_nil, tag_boolean = tag_boolean, tag_true = tag_true, tag_false = tag_false,
		tag_number = tag_number, tag_string = tag_string, tag_table = tag_table, tag_function = tag_function,
		falsy_ty = falsy_ty,
		ax_syntax_facts = ax_syntax_facts,
		rule_match = rule_match,
		rule_rest = rule_rest,
		ax_ty_sub_refl = ax_ty_sub_refl,
		ax_ty_sub_union_here_left = ax_ty_sub_union_here_left,
		ax_ty_sub_union_here_right = ax_ty_sub_union_here_right,
		rule_ty_sub_trans = rule_ty_sub_trans,
		rule_ty_sub_union_of_subsets = rule_ty_sub_union_of_subsets,
		ax_assign_literal_facts = ax_assign_literal_facts,
		ax_assign_copy_facts = ax_assign_copy_facts,
		ax_assign_call_facts = ax_assign_call_facts,
		rule_assign_literal_transfer = rule_assign_literal_transfer,
		rule_assign_copy_transfer = rule_assign_copy_transfer,
		rule_assign_call_transfer = rule_assign_call_transfer,
		ax_loop_facts = ax_loop_facts,
		rule_loop_invariant_discharge = rule_loop_invariant_discharge,
		ax_cf_join_facts = ax_cf_join_facts,
		rule_narrow_join = rule_narrow_join,
		ax_stmt_seq_facts = ax_stmt_seq_facts,
		ax_stmt_preserves_facts = ax_stmt_preserves_facts,
		rule_seq_persist = rule_seq_persist,
	}
end

return M
