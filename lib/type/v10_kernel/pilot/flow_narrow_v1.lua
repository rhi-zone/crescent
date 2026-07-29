-- lib/type/v10_kernel/pilot/flow_narrow_v1.lua
--
-- Flow-narrowing THEORY — pilot step 3
-- (docs/decisions/typechecker-v10-core-design.md, "Pilot: flow-narrowing on
-- the kernel — plan of record", item 3; docs/typechecker-v10-pilot-
-- signatures-proposal.md). Rule schemas over addr-v1 (program-point
-- addressing, pilot/addr_v1.lua) and a version-2 extension of
-- narrow-pilot-v1 (pilot type vocabulary, pilot/narrow_pilot_v1.lua).
-- Declared over the canonical v10 core (lib/type/v10_cleanroom/, per the
-- owner-ratified canon swap).
--
-- fable-delegation-tier throughout (per the core design's pilot-execution
-- delegation note): every choice here is a delegated-execution decision,
-- re-openable on challenge, not an owner ratification.
--
-- ── Why a v2 signature, not a fresh one ─────────────────────────────────────
--
-- A narrowing rule's premises need `holds_at`/`ty_union`/`ty_of`/`tag_*`
-- (narrow-pilot-v1's own ops) AND a new "syntax fact" operator (below) in
-- the SAME pattern — operators, unlike sorts, are never imported across
-- signatures, so the new operator must be declared inside one signature
-- alongside the ops it composes with. Per the core design doc's versioning
-- discipline, this module declares `{ name = "narrow-pilot-v1",
-- version = 2 }`: literally the v1 op set, unchanged, plus one additive
-- op. Object identity is name+version, so this is a wholly independent
-- declared signature from v1's — v1's own module and tests are untouched.
--
-- ── The reality-boundary question: how do syntax facts enter a derivation ──
--
-- The rules below need a premise like "the guard at this point tests
-- whether path X's value belongs to type T, and the branch reached on a
-- match starts at that other point" — a fact about what the PARSER saw in
-- the source file. Nothing in the kernel can derive this. Per the ratified
-- schematic-axiom mechanism, this is declared as ONE schematic axiom,
-- `pilot-syntax-facts-v1`, over a new judgment operator `guard_selects`.
-- Every concrete instance is an axiom CITATION built by the untrusted
-- prover — never asserted as free content, never a hypothesis. This taints
-- every derivation that uses it with the axiom's citation key in its taint
-- set: honest and priced ("the parser is trusted, priced"). This is the
-- reusable pattern for every future theory that needs facts about source
-- syntax. No kernel change.
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
--     composite ty_union(ty_of(tag_nil), ty_of(tag_false))
-- Polarity (== vs ~=) and branch selection (then vs else) are NOT encoded
-- in the judgment or the rules at all — they are entirely the prover's
-- choice of which of the two rules below to cite, and which point it binds
-- as branch_point.
--
-- ── The two rules: peel one member off a binary union, either half ──────────
--
--   narrow-select-match : holds_at(Pg,X,ty_union(TA,Rest)), guard_selects(Pg,Pb,X,TA)
--                         |- holds_at(Pb,X,TA)
--   narrow-select-rest  : holds_at(Pg,X,ty_union(TA,Rest)), guard_selects(Pg,Pb,X,TA)
--                         |- holds_at(Pb,X,Rest)
--
-- `TA` is a NON-LINEAR metavariable shared between both premises — the same
-- mechanism hm-app uses to force an argument's type to equal a function's
-- domain. This is what makes the theory sound rather than a rubber stamp:
-- a prover cannot cite narrow-select-match with a `guard_selects` fact
-- claiming target_ty = T unless the ACTUAL type at the guard point is
-- structurally ty_union(T, something) — replay's shared-environment match
-- rejects any mismatch (the "can't lie about content" property).
-- Soundness of the source-level correspondence rests entirely on the
-- syntax-facts axiom being trustworthy — the named, priced, tainted
-- assumption above; the rules themselves add no further trust.
--
-- ── Why this needs no per-guard-kind rule variants, and no side condition ──
--
-- `Rest` is an unconstrained `ty` metavariable — it may itself be a
-- `ty_union`. Peeling one binary layer via narrow-select-rest and re-citing
-- the same rule against the resulting (still possibly-union) type is how
-- arbitrary-width unions are narrowed WITHOUT enumerating tag-count
-- combinations and WITHOUT any side-condition search. Real-code check
-- (grepped, not assumed): `| nil` appears ~6600 times across lib/, 3+-way
-- unions only ~180 times — binary decomposition with a possibly-union
-- `Rest` covers the dominant real shape directly.
--
-- Explicit, flagged-not-halted scope limit (fable-delegation-tier): a guard
-- over an already-monomorphic type (a bare `ty_of(tag)`, not a `ty_union`)
-- does not match either rule's premise shape — narrowing a redundant/
-- trivially-true guard is out of scope, not silently mishandled. No side
-- condition was needed for anything in the rule set actually built — HALT
-- was not triggered.

local ta = require("lib.type.v10_cleanroom.term_algebra")
local replayer = require("lib.type.v10_cleanroom.replayer")

local M = {}

--:: NarrowVocab = {
--::   signature: Signature,
--::   HoldsAt: (p: Term, x: Term, ty: Term) -> (Term | nil, string | nil),
--::   TyOf: (tag: Term) -> (Term | nil, string | nil),
--::   TyUnion: (a: Term, b: Term) -> (Term | nil, string | nil),
--::   GuardSelects: (pg: Term, pb: Term, x: Term, ty: Term) -> (Term | nil, string | nil),
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
--:: }

-- Declare the flow-narrowing theory's signature (`narrow-pilot-v1` v2) into
-- the given registry, importing `point`/`path` from an already-declared
-- addr-v1 signature. Caps-clean: both `registry` and `addr_sig` are
-- injected, never reached for ambiently (same pattern as hm.lua's
-- declare_vocabulary). Call once per registry ((name, version) unique per
-- registry, F11).
-- `addr_sig` is typed `unknown` and narrowed by hand: a `type(x) ~=
-- "table"` guard on an already-record-typed parameter widens the else
-- branch back to `unknown` (the same typechecker gotcha the pre-swap file
-- documented), so the runtime guard runs on `unknown` and a checked cast
-- restores the shape.
--: (registry: Registry, addr_sig: unknown) -> (NarrowVocab | nil, string | nil)
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
		version = 2,
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

	--: (p: Term, x: Term, ty: Term) -> (Term | nil, string | nil)
	local function HoldsAt(p, x, ty) return ta.build(ops.holds_at, { p, x, ty }) end
	--: (tag: Term) -> (Term | nil, string | nil)
	local function TyOf(tag) return ta.build(ops.ty_of, { tag }) end
	--: (a: Term, b: Term) -> (Term | nil, string | nil)
	local function TyUnion(a, b) return ta.build(ops.ty_union, { a, b }) end
	--: (pg: Term, pb: Term, x: Term, ty: Term) -> (Term | nil, string | nil)
	local function GuardSelects(pg, pb, x, ty) return ta.build(ops.guard_selects, { pg, pb, x, ty }) end

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

	-- The proposal's own "falsy" composite (§2.2): ty_union(nil, false).
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

	local pg = ta.meta("Pg", sig.sorts.point)
	local pb = ta.meta("Pb", sig.sorts.point)
	local x = ta.meta("X", sig.sorts.path)
	local ta_meta = ta.meta("TA", sig.sorts.ty)
	local rest = ta.meta("Rest", sig.sorts.ty)
	if not pg or not pb or not x or not ta_meta or not rest then
		return nil, "declare_vocabulary: failed to build shared metavariables"
	end

	local union_ta_rest = TyUnion(ta_meta, rest)
	if not union_ta_rest then return nil, "declare_vocabulary: failed to build ty_union(TA,Rest) pattern" end
	local holds_guard = HoldsAt(pg, x, union_ta_rest)
	local fact = GuardSelects(pg, pb, x, ta_meta)
	if not holds_guard or not fact then return nil, "declare_vocabulary: failed to build shared premise patterns" end

	local ax_syntax_facts, ax_err = replayer.declare_axiom(registry, {
		name = "pilot-syntax-facts-v1", version = 1,
		pattern = fact,
	})
	if not ax_syntax_facts then return nil, ax_err end

	local holds_match = HoldsAt(pb, x, ta_meta)
	if not holds_match then return nil, "declare_vocabulary: failed to build narrow-select-match conclusion" end
	local rule_match, match_err = replayer.declare_rule(registry, {
		name = "narrow-select-match", version = 1,
		premises = { holds_guard, fact },
		conclusion = holds_match,
	})
	if not rule_match then return nil, match_err end

	local holds_rest = HoldsAt(pb, x, rest)
	if not holds_rest then return nil, "declare_vocabulary: failed to build narrow-select-rest conclusion" end
	local rule_rest, rest_err = replayer.declare_rule(registry, {
		name = "narrow-select-rest", version = 1,
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
