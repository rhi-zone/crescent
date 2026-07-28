-- lib/type/v10_kernel/pilot/flow_narrow_v1.lua
--
-- Flow-narrowing THEORY — pilot step 3
-- (docs/decisions/typechecker-v10-core-design.md, "Pilot: flow-narrowing on
-- the kernel — plan of record", item 3; docs/typechecker-v10-pilot-
-- signatures-proposal.md). Rule schemas over addr-v1 (program-point
-- addressing, pilot/addr_v1.lua) and a version-2 extension of
-- narrow-pilot-v1 (pilot type vocabulary, pilot/narrow_pilot_v1.lua).
--
-- fable-delegation-tier throughout (per the core design's pilot-execution
-- delegation note): every choice here is a delegated-execution decision,
-- re-openable on challenge, not an owner ratification.
--
-- ── Why a v2 signature, not a fresh one ─────────────────────────────────────
--
-- The registry's `check_pattern` (replayer/registry.lua) requires every
-- operator node in a rule/axiom pattern to belong to EXACTLY the one
-- signature object passed as `spec.signature` (name+version match) — sorts
-- may be imported from another signature, but operators may not (confirmed
-- by reading registry.lua and shared.lua directly: `imports` is a sorts-only
-- mechanism). A narrowing rule's premises need `holds_at`/`ty_union`/`ty_of`/
-- `tag_*` (narrow-pilot-v1's own ops) AND a new "syntax fact" operator
-- (below) in the SAME pattern — so the new operator cannot live in a
-- separate signature that merely imports narrow-pilot-v1's sorts; it must be
-- declared inside one signature alongside the ops it composes with. Per the
-- core design doc's versioning discipline ("Extend narrow-pilot-v1's
-- signature — new version or additive ops"), this module declares
-- `{ name = "narrow-pilot-v1", version = 2 }`: literally the v1 op set,
-- unchanged, plus one additive op. Object identity is name+version, so this
-- is a wholly independent declared signature from v1's — v1's own module
-- and tests (pilot/narrow_pilot_v1.lua, pilot/narrow_pilot_v1_test.lua)
-- are untouched and still valid on their own; this module does not consume
-- or extend the v1 SIGNATURE OBJECT, only its op-set design.
--
-- ── The reality-boundary question: how do syntax facts enter a derivation ──
--
-- The rules below need a premise like "the guard at this point tests
-- whether path X's value belongs to type T, and the branch reached on a
-- match starts at that other point" — a fact about what the PARSER saw in
-- the source file. Nothing in the kernel can derive this: it is not a
-- consequence of other judgments, it is an observation about syntax. Per
-- the core design's ratified axiom mechanism ("Axioms are schematic... a
-- citing node supplies bindings; the kernel computes the axiom node's
-- conclusion by instantiating the declaration's pattern" — no new kernel
-- substrate needed, resolving the exact question the task brief raised as
-- possibly requiring one), this is declared as ONE schematic axiom,
-- `pilot-syntax-facts-v1`, over a new judgment operator `guard_selects`.
-- Every concrete instance (a claim like "at P0, the guard on path x selects
-- ty_of(tag_string), landing at P1 on a match") is an axiom CITATION built
-- by the untrusted prover (pilot step 4, not built here) — never asserted
-- as free content, never a hypothesis. This taints every derivation that
-- uses it with the named axiom key (`pilot-syntax-facts-v1@v1`) in its taint
-- set: honest and priced, exactly as the brief anticipated — "the parser is
-- trusted, priced." This is the reusable pattern for every future theory
-- that needs facts about source syntax: one schematic axiom per
-- syntax-observation judgment shape, cited (never hypothesized), taint
-- flowing normally through the existing mechanism. No kernel change.
--
-- ── `guard_selects`: one operator for all three guard forms in scope ────────
--
-- `guard_selects(guard_point, branch_point, var_path, target_ty) : judgment`
-- reads: "the guard evaluated at guard_point, when it selects target_ty for
-- var_path, transfers control to branch_point." This single shape covers
-- all three guard forms the design brief scoped the pilot to:
--   - `type(x) == "T"` / `type(x) ~= "T"`   — target_ty = ty_of(tag_T)
--   - `x == nil` / `x ~= nil`               — target_ty = ty_of(tag_nil)
--   - bare truthiness `if x then`           — target_ty = the falsy
--     composite ty_union(ty_of(tag_nil), ty_of(tag_false)) (proposal §2.2's
--     own "falsy" example)
-- Polarity (== vs ~=) and branch selection (then vs else) are NOT encoded in
-- the judgment or the rules at all — they are entirely the prover's choice
-- of which of the two rules below to cite, and which point (entry_of(then)
-- vs entry_of(else)) it binds as branch_point. This mirrors v3's own
-- `positive`/`in_truthy` XOR (lib/type/static/narrow.lua's
-- `apply_narrowing`), just relocated from a checked producer computation to
-- an untrusted prover CHOICE that the trusted rules structurally verify is
-- consistent with the actual type shape at the guard point (see below).
--
-- ── The two rules: peel one member off a binary union, either half ──────────
--
-- Both rules share the same two premises — a type fact at the guard's own
-- point, decomposed as a binary union, and a syntax fact naming which half
-- is the target — and differ only in which half the conclusion keeps:
--
--   narrow-select-match : holds_at(Pg,X,ty_union(TA,Rest)), guard_selects(Pg,Pb,X,TA)
--                         |- holds_at(Pb,X,TA)
--   narrow-select-rest  : holds_at(Pg,X,ty_union(TA,Rest)), guard_selects(Pg,Pb,X,TA)
--                         |- holds_at(Pb,X,Rest)
--
-- `TA` is a NON-LINEAR metavariable shared between both premises — the same
-- mechanism hm-app uses to force an argument's type to equal a function's
-- domain (core design doc, "Schematic instantiation"). This is what makes
-- the theory sound rather than a rubber stamp: a prover cannot cite
-- narrow-select-match with a `guard_selects` fact claiming target_ty = T
-- unless the ACTUAL type at the guard point is structurally
-- ty_union(T, something) — replay's match/merge_bindings rejects any
-- mismatch (the same "can't lie about content" property named in the core
-- design doc). Soundness of the source-level correspondence (does this
-- syntax fact really describe what the parser saw?) rests entirely on the
-- syntax-facts axiom being trustworthy — the named, priced, tainted
-- assumption above; the rules themselves add no further trust.
--
-- ── Why this needs no per-guard-kind rule variants, and no side condition ──
--
-- `Rest` is an unconstrained `ty` metavariable — it may itself be a
-- `ty_union`. Peeling one binary layer via narrow-select-rest and re-citing
-- the same rule against the resulting (still possibly-union) type is how
-- arbitrary-width unions are narrowed WITHOUT enumerating tag-count
-- combinations and WITHOUT any side-condition search: each individual rule
-- application only ever inspects one binary split, chosen by whichever half
-- the CITED rule's conclusion pattern names — the "search" for which member
-- matches the guard is entirely the untrusted prover's job when it shapes
-- the premise term (produces `ty_union` with the tested member positioned
-- so `guard_selects`'s target_ty binds structurally), never the trusted
-- rule's. Real-code check (grepped, not assumed): `| nil` appears ~6600
-- times across lib/, 3+-way unions only ~180 times — binary decomposition
-- with a possibly-union `Rest` covers the dominant real shape directly and
-- the minority multi-way case via repeated peeling, with no rule-set
-- explosion. Per the task brief's own explicit rule-shape sketch
-- (`holds_at(P_guard, X, ty_union(A, B))`), this is the SCOPED target, not
-- a limitation silently chosen here.
--
-- Explicit, flagged-not-halted scope limit (fable-delegation-tier, matching
-- the task's "narrowing over unions for the guard forms found in real code"
-- framing, not full generality): a guard over an already-monomorphic type
-- (the current fact is a bare `ty_of(tag)`, not a `ty_union`) does not match
-- either rule's premise shape — narrowing a redundant/trivially-true guard
-- is out of scope, not silently mishandled (replay simply rejects/does not
-- apply; the prover would not cite these rules in that case). No side
-- condition was needed for anything in the rule set actually built: no rule
-- here required search, arithmetic, or any check the schema language lacks
-- a slot for — HALT was not triggered.

local term_algebra = require("lib.type.v10_kernel.term_algebra")
local replayer = require("lib.type.v10_kernel.replayer")

local M = {}

--:: TermAlgebra = unknown
--:: Signature = { name: string, version: integer, sorts: { [string]: unknown }, sort_set: { [unknown]: boolean }, ops: { [string]: unknown } }
--:: Vocab = {
--::   signature: Signature,
--::   HoldsAt: (unknown, unknown, unknown) -> (unknown | nil, string | nil),
--::   TyOf: (unknown) -> (unknown | nil, string | nil),
--::   TyUnion: (unknown, unknown) -> (unknown | nil, string | nil),
--::   GuardSelects: (unknown, unknown, unknown, unknown) -> (unknown | nil, string | nil),
--::   tag_nil: () -> (unknown | nil, string | nil),
--::   tag_boolean: () -> (unknown | nil, string | nil),
--::   tag_true: () -> (unknown | nil, string | nil),
--::   tag_false: () -> (unknown | nil, string | nil),
--::   tag_number: () -> (unknown | nil, string | nil),
--::   tag_string: () -> (unknown | nil, string | nil),
--::   tag_table: () -> (unknown | nil, string | nil),
--::   tag_function: () -> (unknown | nil, string | nil),
--::   falsy_ty: () -> (unknown | nil, string | nil),
--::   ax_syntax_facts: unknown,
--::   rule_match: unknown,
--::   rule_rest: unknown,
--:: }

-- Declare the flow-narrowing theory's signature (`narrow-pilot-v1` v2) and
-- its rule/axiom vocabulary against a specific term_algebra tier instance
-- `k`, importing `point`/`path` from an already-declared addr-v1 signature.
-- Caps-clean: both `k` and `addr_sig` are injected, never reached for
-- ambiently (same pattern as hm.lua's declare_vocabulary and
-- narrow_pilot_v1.lua's declare).
--: (k: unknown, addr_sig: unknown) -> (Vocab | nil, string | nil)
function M.declare_vocabulary(k, addr_sig)
	if type(k) ~= "table" then return nil, "declare_vocabulary: k (a term_algebra instance) is required" end
	local kt = k --[[: { [string]: unknown } ]]
	if type(kt.build) ~= "function" or type(kt.build_meta) ~= "function" then
		return nil, "declare_vocabulary: k must be a term_algebra tier instance"
	end
	local kk = k --[[: { build: (unknown, unknown) -> (unknown | nil, string | nil), build_meta: (string, unknown) -> (unknown | nil, string | nil) } ]]
	local build = kk.build
	local build_meta = kk.build_meta

	if type(addr_sig) ~= "table" then
		return nil, "declare_vocabulary: addr_sig (a declared addr-v1 signature) is required"
	end
	local addr_sig_t = addr_sig --[[: Signature ]]
	local addr_sorts = addr_sig_t.sorts
	local point_sort = addr_sorts.point
	local path_sort = addr_sorts.path
	if not point_sort or not path_sort then
		return nil, "declare_vocabulary: addr_sig must declare point and path sorts"
	end

	local sig, sig_err = term_algebra.declare_signature({
		name = "narrow-pilot-v1",
		version = 2,
		sorts = { "prim_tag", "ty", "judgment" },
		imports = { point = point_sort, path = path_sort },
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

			-- Additive op beyond v1: the syntax-fact judgment shape (see
			-- header). guard_point/branch_point: point; var_path: path;
			-- target_ty: ty.
			guard_selects = {
				result = "judgment",
				args = {
					{ sort = "point" }, { sort = "point" }, { sort = "path" }, { sort = "ty" },
				},
			},
		},
	})
	if not sig then return nil, sig_err end
	local ops = sig.ops

	--: (p: unknown, x: unknown, ty: unknown) -> (unknown | nil, string | nil)
	local function HoldsAt(p, x, ty) return build(ops.holds_at, { p, x, ty }) end
	--: (tag: unknown) -> (unknown | nil, string | nil)
	local function TyOf(tag) return build(ops.ty_of, { tag }) end
	--: (a: unknown, b: unknown) -> (unknown | nil, string | nil)
	local function TyUnion(a, b) return build(ops.ty_union, { a, b }) end
	--: (pg: unknown, pb: unknown, x: unknown, ty: unknown) -> (unknown | nil, string | nil)
	local function GuardSelects(pg, pb, x, ty) return build(ops.guard_selects, { pg, pb, x, ty }) end

	--: () -> (unknown | nil, string | nil)
	local function tag_nil() return build(ops.tag_nil, {}) end
	--: () -> (unknown | nil, string | nil)
	local function tag_boolean() return build(ops.tag_boolean, {}) end
	--: () -> (unknown | nil, string | nil)
	local function tag_true() return build(ops.tag_true, {}) end
	--: () -> (unknown | nil, string | nil)
	local function tag_false() return build(ops.tag_false, {}) end
	--: () -> (unknown | nil, string | nil)
	local function tag_number() return build(ops.tag_number, {}) end
	--: () -> (unknown | nil, string | nil)
	local function tag_string() return build(ops.tag_string, {}) end
	--: () -> (unknown | nil, string | nil)
	local function tag_table() return build(ops.tag_table, {}) end
	--: () -> (unknown | nil, string | nil)
	local function tag_function() return build(ops.tag_function, {}) end

	-- The proposal's own "falsy" composite (§2.2): ty_union(nil, false).
	-- Conventionally kept as a single unit and, when part of a larger union,
	-- positioned as the operand a truthiness guard's `guard_selects` binds
	-- directly (a prover-side shaping convention, not a kernel rule — see
	-- header's "no reordering needed" note).
	--: () -> (unknown | nil, string | nil)
	local function falsy_ty() return TyUnion(TyOf(tag_nil()), TyOf(tag_false())) end

	--: (id: string) -> (unknown | nil, string | nil)
	local function meta_point(id) return build_meta(id, sig.sorts.point) end
	--: (id: string) -> (unknown | nil, string | nil)
	local function meta_path(id) return build_meta(id, sig.sorts.path) end
	--: (id: string) -> (unknown | nil, string | nil)
	local function meta_ty(id) return build_meta(id, sig.sorts.ty) end

	local pg, pb, x, ta, rest = meta_point("Pg"), meta_point("Pb"), meta_path("X"), meta_ty("TA"), meta_ty("Rest")
	if not pg or not pb or not x or not ta or not rest then
		return nil, "declare_vocabulary: failed to build shared metavariables"
	end

	local union_ta_rest = TyUnion(ta, rest)
	if not union_ta_rest then return nil, "declare_vocabulary: failed to build ty_union(TA,Rest) pattern" end
	local holds_guard = HoldsAt(pg, x, union_ta_rest)
	local fact = GuardSelects(pg, pb, x, ta)
	if not holds_guard or not fact then return nil, "declare_vocabulary: failed to build shared premise patterns" end

	local ax_syntax_facts, ax_err = replayer.declare_axiom({
		name = "pilot-syntax-facts-v1", version = 1, signature = sig,
		pattern = fact,
	})
	if not ax_syntax_facts then return nil, ax_err end

	local holds_match = HoldsAt(pb, x, ta)
	if not holds_match then return nil, "declare_vocabulary: failed to build narrow-select-match conclusion" end
	local rule_match, match_err = replayer.declare_rule({
		name = "narrow-select-match", version = 1, signature = sig,
		premises = { holds_guard, fact },
		conclusion = holds_match,
	})
	if not rule_match then return nil, match_err end

	local holds_rest = HoldsAt(pb, x, rest)
	if not holds_rest then return nil, "declare_vocabulary: failed to build narrow-select-rest conclusion" end
	local rule_rest, rest_err = replayer.declare_rule({
		name = "narrow-select-rest", version = 1, signature = sig,
		premises = { holds_guard, fact },
		conclusion = holds_rest,
	})
	if not rule_rest then return nil, rest_err end

	return {
		signature = sig,
		HoldsAt = HoldsAt, TyOf = TyOf, TyUnion = TyUnion, GuardSelects = GuardSelects,
		tag_nil = tag_nil, tag_boolean = tag_boolean, tag_true = tag_true, tag_false = tag_false,
		tag_number = tag_number, tag_string = tag_string, tag_table = tag_table, tag_function = tag_function,
		falsy_ty = falsy_ty,
		ax_syntax_facts = ax_syntax_facts,
		rule_match = rule_match,
		rule_rest = rule_rest,
	}
end

return M
