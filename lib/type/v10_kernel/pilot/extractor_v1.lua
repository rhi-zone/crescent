-- lib/type/v10_kernel/pilot/extractor_v1.lua
--
-- Corroboration line, engine build (iteration 3) — phase 2: the AST→base-facts
-- EXTRACTOR. The only component in the engine line that reads a parsed source
-- file. It contains NO analysis: it walks the real crescent parser's AST
-- (lib/type/static/parse.lua, borrowed black-box, never modified) and seeds
-- ground base facts into an engine store (pilot/engine.lua) via `engine.seed`,
-- i.e. as axiom CITATIONS against the already-declared schematic
-- reality-boundary axioms of the pilot theories. Everything an analysis needs
-- beyond raw structure is DERIVED downstream by the theories' own RuleDecls
-- run forward by the engine — nothing is concluded here.
--
-- fable-delegation-tier throughout (per the core design's pilot-execution
-- delegation note): every choice here is a delegated-execution decision,
-- re-openable on challenge, not an owner ratification.
--
-- ── The one structural finding this module is shaped by (READ THIS FIRST) ───
--
-- A certificate-emitting WALKER chooses which rule to cite. A forward-chaining
-- engine does not: every registered rule fires on every matching fact. The
-- narrowing theory's two rules share ONE premise pair —
--   narrow-select-match : holds_at(Pg,X,ty_union(TA,Rest)), guard_selects(Pg,Pb,X,TA) |- holds_at(Pb,X,TA)
--   narrow-select-rest  : same two premises                                          |- holds_at(Pb,X,Rest)
-- — so a single `guard_selects(Pg,Pb,X,TA)` fact run FORWARD derives BOTH
-- `holds_at(Pb,X,TA)` and `holds_at(Pb,X,Rest)` at the SAME point Pb.
-- Measured, not reasoned: seeding one guard fact with both rules registered
-- derives exactly those two facts (engine run, 2 new facts). One of them is
-- false of the source: on the then-branch of `type(x) == "string"`, x is
-- `string`, not `nil`.
--
-- The branch ROLE (match vs rest) lives nowhere in the judgment — flow_narrow_v1's
-- own header records that as deliberate ("Polarity ... and branch selection ...
-- are NOT encoded in the judgment or the rules at all — they are entirely the
-- prover's choice of which of the two rules below to cite"). That choice does
-- not exist for an engine. Closing this needs a THEORY-level decision (a
-- branch-role argument on the guard judgment and two rules keyed on it, or
-- some other mechanism) — it is NOT a fill-in this module is entitled to make,
-- so it is HALTED to the owner and this module implements only the sound
-- subset:
--
--   * `guard_selects` facts are emitted ONLY for the branch the guard's own
--     documented reading licenses — the branch reached WHEN THE GUARD SELECTS
--     `target_ty` — never for the complementary branch.
--   * A driver over this extractor must therefore register `narrow-select-match`
--     and NOT `narrow-select-rest`. Registering both re-introduces the false
--     derivation above. `M.SOUND_NARROW_RULES` below states this in code.
--
-- Consequence, stated plainly, not spun: rest-branch narrowing (the residual
-- type in an `else` block) is UNREACHABLE through this extractor until that
-- fork is decided. Match-branch narrowing at EVERY clause of an elseif chain
-- IS reachable (see "Elseif chains" below), which is the coverage gap phase 1
-- flagged.
--
-- ── Where the declared type enters (precedent, not a new idea) ──────────────
--
-- `pilot-initial-facts-v1` (holds_at(P,X,T), fully schematic) is cited at each
-- guard point, binding P to `exit_of(that clause's test-expression path)` —
-- exactly what `prover.lua` (pass 2) and `fixpoint_prover.lua` already do
-- (both re-ground the declared annotation at the guard point rather than
-- flowing it there). This module does not change that idiom. Anchoring the
-- annotation at the DECLARATION site instead and flowing it to the guard
-- would need a preservation fact for a NON-STATEMENT span (previous statement
-- exit → guard-test exit), and no declared judgment covers that span: the
-- effects theory's `stmt_preserves_fact` reads "the parser saw a single
-- STATEMENT spanning from..to that does not write to x", and fixpoint_v1's
-- `stmt_preserves` is likewise statement-paired. Stretching either reading to
-- cover an expression span, or minting a new span judgment, are both
-- semantics calls — recorded here as a substrate gap, not filled in.
--
-- ── Elseif chains: an ordinary branch point, no new vocabulary ──────────────
--
-- For `if a then A elseif b then B else C end`, clause k's guard fact binds
-- `Pb` to the point control reaches when THAT clause's guard selects its
-- target. When the match branch is the clause body, that is
-- `entry_of(clause k's body path)`. When the match branch is the guard's
-- FAILING continuation (e.g. `x ~= nil` selects `nil` on the else side), the
-- point is `entry_of(clause k+1's TEST path)` if another clause follows, or
-- `entry_of(the else block's path)` if the else block is the continuation.
-- Both are literally true readings of the axiom ("transfers control to Pb"),
-- so no vocabulary is invented and no reading is stretched. This is what makes
-- guard analysis reach every clause of a chain instead of single-clause `if`s.
--
-- ── Preservation edges: statement chains, spine-mediated ────────────────────
--
-- Inside a block, for each adjacent statement pair and each tracked variable
-- the statement structurally cannot write, one
-- `assign-effects-syntax-facts-v1` citation (`stmt_preserves_fact(A,B,X)`) is
-- emitted, spanning `entry_of(block path)`→`exit_of(stmt 0)` and then
-- `exit_of(stmt i-1)`→`exit_of(stmt i)`. Downstream, the effects theory's
-- `preserves-transfer` lifts each into the SPINE judgment and
-- `narrow-persist` composes it with narrowing — the flagship cross-theory
-- composition, now over whole statement chains in every branch rather than
-- `prover_effects.lua`'s single first statement of a single-clause `if`.
-- The negative check ("this statement does not write X") is performed HERE, on
-- the AST, structurally — per the effects theory's own recorded working
-- default ("negation internalized in the producing theory... that negative
-- check happens entirely on the PROVER side"). It is never guessed: an
-- unrecognized statement kind ENDS the chain (counted), it does not extend it.
--
-- Fixpoint_v1's own single-theory persistence route (`stmt_seq` +
-- `stmt_preserves` → `seq-persist`) is deliberately NOT emitted for the same
-- spans: it would derive the same `holds_at` facts by a single-theory path,
-- and since the engine dedups structurally-equal facts, whichever route
-- happened to fire first would own the provenance — making any
-- "composition-only" measurement an artifact of evaluation order rather than
-- of the theories. One route per span, recorded.
--
-- ── Deliberately NOT emitted (scope, recorded — not silent) ─────────────────
--
-- * `assign_copies` facts / `assign-copy-transfer`: the assign-copy-transfer
--   fork (TODO.md:50, self-copy especially) is PARKED pending an owner call.
--   Emitting these facts and registering that rule would resolve half of it
--   unilaterally (a forward engine derives the cross-variable case for free).
--   Left untouched.
-- * `assign_call` facts: would need callee resolution plus `--:` return-
--   annotation parsing (~fixpoint_prover.lua's §"callee resolution", 200+
--   lines duplicated here). Not emitted: it feeds only the loop-invariant
--   line, whose walker cannot be retired regardless (hypothesis-liveness, see
--   the phase-4 report), so it would add lines against the budget for no
--   derivation the measurement counts.
-- * `cf_join` (branch-join) facts: `narrow-join`'s premises need a `holds_at`
--   fact on BOTH branches. Under the sound subset above only the guard's
--   selected branch ever gets one, so a join fact could never fire — it would
--   be dead weight until the branch-role fork is decided, not a working edge.
--   Emitting it anyway would inflate the fact count with facts that derive
--   nothing.
-- * A standalone "call at P" or "function returns T" fact: no declared
--   judgment has a home for either (the theory folds return shapes into
--   `assign_call` at the assignment site). Not minted.
-- * Shadowing: when a `local` re-declares a tracked name, the name is DROPPED
--   from scope rather than re-tracked. Conservative: no fact is emitted about
--   a path that later occurrences no longer denote.

local ta = require("lib.type.v10_cleanroom.term_algebra")
-- Required for its type declarations (AxiomDecl/Term) only — this module
-- never calls the replayer: it seeds facts, and the kernel sees nothing but
-- the certificates the engine later exports. The direct require is needed
-- because type visibility does not survive the two-hop require through
-- `engine.lua` (TODO.md:48).
local _replayer_types = require("lib.type.v10_cleanroom.replayer")
local parse_mod = require("lib.type.static.parse")
local defs = require("lib.type.static.defs")
local intern_mod = require("lib.type.static.intern")
local bit_mod = require("bit")
local engine = require("lib.type.v10_kernel.pilot.engine")
local prover_addr = require("lib.type.v10_kernel.pilot.prover_addr")

local band = bit_mod.band

local M = {}

-- The narrowing rules a driver may register over this extractor's facts. See
-- the module header's structural finding: `narrow-select-rest` is NOT here,
-- and adding it derives facts that are false of the source.
M.SOUND_NARROW_RULES = { "narrow-select-match" }

local NODE_LOCAL_STMT  = defs.NODE_LOCAL_STMT
local NODE_IF_STMT     = defs.NODE_IF_STMT
local NODE_FUNC_DECL   = defs.NODE_FUNC_DECL
local NODE_FUNC_EXPR   = defs.NODE_FUNC_EXPR
local NODE_ASSIGN_STMT = defs.NODE_ASSIGN_STMT
local NODE_EXPR_STMT   = defs.NODE_EXPR_STMT
local NODE_BINARY_EXPR = defs.NODE_BINARY_EXPR
local NODE_UNARY_EXPR  = defs.NODE_UNARY_EXPR
local NODE_CALL_EXPR   = defs.NODE_CALL_EXPR
local NODE_IDENTIFIER  = defs.NODE_IDENTIFIER
local NODE_LITERAL     = defs.NODE_LITERAL

local OP_EQ  = defs.OP_EQ
local OP_NE  = defs.OP_NE
local OP_NOT = defs.OP_NOT

local LIT_NIL    = defs.LIT_NIL
local LIT_STRING = defs.LIT_STRING

local FLAG_HAS_ELSE = defs.FLAG_HAS_ELSE
local FLAG_VARARG   = defs.FLAG_VARARG

local SIX_TAGS = { ["nil"] = true, boolean = true, number = true, string = true, table = true, ["function"] = true }

--:: ASTNode = { kind: integer, flags: integer, line: integer, col: integer, data: { [integer]: integer } }
--:: ASTNodeArena = { get: (ASTNodeArena, integer) -> ASTNode, ... }
--:: ListPool = { get: (ListPool, integer) -> integer, ... }
--:: Pool = { ht_cap: integer, ht_mask: integer, ht_count: integer, next_id: integer, buf_count: integer, entries: { [integer]: unknown, ... }, bufs: { [integer]: unknown, ... }, rev: { [integer]: unknown, ... }, map: { [string]: integer, ... }, _anchors: { [integer]: string, ... }, ... }
--:: Ctx = { nodes: ASTNodeArena, lists: ListPool, pool: Pool, lexer: { annotations: { [integer]: { kind: integer, content: string } } } }

--:: AddrOps = { [string]: OpDecl }
--:: TrackedVar = { kind: "local" | "param", root_path: integer[], index: integer, members: string[] }
--:: VarScope = { [integer]: TrackedVar | nil }

-- Structural shapes of the injected vocabularies — exactly the fields this
-- module reads, declared locally rather than importing the producing modules'
-- own `NarrowVocab`/`AssignEffectsVocab` aliases. Requiring `flow_narrow_v1`
-- and `assign_effects_v1` purely to make two type names visible would couple
-- the extractor to ONE narrowing vocabulary at load time — the opposite of
-- the injection this module is built around (a driver may hand it
-- `flow_narrow_v1`'s v2 vocabulary or `fixpoint_v1`'s v4 one; both satisfy
-- the shape below).
--:: NarrowLike = {
--::   TyOf: (tag: Term) -> (Term | nil, string | nil),
--::   TyUnion: (a: Term, b: Term) -> (Term | nil, string | nil),
--::   tag_nil: () -> (Term | nil, string | nil),
--::   tag_boolean: () -> (Term | nil, string | nil),
--::   tag_number: () -> (Term | nil, string | nil),
--::   tag_string: () -> (Term | nil, string | nil),
--::   tag_table: () -> (Term | nil, string | nil),
--::   tag_function: () -> (Term | nil, string | nil),
--::   falsy_ty: () -> (Term | nil, string | nil),
--::   ax_syntax_facts: AxiomDecl,
--:: }
--:: EffectsLike = { ax_syntax_facts: AxiomDecl }

--:: ExtractorBundle = {
--::   addr_ops: AddrOps,
--::   file_id: Term,
--::   narrow: NarrowLike,
--::   ax_initial: AxiomDecl,
--::   effects: EffectsLike | nil,
--:: }

--:: ExtractStats = {
--::   guards_seeded: integer, initial_facts_seeded: integer,
--::   preserve_facts_seeded: integer, tracked_vars: integer,
--::   skipped: { [string]: integer },
--:: }

--: () -> ExtractStats
function M.new_stats()
	return {
		guards_seeded = 0, initial_facts_seeded = 0, preserve_facts_seeded = 0,
		tracked_vars = 0, skipped = {},
	}
end

--: (counts: { [string]: integer }, reason: string) -> ()
local function bump(counts, reason)
	counts[reason] = (counts[reason] or 0) + 1
end

--: (path: integer[], i: integer) -> integer[]
local function extend_path(path, i)
	local out = {} --[[: integer[] ]]
	for j, v in ipairs(path) do out[j] = v end
	out[#path + 1] = i
	return out
end

-- ── Annotation reading (syntax, no analysis) ────────────────────────────────
-- Same recognition rules as prover_narrow.lua/prover_effects.lua (six
-- `type()`-class names, `|`-separated, deduplicated, all-or-nothing). Kept
-- duplicated rather than shared, per this directory's own established
-- duplication discipline for parser-facing helpers.

--: (content: string) -> (string[] | nil, string | nil)
local function parse_annotation_members(content)
	local members = {} --[[: string[] ]]
	local seen = {} --[[: { [string]: boolean } ]]
	for tok in content:gmatch("[^|]+") do
		local name = tok:match("^%s*(.-)%s*$")
		if name == "" then return nil, "empty union member" end
		if not SIX_TAGS[name] then return nil, "unsupported annotation member" end
		if seen[name] then return nil, "duplicate annotation member" end
		seen[name] = true
		members[#members + 1] = name
	end
	if #members == 0 then return nil, "empty annotation" end
	return members, nil
end

--: (source: string) -> string[]
local function split_source_lines(source)
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

--: (line_text: string) -> boolean
local function is_blank_or_comment_line(line_text)
	return line_text:match("^%s*$") ~= nil or line_text:match("^%s*%-%-") ~= nil
end

--: (ctx: Ctx, source_lines: string[], decl_line: integer) -> { kind: integer, content: string } | nil
local function find_preceding_func_annotation(ctx, source_lines, decl_line)
	local inline = ctx.lexer.annotations[decl_line]
	if inline and inline.kind == defs.ANN_TYPE then return inline end
	local ann_lines = {} --[[: integer[] ]]
	local scan = decl_line - 1
	while scan >= 1 do
		local a = ctx.lexer.annotations[scan]
		if a and a.kind == defs.ANN_TYPE then
			ann_lines[#ann_lines + 1] = scan
			scan = scan - 1
		elseif not a and source_lines[scan] and is_blank_or_comment_line(source_lines[scan]) then
			scan = scan - 1
		else
			break
		end
	end
	if #ann_lines ~= 1 then return nil end
	return ctx.lexer.annotations[ann_lines[1]]
end

--: (content: string) -> (string[] | nil, string | nil)
local function parse_param_type_slices(content)
	local s = content:match("^%s*(.-)%s*$") or content
	if s:sub(1, 1) ~= "(" then return nil, "not in '(T1, ...) -> R' form" end
	local depth = 0
	local close_idx = nil --[[: integer | nil ]]
	for i = 1, #s do
		local c = s:sub(i, i)
		if c == "(" or c == "{" then
			depth = depth + 1
		elseif c == ")" or c == "}" then
			depth = depth - 1
			if depth == 0 then close_idx = i break end
		end
	end
	if not close_idx then return nil, "unbalanced parens" end
	local after = s:sub(close_idx + 1):match("^%s*(.-)%s*$") or ""
	if after:sub(1, 2) ~= "->" then return nil, "missing '->'" end
	local inner = s:sub(2, close_idx - 1)
	if inner:match("^%s*$") then return {}, nil end
	local slices = {} --[[: string[] ]]
	local depth2 = 0
	local start = 1
	for i = 1, #inner do
		local c = inner:sub(i, i)
		if c == "(" or c == "{" then
			depth2 = depth2 + 1
		elseif c == ")" or c == "}" then
			depth2 = depth2 - 1
		elseif c == "," and depth2 == 0 then
			slices[#slices + 1] = inner:sub(start, i - 1)
			start = i + 1
		end
	end
	slices[#slices + 1] = inner:sub(start)
	return slices, nil
end

-- ── Guard-shape recognition (syntax, no analysis) ───────────────────────────

--:: GuardExtract = { var_name_id: integer, target: string, then_is_match: boolean }

--: (ctx: Ctx, nid: integer) -> (integer, boolean)
local function strip_not(ctx, nid)
	local n = ctx.nodes:get(nid)
	if n.kind == NODE_UNARY_EXPR and n.data[0] == OP_NOT then
		return n.data[1], true
	end
	return nid, false
end

--: (ident_side: ASTNode, lit_side: ASTNode, op: integer) -> GuardExtract | nil
local function extract_nil_check(ident_side, lit_side, op)
	if ident_side.kind == NODE_IDENTIFIER and lit_side.kind == NODE_LITERAL and lit_side.data[0] == LIT_NIL then
		return { var_name_id = ident_side.data[0], target = "nil", then_is_match = (op == OP_EQ) }
	end
	return nil
end

--: (ctx: Ctx, call_side: ASTNode, lit_side: ASTNode, op: integer) -> GuardExtract | nil
local function extract_type_check(ctx, call_side, lit_side, op)
	if call_side.kind ~= NODE_CALL_EXPR then return nil end
	if lit_side.kind ~= NODE_LITERAL or lit_side.data[0] ~= LIT_STRING then return nil end
	if call_side.data[2] ~= 1 then return nil end
	local callee = ctx.nodes:get(call_side.data[0])
	if callee.kind ~= NODE_IDENTIFIER then return nil end
	if intern_mod.get(ctx.pool, callee.data[0]) ~= "type" then return nil end
	local arg = ctx.nodes:get(ctx.lists:get(call_side.data[1]))
	if arg.kind ~= NODE_IDENTIFIER then return nil end
	local type_str = intern_mod.get(ctx.pool, lit_side.data[1])
	if not type_str or not SIX_TAGS[type_str] then return nil end
	return { var_name_id = arg.data[0], target = type_str, then_is_match = (op == OP_EQ) }
end

--: (ctx: Ctx, test_nid: integer) -> GuardExtract | nil
local function extract_guard(ctx, test_nid)
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
	local nil_check = extract_nil_check(lhs, rhs, op) or extract_nil_check(rhs, lhs, op)
	if nil_check then return nil_check end
	return extract_type_check(ctx, lhs, rhs, op) or extract_type_check(ctx, rhs, lhs, op)
end

-- ── Term construction over the injected vocabularies ────────────────────────

--: (addr_ops: AddrOps, indices: integer[]) -> (Term | nil, string | nil)
local function path_of(addr_ops, indices)
	local p, err = prover_addr.root(addr_ops)
	if not p then return nil, err end
	for _, i in ipairs(indices) do
		p, err = prover_addr.child(addr_ops, p, i)
		if not p then return nil, err end
	end
	return p
end

--: (vocab: NarrowLike, target: string) -> (Term | nil, string | nil)
local function target_term_of(vocab, target)
	if target == "falsy" then return vocab.falsy_ty() end
	local tag = nil --[[: Term | nil ]]
	local tag_err = nil --[[: string | nil ]]
	if target == "nil" then tag, tag_err = vocab.tag_nil()
	elseif target == "boolean" then tag, tag_err = vocab.tag_boolean()
	elseif target == "number" then tag, tag_err = vocab.tag_number()
	elseif target == "string" then tag, tag_err = vocab.tag_string()
	elseif target == "table" then tag, tag_err = vocab.tag_table()
	elseif target == "function" then tag, tag_err = vocab.tag_function()
	else return nil, "target_term_of: unrecognized target " .. tostring(target) end
	if not tag then return nil, tag_err end
	return vocab.TyOf(tag)
end

--: (members: string[], without: string) -> string[]
local function member_set_without(members, without)
	local out = {} --[[: string[] ]]
	for _, m in ipairs(members) do if m ~= without then out[#out + 1] = m end end
	return out
end

--: (target: string) -> string
local function member_removed_by(target)
	if target == "falsy" then return "nil" end
	return target
end

-- Left-folded union over an ordered member list.
--: (vocab: NarrowLike, members: string[]) -> (Term | nil, string | nil)
local function build_union(vocab, members)
	if #members == 0 then return nil, "build_union: empty member list" end
	local term, err = target_term_of(vocab, members[1])
	if not term then return nil, err end
	for i = 2, #members do
		local next_term, nerr = target_term_of(vocab, members[i])
		if not next_term then return nil, nerr end
		term, err = vocab.TyUnion(term, next_term)
		if not term then return nil, err end
	end
	return term
end

--: (members: string[], target: string) -> boolean
local function contains_member(members, target)
	for _, m in ipairs(members) do if m == target then return true end end
	return false
end

-- ── The walk ────────────────────────────────────────────────────────────────

--:: Walk = {
--::   store: Store, bundle: ExtractorBundle, ctx: Ctx,
--::   source_lines: string[], stats: ExtractStats,
--:: }

--: (w: Walk, tv: TrackedVar) -> (Term | nil, string | nil)
local function var_identity_path(w, tv)
	local addr_ops = w.bundle.addr_ops
	local root, rerr = path_of(addr_ops, tv.root_path)
	if not root then return nil, rerr end
	if tv.kind == "param" then
		return prover_addr.func_param_path(addr_ops, root, tv.index)
	end
	return prover_addr.local_name_path(addr_ops, root, tv.index)
end

-- Does this statement structurally leave `name_id`'s binding untouched?
-- Returns (verified_safe, chain_continues). A statement that is not one of the
-- recognized non-interfering shapes ENDS the chain — never assumed safe.
--: (ctx: Ctx, n: ASTNode, name_id: integer) -> (boolean, boolean)
local function stmt_preserves_var(ctx, n, name_id)
	local kind = n.kind
	if kind == NODE_EXPR_STMT then return true, true end
	if kind == NODE_LOCAL_STMT then return true, true end
	if kind == NODE_ASSIGN_STMT then
		local tl = n.data[1]
		for i = 0, tl - 1 do
			local target_n = ctx.nodes:get(ctx.lists:get(n.data[0] + i))
			if target_n.kind == NODE_IDENTIFIER and target_n.data[0] == name_id then
				return false, true
			end
		end
		return true, true
	end
	return false, false
end

-- Seed the declared-type fact and the guard fact for one recognized guard
-- clause. `match_point_indices` is the path of the branch control reaches
-- WHEN THE GUARD SELECTS `ge.target` (see header: only that branch is ever
-- asserted); `match_is_block_entry` distinguishes a branch BODY (entry_of the
-- body block) from a following clause's TEST (entry_of the test expression) —
-- both are `entry_of` of the given path, so the flag exists only for clarity
-- at the call sites and is not used to vary the term.
--: (w: Walk, ge: GuardExtract, tv: TrackedVar, test_indices: integer[], match_indices: integer[]) -> ()
local function seed_guard(w, ge, tv, test_indices, match_indices)
	local bundle = w.bundle
	local addr_ops, narrow = bundle.addr_ops, bundle.narrow

	local var_path, vperr = var_identity_path(w, tv)
	if not var_path then
		bump(w.stats.skipped, "failed to build variable identity path: " .. tostring(vperr))
		return
	end
	local target_term, tterr = target_term_of(narrow, ge.target)
	if not target_term then
		bump(w.stats.skipped, "failed to build target type: " .. tostring(tterr))
		return
	end
	local rest_members = member_set_without(tv.members, member_removed_by(ge.target))
	local rest_term, rerr = build_union(narrow, rest_members)
	if not rest_term then
		bump(w.stats.skipped, "failed to build rest type: " .. tostring(rerr))
		return
	end
	-- Target-first: `narrow-select-match`'s premise is holds_at(Pg,X,ty_union(TA,Rest))
	-- and matching is structural, so the declared union must be built with the
	-- guard's own target as the LEFT member for the rule to fire at all.
	local whole_term, uerr = narrow.TyUnion(target_term, rest_term)
	if not whole_term then
		bump(w.stats.skipped, "failed to build declared union: " .. tostring(uerr))
		return
	end
	local test_path, tperr = path_of(addr_ops, test_indices)
	if not test_path then
		bump(w.stats.skipped, "failed to build test path: " .. tostring(tperr))
		return
	end
	local guard_point, gperr = prover_addr.exit(addr_ops, bundle.file_id, test_path)
	if not guard_point then
		bump(w.stats.skipped, "failed to build guard point: " .. tostring(gperr))
		return
	end
	local match_path, mperr = path_of(addr_ops, match_indices)
	if not match_path then
		bump(w.stats.skipped, "failed to build match branch path: " .. tostring(mperr))
		return
	end
	local branch_point, bperr = prover_addr.entry(addr_ops, bundle.file_id, match_path)
	if not branch_point then
		bump(w.stats.skipped, "failed to build match branch point: " .. tostring(bperr))
		return
	end

	local f1, e1 = engine.seed(w.store, bundle.ax_initial, { P = guard_point, X = var_path, T = whole_term })
	if not f1 and e1 then
		bump(w.stats.skipped, "seed rejected the declared-type fact: " .. tostring(e1))
		return
	end
	if f1 then w.stats.initial_facts_seeded = w.stats.initial_facts_seeded + 1 end

	local f2, e2 = engine.seed(w.store, narrow.ax_syntax_facts,
		{ Pg = guard_point, Pb = branch_point, X = var_path, TA = target_term })
	if not f2 and e2 then
		bump(w.stats.skipped, "seed rejected the guard fact: " .. tostring(e2))
		return
	end
	if f2 then w.stats.guards_seeded = w.stats.guards_seeded + 1 end
end

-- Seed one preservation fact (spine route) for a statement span.
-- `from_point` is typed `unknown` and narrowed by hand: it reaches here from a
-- `Term | nil` chain variable, and a checked cast cannot discharge the `nil`
-- (full subtyping is required) — the same runtime-guard-plus-cast shape every
-- other pilot module in this directory uses at an injection boundary.
--: (w: Walk, tv: TrackedVar, from_point: unknown, to_indices: integer[]) -> ()
local function seed_preserve(w, tv, from_point, to_indices)
	if type(from_point) ~= "table" then return end
	local from = from_point --[[: Term ]]
	local bundle = w.bundle
	local effects = bundle.effects
	if not effects then return end
	local addr_ops = bundle.addr_ops
	local var_path, vperr = var_identity_path(w, tv)
	if not var_path then
		bump(w.stats.skipped, "failed to build variable identity path: " .. tostring(vperr))
		return
	end
	local to_path, tperr = path_of(addr_ops, to_indices)
	if not to_path then
		bump(w.stats.skipped, "failed to build statement path: " .. tostring(tperr))
		return
	end
	local to_point, toerr = prover_addr.exit(addr_ops, bundle.file_id, to_path)
	if not to_point then
		bump(w.stats.skipped, "failed to build statement exit point: " .. tostring(toerr))
		return
	end
	local f, err = engine.seed(w.store, effects.ax_syntax_facts, { A = from, B = to_point, X = var_path })
	if not f then
		if err then bump(w.stats.skipped, "seed rejected the preservation fact: " .. tostring(err)) end
		return
	end
	w.stats.preserve_facts_seeded = w.stats.preserve_facts_seeded + 1
end

--: (ctx: Ctx, source_lines: string[], func_indices: integer[], ps: integer, pl: integer, decl_line: integer) -> VarScope
local function param_scope(ctx, source_lines, func_indices, ps, pl, decl_line)
	local scope = {} --[[: VarScope ]]
	if pl == 0 then return scope end
	local ann = find_preceding_func_annotation(ctx, source_lines, decl_line)
	if not ann then return scope end
	local slices = parse_param_type_slices(ann.content)
	if not slices then return scope end
	if #slices ~= pl then return scope end
	for i = 0, pl - 1 do
		local raw = slices[i + 1]
		local slice = raw:match("^%s*(.-)%s*$") or raw
		local members = parse_annotation_members(slice)
		if members and #members >= 2 then
			scope[ctx.lists:get(ps + i)] = { kind = "param", root_path = func_indices, index = i, members = members }
		end
	end
	return scope
end

local walk_block --: ((Walk, integer[], integer, integer, VarScope) -> ()) | nil

-- Walk one block: `block_indices` is the block's own addr path, its statements
-- are children 0..stmt_len-1 of it (prover_addr's block rule).
--: (w: Walk, block_indices: integer[], stmt_start: integer, stmt_len: integer, scope: VarScope) -> ()
walk_block = function(w, block_indices, stmt_start, stmt_len, scope)
	if not walk_block then return end
	local ctx = w.ctx
	local addr_ops = w.bundle.addr_ops

	-- The preservation chain's current "from" point: the block's own entry
	-- until a statement has been crossed, then that statement's exit. `nil`
	-- once an unrecognized statement has broken the chain.
	local block_path, bperr = path_of(addr_ops, block_indices)
	local chain_from = nil --[[: Term | nil ]]
	if block_path then
		chain_from = prover_addr.entry(addr_ops, w.bundle.file_id, block_path)
	else
		bump(w.stats.skipped, "failed to build block path: " .. tostring(bperr))
	end

	for i = 0, stmt_len - 1 do
		local n = ctx.nodes:get(ctx.lists:get(stmt_start + i))
		local stmt_indices = extend_path(block_indices, i)
		local kind = n.kind

		-- Preservation edges across this statement, one per tracked variable,
		-- before any scope change this statement makes.
		local from_point = chain_from
		if from_point then
			local any_broken = false
			for name_id, tv in pairs(scope) do
				local safe, continues = stmt_preserves_var(ctx, n, name_id)
				if not continues then
					any_broken = true
				elseif safe and tv then
					seed_preserve(w, tv, from_point, stmt_indices)
				end
			end
			if any_broken then
				chain_from = nil
			else
				local sp = path_of(addr_ops, stmt_indices)
				if sp then
					chain_from = prover_addr.exit(addr_ops, w.bundle.file_id, sp)
				else
					chain_from = nil
				end
			end
		end

		if kind == NODE_LOCAL_STMT then
			local names_len = n.data[1]
			-- Shadowing: any re-declared tracked name stops being tracked (see
			-- header) — the tracked path no longer denotes what later
			-- occurrences of the name mean.
			for j = 0, names_len - 1 do
				local nid = ctx.lists:get(n.data[0] + j)
				if scope[nid] then
					scope[nid] = nil
					bump(w.stats.skipped, "tracked variable shadowed by a later local declaration")
				end
			end
			local ann = ctx.lexer.annotations[n.line]
			if ann and ann.kind == defs.ANN_TYPE and names_len == 1 then
				local members = parse_annotation_members(ann.content)
				if members and #members >= 2 then
					scope[ctx.lists:get(n.data[0])] =
						{ kind = "local", root_path = stmt_indices, index = 0, members = members }
					w.stats.tracked_vars = w.stats.tracked_vars + 1
				end
			end

		elseif kind == NODE_IF_STMT then
			local clauses_len = n.data[1]
			local has_else = band(n.flags, FLAG_HAS_ELSE) ~= 0
			for c = 0, clauses_len - 1 do
				local cl = ctx.nodes:get(ctx.lists:get(n.data[0] + c))
				local ge = extract_guard(ctx, cl.data[0])
				local tv = ge and scope[ge.var_name_id]
				if ge and tv and #tv.members >= 2 and contains_member(tv.members, member_removed_by(ge.target)) then
					local test_indices = extend_path(stmt_indices, prover_addr.if_clause_test_index(c))
					local match_indices = nil --[[: integer[] | nil ]]
					if ge.then_is_match then
						match_indices = extend_path(stmt_indices, prover_addr.if_clause_body_index(c))
					elseif c + 1 < clauses_len then
						-- Elseif chain: the guard's failing continuation is the
						-- NEXT clause's test expression.
						match_indices = extend_path(stmt_indices, prover_addr.if_clause_test_index(c + 1))
					elseif has_else then
						match_indices = extend_path(stmt_indices, prover_addr.if_else_index(clauses_len))
					else
						bump(w.stats.skipped, "guard's selected branch is the (absent) else continuation")
					end
					if match_indices then
						seed_guard(w, ge, tv, test_indices, match_indices)
					end
				end
			end
			-- Walk into every branch with an independent scope copy: facts found
			-- inside a branch never leak to siblings.
			for c = 0, clauses_len - 1 do
				local cl = ctx.nodes:get(ctx.lists:get(n.data[0] + c))
				local body_indices = extend_path(stmt_indices, prover_addr.if_clause_body_index(c))
				local sub = {} --[[: VarScope ]]
				for k, v in pairs(scope) do sub[k] = v end
				walk_block(w, body_indices, cl.data[1], cl.data[2], sub)
			end
			if has_else then
				local else_indices = extend_path(stmt_indices, prover_addr.if_else_index(clauses_len))
				local sub = {} --[[: VarScope ]]
				for k, v in pairs(scope) do sub[k] = v end
				walk_block(w, else_indices, n.data[2], n.data[3], sub)
			end

		elseif kind == NODE_FUNC_DECL then
			local ps, pl = n.data[1], n.data[2]
			if band(n.flags, FLAG_VARARG) == 0 then
				local body_indices = extend_path(stmt_indices, prover_addr.func_body_index(pl))
				local fscope = param_scope(ctx, w.source_lines, stmt_indices, ps, pl, n.line)
				for _ in pairs(fscope) do w.stats.tracked_vars = w.stats.tracked_vars + 1 end
				walk_block(w, body_indices, n.data[3], n.data[4], fscope)
			else
				bump(w.stats.skipped, "vararg function: parameter positions not addressable")
			end
		end

		-- `local f = function(...) end` / `f = function(...) end`: the func-expr
		-- is an init/RHS child of the owning statement (prover_addr's rule).
		if kind == NODE_LOCAL_STMT and n.data[1] == 1 and n.data[3] == 1 then
			local init = ctx.nodes:get(ctx.lists:get(n.data[2]))
			if init.kind == NODE_FUNC_EXPR and band(init.flags, FLAG_VARARG) == 0 then
				local fn_indices = extend_path(stmt_indices, 1)
				local ps, pl = init.data[0], init.data[1]
				local body_indices = extend_path(fn_indices, prover_addr.func_body_index(pl))
				local fscope = param_scope(ctx, w.source_lines, fn_indices, ps, pl, n.line)
				for _ in pairs(fscope) do w.stats.tracked_vars = w.stats.tracked_vars + 1 end
				walk_block(w, body_indices, init.data[2], init.data[3], fscope)
			end
		elseif kind == NODE_ASSIGN_STMT and n.data[1] == 1 and n.data[3] == 1 then
			local init = ctx.nodes:get(ctx.lists:get(n.data[2]))
			if init.kind == NODE_FUNC_EXPR and band(init.flags, FLAG_VARARG) == 0 then
				local fn_indices = extend_path(stmt_indices, 0)
				local ps, pl = init.data[0], init.data[1]
				local body_indices = extend_path(fn_indices, prover_addr.func_body_index(pl))
				local fscope = param_scope(ctx, w.source_lines, fn_indices, ps, pl, n.line)
				for _ in pairs(fscope) do w.stats.tracked_vars = w.stats.tracked_vars + 1 end
				walk_block(w, body_indices, init.data[2], init.data[3], fscope)
			end
		end
	end
end

--- Extract one file's base facts into `store`. Caps-clean: the source text is
--- a parameter (the caller reads the file), and every vocabulary/axiom object
--- arrives through `bundle` — nothing is declared or reached for here.
--: (store: Store, bundle: unknown, source: string, file_path: string) -> (ExtractStats | nil, string | nil)
function M.extract(store, bundle, source, file_path)
	if type(source) ~= "string" then return nil, "extract: source must be a string" end
	if type(file_path) ~= "string" then return nil, "extract: file_path must be a string" end
	if type(bundle) ~= "table" then return nil, "extract: bundle must be an ExtractorBundle" end
	local b = bundle --[[: ExtractorBundle ]]
	if type(b.addr_ops) ~= "table" or type(b.file_id) ~= "table" then
		return nil, "extract: bundle must carry addr_ops and a file_id term"
	end
	if type(b.narrow) ~= "table" or type(b.ax_initial) ~= "table" then
		return nil, "extract: bundle must carry a narrowing vocabulary and the initial-facts axiom"
	end

	local ok, parser = pcall(parse_mod.parse, source, file_path)
	if not ok then return nil, "extract: parse error: " .. tostring(parser) end
	local pr = parser --[[: { nodes: ASTNodeArena, lists: ListPool, pool: Pool, root: integer, lexer: { annotations: { [integer]: { kind: integer, content: string } } } } ]]

	local w = {
		store = store, bundle = b,
		ctx = { nodes = pr.nodes, lists = pr.lists, pool = pr.pool, lexer = pr.lexer },
		source_lines = split_source_lines(source),
		stats = M.new_stats(),
	}

	local root_node = pr.nodes:get(pr.root)
	walk_block(w, {}, root_node.data[0], root_node.data[1], {})
	return w.stats, nil
end

--- Build the addr-v1 `file_id` term for a source text — the one piece of
--- addressing a driver needs before it can assemble a bundle. Thin re-export
--- so a driver never has to require `prover_addr` itself.
--: (addr_ops: unknown, source: string) -> (Term | nil, string | nil)
function M.file_id_of_source(addr_ops, source)
	if type(addr_ops) ~= "table" then return nil, "file_id_of_source: addr_ops is required" end
	local ops = addr_ops --[[: AddrOps ]]
	if type(source) ~= "string" then return nil, "file_id_of_source: source must be a string" end
	return prover_addr.file_id_of_source(ops, source)
end

return M
