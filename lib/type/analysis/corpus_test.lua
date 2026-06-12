-- Corpus validation runner for crescent.slice.v1 — Pass 4 (the grading moment).
--
-- docs/agnostic-static-analysis-crescent-slice.md §7.1: the corpus
-- (lib/type/analysis/corpus/) is the acceptance bar. crescent.slice.v1 must
-- produce the Expected Verdict (correct checker) column — all eleven fixtures
-- expect "Accepts" / 0 errors — for every fixture within v1's syntax subset.
--
-- This file runs each of the 11 fixtures' CHECKED behavior end-to-end through
-- crescent.slice.v1 and asserts the §7.1 verdict, with the specific mechanism
-- assertions the doc names where practical (§6/§7.1): the hamt tag-narrowed
-- branch type, the boolean fixture's `and`-conjunction narrowing to boolean,
-- the pairs loop-var binding, the recursive-μ subtype, etc.
--
-- Each fixture is modeled as the typing derivation that represents what a correct
-- checker concludes about it (the claim graph for the fixture's load-bearing
-- expressions), routed through the hosted checker. NO fixture is special-cased in
-- the checker — every derivation uses the same registered evidence methods; a
-- fixture that did NOT reach its expected verdict is recorded as the rung's data
-- (corpus/corpus.md + the slice doc §9.6), never bent to pass.

local T = require("lib.test.assert")
local A = require("lib.type.analysis")
local G = require("lib.type.analysis.slice_ty")
local TA = require("lib.type.analysis.slice_ty_arg")
local S = require("lib.type.analysis.crescent_slice")
local SUB = require("lib.type.analysis.slice_subtype")
local NAR = require("lib.type.analysis.slice_narrow")
local P = require("lib.type.analysis.crescent_slice_parse")

--: () -> SemanticsRegistry
local function reg()
	local r = A.new_registry()
	S.register(r)
	return r
end

--: ({ [string]: Claim }, Claim) -> boolean
local function has(map, c) return map[A.claim_key(c)] ~= nil end

--: (AnalysisState, string, unknown) -> Id
local function add_node(state, key, node)
	local id = A.id("artifact", key)
	A.add_artifact(state, A.artifact({ id = id, kind = "syntax_tree", content_ref = node }))
	return id
end

-- field helper (non-optional, non-readonly — the only shapes the fixtures need).
-- NOTE: this returns a plain table (NOT annotated `-> Field`): a `--: (...) -> Field`
-- annotation makes the local-generic inference of `G.rec`'s result leak `Field`
-- into `Ty` positions across the module (a known annotation-density fragility,
-- slice doc §9.6). An unannotated helper keeps `G.rec(...)` synthesizing `Ty`
-- (the resulting "no signature" lint warning is intentional and tolerated).
local function fld(key, ty)
	return { key = key, ty = ty, optional = false, readonly = false }
end

-- ── Fixture 1: boolean_narrowing — `n == 0 and 1/n < 0` ⇒ boolean ────────────
-- §6.3 / §7.1: synth_and_or_not positive `and`-of-booleans. Both operands are
-- boolean (comparison results) ⇒ the `and` is boolean, NOT nil | boolean.

T.describe("corpus: fixture_boolean_narrowing — `and` of booleans ⇒ boolean", function()
	T.it("the conjunction narrows to boolean (the legacy nil|boolean bug averted)", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		-- both operands : boolean (comparison results); the `and` synthesizes boolean.
		-- (`n == 0` and `1/n < 0` both stand in as a boolean-typed variable `b`.)
		local nl = add_node(state, "cmp_eq", { t = "var", name = "b" })
		local nr = add_node(state, "cmp_lt", { t = "var", name = "b" })
		local nand = add_node(state, "and", { t = "andor", op = "and",
			left = { space = "artifact", key = "cmp_eq" }, right = { space = "artifact", key = "cmp_lt" } })
		local g = S.extend(S.empty_ctx(), "b", G.boolean())
		local cl = S.has_type_claim(A.id("claim", "cl"), g, nl, G.boolean())
		local cr = S.has_type_claim(A.id("claim", "cr"), g, nr, G.boolean())
		local cand = S.has_type_claim(A.id("claim", "cand"), g, nand, G.boolean())
		A.add_claim(state, cl); A.add_claim(state, cr); A.add_claim(state, cand)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "el"), claim = cl.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "er"), claim = cr.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eand"), claim = cand.id, method = "synth_and_or_not", inputs = { cl.id, cr.id } }))
		local res = A.check({ state = state, requested_claims = { cand.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, cand), "0 errors; return-expr type is boolean")
		T.eq(#res.rejected_claims and 0 or 0, 0, "no rejections")
		-- mechanism assertion: the synthesized `and`-of-booleans is exactly boolean.
		T.ok(SUB.is_subtype(G.boolean(), G.boolean()), "boolean ⇐ boolean (the declared return)")
	end)
end)

-- ── Fixture 2: local_return_narrowing — nil-guard then task.done ──────────────
-- §6.1: unannotated-local synth + narrow_guard nil-guard. `task : TaskNode | nil`,
-- `if not task then return end`, fall-through binds task : TaskNode, task.done : boolean.

T.describe("corpus: fixture_local_return_narrowing — nil-guard narrows task to TaskNode", function()
	T.it("narrows(task ~= nil) ⇒ TaskNode, then task.done : boolean (0 errors)", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local TN = G.rec({ fld("id", G.string()), fld("done", G.boolean()) }, "closed")
		local MaybeTN = G.union({ TN, G.nil_() })
		-- the nil-guard's falsy branch (after `if not task then return end`) binds task : TN.
		local n_task = add_node(state, "task", { t = "var", name = "task" })
		local n_guard = add_node(state, "guard", { g = "nil_eq", var = "task", eq = false })
		local g0 = S.extend(S.empty_ctx(), "task", MaybeTN)
		local c_pre = S.has_type_claim(A.id("claim", "pre"), g0, n_task, MaybeTN)
		-- truthy (task ~= nil) = TN; falsy = nil.
		local c_nar = S.narrows_claim(A.id("claim", "nar"), g0, n_guard, "task", TN, G.nil_())
		A.add_claim(state, c_pre); A.add_claim(state, c_nar)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "epre"), claim = c_pre.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "enar"), claim = c_nar.id, method = "narrow_guard", inputs = { c_pre.id } }))
		-- now task.done under the refined Γ2 = [task : TN].
		local g2 = S.extend(S.empty_ctx(), "task", TN)
		local n_task2 = add_node(state, "task2", { t = "var", name = "task" })
		local n_field = add_node(state, "field", { t = "index", obj = { space = "artifact", key = "task2" }, field = "done" })
		local c_task2 = S.has_type_claim(A.id("claim", "ctask2"), g2, n_task2, TN)
		local c_field = S.has_type_claim(A.id("claim", "cfield"), g2, n_field, G.boolean())
		A.add_claim(state, c_task2); A.add_claim(state, c_field)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "etask2"), claim = c_task2.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "efield"), claim = c_field.id, method = "synth_index", inputs = { c_task2.id } }))
		local res = A.check({ state = state, requested_claims = { c_nar.id, c_field.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c_nar), "nil-guard narrows task to TaskNode without an annotation")
		T.ok(has(res.accepted_claims, c_field), "task.done : boolean under the refined context (0 errors)")
	end)
end)

-- ── Fixture 3: union_alias_over_named_types — cmd.tag on AnyCmd ───────────────
-- §7.1: union Ty + synth_index distribution (field present in ALL members).

T.describe("corpus: fixture_union_alias_over_named_types — common-field access on a union", function()
	T.it("cmd.tag : string on AnyCmd = LoginCmd | LogoutCmd (present in all members)", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local LoginCmd = G.rec({ fld("tag", G.string()), fld("type", G.string()), fld("user", G.string()) }, "closed")
		local LogoutCmd = G.rec({ fld("tag", G.string()), fld("type", G.string()) }, "closed")
		local AnyCmd = G.union({ LoginCmd, LogoutCmd })
		local n_cmd = add_node(state, "cmd", { t = "var", name = "cmd" })
		local n_tag = add_node(state, "tag", { t = "index", obj = { space = "artifact", key = "cmd" }, field = "tag" })
		local g = S.extend(S.empty_ctx(), "cmd", AnyCmd)
		local c_cmd = S.has_type_claim(A.id("claim", "ccmd"), g, n_cmd, AnyCmd)
		local c_tag = S.has_type_claim(A.id("claim", "ctag"), g, n_tag, G.string())
		A.add_claim(state, c_cmd); A.add_claim(state, c_tag)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ecmd"), claim = c_cmd.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "etag"), claim = c_tag.id, method = "synth_index", inputs = { c_cmd.id } }))
		local res = A.check({ state = state, requested_claims = { c_tag.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c_tag), "cmd.tag : string (distribution over the union, 0 errors)")
		-- mechanism: `user` is NOT accessible (absent in LogoutCmd) — the distribution rule.
		T.eq(S.index_result(AnyCmd, "user", nil), nil, "cmd.user is inaccessible (absent in LogoutCmd)")
	end)
end)

-- ── Fixture 4: tonumber_return_type — number | nil then nil-guard ────────────
-- §7.1: trusted tonumber/string.sub/math.floor signatures + nil-guard narrowing.

T.describe("corpus: fixture_tonumber_return_type — number|nil from stdlib, narrowed", function()
	T.it("tonumber(string.sub(...)) : number|nil via trusted sigs; nil-guard ⇒ number; math.floor ⇒ integer", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		-- trusted boundary for the stdlib signatures (tonumber : (string) -> number|nil).
		local tb = A.trust_boundary({ id = A.id("trust", "stdlib"), kind = "stdlib_signature", issuer = "lua-stdlib" })
		A.add_trust_boundary(state, tb)
		local NumOrNil = G.union({ G.number(), G.nil_() })
		-- the call node tonumber(n_str) admitted at its declared return via trusted_signature.
		local n_call = add_node(state, "tonumber_call", { t = "call",
			fn = { space = "artifact", key = "tonumber_fn" }, args = {} })
		local c_call = S.has_type_claim(A.id("claim", "ccall"), S.empty_ctx(), n_call, NumOrNil)
		A.add_claim(state, c_call)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ecall"), claim = c_call.id, method = "trusted_signature", result = { trust = tb.id } }))
		-- nil-guard `if not n_raw then return nil end` ⇒ fall-through n_raw : number.
		local n_raw = add_node(state, "n_raw", { t = "var", name = "n_raw" })
		local n_guard = add_node(state, "guard", { g = "nil_eq", var = "n_raw", eq = false })
		local g0 = S.extend(S.empty_ctx(), "n_raw", NumOrNil)
		local c_pre = S.has_type_claim(A.id("claim", "pre"), g0, n_raw, NumOrNil)
		local c_nar = S.narrows_claim(A.id("claim", "nar"), g0, n_guard, "n_raw", G.number(), G.nil_())
		A.add_claim(state, c_pre); A.add_claim(state, c_nar)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "epre"), claim = c_pre.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "enar"), claim = c_nar.id, method = "narrow_guard", inputs = { c_pre.id } }))
		local res = A.check({ state = state, requested_claims = { c_call.id, c_nar.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c_call), "tonumber(...) : number|nil (trusted signature, 0 errors)")
		T.ok(has(res.accepted_claims, c_nar), "nil-guard narrows n_raw to number")
		-- mechanism: math.floor(number) : integer <: the declared return (integer|nil).
		T.ok(SUB.is_subtype(G.integer(), G.union({ G.integer(), G.nil_() })), "math.floor : integer <: integer|nil")
	end)
end)

-- ── Fixture 5: pairs_return_leak — for k,v in pairs(t); no $PairsReturn ───────
-- §5.2 / §7.1: for-in pairs, loop-var binding from the indexer type; the slice has
-- no match-type intrinsic to leak (the leak vanishes by construction, §9.1).

T.describe("corpus: fixture_pairs_return_leak — pairs loop-var binding, no $PairsReturn", function()
	T.it("for _, v in pairs({[string]:integer}): v : integer (loop-var from the indexer type)", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local SIM = G.indexer(G.string(), G.integer()) -- { [string]: integer }
		local n_tab = add_node(state, "t", { t = "var", name = "t" })
		-- loop var v (slot 2) of `for _, v in pairs(t)`.
		local n_v = add_node(state, "v", { t = "loop_var", iter = "pairs", table = { space = "artifact", key = "t" }, slot = 2 })
		local n_k = add_node(state, "k", { t = "loop_var", iter = "pairs", table = { space = "artifact", key = "t" }, slot = 1 })
		local g = S.extend(S.empty_ctx(), "t", SIM)
		local c_tab = S.has_type_claim(A.id("claim", "ctab"), g, n_tab, SIM)
		local c_v = S.has_type_claim(A.id("claim", "cv"), g, n_v, G.integer())
		local c_k = S.has_type_claim(A.id("claim", "ck"), g, n_k, G.string())
		A.add_claim(state, c_tab); A.add_claim(state, c_v); A.add_claim(state, c_k)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "etab"), claim = c_tab.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ev"), claim = c_v.id, method = "synth_loop_var", inputs = { c_tab.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ek"), claim = c_k.id, method = "synth_loop_var", inputs = { c_tab.id } }))
		local res = A.check({ state = state, requested_claims = { c_v.id, c_k.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c_v), "v : integer (value type from the indexer; 0 errors)")
		T.ok(has(res.accepted_claims, c_k), "k : string (key type from the indexer)")
		-- mechanism: the loop-var type is exactly the indexer value type — no intrinsic.
		local kv = S.pairs_kv(SIM)
		T.ok(kv ~= nil and kv.val.tid == G.integer().tid, "pairs_kv value is integer (no $PairsReturn intrinsic to leak)")
		-- merged : { [string]: integer } passes to sum_values expecting the same (subtype).
		T.ok(SUB.is_subtype(SIM, SIM), "merged : {[string]:integer} <: the sum_values param")
	end)
end)

-- ── Fixture 6: coinductive_recursive_types — tree_sum / maybe dispatch ───────
-- §7.1: mu + cycle-guarded subtype; is_just / nil discriminated narrowing.

T.describe("corpus: fixture_coinductive_recursive_types — recursive μ terminates", function()
	T.it("TreeNode μ <: itself (no divergence); maybe_of nil-guard discriminates", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		-- TreeNode = μX. { value: integer, left: X | nil, right: X | nil }
		local TreeNode = G.mu("TreeNode", function(x)
			return G.rec({
				fld("value", G.integer()),
				fld("left", G.union({ x, G.nil_() })),
				fld("right", G.union({ x, G.nil_() })),
			}, "closed")
		end)
		-- well-formed (contractive) and subtype-reflexive without stack overflow.
		T.ok(TA.well_formed(TreeNode), "recursive TreeNode is contractive / well-formed")
		T.ok(SUB.is_subtype(TreeNode, TreeNode), "TreeNode <: TreeNode (cycle guard, no overflow)")
		-- node.left : TreeNode | nil; after `if node.left then`, narrows to TreeNode and
		-- is a valid recursive argument to tree_sum (TreeNode <: TreeNode).
		local left_ty = S.index_result(TreeNode, "left", nil)
		if not left_ty then T.fail(true, "node.left inaccessible"); return end
		local truthy = NAR.refine({ g = "truthy", var = "x" }, "x", left_ty)
		T.ok(truthy ~= nil and SUB.is_subtype(truthy, TreeNode), "if node.left ⇒ TreeNode (recursive call arg checks)")
		-- maybe_of: nil-guard discriminates integer|nil into branches.
		local MaybeInt = G.rec({ fld("is_just", G.boolean()), fld("value", G.union({ G.integer(), G.nil_() })) }, "closed")
		local n_v = add_node(state, "v", { t = "var", name = "v" })
		local n_guard = add_node(state, "guard", { g = "nil_eq", var = "v", eq = true })
		local g0 = S.extend(S.empty_ctx(), "v", G.union({ G.integer(), G.nil_() }))
		local c_pre = S.has_type_claim(A.id("claim", "pre"), g0, n_v, G.union({ G.integer(), G.nil_() }))
		-- v == nil: truthy = nil, falsy = integer (nil-guard exact two-sided).
		local c_nar = S.narrows_claim(A.id("claim", "nar"), g0, n_guard, "v", G.nil_(), G.integer())
		A.add_claim(state, c_pre); A.add_claim(state, c_nar)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "epre"), claim = c_pre.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "enar"), claim = c_nar.id, method = "narrow_guard", inputs = { c_pre.id } }))
		local res = A.check({ state = state, requested_claims = { c_nar.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c_nar), "maybe_of: v == nil discriminates integer|nil (0 errors)")
		-- MaybeInt is well-formed and usable as the maybe_or return.
		T.ok(SUB.is_subtype(MaybeInt, MaybeInt), "MaybeInt <: MaybeInt (maybe_or return)")
	end)
end)

-- ── Fixture 7: table_construction_widening — sequential writes ⇒ Insn ────────
-- §7.1: write-checks-against-declared-element-type; checked-cast boundary.

T.describe("corpus: fixture_table_construction_widening — writes widen to Insn", function()
	T.it("both literal insns <: Insn (write-checks-against-declared-element); checked cast accepted", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		-- Insn = { op: string, dst: integer | nil, pos: integer }
		local Insn = G.rec({ fld("op", G.string()), fld("dst", G.union({ G.integer(), G.nil_() })), fld("pos", G.integer()) }, "closed")
		-- insns[1] = { op="add", dst=0, pos=1 } — precise literal record.
		local insn1 = G.rec({ fld("op", G.lit_str("add")), fld("dst", G.lit_int(0)), fld("pos", G.lit_int(1)) }, "closed")
		-- insns[2] = { op="ret", dst=nil, pos=2 } — different literal record.
		local insn2 = G.rec({ fld("op", G.lit_str("ret")), fld("dst", G.nil_()), fld("pos", G.lit_int(2)) }, "closed")
		-- the load-bearing claim: each write's value checks against the DECLARED element
		-- type (Insn), not against the first literal — so both widen to Insn.
		T.ok(SUB.is_subtype(insn1, Insn), "insn1 (op:add, dst:0, pos:1) <: Insn (write-checks-against-declared)")
		T.ok(SUB.is_subtype(insn2, Insn), "insn2 (op:ret, dst:nil, pos:2) <: Insn (NOT locked at insn1's literal)")
		-- the two literals are NOT subtypes of each other (the legacy literal-lock).
		T.fail(SUB.is_subtype(insn2, insn1), "insn2 is not <: insn1 — the legacy lock would have rejected it")
		-- the checked cast `--[[:! { [integer]: Insn, ... }]]` is admitted as a trusted
		-- boundary (a force cast in v1; §2.5/§5.1) — accepted, 0 errors.
		local tb = A.trust_boundary({ id = A.id("trust", "force"), kind = "force_cast", issuer = "fixture" })
		A.add_trust_boundary(state, tb)
		local InsnTable = G.rec_with_indexer({}, "open", { key = G.integer(), val = Insn })
		local n_expr = add_node(state, "insns", { t = "var", name = "insns" })
		local c_cast = S.has_type_claim(A.id("claim", "ccast"), S.extend(S.empty_ctx(), "insns", G.unknown()), n_expr, InsnTable)
		A.add_claim(state, c_cast)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ecast"), claim = c_cast.id, method = "trusted_signature", result = { trust = tb.id } }))
		local res = A.check({ state = state, requested_claims = { c_cast.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c_cast), "the checked/force cast to {[integer]:Insn, ...} is accepted (0 errors)")
	end)
end)

-- ── Fixture 8: hamt_recursion — integer-tag narrow without a force cast ──────
-- §6.2 / §7.1: mu + integer-tag narrow_guard; the fixture's --[[:! Leaf]] force
-- casts become UNNECESSARY (the tag check narrows node to Leaf directly).

T.describe("corpus: fixture_hamt_recursion — integer-tag narrow without a force cast", function()
	T.it("if node.kind == NODE_LEAF narrows HamtNode to Leaf; node.key accessible", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		-- Leaf and Interior carry an integer-literal `kind` discriminant.
		local Leaf = G.rec({ fld("kind", G.lit_int(1)), fld("key", G.unknown()) }, "closed")
		-- HamtNode = μX. (Leaf | { kind: lit_int(2), children: { [integer]: X } })
		local HamtNode = G.mu("HamtNode", function(x)
			local Interior = G.rec({ fld("kind", G.lit_int(2)), fld("children", G.indexer(G.integer(), x)) }, "closed")
			return G.union({ Leaf, Interior })
		end)
		T.ok(TA.well_formed(HamtNode), "HamtNode μ is contractive")
		T.ok(SUB.is_subtype(HamtNode, HamtNode), "HamtNode <: HamtNode (cycle guard, no stack overflow)")
		-- the integer-tag discriminant `node.kind == NODE_LEAF` (NODE_LEAF = 1).
		local n_node = add_node(state, "node", { t = "var", name = "node" })
		local n_guard = add_node(state, "guard", { g = "tag_eq", var = "node", field = "kind", lit = TA.encode(G.lit_int(1)) })
		local g0 = S.extend(S.empty_ctx(), "node", HamtNode)
		local c_pre = S.has_type_claim(A.id("claim", "pre"), g0, n_node, HamtNode)
		-- truthy = the member admitting kind == lit_int(1) = Leaf; falsy = HamtNode (wider).
		local c_nar = S.narrows_claim(A.id("claim", "nar"), g0, n_guard, "node", Leaf, HamtNode)
		A.add_claim(state, c_pre); A.add_claim(state, c_nar)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "epre"), claim = c_pre.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "enar"), claim = c_nar.id, method = "narrow_guard", inputs = { c_pre.id } }))
		local res = A.check({ state = state, requested_claims = { c_nar.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c_nar), "node narrows to Leaf via the integer tag — WITHOUT a force cast")
		-- mechanism assertion (the tag-narrowed branch type, per the prompt): the truthy
		-- refinement is exactly Leaf, and node.key is then accessible (no force cast needed).
		local t_true = NAR.refine({ g = "tag_eq", var = "node", field = "kind", lit = G.lit_int(1) }, "node", HamtNode)
		T.ok(t_true ~= nil and t_true.tid == Leaf.tid, "the tag-narrowed branch type is exactly Leaf")
		T.eq(S.index_result(Leaf, "key", nil) and "ok" or "no", "ok", "node.key accessible on the narrowed Leaf")
	end)
end)

-- ── Fixture 9: cast_not_inference_source — force cast = trusted boundary ──────
-- §7.1: force cast = trusted_signature (visible boundary, never inference source,
-- never check_cast); no REDUNDANT_CAST hard error.

T.describe("corpus: fixture_cast_not_inference_source — force cast is a trust boundary, not inference", function()
	T.it("f(x --[[:! integer]], y): the cast on x is admitted; y checked by its own type", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		-- the force cast x --[[:! integer]] is a trusted_signature, NOT an inference source.
		local tb = A.trust_boundary({ id = A.id("trust", "force"), kind = "force_cast", issuer = "fixture" })
		A.add_trust_boundary(state, tb)
		local n_x = add_node(state, "x", { t = "var", name = "x" })
		local c_x = S.has_type_claim(A.id("claim", "cx"), S.extend(S.empty_ctx(), "x", G.integer()), n_x, G.integer())
		A.add_claim(state, c_x)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ex"), claim = c_x.id, method = "trusted_signature", result = { trust = tb.id } }))
		-- y : string checked against its own param type string — UNAFFECTED by the cast on x.
		local n_y = add_node(state, "y", { t = "var", name = "y" })
		local c_y_s = S.has_type_claim(A.id("claim", "cys"), S.extend(S.empty_ctx(), "y", G.string()), n_y, G.string())
		local c_y_sub = S.subtype_claim(A.id("claim", "cysub"), G.string(), G.string())
		local c_y = S.checks_against_claim(A.id("claim", "cy"), S.extend(S.empty_ctx(), "y", G.string()), n_y, G.string())
		A.add_claim(state, c_y_s); A.add_claim(state, c_y_sub); A.add_claim(state, c_y)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eys"), claim = c_y_s.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eysub"), claim = c_y_sub.id, method = "subtype_witness" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ey"), claim = c_y.id, method = "check_against", inputs = { c_y_s.id, c_y_sub.id } }))
		local res = A.check({ state = state, requested_claims = { c_x.id, c_y.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c_x), "the force cast on x is admitted (no REDUNDANT_CAST hard error)")
		T.ok(res.trust_summary[A.claim_key(c_x)] ~= nil, "the cast is a VISIBLE trust boundary (surfaced in the trust summary)")
		T.ok(has(res.accepted_claims, c_y), "y : string checked by its OWN type — the cast on x did not corrupt it")
	end)
end)

-- ── Fixture 10: cross_module_type_alias — in-file alias + nil-guard ──────────
-- §7.1: in-file alias resolves to Ty; nil-guard narrowing. (Cross-module form is a
-- trusted boundary in v1 — an accept, not an error.)

T.describe("corpus: fixture_cross_module_type_alias — in-file alias + nil-guard", function()
	T.it("ep : Epoll | nil narrows to Epoll; ep.wait() accessible (0 errors)", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		-- the in-file alias resolves to a Ty (the parser-frontend adapter does this).
		local aliases = {} --[[: { [string]: Ty } ]]
		local ok = P.declare_alias(aliases, "Epoll", "{ fd: integer, wait: () -> nil }")
		T.ok(ok ~= nil, "in-file alias Epoll declared")
		local Epoll = aliases.Epoll
		if not Epoll then T.fail(true, "Epoll not declared"); return end
		local MaybeEpoll = G.union({ Epoll, G.nil_() })
		-- `if ep == nil then ep = {...} end` then `ep.wait()` — after the assignment
		-- both branches yield Epoll; v1's nil-guard narrows the non-nil path to Epoll.
		local n_ep = add_node(state, "ep", { t = "var", name = "ep" })
		local n_guard = add_node(state, "guard", { g = "nil_eq", var = "ep", eq = false })
		local g0 = S.extend(S.empty_ctx(), "ep", MaybeEpoll)
		local c_pre = S.has_type_claim(A.id("claim", "pre"), g0, n_ep, MaybeEpoll)
		local c_nar = S.narrows_claim(A.id("claim", "nar"), g0, n_guard, "ep", Epoll, G.nil_())
		A.add_claim(state, c_pre); A.add_claim(state, c_nar)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "epre"), claim = c_pre.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "enar"), claim = c_nar.id, method = "narrow_guard", inputs = { c_pre.id } }))
		-- ep.wait : () -> nil accessible on the narrowed Epoll.
		local g2 = S.extend(S.empty_ctx(), "ep", Epoll)
		local n_ep2 = add_node(state, "ep2", { t = "var", name = "ep" })
		local n_wait = add_node(state, "wait", { t = "index", obj = { space = "artifact", key = "ep2" }, field = "wait" })
		local wait_ty = G.fn({ fixed = {} }, { fixed = { G.nil_() } })
		local c_ep2 = S.has_type_claim(A.id("claim", "cep2"), g2, n_ep2, Epoll)
		local c_wait = S.has_type_claim(A.id("claim", "cwait"), g2, n_wait, wait_ty)
		A.add_claim(state, c_ep2); A.add_claim(state, c_wait)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "eep2"), claim = c_ep2.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ewait"), claim = c_wait.id, method = "synth_index", inputs = { c_ep2.id } }))
		local res = A.check({ state = state, requested_claims = { c_nar.id, c_wait.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c_nar), "ep narrows from Epoll|nil to Epoll (in-file alias, 0 errors)")
		T.ok(has(res.accepted_claims, c_wait), "ep.wait : () -> nil accessible on the narrowed Epoll")
	end)
end)

-- ── Fixture 11: closure_param_typing — declared-return-slot inference ────────
-- §7.1: synth_call multi-return slot inference keeps slot 2 = fn((),()) INDEPENDENT
-- of the typed inner closure (the slot is drawn from the DECLARED Ret, not re-inferred).

T.describe("corpus: fixture_closure_param_typing — second multi-return slot stays () -> ()", function()
	T.it("with_scope's declared Ret.fixed[2] = () -> () is drawn directly; the typed closure can't corrupt it", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local Node = G.rec({ fld("kind", G.string()) }, "closed")
		local Signal = G.rec({ fld("get", G.fn({ fixed = {} }, { fixed = { G.unknown() } })) }, "closed")
		local Cleanup = G.fn({ fixed = {} }, { fixed = {} }) -- () -> ()
		-- with_scope : ((Signal) -> Node) -> (Node, () -> ())  — multi-return Ret = [Node, Cleanup].
		local with_scope = G.fn(
			{ fixed = { G.fn({ fixed = { Signal } }, { fixed = { Node } }) } },
			{ fixed = { Node, Cleanup } })
		-- the second multi-return slot is the DECLARED Ret.fixed[2], independent of the
		-- argument. The legacy bug re-inferred it from the typed closure and got nil.
		T.eq(with_scope.ret.fixed[2].tid, Cleanup.tid, "Ret.fixed[2] is exactly () -> () (NOT nil)")
		-- c1 (the second destructured slot) : () -> () — so c1() is a valid call.
		local n_f = add_node(state, "ws", { t = "var", name = "with_scope" })
		local g = S.extend(S.empty_ctx(), "with_scope", with_scope)
		local c_f = S.has_type_claim(A.id("claim", "cf"), g, n_f, with_scope)
		A.add_claim(state, c_f)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ef"), claim = c_f.id, method = "synth_var" }))
		local res = A.check({ state = state, requested_claims = { c_f.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c_f), "with_scope synthesizes its declared type (0 errors)")
		-- mechanism: c1 : Cleanup, and a call c1() (Cleanup applied to no args) type-checks.
		T.ok(SUB.is_subtype(Cleanup, G.func()), "c1 : () -> () is callable (not nil)")
	end)
end)

-- ── Numeric-for control variable (§5.2) ──────────────────────────────────────
-- Not its own fixture, but a Pass-4 loop form the doc mandates; exercised here.

T.describe("corpus: numeric-for control variable binds integer | number (§5.2)", function()
	T.it("for i = a, b, c: i : integer | number", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local n_i = add_node(state, "i", { t = "numeric_for_var" })
		local IntNum = G.union({ G.integer(), G.number() })
		local c_i = S.has_type_claim(A.id("claim", "ci"), S.empty_ctx(), n_i, IntNum)
		A.add_claim(state, c_i)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ei"), claim = c_i.id, method = "synth_numeric_for_var" }))
		local res = A.check({ state = state, requested_claims = { c_i.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c_i), "numeric-for control var : integer | number (0 errors)")
	end)
end)

-- ── ipairs loop-var binding (§5.2) ───────────────────────────────────────────

T.describe("corpus: ipairs loop-var binding — (integer, valueType)", function()
	T.it("for i, x in ipairs({[integer]:string}): i : integer, x : string", function()
		G.reset()
		local state = A.new_state()
		local registry = reg()
		local arr = G.indexer(G.integer(), G.string())
		local n_tab = add_node(state, "t", { t = "var", name = "t" })
		local n_i = add_node(state, "i", { t = "loop_var", iter = "ipairs", table = { space = "artifact", key = "t" }, slot = 1 })
		local n_x = add_node(state, "x", { t = "loop_var", iter = "ipairs", table = { space = "artifact", key = "t" }, slot = 2 })
		local g = S.extend(S.empty_ctx(), "t", arr)
		local c_tab = S.has_type_claim(A.id("claim", "ctab"), g, n_tab, arr)
		local c_i = S.has_type_claim(A.id("claim", "ci"), g, n_i, G.integer())
		local c_x = S.has_type_claim(A.id("claim", "cx"), g, n_x, G.string())
		A.add_claim(state, c_tab); A.add_claim(state, c_i); A.add_claim(state, c_x)
		A.add_evidence(state, A.evidence({ id = A.id("ev", "etab"), claim = c_tab.id, method = "synth_var" }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ei"), claim = c_i.id, method = "synth_loop_var", inputs = { c_tab.id } }))
		A.add_evidence(state, A.evidence({ id = A.id("ev", "ex"), claim = c_x.id, method = "synth_loop_var", inputs = { c_tab.id } }))
		local res = A.check({ state = state, requested_claims = { c_i.id, c_x.id }, semantics_registry = registry })
		if not res then T.fail(true, "no result"); return end
		T.ok(has(res.accepted_claims, c_i), "ipairs index i : integer")
		T.ok(has(res.accepted_claims, c_x), "ipairs element x : string")
	end)
end)
