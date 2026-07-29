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
-- Guarded statement kinds: `if` with any number of clauses (`elseif` chains
-- ARE supported — see "Elseif chains" below), and `while` (only the body
-- branch is addressable; there is no AST node for "the loop was never
-- entered", so only whichever rule matches "body executed" is ever cited).
-- `repeat...until` bodies are walked into (for nested unrolated guards) but
-- the until-test itself never gates a guard: the body runs unconditionally
-- at least once, so there is no "match vs rest branch" split to address.
-- `for` (numeric or generic) bodies are NOT walked into at all (out of
-- scope for this pilot — flagged, not silently mishandled: no events are
-- ever generated for code that is only reachable through a for-loop body).
--
-- ── Elseif chains ────────────────────────────────────────────────────────
--
-- prover_addr.lua's addressing contract already models an N-clause
-- if-statement injectively (child `2k`/`2k+1` per clause, child `2N` the
-- trailing else) — this was true before this pilot supported elseif
-- narrowing at all. What was missing was purely analysis, not addressing:
-- each clause's guard (if recognized) narrows its OWN body's entry scope
-- exactly like the single-clause case already did (`narrow-select-match`),
-- and the negation ("rest") flows FORWARD to become the base scope clause
-- k+1's guard test is evaluated against, chaining down to the trailing
-- else (if present) after the last clause — the SAME `narrow-select-rest`
-- citation the single-clause if/else case already made, just re-cited once
-- per clause rather than once total (see flow_narrow_v1.lua's own note:
-- "Peeling one binary layer via narrow-select-rest and re-citing the same
-- rule against the resulting (still possibly-union) type is how
-- arbitrary-width unions are narrowed" — an elseif chain is exactly this
-- peeling, one clause per union member removed).
--
-- Event-tree shape (a design decision, not a rule/judgment change — see
-- flow_narrow_v1.lua's rule table, unchanged): NO new Event kind was
-- introduced. An elseif chain is represented as a right-nested chain of
-- ordinary `GuardEvent`s, exactly the shape prover_narrow.lua would already
-- produce for hand-nested `if g1 then B1 else if g2 then B2 else B3 end
-- end` Lua source — clause k's `GuardEvent` has `then_path`/`then_events`
-- addressing its own body (child `2k+1`) as before, and its
-- `else_path`/`else_events` addressing EITHER clause k+1's test expression
-- (child `2(k+1)`) with `else_events = { <clause k+1's own GuardEvent> }`
-- (when there IS a next clause), OR the trailing else block (child `2N`)
-- with its actual flat statement events (when clause k is the last
-- clause). This was the more natural of the two options considered (the
-- alternative — widening `GuardEvent` to an N-ary shape with a list of
-- clauses — would need a NEW field shape threaded through prover.lua's
-- pass 2 for no semantic gain, since the rules cited are already exactly
-- the nested-if shape's two per clause); reusing the existing shape means
-- prover.lua's pass 2 needs NO changes at all (see that module's own note
-- at its `emit_events` guard-handling site) — its existing recursive
-- match/rest-branch forking, and its existing `peek_next_target`
-- immediate-next-statement chaining detection, already handle exactly this
-- nesting, because it is literally the same shape as manually-nested ifs.
-- `else_path`/`else_events` are therefore reused for a purpose beyond the
-- literal `else` keyword's block when they address a next clause's test
-- instead — flagged here since the field names alone don't convey it.
--
-- Per-clause eligibility: a clause whose test isn't one of the three
-- recognized guard shapes (see `try_guard_event`) falls back to the SAME
-- "nested_scope, not chained" walk-through the single-clause case already
-- used when its lone guard was unrecognized — for THAT clause's own body
-- only. Clauses before/after an ineligible one in the same chain are still
-- processed on their own merits: the chain does not abort at the first
-- unrecognized test. An ineligible clause's own body IS wrapped in a fresh
-- `nested_scope` (needed since, unlike an eligible clause's `GuardEvent`,
-- there is no enclosing rule citation to fork scope for it in pass 2); its
-- onward continuation (further clauses, or the trailing else) is spliced
-- as further sibling events UNWRAPPED when a further clause follows (that
-- clause's own body is self-isolating one way or the other, recursively),
-- but the trailing else block specifically — reached with no eligible
-- clause anywhere in between — IS wrapped in its own `nested_scope` before
-- being spliced as a sibling: unlike a clause-to-clause transition (no new
-- lexical block), the trailing else block IS a new lexical block, and
-- splicing its raw statement events as bare siblings of the enclosing
-- block would leak any locals it declares past the if-statement.
--
-- No control-flow/fall-through inference: an `if` with no `else` (or a
-- `while`) contributes narrowing ONLY inside the branch/body that actually
-- has an AST block; nothing is asserted about the code textually following
-- the statement (branch-local narrowing per the ratified design's own
-- addressing choice — "AST-node-only, implicit entry/exit" — has no point
-- for "after the loop" or "after a non-diverging if with no else").
--
-- Chaining: this is also exactly the mechanism an elseif chain uses (see
-- "Elseif chains" above) — clause k+1's `GuardEvent`, when eligible, is
-- placed as the sole (first) element of clause k's "rest" events list, so
-- it is detected as chained by construction; when clause k+1 is ineligible
-- its own `nested_scope` wrapper occupies that first-element slot instead,
-- which correctly means a clause k+2 further down the chain is NOT
-- detected as chained through the ineligible k+1 (conservative, matching
-- the general rule below).
--
-- A SECOND guard on the same variable is only recognized as a
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
--
-- ── Function-parameter facts ─────────────────────────────────────────────
--
-- Crescent has no per-parameter `--:` syntax (`function(x --: T)` is
-- invalid/silently-wrong per docs/typechecker-reference.md's "Annotation
-- syntax" section) — the only way to type a parameter is a preceding-line
-- function-type annotation, `--: (T1, T2, ...) -> R`, positionally matched
-- to the function's own parameter list. This pass locates that annotation
-- the SAME way the real typechecker does (`lib/type/static/constrain.lua`'s
-- `get_ann`/`collect_preceding_run`): an inline (same-line-as-the-function)
-- annotation takes priority; otherwise scan backward from the function
-- node's own line, transparently skipping blank/comment-only source lines,
-- collecting a run of consecutive `ANN_TYPE` entries. Unlike the real
-- checker's `collect_preceding_run`, this pass does NOT merge multiple
-- consecutive entries into an overload intersection — an overload signature
-- is ambiguous for positional per-parameter attribution (which alternative
-- would a given position's type come from?), so 2+ consecutive entries are
-- skipped wholesale (reason recorded), matching the multi-name-local
-- wholesale-skip discipline above. For `local f = function(...) ... end` /
-- `f = function(...) ... end`, the annotation is looked up relative to the
-- FUNC_EXPR node's own `line` field (matching
-- `constrain.lua`'s `ExprRule[NODE_FUNC_EXPR]`, which calls `get_ann(ctx,
-- n.line)` on the func-expr node itself, not the enclosing statement) — in
-- practice the same physical source line for this dominant style, but using
-- the func-expr's own line keeps this pass consistent with the real
-- checker's rule rather than a coincidentally-equal approximation of it.
--
-- The signature string is parsed by a separate, lightweight parser
-- (`parse_param_type_slices`, parallel to `parse_annotation_members` — NOT
-- coupled to `lib/type/static/ann.lua`'s arena-based resolver, same
-- decoupling as the existing local-annotation parser): it splits only the
-- top-level (depth-0) commas of the parenthesized parameter list, handing
-- each parameter's full raw slice to the EXISTING `parse_annotation_members`
-- unsplit. A parameter type containing `|` is thus parsed correctly (it's
-- one slice); a parameter type containing nested parens/braces (a table or
-- function type — out of six-tag-union scope) is ALSO captured as one
-- whole slice, then rejected wholesale by `parse_annotation_members`
-- itself (its existing "not one of the six type() classes" rejection) —
-- no separate nested-shape check is needed. A slice count mismatch against
-- the function's actual declared parameter count is a wholesale skip (the
-- signature can't be positionally trusted at all in that case). Vararg
-- functions (`FLAG_VARARG`) are a wholesale skip too: the arrow form's
-- relationship to a trailing `...` is not something this pilot attributes
-- positions through — see `param_scope`.
--
-- ── Scoping correctness ──────────────────────────────────────────────────
--
-- A parameter's fact holds only within its OWN function body: `param_scope`
-- always builds a FRESH `{}` scope (never the caller's ambient scope) from
-- ONLY that function's own qualifying parameters, exactly mirroring how a
-- function body's scope has always been analyzed here (`fresh_scope =
-- true`, starting from `{}`) — a nested function's own same-named parameter
-- (or local) therefore shadows an outer tracked fact by construction: the
-- outer scope is never consulted when building the inner function's own
-- scope, and the inner function's own guard on its own parameter narrows
-- using only the inner `ScopeVar` entry for that name.

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
--::   source_lines: string[],
--:: }
-- `kind` discriminates two DISTINCT addressing shapes a tracked variable's
-- identity path can have (see prover_addr.lua's header and
-- `M.func_param_path` vs `M.local_name_path`): "local" — `root_path` is a
-- NODE_LOCAL_STMT's own path, `index` is its declared-name index (always 0,
-- multi-name locals unsupported); "param" — `root_path` is a
-- NODE_FUNC_DECL/NODE_FUNC_EXPR's own path, `index` is the parameter's
-- 0-based position. Pass 2 (prover.lua) branches on `kind` to call the
-- matching `prover_addr` helper with `index` (no longer a hardcoded 0).
--:: ScopeVar = { kind: "local" | "param", root_path: integer[], index: integer, members: string[] }
--:: Scope = { [integer]: ScopeVar }
--:: Stats = { guards_found: integer, guards_handled: integer, guards_skipped: { [string]: integer }, annotations_parsed: integer, annotations_skipped: { [string]: integer } }

--:: LocalFactEvent = { kind: "local_fact", name_id: integer, path: integer[], members: string[] }
--:: GuardEvent = {
--::   kind: "guard", var_name_id: integer, var_kind: "local" | "param",
--::   var_root_path: integer[], var_index: integer,
--::   target: string, guard_expr_path: integer[],
--::   then_is_match: boolean,
--::   then_path: integer[], then_events: Event[],
--::   else_path: integer[] | nil, else_events: Event[] | nil,
--:: }
--:: NestedScopeEvent = { kind: "nested_scope", path: integer[], events: Event[], fresh_scope: boolean }
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
local FLAG_VARARG   = defs.FLAG_VARARG

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

-- Split `source` into a 1-indexed array of lines (no trailing newline in
-- any entry). Mirrors `lib/type/static/errors.lua`'s `set_source` line-split
-- exactly (same edge-case handling: a final line with no trailing newline
-- is still captured) so line numbers used by `find_preceding_func_annotation`
-- below agree with the same numbering the lexer/parser already use.
--: (string) -> string[]
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

--: (string) -> boolean
local function is_blank_or_comment_line(line_text)
	return line_text:match("^%s*$") ~= nil or line_text:match("^%s*%-%-") ~= nil
end

-- Locate the `--: (T1, ...) -> R` annotation for a function statement at
-- `decl_line`, using the SAME line-association rule as
-- `lib/type/static/constrain.lua`'s `get_ann`/`collect_preceding_run` (see
-- this module's header, "Function-parameter facts"): inline (same-line)
-- annotation takes priority; otherwise scan backward from `decl_line - 1`,
-- transparently skipping blank/comment-only lines, collecting a run of
-- consecutive ANN_TYPE entries. Does NOT merge multiple entries into an
-- overload intersection (unlike `collect_preceding_run`) — 2+ consecutive
-- entries is skipped wholesale as an ambiguous overload for positional
-- attribution; 0 is "no annotation" (not a skip, just nothing to attribute).
--: (Ctx, integer, Stats) -> { kind: integer, content: string } | nil
local function find_preceding_func_annotation(ctx, decl_line, stats)
	local inline = ctx.lexer.annotations[decl_line]
	if inline and inline.kind == defs.ANN_TYPE then return inline end
	local ann_lines = {} --[[: integer[] ]]
	local scan = decl_line - 1
	while scan >= 1 do
		local a = ctx.lexer.annotations[scan]
		if a and a.kind == defs.ANN_TYPE then
			ann_lines[#ann_lines + 1] = scan
			scan = scan - 1
		elseif not a and ctx.source_lines[scan] and is_blank_or_comment_line(ctx.source_lines[scan]) then
			scan = scan - 1
		else
			break
		end
	end
	if #ann_lines == 0 then return nil end
	if #ann_lines > 1 then
		bump_ann_skip(stats, "multiple preceding-line function-type annotations (overload) not supported "
			.. "for positional parameter attribution")
		return nil
	end
	return ctx.lexer.annotations[ann_lines[1]]
end

-- Parse a `(T1, T2, ...) -> R` function-type annotation's raw content into
-- an ordered list of per-parameter raw type strings (the return type R is
-- never parsed — this pilot has no use for it). Splits the parenthesized
-- parameter list on TOP-LEVEL (depth-0) commas only, tracked over nested
-- parens/braces, so a parameter type containing `|` is captured whole (one
-- slice) and a parameter type containing nested parens/braces is ALSO
-- captured whole rather than mis-split on an inner comma — it is then
-- rejected by `parse_annotation_members` itself (not one of the six
-- classes), no separate nested-shape check needed here. See header.
--: (string) -> (string[] | nil, string | nil)
local function parse_param_type_slices(content)
	local s = content:match("^%s*(.-)%s*$") or content
	if s:sub(1, 1) ~= "(" then
		return nil, "function annotation is not in '(T1, ...) -> R' form"
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
	if not close_idx then return nil, "unbalanced parens in function annotation" end
	local after = s:sub(close_idx + 1):match("^%s*(.-)%s*$") or ""
	if after:sub(1, 2) ~= "->" then
		return nil, "function annotation missing '->' after parameter list"
	end
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

-- Build the scope a function body's own analysis starts from, AND the
-- `local_fact`-shaped events pass 2 needs to learn about those same facts
-- (see header, "Function-parameter facts" / "Scoping correctness"). Pass 2
-- (prover.lua's `emit_events`) builds its own `facts` table PURELY by
-- walking `local_fact` events -- it never reads `scope` (a pass-1-only
-- bookkeeping structure) -- so a qualifying parameter needs its own
-- `local_fact` event (mirroring NODE_LOCAL_STMT's own local-fact event
-- alongside its `scope[name_id] = ...` population) or pass 2 would silently
-- treat every guard on it as an untracked-variable skip. ALWAYS a fresh `{}`
-- scope populated with ONLY this function's own qualifying parameters —
-- never the caller's ambient scope.
--: (Ctx, integer[], integer, integer, integer, boolean, Stats) -> (Scope, LocalFactEvent[])
local function param_scope(ctx, func_path, ps, pl, decl_line, has_vararg, stats)
	local scope = {} --[[: Scope ]]
	local fact_events = {} --[[: LocalFactEvent[] ]]
	if pl == 0 then return scope, fact_events end
	if has_vararg then
		bump_ann_skip(stats, "vararg function: positional parameter/signature attribution out of scope")
		return scope, fact_events
	end
	local ann = find_preceding_func_annotation(ctx, decl_line, stats)
	if not ann then return scope, fact_events end
	local slices, perr = parse_param_type_slices(ann.content)
	if not slices then
		bump_ann_skip(stats, perr or "function annotation not in '(T1, ...) -> R' form")
		return scope, fact_events
	end
	if #slices ~= pl then
		bump_ann_skip(stats, "function signature parameter count (" .. #slices
			.. ") does not match declared parameter count (" .. pl .. ")")
		return scope, fact_events
	end
	for i = 0, pl - 1 do
		local raw = slices[i + 1]
		local slice = raw:match("^%s*(.-)%s*$") or raw
		local members, merr = parse_annotation_members(slice)
		if not members then
			bump_ann_skip(stats, "parameter " .. i .. ": " .. (merr or "unparseable annotation"))
		else
			stats.annotations_parsed = stats.annotations_parsed + 1
			if #members >= 2 then
				local name_id = ctx.lists:get(ps + i)
				local param_path = extend_path(func_path, i)
				scope[name_id] = { kind = "param", root_path = func_path, index = i, members = members }
				fact_events[#fact_events + 1] = {
					kind = "local_fact", name_id = name_id, path = param_path, members = members,
				}
			end
		end
	end
	return scope, fact_events
end

-- Splice a function's own parameter `local_fact` events in FRONT of its
-- body's own event list (parameters are bound before any body statement
-- runs, so their facts precede the body's own events in the same sense a
-- local's own `local_fact` event precedes what follows it in its block).
--: (LocalFactEvent[], Event[]) -> Event[]
local function prepend_facts(fact_events, body_events)
	if #fact_events == 0 then return body_events end
	local out = {} --[[: Event[] ]]
	for _, fe in ipairs(fact_events) do out[#out + 1] = fe end
	for _, e in ipairs(body_events) do out[#out + 1] = e end
	return out
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
--:: GuardHit = {
--::   var_name_id: integer, var_kind: "local" | "param",
--::   var_root_path: integer[], var_index: integer,
--::   target: string, guard_expr_path: integer[], then_is_match: boolean,
--:: }

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
-- `test_path` is the test expression's OWN path (the caller computes it --
-- for an if-clause k this is child `2k` of the if-stmt path per
-- prover_addr.lua's addressing contract, NOT always child 0; only a
-- single-clause if or a while happens to have its test at child 0).
--: (Ctx, integer[], integer, Scope, Stats) -> GuardHit | nil
local function try_guard_event(ctx, test_path, test_nid, scope, stats)
	local g = extract_guard(ctx, test_nid)
	if not g then return nil end
	stats.guards_found = stats.guards_found + 1

	local sv = scope[g.var_name_id]
	if not sv then
		bump_skip(stats, "guarded variable not a tracked annotated local or parameter")
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
		var_kind = sv.kind,
		var_root_path = sv.root_path,
		var_index = sv.index,
		target = g.target,
		guard_expr_path = test_path,
		then_is_match = g.then_is_match,
	}
end

-- Forward-declared: analyze_block and analyze_if_chain are mutually
-- recursive (a clause/else body is analyzed via analyze_block; an
-- if-statement inside analyze_block is analyzed via analyze_if_chain,
-- which itself recurses into analyze_block for clause/else bodies and
-- into itself for the next clause -- see "Elseif chains" in the header).
local analyze_block --: ((Ctx, integer[], integer, integer, Scope, Stats) -> Event[]) | nil

-- Build the events for "clause `c` onward" of an if-statement (clause `c`
-- itself, then whatever follows it: clause `c+1`, ..., the trailing else).
-- Returns (path, events): `events` is what the CALLER (either this same
-- function recursing for clause c-1, or analyze_block for the whole
-- if-statement at c=0) should splice in at its own level; `path` is the
-- address the events would be entered at (clause c's own test path if
-- there IS a clause c, else the trailing else block's path, or nil if
-- there is neither) -- used by an ELIGIBLE clause c-1 as its own
-- `else_path` (see header). See the header's "Elseif chains" section for
-- the full reasoning, including why the ineligible-clause branch wraps the
-- trailing else in its own `nested_scope` but not a further eligible/
-- ineligible clause.
--: (Ctx, integer[], integer, integer, integer, integer, boolean, integer, Scope, Stats) -> (integer[] | nil, Event[])
local function analyze_if_chain(ctx, stmt_path, clauses_start, clauses_len, else_start, else_len, has_else, c, scope, stats)
	if not analyze_block then return nil, {} end
	if c >= clauses_len then
		if not has_else then return nil, {} end
		local else_path = extend_path(stmt_path, 2 * clauses_len)
		local events = analyze_block(ctx, else_path, else_start, else_len, scope, stats)
		return else_path, events
	end

	local clause_nid = ctx.lists:get(clauses_start + c)
	local cl = ctx.nodes:get(clause_nid)
	local test_path = extend_path(stmt_path, 2 * c)
	local body_path = extend_path(stmt_path, 2 * c + 1)

	local ge = try_guard_event(ctx, test_path, cl.data[0], scope, stats)
	if not ge then
		-- Not a recognized guard shape: walk this clause's own body for
		-- nested unrelated guards (unnarrowed scope copy -- matches the
		-- single-clause "ineligible" case), then continue the chain
		-- onward with the scope UNCHANGED (this test told us nothing
		-- about the variable). Clauses before/after an ineligible one are
		-- still processed on their own merits (see header).
		local sub = analyze_block(ctx, body_path, cl.data[1], cl.data[2], copy_scope(scope), stats)
		local rest_events = { { kind = "nested_scope", path = body_path, events = sub, fresh_scope = false } } --[[: Event[] ]]
		local cont_path, cont_events = analyze_if_chain(
			ctx, stmt_path, clauses_start, clauses_len, else_start, else_len, has_else, c + 1, scope, stats)
		if c + 1 >= clauses_len then
			-- The recursion just returned the trailing else (or nothing):
			-- a genuinely NEW lexical block, unlike a clause-to-clause
			-- transition -- must get its own nested_scope wrap before
			-- being spliced as a bare sibling here (else a local declared
			-- inside the else block would leak into this list's ambient
			-- scope/facts, visible to code after the whole if-statement).
			if cont_path then
				rest_events[#rest_events + 1] = { kind = "nested_scope", path = cont_path, events = cont_events, fresh_scope = false }
			end
		else
			-- A further clause follows; its own body is already isolated
			-- (its own GuardEvent fork if eligible, or its own
			-- nested_scope wrap if not, per this same function,
			-- recursively) -- safe to splice its events directly.
			for _, e in ipairs(cont_events) do rest_events[#rest_events + 1] = e end
		end
		return cont_path, rest_events
	end

	local matched_scope = copy_scope(scope)
	local rest_scope = copy_scope(scope)
	local sv = scope[ge.var_name_id]
	local rest_members = member_set_without(sv.members, member_removed_by(ge.target)) or {}
	matched_scope[ge.var_name_id] = { kind = sv.kind, root_path = sv.root_path, index = sv.index, members = { ge.target } }
	rest_scope[ge.var_name_id] = { kind = sv.kind, root_path = sv.root_path, index = sv.index, members = rest_members }

	local then_scope, cont_scope
	if ge.then_is_match then
		then_scope, cont_scope = matched_scope, rest_scope
	else
		then_scope, cont_scope = rest_scope, matched_scope
	end

	local then_events = analyze_block(ctx, body_path, cl.data[1], cl.data[2], then_scope, stats)
	local cont_path, cont_events = analyze_if_chain(
		ctx, stmt_path, clauses_start, clauses_len, else_start, else_len, has_else, c + 1, cont_scope, stats)

	stats.guards_handled = stats.guards_handled + 1
	local guard_event = {
		kind = "guard",
		var_name_id = ge.var_name_id,
		var_kind = ge.var_kind,
		var_root_path = ge.var_root_path,
		var_index = ge.var_index,
		target = ge.target,
		guard_expr_path = ge.guard_expr_path,
		then_is_match = ge.then_is_match,
		then_path = body_path,
		then_events = then_events,
		-- else_path/else_events, when cont_path is non-nil, address either
		-- the NEXT clause's test (else_events = a singleton list holding
		-- that clause's own GuardEvent) or the trailing else block (when
		-- this is the last clause) -- see header, "Elseif chains". Either
		-- way this GuardEvent's own citation in pass 2 forks scope before
		-- descending into else_events, so no extra wrap is needed here
		-- regardless of which of the two `cont_events` actually is.
		else_path = cont_path,
		else_events = cont_path and cont_events or nil,
	} --[[: Event ]]
	return test_path, { guard_event }
end

-- Analyze a statement list (a "block" per prover_addr.lua's addressing
-- contract: the statements at indices 0..len-1 of `block_path`).
--: (Ctx, integer[], integer, integer, Scope, Stats) -> Event[]
analyze_block = function(ctx, block_path, stmt_start, stmt_len, scope, stats)
	if not analyze_block then return {} end
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
							scope[name_id] = { kind = "local", root_path = stmt_path, index = 0, members = members }
							events[#events + 1] = {
								kind = "local_fact", name_id = name_id, path = stmt_path, members = members,
							} --[[: Event ]]
						end
					end
				end
			end
			-- `local f = function(...) ... end`: a single-name local whose sole
			-- init expression is a func-expr is treated exactly like
			-- NODE_FUNC_DECL (own independent scope analysis, now seeded with
			-- any qualifying parameter facts via `param_scope` -- see header,
			-- "Function-parameter facts") -- see header note on the two
			-- func-defining shapes this pilot walks. The func-expr gets its OWN
			-- path (child names_len+0 of the local-stmt path, per
			-- prover_addr.lua's M.local_stmt_init_path), distinct from the
			-- statement's own path; its body is then child `pl` of THAT path
			-- (NODE_FUNC_EXPR's own rule, params occupying children 0..pl-1),
			-- not of stmt_path directly — this is the injectivity fix (see
			-- prover_addr.lua).
			if names_len == 1 and n.data[3] == 1 then
				local init_nid = ctx.lists:get(n.data[2])
				local init_n = ctx.nodes:get(init_nid)
				if init_n.kind == NODE_FUNC_EXPR then
					local func_expr_path = extend_path(stmt_path, names_len + 0)
					local ps, pl = init_n.data[0], init_n.data[1]
					local has_vararg = band(init_n.flags, FLAG_VARARG) ~= 0
					local fscope, ffacts = param_scope(ctx, func_expr_path, ps, pl, init_n.line, has_vararg, stats)
					local body_path = extend_path(func_expr_path, pl)
					local sub = analyze_block(ctx, body_path, init_n.data[2], init_n.data[3], fscope, stats)
					sub = prepend_facts(ffacts, sub)
					events[#events + 1] = { kind = "nested_scope", path = body_path, events = sub, fresh_scope = true }
				end
			end

		elseif kind == NODE_IF_STMT then
			local clauses_len = n.data[1]
			local has_else = band(n.flags, FLAG_HAS_ELSE) ~= 0
			local _, chain_events = analyze_if_chain(
				ctx, stmt_path, n.data[0], clauses_len, n.data[2], n.data[3], has_else, 0, scope, stats)
			for _, e in ipairs(chain_events) do events[#events + 1] = e end

		elseif kind == NODE_WHILE_STMT then
			local body_path = extend_path(stmt_path, 1)
			local ge = try_guard_event(ctx, extend_path(stmt_path, 0), n.data[0], scope, stats)
			if ge then
				local body_scope = copy_scope(scope)
				local sv = scope[ge.var_name_id]
				local rest_members = member_set_without(sv.members, member_removed_by(ge.target)) or {}
				if ge.then_is_match then
					body_scope[ge.var_name_id] = { kind = sv.kind, root_path = sv.root_path, index = sv.index, members = { ge.target } }
				else
					body_scope[ge.var_name_id] = { kind = sv.kind, root_path = sv.root_path, index = sv.index, members = rest_members }
				end
				local body_events = analyze_block(ctx, body_path, n.data[1], n.data[2], body_scope, stats)
				stats.guards_handled = stats.guards_handled + 1
				events[#events + 1] = {
					kind = "guard",
					var_name_id = ge.var_name_id,
					var_kind = ge.var_kind,
					var_root_path = ge.var_root_path,
					var_index = ge.var_index,
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
				events[#events + 1] = { kind = "nested_scope", path = body_path, events = sub, fresh_scope = false }
			end

		elseif kind == NODE_REPEAT_STMT then
			local body_path = extend_path(stmt_path, 0)
			local sub = analyze_block(ctx, body_path, n.data[1], n.data[2], copy_scope(scope), stats)
			events[#events + 1] = { kind = "nested_scope", path = body_path, events = sub, fresh_scope = false }

		elseif kind == NODE_DO_STMT then
			local body_path = extend_path(stmt_path, 0)
			local sub = analyze_block(ctx, body_path, n.data[0], n.data[1], copy_scope(scope), stats)
			events[#events + 1] = { kind = "nested_scope", path = body_path, events = sub, fresh_scope = false }

		elseif kind == NODE_FUNC_DECL then
			local ps, pl = n.data[1], n.data[2]
			local has_vararg = band(n.flags, FLAG_VARARG) ~= 0
			local fscope, ffacts = param_scope(ctx, stmt_path, ps, pl, n.line, has_vararg, stats)
			local body_path = extend_path(stmt_path, pl)
			local sub = analyze_block(ctx, body_path, n.data[3], n.data[4], fscope, stats)
			sub = prepend_facts(ffacts, sub)
			events[#events + 1] = { kind = "nested_scope", path = body_path, events = sub, fresh_scope = true }

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
			-- The func-expr gets its OWN path (child 0 of the assign-stmt
			-- path, per prover_addr.lua's M.assign_stmt_init_path — targets
			-- are unaddressed so the RHS expression occupies child 0
			-- directly), distinct from the statement's own path; its body is
			-- then child `pl` of THAT path (NODE_FUNC_EXPR's own rule, params
			-- occupying children 0..pl-1), not of stmt_path directly — this
			-- is the injectivity fix (see prover_addr.lua).
			if n.data[1] == 1 and n.data[3] == 1 then
				local init_nid = ctx.lists:get(n.data[2])
				local init_n = ctx.nodes:get(init_nid)
				if init_n.kind == NODE_FUNC_EXPR then
					local func_expr_path = extend_path(stmt_path, 0)
					local ps, pl = init_n.data[0], init_n.data[1]
					local has_vararg = band(init_n.flags, FLAG_VARARG) ~= 0
					local fscope, ffacts = param_scope(ctx, func_expr_path, ps, pl, init_n.line, has_vararg, stats)
					local body_path = extend_path(func_expr_path, pl)
					local sub = analyze_block(ctx, body_path, init_n.data[2], init_n.data[3], fscope, stats)
					sub = prepend_facts(ffacts, sub)
					events[#events + 1] = { kind = "nested_scope", path = body_path, events = sub, fresh_scope = true }
				end
			end
		end
	end
	return events
end

-- Analyze one already-parsed file (see lib/type/static/parse.lua). Returns
-- the chunk's own top-level event list, as a NestedScopeEvent-shaped
-- record so callers can treat every scope root (chunk + each function
-- found) uniformly. `source` is the SAME source text the caller already
-- passed to `lib.type.static.parse.parse` to build `parser` -- required to
-- replicate the real typechecker's preceding-line annotation line-
-- association rule (blank/comment-only line skipping; see header,
-- "Function-parameter facts" and `find_preceding_func_annotation`).
--: (unknown, Stats, string) -> (NestedScopeEvent | nil, string | nil)
function M.analyze(parser, stats, source)
	if type(parser) ~= "table" then
		return nil, "prover_narrow.analyze: parser must be a lib.type.static.parse result table"
	end
	if type(source) ~= "string" then
		return nil, "prover_narrow.analyze: source must be the string passed to parse.parse"
	end
	local pr = parser --[[: { nodes: ASTNodeArena, lists: ListPool, pool: Pool, root: integer, lexer: { annotations: { [integer]: { kind: integer, content: string } } } } ]]
	local ctx = {
		nodes = pr.nodes, lists = pr.lists, pool = pr.pool, lexer = pr.lexer,
		source_lines = split_source_lines(source),
	}
	local root_node = pr.nodes:get(pr.root)
	local root_path = {} --[[: integer[] ]]
	local events = analyze_block(ctx, root_path, root_node.data[0], root_node.data[1], {}, stats)
	return { kind = "nested_scope", path = root_path, events = events, fresh_scope = true }, nil
end

--: () -> Stats
function M.new_stats()
	return { guards_found = 0, guards_handled = 0, guards_skipped = {}, annotations_parsed = 0, annotations_skipped = {} }
end

return M
