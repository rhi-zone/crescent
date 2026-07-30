-- lib/type/v10_kernel/pilot/fixpoint_prover.lua
--
-- Pilot step 4 (certificate-emitting prover) — PHASE 3: loop-invariant
-- discharge over real Lua source, citing fixpoint_v1.lua's theory
-- (docs/typechecker-v10-fixpoint-proposal.md + its addendum). A NEW
-- SIBLING module to prover_narrow.lua/prover.lua, not an in-place
-- extension of either — see "Why a sibling module" below.
--
-- ── What this module does ────────────────────────────────────────────────
--
-- Detects every `NODE_WHILE_STMT` in a file (via prover_narrow.lua's
-- Phase-3 `while_loop` event — see that module's header), and for each
-- already-tracked (`--:`-annotated, 2+-member six-tag-union) local or
-- parameter in scope at that loop, attempts to derive and root-REPLAY a
-- `loop-invariant-discharge` certificate: the tracked variable's declared
-- union survives one iteration of the loop body. The loop's own TEST is
-- never inspected — this theory needs no guard fact at all (unlike
-- flow_narrow_v1's branch-narrowing, which prover.lua/prover_narrow.lua
-- already handle). This is a deliberately separate concern from branch
-- narrowing: different event kind, different rule set
-- (fixpoint_v1.lua, not flow_narrow_v1.lua), no interaction with
-- `guard_selects`/`narrow-select-*`.
--
-- ── Why a sibling module, not an in-place extension ──────────────────────
--
-- prover_narrow.lua/prover.lua's own header explains their two-pass
-- module boundary as deliberate: pass 1 (real-AST analysis) and pass 2
-- (certificate construction/replay) are independent, with a FEW small
-- helpers duplicated across them rather than shared (see prover.lua's
-- header, "mirrors prover_narrow.lua's own private helpers -- duplicated
-- rather than imported"). Loop-invariant derivation is additive to that
-- existing shape, not a modification of it: it needs a NEW event kind
-- (`while_loop`, added to prover_narrow.lua as a strictly additive
-- sibling event -- prover.lua's existing `emit_events` already tolerates
-- unrecognized event kinds silently, so this changes no existing
-- behavior) and an entirely disjoint certificate vocabulary
-- (fixpoint_v1.lua's five theories vs. flow_narrow_v1.lua's guard rules).
-- Folding this into prover.lua's `emit_events` would entangle two
-- unrelated rule sets' bookkeeping (branch-fact threading vs.
-- loop-body statement walking) in one function for no shared benefit --
-- this module reuses prover_narrow.lua's ALREADY-COMPUTED `Scope`
-- snapshot (carried on the `while_loop` event) rather than rebuilding
-- scope/annotation-parsing itself (the two-pass precedent's own
-- discipline: don't re-derive what pass 1 already resolved), but owns
-- its OWN independent registry/vocabulary/replayer and its OWN raw-AST
-- walk of each loop's body (pass 1's event tree does not capture generic
-- `NODE_ASSIGN_STMT`/`NODE_EXPR_STMT` statements at all -- see
-- prover_narrow.lua's `analyze_block`, which only ever emits an event for
-- a `NODE_ASSIGN_STMT` in the single narrow case of a func-expr-valued
-- single target -- so this module reads the `Ctx` carried on the
-- `while_loop` event directly, one loop body at a time, rather than
-- trying to shoehorn a second analysis concern into pass 1's existing
-- event shapes).
--
-- ── Addressing convention this module implements ─────────────────────────
--
-- See prover_addr.lua's header ("Addressing convention: assign-transfer's
-- `Pa`"): for a `NODE_LOCAL_STMT`/`NODE_ASSIGN_STMT` transferring a
-- literal or bare-identifier-copy RHS, `Pa` binds to
-- `exit_of(the owning statement's own path)` -- the SAME point every
-- `seq-persist` step also advances to after that statement, so a chain of
-- citations down a block shares one consistent point per statement.
--
-- ── The loop-body walk, one tracked variable `X` at a time ───────────────
--
-- Per docs/typechecker-v10-fixpoint-proposal.md §3 + its addendum §8.3:
-- starting from the ASSUMED hypothesis `holds_at(LH, X, Tinv)` at
-- `LH = entry_of(body_path)`, walk the body's own top-level statements in
-- source order, maintaining a "current fact" (node, point):
--   - `NODE_LOCAL_STMT` (any declared name -- see the doc's corrected §8.3
--     rule (a): it always introduces a FRESH binding at a path distinct
--     from `X`'s own declaration site, so it can never rebind `X` no
--     matter what name it declares) and a bare call-statement
--     (`NODE_EXPR_STMT` -- rule (c)) are always preserving: `seq-persist`
--     carries the fact forward to `exit_of(this statement's own path)`.
--   - `NODE_ASSIGN_STMT` whose target list does not include `X` (rule
--     (b)) is likewise preserving.
--   - `NODE_ASSIGN_STMT`/`NODE_LOCAL_STMT` targeting `X` (single target,
--     single value only -- multi-target/multi-value is out of scope) with
--     a six-tag-literal RHS: `assign-literal-transfer`, replacing the
--     running fact with the literal's own tag at `Pa`.
--   - targeting `X` with a bare-identifier copy RHS: see "Known scope
--     reduction" below -- NOT attempted by this module; a counted skip.
--   - anything else touching `X`, or any control-flow statement
--     (`if`/`while`/`repeat`/`do`/`for`/`return`/`break`) at the body's
--     own top level, or any other statement kind: a counted skip, chain
--     abandoned for this (loop, X) pair (conservative, never a certificate
--     attempt on an unrecognized shape).
-- On a clean walk to the body's last statement, `Tp`/`BE` are established;
-- `ty_sub(Tp, Tinv)` is closed via `ty-sub-refl` (`Tp` syntactically
-- `Tinv`, the only case this module attempts a certificate for -- see
-- below) or the union-membership chain fixpoint_v1.lua's header documents.
-- `PreLoop := LH` (this module does not attempt to derive an ENTRY fact
-- from a preceding declaration -- it cites `pilot-initial-facts-v1`
-- directly at `LH` for `T0 = Tinv`, exactly like the Phase 2 test and
-- exactly like prover.lua's own existing guard-initial-fact citation:
-- "assert the declared union holds here" is licensed at ANY point the
-- prover chooses to cite it, not only a point reached by derivation).
-- `loop_edge(LH, BE)` is cited directly (`pilot-loop-facts-v1`). The
-- single hypothesis leaf introduced at the walk's start is reused
-- (never re-created) as the discharge slot's citation.
--
-- ── Known scope reduction: bare-identifier copy RHS is NOT attempted ─────
--
-- **This module does not attempt `assign-copy-transfer` at all** (neither
-- self-copy `x = x` nor a copy from a different tracked variable) --
-- every bare-identifier-copy RHS targeting the loop variable is a counted
-- skip ("copy source not independently established at the assign point"),
-- even when the source IS independently tracked. This is a deliberate,
-- reported scope reduction, not an oversight -- worked through and left
-- open for the orchestrator rather than resolved unilaterally, per two
-- separate findings:
--   1. Self-copy (`x = x`) requires `holds_at(Pa, X, T)` as
--      `assign-copy-transfer`'s OWN premise, at the SAME `Pa` as its
--      conclusion (the rule shares one `Pa` metavariable across both).
--      Under THIS module's addressing convention (`Pa = exit_of(the
--      statement's own path)`, i.e. AFTER the statement completes), that
--      premise cannot be reached by `seq-persist` from the running fact
--      established BEFORE this statement: `seq-persist` needs
--      `stmt_preserves(prev, Pa, X)`, which requires `X` NOT be among the
--      statement's targets (§8.3 rule (b)) -- but self-copy's target list
--      DOES name `X`. The Phase 2 test
--      (`fixpoint_v1_test.lua`) closes this same shape using a DIFFERENT,
--      now-superseded addressing choice for its hand-built `Pa` (its own
--      header flags this explicitly: "not tied to prover_addr.lua's real
--      conventions"), which does not transfer to this module's corrected
--      convention.
--   2. A copy from a genuinely different tracked variable `Y` would need
--      `Y`'s OWN fact independently chained forward (via its own
--      `seq-persist` steps through the SAME body prefix, grounded in its
--      own `pilot-initial-facts-v1` citation at `LH`) IN PARALLEL with
--      `X`'s chain -- multi-variable simultaneous fact-tracking through
--      one body walk. Buildable in principle, but no required test
--      exercises it, and it was not attempted here rather than guessed at
--      under time pressure.
-- Both are reported to the orchestrator rather than resolved by picking
-- an unstated convention -- see the accompanying report.
--
-- The required root-accepting fixture (below) therefore uses a LITERAL
-- reassignment (`x = false`), not a self-copy -- explicitly permitted as
-- "your choice" by the originating brief.
--
-- ── Another reported gap: the empty-loop-body edge case ──────────────────
--
-- A body with zero statements has no `stmt_seq` adjacency to bridge
-- `LH = entry_of(body_path)` to any `BE` at all (this theory has no axiom
-- relating `entry_of`/`exit_of` of the SAME path absent an intervening
-- statement) -- this module treats it as a counted skip ("empty loop
-- body: no persistence chain from loop head to back edge under this
-- theory") rather than inventing a bridging axiom.

local ta = require("lib.type.v10_cleanroom.term_algebra")
local rl = require("lib.type.v10_cleanroom.replayer")
local parse_mod = require("lib.type.static.parse")
local defs = require("lib.type.static.defs")
local addr_v1 = require("lib.type.v10_kernel.pilot.addr_v1")
local fixpoint_v1 = require("lib.type.v10_kernel.pilot.fixpoint_v1")
local pilot_initial_facts_v1 = require("lib.type.v10_kernel.pilot.pilot_initial_facts_v1")
local prover_narrow = require("lib.type.v10_kernel.pilot.prover_narrow")
local prover_addr = require("lib.type.v10_kernel.pilot.prover_addr")

local M = {}

local NODE_LOCAL_STMT  = defs.NODE_LOCAL_STMT
local NODE_ASSIGN_STMT = defs.NODE_ASSIGN_STMT
local NODE_EXPR_STMT   = defs.NODE_EXPR_STMT
local NODE_IDENTIFIER  = defs.NODE_IDENTIFIER
local NODE_LITERAL     = defs.NODE_LITERAL

local LIT_STRING  = defs.LIT_STRING
local LIT_NUMBER  = defs.LIT_NUMBER
local LIT_BOOLEAN = defs.LIT_BOOLEAN
local LIT_NIL     = defs.LIT_NIL

-- Same `Ctx`/AST-arena shapes prover_narrow.lua declares (structural, not
-- imported -- each module owns its own copy per the two-pass boundary's
-- own duplication precedent -- see this module's header).
--:: ASTNode = { kind: integer, flags: integer, line: integer, col: integer, data: { [integer]: integer } }
--:: ASTNodeArena = { get: (ASTNodeArena, integer) -> ASTNode, ... }
--:: ListPool = { get: (ListPool, integer) -> integer, ... }
--:: Ctx = { nodes: ASTNodeArena, lists: ListPool, pool: unknown, lexer: unknown, source_lines: string[] }

--:: SkipCounts = { [string]: integer }
--:: Stats = {
--::   loops_found: integer, loop_vars_attempted: integer, loop_vars_certified: integer,
--::   loop_skipped: SkipCounts,
--:: }
--:: AnalyzeResult = { judgments: ReplayResult[], stats: Stats }

--: () -> Stats
function M.new_stats()
	return { loops_found = 0, loop_vars_attempted = 0, loop_vars_certified = 0, loop_skipped = {} }
end

--: (SkipCounts, string) -> ()
local function bump(counts, reason)
	counts[reason] = (counts[reason] or 0) + 1
end

--:: ScopeVar = { kind: "local" | "param", root_path: integer[], index: integer, members: string[] }
--:: Scope = { [integer]: ScopeVar }
--:: WhileLoopEvent = { kind: "while_loop", while_path: integer[], body_path: integer[], body_start: integer, body_len: integer, scope: Scope, ctx: Ctx }

--:: AddrOps = { [string]: OpDecl }

-- Build an addr-v1 path term from a root-relative child-index array.
-- Duplicated from prover.lua (small pure helper -- see this module's
-- header on the two-pass precedent's own duplication discipline).
--: (AddrOps, integer[]) -> (Term | nil, string | nil)
local function path_of(addr_ops, indices)
	local p, err = prover_addr.root(addr_ops)
	if not p then return nil, err end
	for _, i in ipairs(indices) do
		p, err = prover_addr.child(addr_ops, p, i)
		if not p then return nil, err end
	end
	return p
end

--: (integer[], integer) -> integer[]
local function extend_path(path, i)
	local out = {} --[[: integer[] ]]
	for j, v in ipairs(path) do out[j] = v end
	out[#path + 1] = i
	return out
end

-- A tracked variable's identity path, dispatched on `sv.kind` -- same
-- dispatch prover.lua's `var_identity_path` performs, duplicated here (see
-- this module's header).
--: (AddrOps, Term, ScopeVar) -> (Term | nil, string | nil)
local function var_identity_path(addr_ops, root_path_term, sv)
	if sv.kind == "param" then
		return prover_addr.func_param_path(addr_ops, root_path_term, sv.index)
	end
	return prover_addr.local_name_path(addr_ops, root_path_term, sv.index)
end

-- Build a right-associated `ty_union` term over `members` in DECLARED
-- order (the same order `parse_annotation_members` preserves) -- this is
-- `Tinv`, the invariant candidate, not a chain-aware reordering (that
-- reordering is flow_narrow_v1/prover.lua's own guard-chaining concern,
-- irrelevant here: this module never needs a member positioned first for
-- a `narrow-select-*` citation).
--: (FixpointVocab, string) -> (Term | nil, string | nil)
local function tag_term_of(vocab, tag)
	local t = nil --[[: Term | nil ]]
	local terr = nil --[[: string | nil ]]
	if tag == "nil" then t, terr = vocab.tag_nil()
	elseif tag == "boolean" then t, terr = vocab.tag_boolean()
	elseif tag == "number" then t, terr = vocab.tag_number()
	elseif tag == "string" then t, terr = vocab.tag_string()
	elseif tag == "table" then t, terr = vocab.tag_table()
	elseif tag == "function" then t, terr = vocab.tag_function()
	else return nil, "tag_term_of: unrecognized tag " .. tostring(tag) end
	if not t then return nil, terr end
	return vocab.TyOf(t)
end

--: (FixpointVocab, string[]) -> (Term | nil, string | nil)
local function build_declared_union(vocab, members)
	if #members == 0 then return nil, "build_declared_union: empty member list" end
	local term, err = tag_term_of(vocab, members[1])
	if not term then return nil, err end
	for i = 2, #members do
		local next_term, nerr = tag_term_of(vocab, members[i])
		if not next_term then return nil, nerr end
		term, err = vocab.TyUnion(term, next_term)
		if not term then return nil, err end
	end
	return term
end

-- Build the `ty_sub(single_tag_ty, tinv)` derivation node when `Tp` is a
-- single tag (from a literal reassignment) and `Tinv` is the declared
-- union `members` -- fixpoint_v1.lua's header's own "peel one binary
-- layer, re-cite" idiom: `k` `ty-sub-union-here-right`/`ty-sub-trans`
-- citations to skip past the members before `tag`'s own position, then one
-- final `ty-sub-union-here-left` (if `tag` is not the union's own last
-- member) or `ty-sub-refl` (if `members` has exactly one entry, i.e.
-- `Tinv` is not actually a union at all -- out of scope for a loop
-- invariant, since `try_guard_event`-style tracking requires 2+ members,
-- but defended here regardless).
--: (FixpointVocab, string, string[], Term) -> (CertNode | nil, string | nil)
local function build_ty_sub_to_union(vocab, tag, members, tinv_term)
	local tag_ty, tterr = tag_term_of(vocab, tag)
	if not tag_ty then return nil, tterr end
	local pos = nil --[[: integer | nil ]]
	for i, m in ipairs(members) do
		if m == tag then pos = i break end
	end
	if pos == nil then
		return nil, "reassigned type not a member of the declared invariant"
	end
	if #members == 1 then
		return { kind = "axiom", axiom = vocab.ax_ty_sub_refl, bindings = { A = tag_ty } } --[[: CertNode ]]
	end
	-- Build the suffix union starting at `pos` (Rest for union-here-left),
	-- i.e. the same right-associated spine `build_declared_union` builds,
	-- restricted to members[pos..]. Needed to cite `ty-sub-union-here-left`
	-- once at that suffix, or `ty-sub-union-here-right` once per member
	-- strictly before `pos` (peeling `Rest` one layer per skipped member).
	--: (integer) -> (Term | nil, string | nil)
	local function suffix_union(from)
		local term, err = tag_term_of(vocab, members[from])
		if not term then return nil, err end
		for i = from + 1, #members do
			local next_term, nerr = tag_term_of(vocab, members[i])
			if not next_term then return nil, nerr end
			term, err = vocab.TyUnion(term, next_term)
			if not term then return nil, err end
		end
		return term
	end
	local node = nil --[[: CertNode | nil ]]
	local loop_start --[[: integer ]]
	if pos == #members then
		-- `tag` is the union's own last member: base case is
		-- `ty-sub-union-here-right` against the second-to-last member's
		-- own suffix (`suffix_union(pos-1) == ty_union(members[pos-1],
		-- tag)` structurally) -- this already folds in `members[pos-1]`,
		-- so further peeling starts at `pos-2`, not `pos-1`.
		local prev_ty, perr = tag_term_of(vocab, members[pos - 1])
		if not prev_ty then return nil, perr end
		node = { kind = "axiom", axiom = vocab.ax_ty_sub_union_here_right,
			bindings = { X = prev_ty, B = tag_ty } } --[[: CertNode ]]
		loop_start = pos - 2
	else
		local rest_term, rerr = suffix_union(pos + 1)
		if not rest_term then return nil, rerr end
		node = { kind = "axiom", axiom = vocab.ax_ty_sub_union_here_left,
			bindings = { A = tag_ty, Rest = rest_term } } --[[: CertNode ]]
		loop_start = pos - 1
	end
	-- Chain ty-sub-trans once per remaining member strictly before the
	-- base case's own coverage (peeling one union-here-right layer per
	-- skipped prefix member), from the LAST such member back to the
	-- first, matching fixpoint_v1.lua's own "peel one binary layer,
	-- re-cite" idiom. Invariant maintained by `node` on entry to each
	-- iteration: `ty_sub(tag_ty, suffix_union(i+1))`.
	for i = loop_start, 1, -1 do
		local rest_term, rerr = suffix_union(i + 1)
		if not rest_term then return nil, rerr end
		local i_ty, ierr = tag_term_of(vocab, members[i])
		if not i_ty then return nil, ierr end
		-- ab: ty_sub(suffix_union(i+1), suffix_union(i))
		local ab = { kind = "axiom", axiom = vocab.ax_ty_sub_union_here_right,
			bindings = { X = i_ty, B = rest_term } } --[[: CertNode ]]
		-- ty-sub-trans premises are (ty_sub(A,B), ty_sub(B,C)) -> ty_sub(A,C):
		-- `node` is ty_sub(tag_ty, suffix_union(i+1)) = ty_sub(A,B); `ab`
		-- is ty_sub(suffix_union(i+1), suffix_union(i)) = ty_sub(B,C).
		node = { kind = "rule", rule = vocab.rule_ty_sub_trans, premises = { node, ab } } --[[: CertNode ]]
	end
	return node
end

--:: EmitCtx = {
--::   addr_ops: AddrOps, file_id: Term, vocab: FixpointVocab, ax_initial: AxiomDecl,
--::   rp: Replayer, stats: Stats, judgments: ReplayResult[],
--:: }

-- Find the smallest body-statement index (0-based) at which a
-- `NODE_LOCAL_STMT` re-declares `name_id` as a single new name (shadowing
-- any outer variable of the same name from that point forward within this
-- body) -- infinity (`math.huge`) if none does. Used so a later
-- assignment/read of `name_id` after such a redeclaration is correctly
-- resolved as touching the SHADOW, never the outer tracked variable (see
-- prover_narrow.lua's own "Scoping correctness" note for the same
-- shadow-by-fresh-binding discipline this mirrors).
--: (Ctx, integer, integer, integer) -> number
local function shadow_index_for(ctx, body_start, body_len, name_id)
	for i = 0, body_len - 1 do
		local nid = ctx.lists:get(body_start + i)
		local n = ctx.nodes:get(nid)
		if n.kind == NODE_LOCAL_STMT and n.data[1] == 1 then
			local decl_name_id = ctx.lists:get(n.data[0])
			if decl_name_id == name_id then return i end
		end
	end
	return math.huge
end

-- Cite + replay a `seq-persist` step carrying `(node, X)`'s fact from
-- `from_point` to `to_point` over a statement confirmed (by the caller)
-- non-interfering with `X`. Returns the new node, or nil + a skip reason
-- string on replay rejection (never silently dropped -- recorded by the
-- caller via `loop_skipped`).
--: (EmitCtx, CertNode, Term, Term, Term) -> (CertNode | nil, string | nil)
local function persist(ectx, node, from_point, to_point, x_path)
	local vocab = ectx.vocab
	local seq = { kind = "axiom", axiom = vocab.ax_stmt_seq_facts,
		bindings = { A = from_point, B = to_point } } --[[: CertNode ]]
	local pres = { kind = "axiom", axiom = vocab.ax_stmt_preserves_facts,
		bindings = { A = from_point, B = to_point, X = x_path } } --[[: CertNode ]]
	local rule_node = { kind = "rule", rule = vocab.rule_seq_persist, premises = { node, seq, pres } } --[[: CertNode ]]
	local result, rerr = rl.observe(ectx.rp, rule_node)
	if not result then
		return nil, "replay rejected a seq-persist step: " .. tostring(rerr)
	end
	return rule_node
end

-- Returns the six-tag name a `NODE_LITERAL` denotes, or nil if it is not
-- one of the four literal-representable tags this theory transfers
-- (nil/true/false/number/string are literal-representable; table/function
-- values are never `NODE_LITERAL` nodes at all).
--: (ASTNode) -> string | nil
local function literal_tag_name(lit_node)
	local kind = lit_node.data[0]
	if kind == LIT_NIL then return "nil" end
	if kind == LIT_BOOLEAN then
		if lit_node.data[1] == 1 then return "true" end
		return "false"
	end
	if kind == LIT_NUMBER then return "number" end
	if kind == LIT_STRING then return "string" end
	return nil
end

--: (FixpointVocab, string) -> (Term | nil, string | nil)
local function literal_tag_term(vocab, tagname)
	if tagname == "nil" then return vocab.tag_nil() end
	if tagname == "true" then return vocab.tag_true() end
	if tagname == "false" then return vocab.tag_false() end
	if tagname == "number" then return vocab.tag_number() end
	if tagname == "string" then return vocab.tag_string() end
	return nil, "literal_tag_term: unrecognized literal tag " .. tostring(tagname)
end

-- The declared-union member name a literal tag corresponds to: `true`/
-- `false` both narrow to the declared union's own `"boolean"` member (this
-- theory's six-tag vocabulary has no separate true/false union member --
-- see fixpoint_v1.lua's `tag_boolean` vs `tag_true`/`tag_false`: the union
-- spine this module builds from `sv.members` uses `"boolean"`, matching
-- `parse_annotation_members`'s own six-class vocabulary, never `"true"`/
-- `"false"` as a member name). `ty_sub` here checks `ty_of(tag_true())` /
-- `ty_of(tag_false())` against a `ty_of(tag_boolean())` union member --
-- NOT the same term (`tag_true() ~= tag_boolean()`), so a literal
-- `true`/`false` reassignment can only be shown a member of `Tinv` when
-- `Tinv` was NOT built from `sv.members` directly for this comparison but
-- from the LITERAL's own tag matched structurally -- see
-- `build_ty_sub_to_union`'s `tag` parameter, which is always the literal's
-- OWN prim_tag selector name (`"nil"`/`"true"`/`"false"`/`"number"`/
-- `"string"`), and is matched against `members` using THAT vocabulary.
-- Since `sv.members` (parsed from a `--:` annotation) can only ever
-- contain `"boolean"` (never `"true"`/`"false"` — `parse_annotation_members`
-- only accepts the six `type()`-class names), a literal `true`/`false`
-- reassignment's own tag can NEVER structurally match a `"boolean"` union
-- member by name — captured here as an explicit, honest scope limit
-- (`ty_of(tag_true())` and `ty_of(tag_boolean())` are different, unrelated
-- terms in this theory; nothing in fixpoint_v1.lua relates them), not
-- silently misreported as a match.
--: (string) -> string
local function declared_member_name_for_literal(tagname)
	if tagname == "true" or tagname == "false" then return "boolean" end
	return tagname
end

local attempt_loop_invariant --: ((EmitCtx, integer[], integer, integer, Ctx, integer, ScopeVar) -> ()) | nil

--: (EmitCtx, integer[], integer, integer, Ctx, integer, ScopeVar) -> ()
attempt_loop_invariant = function(ectx, body_path, body_start, body_len, ctx, name_id, sv)
	local addr_ops, vocab = ectx.addr_ops, ectx.vocab
	ectx.stats.loop_vars_attempted = ectx.stats.loop_vars_attempted + 1

	--: (string) -> ()
	local function skip(reason)
		bump(ectx.stats.loop_skipped, reason)
	end

	local root_path_term, rperr = path_of(addr_ops, sv.root_path)
	if not root_path_term then skip("failed to build var root path: " .. tostring(rperr)) return end
	local x_path, xperr = var_identity_path(addr_ops, root_path_term, sv)
	if not x_path then skip("failed to build var identity path: " .. tostring(xperr)) return end

	local tinv_term, tierr = build_declared_union(vocab, sv.members)
	if not tinv_term then skip("failed to build declared union: " .. tostring(tierr)) return end

	if body_len == 0 then
		skip("empty loop body: no persistence chain from loop head to back edge under this theory")
		return
	end

	local body_path_term, bpterr = path_of(addr_ops, body_path)
	if not body_path_term then skip("failed to build body path: " .. tostring(bpterr)) return end
	local lh, lherr = prover_addr.entry(addr_ops, ectx.file_id, body_path_term)
	if not lh then skip("failed to build LH: " .. tostring(lherr)) return end

	local h1_judgment, h1jerr = vocab.HoldsAt(lh, x_path, tinv_term)
	if not h1_judgment then skip("failed to build LH hypothesis judgment: " .. tostring(h1jerr)) return end
	local h1 = { kind = "hypothesis", judgment = h1_judgment } --[[: CertNode ]]

	local shadow_index = shadow_index_for(ctx, body_start, body_len, name_id)

	local cur_node = h1
	local cur_point = lh
	local cur_term = tinv_term
	-- `cur_tag_name` tracks the DECLARED-UNION member name (see
	-- `declared_member_name_for_literal`) of the last literal transferred,
	-- or nil while the running fact is still exactly `Tinv` (persistence
	-- only, no reassignment has touched X yet).
	local cur_tag_name = nil --[[: string | nil ]]
	-- `h1_live`: whether `cur_node`'s own derivation tree still traces
	-- back to `h1` (the assumed invariant hypothesis). `seq-persist`
	-- always carries the PRIOR `cur_node` forward as its own premise, so
	-- persistence steps preserve this; `assign-literal-transfer` builds a
	-- BRAND NEW, axiom-grounded derivation with NO reference to the prior
	-- `cur_node` at all, severing the dependency permanently (once false,
	-- stays false -- a later persist step only carries the LITERAL fact
	-- forward, never resurrects `h1`). The root's discharge citation must
	-- be OMITTED (vacuous -- `M.replay`'s own explicitly legal case) when
	-- `h1_live` is false at the end of the walk: citing `{h1}` against a
	-- premise 2 that no longer has `h1` in its open set is rejected by
	-- `replay_rule`'s own discharge-citation check ("cites a hypothesis
	-- not open in premise 2"). This is not a special case invented here --
	-- it is the theory's own degenerate/base-case reading: when the
	-- back-edge fact is derived WITHOUT depending on the assumed
	-- invariant at all (a literal reassignment need not read the
	-- variable's own prior value), the coinductive discharge is
	-- vacuously satisfied, and `holds_at(LH,X,Tinv)` is licensed by the
	-- rule either way (its own entry-fact premise, P3, already grounds
	-- `LH` directly via `pilot-initial-facts-v1`).
	local h1_live = true
	local ok = true
	local fail_reason = nil --[[: string | nil ]]
	local last_stmt_path = nil --[[: integer[] | nil ]]

	for i = 0, body_len - 1 do
		local stmt_path = extend_path(body_path, i)
		last_stmt_path = stmt_path
		local nid = ctx.lists:get(body_start + i)
		local n = ctx.nodes:get(nid)
		local kind = n.kind
		local shadowed = i >= shadow_index

		local stmt_path_term, sperr = path_of(addr_ops, stmt_path)
		if not stmt_path_term then
			ok = false fail_reason = "failed to build statement path: " .. tostring(sperr) break
		end
		local new_point, neperr = prover_addr.exit(addr_ops, ectx.file_id, stmt_path_term)
		if not new_point then
			ok = false fail_reason = "failed to build statement exit point: " .. tostring(neperr) break
		end

		if kind == NODE_LOCAL_STMT then
			local node, perr = persist(ectx, cur_node, cur_point, new_point, x_path)
			if not node then ok = false fail_reason = perr break end
			cur_node, cur_point = node, new_point

		elseif kind == NODE_EXPR_STMT then
			local node, perr = persist(ectx, cur_node, cur_point, new_point, x_path)
			if not node then ok = false fail_reason = perr break end
			cur_node, cur_point = node, new_point

		elseif kind == NODE_ASSIGN_STMT then
			local tl, el = n.data[1], n.data[3]
			local targets_start, values_start = n.data[0], n.data[2]
			local targets_include_x = false
			if not shadowed then
				for t = 0, tl - 1 do
					local tnid = ctx.lists:get(targets_start + t)
					local tn = ctx.nodes:get(tnid)
					if tn.kind == NODE_IDENTIFIER and tn.data[0] == name_id then
						targets_include_x = true
					end
				end
			end
			if not targets_include_x then
				local node, perr = persist(ectx, cur_node, cur_point, new_point, x_path)
				if not node then ok = false fail_reason = perr break end
				cur_node, cur_point = node, new_point
			elseif tl ~= 1 or el ~= 1 then
				ok = false
				fail_reason = "multi-target/multi-value assignment to the invariant variable (out of scope)"
				break
			else
				local rhs_nid = ctx.lists:get(values_start)
				local rhs = ctx.nodes:get(rhs_nid)
				local literal_tagname = rhs.kind == NODE_LITERAL and literal_tag_name(rhs) or nil
				-- TYPECHECKER WORKAROUND: a plain truthy/`~= nil` check on
				-- `literal_tagname` does not narrow away `nil` here (same
				-- gotcha prover.lua's header documents for its own
				-- `match_path`/`rest_path` locals) -- `type(x) == "string"`
				-- narrows correctly. See TODO.md.
				if type(literal_tagname) == "string" then
					local tagname = literal_tagname
					local tag_term, tterr = literal_tag_term(vocab, tagname)
					if not tag_term then ok = false fail_reason = "failed to build literal tag: " .. tostring(tterr) break end
					local fact = { kind = "axiom", axiom = vocab.ax_assign_literal_facts,
						bindings = { Pa = new_point, X = x_path, Tag = tag_term } } --[[: CertNode ]]
					local node = { kind = "rule", rule = vocab.rule_assign_literal_transfer, premises = { fact } } --[[: CertNode ]]
					local result, rerr = rl.observe(ectx.rp, node)
					if not result then
						ok = false fail_reason = "replay rejected assign-literal-transfer: " .. tostring(rerr) break
					end
					local ty_of_tag, toerr = vocab.TyOf(tag_term)
					if not ty_of_tag then ok = false fail_reason = "failed to build ty_of(tag): " .. tostring(toerr) break end
					cur_node, cur_point, cur_term = node, new_point, ty_of_tag
					cur_tag_name = declared_member_name_for_literal(tagname)
					h1_live = false
				elseif rhs.kind == NODE_IDENTIFIER then
					-- Known scope reduction (module header): neither
					-- self-copy nor cross-variable copy is attempted.
					ok = false
					fail_reason = "copy source not independently established at the assign point"
					break
				else
					ok = false
					fail_reason = "assignment RHS out of scope (not literal or bare-identifier copy)"
					break
				end
			end
		else
			ok = false
			fail_reason = "control-flow statement breaks persistence chaining (out of scope)"
			break
		end
	end

	if not ok then
		skip(fail_reason or "unknown persistence-chain failure")
		return
	end
	if not last_stmt_path then
		skip("empty loop body: no persistence chain from loop head to back edge under this theory")
		return
	end

	local be = cur_point

	-- ty_sub(Tp, Tinv): either Tp == Tinv syntactically (persistence only,
	-- no reassignment touched X), or Tp is a single literal tag that must
	-- be shown a member of Tinv's declared spine.
	local sub_node = nil --[[: CertNode | nil ]]
	if cur_tag_name == nil then
		-- Persistence only: Tp is syntactically Tinv.
		sub_node = { kind = "axiom", axiom = vocab.ax_ty_sub_refl, bindings = { A = tinv_term } } --[[: CertNode ]]
	else
		local node, serr = build_ty_sub_to_union(vocab, cur_tag_name, sv.members, tinv_term)
		if not node then
			skip(serr or "failed to build ty_sub(Tp, Tinv)")
			return
		end
		sub_node = node
	end

	local p0 = { kind = "axiom", axiom = vocab.ax_loop_facts, bindings = { LH = lh, BE = be } } --[[: CertNode ]]
	local p3 = { kind = "axiom", axiom = ectx.ax_initial, bindings = { P = lh, X = x_path, T = tinv_term } } --[[: CertNode ]]
	local p4 = { kind = "axiom", axiom = vocab.ax_ty_sub_refl, bindings = { A = tinv_term } } --[[: CertNode ]]

	-- Vacuous discharge (see `h1_live`'s own note above) when `h1` was
	-- introduced but never referenced by `cur_node`'s own tree: the
	-- `discharge` field is OMITTED entirely rather than set to an empty
	-- table, matching `CertNode`'s own optional-field contract.
	local root --[[: CertNode ]]
	if h1_live then
		root = {
			kind = "rule", rule = vocab.rule_loop_invariant_discharge,
			premises = { p0, cur_node, sub_node, p3, p4 },
			discharge = { [1] = { h1 } },
		}
	else
		root = {
			kind = "rule", rule = vocab.rule_loop_invariant_discharge,
			premises = { p0, cur_node, sub_node, p3, p4 },
		}
	end

	local result, rerr = rl.replay(ectx.rp, root)
	if not result then
		bump(ectx.stats.loop_skipped, "replay rejected an emitted loop-invariant certificate: " .. tostring(rerr))
		return
	end
	ectx.stats.loop_vars_certified = ectx.stats.loop_vars_certified + 1
	ectx.judgments[#ectx.judgments + 1] = result
end

-- Flat, all-kinds-superimposed shape covering every field this module
-- reads off a raw pass-1 event, mirroring prover.lua's own discriminated-
-- event handling (see `Event`'s header there): a real event only ever
-- populates the subset its own `kind` implies, so every field beyond
-- `kind` is optional here and narrowed with an explicit `type()` check
-- before use, never blindly assumed present.
--:: RawEvent = {
--::   kind: string,
--::   events: unknown[] | nil,
--::   then_events: unknown[] | nil,
--::   else_events: unknown[] | nil,
--::   scope: Scope | nil,
--::   body_path: integer[] | nil,
--::   body_start: integer | nil,
--::   body_len: integer | nil,
--::   ctx: Ctx | nil,
--:: }

--: (EmitCtx, RawEvent) -> ()
local function process_while_loop(ectx, ev)
	ectx.stats.loops_found = ectx.stats.loops_found + 1
	local scope = ev.scope
	local body_path = ev.body_path
	local body_start = ev.body_start
	local body_len = ev.body_len
	local ctx = ev.ctx
	if scope == nil then bump(ectx.stats.loop_skipped, "malformed while_loop event (internal)") return end
	if body_path == nil then bump(ectx.stats.loop_skipped, "malformed while_loop event (internal)") return end
	if body_start == nil then bump(ectx.stats.loop_skipped, "malformed while_loop event (internal)") return end
	if body_len == nil then bump(ectx.stats.loop_skipped, "malformed while_loop event (internal)") return end
	if ctx == nil then bump(ectx.stats.loop_skipped, "malformed while_loop event (internal)") return end
	local any_tracked = false
	for name_id, sv in pairs(scope) do
		if #sv.members >= 2 then
			any_tracked = true
			if attempt_loop_invariant then
				attempt_loop_invariant(ectx, body_path, body_start, body_len, ctx, name_id, sv)
			end
		end
	end
	if not any_tracked then
		bump(ectx.stats.loop_skipped, "no tracked variable in scope at this loop")
	end
end

local walk_events --: ((EmitCtx, unknown[]) -> ()) | nil

--: (EmitCtx, unknown[]) -> ()
walk_events = function(ectx, events)
	if not walk_events then return end
	for _, ev_raw in ipairs(events) do
		if type(ev_raw) == "table" then
			local ev = ev_raw --[[: RawEvent ]]
			if ev.kind == "while_loop" then
				process_while_loop(ectx, ev)
			elseif ev.kind == "nested_scope" then
				local sub = ev.events
				if type(sub) == "table" then walk_events(ectx, sub) end
			elseif ev.kind == "guard" then
				local te = ev.then_events
				local ree = ev.else_events
				if type(te) == "table" then walk_events(ectx, te) end
				if type(ree) == "table" then walk_events(ectx, ree) end
			end
		end
	end
end

-- Analyze one file's source text end-to-end for loop-invariant
-- certificates only (see module header): parse, reuse prover_narrow's
-- pass 1 (for its `while_loop` events + scope snapshots), then this
-- module's own independent registry/vocabulary/replayer walk. Caps-clean:
-- no ambient io.
--: (source: string, file_path: string) -> (AnalyzeResult | nil, string | nil)
function M.analyze_file(source, file_path)
	if type(source) ~= "string" then return nil, "analyze_file: source must be a string" end
	if type(file_path) ~= "string" then return nil, "analyze_file: file_path must be a string" end

	local ok, parser = pcall(parse_mod.parse, source, file_path)
	if not ok then return nil, "analyze_file: parse error: " .. tostring(parser) end

	local pass1_stats = prover_narrow.new_stats()
	local root, aerr = prover_narrow.analyze(parser, pass1_stats, source)
	if not root then return nil, aerr end

	local addr_sig = addr_v1.declare()
	if addr_sig == nil then return nil, "analyze_file: addr_v1.declare failed" end
	local addr_ops = addr_sig.ops

	local reg = rl.new_registry()
	local vocab, verr = fixpoint_v1.declare_vocabulary(reg, addr_sig)
	if not vocab then return nil, "analyze_file: " .. tostring(verr) end
	local ax_initial, iaerr = pilot_initial_facts_v1.declare(reg, vocab)
	if not ax_initial then return nil, "analyze_file: " .. tostring(iaerr) end
	local file_id, fierr = prover_addr.file_id_of_source(addr_ops, source)
	if not file_id then return nil, "analyze_file: " .. tostring(fierr) end

	local rp, rperr = rl.new_replayer({ registry = reg })
	if not rp then return nil, "analyze_file: " .. tostring(rperr) end

	local stats = M.new_stats()
	local judgments = {} --[[: ReplayResult[] ]]
	local ectx = {
		addr_ops = addr_ops, file_id = file_id, vocab = vocab, ax_initial = ax_initial,
		rp = rp, stats = stats, judgments = judgments,
	} --[[: EmitCtx ]]

	walk_events(ectx, root.events)

	return { judgments = judgments, stats = stats }, nil
end

return M
