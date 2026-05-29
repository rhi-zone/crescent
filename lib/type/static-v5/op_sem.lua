-- lib/type/static-v5/op_sem.lua
-- v5.0 typechecker operational semantics — EXECUTABLE FORM.
--
-- Companion to `docs/typechecker-v5-operational-semantics.md`.  Per H7
-- (parallel impl + docs with parity tests) and F2 (op-sem is a runnable
-- test, not prose).
--
-- Each labelled rule in the doc has a `rule_<label>` function here.
-- `run()` is the solver loop implementing S-Step / S-Park / S-Wake /
-- S-Quiesce.
--
-- This module REUSES the perf-prototype substrate at
-- `lib/type/experiments/v5_perf/` — types.lua (AST), subst.lua (union-find
-- substitution with phase), constraint.lua (constraint ADT).  CInst is
-- added locally here as a "cinst"-tagged shape.

local types_mod      = require("lib.type.experiments.v5_perf.types")
local subst_mod      = require("lib.type.experiments.v5_perf.subst")
local constraint_mod = require("lib.type.experiments.v5_perf.constraint")
local variance_mod   = require("lib.type.experiments.v5_perf.variance")

local M = {}

-- ────────────────────────────────────────────────────────────────────────────
-- Scheme + CInst extension
-- ────────────────────────────────────────────────────────────────────────────

--:: V5Scheme       = { binders: integer, body: V5Type }
--:: ConstraintInst = { id: integer, tag: "cinst", scheme: V5Scheme, target: V5Type, prov: Provenance }
--:: ConstraintHKT  = { id: integer, tag: "chkt", f: V5Type, args: V5Type[], result: V5Type, prov: Provenance }
--:: ConstraintHO   = { id: integer, tag: "hounify", f: V5Type, args: V5Type[], result: V5Type, prov: Provenance }
--:: OpSemConstraint = V5Constraint | ConstraintInst | ConstraintHKT | ConstraintHO

-- Narrow an unknown value to V5Type (requires non-nil table with string .tag).
-- Used when reading V5Type fields off unknown-typed constraint field accesses.
--: (unknown) -> V5Type | nil
local function as_v5type(v)
	if type(v) ~= "table" then return nil end
	--: { tag: unknown, ... }
	local t = v
	local tg = t.tag
	if type(tg) ~= "string" then return nil end
	--: V5Type
	local ty = v
	return ty
end

local _next_id = 100000

--: () -> integer
local function fresh_id()
	local i = _next_id
	_next_id = i + 1
	return i
end

--: (integer, V5Type) -> V5Scheme
function M.scheme(binders, body)
	return { binders = binders, body = body }
end

--: (V5Scheme, V5Type, Provenance) -> ConstraintInst
function M.inst(sch, target, prov)
	return { id = fresh_id(), tag = "cinst", scheme = sch, target = target, prov = prov }
end

--: (V5Type, V5Type[], V5Type, Provenance) -> ConstraintHKT
function M.chkt(f, args, result, prov)
	return { id = fresh_id(), tag = "chkt", f = f, args = args, result = result, prov = prov }
end

--: (V5Type, V5Type[], V5Type, Provenance) -> ConstraintHO
function M.hounify(f, args, result, prov)
	return { id = fresh_id(), tag = "hounify", f = f, args = args, result = result, prov = prov }
end

-- Re-export constructor pass-throughs.
M.eq          = constraint_mod.eq
M.sub         = constraint_mod.sub
M.table_open  = constraint_mod.table_open
M.table_set   = constraint_mod.table_set
M.table_seal  = constraint_mod.table_seal
M.method_call = constraint_mod.method_call
M.row_extend  = constraint_mod.row_extend
M.row_lacks   = constraint_mod.row_lacks
M.row_close   = constraint_mod.row_close
M.prov        = constraint_mod.prov
M.variance    = variance_mod

-- ────────────────────────────────────────────────────────────────────────────
-- State
-- ────────────────────────────────────────────────────────────────────────────

--:: ErrorDetails = { tag: "const_mismatch", a_name: string, b_name: string } | { tag: "missing_field", field: string } | { tag: "extra_field", field: string } | { tag: "effect_not_permitted", effect: V5Type, container: V5Type | nil } | { tag: "kind_mismatch", a_tag: string, b_tag: string } | { tag: "no_matching_branch", value_ty: V5Type, union_ty: V5Type } | { tag: "arrow_arity_mismatch", expected: integer, got: integer } | { tag: "record_arity_mismatch", expected: integer, got: integer } | { tag: "head_mismatch", a_name: string, b_name: string } | { tag: "closed_extend", field: string } | { tag: "row_already_contains", field: string } | { tag: "occurs_check", a_name: string } | { tag: "intersection_arity_mismatch", expected: integer, got: integer } | { tag: "all_parts_unresolved" } | { tag: "sealed_field_set", field: string } | { tag: "missing_method", method: string } | { tag: "not_a_record", found_tag: string } | { tag: "ambiguous_constructor" } | { tag: "hkt_arity_mismatch", expected: integer, got: integer }
--:: OpSemError = { rule: string, msg: string, prov: Provenance | nil, details: ErrorDetails | nil }
--:: OpSemTrace = { rule: string, msg: string }
--:: OpSemBounds = { lower: { [integer]: V5Type[] }, upper: { [integer]: V5Type[] }, edge_up: { [integer]: { [integer]: boolean } }, edge_down: { [integer]: { [integer]: boolean } } }
--:: OpSemState = { subst: Subst, worklist: OpSemConstraint[], head: integer, tail: integer, inert: { [integer]: OpSemConstraint }, errors: OpSemError[], trace: OpSemTrace[], reactivations: integer, steps: integer, row_watchers: { [integer]: { [integer]: boolean } }, bounds: OpSemBounds, subcache: { [string]: boolean }, sub_emits: integer }

--: () -> OpSemState
function M.new_state()
	return {
		subst         = subst_mod.new(),
		worklist      = {} --[[: OpSemConstraint[] ]],
		head          = 1,
		tail          = 0,
		inert         = {} --[[: { [integer]: OpSemConstraint } ]],
		errors        = {} --[[: OpSemError[] ]],
		trace         = {} --[[: OpSemTrace[] ]],
		reactivations = 0,
		steps         = 0,
		row_watchers  = {} --[[: { [integer]: { [integer]: boolean } } ]],
		-- Spec A simple-sub bound-graph B = {lower, upper, edge_up}, keyed by
		-- union-find root.  `subcache` is the mandatory structural-hash
		-- termination cache C; `sub_emits` counts re-emitted CSub obligations
		-- (observability for the termination assertions).
		bounds        = {
			lower     = {} --[[: { [integer]: V5Type[] } ]],
			upper     = {} --[[: { [integer]: V5Type[] } ]],
			edge_up   = {} --[[: { [integer]: { [integer]: boolean } } ]],
			edge_down = {} --[[: { [integer]: { [integer]: boolean } } ]],
		},
		subcache      = {} --[[: { [string]: boolean } ]],
		sub_emits     = 0,
	}
end

--: (OpSemState, OpSemConstraint) -> nil
function M.emit(st, c)
	local n = st.tail + 1
	st.worklist[n] = c
	st.tail = n
end

--: (OpSemState, string, string) -> nil
local function trace(st, rule, msg)
	st.trace[#st.trace + 1] = { rule = rule, msg = msg }
end

--: (OpSemState, string, string, Provenance | nil, ErrorDetails | nil) -> nil
local function err(st, rule, msg, prov, details)
	st.errors[#st.errors + 1] = { rule = rule, msg = msg, prov = prov, details = details }
	trace(st, rule, msg)
end

-- ────────────────────────────────────────────────────────────────────────────
-- Wake + park
-- ────────────────────────────────────────────────────────────────────────────

--: (OpSemState, integer) -> nil
local function wake(st, tvar_id)
	local watchers = subst_mod.drain_watchers(st.subst, tvar_id)
	if watchers == nil then return end
	for cid in pairs(watchers) do
		local c = st.inert[cid]
		if c ~= nil then
			st.inert[cid] = nil
			local n = st.tail + 1
			st.worklist[n] = c
			st.tail = n
			st.reactivations = st.reactivations + 1
		end
	end
end

-- S-Wake-Head.  Drain head-watchers when the tvar's binding's head becomes
-- rigid.  Called after any binding event where head_is_rigid holds.
--: (OpSemState, integer) -> nil
local function wake_head(st, tvar_id)
	if not subst_mod.head_is_rigid(st.subst, tvar_id) then return end
	local hw = subst_mod.drain_head_watchers(st.subst, tvar_id)
	if hw == nil then return end
	for cid in pairs(hw) do
		local c = st.inert[cid]
		if c ~= nil then
			st.inert[cid] = nil
			local n = st.tail + 1
			st.worklist[n] = c
			st.tail = n
			st.reactivations = st.reactivations + 1
		end
	end
end

-- Row-var watcher helpers (needed by park, which is defined next).
-- watch_rowvar/wake_rowvar are also referenced from the CRow rules below;
-- declaring them here ensures they are in scope for both park and the rules.

--: (OpSemState, integer, integer) -> nil
local function watch_rowvar(st, rv_id, cid)
	local w = st.row_watchers[rv_id]
	if w == nil then w = {} --[[: { [integer]: boolean } ]]; st.row_watchers[rv_id] = w end
	w[cid] = true
end

--: (OpSemState, integer) -> nil
local function wake_rowvar(st, rv_id)
	local w = st.row_watchers[rv_id]
	if w == nil then return end
	st.row_watchers[rv_id] = nil
	for cid in pairs(w) do
		local c = st.inert[cid]
		if c ~= nil then
			st.inert[cid] = nil
			local n = st.tail + 1
			st.worklist[n] = c
			st.tail = n
			st.reactivations = st.reactivations + 1
		end
	end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Spec A — atomic_subtype (the single primitive lattice)
-- ────────────────────────────────────────────────────────────────────────────
--
-- The base-type subtyping facts (never <: anything, anything <: unknown,
-- integer <: number, literal widening) are specified ONCE here as a relation
-- consulted everywhere.  Per the spec's "Abstract lattice consultation":
-- atomic_subtype is written against ABSTRACT predicates (is_never, is_unknown,
-- eq_atom, base_widens).  The literal-encoding recognizer is ISOLATED inside
-- base_widens only — Spec C will flip that backing to tag-dispatch with NO
-- change to atomic_subtype.

--: (V5Type) -> boolean
local function is_never(a)
	if a.tag ~= "const" then return false end
	return a.name == "never"
end
--: (V5Type) -> boolean
local function is_unknown(b)
	if b.tag ~= "const" then return false end
	return b.name == "unknown"
end
--: (V5Type, V5Type) -> boolean
local function eq_atom(a, b) return types_mod.equal(a, b) end

-- base_widens(a, name_b): does atom `a` widen to the base atom named `name_b`?
-- This is the SOLE site holding the concrete literal encoding (the `$Lit*`
-- recognizer + the integer<:number / bool-literal edges).  atomic_subtype
-- never inspects `$`-names; it only calls base_widens.
--: (V5Type, string) -> boolean
local function base_widens(a, name_b)
	if a.tag == "const" then
		-- integer <: number (primitive numeric widening).
		if a.name == "integer" and name_b == "number" then return true end
		-- boolean literal constants widen to boolean.
		if (a.name == "true" or a.name == "false") and name_b == "boolean" then return true end
		return false
	end
	if a.tag == "app" then
		local af = a.f
		if af ~= nil and af.tag == "const" then
			local fn = af.name
			if fn == "$Lit" and name_b == "string" then return true end
			if fn == "$LitInt" and (name_b == "integer" or name_b == "number") then return true end
			if fn == "$LitNum" and name_b == "number" then return true end
			if (fn == "true" or fn == "false") and name_b == "boolean" then return true end
		end
	end
	return false
end

-- atomic_subtype(a, b): the decidable base-lattice judgment.  Holds iff a is
-- bottom, b is top, a = b, or a widens to b through the primitive lattice.
-- Written purely against the abstract predicates above.
--: (V5Type, V5Type) -> boolean
local function atomic_subtype(a, b)
	if is_never(a) then return true end
	if is_unknown(b) then return true end
	if eq_atom(a, b) then return true end
	if b.tag == "const" and base_widens(a, b.name) then return true end
	return false
end

M.atomic_subtype = atomic_subtype

-- is_lattice_atom(t): does the atomic lattice treat `t` as a leaf?  A const is
-- always a leaf; a literal-encoding app (head is a `$Lit*`/bool-literal const)
-- is a leaf too.  This recognizer is ISOLATED here (same boundary as
-- base_widens); Spec C flips it to tag-dispatch with no change to callers.
--: (V5Type) -> boolean
local function is_lattice_atom(t)
	if t.tag == "const" then return true end
	if t.tag == "app" then
		local af = t.f
		if af ~= nil and af.tag == "const" then
			local fn = af.name
			return fn == "$Lit" or fn == "$LitInt" or fn == "$LitNum"
				or fn == "true" or fn == "false"
		end
	end
	return false
end

-- ────────────────────────────────────────────────────────────────────────────
-- Spec A — bound-graph B + termination cache C
-- ────────────────────────────────────────────────────────────────────────────
--
-- B = { lower, upper, edge_up }, keyed by union-find root.  C = subcache.
-- Set membership / dedup is modulo types.equal after deref.

--: (V5Type[], V5Type) -> boolean
local function bounds_contains(xs, t)
	for i = 1, #xs do
		local v = xs[i]
		if v ~= nil and types_mod.equal(v, t) then return true end
	end
	return false
end

-- Add a type to a per-root bound set; returns true iff newly added.
--: ({ [integer]: V5Type[] }, integer, V5Type) -> boolean
local function bound_set_add(map, root, ty)
	local list = map[root]
	if list == nil then list = {} --[[: V5Type[] ]]; map[root] = list end
	if bounds_contains(list, ty) then return false end
	list[#list + 1] = ty
	return true
end

-- key(L, U) = structural head hash.  head = top-level tag, plus for a uvar
-- leaf its union-find root id, so two uvars sharing a root collide and a uvar
-- vs a different root do not.  (Spec A §"Bound-add with cache".)
--: (OpSemState, V5Type) -> string
local function head_key(st, t)
	local d = subst_mod.deref(st.subst, t) --[[: V5Type ]]
	if d.tag == "uvar" then return "uvar#" .. tostring(subst_mod.find(st.subst, d.id)) end
	if d.tag == "const" then return "const:" .. d.name end
	return d.tag
end

--: (OpSemState, V5Type, V5Type) -> string
local function sub_key(st, l, u) return head_key(st, l) .. "<:" .. head_key(st, u) end

-- Cache-guarded re-emission of CSub(L, U): record the key BEFORE the obligation
-- enters W (S-Sub-CacheMiss "record before recursion"); a key already present
-- discharges via S-Sub-CacheHit (emit nothing).  This is the termination
-- protocol — cyclic bound-graphs re-encounter their own key and stop.
--: (OpSemState, V5Type, V5Type, Provenance) -> nil
local function emit_sub_cached(st, l, u, prov)
	local k = sub_key(st, l, u)
	if st.subcache[k] then return end
	st.subcache[k] = true
	st.sub_emits = st.sub_emits + 1
	M.emit(st, constraint_mod.sub(l, u, prov))
end

-- Bound propagation directions (standard simple-sub / MLstruct §3.2 closure,
-- which the spec derives from).  For an edge α → β (meaning α <: β):
--   • a LOWER L of α satisfies L <: α <: β, so L flows FORWARD to β's lowers.
--   • an UPPER U of β satisfies α <: β <: U, so U flows BACKWARD to α's uppers.
-- (The spec's prose §"State" inverts these polarities — "α's uppers flow to β;
-- β's lowers flow to α" — which loses transitive lowers and is unsound; we
-- implement the sound MLstruct direction the same section cites.  See the
-- handoff note.)  Bound-set dedup terminates the walk; the cache the re-emit.
--: (OpSemState, integer, V5Type, Provenance) -> nil
local function add_upper(st, r, ty, prov)
	if not bound_set_add(st.bounds.upper, r, ty) then return end
	local lowers = st.bounds.lower[r]
	if lowers ~= nil then
		for i = 1, #lowers do
			local lo = lowers[i]
			if lo ~= nil then emit_sub_cached(st, lo, ty, prov) end
		end
	end
	-- Upper flows BACKWARD to predecessors (α where α → r).
	local pred = st.bounds.edge_down[r] --[[: { [integer]: boolean } | nil ]]
	if pred ~= nil then
		for p in pairs(pred) do
			local pr = p --[[: integer ]]
			add_upper(st, pr, ty, prov)
		end
	end
end

--: (OpSemState, integer, V5Type, Provenance) -> nil
local function add_lower(st, r, ty, prov)
	if not bound_set_add(st.bounds.lower, r, ty) then return end
	local uppers = st.bounds.upper[r]
	if uppers ~= nil then
		for i = 1, #uppers do
			local up = uppers[i]
			if up ~= nil then emit_sub_cached(st, ty, up, prov) end
		end
	end
	-- Lower flows FORWARD to successors (β where r → β).
	local succ = st.bounds.edge_up[r] --[[: { [integer]: boolean } | nil ]]
	if succ ~= nil then
		for s in pairs(succ) do
			local sr = s --[[: integer ]]
			add_lower(st, sr, ty, prov)
		end
	end
end

--: (OpSemConstraint, Subst) -> { [integer]: boolean }
local function blockers_of(c, s)
	local acc = {} --[[: { [integer]: boolean } ]]
	if c.tag == "ceq" then
		local a = subst_mod.deref(s, c.a) --[[: V5Type ]]
		local b = subst_mod.deref(s, c.b) --[[: V5Type ]]
		if a.tag == "uvar" then acc[a.id] = true end
		if b.tag == "uvar" then acc[b.id] = true end
	elseif c.tag == "csub" then
		local a = subst_mod.deref(s, c.a) --[[: V5Type ]]
		local b = subst_mod.deref(s, c.b) --[[: V5Type ]]
		if a.tag == "uvar" then acc[a.id] = true end
		if b.tag == "uvar" then acc[b.id] = true end
	elseif c.tag == "topen" then acc[c.tv] = true
	elseif c.tag == "tset"  then acc[c.tv] = true
	elseif c.tag == "tseal" then acc[c.tv] = true
	elseif c.tag == "mcall" then acc[c.tv] = true
	elseif c.tag == "crow_extend" then
		local cr = c --[[: ConstraintRowExtend ]]
		local rt = subst_mod.deref(s, cr.record_ty)
		if rt.tag == "uvar" then acc[rt.id] = true end
	elseif c.tag == "crow_lacks" then
		local cl = c --[[: ConstraintRowLacks ]]
		local rt = subst_mod.deref(s, cl.record_ty)
		if rt.tag == "uvar" then acc[rt.id] = true end
	elseif c.tag == "crow_close" then
		local cc2 = c --[[: ConstraintRowClose ]]
		local rt = subst_mod.deref(s, cc2.record_ty)
		if rt.tag == "uvar" then acc[rt.id] = true end
	elseif c.tag == "cint_member" then
		local cm = c --[[: ConstraintIntMember ]]
		local ty = subst_mod.deref(s, cm.ty)
		if ty.tag == "uvar" then acc[ty.id] = true end
	end
	return acc
end

--: (OpSemState, OpSemConstraint) -> nil
local function park(st, c)
	st.inert[c.id] = c
	if c.tag == "hounify" then
		-- HOUnify parks on head rigidity of f's underlying uvar.
		local f = subst_mod.deref(st.subst, c.f) --[[: V5Type ]]
		if f.tag == "uvar" then
			subst_mod.watch_head(st.subst, f.id, c.id)
		end
		return
	end
	if c.tag == "chkt" then
		-- CHKT parks on head rigidity of f's uvar (same wake condition as HOUnify).
		local f = subst_mod.deref(st.subst, c.f) --[[: V5Type ]]
		if f.tag == "uvar" then
			subst_mod.watch_head(st.subst, f.id, c.id)
		end
		return
	end
	if c.tag == "crow_lacks" then
		-- CRowLacks parks on either the record_ty UVar (if not yet concrete) or
		-- on the open row-var id (if record is already concrete with open row).
		local cl = c --[[: ConstraintRowLacks ]]
		local rt = subst_mod.deref(st.subst, cl.record_ty)
		if rt.tag == "uvar" then
			subst_mod.watch(st.subst, rt.id, c.id)
		elseif rt.tag == "record" then
			local rrow = rt.row --[[: TRowVar | nil ]]
			if rrow ~= nil then
				watch_rowvar(st, rrow.id, c.id)
			end
		end
		return
	end
	local b = blockers_of(c, st.subst)
	for tv in pairs(b) do subst_mod.watch(st.subst, tv, c.id) end
end

-- ────────────────────────────────────────────────────────────────────────────
-- T-CEq family
-- ────────────────────────────────────────────────────────────────────────────

-- T-CEq-UU: both sides UVar.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CEq_UU(st, a, b, prov)
	-- internal: dispatcher guarantees both are uvar; fires only on solver bug
	if a.tag ~= "uvar" then err(st, "T-CEq-UU", "precondition a must be uvar"); return "error" end
	-- internal: dispatcher guarantees both are uvar; fires only on solver bug
	if b.tag ~= "uvar" then err(st, "T-CEq-UU", "precondition b must be uvar"); return "error" end
	if a.id == b.id then trace(st, "T-CEq-UU", "refl"); return "done" end
	local winner, loser = subst_mod.union(st.subst, a.id, b.id)
	if loser ~= nil then
		-- T-CEq-UU-Bounds: fold loser's bound sets + edges into winner, then
		-- re-establish closure across the joined cross-pairs (cache-guarded;
		-- cannot loop on a cyclic graph).  Equality is stronger than mutual
		-- subtyping, so the directional edge between the two collapses to a
		-- self-loop and is dropped.
		local B = st.bounds
		-- Snapshot loser's bounds, then clear its entries.
		local loser_lowers = {} --[[: V5Type[] ]]
		local ll = B.lower[loser]
		if ll ~= nil then for i = 1, #ll do loser_lowers[i] = ll[i] end; B.lower[loser] = nil end
		local loser_uppers = {} --[[: V5Type[] ]]
		local lu = B.upper[loser]
		if lu ~= nil then for i = 1, #lu do loser_uppers[i] = lu[i] end; B.upper[loser] = nil end
		-- Migrate out-edges (edge_up) and in-edges (edge_down); fix the
		-- neighbors' back-references from loser to winner.
		local le_up = B.edge_up[loser]
		if le_up ~= nil then
			local we = B.edge_up[winner]
			if we == nil then we = {} --[[: { [integer]: boolean } ]]; B.edge_up[winner] = we end
			for r in pairs(le_up) do
				we[r] = true
				local rd = B.edge_down[r]
				if rd ~= nil then rd[loser] = nil; rd[winner] = true end
			end
			B.edge_up[loser] = nil
		end
		local le_dn = B.edge_down[loser]
		if le_dn ~= nil then
			local wd = B.edge_down[winner]
			if wd == nil then wd = {} --[[: { [integer]: boolean } ]]; B.edge_down[winner] = wd end
			for r in pairs(le_dn) do
				wd[r] = true
				local ru = B.edge_up[r]
				if ru ~= nil then ru[loser] = nil; ru[winner] = true end
			end
			B.edge_down[loser] = nil
		end
		-- Drop the self-loop the merge induces.
		local we2 = B.edge_up[winner]
		if we2 ~= nil then we2[winner] = nil end
		local wd2 = B.edge_down[winner]
		if wd2 ~= nil then wd2[winner] = nil end
		-- Re-add loser's bounds into the winner via the edge-aware adders: this
		-- both records the cross-pair obligations and propagates them across the
		-- now-merged component.
		for i = 1, #loser_lowers do local v = loser_lowers[i]; if v ~= nil then add_lower(st, winner, v, prov) end end
		for i = 1, #loser_uppers do local v = loser_uppers[i]; if v ~= nil then add_upper(st, winner, v, prov) end end
		wake(st, loser)
	end
	trace(st, "T-CEq-UU", "union")
	return "done"
end

-- T-CEq-Bind-L.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CEq_Bind_L(st, a, b, prov)
	-- internal: dispatcher routes here only when a=uvar; fires only on solver bug
	if a.tag ~= "uvar" then err(st, "T-CEq-Bind-L", "precondition a must be uvar"); return "error" end
	-- internal: dispatcher routes here only when b is concrete; fires only on solver bug
	if b.tag == "uvar" then err(st, "T-CEq-Bind-L", "precondition b must be concrete"); return "error" end
	local seen = {} --[[: { [integer]: boolean } ]]
	types_mod.collect_uvars(b, seen)
	local root = subst_mod.find(st.subst, a.id)
	if seen[root] == true then
		err(st, "T-CEq-Occurs", "occurs check failed",
			prov, { tag = "occurs_check", a_name = tostring(a.id) })
		return "error"
	end
	if subst_mod.bind(st.subst, a.id, b) then
		wake(st, a.id)
		wake_head(st, a.id)
	end
	-- T-CEq-Bind-L-Bounds: honor accumulated bounds on the root.  Verify every
	-- lower L <: b and every upper b <: U by emitting cache-guarded CSubs.  The
	-- bound sets are retained (still valid facts about the now-concrete root).
	local lowers = st.bounds.lower[root]
	if lowers ~= nil then
		for i = 1, #lowers do
			local lb = lowers[i]
			if lb ~= nil then emit_sub_cached(st, lb, b, prov) end
		end
	end
	local uppers = st.bounds.upper[root]
	if uppers ~= nil then
		for i = 1, #uppers do
			local ub = uppers[i]
			if ub ~= nil then emit_sub_cached(st, b, ub, prov) end
		end
	end
	trace(st, "T-CEq-Bind-L", "bound")
	return "done"
end

-- T-CEq-Bind-R.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CEq_Bind_R(st, a, b, prov)
	return M.rule_T_CEq_Bind_L(st, b, a, prov)
end

-- T-CEq-Const.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CEq_Const(st, a, b, prov)
	-- internal: dispatcher routes here only when both are const; fires only on solver bug
	if a.tag ~= "const" or b.tag ~= "const" then
		err(st, "T-CEq-Const", "precondition: both const"); return "error"
	end
	if a.name ~= b.name then
		err(st, "T-CEq-Const", "const mismatch: " .. a.name .. " vs " .. b.name,
			prov, { tag = "const_mismatch", a_name = a.name, b_name = b.name })
		return "error"
	end
	trace(st, "T-CEq-Const", a.name)
	return "done"
end

-- T-CEq-Arrow.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CEq_Arrow(st, a, b, prov)
	-- internal: dispatcher routes here only when both are arrow; fires only on solver bug
	if a.tag ~= "arrow" or b.tag ~= "arrow" then
		err(st, "T-CEq-Arrow", "precondition: both arrow"); return "error"
	end
	if #a.args ~= #b.args then
		err(st, "T-CEq-Arrow", "arity mismatch", prov,
			{ tag = "arrow_arity_mismatch", expected = #b.args, got = #a.args })
		return "error"
	end
	for i = 1, #a.args do
		local av, bv = a.args[i], b.args[i]
		if av ~= nil and bv ~= nil then M.emit(st, constraint_mod.eq(av, bv, prov)) end
	end
	M.emit(st, constraint_mod.eq(a.ret, b.ret, prov))
	trace(st, "T-CEq-Arrow", "")
	return "done"
end

-- is_positional: true iff record fields are exactly the string keys "1".."n"
-- for some n >= 0, with no gaps and no non-numeric keys.
-- Keys are stored as strings (tostring(i)) per the substrate in types.lua.
--: (V5Type) -> boolean
local function is_positional(r)
	if r.tag ~= "record" then return false end
	local n = 0
	for _ in pairs(r.fields) do n = n + 1 end
	for i = 1, n do
		if r.fields[tostring(i)] == nil then return false end
	end
	return true
end

-- T-CEq-Record.
-- Dispatch: both positional -> arity-check then per-field eq.
--           named/mixed    -> existing invariant domain-equality check.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CEq_Record(st, a, b, prov)
	-- internal: dispatcher routes here only when both are record; fires only on solver bug
	if a.tag ~= "record" or b.tag ~= "record" then
		err(st, "T-CEq-Record", "precondition: both record"); return "error"
	end
	local a_pos = is_positional(a)
	local b_pos = is_positional(b)
	if a_pos and b_pos then
		-- Positional branch: eq is strict on arity (no nil-pad for eq).
		local na, nb = 0, 0
		for _ in pairs(a.fields) do na = na + 1 end
		for _ in pairs(b.fields) do nb = nb + 1 end
		if na ~= nb then
			err(st, "T-CEq-Record", "positional arity mismatch: " .. na .. " vs " .. nb,
				prov, { tag = "record_arity_mismatch", expected = nb, got = na })
			return "error"
		end
		for i = 1, na do
			local va = a.fields[tostring(i)]
			local vb = b.fields[tostring(i)]
			if va ~= nil and vb ~= nil then
				M.emit(st, constraint_mod.eq(va, vb, prov))
			end
		end
		trace(st, "T-CEq-Record", "positional n=" .. na)
		return "done"
	end
	-- Mixed shapes (one positional, one named): fall through to named-key rule.
	-- Conservative choice: treat as named-key domain mismatch if keys differ.
	for k, va in pairs(a.fields) do
		local vb = b.fields[k]
		if vb == nil then
			err(st, "T-CEq-Record", "missing field " .. k, prov,
				{ tag = "missing_field", field = k })
		elseif va ~= nil then
			M.emit(st, constraint_mod.eq(va, vb, prov))
		end
	end
	for k, _ in pairs(b.fields) do
		if a.fields[k] == nil then
			err(st, "T-CEq-Record", "extra field " .. k, prov,
				{ tag = "extra_field", field = k })
		end
	end
	trace(st, "T-CEq-Record", "")
	return "done"
end

-- T-CEq-App.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CEq_App(st, a, b, prov)
	-- internal: dispatcher routes here only when both are app; fires only on solver bug
	if a.tag ~= "app" then err(st, "T-CEq-App", "precondition: a app"); return "error" end
	if b.tag ~= "app" then err(st, "T-CEq-App", "precondition: b app"); return "error" end
	local af = a.f --[[: V5Type ]]
	local bf = b.f --[[: V5Type ]]
	local aa = a.a --[[: V5Type ]]
	local ba = b.a --[[: V5Type ]]
	M.emit(st, constraint_mod.eq(af, bf, prov))
	M.emit(st, constraint_mod.eq(aa, ba, prov))
	trace(st, "T-CEq-App", "")
	return "done"
end

-- T-CEq-Mismatch.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CEq_Mismatch(st, a, b, prov)
	err(st, "T-CEq-Mismatch", "kind mismatch: " .. a.tag .. " vs " .. b.tag,
		prov, { tag = "kind_mismatch", a_tag = a.tag, b_tag = b.tag })
	return "error"
end

-- Dispatcher.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
local function step_ceq(st, ra, rb, prov)
	if ra.tag == "uvar" and rb.tag == "uvar" then return M.rule_T_CEq_UU(st, ra, rb, prov) end
	if ra.tag == "uvar" then return M.rule_T_CEq_Bind_L(st, ra, rb, prov) end
	if rb.tag == "uvar" then return M.rule_T_CEq_Bind_R(st, ra, rb, prov) end
	if ra.tag ~= rb.tag then return M.rule_T_CEq_Mismatch(st, ra, rb, prov) end
	if ra.tag == "const" then return M.rule_T_CEq_Const(st, ra, rb, prov) end
	if ra.tag == "arrow" then return M.rule_T_CEq_Arrow(st, ra, rb, prov) end
	if ra.tag == "record" then return M.rule_T_CEq_Record(st, ra, rb, prov) end
	if ra.tag == "app" then return M.rule_T_CEq_App(st, ra, rb, prov) end
	return M.rule_T_CEq_Mismatch(st, ra, rb, prov)
end

-- ────────────────────────────────────────────────────────────────────────────
-- T-CSub family (variance-respecting)
-- ────────────────────────────────────────────────────────────────────────────
--
-- Per `docs/typechecker-v5-operational-semantics.md` § "Subtyping (variance-
-- respecting)".  Declaration-site variance via `variance.lookup(name)`;
-- default = invariant.  Soundness floor: record fields are invariant in
-- v5.0 (CTableSet model — mutable fields can't be covariant).

-- T-CSub-Refl.  Same type both sides under deref.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_Refl(st, a, b, prov)
	-- internal: dispatcher calls this only after equal() returns true; fires only on solver bug
	if not types_mod.equal(a, b) then
		err(st, "T-CSub-Refl", "precondition: types equal"); return "error"
	end
	trace(st, "T-CSub-Refl", "")
	return "done"
end

-- T-CSub-TVar.  At least one side is an unbound UVar.  Spec A simple-sub: the
-- three cases are DONE-with-re-emission (never park).  Each maintains the
-- bound-graph closure by re-emitting cache-guarded cross obligations.
--   Upper:  α <: T (T non-uvar)  — add T to upper[r]; ∀ L∈lower[r]: CSub(L,T).
--   Lower:  T <: α (T non-uvar)  — add T to lower[r]; ∀ U∈upper[r]: CSub(T,U).
--   Flow:   α <: β (distinct)    — record edge r_α→r_β; flow β's lowers into
--                                  α's lowers and α's uppers into β's uppers;
--                                  re-emit the cross-product the flow creates.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_TVar(st, a, b, prov)
	local B = st.bounds
	if a.tag == "uvar" and b.tag ~= "uvar" then
		-- T-CSub-TVar-Upper.
		local r = subst_mod.find(st.subst, a.id)
		add_upper(st, r, b, prov)
		trace(st, "T-CSub-TVar-Upper", "upper of " .. tostring(r))
		return "done"
	end
	if b.tag == "uvar" and a.tag ~= "uvar" then
		-- T-CSub-TVar-Lower.
		local r = subst_mod.find(st.subst, b.id)
		add_lower(st, r, a, prov)
		trace(st, "T-CSub-TVar-Lower", "lower of " .. tostring(r))
		return "done"
	end
	-- Both uvars: T-CSub-TVar-Flow.
	-- internal: dispatcher guarantees both are uvar here; fires only on solver bug
	if a.tag ~= "uvar" or b.tag ~= "uvar" then
		err(st, "T-CSub-TVar-Flow", "precondition: both uvar"); return "error"
	end
	local ra = subst_mod.find(st.subst, a.id)
	local rb = subst_mod.find(st.subst, b.id)
	if ra == rb then
		-- Reflexive (subsumed by T-CSub-Refl): no change.
		trace(st, "T-CSub-TVar-Flow", "reflexive")
		return "done"
	end
	-- Record directional edge r_α → r_β (and the dual in-edge).
	local ea = B.edge_up[ra]
	if ea == nil then ea = {} --[[: { [integer]: boolean } ]]; B.edge_up[ra] = ea end
	ea[rb] = true
	local ed = B.edge_down[rb]
	if ed == nil then ed = {} --[[: { [integer]: boolean } ]]; B.edge_down[rb] = ed end
	ed[ra] = true
	-- Flow α's lowers FORWARD into β (L <: α <: β ⇒ L <: β) and β's uppers
	-- BACKWARD into α (α <: β <: U ⇒ α <: U).  add_lower(rb,…)/add_upper(ra,…)
	-- propagate transitively across the component and re-emit every new cross
	-- obligation; bound-set dedup + the cache terminate it.
	local a_lowers = B.lower[ra]
	if a_lowers ~= nil then
		-- Snapshot: add_lower may mutate B.lower[rb]; iterate the source list.
		local snap = {} --[[: V5Type[] ]]
		for i = 1, #a_lowers do snap[i] = a_lowers[i] end
		for i = 1, #snap do local v = snap[i]; if v ~= nil then add_lower(st, rb, v, prov) end end
	end
	local b_uppers = B.upper[rb]
	if b_uppers ~= nil then
		local snap = {} --[[: V5Type[] ]]
		for i = 1, #b_uppers do snap[i] = b_uppers[i] end
		for i = 1, #snap do local v = snap[i]; if v ~= nil then add_upper(st, ra, v, prov) end end
	end
	trace(st, "T-CSub-TVar-Flow", tostring(ra) .. "→" .. tostring(rb))
	return "done"
end

-- T-CSub-Arrow.  Contra in args, co in rets.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_Arrow(st, a, b, prov)
	-- internal: dispatcher routes here only when both are arrow; fires only on solver bug
	if a.tag ~= "arrow" or b.tag ~= "arrow" then
		err(st, "T-CSub-Arrow", "precondition: both arrow"); return "error"
	end
	if #a.args ~= #b.args then
		err(st, "T-CSub-Arrow", "arity mismatch", prov,
			{ tag = "arrow_arity_mismatch", expected = #b.args, got = #a.args })
		return "error"
	end
	for i = 1, #a.args do
		local av, bv = a.args[i], b.args[i]
		if av ~= nil and bv ~= nil then
			-- contravariant in args: B_i <: A_i.
			M.emit(st, constraint_mod.sub(bv, av, prov))
		end
	end
	-- covariant in ret: delegate to positional Record rules (Phase 3).
	M.emit(st, constraint_mod.sub(a.ret, b.ret, prov))
	trace(st, "T-CSub-Arrow", "")
	return "done"
end

-- T-CSub-Const-Var.  Two same-named Consts; degenerate (no params on AST).
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_Const_Var(st, a, b, prov)
	-- internal: dispatcher routes here only when both are const; fires only on solver bug
	if a.tag ~= "const" or b.tag ~= "const" then
		err(st, "T-CSub-Const-Var", "precondition: both const"); return "error"
	end
	-- Spec A: the const-vs-const lattice (including integer <: number) is the
	-- single atomic_subtype relation — no inline lattice facts here.
	return M.rule_T_CSub_Atomic(st, a, b, prov)
end

-- Walk a left-associated App chain to extract the head Const name and its
-- argument list (innermost-first reversal — args in source order).
-- Returns (head_name, args[]) where head_name is nil if the head is not
-- a Const.  Using head name (string) instead of returning the Const itself
-- sidesteps narrowing through the union return type.
--: (V5Type) -> (string | nil, V5Type[])
local function app_head_and_args(t)
	local args = {} --[[: V5Type[] ]]
	local cur = t
	while cur.tag == "app" do
		-- cur.f is the curried head; cur.a is the rightmost arg.
		args[#args + 1] = cur.a
		cur = cur.f
	end
	-- Reverse args so source-order matches (outermost App carries last arg).
	local n = #args
	local sorted = {} --[[: V5Type[] ]]
	for i = 1, n do sorted[i] = args[n - i + 1] end
	if cur.tag == "const" then return cur.name, sorted end
	return nil, sorted
end

-- T-CSub-App-Var.  Two applications with matching named head — per-position
-- variance dispatch.  Returns "miss" if heads aren't both Consts with the
-- same name (caller falls to T-CSub-App-Struct).
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_App_Var(st, a, b, prov)
	local ha, aa = app_head_and_args(a)
	local hb, ab = app_head_and_args(b)
	if ha == nil or hb == nil then return "miss" end
	if ha ~= hb then
		err(st, "T-CSub-App-Var",
			"head mismatch: " .. ha .. " vs " .. hb,
			prov, { tag = "head_mismatch", a_name = ha, b_name = hb })
		return "error"
	end
	if #aa ~= #ab then
		err(st, "T-CSub-App-Var",
			"arity mismatch for " .. ha, prov,
			{ tag = "arrow_arity_mismatch", expected = #ab, got = #aa })
		return "error"
	end
	for i = 1, #aa do
		local xi, yi = aa[i], ab[i]
		if xi ~= nil and yi ~= nil then
			local v = variance_mod.at(ha, i)
			if v == "co" then
				M.emit(st, constraint_mod.sub(xi, yi, prov))
			elseif v == "contra" then
				M.emit(st, constraint_mod.sub(yi, xi, prov))
			else
				M.emit(st, constraint_mod.eq(xi, yi, prov))
			end
		end
	end
	trace(st, "T-CSub-App-Var", ha)
	return "done"
end

-- T-CSub-App-Struct.  Non-Const head fallback: decompose under invariance.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_App_Struct(st, a, b, prov)
	-- internal: dispatcher routes here only when both are app; fires only on solver bug
	if a.tag ~= "app" or b.tag ~= "app" then
		err(st, "T-CSub-App-Struct", "precondition: both app"); return "error"
	end
	M.emit(st, constraint_mod.eq(a.f, b.f, prov))
	M.emit(st, constraint_mod.eq(a.a, b.a, prov))
	trace(st, "T-CSub-App-Struct", "")
	return "done"
end

-- T-CSub-Record-Width.  Width subtyping with invariant fields.  Supertype
-- (b) has fewer fields; each common field is required equal.
-- Dispatch: both positional -> covariant per-field sub with nil-pad width
--           policy; named/mixed -> existing invariant domain check.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_Record_Width(st, a, b, prov)
	-- internal: dispatcher routes here only when both are record; fires only on solver bug
	if a.tag ~= "record" or b.tag ~= "record" then
		err(st, "T-CSub-Record-Width", "precondition: both record"); return "error"
	end
	local a_pos = is_positional(a)
	local b_pos = is_positional(b)
	if a_pos and b_pos then
		-- Positional covariant branch (Arrow returns).
		-- Nil-pad policy: only iterate up to nb (supertype's field count).
		--   - Slots 1..min(na,nb): sub(a.fields[i], b.fields[i]) — covariant.
		--   - Slots na+1..nb: a's missing slots are nil; sub(nil, b.fields[i]).
		--   - Slots nb+1..na: truncation — b does not require them; skip.
		-- This matches Lua multi-return semantics: extra callee returns are
		-- silently discarded when fewer LHS slots are requested.
		local na, nb = 0, 0
		for _ in pairs(a.fields) do na = na + 1 end
		for _ in pairs(b.fields) do nb = nb + 1 end
		local nil_type = types_mod.const("nil")
		for i = 1, nb do
			local va = a.fields[tostring(i)] or nil_type
			local vb = b.fields[tostring(i)]
			if vb ~= nil then
				M.emit(st, constraint_mod.sub(va, vb, prov))
			end
		end
		trace(st, "T-CSub-Record-Width", "positional covariant na=" .. na .. " nb=" .. nb)
		return "done"
	end
	-- Mixed shapes (one positional, one named): fall through to named-key rule.
	-- Conservative choice: treat as named-key subtyping; key-shape mismatch
	-- surfaces as a missing-field error when the positional string keys ("1",
	-- "2", ...) don't appear in the named record.
	for k, vb in pairs(b.fields) do
		local va = a.fields[k]
		if va == nil then
			err(st, "T-CSub-Record-Width", "missing field " .. k, prov,
				{ tag = "missing_field", field = k })
		elseif vb ~= nil then
			-- Invariant: fields are mutable in v5.0 (per CTableSet model).
			M.emit(st, constraint_mod.eq(va, vb, prov))
		end
	end
	trace(st, "T-CSub-Record-Width", "")
	return "done"
end

-- T-CSub-Union-L.  LHS is union: each branch subtypes RHS.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_Union_L(st, a, b, prov)
	-- internal: dispatcher routes here only when a=union; fires only on solver bug
	if a.tag ~= "union" then
		err(st, "T-CSub-Union-L", "precondition: a union"); return "error"
	end
	for i = 1, #a.xs do
		local ai = a.xs[i]
		if ai ~= nil then M.emit(st, constraint_mod.sub(ai, b, prov)) end
	end
	trace(st, "T-CSub-Union-L", "")
	return "done"
end

-- T-CSub-Union-R.  RHS is union: LHS must exactly equal some branch.
-- v5.0 simplification (no backtracking search).
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_Union_R(st, a, b, prov)
	-- internal: dispatcher routes here only when b=union; fires only on solver bug
	if b.tag ~= "union" then
		err(st, "T-CSub-Union-R", "precondition: b union"); return "error"
	end
	for j = 1, #b.xs do
		local bj = b.xs[j]
		if bj ~= nil and types_mod.equal(a, bj) then
			trace(st, "T-CSub-Union-R", "matched branch " .. tostring(j))
			return "done"
		end
	end
	err(st, "T-CSub-Union-R", "no branch matches LHS exactly (v5.0 limitation)",
		prov, { tag = "no_matching_branch", value_ty = a, union_ty = b })
	return "error"
end

-- T-CSub-Mismatch.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_Mismatch(st, a, b, prov)
	err(st, "T-CSub-Mismatch", "sub kind mismatch: " .. a.tag .. " vs " .. b.tag,
		prov, { tag = "kind_mismatch", a_tag = a.tag, b_tag = b.tag })
	return "error"
end

-- T-CSub-Atomic.  Both sides deref to atoms (no decomposable structure); the
-- relation is decided by ONE atomic_subtype call.  Subsumes the former
-- T-CSub-Top / T-CSub-Never / T-CSub-LitWiden / T-CSub-Const-Var atom facts —
-- they are now all a single lattice consultation (Spec A).
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_Atomic(st, ra, rb, prov)
	if atomic_subtype(ra, rb) then
		trace(st, "T-CSub-Atomic", "")
		return "done"
	end
	-- ¬atomic_subtype(a, b) ⇒ error("not a subtype").  Const-vs-const reports a
	-- const_mismatch (preserves the prior error shape); else generic.
	if ra.tag == "const" and rb.tag == "const" then
		err(st, "T-CSub-Const-Var",
			"const name mismatch: " .. ra.name .. " vs " .. rb.name,
			prov, { tag = "const_mismatch", a_name = ra.name, b_name = rb.name })
		return "error"
	end
	err(st, "T-CSub-Atomic", "not a subtype", prov,
		{ tag = "kind_mismatch", a_tag = ra.tag, b_tag = rb.tag })
	return "error"
end

-- CSub dispatcher.  Order matters: Refl first (cheap fast path), then TVar
-- (must precede shape dispatch — uvars masquerade as no tag here), then
-- top/bottom, then by tag.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
local function step_csub(st, ra, rb, prov)
	-- Refl fast path.
	if types_mod.equal(ra, rb) then
		return M.rule_T_CSub_Refl(st, ra, rb, prov)
	end
	-- TVar route.
	if ra.tag == "uvar" or rb.tag == "uvar" then
		return M.rule_T_CSub_TVar(st, ra, rb, prov)
	end
	-- T-CSub-Atomic (Spec A): bottom/top edges, plus both-atom lattice
	-- (integer<:number, literal widening, const reflexivity) are ONE relation.
	-- `never <: anything` and `anything <: unknown` hold regardless of the other
	-- side's structure; otherwise both sides must be lattice atoms.
	if is_never(ra) or is_unknown(rb) or (is_lattice_atom(ra) and is_lattice_atom(rb)) then
		return M.rule_T_CSub_Atomic(st, ra, rb, prov)
	end
	-- Union dispatch (L takes priority over R; both can apply if both sides
	-- are unions — emit per-branch sub from L, the recursive call will see
	-- RHS-only-union on each branch).
	if ra.tag == "union" then
		return M.rule_T_CSub_Union_L(st, ra, rb, prov)
	end
	if rb.tag == "union" then
		return M.rule_T_CSub_Union_R(st, ra, rb, prov)
	end
	-- Intersection dispatch (LHS decomp first; if both sides are
	-- intersections, the recursive call lands on RHS-only intersection).
	if ra.tag == "intersection" then
		return M.rule_T_CSub_Intersection_Decomp(st, ra.parts, rb, prov)
	end
	if rb.tag == "intersection" then
		return M.rule_T_CSub_Intersection_Conj(st, ra, rb.parts, prov)
	end
	-- Same-tag dispatch.
	if ra.tag == rb.tag then
		if ra.tag == "const" then
			return M.rule_T_CSub_Const_Var(st, ra, rb, prov)
		end
		if ra.tag == "arrow" then
			return M.rule_T_CSub_Arrow(st, ra, rb, prov)
		end
		if ra.tag == "record" then
			return M.rule_T_CSub_Record_Width(st, ra, rb, prov)
		end
		if ra.tag == "app" then
			local status = M.rule_T_CSub_App_Var(st, ra, rb, prov)
			if status == "miss" then
				return M.rule_T_CSub_App_Struct(st, ra, rb, prov)
			end
			return status
		end
		-- Var / lambda / etc.: fall back to equality.
		M.emit(st, constraint_mod.eq(ra, rb, prov))
		trace(st, "T-CSub-Struct", "fallback CEq for tag=" .. ra.tag)
		return "done"
	end
	return M.rule_T_CSub_Mismatch(st, ra, rb, prov)
end

-- ────────────────────────────────────────────────────────────────────────────
-- Intersection rules (Phase 4)
-- ────────────────────────────────────────────────────────────────────────────
--
-- Effects ARE types — `!io`, `!throw<E>`, `!yield<Y,R>` are TConst (with a
-- "!" prefix) and TApp chains over them, handled uniformly with all other
-- types under intersection.  Canonical form (flatten/sort/dedupe) lives in
-- constraint_mod so both interpreters share a single source of truth.

-- T-CIntersectionEq-Canonical.  Canonicalize both sides; if lengths differ
-- after canonicalization → error.  Else emit pair-wise CEq.
--: (OpSemState, V5Type[], V5Type[], Provenance) -> string
function M.rule_T_CIntersectionEq_Canonical(st, parts_a, parts_b, prov)
	local ca = constraint_mod.flatten_parts(parts_a)
	local cb = constraint_mod.flatten_parts(parts_b)
	if #ca ~= #cb then
		err(st, "T-CIntersectionEq-Canonical",
			"intersection arity mismatch after canonicalization: " ..
			tostring(#ca) .. " vs " .. tostring(#cb),
			prov, { tag = "intersection_arity_mismatch", expected = #cb, got = #ca })
		return "error"
	end
	for i = 1, #ca do
		local av, bv = ca[i], cb[i]
		if av ~= nil and bv ~= nil then
			M.emit(st, constraint_mod.eq(av, bv, prov))
		end
	end
	trace(st, "T-CIntersectionEq-Canonical", "n=" .. tostring(#ca))
	return "done"
end

-- T-CSub-Intersection-Decomp.  LHS intersection: (A & B) <: C if some part
-- already proves it under types_mod.equal.  Eager fast path; v5.0 has no
-- disjunctive constraint scheduler, so all parts being unresolved tvars
-- yields a stuck error rather than a disjunction.
--: (OpSemState, V5Type[], V5Type, Provenance) -> string
function M.rule_T_CSub_Intersection_Decomp(st, parts_lhs, rhs, prov)
	local canon = constraint_mod.flatten_parts(parts_lhs)
	for i = 1, #canon do
		local p = canon[i]
		if p ~= nil and types_mod.equal(p, rhs) then
			trace(st, "T-CSub-Intersection-Decomp",
				"eager part-match at " .. tostring(i))
			return "done"
		end
	end
	-- No eager match — try emitting CSub on the first non-uvar part as the
	-- best-effort progress.  If every part is a uvar, error (no disjunction).
	for i = 1, #canon do
		local p = canon[i]
		if p ~= nil and p.tag ~= "uvar" then
			M.emit(st, constraint_mod.sub(p, rhs, prov))
			trace(st, "T-CSub-Intersection-Decomp", "delegated part " .. tostring(i))
			return "done"
		end
	end
	err(st, "T-CSub-Intersection-Decomp",
		"all LHS intersection parts are uvars; no disjunctive scheduler in v5.0",
		prov, { tag = "all_parts_unresolved" })
	return "error"
end

-- T-CSub-Intersection-Conj.  RHS intersection: A <: (B & C) iff A <: B AND
-- A <: C.  Emit a CSub per canonicalized RHS part.
--: (OpSemState, V5Type, V5Type[], Provenance) -> string
function M.rule_T_CSub_Intersection_Conj(st, lhs, parts_rhs, prov)
	local canon = constraint_mod.flatten_parts(parts_rhs)
	for i = 1, #canon do
		local p = canon[i]
		if p ~= nil then M.emit(st, constraint_mod.sub(lhs, p, prov)) end
	end
	trace(st, "T-CSub-Intersection-Conj", "n=" .. tostring(#canon))
	return "done"
end

-- T-CIntersectionMember-Direct.  If `ty` (post-deref) is an intersection
-- canonically containing `part`, succeed.  If unresolved uvars remain in
-- ty, park (F2 enforcement at quiescence will surface the unresolved case).
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CIntersectionMember_Direct(st, ty, part, prov)
	local dty = subst_mod.deref(st.subst, ty) --[[: V5Type ]]
	if dty.tag == "uvar" then
		-- Park: when ty's uvar is bound we may decide.
		return "stuck"
	end
	if dty.tag == "intersection" then
		local canon = constraint_mod.flatten_parts(dty.parts)
		for i = 1, #canon do
			local p = canon[i]
			if p ~= nil and types_mod.equal(p, part) then
				trace(st, "T-CIntersectionMember-Direct",
					"member match at " .. tostring(i))
				return "done"
			end
		end
		err(st, "T-CIntersectionMember-Direct",
			"part not in intersection",
			prov, { tag = "effect_not_permitted", effect = part, container = dty })
		return "error"
	end
	-- Singleton case: ty IS the part itself.
	if types_mod.equal(dty, part) then
		trace(st, "T-CIntersectionMember-Direct", "singleton match")
		return "done"
	end
	err(st, "T-CIntersectionMember-Direct",
		"ty is neither intersection nor equal to part (tag=" .. dty.tag .. ")",
		prov, { tag = "effect_not_permitted", effect = part, container = dty })
	return "error"
end

-- ────────────────────────────────────────────────────────────────────────────
-- Construction-phase rules
-- ────────────────────────────────────────────────────────────────────────────

-- T-CTOpen.
--: (OpSemState, integer, Provenance) -> string
function M.rule_T_CTOpen(st, tv, prov)
	local r = subst_mod.find(st.subst, tv)
	if subst_mod.binding(st.subst, r) ~= nil then
		trace(st, "T-CTOpen", "idempotent")
		return "done"
	end
	local rec = types_mod.record({}) --[[: V5Type ]]
	if subst_mod.bind(st.subst, r, rec) then wake(st, r); wake_head(st, r) end
	trace(st, "T-CTOpen", "bound empty")
	return "done"
end

-- T-CTSet-Open-Fresh.
--: (OpSemState, integer, string, V5Type, Provenance) -> string
function M.rule_T_CTSet_Open_Fresh(st, tv, key, ty, prov)
	local r = subst_mod.find(st.subst, tv)
	local fields = {} --[[: { [string]: V5Type } ]]
	fields[key] = ty
	local rec = types_mod.record(fields) --[[: V5Type ]]
	if subst_mod.bind(st.subst, r, rec) then wake(st, r); wake_head(st, r) end
	trace(st, "T-CTSet-Open-Fresh", key)
	return "done"
end

-- T-CTSet-Open-Extend.
--: (OpSemState, integer, string, V5Type, Provenance) -> string
function M.rule_T_CTSet_Open_Extend(st, tv, key, ty, prov)
	local r = subst_mod.find(st.subst, tv)
	local b = subst_mod.binding(st.subst, r)
	-- internal: dispatcher routes here after confirming binding present; fires only on solver bug
	if b == nil then
		err(st, "T-CTSet-Open-Extend", "precondition: tv bound"); return "error"
	end
	-- internal: dispatcher routes here after confirming record type; fires only on solver bug
	if b.tag ~= "record" then
		err(st, "T-CTSet-Open-Extend", "precondition: tv bound to record"); return "error"
	end
	b.fields[key] = ty
	wake(st, r)
	trace(st, "T-CTSet-Open-Extend", key)
	return "done"
end

-- T-CTSet-Open-Equate.
--: (OpSemState, integer, string, V5Type, Provenance) -> string
function M.rule_T_CTSet_Open_Equate(st, tv, key, ty, prov)
	local r = subst_mod.find(st.subst, tv)
	local b = subst_mod.binding(st.subst, r)
	-- internal: dispatcher routes here after confirming binding present; fires only on solver bug
	if b == nil then err(st, "T-CTSet-Open-Equate", "precondition: tv bound"); return "error" end
	-- internal: dispatcher routes here after confirming record type; fires only on solver bug
	if b.tag ~= "record" then err(st, "T-CTSet-Open-Equate", "precondition: record"); return "error" end
	local existing = b.fields[key]
	-- internal: dispatcher routes here after confirming field present; fires only on solver bug
	if existing == nil then err(st, "T-CTSet-Open-Equate", "precondition: field present"); return "error" end
	M.emit(st, constraint_mod.eq(existing, ty, prov))
	trace(st, "T-CTSet-Open-Equate", key)
	return "done"
end

-- T-CTSet-Sealed-Reject.
--: (OpSemState, integer, string, V5Type, Provenance) -> string
function M.rule_T_CTSet_Sealed_Reject(st, tv, key, ty, prov)
	err(st, "T-CTSet-Sealed-Reject", "set " .. key .. " on sealed table (tv=" .. tostring(tv) .. ")",
		prov, { tag = "sealed_field_set", field = key })
	return "error"
end

--: (OpSemState, OpSemConstraint) -> string
local function step_tset(st, c)
	if c.tag ~= "tset" then return "done" end
	local r = subst_mod.find(st.subst, c.tv)
	local phase = subst_mod.phase(st.subst, r)
	if phase == "sealed" then
		return M.rule_T_CTSet_Sealed_Reject(st, c.tv, c.key, c.ty, c.prov)
	end
	local b = subst_mod.binding(st.subst, r)
	if b == nil then
		return M.rule_T_CTSet_Open_Fresh(st, c.tv, c.key, c.ty, c.prov)
	end
	-- internal: binding is present but not a record; indicates a solver invariant violation
	if b.tag ~= "record" then
		err(st, "T-CTSet", "tv bound to non-record"); return "error"
	end
	if b.fields[c.key] == nil then
		return M.rule_T_CTSet_Open_Extend(st, c.tv, c.key, c.ty, c.prov)
	end
	return M.rule_T_CTSet_Open_Equate(st, c.tv, c.key, c.ty, c.prov)
end

-- T-CTSeal.
--: (OpSemState, integer, integer | nil, Provenance) -> string
function M.rule_T_CTSeal(st, tv, mu, prov)
	subst_mod.seal(st.subst, tv)
	wake(st, tv)
	trace(st, "T-CTSeal", "")
	return "done"
end

-- ────────────────────────────────────────────────────────────────────────────
-- Method-call rules
-- ────────────────────────────────────────────────────────────────────────────

-- T-CMCall-Open-Stuck.
--: (OpSemState, integer, string, integer, Provenance) -> string
function M.rule_T_CMCall_Open_Stuck(st, tv, key, ret, prov)
	trace(st, "T-CMCall-Open-Stuck", key)
	return "stuck"
end

-- T-CMCall-Sealed-Field.
--: (OpSemState, integer, string, integer, Provenance) -> string
function M.rule_T_CMCall_Sealed_Field(st, tv, key, ret, prov)
	local r = subst_mod.find(st.subst, tv)
	local b = subst_mod.binding(st.subst, r)
	-- internal: step_mcall routes here after confirming sealed+bound; fires only on solver bug
	if b == nil then err(st, "T-CMCall-Sealed-Field", "precondition: bound"); return "error" end
	-- internal: step_mcall routes here after confirming record; fires only on solver bug
	if b.tag ~= "record" then err(st, "T-CMCall-Sealed-Field", "precondition: record"); return "error" end
	local mraw = b.fields[key]
	-- internal: step_mcall routes here after confirming field exists; fires only on solver bug
	if mraw == nil then err(st, "T-CMCall-Sealed-Field", "precondition: field present"); return "error" end
	local m = mraw --[[: V5Type ]]
	-- internal: field found but is not callable (type inconsistency); fires only on solver bug
	if m.tag ~= "arrow" then err(st, "T-CMCall-Sealed-Field", "field is not callable"); return "error" end
	local r1raw = m.ret.fields["1"]
	-- internal: arrow has no return slots; fires only on solver bug
	if r1raw == nil then err(st, "T-CMCall-Sealed-Field", "arrow with zero rets"); return "error" end
	local r1 = r1raw --[[: V5Type ]]
	local lhs = types_mod.uvar(ret) --[[: V5Type ]]
	M.emit(st, constraint_mod.eq(lhs, r1, prov))
	trace(st, "T-CMCall-Sealed-Field", key)
	return "done"
end

-- T-CMCall-Sealed-Missing.
--: (OpSemState, integer, string, integer, Provenance) -> string
function M.rule_T_CMCall_Sealed_Missing(st, tv, key, ret, prov)
	err(st, "T-CMCall-Sealed-Missing", "no method " .. key,
		prov, { tag = "missing_method", method = key })
	return "error"
end

--: (OpSemState, OpSemConstraint) -> string
local function step_mcall(st, c)
	if c.tag ~= "mcall" then return "done" end
	local r = subst_mod.find(st.subst, c.tv)
	local phase = subst_mod.phase(st.subst, r)
	if phase == "open" then
		return M.rule_T_CMCall_Open_Stuck(st, c.tv, c.key, c.ret, c.prov)
	end
	local b = subst_mod.binding(st.subst, r)
	-- internal: phase=sealed but tv has no binding; fires only on solver bug
	if b == nil then err(st, "T-CMCall", "sealed tv unbound"); return "error" end
	-- internal: binding is not a record; fires only on solver bug
	if b.tag ~= "record" then err(st, "T-CMCall", "sealed tv not a record"); return "error" end
	if b.fields[c.key] == nil then
		return M.rule_T_CMCall_Sealed_Missing(st, c.tv, c.key, c.ret, c.prov)
	end
	return M.rule_T_CMCall_Sealed_Field(st, c.tv, c.key, c.ret, c.prov)
end

-- ────────────────────────────────────────────────────────────────────────────
-- CRow rules (row-polymorphic records)
-- ────────────────────────────────────────────────────────────────────────────
--
-- Row variables live on TRecord.row (a TRowVar node or nil).
-- nil means closed (no further extension allowed).
-- A TRowVar with id means open (may grow).
--
-- CRow constraints operate on an entire TRecord type (not a tvar id) so the
-- solver must first deref the record_ty argument to find the concrete record.
-- If record_ty is still a UVar, the rule parks on that UVar.
--
-- Row-var ids are separate from UVar ids.  They are tracked in a simple
-- counter; no union-find (row vars are either open or closed, never merged
-- with other row vars directly — field CEqs handle structural sharing).

-- Row-var ids are created by callers (e.g. tests) using types_mod.rowvar(id)
-- and types_mod.record_open(fields, row).  The solver does not allocate new
-- row vars in Phase 2; it only reads and closes them.

-- Deref the record_ty through UVars; return the record or nil if still stuck.
--: (OpSemState, V5Type) -> (V5Type | nil, boolean)
-- Returns (record_type, is_stuck).  is_stuck=true means park on the uvar.
local function deref_to_record(st, ty)
	local t = subst_mod.deref(st.subst, ty) --[[: V5Type ]]
	if t.tag == "uvar" then return nil, true end
	if t.tag == "record" then return t, false end
	return nil, false -- concrete non-record: error at caller
end

-- T-CRowExtend-Bind: record has an open row var → add key to fields and keep row open.
--: (OpSemState, V5Type, V5Type, string, V5Type, Provenance) -> string
function M.rule_T_CRowExtend_Bind(st, _rec_ty, rec, key, field_ty, _prov)
	-- internal: caller deref_to_record already confirmed record; fires only on solver bug
	if rec.tag ~= "record" then err(st, "T-CRowExtend-Bind", "precondition: record"); return "error" end
	-- internal: dispatcher routes here only for open-row case; fires only on solver bug
	if rec.row == nil then err(st, "T-CRowExtend-Bind", "precondition: open row"); return "error" end
	-- Mutate field into the record (monotone extension — no overwrite).
	rec.fields[key] = field_ty
	trace(st, "T-CRowExtend-Bind", "bound " .. key)
	return "done"
end

-- T-CRowExtend-Lookup: record already has the key → emit CEq(existing, field_ty).
--: (OpSemState, V5Type, V5Type, string, V5Type, Provenance) -> string
function M.rule_T_CRowExtend_Lookup(st, _rec_ty, rec, key, field_ty, prov)
	-- internal: caller deref_to_record already confirmed record; fires only on solver bug
	if rec.tag ~= "record" then err(st, "T-CRowExtend-Lookup", "precondition: record"); return "error" end
	local existing = rec.fields[key]
	-- internal: dispatcher routes here only when key already present; fires only on solver bug
	if existing == nil then err(st, "T-CRowExtend-Lookup", "precondition: key present"); return "error" end
	M.emit(st, constraint_mod.eq(existing, field_ty, prov))
	trace(st, "T-CRowExtend-Lookup", "equated " .. key)
	return "done"
end

-- T-CRowExtend-Closed: closed record missing key → ERROR.
--: (OpSemState, V5Type, V5Type, string, V5Type, Provenance) -> string
function M.rule_T_CRowExtend_Closed(st, _rec_ty, rec, key, _field_ty, prov)
	-- internal: caller deref_to_record already confirmed record; fires only on solver bug
	if rec.tag ~= "record" then err(st, "T-CRowExtend-Closed", "precondition: record"); return "error" end
	err(st, "T-CRowExtend-Closed", "closed record cannot extend: key=" .. key,
		prov, { tag = "closed_extend", field = key })
	return "error"
end

--: (OpSemState, V5Type, string, V5Type, Provenance) -> string
local function step_crow_extend(st, record_ty, key, field_ty, prov)
	local rec, stuck = deref_to_record(st, record_ty)
	if stuck then
		-- record_ty is still a UVar; park (blockers_of picks up the watcher).
		return "stuck"
	end
	if rec == nil then
		local tag = subst_mod.deref(st.subst, record_ty).tag
		err(st, "T-CRowExtend", "record_ty is not a record: tag=" .. tag,
			prov, { tag = "not_a_record", found_tag = tag })
		return "error"
	end
	-- Dispatch on row state.
	if rec.row ~= nil then
		-- Open row.
		if rec.fields[key] ~= nil then
			return M.rule_T_CRowExtend_Lookup(st, record_ty, rec, key, field_ty, prov)
		end
		return M.rule_T_CRowExtend_Bind(st, record_ty, rec, key, field_ty, prov)
	end
	-- Closed row (row == nil).
	if rec.fields[key] ~= nil then
		return M.rule_T_CRowExtend_Lookup(st, record_ty, rec, key, field_ty, prov)
	end
	return M.rule_T_CRowExtend_Closed(st, record_ty, rec, key, field_ty, prov)
end

-- T-CRowLacks-Open: row is open → park watching the row-var id.
--: (OpSemState, V5Type, V5Type, string, Provenance) -> string
function M.rule_T_CRowLacks_Open(st, _rec_ty, rec, key, _prov)
	local rrow = rec.row
	-- internal: dispatcher routes here only when row is open; fires only on solver bug
	if rrow == nil then err(st, "T-CRowLacks-Open", "precondition: open row"); return "error" end
	trace(st, "T-CRowLacks-Open", "park on rowvar " .. rrow.id .. " key=" .. key)
	return "stuck"
end

-- T-CRowLacks-Closed-Pass: closed and key absent → succeed.
--: (OpSemState, V5Type, V5Type, string, Provenance) -> string
function M.rule_T_CRowLacks_Closed_Pass(st, _rec_ty, _rec, key, _prov)
	trace(st, "T-CRowLacks-Closed-Pass", "key absent: " .. key)
	return "done"
end

-- T-CRowLacks-Closed-Fail: closed and key present → ERROR.
--: (OpSemState, V5Type, V5Type, string, Provenance) -> string
function M.rule_T_CRowLacks_Closed_Fail(st, _rec_ty, _rec, key, prov)
	err(st, "T-CRowLacks-Closed-Fail", "row already contains key: " .. key,
		prov, { tag = "row_already_contains", field = key })
	return "error"
end

--: (OpSemState, V5Type, string, Provenance) -> string
local function step_crow_lacks(st, record_ty, key, prov)
	local rec, stuck = deref_to_record(st, record_ty)
	if stuck then return "stuck" end
	if rec == nil then
		local tag2 = subst_mod.deref(st.subst, record_ty).tag
		err(st, "T-CRowLacks", "record_ty is not a record",
			prov, { tag = "not_a_record", found_tag = tag2 })
		return "error"
	end
	if rec.row ~= nil then
		-- Open row: park watching the row-var id so CRowClose can wake us.
		return M.rule_T_CRowLacks_Open(st, record_ty, rec, key, prov)
	end
	-- Closed.
	if rec.fields[key] ~= nil then
		return M.rule_T_CRowLacks_Closed_Fail(st, record_ty, rec, key, prov)
	end
	return M.rule_T_CRowLacks_Closed_Pass(st, record_ty, rec, key, prov)
end

-- T-CRowClose-Bind: close the row var of a record (set row = nil).
-- If already closed, no-op.
--: (OpSemState, V5Type, Provenance) -> string
function M.rule_T_CRowClose_Bind(st, record_ty, prov)
	local rec, stuck = deref_to_record(st, record_ty)
	if stuck then return "stuck" end
	if rec == nil then
		local tag3 = subst_mod.deref(st.subst, record_ty).tag
		err(st, "T-CRowClose-Bind", "record_ty is not a record",
			prov, { tag = "not_a_record", found_tag = tag3 })
		return "error"
	end
	-- Capture row-var id before closing (needed to wake watchers).
	local rrow = rec.row
	if rrow == nil then
		-- Already closed (positional record or previously closed).
		trace(st, "T-CRowClose-Bind", "already closed")
		return "done"
	end
	local rv_id = rrow.id
	-- Close: set row to nil.
	rec.row = nil
	trace(st, "T-CRowClose-Bind", "closed row rv=" .. rv_id)
	-- Wake any CRowLacks constraints that were parked on this row-var.
	wake_rowvar(st, rv_id)
	return "done"
end

-- blockers_of extension: CRow constraints park on the record_ty's uvar.
-- We override the park logic in M.step via a dedicated branch.

-- ────────────────────────────────────────────────────────────────────────────
-- Instantiation
-- ────────────────────────────────────────────────────────────────────────────

-- T-CInst-Mono.
--: (OpSemState, V5Scheme, V5Type, Provenance) -> string
function M.rule_T_CInst_Mono(st, sch, target, prov)
	M.emit(st, constraint_mod.eq(sch.body, target, prov))
	trace(st, "T-CInst-Mono", "")
	return "done"
end

-- T-CInst.  Allocate `binders` fresh tvars; β-substitute into body.
-- Substitute repeatedly at depth 0: after each step the next outer Var
-- becomes Var(0).
--: (OpSemState, V5Scheme, V5Type, Provenance) -> string
function M.rule_T_CInst(st, sch, target, prov)
	if sch.binders == 0 then return M.rule_T_CInst_Mono(st, sch, target, prov) end
	local body = sch.body
	for _i = 1, sch.binders do
		local fresh = subst_mod.fresh(st.subst, "open")
		local arg = types_mod.uvar(fresh) --[[: V5Type ]]
		body = types_mod.instantiate(body, arg, 0)
	end
	M.emit(st, constraint_mod.eq(body, target, prov))
	trace(st, "T-CInst", "binders=" .. tostring(sch.binders))
	return "done"
end

--: (OpSemState, OpSemConstraint) -> string
local function step_cinst(st, c)
	if c.tag ~= "cinst" then return "done" end
	return M.rule_T_CInst(st, c.scheme, c.target, c.prov)
end

-- ────────────────────────────────────────────────────────────────────────────
-- CHKT / HOUnify (higher-kinded type application + HO unification residue)
-- ────────────────────────────────────────────────────────────────────────────

-- Collect free UVar ids in a type.
--: (V5Type, { [integer]: boolean }) -> nil
local function collect_free_uvars(t, acc)
	types_mod.collect_uvars(t, acc)
end

-- v5.0 restricted Miller pattern fragment check.  Each arg must be a UVar
-- or Const (deref'd); UVars must be pairwise distinct; T's free UVars must
-- be a subset of the arg-UVars.  Returns the allowed-uvar set if in fragment,
-- nil otherwise.
--: (Subst, V5Type[], V5Type) -> { [integer]: boolean } | nil
local function miller_check(s, args, result_walked)
	local allowed = {} --[[: { [integer]: boolean } ]]
	local seen_uvars = {} --[[: { [integer]: boolean } ]]
	local seen_consts = {} --[[: { [string]: boolean } ]]
	for i = 1, #args do
		local a = args[i]
		if a == nil then return nil end
		local da = subst_mod.deref(s, a) --[[: V5Type ]]
		if da.tag == "uvar" then
			if seen_uvars[da.id] == true then return nil end
			seen_uvars[da.id] = true
			allowed[da.id] = true
		elseif da.tag == "const" then
			if seen_consts[da.name] == true then return nil end
			seen_consts[da.name] = true
			-- Const has no UVars; nothing to allow.
		else
			-- v5.0 restriction: only UVar or Const args admitted.
			return nil
		end
	end
	local fv = {} --[[: { [integer]: boolean } ]]
	collect_free_uvars(result_walked, fv)
	for id, _ in pairs(fv) do
		if allowed[id] ~= true then return nil end
	end
	return allowed
end

-- Walker for abstract_body: replaces UVar(id) with Var(map[id]).
-- Recursive; does NOT cross nested Lambdas (returns unchanged, since
-- caller guards via contains_lambda).
--: ({ [integer]: integer }, V5Type) -> V5Type
local function abstract_sub(map, t)
	if t.tag == "uvar" then
		local idx = map[t.id]
		if idx ~= nil then return types_mod.var(idx) end
		return t
	elseif t.tag == "const" or t.tag == "var" or t.tag == "lambda" then
		return t
	elseif t.tag == "app" then
		local sf = abstract_sub(map, t.f) --[[: V5Type ]]
		local sa = abstract_sub(map, t.a) --[[: V5Type ]]
		return types_mod.app(sf, sa)
	elseif t.tag == "record" then
		local out = {} --[[: { [string]: V5Type } ]]
		for fk, fv in pairs(t.fields) do
			if fv ~= nil then local s2 = abstract_sub(map, fv) --[[: V5Type ]]; out[fk] = s2 end
		end
		return types_mod.record(out)
	elseif t.tag == "arrow" then
		local aargs = {} --[[: V5Type[] ]]
		for i = 1, #t.args do
			local v = t.args[i]
			if v ~= nil then local s2 = abstract_sub(map, v) --[[: V5Type ]]; aargs[i] = s2 end
		end
		local aret = abstract_sub(map, t.ret) --[[: V5Type ]]
		return { tag = "arrow", args = aargs, ret = aret }
	elseif t.tag == "union" then
		local xs = {} --[[: V5Type[] ]]
		for i = 1, #t.xs do
			local v = t.xs[i]
			if v ~= nil then local s2 = abstract_sub(map, v) --[[: V5Type ]]; xs[i] = s2 end
		end
		return types_mod.union(xs)
	end
	return t
end

-- Abstract a body over a list of UVar-args, producing a nested Lambda chain.
-- For args = [u1, u2, ..., un], produces  Lambda(_, Lambda(_, ... Lambda(_, body')))
-- where body' has UVar(ui.id) replaced by Var(n - i)  (so u1 -> Var(n-1),
-- u_n -> Var(0)).  v5.0 restriction: assumes body has no inner Lambdas
-- (capture-avoiding shift over nested lambdas is a spec gap; caller must
-- guard via contains_lambda).
--: (V5Type, V5Type[]) -> V5Type
local function abstract_body(body, args)
	local n = #args
	local map = {} --[[: { [integer]: integer } ]]
	for i = 1, n do
		local a = args[i]
		if a ~= nil and a.tag == "uvar" then
			map[a.id] = n - i  -- innermost binder = Var(0) = last arg.
		end
	end
	local body2 = abstract_sub(map, body) --[[: V5Type ]]
	local result = body2
	for _i = 1, n do
		result = types_mod.lambda("*", result) --[[: V5Type ]]
	end
	return result
end

-- Returns true if t contains a Lambda anywhere (used to guard the v5.0
-- restricted abstract).
--: (V5Type) -> boolean
local function contains_lambda(t)
	if t.tag == "lambda" then return true end
	if t.tag == "app" then return contains_lambda(t.f) or contains_lambda(t.a) end
	if t.tag == "record" then
		for _, fv in pairs(t.fields) do if contains_lambda(fv) then return true end end
		return false
	end
	if t.tag == "arrow" then
		for i = 1, #t.args do if contains_lambda(t.args[i]) then return true end end
		return contains_lambda(t.ret)
	end
	if t.tag == "union" then
		for i = 1, #t.xs do if contains_lambda(t.xs[i]) then return true end end
		return false
	end
	return false
end

-- T-CHKT-Miller.  Returns "done" if Miller bound, "miss" if not in fragment.
--: (OpSemState, V5Type, V5Type[], V5Type, Provenance) -> string
function M.rule_T_CHKT_Miller(st, f, args, result, prov)
	local df = subst_mod.deref(st.subst, f) --[[: V5Type ]]
	if df.tag ~= "uvar" then return "miss" end
	local rw = subst_mod.walk(st.subst, result) --[[: V5Type ]]
	local allowed = miller_check(st.subst, args, rw)
	if allowed == nil then return "miss" end
	-- Occurs check: ?F itself must not appear in result.
	if allowed[df.id] == true then
		-- ?F appears among its own args' allowed set vacuously?  No;
		-- allowed comes from args, and ?F binding is what we're computing.
	end
	-- Free-vars check already done in miller_check.
	-- Spec-gap guard: refuse if body contains existing Lambda (v5.0
	-- doesn't shift across nested binders).
	if contains_lambda(rw) then return "miss" end
	local body = abstract_body(rw, args)
	if subst_mod.bind(st.subst, df.id, body) then
		wake(st, df.id)
		wake_head(st, df.id)
	end
	trace(st, "T-CHKT-Miller", "bound ?F id=" .. tostring(df.id))
	return "done"
end

-- T-CHKT-Reduce.  ?F is bound to a (chain of) Lambda(s).  β-reduce and
-- emit CEq(reduced, result).
--: (OpSemState, V5Type, V5Type[], V5Type, Provenance) -> string
function M.rule_T_CHKT_Reduce(st, f, args, result, prov)
	local df = subst_mod.deref(st.subst, f) --[[: V5Type ]]
	-- internal: dispatcher routes here only when f deref to lambda; fires only on solver bug
	if df.tag ~= "lambda" then
		err(st, "T-CHKT-Reduce", "precondition: f deref to lambda")
		return "error"
	end
	local body = df --[[: V5Type ]]
	for i = 1, #args do
		-- internal: lambda binder count must match arg count; fires only on solver bug
		if body.tag ~= "lambda" then
			err(st, "T-CHKT-Reduce", "arity mismatch: not enough lambda binders for " .. tostring(#args) .. " args")
			return "error"
		end
		local a = args[i]
		-- internal: args array contains nil; fires only on solver bug
		if a == nil then
			err(st, "T-CHKT-Reduce", "nil arg at " .. tostring(i))
			return "error"
		end
		local lb = body.b --[[: V5Type ]]
		body = types_mod.instantiate(lb, a, 0) --[[: V5Type ]]
	end
	M.emit(st, constraint_mod.eq(body, result, prov))
	trace(st, "T-CHKT-Reduce", "reduced #args=" .. tostring(#args))
	return "done"
end

-- T-CHKT-Rigid-Mismatch.
--: (OpSemState, V5Type, V5Type[], V5Type, Provenance) -> string
function M.rule_T_CHKT_Rigid_Mismatch(st, f, args, result, prov)
	local df = subst_mod.deref(st.subst, f) --[[: V5Type ]]
	err(st, "T-CHKT-Rigid-Mismatch", "HKT application on non-constructor: tag=" .. df.tag,
		prov, { tag = "not_a_record", found_tag = df.tag })
	return "error"
end

-- T-CHKT-Park.  ?F unbound, Miller fragment doesn't apply: emit HOUnify
-- (which will park on head_watchers in the next dispatch loop iteration).
--: (OpSemState, V5Type, V5Type[], V5Type, Provenance) -> string
function M.rule_T_CHKT_Park(st, f, args, result, prov)
	M.emit(st, M.hounify(f, args, result, prov))
	trace(st, "T-CHKT-Park", "emit HOUnify")
	return "done"
end

-- T-HOUnify-Wake.  f is now rigid (head-watch fired); retry as CHKT.
--: (OpSemState, V5Type, V5Type[], V5Type, Provenance) -> string
function M.rule_T_HOUnify_Wake(st, f, args, result, prov)
	M.emit(st, M.chkt(f, args, result, prov))
	trace(st, "T-HOUnify-Wake", "re-emit CHKT")
	return "done"
end

-- T-HOUnify-Stuck.  Reported at quiescence; helper used by the run loop.
-- Takes OpSemConstraint to avoid narrowing-through-Map issues at call site.
--: (OpSemState, OpSemConstraint) -> nil
function M.rule_T_HOUnify_Stuck(st, c)
	err(st, "T-HOUnify-Stuck",
		"ambiguous constructor variable: head shape never rigidified",
		c.prov, { tag = "ambiguous_constructor" })
end

-- CHKT dispatch.  Decides which CHKT rule applies.
--: (OpSemState, ConstraintHKT) -> string
local function step_chkt(st, c)
	local df = subst_mod.deref(st.subst, c.f) --[[: V5Type ]]
	if df.tag == "lambda" then
		return M.rule_T_CHKT_Reduce(st, c.f, c.args, c.result, c.prov)
	end
	if df.tag ~= "uvar" then
		return M.rule_T_CHKT_Rigid_Mismatch(st, c.f, c.args, c.result, c.prov)
	end
	-- ?F is uvar: try Miller, else park.
	local status = M.rule_T_CHKT_Miller(st, c.f, c.args, c.result, c.prov)
	if status == "miss" then
		return M.rule_T_CHKT_Park(st, c.f, c.args, c.result, c.prov)
	end
	return status
end

-- HOUnify dispatch.  If f is now rigid, retry; else stuck (park).
--: (OpSemState, ConstraintHO) -> string
local function step_hounify(st, c)
	local df = subst_mod.deref(st.subst, c.f) --[[: V5Type ]]
	if df.tag ~= "uvar" then
		return M.rule_T_HOUnify_Wake(st, c.f, c.args, c.result, c.prov)
	end
	trace(st, "T-HOUnify-Park", "stuck on head(?F)")
	return "stuck"
end

-- ────────────────────────────────────────────────────────────────────────────
-- Top-level dispatch + run
-- ────────────────────────────────────────────────────────────────────────────

--: (OpSemState, OpSemConstraint) -> string
function M.step(st, c)
	st.steps = st.steps + 1
	if c.tag == "ceq" then
		local a = subst_mod.deref(st.subst, c.a) --[[: V5Type ]]
		local b = subst_mod.deref(st.subst, c.b) --[[: V5Type ]]
		return step_ceq(st, a, b, c.prov)
	end
	if c.tag == "csub" then
		local a = subst_mod.deref(st.subst, c.a) --[[: V5Type ]]
		local b = subst_mod.deref(st.subst, c.b) --[[: V5Type ]]
		return step_csub(st, a, b, c.prov)
	end
	if c.tag == "topen" then return M.rule_T_CTOpen(st, c.tv, c.prov) end
	if c.tag == "tset"  then return step_tset(st, c) end
	if c.tag == "tseal" then return M.rule_T_CTSeal(st, c.tv, c.mu, c.prov) end
	if c.tag == "mcall" then return step_mcall(st, c) end
	if c.tag == "cinst"   then return step_cinst(st, c) end
	if c.tag == "chkt"    then return step_chkt(st, c) end
	if c.tag == "hounify" then return step_hounify(st, c) end
	if c.tag == "crow_extend" then
		return step_crow_extend(st, c.record_ty, c.key, c.field_ty, c.prov)
	end
	if c.tag == "crow_lacks" then
		return step_crow_lacks(st, c.record_ty, c.key, c.prov)
	end
	if c.tag == "crow_close" then
		return M.rule_T_CRowClose_Bind(st, c.record_ty, c.prov)
	end
	if c.tag == "cint_eq" then
		return M.rule_T_CIntersectionEq_Canonical(st, c.parts_a, c.parts_b, c.prov)
	end
	if c.tag == "cint_sub" then
		-- Set-direction subtyping reduces to RHS-conj (every super-part
		-- must be matched by some sub-part), each emitted as a member query.
		local canon_super = constraint_mod.flatten_parts(c.parts_super)
		local lhs_ty = types_mod.intersection(constraint_mod.flatten_parts(c.parts_sub)) --[[: V5Type ]]
		for i = 1, #canon_super do
			local p = canon_super[i]
			if p ~= nil then
				M.emit(st, constraint_mod.intersection_member(lhs_ty, p, c.prov))
			end
		end
		trace(st, "T-CIntersectionSub", "n=" .. tostring(#canon_super))
		return "done"
	end
	if c.tag == "cint_member" then
		return M.rule_T_CIntersectionMember_Direct(st, c.ty, c.part, c.prov)
	end
	-- internal: constraint tag not recognized by dispatcher; fires only on solver bug
	err(st, "step", "unknown constraint tag " .. tostring(c.tag))
	return "error"
end

-- ────────────────────────────────────────────────────────────────────────────
-- Compatible-bound intersection reduction (Phase 5.F4 residual)
-- ────────────────────────────────────────────────────────────────────────────
--
-- When S-Quiesce emits meet(upper_bounds) as a TIntersection, pairwise
-- structural subtype checks drop subsumed elements so that `integer & number`
-- collapses to `integer` before the CEq is emitted.
--
-- structurally_subtype(a, b) returns true iff `a <: b` can be decided by
-- cheap structural inspection — no constraint emission, no op-sem state.
-- It handles the common primitive lattice and depth-1 structural cases;
-- it returns false (conservative) for any shape it cannot cheaply decide.
--: (V5Type, V5Type) -> boolean
local function structurally_subtype(a, b)
	-- Atom case (Spec A): bottom/top edges + primitive widening (integer<:number,
	-- literal widening, const reflexivity) are the single atomic_subtype relation.
	if is_never(a) or is_unknown(b) or (is_lattice_atom(a) and is_lattice_atom(b)) then
		return atomic_subtype(a, b)
	end
	-- Reflexivity for non-atom shapes.
	if types_mod.equal(a, b) then return true end
	-- Record width: a <: b iff a has at least all fields of b and each shared
	-- field satisfies structural subtyping.  Open row in b is conservative (punt).
	if a.tag == "record" and b.tag == "record" then
		if b.row ~= nil then return false end  -- open supertype: conservative
		for k, bv in pairs(b.fields) do
			local av = a.fields[k]
			if av == nil then return false end
			if not structurally_subtype(av, bv) then return false end
		end
		return true
	end
	-- Arrow: contravariant args, covariant ret.
	if a.tag == "arrow" and b.tag == "arrow" then
		if #a.args ~= #b.args then return false end
		for i = 1, #a.args do
			local ai, bi = a.args[i], b.args[i]
			if ai == nil or bi == nil then return false end
			-- contravariant: b_arg <: a_arg
			if not structurally_subtype(bi, ai) then return false end
		end
		-- covariant ret (both are records)
		return structurally_subtype(a.ret, b.ret)
	end
	return false
end

-- reduce_intersection(xs) takes a list of types (the raw upper bounds) and
-- returns either the single surviving type or a TIntersection with subsumed
-- elements removed.  An element e_j is dropped iff some other e_i satisfies
-- structurally_subtype(e_i, e_j) — i.e., e_i is more specific.
-- Ordering does not affect the result (pairwise, symmetric check).
--: (V5Type[]) -> V5Type
local function reduce_intersection(xs)
	local n = #xs
	local keep = {} --[[: boolean[] ]]
	for i = 1, n do keep[i] = true end
	for i = 1, n do
		if keep[i] then
			for j = 1, n do
				if i ~= j and keep[j] then
					-- xs[i] <: xs[j] → drop xs[j] (xs[i] is more specific).
					local xi, xj = xs[i], xs[j]
					if xi ~= nil and xj ~= nil and structurally_subtype(xi, xj) then
						keep[j] = false
					end
				end
			end
		end
	end
	local reduced = {} --[[: V5Type[] ]]
	for i = 1, n do
		if keep[i] then
			local v = xs[i]
			if v ~= nil then reduced[#reduced + 1] = v end
		end
	end
	if #reduced == 1 then
		local r = reduced[1]
		if r ~= nil then return r end
	end
	return types_mod.intersection(reduced)
end

-- reduce_union(xs) is the dual simplifier for the POSITIVE face (⋃ lowers):
-- an element e_i is dropped iff some other e_j subsumes it
-- (structurally_subtype(e_i, e_j) — e_j is the wider type), e.g.
-- `integer | number → number`.  Applied only at coalescing.
--: (V5Type[]) -> V5Type
local function reduce_union(xs)
	local n = #xs
	local keep = {} --[[: boolean[] ]]
	for i = 1, n do keep[i] = true end
	for i = 1, n do
		if keep[i] then
			for j = 1, n do
				if i ~= j and keep[j] then
					-- xs[i] <: xs[j] → drop xs[i] (xs[j] is wider, dominates the union).
					local xi, xj = xs[i], xs[j]
					if xi ~= nil and xj ~= nil and structurally_subtype(xi, xj) then
						keep[i] = false
					end
				end
			end
		end
	end
	local reduced = {} --[[: V5Type[] ]]
	for i = 1, n do
		if keep[i] then
			local v = xs[i]
			if v ~= nil then reduced[#reduced + 1] = v end
		end
	end
	if #reduced == 1 then
		local r = reduced[1]
		if r ~= nil then return r end
	end
	return types_mod.union(reduced)
end

-- S-Quiesce polar coalescing (Spec A §"S-Quiesce — polar coalescing").  Each
-- root still UNBOUND but carrying bounds is materialized into σ by polarity:
--   • uppers present (negative face dominates) → bind to ⋂ B.upper[r]
--   • only lowers present (positive face)      → bind to ⋃ B.lower[r]
--   • neither                                  → left unbound (free var)
-- The `reduce_intersection`/`reduce_union` simplifiers drop dominated bounds
-- ONLY here.  The ⋃lowers ⊆ ⋂uppers invariant is already enforced eagerly by
-- the on-add cross-emission, so it is not re-checked.  Polarity note: full
-- positive/negative occurrence inference is unbuilt substrate; this picks the
-- consumed (upper) face when uppers exist, else the produced (lower) face —
-- a faithful materialization that any conflict has already surfaced through.
--: (OpSemState) -> nil
local function coalesce_bounds(st)
	local B = st.bounds
	-- Collect candidate roots (those with any bound), dedup via a set.
	local roots = {} --[[: { [integer]: boolean } ]]
	for r in pairs(B.upper) do roots[r] = true end
	for r in pairs(B.lower) do roots[r] = true end
	for r in pairs(roots) do
		local root = subst_mod.find(st.subst, r)
		if subst_mod.binding(st.subst, root) == nil then
			local uppers = B.upper[root]
			local lowers = B.lower[root]
			--: V5Type | nil
			local coalesced = nil
			if uppers ~= nil and #uppers > 0 then
				coalesced = reduce_intersection(uppers)
			elseif lowers ~= nil and #lowers > 0 then
				coalesced = reduce_union(lowers)
			end
			if coalesced ~= nil then
				if subst_mod.bind(st.subst, root, coalesced) then
					wake(st, root); wake_head(st, root)
				end
				trace(st, "S-Quiesce-Coalesce", "root=" .. tostring(root) .. " → " .. coalesced.tag)
			end
		end
	end
end

-- S-Step / S-Park / S-Wake / S-Quiesce.
--: (OpSemState) -> nil
function M.run(st)
	while true do
		local h = st.head
		if h > st.tail then
			st.head = 1; st.tail = 0
			break
		end
		local c = st.worklist[h]
		st.worklist[h] = nil
		st.head = h + 1
		if c ~= nil then
			local status = M.step(st, c)
			if status == "stuck" then park(st, c) end
		end
	end
	-- S-Quiesce polar coalescing (Spec A): materialize unbound roots that carry
	-- bounds into σ BEFORE reporting inert constraints, since coalescing may
	-- bind a root and wake a parked constraint (e.g. a CMethodCall).
	coalesce_bounds(st)
	-- Drain anything coalescing woke; coalescing can in turn produce more
	-- bound-add re-emission, but the cache C guarantees this terminates.
	while st.head <= st.tail do
		local h = st.head
		local cw = st.worklist[h]
		st.worklist[h] = nil
		st.head = h + 1
		if cw ~= nil then
			local status = M.step(st, cw)
			if status == "stuck" then park(st, cw) end
		end
	end
	st.head = 1; st.tail = 0
	-- S-Quiesce: report inert constraints as stuck errors.  CSub never parks
	-- under Spec A (the three T-CSub-TVar cases are done-with-re-emission), so
	-- no csub appears here.  HOUnify gets the dedicated T-HOUnify-Stuck rule;
	-- CRowLacks still parked means the row var was never closed (soundness
	-- floor); others get a generic error.
	for _cid, c in pairs(st.inert) do
		if c.tag == "hounify" then
			M.rule_T_HOUnify_Stuck(st, c)
		elseif c.tag == "crow_lacks" then
			local ckey = c.key or "?"
			err(st, "S-Quiesce-CRowLacks",
				"CRowLacks still unresolved at quiescence (row never closed): key=" .. ckey,
				c.prov, { tag = "missing_field", field = ckey })
		elseif c.tag == "cint_member" then
			-- F2 enforcement: stuck inferred effect — a CIntersectionMember
			-- on a uvar that never got bound must error at quiescence.
			--: V5Type | nil
			local container_nil = nil
			local eff_ty = as_v5type(c.part)
			if eff_ty ~= nil then
				--: ErrorDetails
				local det = { tag = "effect_not_permitted", effect = eff_ty, container = container_nil }
				err(st, "S-Quiesce-CIntersectionMember",
					"CIntersectionMember stuck on unbound uvar (effect never inferred)",
					c.prov, det)
			else
				err(st, "S-Quiesce-CIntersectionMember",
					"CIntersectionMember stuck on unbound uvar (effect never inferred)",
					c.prov, nil)
			end
		else
			-- internal: unknown constraint tag still stuck at quiescence; fires only on solver bug
			err(st, "S-Quiesce", "stuck constraint (tag=" .. c.tag .. ")")
		end
	end
	-- Drain any CEq constraints emitted by S-Quiesce defaulting above.
	while st.head <= st.tail do
		local h = st.head
		local c2 = st.worklist[h]
		st.worklist[h] = nil
		st.head = h + 1
		if c2 ~= nil then
			local status = M.step(st, c2)
			if status == "stuck" then
				-- internal: constraint emitted by S-Quiesce defaulting is still stuck; fires only on solver bug
				err(st, "S-Quiesce-Drain", "constraint still stuck after quiescence drain (tag=" .. c2.tag .. ")")
			end
		end
	end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Inspection helpers
-- ────────────────────────────────────────────────────────────────────────────

--: (OpSemState, integer) -> V5Type
function M.resolve(st, tv)
	local t = types_mod.uvar(tv) --[[: V5Type ]]
	return subst_mod.walk(st.subst, t)
end

--: (OpSemState) -> integer
function M.error_count(st) return #st.errors end

return M
