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
-- ── Assignment transfer from an annotated-call RHS ───────────────────────
--
-- Per fixpoint_v1.lua's v4 bump (`assign_call`/`pilot-assign-call-facts-v1`/
-- `assign-call-transfer`): when `NODE_ASSIGN_STMT`/`NODE_LOCAL_STMT` targets
-- `X` with a call-expression RHS, this module attempts to resolve the
-- callee STATICALLY AND LOCALLY -- a directly-named (bare-identifier,
-- non-method) call whose callee resolves, by structural correspondence
-- only (never guessed), to a SAME-FILE, CHUNK-TOP-LEVEL function
-- declaration (one of the three function-defining shapes this pilot
-- already recognizes elsewhere: `NODE_FUNC_DECL` -- covers both
-- `function f()` and `local function f()`, same node kind, see
-- lib/type/static/parse.lua's `parse_local_stmt`/`parse_func_decl` --,
-- `local f = function(...) end`, or `f = function(...) end` with a bare-
-- identifier target only, never `M.f`/`obj:f`) whose OWN preceding-line
-- `--: (T1,...) -> R` annotation's `R` parses within the pilot's six-tag-
-- plus-union vocabulary as a SINGLE return value (a parenthesized,
-- multi-return `R` -- `-> (A, B)` -- is a counted skip: "first-value-only
-- scope," per the brief). Every other RHS-call shape (a method call, a
-- computed/non-identifier callee, a callee with no resolvable top-level
-- declaration or no/ambiguous annotation, an out-of-vocabulary return
-- annotation) is a counted skip, never a fabricated axiom citation --
-- exactly the "never emit a fact not structurally verified from the parse"
-- law this module already holds itself to for every other citation.
--
-- **Reported, NOT-closed soundness scope limit (structural, not a guess by
-- omission -- flagged plainly, same discipline as the two assign-copy-
-- transfer gaps above):** callee-name shadowing is checked ONLY within the
-- CURRENT flat statement list this module is already walking (the loop
-- body, or the current if/else branch) -- via `shadow_index_for`, the SAME
-- mechanism and SAME granularity already used for `X`'s own shadow safety.
-- For `X`, block-local checking is actually SOUND on its own: prover_narrow
-- .lua's own scope-threading already resolves `X`'s identity correctly
-- relative to everything OUTSIDE the loop body (real Lua block scoping:
-- an inner block's own locals cannot leak out to shadow an outer name, so
-- checking only the block currently being walked is exactly right, at
-- every level, chained). The callee name has NO such upstream resolution
-- machinery -- prover_narrow.lua tracks only `--:`-annotated six-tag-union
-- locals/parameters, never arbitrary identifiers -- so this module's own
-- block-local check does NOT protect against the callee name being
-- shadowed by an ENCLOSING function's own parameter or an earlier local in
-- an OUTER block between the chunk root and this loop (a full lexical
-- scope-chain walk over EVERY identifier, not just tracked ones, is
-- substrate this pilot does not have -- building it is a separate,
-- materially larger undertaking than "one transfer rule mirroring
-- assign_literal," analogous in kind to the fixpoint proposal's own §6
-- "sequential-flow judgment is completely undesigned" finding: a real gap
-- surfaced by trying to write this down, not resolved here). Consequence:
-- a pathological file where an enclosing function's own parameter (or an
-- outer local, declared before the loop, at a shallower nesting level than
-- this module inspects) reuses a chunk-top-level function's name could, in
-- principle, cause this module to cite a call-return-type fact for the
-- WRONG function. No such case was found in Run 5's real corpus (every
-- certified call-RHS pair was hand-verified against the actual callee, not
-- merely the resolved one -- see the measurement report), but the
-- limitation is not eliminated by construction, only by absence in this
-- corpus, and is reported to the orchestrator as exactly that: an open,
-- unresolved scope boundary, not a guess dressed up as a decision.
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
local intern_mod = require("lib.type.static.intern")
local bit_mod = require("bit")
local addr_v1 = require("lib.type.v10_kernel.pilot.addr_v1")
local fixpoint_v1 = require("lib.type.v10_kernel.pilot.fixpoint_v1")
local pilot_initial_facts_v1 = require("lib.type.v10_kernel.pilot.pilot_initial_facts_v1")
local prover_narrow = require("lib.type.v10_kernel.pilot.prover_narrow")
local prover_addr = require("lib.type.v10_kernel.pilot.prover_addr")

local band = bit_mod.band

local M = {}

local NODE_LOCAL_STMT  = defs.NODE_LOCAL_STMT
local NODE_ASSIGN_STMT = defs.NODE_ASSIGN_STMT
local NODE_EXPR_STMT   = defs.NODE_EXPR_STMT
local NODE_IF_STMT     = defs.NODE_IF_STMT
local NODE_IDENTIFIER  = defs.NODE_IDENTIFIER
local NODE_LITERAL     = defs.NODE_LITERAL
local NODE_BINARY_EXPR = defs.NODE_BINARY_EXPR
local NODE_UNARY_EXPR  = defs.NODE_UNARY_EXPR
local NODE_CALL_EXPR   = defs.NODE_CALL_EXPR
local NODE_METHOD_CALL = defs.NODE_METHOD_CALL
local NODE_FUNC_DECL   = defs.NODE_FUNC_DECL
local NODE_FUNC_EXPR   = defs.NODE_FUNC_EXPR

local OP_EQ  = defs.OP_EQ
local OP_NE  = defs.OP_NE
local OP_NOT = defs.OP_NOT

local FLAG_HAS_ELSE = defs.FLAG_HAS_ELSE

local LIT_STRING  = defs.LIT_STRING
local LIT_NUMBER  = defs.LIT_NUMBER
local LIT_BOOLEAN = defs.LIT_BOOLEAN
local LIT_NIL     = defs.LIT_NIL

local SIX_TAGS = { ["nil"] = true, boolean = true, number = true, string = true, table = true, ["function"] = true }

-- Same `Ctx`/AST-arena shapes prover_narrow.lua declares (structural, not
-- imported -- each module owns its own copy per the two-pass boundary's
-- own duplication precedent -- see this module's header).
--:: ASTNode = { kind: integer, flags: integer, line: integer, col: integer, data: { [integer]: integer } }
--:: ASTNodeArena = { get: (ASTNodeArena, integer) -> ASTNode, ... }
--:: ListPool = { get: (ListPool, integer) -> integer, ... }
--:: Ctx = { nodes: ASTNodeArena, lists: ListPool, pool: Pool, lexer: unknown, source_lines: string[] }

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

-- BUGFIX (found while adding v4's call-RHS multi-member combinator, see
-- module header and TODO.md): this function's own comment above already
-- claimed "right-associated," but the code as written accumulated
-- LEFT-to-right (`term = TyUnion(term, next_term)`, folding forward) --
-- structurally identical to a right fold ONLY when `members` has exactly
-- 2 entries (the overwhelming common real-world/test case to date, which
-- is why this went undetected through runs 1-4's entire measurement
-- history and every hand-built theory test). For 3+ members the two folds
-- produce DIFFERENT terms, and `build_ty_sub_to_union`'s own trans-
-- chaining loop below structurally REQUIRES the true right fold (each
-- step's invariant is `suffix_union(i) == ty_union(members[i],
-- suffix_union(i+1))`, which only a right fold satisfies) -- exposed by
-- this v4 work's own first-ever 3-member-union fixture. Fixed here by
-- folding from the LAST member backward.
--: (FixpointVocab, string[]) -> (Term | nil, string | nil)
local function build_declared_union(vocab, members)
	if #members == 0 then return nil, "build_declared_union: empty member list" end
	local term, err = tag_term_of(vocab, members[#members])
	if not term then return nil, err end
	for i = #members - 1, 1, -1 do
		local head_term, herr = tag_term_of(vocab, members[i])
		if not head_term then return nil, herr end
		term, err = vocab.TyUnion(head_term, term)
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
-- Build the suffix union starting at `from` (Rest for union-here-left, or
-- the base term for union-here-right's own `B`), i.e. the same
-- right-associated spine `build_declared_union` builds, restricted to
-- `members[from..]`. Standalone (not nested inside `build_ty_sub_to_union`)
-- because the branch-join handling below (control-flow chaining) also needs
-- it directly, to build a guard's own `Rest` term without going through a
-- literal-reassignment's tag first.
-- BUGFIX: same left-vs-right-fold defect as `build_declared_union` above
-- (identical root cause, same fix -- fold from the last member backward).
--: (FixpointVocab, string[], integer) -> (Term | nil, string | nil)
local function suffix_union(vocab, members, from)
	local term, err = tag_term_of(vocab, members[#members])
	if not term then return nil, err end
	for i = #members - 1, from, -1 do
		local head_term, herr = tag_term_of(vocab, members[i])
		if not head_term then return nil, herr end
		term, err = vocab.TyUnion(head_term, term)
		if not term then return nil, err end
	end
	return term
end

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
		local rest_term, rerr = suffix_union(vocab, members, pos + 1)
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
		local rest_term, rerr = suffix_union(vocab, members, i + 1)
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

-- One entry per distinct name_id declared by a CHUNK-TOP-LEVEL function-
-- defining statement (see module header). `count > 1` means the name is
-- declared more than once at chunk top level -- ambiguous, never resolved.
--:: TopLevelFuncEntry = { count: integer, decl_line: integer }
--:: TopLevelFuncIndex = { [integer]: TopLevelFuncEntry }

-- Same shape as prover_narrow.lua's own (unexported) `Ctx` -- `lexer` typed
-- precisely (not `unknown`, unlike THIS module's own `Ctx` above, which
-- never previously needed to look inside `lexer`) because
-- `find_preceding_func_annotation_fp` indexes `ctx0.lexer.annotations`
-- directly, mirroring prover_narrow.lua's own `find_preceding_func_annotation`.
--:: Ctx0 = {
--::   nodes: ASTNodeArena, lists: ListPool, pool: Pool,
--::   lexer: { annotations: { [integer]: { kind: integer, content: string } } },
--::   source_lines: string[],
--:: }

--:: EmitCtx = {
--::   addr_ops: AddrOps, file_id: Term, vocab: FixpointVocab, ax_initial: AxiomDecl,
--::   rp: Replayer, stats: Stats, judgments: ReplayResult[],
--::   toplevel_funcs: TopLevelFuncIndex, ctx0: Ctx0,
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

-- ── Assignment transfer from an annotated-call RHS: helpers ──────────────
-- (see module header). Small pure helpers duplicated from prover_narrow.lua
-- (same two-pass duplication discipline this module already follows for
-- `path_of`/`extend_path`/`strip_not`/`extract_guard_fp`/etc.) -- adapted
-- here to additionally capture the RETURN type `R`, which prover_narrow
-- .lua's own `parse_param_type_slices` explicitly documents as "never
-- parsed -- this pilot has no use for it" (true for prover_narrow.lua's own
-- purposes; not true for this module's).

--: (string) -> string[]
local function split_source_lines_fp(source)
	local lines = {} --[[: string[] ]]
	local i = 1
	local len = #source
	while i <= len do
		local nl = source:find("\n", i, true)
		if nl then
			lines[#lines + 1] = source:sub(i, nl - 1)
			i = nl + 1
		else
			lines[#lines + 1] = source:sub(i)
			break
		end
	end
	return lines
end

--: (string) -> boolean
local function is_blank_or_comment_line_fp(line_text)
	return line_text:match("^%s*$") ~= nil or line_text:match("^%s*%-%-") ~= nil
end

-- Build the chunk-top-level function-name index (module header): walks
-- ONLY the file's own root statement list (never recurses into any nested
-- block) for the three function-defining shapes prover_narrow.lua's own
-- `analyze_block` already recognizes, restricted here to a BARE-IDENTIFIER
-- name only (a dotted/method name, e.g. `function M.foo()`/`function
-- obj:method()`, or an `M.foo = function() end` assignment target, can
-- never be reached by a bare-identifier call site, so is not indexed at
-- all -- not a skip, simply not a candidate).
--: (Ctx0, integer, integer) -> TopLevelFuncIndex
local function build_toplevel_func_index(ctx0, root_stmt_start, root_stmt_len)
	local index = {} --[[: TopLevelFuncIndex ]]
	--: (integer, integer) -> ()
	local function record(name_id, decl_line)
		local e = index[name_id]
		if e then
			e.count = e.count + 1
		else
			index[name_id] = { count = 1, decl_line = decl_line }
		end
	end
	for i = 0, root_stmt_len - 1 do
		local nid = ctx0.lists:get(root_stmt_start + i)
		local n = ctx0.nodes:get(nid)
		if n.kind == NODE_FUNC_DECL then
			-- Covers both `function f() end` and `local function f() end`
			-- (same node kind -- see lib/type/static/parse.lua). A dotted/
			-- method name's own `data[0]` is a NODE_FIELD_EXPR, not a
			-- NODE_IDENTIFIER -- excluded.
			local name_node = ctx0.nodes:get(n.data[0])
			if name_node.kind == NODE_IDENTIFIER then
				record(name_node.data[0], n.line)
			end
		elseif n.kind == NODE_LOCAL_STMT then
			local names_len, el = n.data[1], n.data[3]
			if names_len == 1 and el == 1 then
				local init_nid = ctx0.lists:get(n.data[2])
				local init_n = ctx0.nodes:get(init_nid)
				if init_n.kind == NODE_FUNC_EXPR then
					local name_id = ctx0.lists:get(n.data[0])
					record(name_id, init_n.line)
				end
			end
		elseif n.kind == NODE_ASSIGN_STMT then
			local tl, el = n.data[1], n.data[3]
			if tl == 1 and el == 1 then
				local target_nid = ctx0.lists:get(n.data[0])
				local target_n = ctx0.nodes:get(target_nid)
				if target_n.kind == NODE_IDENTIFIER then
					local init_nid = ctx0.lists:get(n.data[2])
					local init_n = ctx0.nodes:get(init_nid)
					if init_n.kind == NODE_FUNC_EXPR then
						record(target_n.data[0], init_n.line)
					end
				end
			end
		end
	end
	return index
end

-- Locate a callee's own preceding-line `--: (T1, ...) -> R` annotation,
-- duplicated from prover_narrow.lua's `find_preceding_func_annotation`
-- (same line-association rule: inline takes priority; else scan backward
-- skipping blank/comment-only lines, requiring a run of exactly one
-- ANN_TYPE entry -- 2+ is an ambiguous overload, distinctly reported here
-- as "return type not resolvable" rather than prover_narrow.lua's own
-- "not supported for positional parameter attribution" wording, since this
-- module has no parameters to attribute at all).
--: (Ctx0, integer) -> ({ kind: integer, content: string } | nil, string | nil)
local function find_preceding_func_annotation_fp(ctx0, decl_line)
	local inline = ctx0.lexer.annotations[decl_line]
	if inline and inline.kind == defs.ANN_TYPE then return inline, nil end
	local ann_lines = {} --[[: integer[] ]]
	local scan = decl_line - 1
	while scan >= 1 do
		local a = ctx0.lexer.annotations[scan]
		if a and a.kind == defs.ANN_TYPE then
			ann_lines[#ann_lines + 1] = scan
			scan = scan - 1
		elseif not a and ctx0.source_lines[scan] and is_blank_or_comment_line_fp(ctx0.source_lines[scan]) then
			scan = scan - 1
		else
			break
		end
	end
	if #ann_lines == 0 then return nil, "callee has no resolvable function-type annotation" end
	if #ann_lines > 1 then
		return nil, "callee has multiple preceding function-type annotations (overload) -- return type not resolvable"
	end
	return ctx0.lexer.annotations[ann_lines[1]], nil
end

-- Extract the RAW return-type string `R` from a `(T1, ...) -> R`
-- annotation's content, via the SAME balanced-paren scan as prover_narrow
-- .lua's `parse_param_type_slices` (duplicated, not imported -- see this
-- function's own header note: that module explicitly never parses `R`).
--: (string) -> (string | nil, string | nil)
local function parse_return_type_raw(content)
	local s = content:match("^%s*(.-)%s*$") or content
	if s:sub(1, 1) ~= "(" then
		return nil, "callee annotation is not in '(T1, ...) -> R' form"
	end
	local depth = 0
	local close_idx = nil --[[: integer | nil ]]
	for i = 1, #s do
		local c = s:sub(i, i)
		if c == "(" or c == "{" then
			depth = depth + 1
		elseif c == ")" or c == "}" then
			depth = depth - 1
			if depth == 0 then
				close_idx = i
				break
			end
		end
	end
	if not close_idx then return nil, "callee annotation is not in '(T1, ...) -> R' form" end
	local after = s:sub(close_idx + 1):match("^%s*(.-)%s*$") or ""
	if after:sub(1, 2) ~= "->" then
		return nil, "callee annotation is not in '(T1, ...) -> R' form"
	end
	local r = after:sub(3):match("^%s*(.-)%s*$") or ""
	return r, nil
end

-- Parse the return type's own raw string into an ordered, deduplicated
-- six-tag-class member list -- same vocabulary/rejection discipline as
-- prover_narrow.lua's `parse_annotation_members` (duplicated: that
-- function is a local, not exported). A parenthesized `R` (`-> (A, B)`,
-- i.e. a declared multi-return) is REJECTED here, distinctly: this module
-- only ever transfers a call's FIRST (and, per the annotation, ONLY)
-- return value -- multi-return is out of scope per the brief.
--: (string) -> (string[] | nil, string | nil)
local function parse_return_members(r)
	if r:sub(1, 1) == "(" then
		return nil, "callee return annotation declares multiple return values (first-value-only scope)"
	end
	local members = {} --[[: string[] ]]
	local seen = {} --[[: { [string]: boolean } ]]
	for tok in r:gmatch("[^|]+") do
		local name = tok:match("^%s*(.-)%s*$")
		if name == "" then return nil, "callee return annotation: empty union member" end
		if not SIX_TAGS[name] then
			return nil, "callee return annotation: unsupported annotation member '" .. name
				.. "' (not one of the six type() classes)"
		end
		if seen[name] then return nil, "callee return annotation: duplicate annotation member '" .. name .. "'" end
		seen[name] = true
		members[#members + 1] = name
	end
	if #members == 0 then return nil, "callee return annotation: empty annotation" end
	return members, nil
end

-- Resolve a bare-identifier callee's declared return-type member list, or
-- nil + a taxonomy-stable skip reason (module header enumerates every
-- reason this can fail; never guessed, never silently defaulted).
--: (EmitCtx, integer) -> (string[] | nil, string | nil)
local function resolve_callee_return_members(ectx, callee_name_id)
	local entry = ectx.toplevel_funcs[callee_name_id]
	if not entry then return nil, "callee is not a same-file top-level function declaration (unresolvable)" end
	if entry.count > 1 then
		return nil, "callee name has multiple same-file top-level declarations (ambiguous, not resolvable)"
	end
	local ann, aerr = find_preceding_func_annotation_fp(ectx.ctx0, entry.decl_line)
	if not ann then return nil, aerr end
	local raw_r, rerr = parse_return_type_raw(ann.content)
	if not raw_r then return nil, rerr end
	return parse_return_members(raw_r)
end

-- Tail of a members list (`members[2..]`) -- used by
-- `build_ty_sub_union_to_union`'s own recursion (peeling one member at a
-- time), distinct from `suffix_union` (which builds a TERM, not a list).
--: (string[]) -> string[]
local function members_tail(members)
	local out = {} --[[: string[] ]]
	for i = 2, #members do out[#out + 1] = members[i] end
	return out
end

-- Build `ty_sub(Tp, Tinv)` when `Tp` is ITSELF a union of `tp_members`
-- (a callee's declared return annotation can be a multi-member union, e.g.
-- `string | nil` -- unlike a literal reassignment's `Tp`, always a single
-- tag). Generalizes `build_ty_sub_to_union` (single-tag case, reused
-- directly as the base case) by peeling one member of `Tp` at a time and
-- combining via the ALREADY-declared `ty-sub-union-of-subsets` rule --
-- the SAME rule `narrow-join`'s own branch-merge already cites for exactly
-- this "both halves of a union individually sub Tinv" shape; no new theory
-- content needed for this combinator, purely prover-side reuse.
--: (FixpointVocab, string[], string[], Term) -> (CertNode | nil, string | nil)
local function build_ty_sub_union_to_union(vocab, tp_members, tinv_members, tinv_term)
	if #tp_members == 0 then return nil, "empty callee return-type union" end
	if #tp_members == 1 then
		return build_ty_sub_to_union(vocab, tp_members[1], tinv_members, tinv_term)
	end
	local head_node, herr = build_ty_sub_to_union(vocab, tp_members[1], tinv_members, tinv_term)
	if not head_node then return nil, herr end
	local rest_node, rerr = build_ty_sub_union_to_union(vocab, members_tail(tp_members), tinv_members, tinv_term)
	if not rest_node then return nil, rerr end
	return { kind = "rule", rule = vocab.rule_ty_sub_union_of_subsets, premises = { head_node, rest_node } } --[[: CertNode ]]
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

-- Strip at most one leading `not`. Returns (inner_node_id, negated).
-- Duplicated from prover_narrow.lua (small pure helper -- see this module's
-- header, "Why a sibling module", on the two-pass precedent's own
-- duplication discipline: this module already duplicates several such
-- helpers from prover_narrow.lua/prover.lua rather than importing them).
--: (Ctx, integer) -> (integer, boolean)
local function strip_not(ctx, nid)
	local n = ctx.nodes:get(nid)
	if n.kind == NODE_UNARY_EXPR and n.data[0] == OP_NOT then
		return n.data[1], true
	end
	return nid, false
end

--:: GuardHitFP = { var_name_id: integer, target: string, then_is_match: boolean }

--: (ASTNode, ASTNode, integer) -> GuardHitFP | nil
local function extract_nil_check_fp(ident_side, lit_side, op)
	if ident_side.kind == NODE_IDENTIFIER and lit_side.kind == NODE_LITERAL and lit_side.data[0] == LIT_NIL then
		return { var_name_id = ident_side.data[0], target = "nil", then_is_match = (op == OP_EQ) }
	end
	return nil
end

--: (Ctx, ASTNode, ASTNode, integer) -> GuardHitFP | nil
local function extract_type_check_fp(ctx, call_side, lit_side, op)
	if call_side.kind ~= NODE_CALL_EXPR then return nil end
	if lit_side.kind ~= NODE_LITERAL or lit_side.data[0] ~= LIT_STRING then return nil end
	if call_side.data[2] ~= 1 then return nil end
	local callee = ctx.nodes:get(call_side.data[0])
	if callee.kind ~= NODE_IDENTIFIER then return nil end
	local callee_name = intern_mod.get(ctx.pool, callee.data[0])
	if callee_name ~= "type" then return nil end
	local arg_nid = ctx.lists:get(call_side.data[1])
	local arg = ctx.nodes:get(arg_nid)
	if arg.kind ~= NODE_IDENTIFIER then return nil end
	local type_str = intern_mod.get(ctx.pool, lit_side.data[1])
	if not type_str or not SIX_TAGS[type_str] then return nil end
	return { var_name_id = arg.data[0], target = type_str, then_is_match = (op == OP_EQ) }
end

-- Extract one of the three in-scope guard shapes (`type(x)==`/`x==nil`/bare
-- truthiness) from an if-clause's own test expression. Duplicated from
-- prover_narrow.lua's `extract_guard` (same duplication discipline -- see
-- this module's header). Returns nil if the test is not one of the three
-- recognized shapes at all (not a skip -- simply not a guard).
--: (Ctx, integer) -> GuardHitFP | nil
local function extract_guard_fp(ctx, test_nid)
	local inner_nid, negated = strip_not(ctx, test_nid)
	local n = ctx.nodes:get(inner_nid)

	if n.kind == NODE_IDENTIFIER then
		return { var_name_id = n.data[0], target = "falsy", then_is_match = negated }
	end

	if n.kind ~= NODE_BINARY_EXPR then return nil end
	local op = n.data[0]
	if op ~= OP_EQ and op ~= OP_NE then return nil end
	if negated then return nil end
	local lhs = ctx.nodes:get(n.data[1])
	local rhs = ctx.nodes:get(n.data[2])

	local nil_check = extract_nil_check_fp(lhs, rhs, op) or extract_nil_check_fp(rhs, lhs, op)
	if nil_check then return nil_check end

	return extract_type_check_fp(ctx, lhs, rhs, op) or extract_type_check_fp(ctx, rhs, lhs, op)
end

-- The declared-union member name a guard's `target` removes: a truthiness
-- guard's target is the marker "falsy" (not a literal member name), and it
-- always removes "nil". Duplicated from prover_narrow.lua's own
-- `member_removed_by`.
--: (string) -> string
local function member_removed_by_fp(target)
	if target == "falsy" then return "nil" end
	return target
end

--:: WalkState = {
--::   node: CertNode, point: Term, term: Term, sub_node: CertNode, h1_live: boolean,
--:: }

local walk_stmts --: ((EmitCtx, Term, Term, integer, ScopeVar, Ctx, integer[], integer, integer, WalkState, boolean, boolean) -> (WalkState, boolean, string | nil)) | nil

-- Walk a flat statement list -- the loop body itself (`allow_if = true`), or
-- a single if/else branch's own body reached from there (`allow_if = false`
-- -- one level of nesting only, see below) -- threading a running
-- `WalkState` through each statement via the persistence/assignment-transfer
-- rules this module's header documents. Returns the end state, or
-- `ok = false` + a taxonomy-stable `fail_reason` on the first unrecognized/
-- out-of-scope statement (chain abandoned there, honestly -- never a
-- fabricated fact, per the fixpoint proposal's §8.3 correction).
--
-- ── Control-flow chaining (if/else), added here ──────────────────────────
--
-- A `NODE_IF_STMT` with exactly one clause (no elseif -- see below) is
-- handled by deriving each branch's own fact independently, then merging via
-- the fixpoint theory's join rule
-- (docs/typechecker-v10-fixpoint-proposal.md §4, `cf_join`/`narrow-join`,
-- already declared in fixpoint_v1.lua's v3 signature bump). Both branches
-- are ALWAYS re-grounded fresh via `pilot-initial-facts-v1` asserting the
-- DECLARED union `Tinv` at the if-statement's own point (`Pg =
-- entry_of(if_stmt_path)`) -- this is always honest regardless of what
-- narrower fact (if any) was already known for `X` entering the if, because
-- `Tinv` is `X`'s SCOPE-WIDE declared type for its whole enclosing scope
-- (see this module's own precedent for `PreLoop := LH`, and
-- prover_narrow.lua's header on `--:` annotations being scope-wide, never
-- merely describing an initial value) -- never a claim that some OTHER,
-- narrower fact is what holds at that point. Consequence: `h1_live` is
-- unconditionally severed (set false) the moment an if-statement is
-- processed, regardless of its value entering the if -- the same
-- degenerate/vacuous-discharge reading this module's header already
-- documents for a literal reassignment, extended identically here (neither
-- branch's own derivation traces back to `h1`; vacuous discharge is fully
-- legal per the theory).
--
-- A guard on the tracked variable `X` narrows via `narrow-select-match`/
-- `narrow-select-rest` (flow_narrow_v1's rules, unchanged in the v3
-- signature bump) exactly as prover.lua's own existing narrowing prover
-- does, reusing the SAME structural-first-member scope limit pilot has
-- always had (prover_narrow.lua's own header: a guard only narrows when its
-- target is the union's own STRUCTURALLY FIRST declared member -- since
-- this module always re-grounds to `Tinv` in DECLARED member order, this is
-- simply `guard target == sv.members[1]`). A guard recognized on a
-- DIFFERENT variable, or whose target isn't the first declared member, or
-- that isn't one of the three recognized shapes at all, or whose own
-- variable reference is inside an already-shadowed region (see
-- `already_shadowed` below), is NOT treated as an error -- it degrades to
-- the UNGUARDED reading (both branches simply get `Tinv`, always honest,
-- merely less precise) rather than aborting the chain.
--
-- Each branch's own body is walked via THIS SAME function with
-- `allow_if = false`: a nested if/while/for/etc. inside a branch falls
-- through to the SAME generic "control-flow statement breaks persistence
-- chaining" reason as any other unrecognized top-level construct (one level
-- of if/else chaining only, per the brief's own taxonomy: "nested if"
-- defeats analysis). An `elseif` chain (`clauses_len > 1`) is ALSO a
-- counted skip, a distinct, explicitly out-of-scope case: the join rule as
-- designed (docs/typechecker-v10-fixpoint-proposal.md §4) is strictly
-- binary; chaining an N-way join was not designed there and is not invented
-- here.
--
-- An if-branch with an empty body needs no special case at all: this same
-- function, called with `stmt_len = 0`, returns the entry state UNCHANGED
-- (the `for` loop simply never runs) -- `cf_join`'s own Pa/Pb are honestly
-- satisfied by using the branch's ENTRY point directly in that case (no
-- axiom relating entry_of/exit_of of the same path is needed, unlike the
-- empty-LOOP-body case, because `cf_join` never required an "exit_of a
-- block" reading to begin with -- see docs/typechecker-v10-fixpoint-
-- proposal.md §4.1, which only fixes a READING for the non-empty case).
--
-- ── Shadowing across the if-statement (`already_shadowed`) ───────────────
--
-- `already_shadowed`, when true, means the OUTER context (before this
-- `walk_stmts` call even starts) has ALREADY shadowed `name_id` -- every
-- occurrence of that intern id within THIS statement list (including one
-- inside a nested if-statement's own branches, recursively) refers to the
-- shadow, never the tracked `X`. This is threaded all the way down into a
-- branch's own recursive `walk_stmts` call (forcing its own local
-- `shadow_index` to 0, i.e. shadowed from its very first statement) --
-- otherwise a branch that does NOT itself redeclare `name_id` would wrongly
-- treat an assignment to the (already-shadowed) name as touching the
-- tracked `X`'s own identity path: a genuinely FALSE `assign_literal`/
-- `assign_copies` axiom citation, the one thing this module's header calls
-- out as unforgivable. Guard recognition on the if-statement's own test is
-- likewise suppressed when `already_shadowed` (an identifier match there is
-- the shadow, not `X`) -- falls back to the always-safe unguarded reading,
-- never treated as an error.
--: (EmitCtx, Term, Term, integer, ScopeVar, Ctx, integer[], integer, integer, WalkState, boolean, boolean) -> (WalkState, boolean, string | nil)
walk_stmts = function(ectx, x_path, tinv_term, name_id, sv, ctx, block_path, stmt_start, stmt_len, state, already_shadowed, allow_if)
	if not walk_stmts then return state, false, "internal: walk_stmts not yet bound" end
	local addr_ops, vocab = ectx.addr_ops, ectx.vocab
	local shadow_index = already_shadowed and 0 or shadow_index_for(ctx, stmt_start, stmt_len, name_id)

	local cur_node, cur_point, cur_term, cur_sub_node, h1_live =
		state.node, state.point, state.term, state.sub_node, state.h1_live

	for i = 0, stmt_len - 1 do
		local stmt_path = extend_path(block_path, i)
		local nid = ctx.lists:get(stmt_start + i)
		local n = ctx.nodes:get(nid)
		local kind = n.kind
		local shadowed = i >= shadow_index

		local stmt_path_term, sperr = path_of(addr_ops, stmt_path)
		if not stmt_path_term then
			return state, false, "failed to build statement path: " .. tostring(sperr)
		end
		local new_point, neperr = prover_addr.exit(addr_ops, ectx.file_id, stmt_path_term)
		if not new_point then
			return state, false, "failed to build statement exit point: " .. tostring(neperr)
		end

		if kind == NODE_LOCAL_STMT or kind == NODE_EXPR_STMT then
			local node, perr = persist(ectx, cur_node, cur_point, new_point, x_path)
			if not node then return state, false, perr end
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
				if not node then return state, false, perr end
				cur_node, cur_point = node, new_point
			elseif tl ~= 1 or el ~= 1 then
				return state, false, "multi-target/multi-value assignment to the invariant variable (out of scope)"
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
					if not tag_term then return state, false, "failed to build literal tag: " .. tostring(tterr) end
					local fact = { kind = "axiom", axiom = vocab.ax_assign_literal_facts,
						bindings = { Pa = new_point, X = x_path, Tag = tag_term } } --[[: CertNode ]]
					local node = { kind = "rule", rule = vocab.rule_assign_literal_transfer, premises = { fact } } --[[: CertNode ]]
					local result, rerr = rl.observe(ectx.rp, node)
					if not result then
						return state, false, "replay rejected assign-literal-transfer: " .. tostring(rerr)
					end
					local ty_of_tag, toerr = vocab.TyOf(tag_term)
					if not ty_of_tag then return state, false, "failed to build ty_of(tag): " .. tostring(toerr) end
					local member_name = declared_member_name_for_literal(tagname)
					local lit_sub_node, serr = build_ty_sub_to_union(vocab, member_name, sv.members, tinv_term)
					if not lit_sub_node then return state, false, serr or "failed to build ty_sub(Tp, Tinv)" end
					cur_node, cur_point, cur_term, cur_sub_node = node, new_point, ty_of_tag, lit_sub_node
					h1_live = false
				elseif rhs.kind == NODE_IDENTIFIER then
					-- Known scope reduction (module header): neither
					-- self-copy nor cross-variable copy is attempted.
					return state, false, "copy source not independently established at the assign point"
				elseif rhs.kind == NODE_METHOD_CALL then
					return state, false, "method call callee out of scope (not statically resolvable)"
				elseif rhs.kind == NODE_CALL_EXPR then
					local callee_nid = rhs.data[0]
					local callee = ctx.nodes:get(callee_nid)
					if callee.kind ~= NODE_IDENTIFIER then
						return state, false, "computed callee (not a bare identifier, not statically resolvable)"
					end
					local callee_name_id = callee.data[0]
					-- Block-local shadow check only -- see module header's
					-- reported, NOT-closed soundness scope limit on
					-- callee-name shadowing from an enclosing scope.
					local shadow_at = shadow_index_for(ctx, stmt_start, stmt_len, callee_name_id)
					if i >= shadow_at then
						return state, false, "callee identifier locally shadowed within the loop body "
							.. "(not statically resolvable to a single same-file declaration)"
					end
					local ret_members, rmerr = resolve_callee_return_members(ectx, callee_name_id)
					if not ret_members then
						return state, false, rmerr or "callee return type not resolvable"
					end
					local t_term, tterr = build_declared_union(vocab, ret_members)
					if not t_term then
						return state, false, "failed to build callee return type: " .. tostring(tterr)
					end
					local fact = { kind = "axiom", axiom = vocab.ax_assign_call_facts,
						bindings = { Pa = new_point, X = x_path, T = t_term } } --[[: CertNode ]]
					local node = { kind = "rule", rule = vocab.rule_assign_call_transfer, premises = { fact } } --[[: CertNode ]]
					local result, rerr2 = rl.observe(ectx.rp, node)
					if not result then
						return state, false, "replay rejected assign-call-transfer: " .. tostring(rerr2)
					end
					local call_sub_node, cserr = build_ty_sub_union_to_union(vocab, ret_members, sv.members, tinv_term)
					if not call_sub_node then
						return state, false, cserr or "failed to build ty_sub(Tp, Tinv) for call-RHS"
					end
					cur_node, cur_point, cur_term, cur_sub_node = node, new_point, t_term, call_sub_node
					h1_live = false
				else
					return state, false, "assignment RHS out of scope "
						.. "(not literal, bare-identifier copy, or annotated same-file call)"
				end
			end

		elseif kind == NODE_IF_STMT and allow_if then
			local clauses_len = n.data[1]
			if clauses_len ~= 1 then
				return state, false, "elseif chain in loop body not yet supported for branch-join chaining (out of scope)"
			end
			local has_else = band(n.flags, FLAG_HAS_ELSE) ~= 0
			local clauses_start, else_start, else_len = n.data[0], n.data[2], n.data[3]
			local clause_nid = ctx.lists:get(clauses_start)
			local cl = ctx.nodes:get(clause_nid)
			local test_nid, then_start, then_len = cl.data[0], cl.data[1], cl.data[2]
			local then_body_path = extend_path(stmt_path, prover_addr.if_clause_body_index(0))
			local else_body_path = extend_path(stmt_path, prover_addr.if_else_index(1))

			local pg, pgerr = prover_addr.entry(addr_ops, ectx.file_id, stmt_path_term)
			if not pg then return state, false, "failed to build if-statement guard point: " .. tostring(pgerr) end
			local init_node_g = { kind = "axiom", axiom = ectx.ax_initial,
				bindings = { P = pg, X = x_path, T = tinv_term } } --[[: CertNode ]]

			local guard_hit = (not shadowed) and extract_guard_fp(ctx, test_nid) or nil
			local is_guarded = false
			local guard_then_is_match = false
			local ta_term --[[: Term | nil ]]
			local rest_term --[[: Term | nil ]]
			if guard_hit and guard_hit.var_name_id == name_id
				and member_removed_by_fp(guard_hit.target) == sv.members[1] then
				local tag_ty, tterr = tag_term_of(vocab, sv.members[1])
				local rest_ty, rerr = suffix_union(vocab, sv.members, 2)
				if tag_ty and rest_ty then
					ta_term, rest_term, is_guarded = tag_ty, rest_ty, true
					guard_then_is_match = guard_hit.then_is_match
				end
			end

			local then_term --[[: Term ]]
			local then_sub_node --[[: CertNode ]]
			local then_use_match --[[: boolean ]]
			local else_term --[[: Term ]]
			local else_sub_node --[[: CertNode ]]
			local else_use_match --[[: boolean ]]
			if is_guarded and type(ta_term) == "table" and type(rest_term) == "table" then
				local ta_ty = ta_term
				local rest_ty = rest_term
				local ta_sub_node, ta_serr = build_ty_sub_to_union(vocab, sv.members[1], sv.members, tinv_term)
				if not ta_sub_node then return state, false, ta_serr or "failed to build ty_sub(TA, Tinv)" end
				local rest_sub_node = { kind = "axiom", axiom = vocab.ax_ty_sub_union_here_right,
					bindings = { X = ta_ty, B = rest_ty } } --[[: CertNode ]]
				if guard_then_is_match then
					then_term, then_sub_node, then_use_match = ta_ty, ta_sub_node, true
					else_term, else_sub_node, else_use_match = rest_ty, rest_sub_node, false
				else
					then_term, then_sub_node, then_use_match = rest_ty, rest_sub_node, false
					else_term, else_sub_node, else_use_match = ta_ty, ta_sub_node, true
				end
			else
				is_guarded = false
				local refl_tinv = { kind = "axiom", axiom = vocab.ax_ty_sub_refl, bindings = { A = tinv_term } } --[[: CertNode ]]
				then_term, then_sub_node, then_use_match = tinv_term, refl_tinv, false
				else_term, else_sub_node, else_use_match = tinv_term, refl_tinv, false
			end

			local then_body_term, tbterr = path_of(addr_ops, then_body_path)
			if not then_body_term then return state, false, "failed to build then-branch body path: " .. tostring(tbterr) end
			local then_entry_point, tepterr = prover_addr.entry(addr_ops, ectx.file_id, then_body_term)
			if not then_entry_point then return state, false, "failed to build then-branch entry point: " .. tostring(tepterr) end

			local else_entry_point --[[: Term ]]
			if has_else then
				local else_body_term, ebterr = path_of(addr_ops, else_body_path)
				if not else_body_term then return state, false, "failed to build else-branch body path: " .. tostring(ebterr) end
				local eep, eeperr = prover_addr.entry(addr_ops, ectx.file_id, else_body_term)
				if not eep then return state, false, "failed to build else-branch entry point: " .. tostring(eeperr) end
				else_entry_point = eep
			else
				-- No else block: the implicit "control skipped the if"
				-- edge is honestly anchored at the if's own guard point
				-- (see module header) -- no real branch body to walk.
				else_entry_point = pg
			end

			--: (integer[], integer, integer, Term, Term, CertNode, boolean) -> (WalkState | nil, string | nil)
			local function branch_state(branch_block_path, branch_start, branch_len, entry_point, entry_term, entry_sub_node, use_match)
				local entry_node --[[: CertNode ]]
				if is_guarded and type(ta_term) == "table" then
					local ta_ty = ta_term
					local fact = { kind = "axiom", axiom = vocab.ax_syntax_facts,
						bindings = { Pg = pg, Pb = entry_point, X = x_path, TA = ta_ty } } --[[: CertNode ]]
					local rule = use_match and vocab.rule_match or vocab.rule_rest
					entry_node = { kind = "rule", rule = rule, premises = { init_node_g, fact } } --[[: CertNode ]]
				else
					entry_node = { kind = "axiom", axiom = ectx.ax_initial,
						bindings = { P = entry_point, X = x_path, T = tinv_term } } --[[: CertNode ]]
				end
				local result, rerr = rl.observe(ectx.rp, entry_node)
				if not result then
					return nil, "replay rejected an if-branch entry citation: " .. tostring(rerr)
				end
				local branch_state_in = {
					node = entry_node, point = entry_point, term = entry_term, sub_node = entry_sub_node, h1_live = false,
				} --[[: WalkState ]]
				if not walk_stmts then return nil, "internal: walk_stmts not yet bound" end
				local out_state, bok, berr = walk_stmts(
					ectx, x_path, tinv_term, name_id, sv, ctx, branch_block_path, branch_start, branch_len,
					branch_state_in, shadowed, false)
				if not bok then return nil, berr end
				return out_state, nil
			end

			local then_out, then_err = branch_state(then_body_path, then_start, then_len, then_entry_point, then_term, then_sub_node, then_use_match)
			if not then_out then return state, false, then_err end

			local else_out, else_err
			if has_else then
				else_out, else_err = branch_state(else_body_path, else_start, else_len, else_entry_point, else_term, else_sub_node, else_use_match)
			else
				-- No real else body: a zero-statement walk over the
				-- (unused) if-statement's own path is a no-op, returning
				-- the entry state right back (see module header).
				else_out, else_err = branch_state(stmt_path, 0, 0, else_entry_point, else_term, else_sub_node, else_use_match)
			end
			if not else_out then return state, false, else_err end

			local pj = new_point
			local cf_fact = { kind = "axiom", axiom = vocab.ax_cf_join_facts,
				bindings = { Pa = then_out.point, Pb = else_out.point, Pj = pj } } --[[: CertNode ]]
			local join_node = { kind = "rule", rule = vocab.rule_narrow_join,
				premises = { then_out.node, else_out.node, cf_fact } } --[[: CertNode ]]
			local jresult, jrerr = rl.observe(ectx.rp, join_node)
			if not jresult then
				return state, false, "replay rejected a narrow-join citation: " .. tostring(jrerr)
			end

			local union_term, uerr = vocab.TyUnion(then_out.term, else_out.term)
			if not union_term then return state, false, "failed to build ty_union(A,B) for join: " .. tostring(uerr) end

			local joined_sub_node = { kind = "rule", rule = vocab.rule_ty_sub_union_of_subsets,
				premises = { then_out.sub_node, else_out.sub_node } } --[[: CertNode ]]
			local sresult, srerr = rl.observe(ectx.rp, joined_sub_node)
			if not sresult then
				return state, false, "replay rejected a ty-sub-union-of-subsets citation after a branch join: " .. tostring(srerr)
			end

			cur_node, cur_point, cur_term, cur_sub_node = join_node, pj, union_term, joined_sub_node
			h1_live = false

		else
			return state, false, "control-flow statement breaks persistence chaining (out of scope)"
		end
	end

	return { node = cur_node, point = cur_point, term = cur_term, sub_node = cur_sub_node, h1_live = h1_live }, true, nil
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

	local init_sub_node = { kind = "axiom", axiom = vocab.ax_ty_sub_refl, bindings = { A = tinv_term } } --[[: CertNode ]]
	local init_state = { node = h1, point = lh, term = tinv_term, sub_node = init_sub_node, h1_live = true } --[[: WalkState ]]

	if not walk_stmts then skip("internal: walk_stmts not yet bound") return end
	local final_state, ok, fail_reason = walk_stmts(
		ectx, x_path, tinv_term, name_id, sv, ctx, body_path, body_start, body_len, init_state, false, true)
	if not ok then
		skip(fail_reason or "unknown persistence-chain failure")
		return
	end

	local be = final_state.point
	local cur_node = final_state.node
	local sub_node = final_state.sub_node
	local h1_live = final_state.h1_live

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

	-- ctx0/toplevel_funcs: the chunk-top-level function-name index for
	-- assignment transfer from an annotated-call RHS (module header). A
	-- SEPARATE ctx table from prover_narrow.lua's own internal one (not
	-- referentially the same object -- structurally equivalent, built from
	-- the same parser/source), matching this module's established
	-- duplication-over-sharing discipline.
	local ctx0 = {
		nodes = parser.nodes, lists = parser.lists, pool = parser.pool, lexer = parser.lexer,
		source_lines = split_source_lines_fp(source),
	} --[[: Ctx0 ]]
	local root_node = parser.nodes:get(parser.root)
	local toplevel_funcs = build_toplevel_func_index(ctx0, root_node.data[0], root_node.data[1])

	local stats = M.new_stats()
	local judgments = {} --[[: ReplayResult[] ]]
	local ectx = {
		addr_ops = addr_ops, file_id = file_id, vocab = vocab, ax_initial = ax_initial,
		rp = rp, stats = stats, judgments = judgments,
		toplevel_funcs = toplevel_funcs, ctx0 = ctx0,
	} --[[: EmitCtx ]]

	walk_events(ectx, root.events)

	return { judgments = judgments, stats = stats }, nil
end

return M
