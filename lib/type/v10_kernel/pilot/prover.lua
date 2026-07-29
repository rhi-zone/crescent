-- lib/type/v10_kernel/pilot/prover.lua
--
-- Pilot step 4 (certificate-emitting prover) — PASS 2 + entry point.
-- Mirrors lib/type/v10_kernel/theories/algorithm_w.lua's two-pass
-- precedent: prover_narrow.lua (pass 1) produces a fully-resolved,
-- plain-data event tree over a real file's AST; this module walks that
-- SAME tree mechanically, building canonical-core terms and certificate
-- nodes (lib/type/v10_cleanroom/, per the owner-ratified canon swap),
-- citing flow_narrow_v1's rules/axiom and pilot_initial_facts_v1's axiom,
-- replaying every emitted certificate immediately (never batch-deferred).
-- Certificate nodes are plain tables per the canonical grammar; the
-- replayer validates them at replay. Prover-emitted certificates contain
-- only axiom citations and rule applications — never hypotheses — so
-- their open-hypothesis set is empty by construction and root-strict
-- replay (the acceptance channel) is the correct call per certificate.
--
-- ── How an initial fact enters a derivation, lazily ─────────────────────────
--
-- A tracked local's declared union is NOT cited as an axiom the moment its
-- `local_fact` event is seen — only lazily, the first time some guard in
-- this scope actually needs it as a premise (an annotated local nobody ever
-- guards costs nothing: no axiom citation, no certificate, no replay).
-- Once cited, the citation's OWN certificate node is threaded forward as
-- the premise for every subsequent (chained) guard on that variable within
-- the same branch — never re-cited — exactly matching
-- flow_narrow_v1_test.lua's chained worked example, where an outer guard's
-- `rest` conclusion node is reused directly as the inner guard's own
-- "type fact at the guard point" premise (no fresh axiom, no fresh
-- hypothesis).
--
-- ── Union term construction: target-first, chain-aware ──────────────────────
--
-- Every premise term this module builds is `ty_union(TA, Rest)` with TA
-- positioned as the pattern's own FIRST operand structurally (required for
-- `match()` to bind the shared `TA` metavariable the way flow_narrow_v1's
-- rules declare it — see that module's header). Building `Rest` needs to
-- know, one level ahead, whether a CHAINED guard nested immediately inside
-- the "rest" branch will need one of Rest's own members positioned first in
-- turn (see prover_narrow.lua's "Chaining" scope note — only the immediate
-- next statement of the rest branch is checked; a chain past that is out of
-- scope and simply will not structurally match at replay, in which case
-- this pass SKIPS the citation with a recorded reason rather than emitting
-- a certificate doomed to fail replay).
--
-- ── Branch-local, no join: scope forks and un-forks exactly like pass 1 ────
--
-- Processing a guard's match/rest branches (or any `nested_scope` event)
-- works over a COPY of the running var-fact table; after both branches are
-- processed, sibling events at the current level continue against the
-- ORIGINAL (unforked) table -- mirroring prover_narrow.lua's own
-- copy-on-branch-entry discipline exactly, so nothing narrowed inside one
-- branch leaks into an unrelated sibling.
--
-- ── Elseif chains needed NO changes here ────────────────────────────────────
--
-- prover_narrow.lua's pass 1 represents an elseif chain as a right-nested
-- chain of ordinary `GuardEvent`s (see that module's "Elseif chains"
-- section) -- the SAME shape this module already builds certificates over
-- for a hand-nested `if g1 then B1 else if g2 then B2 else B3 end end`.
-- This `emit_events` guard-handling branch below is already fully generic
-- over what `match_events`/`rest_events` contain: it forks `facts` once via
-- `copy_facts` before recursing into either, and `peek_next_target`
-- already detects "the immediate next sibling is a guard on the same
-- variable" by inspecting `events[1]`'s `kind`, with no assumption that the
-- nesting came from a literal nested `if` statement rather than a
-- synthetic elseif-chain wrapper. So an elseif chain replays via exactly
-- the same two rule citations (`narrow-select-match`/`-rest`) per clause,
-- re-cited once per clause exactly like a hand-nested chain would be --
-- zero new code needed in this module.

local ta = require("lib.type.v10_cleanroom.term_algebra")
local rl = require("lib.type.v10_cleanroom.replayer")
local parse_mod = require("lib.type.static.parse")
local addr_v1 = require("lib.type.v10_kernel.pilot.addr_v1")
local flow_narrow_v1 = require("lib.type.v10_kernel.pilot.flow_narrow_v1")
local pilot_initial_facts_v1 = require("lib.type.v10_kernel.pilot.pilot_initial_facts_v1")
local prover_narrow = require("lib.type.v10_kernel.pilot.prover_narrow")
local prover_addr = require("lib.type.v10_kernel.pilot.prover_addr")

local M = {}

--:: ClockFn = () -> number

--:: VarFact = { node: CertNode | nil, term: Term | nil, point: Term | nil, members: string[] }
--:: VarFacts = { [integer]: VarFact }

-- The same event-tree shapes prover_narrow.lua declares (structural, not
-- imported -- each pass owns its own copy of the shared shape per the
-- two-pass module boundary; see this module's header).
--
-- TYPECHECKER WORKAROUND: sub-event lists are typed `unknown[]`, not
-- `Event[]`, and every consumption site re-narrows each element via
-- `type(ev_raw) == "table"` + a checked cast to `Event` inside the loop
-- (see `emit_events` below) -- confirmed by a minimal repro that
-- discriminated-union narrowing on a literal `kind` field (the documented,
-- normally-working pattern) does not resolve for a union-typed ARRAY
-- ELEMENT obtained via indexing or `ipairs` iteration (even a bare `local x
-- = arr[1]` breaks it), while the identical narrowing on a plain local
-- variable or function parameter of the same union type works correctly.
-- The natural code would type these fields `Event[]` directly with no
-- extra per-element cast. See TODO.md.
--
-- TYPECHECKER WORKAROUND (second, related): in `emit_events`'s guard
-- branch, `match_path`/`rest_path`/`match_events`/`rest_events` (locals
-- populated from `ge.then_path`/`ge.else_path` etc. via a conditional
-- multi-assignment) do not narrow away `nil` under a plain truthy check
-- (`if match_path then`) even after reassignment to a fresh local -- but DO
-- narrow correctly under an explicit `type(x) == "table"` check. A minimal
-- repro reproducing the truthy-check failure in isolation could not be
-- constructed in the time available; the `type()`-check form is used
-- throughout as the reliable equivalent. The natural code is the bare
-- truthy checks. See TODO.md.
--:: LocalFactEvent = { kind: "local_fact", name_id: integer, path: integer[], members: string[] }
--:: GuardEvent = {
--::   kind: "guard", var_name_id: integer, var_kind: "local" | "param",
--::   var_root_path: integer[], var_index: integer,
--::   target: string, guard_expr_path: integer[],
--::   then_is_match: boolean,
--::   then_path: integer[], then_events: unknown[],
--::   else_path: integer[] | nil, else_events: unknown[] | nil,
--:: }
--:: NestedScopeEvent = { kind: "nested_scope", path: integer[], events: unknown[], fresh_scope: boolean }
--:: Event = LocalFactEvent | GuardEvent | NestedScopeEvent

--:: SkipCounts = { [string]: integer }
--:: Stats = {
--::   guards_found: integer, guards_handled: integer, guards_skipped: SkipCounts,
--::   annotations_parsed: integer, annotations_skipped: SkipCounts,
--::   certificates_emitted: integer, replay_pass: integer, replay_fail: integer,
--::   emission_skipped: SkipCounts,
--::   timing: { analyze_ms: number, emit_ms: number, replay_ms: number },
--:: }
--:: AnalyzeResult = { judgments: ReplayResult[], stats: Stats }
--:: AnalyzeOpts = { clock_fn: ClockFn | nil }

-- ── Small pure helpers over member-tag sets (mirrors prover_narrow.lua's
-- own private helpers -- duplicated rather than imported: these are a few
-- lines of pure list logic, and pass 1/pass 2 are deliberately independent
-- modules per the two-pass precedent's own module boundary). ─────────────────

--: (string) -> string
local function member_removed_by(target)
	if target == "falsy" then return "nil" end
	return target
end

--: (string[], string) -> string[]
local function member_set_without(members, target)
	local out = {} --[[: string[] ]]
	for _, m in ipairs(members) do
		if m ~= target then out[#out + 1] = m end
	end
	return out
end

--: (VarFacts) -> VarFacts
local function copy_facts(facts)
	local out = {} --[[: VarFacts ]]
	for k, v in pairs(facts) do out[k] = v end
	return out
end

--: (SkipCounts, string) -> integer
local function bump(counts, reason)
	counts[reason] = (counts[reason] or 0) + 1
	return counts[reason]
end

-- The target term a guard's `guard_selects`/rule citations bind TA to.
--: (NarrowVocab, string) -> (Term | nil, string | nil)
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

-- Build a union term over an ordered member-tag list, with `first` (if
-- given and present in `members`) positioned as the union's structural
-- first operand -- the chain-aware ordering prover.lua's header describes.
-- Falls back to declared order when there is nothing to chain into.
--: (NarrowVocab, string[], string | nil) -> (Term | nil, string | nil)
local function build_member_union(vocab, members, first)
	if #members == 0 then return nil, "build_member_union: empty member list" end
	local ordered = members
	if first then
		local without_first = member_set_without(members, first)
		if #without_first ~= #members then
			ordered = { first }
			for _, m in ipairs(without_first) do ordered[#ordered + 1] = m end
		end
	end
	local term, err = target_term_of(vocab, ordered[1])
	if not term then return nil, err end
	for i = 2, #ordered do
		local next_term, nerr = target_term_of(vocab, ordered[i])
		if not next_term then return nil, nerr end
		term, err = vocab.TyUnion(term, next_term)
		if not term then return nil, err end
	end
	return term
end

-- If `events[1]` is a `guard` event on `var_name_id`, return its target
-- (the immediate-next-statement chaining lookahead prover_narrow.lua's
-- header documents) -- else nil. See the `Event` type's header for why
-- `events` is `unknown[]`, not `Event[]`.
--: (unknown[] | nil, integer) -> string | nil
local function peek_next_target(events, var_name_id)
	if not events then return nil end
	local first_raw = events[1]
	if type(first_raw) ~= "table" then return nil end
	local first = first_raw --[[: Event ]]
	if first.kind == "guard" and first.var_name_id == var_name_id then return first.target end
	return nil
end

--:: AddrOps = { [string]: OpDecl }

-- Build an addr-v1 path term from a root-relative child-index array.
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

-- A tracked variable's identity path, dispatched on `ge.var_kind` (see
-- prover_narrow.lua's `ScopeVar` header note): a "local" fact's identity
-- path is child `var_index` of its NODE_LOCAL_STMT's own path
-- (`local_name_path`); a "param" fact's identity path is child `var_index`
-- of its NODE_FUNC_DECL/NODE_FUNC_EXPR's own path (`func_param_path`) --
-- structurally the same `M.child` call but over different path
-- roots/semantics, so this dispatch (not a hardcoded index-0 local-only
-- call) is required for a parameter at any position other than 0 to
-- address correctly.
--: (AddrOps, Term, GuardEvent) -> (Term | nil, string | nil)
local function var_identity_path(addr_ops, root_path, ge)
	if ge.var_kind == "param" then
		return prover_addr.func_param_path(addr_ops, root_path, ge.var_index)
	end
	return prover_addr.local_name_path(addr_ops, root_path, ge.var_index)
end

--:: EmitCtx = {
--::   addr_ops: AddrOps, file_id: Term, vocab: NarrowVocab, ax_initial: AxiomDecl,
--::   rp: Replayer, stats: Stats, judgments: ReplayResult[],
--:: }

local emit_events --: ((EmitCtx, unknown[], VarFacts) -> ()) | nil

-- Cite + replay one rule application (`narrow-select-match` or
-- `-rest`), recording the judgment and stats, returning the built node
-- (for threading into a chained continuation) or nil on a replay failure
-- (recorded via emission_skipped, never silently dropped). Certificate
-- nodes are plain tables (no construction step can fail); the sole
-- validation point is replay itself.
--: (EmitCtx, RuleDecl, CertNode, Term, Term, Term, Term) -> CertNode | nil
local function cite_and_replay(ectx, rule, premise_node, pg, pb, x, target_ty)
	local fact_node = {
		kind = "axiom", axiom = ectx.vocab.ax_syntax_facts,
		bindings = { Pg = pg, Pb = pb, X = x, TA = target_ty },
	} --[[: CertNode ]]
	local node = { kind = "rule", rule = rule, premises = { premise_node, fact_node } } --[[: CertNode ]]
	ectx.stats.certificates_emitted = ectx.stats.certificates_emitted + 1
	local result, rerr = rl.replay(ectx.rp, node)
	if not result then
		ectx.stats.replay_fail = ectx.stats.replay_fail + 1
		bump(ectx.stats.emission_skipped, "replay rejected an emitted certificate: " .. tostring(rerr))
		return nil
	end
	ectx.stats.replay_pass = ectx.stats.replay_pass + 1
	ectx.judgments[#ectx.judgments + 1] = result
	return node
end

--: (EmitCtx, unknown[], VarFacts) -> ()
emit_events = function(ectx, events, facts)
	if not emit_events then return end
	local addr_ops = ectx.addr_ops
	local vocab = ectx.vocab

	for _, ev_raw in ipairs(events) do
		-- See the `Event` type's header (TYPECHECKER WORKAROUND note) for why
		-- this per-element `type()`-then-cast is needed: discriminated-union
		-- narrowing on `ev.kind` does not resolve for a union-typed ARRAY
		-- ELEMENT (obtained via `ipairs`/indexing), only for a plain
		-- local/parameter of the same union type -- confirmed by a minimal
		-- repro unrelated to this module's own types.
		if type(ev_raw) == "table" then
			local ev = ev_raw --[[: Event ]]

		if ev.kind == "local_fact" then
			facts[ev.name_id] = {
				node = nil, term = nil, point = nil,
				members = ev.members,
			} --[[: VarFact ]]

		elseif ev.kind == "nested_scope" then
			local child_facts = ev.fresh_scope and {} or copy_facts(facts)
			emit_events(ectx, ev.events, child_facts)

		elseif ev.kind == "guard" then
			local ge = ev
			local var_name_id = ge.var_name_id
			local target = ge.target

			local vf = facts[var_name_id]
			if not vf then
				bump(ectx.stats.emission_skipped, "guard event referenced an untracked variable (internal)")
			else
				local match_path, match_events, rest_path, rest_events
				if ge.then_is_match then
					match_path, match_events = ge.then_path, ge.then_events
					rest_path, rest_events = ge.else_path, ge.else_events
				else
					match_path, match_events = ge.else_path, ge.else_events
					rest_path, rest_events = ge.then_path, ge.then_events
				end

				local root_path, rperr = path_of(addr_ops, ge.var_root_path)
				local target_term, tterr = target_term_of(vocab, target)
				if root_path == nil or target_term == nil then
					bump(ectx.stats.emission_skipped, "failed to build var path / target term: "
						.. tostring(rperr or tterr))
				else
					local var_path, vperr = var_identity_path(addr_ops, root_path, ge)
					if var_path == nil then
						bump(ectx.stats.emission_skipped, "failed to build var path / target term: "
							.. tostring(vperr))
					else
						if vf.node == nil then
							local rest_members0 = member_set_without(vf.members, member_removed_by(target))
							local next_target0 = peek_next_target(rest_events, var_name_id)
							local rest_term0, rterr = build_member_union(vocab, rest_members0, next_target0)
							if rest_term0 == nil then
								bump(ectx.stats.emission_skipped, "failed to build initial rest term: " .. tostring(rterr))
							else
								local whole_term, uerr = vocab.TyUnion(target_term, rest_term0)
								local guard_expr_path, gpperr = path_of(addr_ops, ge.guard_expr_path)
								if whole_term == nil or guard_expr_path == nil then
									bump(ectx.stats.emission_skipped, "failed to build guard point/union: "
										.. tostring(uerr or gpperr))
								else
									local guard_point, gperr = prover_addr.exit(addr_ops, ectx.file_id, guard_expr_path)
									if guard_point == nil then
										bump(ectx.stats.emission_skipped, "failed to build guard point/union: "
											.. tostring(gperr))
									else
										local init_node = {
											kind = "axiom", axiom = ectx.ax_initial,
											bindings = { P = guard_point, X = var_path, T = whole_term },
										} --[[: CertNode ]]
										vf.node = init_node
										vf.term = whole_term
										vf.point = guard_point
									end
								end
							end
						end

						local vf_node = vf.node
						local vf_point = vf.point
						if vf_node ~= nil and vf_point ~= nil then
							local mp = match_path
							if type(mp) == "table" then
								local match_body_path = path_of(addr_ops, mp)
								if match_body_path ~= nil then
									local match_point = prover_addr.entry(addr_ops, ectx.file_id, match_body_path)
									if match_point ~= nil then
										local node = cite_and_replay(ectx, vocab.rule_match, vf_node, vf_point, match_point, var_path, target_term)
										local me = match_events
										if node and type(me) == "table" then
											local child_facts = copy_facts(facts)
											child_facts[var_name_id] = { node = node, term = target_term, point = match_point, members = { target } }
											emit_events(ectx, me, child_facts)
										end
									end
								end
							end
							local rp_path = rest_path
							if type(rp_path) == "table" then
								local rest_body_path = path_of(addr_ops, rp_path)
								if rest_body_path ~= nil then
									local rest_point = prover_addr.entry(addr_ops, ectx.file_id, rest_body_path)
									if rest_point ~= nil then
										local rest_members = member_set_without(vf.members, member_removed_by(target))
										local next_target = peek_next_target(rest_events, var_name_id)
										local rest_term = build_member_union(vocab, rest_members, next_target)
										local node = cite_and_replay(ectx, vocab.rule_rest, vf_node, vf_point, rest_point, var_path, target_term)
										local re = rest_events
										if node and rest_term and type(re) == "table" then
											local child_facts = copy_facts(facts)
											child_facts[var_name_id] = { node = node, term = rest_term, point = rest_point, members = rest_members }
											emit_events(ectx, re, child_facts)
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end
end
end

--: (ClockFn | nil) -> number
local function now_ms(clock_fn)
	if not clock_fn then return 0 end
	return clock_fn() * 1000
end

--: () -> Stats
local function new_stats()
	return {
		guards_found = 0, guards_handled = 0, guards_skipped = {},
		annotations_parsed = 0, annotations_skipped = {},
		certificates_emitted = 0, replay_pass = 0, replay_fail = 0,
		emission_skipped = {},
		timing = { analyze_ms = 0, emit_ms = 0, replay_ms = 0 },
	}
end

-- Analyze one file's source text end-to-end: parse (reusing the real
-- crescent parser), pass 1 (prover_narrow), pass 2 (this module), replaying
-- every emitted certificate immediately. Caps-clean: no ambient io -- the
-- caller reads the file and passes its text in; `opts.clock_fn` (a caller-
-- injected `() -> number` returning seconds, e.g. `os.clock`) is OPTIONAL --
-- when absent, timing fields report 0 rather than reaching for an ambient
-- clock.
--: (source: string, file_path: string, opts: AnalyzeOpts | nil) -> (AnalyzeResult | nil, string | nil)
function M.analyze_file(source, file_path, opts)
	if type(source) ~= "string" then return nil, "analyze_file: source must be a string" end
	if type(file_path) ~= "string" then return nil, "analyze_file: file_path must be a string" end
	local o = opts or {}
	local clock_fn = o.clock_fn

	local t0 = now_ms(clock_fn)
	local ok, parser = pcall(parse_mod.parse, source, file_path)
	if not ok then
		return nil, "analyze_file: parse error: " .. tostring(parser)
	end

	-- Pass 1 gets its OWN (sealed) stats shape -- prover_narrow.lua owns
	-- that type; this module's richer Stats (superset, pass-2 fields added)
	-- is populated by copying pass 1's fields in afterward, not by handing
	-- pass 1 a record it doesn't recognize.
	local pass1_stats = prover_narrow.new_stats()
	local root, aerr = prover_narrow.analyze(parser, pass1_stats, source)
	if not root then return nil, aerr end
	local t1 = now_ms(clock_fn)

	local stats = new_stats()
	stats.guards_found = pass1_stats.guards_found
	stats.guards_handled = pass1_stats.guards_handled
	stats.guards_skipped = pass1_stats.guards_skipped
	stats.annotations_parsed = pass1_stats.annotations_parsed
	stats.annotations_skipped = pass1_stats.annotations_skipped
	stats.timing.analyze_ms = t1 - t0

	local addr_sig = addr_v1.declare()
	if addr_sig == nil then return nil, "analyze_file: addr_v1.declare failed" end
	local addr_ops = addr_sig.ops

	local reg = rl.new_registry()
	local vocab, verr = flow_narrow_v1.declare_vocabulary(reg, addr_sig)
	if not vocab then return nil, "analyze_file: " .. tostring(verr) end
	local ax_initial, iaerr = pilot_initial_facts_v1.declare(reg, vocab)
	if not ax_initial then return nil, "analyze_file: " .. tostring(iaerr) end
	local file_id, fierr = prover_addr.file_id_of_source(addr_ops, source)
	if not file_id then return nil, "analyze_file: " .. tostring(fierr) end

	local rp, rperr = rl.new_replayer({ registry = reg })
	if not rp then return nil, "analyze_file: " .. tostring(rperr) end

	local judgments = {} --[[: ReplayResult[] ]]
	local ectx = {
		addr_ops = addr_ops, file_id = file_id, vocab = vocab, ax_initial = ax_initial,
		rp = rp, stats = stats, judgments = judgments,
	} --[[: EmitCtx ]]

	emit_events(ectx, root.events, {})
	local t2 = now_ms(clock_fn)
	stats.timing.emit_ms = t2 - t1
	stats.timing.replay_ms = 0 -- replay happens inline with emission; see cite_and_replay.

	return { judgments = judgments, stats = stats }, nil
end

return M
