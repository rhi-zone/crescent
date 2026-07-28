-- lib/type/v10_kernel/pilot/prover_narrow.lua
--
-- Pilot step 4 (certificate-emitting prover) — PASS 1: real-Lua-AST
-- narrowing analysis. Reuses the crescent parser (lib/type/static/parse.lua)
-- directly; does NOT reimplement parsing. Produces a plain-Lua-data EVENT
-- TREE (no term_algebra terms, no replayer calls — that is prover.lua's
-- pass 2, mirroring lib/type/v10_kernel/theories/algorithm_w.lua's two-pass
-- precedent: full analysis to a resolved intermediate form first, then a
-- purely mechanical second pass builds certificates over it).
--
-- ── Scope, exactly (flagged limitations, not silent gaps) ───────────────────
--
-- Guard forms recognized (matching the task brief's three, plus one
-- direct, non-speculative extension — see below):
--   1. `type(x) == "T"` / `type(x) ~= "T"`, T one of the six `type()`
--      classes (nil/boolean/number/string/table/function).
--   2. `x == nil` / `x ~= nil`.
--   3. bare truthiness `if x then` / `while x do`, OPTIONALLY wrapped in
--      exactly one leading `not` (`if not x then`) — this is not a fourth
--      guard *judgment* shape (still cites the same two flow_narrow_v1
--      rules over the same falsy composite), only a polarity flip on
--      which AST branch is "match" vs "rest"; directly mirrors
--      lib/type/static/narrow.lua's own compositional `negation` node
--      (peeling one leading `not`), simplified to a single peel since the
--      pilot's guard forms never nest `not` more than once in the cases
--      this scope covers.
--
-- Guarded statement kinds: `if` with EXACTLY ONE clause (no `elseif` — an
-- if-statement with elseif clauses is walked into for NESTED unrelated
-- guards, but its own leading test is never extracted as a guard: with
-- elseif present there is no single "rest" AST branch to address, only a
-- further test, and this pilot's addressing model has no CFG/join-point
-- notion to fall back on — flagged, matching flow_narrow_v1's own
-- documented "no side condition, no CFG" scope), and `while` (only the
-- body branch is addressable; there is no AST node for "the loop was never
-- entered", so only whichever rule matches "body executed" is ever cited).
-- `repeat...until` bodies are walked into (for nested unrolated guards) but
-- the until-test itself never gates a guard: the body runs unconditionally
-- at least once, so there is no "match vs rest branch" split to address.
-- `for` (numeric or generic) bodies are NOT walked into at all (out of
-- scope for this pilot — flagged, not silently mishandled: no events are
-- ever generated for code that is only reachable through a for-loop body).
--
-- No control-flow/fall-through inference: an `if` with no `else` (or a
-- `while`) contributes narrowing ONLY inside the branch/body that actually
-- has an AST block; nothing is asserted about the code textually following
-- the statement (branch-local narrowing per the ratified design's own
-- addressing choice — "AST-node-only, implicit entry/exit" — has no point
-- for "after the loop" or "after a non-diverging if with no else").
--
-- Chaining: a SECOND guard on the same variable is only recognized as a
-- continuation of the first ("chained") when it is the IMMEDIATE first
-- statement inside the enclosing guard's "rest" branch (never the "match"
-- branch — a match branch narrows to one member and nothing in this
-- pilot's rule set further decomposes a monomorphic fact, matching
-- flow_narrow_v1's own documented scope limit). A second guard elsewhere
-- (not the immediate first statement of the rest branch) is treated as an
-- independent, non-chained guard: pass 2 will only succeed in citing it if
-- the underlying union term it needs already happens to have that guard's
-- target as its structural first operand; otherwise pass 2 SKIPS it
-- (reason: "guard target not structurally first in the carried union — the
-- pilot only chains through the immediate next statement"). This is a
-- flagged conservative scope limit, not a silent miss: this pass only
-- records the event TREE (which guard nests inside which branch); the
-- decision of whether a nested guard's target can actually be positioned
-- first in the term being carried is made in prover.lua's pass 2, the only
-- place that builds the actual union terms.
--
-- Reassignment: a plain `x = ...` to an already-tracked local does NOT
-- invalidate its tracked member set. This matches this codebase's own
-- annotation semantics (docs/conventions.md / lib/type/CLAUDE.md, and
-- lib/type/static/CLAUDE.md's fuzz-suite note that `local x --: T`
-- "narrows the variable's type" for its scope, not merely its initial
-- value) — a `--: T` annotation on a local is a scope-wide declared type,
-- with compatibility of any later assignment checked elsewhere (the real
-- typechecker), not this narrowing pass's job. Multi-name locals
-- (`local a, b --: ...`) are not supported (skipped, reason recorded):
-- there is no way to determine which name a single trailing annotation
-- describes.

local defs = require("lib.type.static.defs")
local intern_mod = require("lib.type.static.intern")
local bit_mod = require("bit")
local band = bit_mod.band

local M = {}

--:: ASTNode = { kind: integer, flags: integer, line: integer, col: integer, data: { [integer]: integer } }
--:: ASTNodeArena = { get: (ASTNodeArena, integer) -> ASTNode, ... }
--:: ListPool = { get: (ListPool, integer) -> integer, ... }
--:: Pool = { ht_cap: integer, ht_mask: integer, ht_count: integer, next_id: integer, buf_count: integer, entries: { [integer]: unknown, ... }, bufs: { [integer]: unknown, ... }, rev: { [integer]: unknown, ... }, map: { [string]: integer, ... }, _anchors: { [integer]: string, ... }, ... }
--:: Ctx = {
--::   nodes: ASTNodeArena,
--::   lists: ListPool,
--::   pool: Pool,
--::   lexer: { annotations: { [integer]: { kind: integer, content: string } } },
--:: }
--:: ScopeVar = { local_stmt_path: integer[], name_index: integer, members: string[] }
--:: Scope = { [integer]: ScopeVar }
--:: Stats = { guards_found: integer, guards_handled: integer, guards_skipped: { [string]: integer }, annotations_parsed: integer, annotations_skipped: { [string]: integer } }

--:: LocalFactEvent = { kind: "local_fact", name_id: integer, path: integer[], members: string[] }
--:: GuardEvent = {
--::   kind: "guard", var_name_id: integer, var_local_stmt_path: integer[],
--::   target: string, guard_expr_path: integer[],
--::   then_is_match: boolean,
--::   then_path: integer[], then_events: Event[],
--::   else_path: integer[] | nil, else_events: Event[] | nil,
--:: }
--:: NestedScopeEvent = { kind: "nested_scope", path: integer[], events: Event[] }
--:: Event = LocalFactEvent | GuardEvent | NestedScopeEvent

local NODE_LOCAL_STMT  = defs.NODE_LOCAL_STMT
local NODE_IF_STMT     = defs.NODE_IF_STMT
local NODE_IF_CLAUSE   = defs.NODE_IF_CLAUSE
local NODE_WHILE_STMT  = defs.NODE_WHILE_STMT
local NODE_REPEAT_STMT = defs.NODE_REPEAT_STMT
local NODE_DO_STMT     = defs.NODE_DO_STMT
local NODE_FUNC_DECL   = defs.NODE_FUNC_DECL
local NODE_FUNC_EXPR   = defs.NODE_FUNC_EXPR
local NODE_ASSIGN_STMT = defs.NODE_ASSIGN_STMT
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

local SIX_TAGS = { ["nil"] = true, boolean = true, number = true, string = true, table = true, ["function"] = true }

--: (integer[], integer) -> integer[]
local function extend_path(path, i)
	local out = {} --[[: integer[] ]]
	for j, v in ipairs(path) do out[j] = v end
	out[#path + 1] = i
	return out
end

--: (Scope) -> Scope
local function copy_scope(scope)
	local out = {} --[[: Scope ]]
	for k, v in pairs(scope) do out[k] = v end
	return out
end

--: (Stats, string) -> ()
local function bump_skip(stats, reason)
	stats.guards_skipped[reason] = (stats.guards_skipped[reason] or 0) + 1
end

--: (Stats, string) -> ()
local function bump_ann_skip(stats, reason)
	stats.annotations_skipped[reason] = (stats.annotations_skipped[reason] or 0) + 1
end

-- Parse a `--:` annotation's raw content string into an ordered,
-- deduplicated list of the six `type()`-class names. Anything else (a
-- record/table-shape annotation, a named type alias, a generic, a
-- non-six identifier such as "integer") is REJECTED wholesale — no
-- partial acceptance.
--: (string) -> (string[] | nil, string | nil)
local function parse_annotation_members(content)
	local members = {} --[[: string[] ]]
	local seen = {} --[[: { [string]: boolean } ]]
	for tok in content:gmatch("[^|]+") do
		local name = tok:match("^%s*(.-)%s*$")
		if name == "" then return nil, "empty union member" end
		if not SIX_TAGS[name] then
			return nil, "unsupported annotation member '" .. name .. "' (not one of the six type() classes)"
		end
		if seen[name] then return nil, "duplicate annotation member '" .. name .. "'" end
		seen[name] = true
		members[#members + 1] = name
	end
	if #members == 0 then return nil, "empty annotation" end
	return members, nil
end

-- Strip at most one leading `not`. Returns (inner_node_id, negated).
--: (Ctx, integer) -> (integer, boolean)
local function strip_not(ctx, nid)
	local n = ctx.nodes:get(nid)
	if n.kind == NODE_UNARY_EXPR and n.data[0] == OP_NOT then
		return n.data[1], true
	end
	return nid, false
end

--:: GuardExtract = { var_name_id: integer, target: string, then_is_match: boolean }
--:: GuardHit = { var_name_id: integer, var_local_stmt_path: integer[], target: string, guard_expr_path: integer[], then_is_match: boolean }

-- `ident_side == nil` / `ident_side ~= nil`, given a fixed operand
-- assignment (caller tries both orderings).
--: (ASTNode, ASTNode, integer) -> GuardExtract | nil
local function extract_nil_check(ident_side, lit_side, op)
	if ident_side.kind == NODE_IDENTIFIER and lit_side.kind == NODE_LITERAL and lit_side.data[0] == LIT_NIL then
		return { var_name_id = ident_side.data[0], target = "nil", then_is_match = (op == OP_EQ) }
	end
	return nil
end

-- `type(x) == "T"` / `type(x) ~= "T"`, given a fixed operand assignment
-- (caller tries both orderings).
--: (Ctx, ASTNode, ASTNode, integer) -> GuardExtract | nil
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

-- Extract one of the three in-scope guard shapes from a test expression.
-- Returns nil if the test does not match any of them (not a "skip" —
-- simply not a guard at all).
--: (Ctx, integer) -> GuardExtract | nil
local function extract_guard(ctx, test_nid)
	local inner_nid, negated = strip_not(ctx, test_nid)
	local n = ctx.nodes:get(inner_nid)

	-- Bare truthiness: `if x then` / `if not x then`.
	if n.kind == NODE_IDENTIFIER then
		return { var_name_id = n.data[0], target = "falsy", then_is_match = negated }
	end

	if n.kind ~= NODE_BINARY_EXPR then return nil end
	local op = n.data[0]
	if op ~= OP_EQ and op ~= OP_NE then return nil end
	if negated then return nil end -- `not (a == b)` not in scope
	local lhs = ctx.nodes:get(n.data[1])
	local rhs = ctx.nodes:get(n.data[2])

	-- x == nil / x ~= nil (either operand order)
	local nil_check = extract_nil_check(lhs, rhs, op)
		or extract_nil_check(rhs, lhs, op)
	if nil_check then return nil_check end

	-- type(x) == "T" / type(x) ~= "T"
	return extract_type_check(ctx, lhs, rhs, op)
		or extract_type_check(ctx, rhs, lhs, op)
end

--: (string[], string) -> string[] | nil
local function member_set_without(members, target)
	local found = false
	local out = {} --[[: string[] ]]
	for _, m in ipairs(members) do
		if m == target then found = true else out[#out + 1] = m end
	end
	if not found then return nil end
	return out
end

-- The actual member-set entry a guard's target removes: a truthiness
-- guard's target is the marker "falsy" (not a literal member name — see
-- extract_guard) but the only real member set entry it can ever remove is
-- "nil" (truthiness guards are rejected earlier, in try_guard_event, when
-- "boolean" is present, so "nil" is always the sole falsy member in scope).
--: (string) -> string
local function member_removed_by(target)
	if target == "falsy" then return "nil" end
	return target
end

--: (string[], string) -> boolean
local function contains(members, target)
	for _, m in ipairs(members) do if m == target then return true end end
	return false
end


-- Process one if/while's test expression as a guard candidate. Returns the
-- resolved GuardHit, or nil (+ records a skip stat) if ineligible. Does NOT
-- build the Event itself -- the caller (analyze_block) owns branch/scope
-- bookkeeping, which differs between if (two branches) and while (one).
--: (Ctx, integer[], integer, Scope, Stats) -> GuardHit | nil
local function try_guard_event(ctx, stmt_path, test_nid, scope, stats)
	local g = extract_guard(ctx, test_nid)
	if not g then return nil end
	stats.guards_found = stats.guards_found + 1

	local sv = scope[g.var_name_id]
	if not sv then
		bump_skip(stats, "guarded variable not a tracked annotated local")
		return nil
	end
	if #sv.members < 2 then
		bump_skip(stats, "guard over an already-monomorphic fact (out of scope)")
		return nil
	end
	if g.target == "falsy" then
		if not contains(sv.members, "nil") then
			bump_skip(stats, "truthiness guard but declared union has no nil member")
			return nil
		end
		if contains(sv.members, "boolean") then
			bump_skip(stats, "truthiness guard unsupported: declared union includes plain 'boolean' "
				.. "(narrow-pilot-v1's tag_boolean is structurally unrelated to the falsy composite's tag_false)")
			return nil
		end
	else
		if not contains(sv.members, g.target) then
			bump_skip(stats, "guarded type not present in the variable's currently tracked union")
			return nil
		end
	end

	return {
		var_name_id = g.var_name_id,
		var_local_stmt_path = sv.local_stmt_path,
		target = g.target,
		guard_expr_path = extend_path(stmt_path, 0),
		then_is_match = g.then_is_match,
	}
end

-- Analyze a statement list (a "block" per prover_addr.lua's addressing
-- contract: the statements at indices 0..len-1 of `block_path`).
--: (Ctx, integer[], integer, integer, Scope, Stats) -> Event[]
local function analyze_block(ctx, block_path, stmt_start, stmt_len, scope, stats)
	local events = {} --[[: Event[] ]]
	for i = 0, stmt_len - 1 do
		local nid = ctx.lists:get(stmt_start + i)
		local n = ctx.nodes:get(nid)
		local stmt_path = extend_path(block_path, i)
		local kind = n.kind

		if kind == NODE_LOCAL_STMT then
			local names_len = n.data[1]
			local ann = ctx.lexer.annotations[n.line]
			if ann and ann.kind == defs.ANN_TYPE then
				if names_len ~= 1 then
					bump_ann_skip(stats, "multi-name local declaration not supported")
				else
					local members, perr = parse_annotation_members(ann.content)
					if not members then
						bump_ann_skip(stats, perr or "unparseable annotation")
					else
						stats.annotations_parsed = stats.annotations_parsed + 1
						if #members >= 2 then
							local name_id = ctx.lists:get(n.data[0])
							scope[name_id] = { local_stmt_path = stmt_path, name_index = 0, members = members }
							events[#events + 1] = {
								kind = "local_fact", name_id = name_id, path = stmt_path, members = members,
							} --[[: Event ]]
						end
					end
				end
			end
			-- `local f = function(...) ... end`: a single-name local whose sole
			-- init expression is a func-expr is treated exactly like
			-- NODE_FUNC_DECL (own independent, empty-initial-scope analysis) --
			-- see header note on the two func-defining shapes this pilot walks.
			if names_len == 1 and n.data[3] == 1 then
				local init_nid = ctx.lists:get(n.data[2])
				local init_n = ctx.nodes:get(init_nid)
				if init_n.kind == NODE_FUNC_EXPR then
					local body_path = extend_path(stmt_path, 0)
					local sub = analyze_block(ctx, body_path, init_n.data[2], init_n.data[3], {}, stats)
					events[#events + 1] = { kind = "nested_scope", path = body_path, events = sub }
				end
			end

		elseif kind == NODE_IF_STMT then
			local clauses_len = n.data[1]
			local has_else = band(n.flags, FLAG_HAS_ELSE) ~= 0
			if clauses_len ~= 1 then
				bump_skip(stats, "elseif chain not supported (no single addressable rest-branch point)")
				-- Still walk each clause body + else body for nested unrelated guards.
				for c = 0, clauses_len - 1 do
					local clause_nid = ctx.lists:get(n.data[0] + c)
					local cl = ctx.nodes:get(clause_nid)
					local body_path = extend_path(stmt_path, 2 * c + 1)
					local sub = analyze_block(ctx, body_path, cl.data[1], cl.data[2], copy_scope(scope), stats)
					events[#events + 1] = { kind = "nested_scope", path = body_path, events = sub }
				end
				if has_else then
					local else_path = extend_path(stmt_path, 2 * clauses_len)
					local sub = analyze_block(ctx, else_path, n.data[2], n.data[3], copy_scope(scope), stats)
					events[#events + 1] = { kind = "nested_scope", path = else_path, events = sub }
				end
			else
				local clause_nid = ctx.lists:get(n.data[0])
				local cl = ctx.nodes:get(clause_nid)
				local then_path = extend_path(stmt_path, 1)
				local else_path = extend_path(stmt_path, 2) -- meaningful only when has_else

				local ge = try_guard_event(ctx, stmt_path, cl.data[0], scope, stats)
				if ge then
					local then_scope = copy_scope(scope)
					local else_scope = copy_scope(scope)
					local sv = scope[ge.var_name_id]
					local rest_members = member_set_without(sv.members, member_removed_by(ge.target)) or {}
					if ge.then_is_match then
						then_scope[ge.var_name_id] = { local_stmt_path = sv.local_stmt_path, name_index = 0, members = { ge.target } }
						else_scope[ge.var_name_id] = { local_stmt_path = sv.local_stmt_path, name_index = 0, members = rest_members }
					else
						then_scope[ge.var_name_id] = { local_stmt_path = sv.local_stmt_path, name_index = 0, members = rest_members }
						else_scope[ge.var_name_id] = { local_stmt_path = sv.local_stmt_path, name_index = 0, members = { ge.target } }
					end
					local then_events = analyze_block(ctx, then_path, cl.data[1], cl.data[2], then_scope, stats)
					local else_events --[[: Event[] | nil ]] = nil
					if has_else then
						else_events = analyze_block(ctx, else_path, n.data[2], n.data[3], else_scope, stats)
					end
					stats.guards_handled = stats.guards_handled + 1
					events[#events + 1] = {
						kind = "guard",
						var_name_id = ge.var_name_id,
						var_local_stmt_path = ge.var_local_stmt_path,
						target = ge.target,
						guard_expr_path = ge.guard_expr_path,
						then_is_match = ge.then_is_match,
						then_path = then_path,
						then_events = then_events,
						else_path = has_else and else_path or nil,
						else_events = else_events,
					} --[[: Event ]]
				else
					local sub_then = analyze_block(ctx, then_path, cl.data[1], cl.data[2], copy_scope(scope), stats)
					events[#events + 1] = { kind = "nested_scope", path = then_path, events = sub_then }
					if has_else then
						local sub_else = analyze_block(ctx, else_path, n.data[2], n.data[3], copy_scope(scope), stats)
						events[#events + 1] = { kind = "nested_scope", path = else_path, events = sub_else }
					end
				end
			end

		elseif kind == NODE_WHILE_STMT then
			local body_path = extend_path(stmt_path, 1)
			local ge = try_guard_event(ctx, stmt_path, n.data[0], scope, stats)
			if ge then
				local body_scope = copy_scope(scope)
				local sv = scope[ge.var_name_id]
				local rest_members = member_set_without(sv.members, member_removed_by(ge.target)) or {}
				if ge.then_is_match then
					body_scope[ge.var_name_id] = { local_stmt_path = sv.local_stmt_path, name_index = 0, members = { ge.target } }
				else
					body_scope[ge.var_name_id] = { local_stmt_path = sv.local_stmt_path, name_index = 0, members = rest_members }
				end
				local body_events = analyze_block(ctx, body_path, n.data[1], n.data[2], body_scope, stats)
				stats.guards_handled = stats.guards_handled + 1
				events[#events + 1] = {
					kind = "guard",
					var_name_id = ge.var_name_id,
					var_local_stmt_path = ge.var_local_stmt_path,
					target = ge.target,
					guard_expr_path = ge.guard_expr_path,
					then_is_match = ge.then_is_match,
					then_path = body_path,
					then_events = body_events,
					else_path = nil,
					else_events = nil,
				} --[[: Event ]]
			else
				local sub = analyze_block(ctx, body_path, n.data[1], n.data[2], copy_scope(scope), stats)
				events[#events + 1] = { kind = "nested_scope", path = body_path, events = sub }
			end

		elseif kind == NODE_REPEAT_STMT then
			local body_path = extend_path(stmt_path, 0)
			local sub = analyze_block(ctx, body_path, n.data[1], n.data[2], copy_scope(scope), stats)
			events[#events + 1] = { kind = "nested_scope", path = body_path, events = sub }

		elseif kind == NODE_DO_STMT then
			local body_path = extend_path(stmt_path, 0)
			local sub = analyze_block(ctx, body_path, n.data[0], n.data[1], copy_scope(scope), stats)
			events[#events + 1] = { kind = "nested_scope", path = body_path, events = sub }

		elseif kind == NODE_FUNC_DECL then
			local body_path = extend_path(stmt_path, 0)
			local sub = analyze_block(ctx, body_path, n.data[3], n.data[4], {}, stats)
			events[#events + 1] = { kind = "nested_scope", path = body_path, events = sub }

		elseif kind == NODE_ASSIGN_STMT then
			-- Reassignment does NOT invalidate a tracked local's declared
			-- union (see header). `M.f = function(...) ... end` / `f = function
			-- (...) ... end` (single target, single func-expr init) is walked
			-- as its own independent scope root, exactly like NODE_FUNC_DECL --
			-- this is crescent's dominant function-defining style (`M.name =
			-- function(...) ... end`), not merely an expression-tree corner
			-- case, so it is explicitly in scope despite the general
			-- "does not dig into arbitrary expression trees" limitation (see
			-- header): this is a single target/init pair on the assignment
			-- statement itself, not a nested expression search.
			if n.data[1] == 1 and n.data[3] == 1 then
				local init_nid = ctx.lists:get(n.data[2])
				local init_n = ctx.nodes:get(init_nid)
				if init_n.kind == NODE_FUNC_EXPR then
					local body_path = extend_path(stmt_path, 0)
					local sub = analyze_block(ctx, body_path, init_n.data[2], init_n.data[3], {}, stats)
					events[#events + 1] = { kind = "nested_scope", path = body_path, events = sub }
				end
			end
		end
	end
	return events
end

-- Analyze one already-parsed file (see lib/type/static/parse.lua). Returns
-- the chunk's own top-level event list, as a NestedScopeEvent-shaped
-- record so callers can treat every scope root (chunk + each function
-- found) uniformly.
--: (unknown, Stats) -> (NestedScopeEvent | nil, string | nil)
function M.analyze(parser, stats)
	if type(parser) ~= "table" then
		return nil, "prover_narrow.analyze: parser must be a lib.type.static.parse result table"
	end
	local pr = parser --[[: { nodes: ASTNodeArena, lists: ListPool, pool: Pool, root: integer, lexer: { annotations: { [integer]: { kind: integer, content: string } } } } ]]
	local ctx = { nodes = pr.nodes, lists = pr.lists, pool = pr.pool, lexer = pr.lexer }
	local root_node = pr.nodes:get(pr.root)
	local root_path = {} --[[: integer[] ]]
	local events = analyze_block(ctx, root_path, root_node.data[0], root_node.data[1], {}, stats)
	return { kind = "nested_scope", path = root_path, events = events }, nil
end

--: () -> Stats
function M.new_stats()
	return { guards_found = 0, guards_handled = 0, guards_skipped = {}, annotations_parsed = 0, annotations_skipped = {} }
end

return M
