-- lib/type/v10_kernel/pilot/prover_effects.lua
--
-- Corroboration proof-of-concept, spine step 4 (certificate-emitting
-- prover) — the composed narrow-persist derivation over REAL crescent
-- source. A NEW, deliberately NARROW, self-contained AST walk (not a
-- modification of prover_narrow.lua/prover.lua — see "Why a fresh, narrow
-- walk" below), citing flow_narrow_v1's rules, assign_effects_v1's rules,
-- and narrow_persist_v1's composed rule, over the canonical v10 core.
--
-- fable-delegation-tier throughout (per the core design's pilot-execution
-- delegation note): every choice here is a delegated-execution decision,
-- re-openable on challenge, not an owner ratification.
--
-- ── What this module finds and certifies ────────────────────────────────────
--
-- For every `--:`-annotated, 2-member six-tag-union local or parameter
-- (same recognition rule as prover_narrow.lua's own `parse_annotation_members`
-- /`param_scope`, duplicated here per that module's own established
-- duplication discipline — see its header), guarded by a SINGLE-CLAUSE
-- `if <guard> then <A> else <B> end` (no elseif — see scope note below) on
-- one of the three recognized guard shapes: derives the match-branch's
-- `holds_at(entry_of(A), X, target)` (flow_narrow_v1's `narrow-select-match`,
-- exactly as prover.lua's own real-file citation does), THEN, if branch A's
-- own FIRST statement is structurally verified (never guessed) to be
-- non-interfering with X — a bare call-expression statement
-- (`NODE_EXPR_STMT`) or a fresh local declaration (`NODE_LOCAL_STMT`, which
-- can never rebind X: it always introduces a binding at a path distinct
-- from X's own declaration site, the same reasoning
-- lib/type/v10_kernel/pilot/fixpoint_prover.lua's header already documents
-- for its own §8.3 rule (a)) — cites `assign_effects_v1`'s
-- `preserves-transfer` for that one statement's span, then
-- `narrow_persist_v1`'s `narrow-persist` to derive `holds_at` at
-- `exit_of(that statement's own path)`: a point narrowing's OWN rules
-- (flow_narrow_v1.lua) have no way to reach, since narrowing has no
-- sequencing/persistence vocabulary of its own at all — see this module's
-- companion test, `prover_effects_test.lua`, for the fail-closed/derives/
-- scale-to-zero three-leg proof this real-file prover feeds evidence into.
--
-- ── Why a fresh, narrow walk, not a reuse/extension of prover_narrow.lua ────
--
-- prover_narrow.lua's own pass-1 event tree (by design, per its header)
-- records events ONLY for constructs its OWN rule set (flow_narrow_v1) can
-- cite: annotated locals and guards. A plain call-expression statement or
-- an assignment to an unrelated variable — precisely the "non-interfering
-- statement" this module needs to find and address — produces NO event at
-- all in that tree (confirmed by reading `analyze_block`: only
-- `NODE_LOCAL_STMT`-with-annotation, `NODE_IF_STMT`, `NODE_WHILE_STMT`,
-- `NODE_REPEAT_STMT`/`NODE_DO_STMT` wrapping, `NODE_FUNC_DECL`, and a
-- narrow func-expr-assignment case ever emit an event). Reaching a plain
-- statement's own raw AST node and its own (body_start, body_len) position
-- therefore needs a walk over the REAL AST directly — the same conclusion
-- `fixpoint_prover.lua`'s own header already reached and documented for
-- its own (unrelated) loop-body walk. This module's walk is deliberately
-- MUCH narrower than either existing prover (single-clause if only, no
-- elseif/while/repeat/do, one safety check per guard rather than a full
-- statement-chain walk) — sufficient to demonstrate genuine cross-theory
-- composition on real source without re-deriving either existing prover's
-- full generality.
--
-- ── Explicit, flagged scope limits (not silent) ─────────────────────────────
--
-- - Only SINGLE-CLAUSE `if ... then ... else ... end` (or no else) is
--   recognized; an elseif chain is a counted skip.
-- - Only the MATCH branch's own first statement is checked for
--   non-interference (never the rest branch, never a chain of statements);
--   a match branch whose first statement is not a bare call or a fresh
--   local declaration is a counted skip — never a fabricated citation.
-- - An `if` with no `else` still qualifies (the match branch is addressable
--   regardless — same reasoning flow_narrow_v1/prover.lua already rely on).
-- - Function bodies (`NODE_FUNC_DECL`/`NODE_FUNC_EXPR`, both the
--   `function f() end` and `local f = function() end` / `f = function()
--   end` forms) are walked into, one level of parameter tracking, exactly
--   mirroring prover_narrow.lua's own recognized shapes — but nested
--   functions inside a function body are NOT walked into further (one
--   level of scope only) — a counted skip, never silently ignored.

local ta = require("lib.type.v10_cleanroom.term_algebra")
local rl = require("lib.type.v10_cleanroom.replayer")
local parse_mod = require("lib.type.static.parse")
local defs = require("lib.type.static.defs")
local intern_mod = require("lib.type.static.intern")
local bit_mod = require("bit")
local addr_v1 = require("lib.type.v10_kernel.pilot.addr_v1")
local flow_narrow_v1 = require("lib.type.v10_kernel.pilot.flow_narrow_v1")
local pilot_initial_facts_v1 = require("lib.type.v10_kernel.pilot.pilot_initial_facts_v1")
local effects_spine_v1 = require("lib.type.v10_kernel.pilot.effects_spine_v1")
local assign_effects_v1 = require("lib.type.v10_kernel.pilot.assign_effects_v1")
local narrow_persist_v1 = require("lib.type.v10_kernel.pilot.narrow_persist_v1")
local prover_addr = require("lib.type.v10_kernel.pilot.prover_addr")

local band = bit_mod.band

local M = {}

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

--:: ScopeVar = { kind: "local" | "param", root_path: integer[], index: integer, members: string[] }
--:: Scope = { [integer]: ScopeVar }

--:: Stats = {
--::   guards_found: integer, guards_certified: integer, guards_skipped: { [string]: integer },
--::   persist_certified: integer, persist_skipped: { [string]: integer },
--:: }

--: () -> Stats
function M.new_stats()
	return { guards_found = 0, guards_certified = 0, guards_skipped = {}, persist_certified = 0, persist_skipped = {} }
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

-- Parse a `--:` annotation's raw content into an ordered, deduplicated list
-- of the six `type()`-class names. Duplicated from prover_narrow.lua's own
-- `parse_annotation_members` (same six-tag/duplication discipline).
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

-- Split `source` into a 1-indexed array of lines. Duplicated from
-- prover_narrow.lua's `split_source_lines` (needed here for the SAME
-- preceding-line function-annotation scan that module performs).
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

-- Locate the `--: (T1, ...) -> R` annotation for a function statement at
-- `decl_line`. Duplicated from prover_narrow.lua's
-- `find_preceding_func_annotation` (same line-association rule: inline
-- takes priority; else scan backward skipping blank/comment-only lines,
-- requiring exactly one ANN_TYPE entry — 2+ is an ambiguous overload,
-- skipped).
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
	if #ann_lines == 0 then return nil end
	if #ann_lines > 1 then return nil end
	return ctx.lexer.annotations[ann_lines[1]]
end

-- Split a `(T1, T2, ...) -> R` function-type annotation's raw content into
-- per-parameter raw type slices. Duplicated from prover_narrow.lua's
-- `parse_param_type_slices` (same top-level-comma splitting, tracked over
-- nested parens/braces).
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

-- Build the scope entries for a function's own qualifying (2+ member,
-- annotated) parameters. Duplicated from prover_narrow.lua's `param_scope`,
-- simplified: this module has no `Stats`-shaped skip-reason bookkeeping for
-- annotation parsing (only for guard/persistence bookkeeping — see `Stats`
-- above), so failures here are silent narrowing of scope, not a counted
-- skip — an acceptable reduction for a demonstration-scope prover (never a
-- FALSE positive: a parameter is added to scope only when its annotation
-- parses cleanly and its slice count matches).
--: (ctx: Ctx, source_lines: string[], func_path: integer[], ps: integer, pl: integer, decl_line: integer, has_vararg: boolean) -> Scope
local function param_scope(ctx, source_lines, func_path, ps, pl, decl_line, has_vararg)
	local scope = {} --[[: Scope ]]
	if pl == 0 or has_vararg then return scope end
	local ann = find_preceding_func_annotation(ctx, source_lines, decl_line)
	if not ann then return scope end
	local slices, _perr = parse_param_type_slices(ann.content)
	if not slices then return scope end
	if #slices ~= pl then return scope end
	for i = 0, pl - 1 do
		local raw = slices[i + 1]
		local slice = raw:match("^%s*(.-)%s*$") or raw
		local members = parse_annotation_members(slice)
		if members and #members >= 2 then
			local name_id = ctx.lists:get(ps + i)
			scope[name_id] = { kind = "param", root_path = func_path, index = i, members = members }
		end
	end
	return scope
end

--:: GuardExtract = { var_name_id: integer, target: string, then_is_match: boolean }

-- Strip at most one leading `not`. Duplicated from prover_narrow.lua.
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
	local callee_name = intern_mod.get(ctx.pool, callee.data[0])
	if callee_name ~= "type" then return nil end
	local arg_nid = ctx.lists:get(call_side.data[1])
	local arg = ctx.nodes:get(arg_nid)
	if arg.kind ~= NODE_IDENTIFIER then return nil end
	local type_str = intern_mod.get(ctx.pool, lit_side.data[1])
	if not type_str or not SIX_TAGS[type_str] then return nil end
	return { var_name_id = arg.data[0], target = type_str, then_is_match = (op == OP_EQ) }
end

-- Duplicated from prover_narrow.lua's own `extract_guard`.
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

--:: AddrOps = { [string]: OpDecl }
--:: TheoryStack = {
--::   addr_ops: AddrOps, file_id: Term, narrow: NarrowVocab, ax_initial: AxiomDecl,
--::   spine: EffectsSpine, effects: AssignEffectsVocab, persist: NarrowPersist,
--::   rp: Replayer, stats: Stats, judgments: ReplayResult[],
--::   ctx: Ctx, root_path: Term, source_lines: string[],
--:: }
--:: NarrowPersist = { rule_persist: RuleDecl }

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

--: (addr_ops: AddrOps, root_path: Term, sv: ScopeVar) -> (Term | nil, string | nil)
local function var_identity_path(addr_ops, root_path, sv)
	if sv.kind == "param" then
		return prover_addr.func_param_path(addr_ops, root_path, sv.index)
	end
	return prover_addr.local_name_path(addr_ops, root_path, sv.index)
end

--: (vocab: NarrowVocab, target: string) -> (Term | nil, string | nil)
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

-- Build a union term over an ordered member list.
--: (vocab: NarrowVocab, members: string[]) -> (Term | nil, string | nil)
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

-- Given the match branch's own (body_start, body_len), check whether
-- statement 0 structurally does not interfere with `name_id`. Returns
-- (safe: boolean, reason_if_not: string | nil). NEVER guesses: an
-- unrecognized statement kind, or an assignment naming `name_id` among its
-- (possibly multiple) targets, is `false` with a reason.
--: (ctx: Ctx, body_start: integer, body_len: integer, name_id: integer) -> (boolean, string | nil)
local function first_stmt_is_safe(ctx, body_start, body_len, name_id)
	if body_len == 0 then return false, "empty branch body: no statement to address" end
	local nid = ctx.lists:get(body_start)
	local n = ctx.nodes:get(nid)
	if n.kind == NODE_EXPR_STMT then return true, nil end
	if n.kind == NODE_LOCAL_STMT then return true, nil end
	if n.kind == NODE_ASSIGN_STMT then
		local tl = n.data[1]
		for i = 0, tl - 1 do
			local target_nid = ctx.lists:get(n.data[0] + i)
			local target_n = ctx.nodes:get(target_nid)
			if target_n.kind == NODE_IDENTIFIER and target_n.data[0] == name_id then
				return false, "first statement assigns to the tracked variable"
			end
		end
		return true, nil
	end
	return false, "first statement is not a recognized non-interfering shape (bare call / local / safe assign)"
end

-- Cite the match-branch derivation and, if licensed, the composed
-- persistence step. `if_path` is the if-statement's own addr path;
-- `body_start`/`body_len` are the match branch's (clause 0, or the else
-- block when the guard's match reading is the else branch) raw statement
-- range; `body_path` is that branch's own addr path.
--: (stack: TheoryStack, ge: GuardExtract, sv: ScopeVar, root_path: Term, if_path: integer[], body_path: integer[], body_start: integer, body_len: integer) -> ()
local function certify_guard(stack, ge, sv, root_path, if_path, body_path, body_start, body_len)
	local addr_ops, narrow = stack.addr_ops, stack.narrow
	stack.stats.guards_found = stack.stats.guards_found + 1

	local var_path, vperr = var_identity_path(addr_ops, root_path, sv)
	local target_term, tterr = target_term_of(narrow, ge.target)
	if not var_path or not target_term then
		bump(stack.stats.guards_skipped, "failed to build var path / target term: " .. tostring(vperr or tterr))
		return
	end
	local rest_members = member_set_without(sv.members, member_removed_by(ge.target))
	local rest_term, rerr = build_union(narrow, rest_members)
	if not rest_term then
		bump(stack.stats.guards_skipped, "failed to build rest term: " .. tostring(rerr))
		return
	end
	local whole_term, uerr = narrow.TyUnion(target_term, rest_term)
	local test_path = extend_path(if_path, prover_addr.if_clause_test_index(0))
	local test_path_term, tpterr = path_of(addr_ops, test_path)
	if not whole_term or not test_path_term then
		bump(stack.stats.guards_skipped, "failed to build whole union / test path: " .. tostring(uerr or tpterr))
		return
	end
	local guard_point, gperr = prover_addr.exit(addr_ops, stack.file_id, test_path_term)
	local body_path_term, bpterr = path_of(addr_ops, body_path)
	if not guard_point or not body_path_term then
		bump(stack.stats.guards_skipped, "failed to build guard point / body path: " .. tostring(gperr or bpterr))
		return
	end
	local branch_point, brperr = prover_addr.entry(addr_ops, stack.file_id, body_path_term)
	if not branch_point then
		bump(stack.stats.guards_skipped, "failed to build branch entry point: " .. tostring(brperr))
		return
	end

	local init_node = {
		kind = "axiom", axiom = stack.ax_initial,
		bindings = { P = guard_point, X = var_path, T = whole_term },
	} --[[: CertNode ]]
	local fact_node = {
		kind = "axiom", axiom = narrow.ax_syntax_facts,
		bindings = { Pg = guard_point, Pb = branch_point, X = var_path, TA = target_term },
	} --[[: CertNode ]]
	local match_node = { kind = "rule", rule = narrow.rule_match, premises = { init_node, fact_node } } --[[: CertNode ]]
	local result, err = rl.replay(stack.rp, match_node)
	if not result then
		bump(stack.stats.guards_skipped, "replay rejected the match-branch certificate: " .. tostring(err))
		return
	end
	stack.stats.guards_certified = stack.stats.guards_certified + 1
	stack.judgments[#stack.judgments + 1] = result

	local safe, unsafe_reason = first_stmt_is_safe(stack.ctx, body_start, body_len, ge.var_name_id)
	if not safe then
		bump(stack.stats.persist_skipped, unsafe_reason or "first statement not structurally verified safe")
		return
	end
	local safe_stmt_path = extend_path(body_path, 0)
	local safe_stmt_path_term, spterr = path_of(addr_ops, safe_stmt_path)
	if not safe_stmt_path_term then
		bump(stack.stats.persist_skipped, "failed to build safe-statement path: " .. tostring(spterr))
		return
	end
	local q_point, qperr = prover_addr.exit(addr_ops, stack.file_id, safe_stmt_path_term)
	if not q_point then
		bump(stack.stats.persist_skipped, "failed to build Q point: " .. tostring(qperr))
		return
	end

	local preserves_fact_node = {
		kind = "axiom", axiom = stack.effects.ax_syntax_facts,
		bindings = { A = branch_point, B = q_point, X = var_path },
	} --[[: CertNode ]]
	local preserves_node = {
		kind = "rule", rule = stack.effects.rule_transfer, premises = { preserves_fact_node },
	} --[[: CertNode ]]
	local persist_node = {
		kind = "rule", rule = stack.persist.rule_persist, premises = { match_node, preserves_node },
	} --[[: CertNode ]]
	local presult, perr = rl.replay(stack.rp, persist_node)
	if not presult then
		bump(stack.stats.persist_skipped, "replay rejected the composed persistence certificate: " .. tostring(perr))
		return
	end
	stack.stats.persist_certified = stack.stats.persist_certified + 1
	stack.judgments[#stack.judgments + 1] = presult
end

--: (members: string[], target: string) -> boolean
local function contains_member(members, target)
	for _, m in ipairs(members) do if m == target then return true end end
	return false
end

local walk_block --: ((TheoryStack, integer[], integer, integer, Scope) -> ()) | nil

--: (stack: TheoryStack, block_path: integer[], stmt_start: integer, stmt_len: integer, scope: Scope) -> ()
walk_block = function(stack, block_path, stmt_start, stmt_len, scope)
	if not walk_block then return end
	local ctx = stack.ctx
	for i = 0, stmt_len - 1 do
		local nid = ctx.lists:get(stmt_start + i)
		local n = ctx.nodes:get(nid)
		local stmt_path = extend_path(block_path, i)
		local kind = n.kind

		if kind == NODE_LOCAL_STMT then
			local names_len = n.data[1]
			local ann = ctx.lexer.annotations[n.line]
			if ann and ann.kind == defs.ANN_TYPE and names_len == 1 then
				local members = parse_annotation_members(ann.content)
				if members and #members >= 2 then
					local name_id = ctx.lists:get(n.data[0])
					scope[name_id] = { kind = "local", root_path = stmt_path, index = 0, members = members }
				end
			end

		elseif kind == NODE_IF_STMT then
			local clauses_len = n.data[1]
			local has_else = band(n.flags, FLAG_HAS_ELSE) ~= 0
			if clauses_len == 1 then
				local clause_nid = ctx.lists:get(n.data[0])
				local cl = ctx.nodes:get(clause_nid)
				local ge = extract_guard(ctx, cl.data[0])
				local sv = ge and scope[ge.var_name_id]
				if ge and sv and #sv.members >= 2 and contains_member(sv.members, ge.target) then
					local then_path = extend_path(stmt_path, prover_addr.if_clause_body_index(0))
					local else_path = has_else and extend_path(stmt_path, prover_addr.if_else_index(1)) or nil
					local match_path, match_start, match_len
					local rest_path
					if ge.then_is_match then
						match_path, match_start, match_len = then_path, cl.data[1], cl.data[2]
						rest_path = else_path
					else
						if not else_path then
							bump(stack.stats.guards_skipped, "match branch is the (absent) else block")
							match_path = nil
						else
							match_path, match_start, match_len = else_path, n.data[2], n.data[3]
						end
						rest_path = then_path
					end
					if match_path then
						certify_guard(stack, ge, sv, stack.root_path, stmt_path, match_path, match_start, match_len)
					end
				end
			else
				bump(stack.stats.guards_skipped, "elseif chain (>1 clause): out of scope for this prover")
			end
			-- Walk into both branches for nested annotated locals / guards
			-- (independent scope copies — narrowing/persistence facts found
			-- inside a branch are never leaked to siblings).
			for c = 0, clauses_len - 1 do
				local clause_nid = ctx.lists:get(n.data[0] + c)
				local cl = ctx.nodes:get(clause_nid)
				local body_path = extend_path(stmt_path, prover_addr.if_clause_body_index(c))
				local sub_scope = {} --[[: Scope ]]
				for k, v in pairs(scope) do sub_scope[k] = v end
				walk_block(stack, body_path, cl.data[1], cl.data[2], sub_scope)
			end
			if has_else then
				local else_path = extend_path(stmt_path, prover_addr.if_else_index(clauses_len))
				local sub_scope = {} --[[: Scope ]]
				for k, v in pairs(scope) do sub_scope[k] = v end
				walk_block(stack, else_path, n.data[2], n.data[3], sub_scope)
			end

		elseif kind == NODE_FUNC_DECL then
			local ps, pl = n.data[1], n.data[2]
			local has_vararg = band(n.flags, FLAG_VARARG) ~= 0
			local body_path = extend_path(stmt_path, pl)
			if not has_vararg then
				-- Fresh scope containing ONLY this function's own qualifying
				-- parameters (never the caller's ambient scope) — same
				-- discipline as prover_narrow.lua's own `param_scope` callers.
				local fscope = param_scope(ctx, stack.source_lines, stmt_path, ps, pl, n.line, has_vararg)
				walk_block(stack, body_path, n.data[3], n.data[4], fscope)
			end
		end
	end
end

--:: AnalyzeResult = { judgments: ReplayResult[], stats: Stats }

-- Analyze one file's source text end-to-end: parse (reusing the real
-- crescent parser), walk (this module), citing+replaying every certificate
-- inline. Caps-clean: no ambient io — the caller reads the file.
--: (source: string, file_path: string) -> (AnalyzeResult | nil, string | nil)
function M.analyze_file(source, file_path)
	if type(source) ~= "string" then return nil, "analyze_file: source must be a string" end
	if type(file_path) ~= "string" then return nil, "analyze_file: file_path must be a string" end
	local ok, parser = pcall(parse_mod.parse, source, file_path)
	if not ok then return nil, "analyze_file: parse error: " .. tostring(parser) end
	local pr = parser --[[: { nodes: ASTNodeArena, lists: ListPool, pool: Pool, root: integer, lexer: { annotations: { [integer]: { kind: integer, content: string } } } } ]]
	local ctx = { nodes = pr.nodes, lists = pr.lists, pool = pr.pool, lexer = pr.lexer }

	local addr_sig, aerr = addr_v1.declare()
	if not addr_sig then return nil, "analyze_file: " .. tostring(aerr) end
	local addr_ops = addr_sig.ops

	local reg = rl.new_registry()
	local narrow, nerr = flow_narrow_v1.declare_vocabulary(reg, addr_sig)
	if not narrow then return nil, "analyze_file: " .. tostring(nerr) end
	local ax_initial, iaerr = pilot_initial_facts_v1.declare(reg, narrow)
	if not ax_initial then return nil, "analyze_file: " .. tostring(iaerr) end
	local spine, sperr = effects_spine_v1.declare(addr_sig)
	if not spine then return nil, "analyze_file: " .. tostring(sperr) end
	local effects, eerr = assign_effects_v1.declare_vocabulary(reg, addr_sig, spine)
	if not effects then return nil, "analyze_file: " .. tostring(eerr) end
	local persist, perr = narrow_persist_v1.declare(reg, narrow, spine)
	if not persist then return nil, "analyze_file: " .. tostring(perr) end

	local file_id, fierr = prover_addr.file_id_of_source(addr_ops, source)
	if not file_id then return nil, "analyze_file: " .. tostring(fierr) end
	local rp, rperr = rl.new_replayer({ registry = reg })
	if not rp then return nil, "analyze_file: " .. tostring(rperr) end

	local root_path, rperr2 = prover_addr.root(addr_ops)
	if not root_path then return nil, "analyze_file: " .. tostring(rperr2) end

	local stats = M.new_stats()
	local judgments = {} --[[: ReplayResult[] ]]
	local stack = {
		addr_ops = addr_ops, file_id = file_id, narrow = narrow, ax_initial = ax_initial,
		spine = spine, effects = effects, persist = persist,
		rp = rp, stats = stats, judgments = judgments, ctx = ctx, root_path = root_path,
		source_lines = split_source_lines(source),
	} --[[: TheoryStack ]]

	local root_node = ctx.nodes:get(pr.root)
	walk_block(stack, {}, root_node.data[0], root_node.data[1], {})

	return { judgments = judgments, stats = stats }, nil
end

return M
