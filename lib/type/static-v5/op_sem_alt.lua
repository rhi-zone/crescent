-- lib/type/static-v5/op_sem_alt.lua
-- v5.0 typechecker operational semantics — ALTERNATE INTERPRETER.
--
-- This module is an independently-written transcription of the inference
-- rules in `docs/typechecker-v5-operational-semantics.md`.  It exists to
-- give the parity test TWO independently-encoded interpreters: the existing
-- `op_sem.lua` and this one.  If they agree on every fixture, the rule
-- encoding is corroborated.  If they disagree, the divergence is logged
-- (see `docs/typechecker-v5-log.md`) and an orchestrator decides which
-- reading is correct.
--
-- Methodology constraint (per the task brief): this file was written
-- WITHOUT reading `op_sem.lua`.  It uses only the substrate modules
-- (`types.lua`, `subst.lua`, `constraint.lua`, `variance.lua`), the
-- inference rules in the spec doc, and the public state-shape /
-- constraint-tag set advertised by `op_sem.lua`'s headers (so the parity
-- test can compare apples to apples).
--
-- Same `M.run(state)` entry point as op_sem; the parity harness can call
-- either interchangeably.

local types_mod      = require("lib.type.experiments.v5_perf.types")
local subst_mod      = require("lib.type.experiments.v5_perf.subst")
local constraint_mod = require("lib.type.experiments.v5_perf.constraint")
local variance_mod   = require("lib.type.experiments.v5_perf.variance")

local _ = constraint_mod -- silence unused-import; aliases come via op_sem in caller

local M = {}

-- ────────────────────────────────────────────────────────────────────────────
-- State shape (mirrors op_sem.lua so the parity test can use either)
-- ────────────────────────────────────────────────────────────────────────────
--
-- We don't define new_state/emit/scheme/etc. here — the parity test
-- constructs state via op_sem.new_state() and emits via op_sem.emit(), and
-- our M.run consumes the same state.  This keeps the comparison surface
-- identical: only the SOLVER LOOP and RULE LOGIC differ.

--:: OpSemError    = { rule: string, msg: string }
--:: OpSemTrace    = { rule: string, msg: string }
--:: AltScheme     = { binders: integer, body: V5Type }
--:: AltCInst      = { id: integer, tag: "cinst", scheme: AltScheme, target: V5Type, prov: Provenance }
--:: AltCHKT       = { id: integer, tag: "chkt", f: V5Type, args: V5Type[], result: V5Type, prov: Provenance }
--:: AltHOUnify    = { id: integer, tag: "hounify", f: V5Type, args: V5Type[], result: V5Type, prov: Provenance }
--:: AltConstraint = V5Constraint | AltCInst | AltCHKT | AltHOUnify
--:: AltBounds     = { lower: { [integer]: V5Type[] }, upper: { [integer]: V5Type[] }, edge_up: { [integer]: { [integer]: boolean } }, edge_down: { [integer]: { [integer]: boolean } } }
--:: AltState      = { subst: Subst, worklist: AltConstraint[], head: integer, tail: integer, inert: { [integer]: AltConstraint }, errors: OpSemError[], trace: OpSemTrace[], reactivations: integer, steps: integer, row_watchers: { [integer]: { [integer]: boolean } }, bounds: AltBounds, subcache: { [string]: boolean }, sub_emits: integer }

-- ────────────────────────────────────────────────────────────────────────────
-- Small helpers
-- ────────────────────────────────────────────────────────────────────────────

--: (AltState, string, string) -> nil
local function record_error(st, rule, msg)
	st.errors[#st.errors + 1] = { rule = rule, msg = msg }
end

--: (AltState, AltConstraint) -> nil
local function emit(st, c)
	local n = st.tail + 1
	st.worklist[n] = c
	st.tail = n
end

-- Drain ordinary watchers for tv (called after a bind/seal/union).
--: (AltState, integer) -> nil
local function wake(st, tv)
	local w = subst_mod.drain_watchers(st.subst, tv)
	if w == nil then return end
	for cid in pairs(w) do
		local c = st.inert[cid]
		if c ~= nil then
			st.inert[cid] = nil
			emit(st, c)
			st.reactivations = st.reactivations + 1
		end
	end
end

-- Drain head-watchers ONLY if the new binding contributes a rigid head.
--: (AltState, integer) -> nil
local function wake_head(st, tv)
	if not subst_mod.head_is_rigid(st.subst, tv) then return end
	local w = subst_mod.drain_head_watchers(st.subst, tv)
	if w == nil then return end
	for cid in pairs(w) do
		local c = st.inert[cid]
		if c ~= nil then
			st.inert[cid] = nil
			emit(st, c)
			st.reactivations = st.reactivations + 1
		end
	end
end

-- Compose: bind a uvar, then run BOTH wakes.
--: (AltState, integer, V5Type) -> nil
local function bind_and_wake(st, id, ty)
	subst_mod.bind(st.subst, id, ty)
	wake(st, id)
	wake_head(st, id)
end

-- Free-uvar membership check for occurs.
--: (V5Type, integer) -> boolean
local function occurs(ty, id)
	local acc = {} --[[: { [integer]: boolean } ]]
	types_mod.collect_uvars(ty, acc)
	return acc[id] == true
end

-- Park a constraint in the inert set, watching ?t on `watch_kind`.
--: (AltState, AltConstraint, integer, string) -> nil
local function park(st, c, tv, watch_kind)
	st.inert[c.id] = c
	if watch_kind == "head" then
		subst_mod.watch_head(st.subst, tv, c.id)
	else
		subst_mod.watch(st.subst, tv, c.id)
	end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Spec A — atomic lattice (independent encoding)
-- ────────────────────────────────────────────────────────────────────────────
--
-- The single primitive-lattice relation, written against abstract predicates.
-- The concrete literal recognizer is confined to `widens_to` (the sole site
-- holding `$Lit*` knowledge); Spec C will swap that backing without touching
-- `atomic_sub`.

-- widens_to(a, name): atom `a` widens to the base atom `name`.  Spec C backing:
-- tag-dispatch on `a.tag == "literal"` reading `a.base` (NO `$`-name matching).
-- A literal widens to its base; an integer-based literal also widens to number.
-- The const arm carries the bare integer<:number lattice edge.
--: (V5Type, string) -> boolean
local function widens_to(a, name)
	if a.tag == "const" then
		if a.name == "integer" then return name == "number" end
		return false
	end
	if a.tag == "literal" then
		if a.base == name then return true end
		if a.base == "integer" and name == "number" then return true end
		return false
	end
	return false
end

-- A leaf the atomic lattice handles: a const or a literal (both base atoms).
-- Pure tag-dispatch (Spec C) — no `$`-name matching.
--: (V5Type) -> boolean
local function is_atom(t)
	return t.tag == "const" or t.tag == "literal"
end

-- atomic_sub(a, b): decidable base-lattice judgment.  bottom/top/refl/widen.
--: (V5Type, V5Type) -> boolean
local function atomic_sub(a, b)
	if a.tag == "const" and a.name == "never" then return true end
	if b.tag == "const" and b.name == "unknown" then return true end
	if types_mod.equal(a, b) then return true end
	if b.tag == "const" then
		local bn = b.name
		if bn ~= nil and widens_to(a, bn) then return true end
	end
	return false
end

M.atomic_subtype = atomic_sub

-- ────────────────────────────────────────────────────────────────────────────
-- Spec A — bound-graph B + termination cache C (independent encoding)
-- ────────────────────────────────────────────────────────────────────────────

-- Append `ty` to a per-root bound list (dedup modulo types.equal); true if new.
--: ({ [integer]: V5Type[] }, integer, V5Type) -> boolean
local function add_bound(map, root, ty)
	local xs = map[root]
	if xs == nil then xs = {} --[[: V5Type[] ]]; map[root] = xs end
	for i = 1, #xs do
		local v = xs[i]
		if v ~= nil and types_mod.equal(v, ty) then return false end
	end
	xs[#xs + 1] = ty
	return true
end

-- Structural head token of a type (after deref): tag, plus the union-find
-- root for a uvar leaf so root-sharing uvars collide and distinct roots don't.
--: (AltState, V5Type) -> string
local function head_token(st, t)
	local d = subst_mod.deref(st.subst, t) --[[: V5Type ]]
	if d.tag == "uvar" then return "v" .. tostring(subst_mod.find(st.subst, d.id)) end
	if d.tag == "const" then return "k:" .. d.name end
	-- Spec B: the pack head extends to ⟨"pack", #items, rest-id-or-nil⟩ plus the
	-- per-item heads; an arrow folds in its args + ret pack heads.
	if d.tag == "pack" then
		local s = types_mod.pack_head_key(d)
		for i = 1, #d.items do
			local it = d.items[i]
			if it ~= nil then s = s .. "|" .. head_token(st, it) end
		end
		return s
	end
	if d.tag == "arrow" then
		return "arrow[" .. head_token(st, d.args) .. "][" .. head_token(st, d.ret) .. "]"
	end
	return d.tag
end

-- Cache-guarded CSub re-emission.  Record the key first (so a cyclic graph
-- re-meeting its own key discharges as assumed); only then enqueue.
--: (AltState, V5Type, V5Type, Provenance) -> nil
local function reemit_sub(st, lo, up, prov)
	local key = head_token(st, lo) .. " <: " .. head_token(st, up)
	if st.subcache[key] then return end
	st.subcache[key] = true
	st.sub_emits = st.sub_emits + 1
	emit(st, constraint_mod.sub(lo, up, prov))
end

-- Propagation directions (standard simple-sub / MLstruct closure).  Edge α→β
-- (α <: β): an upper of β flows BACKWARD to α (α<:β<:U ⇒ α<:U); a lower of α
-- flows FORWARD to β (L<:α<:β ⇒ L<:β).  (The spec prose inverts these; we
-- implement the sound MLstruct direction it derives from — see handoff note.)
-- per-root dedup terminates the walk; the cache terminates the re-emission.
--: (AltState, integer, V5Type, Provenance) -> nil
local function push_upper(st, r, ty, prov)
	if not add_bound(st.bounds.upper, r, ty) then return end
	local los = st.bounds.lower[r]
	if los ~= nil then
		for i = 1, #los do local v = los[i]; if v ~= nil then reemit_sub(st, v, ty, prov) end end
	end
	-- Upper flows BACKWARD to predecessors (α where α → r).
	local pred = st.bounds.edge_down[r] --[[: { [integer]: boolean } | nil ]]
	if pred ~= nil then for p in pairs(pred) do local pr = p --[[: integer ]]; push_upper(st, pr, ty, prov) end end
end

--: (AltState, integer, V5Type, Provenance) -> nil
local function push_lower(st, r, ty, prov)
	if not add_bound(st.bounds.lower, r, ty) then return end
	local ups = st.bounds.upper[r]
	if ups ~= nil then
		for i = 1, #ups do local v = ups[i]; if v ~= nil then reemit_sub(st, ty, v, prov) end end
	end
	-- Lower flows FORWARD to successors (β where r → β).
	local succ = st.bounds.edge_up[r] --[[: { [integer]: boolean } | nil ]]
	if succ ~= nil then for s in pairs(succ) do local sr = s --[[: integer ]]; push_lower(st, sr, ty, prov) end end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Equality / unification rules
-- ────────────────────────────────────────────────────────────────────────────
--
-- Dispatch order per the doc:
--   1.  If both sides deref to UVar  -> T-CEq-UU (T-CEq-Refl is degenerate
--       and subsumed).
--   2.  If LHS UVar, RHS concrete    -> T-CEq-Bind-L (with occurs check
--       falling over to T-CEq-Occurs).
--   3.  Mirror of 2 with RHS UVar    -> T-CEq-Bind-R.
--   4.  Otherwise dispatch by matching tags.

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CEq_UU(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	-- Per spec: "If a = b: discharged with no change."
	if da.tag == "uvar" and db.tag == "uvar" then
		if da.id == db.id then return end
		local winner, loser = subst_mod.union(st.subst, da.id, db.id)
		if loser ~= nil then
			-- T-CEq-UU-Bounds: fold loser's bound sets + out-edges into winner,
			-- drop the now-self-loop edge, re-establish closure on cross-pairs.
			local B = st.bounds
			local loser_lo = {} --[[: V5Type[] ]]
			local fl = B.lower[loser]
			if fl ~= nil then for i = 1, #fl do loser_lo[i] = fl[i] end; B.lower[loser] = nil end
			local loser_up = {} --[[: V5Type[] ]]
			local fu = B.upper[loser]
			if fu ~= nil then for i = 1, #fu do loser_up[i] = fu[i] end; B.upper[loser] = nil end
			local el = B.edge_up[loser]
			if el ~= nil then
				local ew = B.edge_up[winner]
				if ew == nil then ew = {} --[[: { [integer]: boolean } ]]; B.edge_up[winner] = ew end
				for r in pairs(el) do
					ew[r] = true
					local rd = B.edge_down[r]
					if rd ~= nil then rd[loser] = nil; rd[winner] = true end
				end
				B.edge_up[loser] = nil
			end
			local ed = B.edge_down[loser]
			if ed ~= nil then
				local wd = B.edge_down[winner]
				if wd == nil then wd = {} --[[: { [integer]: boolean } ]]; B.edge_down[winner] = wd end
				for r in pairs(ed) do
					wd[r] = true
					local ru = B.edge_up[r]
					if ru ~= nil then ru[loser] = nil; ru[winner] = true end
				end
				B.edge_down[loser] = nil
			end
			local ew2 = B.edge_up[winner]
			if ew2 ~= nil then ew2[winner] = nil end
			local wd2 = B.edge_down[winner]
			if wd2 ~= nil then wd2[winner] = nil end
			for i = 1, #loser_lo do local v = loser_lo[i]; if v ~= nil then push_lower(st, winner, v, prov) end end
			for i = 1, #loser_up do local v = loser_up[i]; if v ~= nil then push_upper(st, winner, v, prov) end end
			wake(st, winner); wake_head(st, winner)
		end
	end
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CEq_Bind_L(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag ~= "uvar" then return end
	if db.tag == "uvar" then return end
	if occurs(db, da.id) then
		record_error(st, "T-CEq-Occurs", "occurs check failed")
		return
	end
	local root = subst_mod.find(st.subst, da.id)
	bind_and_wake(st, da.id, db)
	-- T-CEq-Bind-L-Bounds: verify accumulated lower/upper bounds against db.
	local B = st.bounds
	local los = B.lower[root]
	if los ~= nil then
		for i = 1, #los do local v = los[i]; if v ~= nil then reemit_sub(st, v, db, prov) end end
	end
	local ups = B.upper[root]
	if ups ~= nil then
		for i = 1, #ups do local v = ups[i]; if v ~= nil then reemit_sub(st, db, v, prov) end end
	end
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CEq_Bind_R(st, a, b, prov)
	M.rule_T_CEq_Bind_L(st, b, a, prov)
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CEq_Const(st, a, b, prov)
	local _ = prov
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag ~= "const" or db.tag ~= "const" then return end
	if da.name ~= db.name then
		record_error(st, "T-CEq-Const", "const mismatch " .. da.name .. " vs " .. db.name)
	end
end

-- T-CEq-Literal (Spec C).  Two literals are equal iff base AND value agree.
-- `base` distinguishes 1 (integer) from 1.0 (number) since Lua `1 == 1.0`.
-- A literal vs a non-literal head reaches T-CEq-Mismatch (tags differ): a literal
-- is only a SUBTYPE of its base, never equal to it.
--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CEq_Literal(st, a, b, prov)
	local _ = prov
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag ~= "literal" or db.tag ~= "literal" then return end
	if da.base ~= db.base then
		record_error(st, "T-CEq-Literal", "literal base mismatch " .. da.base .. " vs " .. db.base)
		return
	end
	if da.value ~= db.value then
		record_error(st, "T-CEq-Literal",
			"literal value mismatch " .. tostring(da.value) .. " vs " .. tostring(db.value))
	end
end

-- ── TPack substrate (Spec B), independently encoded ─────────────────────────
-- Pack-var bindings live in st.subst.pack_bindings (single-rest invariant).

-- Resolve a pack through the splice (deref_pack), returning items + rest.
--: (AltState, V5Type) -> V5Type
local function pack_resolve(st, p)
	return types_mod.deref_pack(p, st.subst.pack_bindings)
end

-- Bind a pack-var id to a pack.
--: (AltState, integer, V5Type) -> nil
local function pack_bind(st, id, p)
	st.subst.pack_bindings[id] = p
end

-- Build a closed pack of items[lo..hi] (inclusive, compacted).
--: (V5Type[], integer, integer) -> V5Type
local function slice_pack(items, lo, hi)
	local out = {} --[[: V5Type[] ]]
	for i = lo, hi do local v = items[i]; if v ~= nil then out[#out + 1] = v end end
	return types_mod.pack(out, nil)
end

-- T-CEq-Pack (Closed / OpenL / OpenR / OpenBoth).  Prefix aligned by min(n,m).
--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CEq_Pack(st, a, b, prov)
	local pa = pack_resolve(st, a) --[[: V5Type ]]
	local pb = pack_resolve(st, b) --[[: V5Type ]]
	if pa.tag ~= "pack" or pb.tag ~= "pack" then return end
	local n = #pa.items
	local m = #pb.items
	local lo = n
	if m < lo then lo = m end
	for i = 1, lo do
		local xa = pa.items[i]; local xb = pb.items[i]
		if xa ~= nil and xb ~= nil then emit(st, constraint_mod.eq(xa, xb, prov)) end
	end
	local ar = pa.rest
	local br = pb.rest
	-- Both closed.
	if ar == nil and br == nil then
		if n ~= m then record_error(st, "T-CEq-Pack-Closed", "pack arity mismatch") end
		return
	end
	-- LHS open, RHS closed.
	if ar ~= nil and br == nil then
		if m < n then record_error(st, "T-CEq-Pack-OpenL", "LHS demands more fixed positions"); return end
		pack_bind(st, ar.id, slice_pack(pb.items, n + 1, m))
		return
	end
	-- RHS open, LHS closed.
	if ar == nil and br ~= nil then
		if n < m then record_error(st, "T-CEq-Pack-OpenR", "RHS demands more fixed positions"); return end
		pack_bind(st, br.id, slice_pack(pa.items, m + 1, n))
		return
	end
	-- Both open: prefix-align by min, surplus prefix → shorter rest.
	if ar == nil or br == nil then return end
	if n == m then
		pack_bind(st, ar.id, types_mod.pack({}, br))
		return
	end
	if n > m then
		-- LHS longer: surplus pa[m+1..n] prepend to RHS rest; bind shorter (br).
		local surplus = {} --[[: V5Type[] ]]
		for i = m + 1, n do local v = pa.items[i]; if v ~= nil then surplus[#surplus + 1] = v end end
		pack_bind(st, br.id, types_mod.pack(surplus, ar))
		return
	end
	-- RHS longer.
	local surplus = {} --[[: V5Type[] ]]
	for i = n + 1, m do local v = pb.items[i]; if v ~= nil then surplus[#surplus + 1] = v end end
	pack_bind(st, ar.id, types_mod.pack(surplus, br))
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CEq_Arrow(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag ~= "arrow" or db.tag ~= "arrow" then return end
	emit(st, constraint_mod.eq(da.args, db.args, prov))
	emit(st, constraint_mod.eq(da.ret, db.ret, prov))
end

-- T-CEq-Record (Spec C, three-region).  Domains, per-field attributes, index
-- lists, and rows must all agree; field types and index key/value pairs are
-- equated.  Positional records are retired (TPack owns sequences) — no
-- positional branch.
--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CEq_Record(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag ~= "record" or db.tag ~= "record" then return end
	-- Domain agreement.
	for k, _v in pairs(da.fields) do
		if db.fields[k] == nil then
			record_error(st, "T-CEq-Record", "missing field " .. k)
			return
		end
	end
	for k, _v in pairs(db.fields) do
		if da.fields[k] == nil then
			record_error(st, "T-CEq-Record", "extra field " .. k)
			return
		end
	end
	-- Per-field attribute agreement, then equate types.
	for k, fa in pairs(da.fields) do
		local fb = db.fields[k]
		if fb ~= nil then
			if fa.optional ~= fb.optional or fa.readonly ~= fb.readonly then
				record_error(st, "T-CEq-Record", "field attribute mismatch: " .. k)
				return
			end
			emit(st, constraint_mod.eq(fa.type, fb.type, prov))
		end
	end
	-- Index lists: equal length, pairwise key+value equality (readonly agreement).
	if #da.indexes ~= #db.indexes then
		record_error(st, "T-CEq-Record", "index count mismatch: " .. #da.indexes .. " vs " .. #db.indexes)
		return
	end
	for i = 1, #da.indexes do
		local ia, ib = da.indexes[i], db.indexes[i]
		if ia ~= nil and ib ~= nil then
			if ia.readonly ~= ib.readonly then
				record_error(st, "T-CEq-Record", "index attribute mismatch")
				return
			end
			emit(st, constraint_mod.eq(ia.key, ib.key, prov))
			emit(st, constraint_mod.eq(ia.value, ib.value, prov))
		end
	end
	-- Row agreement: both nil, or both TRowVar with equal id.
	local ar, br = da.row, db.row
	if (ar == nil) ~= (br == nil) then
		record_error(st, "T-CEq-Record", "row disagreement (open vs closed)")
		return
	end
	if ar ~= nil and br ~= nil and ar.id ~= br.id then
		record_error(st, "T-CEq-Record", "row var id disagreement")
	end
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CEq_App(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag ~= "app" or db.tag ~= "app" then return end
	emit(st, constraint_mod.eq(da.f, db.f, prov))
	emit(st, constraint_mod.eq(da.a, db.a, prov))
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CEq_Mismatch(st, a, b, prov)
	local _ = prov
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag == "uvar" or db.tag == "uvar" then return end
	if da.tag == db.tag then return end
	record_error(st, "T-CEq-Mismatch", "kind mismatch " .. da.tag .. " vs " .. db.tag)
end

-- Top-level dispatch for CEq.  Encodes the rule-priority described in the
-- spec's prose.
--: (AltState, V5Type, V5Type, Provenance) -> nil
local function step_ceq(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag == "uvar" and db.tag == "uvar" then
		-- T-CEq-UU (covers Refl when a==b).
		M.rule_T_CEq_UU(st, da, db, prov)
		return
	end
	if da.tag == "uvar" then
		M.rule_T_CEq_Bind_L(st, da, db, prov); return
	end
	if db.tag == "uvar" then
		M.rule_T_CEq_Bind_R(st, da, db, prov); return
	end
	-- Both concrete; dispatch on tag pair.
	if da.tag ~= db.tag then
		M.rule_T_CEq_Mismatch(st, da, db, prov); return
	end
	if da.tag == "const" then M.rule_T_CEq_Const(st, da, db, prov); return end
	if da.tag == "literal" then M.rule_T_CEq_Literal(st, da, db, prov); return end
	if da.tag == "arrow" then M.rule_T_CEq_Arrow(st, da, db, prov); return end
	if da.tag == "pack" then M.rule_T_CEq_Pack(st, da, db, prov); return end
	if da.tag == "record" then M.rule_T_CEq_Record(st, da, db, prov); return end
	if da.tag == "app" then M.rule_T_CEq_App(st, da, db, prov); return end
	if da.tag == "lambda" then
		-- Spec doesn't explicitly list T-CEq-Lambda; structural equal-or-mismatch.
		if types_mod.equal(da, db) then return end
		record_error(st, "T-CEq-Mismatch", "lambda mismatch")
		return
	end
	if da.tag == "union" then
		if types_mod.equal(da, db) then return end
		record_error(st, "T-CEq-Mismatch", "union mismatch")
		return
	end
	if da.tag == "var" then
		if da.i == db.i then return end
		record_error(st, "T-CEq-Mismatch", "var mismatch")
		return
	end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Subtyping (variance-respecting) rules
-- ────────────────────────────────────────────────────────────────────────────

-- Walk a (possibly curried) application down to its head + ordered args.
-- Returns (head_after_deref, args_list).  For non-app input returns (t, {}).
--: (AltState, V5Type) -> (V5Type, V5Type[])
local function split_app(st, t)
	local args = {} --[[: V5Type[] ]]
	local cur = subst_mod.deref(st.subst, t) --[[: V5Type ]]
	while cur.tag == "app" do
		args[#args + 1] = cur.a
		cur = subst_mod.deref(st.subst, cur.f) --[[: V5Type ]]
	end
	-- args were collected outermost-first (a_n, a_{n-1}, …, a_1).  Reverse.
	local n = #args
	local out = {} --[[: V5Type[] ]]
	for i = 1, n do
		local v = args[n - i + 1]
		if v ~= nil then out[i] = v end
	end
	return cur, out
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CSub_Refl(st, a, b, prov)
	local _ = prov
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if types_mod.equal(da, db) then
		-- discharged
	end
end

-- T-CSub-TVar (Spec A simple-sub): three done-with-re-emission cases.  Never
-- parks; each maintains the bound-graph closure via cache-guarded re-emission.
--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CSub_TVar(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	local B = st.bounds
	-- Upper: α <: T.
	if da.tag == "uvar" and db.tag ~= "uvar" then
		local r = subst_mod.find(st.subst, da.id)
		push_upper(st, r, db, prov)
		return
	end
	-- Lower: T <: α.
	if db.tag == "uvar" and da.tag ~= "uvar" then
		local r = subst_mod.find(st.subst, db.id)
		push_lower(st, r, da, prov)
		return
	end
	-- Flow: α <: β (both uvars, distinct roots).
	if da.tag == "uvar" and db.tag == "uvar" then
		local ra = subst_mod.find(st.subst, da.id)
		local rb = subst_mod.find(st.subst, db.id)
		if ra == rb then return end  -- reflexive
		local ea = B.edge_up[ra]
		if ea == nil then ea = {} --[[: { [integer]: boolean } ]]; B.edge_up[ra] = ea end
		ea[rb] = true
		local ed = B.edge_down[rb]
		if ed == nil then ed = {} --[[: { [integer]: boolean } ]]; B.edge_down[rb] = ed end
		ed[ra] = true
		-- Flow α's lowers forward into β and β's uppers backward into α; the
		-- edge-aware push_* propagate transitively + re-emit cross obligations.
		local a_lo = B.lower[ra]
		if a_lo ~= nil then
			local snap = {} --[[: V5Type[] ]]
			for i = 1, #a_lo do snap[i] = a_lo[i] end
			for i = 1, #snap do local v = snap[i]; if v ~= nil then push_lower(st, rb, v, prov) end end
		end
		local b_up = B.upper[rb]
		if b_up ~= nil then
			local snap = {} --[[: V5Type[] ]]
			for i = 1, #b_up do snap[i] = b_up[i] end
			for i = 1, #snap do local v = snap[i]; if v ~= nil then push_upper(st, ra, v, prov) end end
		end
	end
end

-- T-CSub-Pack (Spec B): positional, length-polymorphic; variance `v` carried
-- from the arrow site ("co"|"contra").  Prefix aligned by min(n,m); surplus +
-- rests reconciled identically to T-CEq-Pack-OpenBoth (surplus → shorter rest).
-- v "co": Lua multi-return adjustment on closed ret packs (nil-pad short /
-- truncate long); v "contra": strict arity on closed arg packs.  Open packs are
-- length-polymorphic (open tail absorbs surplus).
--: (AltState, V5Type, V5Type, string, Provenance) -> nil
function M.rule_T_CSub_Pack(st, a, b, v, prov)
	local pa = pack_resolve(st, a) --[[: V5Type ]]
	local pb = pack_resolve(st, b) --[[: V5Type ]]
	if pa.tag ~= "pack" or pb.tag ~= "pack" then return end
	local n = #pa.items
	local m = #pb.items
	local ar = pa.rest
	local br = pb.rest
	-- Both closed.
	if ar == nil and br == nil then
		if v == "co" then
			-- Covariant ret: iterate supertype's m slots; pad missing sub slots
			-- with nil; truncate surplus sub slots beyond m.
			local nil_ty = types_mod.const("nil")
			for i = 1, m do
				local xa = pa.items[i] or nil_ty
				local xb = pb.items[i]
				if xb ~= nil then emit(st, constraint_mod.sub(xa, xb, prov)) end
			end
			return
		end
		-- Contravariant args: strict.
		for i = 1, n do
			local xa = pa.items[i]; local xb = pb.items[i]
			if xa ~= nil and xb ~= nil then emit(st, constraint_mod.sub(xb, xa, prov)) end
		end
		if n ~= m then record_error(st, "T-CSub-Pack", "pack arity mismatch") end
		return
	end
	-- Open cases: align shared prefix by min(n,m).
	local lo = n
	if m < lo then lo = m end
	for i = 1, lo do
		local xa = pa.items[i]; local xb = pb.items[i]
		if xa ~= nil and xb ~= nil then
			if v == "contra" then emit(st, constraint_mod.sub(xb, xa, prov))
			else emit(st, constraint_mod.sub(xa, xb, prov)) end
		end
	end
	if ar ~= nil and br == nil then
		if m < n then record_error(st, "T-CSub-Pack", "LHS open demands more fixed positions") end
		return
	end
	if ar == nil and br ~= nil then
		if n < m then record_error(st, "T-CSub-Pack", "RHS open demands more fixed positions"); return end
		pack_bind(st, br.id, slice_pack(pa.items, m + 1, n))
		return
	end
	if ar == nil or br == nil then return end
	if n == m then
		pack_bind(st, ar.id, types_mod.pack({}, br))
		return
	end
	if n > m then
		local surplus = {} --[[: V5Type[] ]]
		for i = m + 1, n do local x = pa.items[i]; if x ~= nil then surplus[#surplus + 1] = x end end
		pack_bind(st, br.id, types_mod.pack(surplus, ar))
		return
	end
	local surplus = {} --[[: V5Type[] ]]
	for i = n + 1, m do local x = pb.items[i]; if x ~= nil then surplus[#surplus + 1] = x end end
	pack_bind(st, ar.id, types_mod.pack(surplus, br))
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CSub_Arrow(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag ~= "arrow" or db.tag ~= "arrow" then return end
	-- args contravariant, ret covariant — via the pack rule.
	M.rule_T_CSub_Pack(st, da.args, db.args, "contra", prov)
	M.rule_T_CSub_Pack(st, da.ret, db.ret, "co", prov)
end

-- T-CSub-Atomic (Spec A): both sides atoms — decide via the single atomic_sub.
--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CSub_Atomic(st, a, b, prov)
	local _ = prov
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if atomic_sub(da, db) then return end
	if da.tag == "const" and db.tag == "const" then
		record_error(st, "T-CSub-Const-Var", "const sub mismatch " .. da.name .. " vs " .. db.name)
		return
	end
	record_error(st, "T-CSub-Atomic", "not a subtype " .. da.tag .. " vs " .. db.tag)
end

-- Retained name; const-vs-const now routes through the single atomic lattice.
--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CSub_Const_Var(st, a, b, prov)
	M.rule_T_CSub_Atomic(st, a, b, prov)
end

--: (AltState, V5Type, V5Type[], V5Type, V5Type[], string, Provenance) -> nil
local function emit_app_var_subgoals(st, _head_a, args_a, _head_b, args_b, name, prov)
	for i = 1, #args_a do
		local v = variance_mod.at(name, i)
		local xi = args_a[i]
		local yi = args_b[i]
		if v == "co" then
			emit(st, constraint_mod.sub(xi, yi, prov))
		elseif v == "contra" then
			emit(st, constraint_mod.sub(yi, xi, prov))
		else
			emit(st, constraint_mod.eq(xi, yi, prov))
		end
	end
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CSub_App_Var(st, a, b, prov)
	local ha, aa = split_app(st, a)
	local hb, bb = split_app(st, b)
	if ha.tag ~= "const" or hb.tag ~= "const" then return end
	if ha.name ~= hb.name then
		record_error(st, "T-CSub-Const-Var", "const head mismatch " .. ha.name .. " vs " .. hb.name)
		return
	end
	if #aa ~= #bb then
		record_error(st, "T-CSub-App-Var", "arity mismatch on " .. ha.name)
		return
	end
	emit_app_var_subgoals(st, ha, aa, hb, bb, ha.name, prov)
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CSub_App_Struct(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag ~= "app" or db.tag ~= "app" then return end
	emit(st, constraint_mod.eq(da.f, db.f, prov))
	emit(st, constraint_mod.eq(da.a, db.a, prov))
end

-- alt_field_subgoal: the ONE variance rule (Spec C), shared by named fields and
-- index sigs.  The SUPERTYPE modifier governs: readonly ⇒ covariant (CSub);
-- mutable (default) ⇒ invariant (CEq).
--: (AltState, V5Type, V5Type, boolean, Provenance) -> nil
local function alt_field_subgoal(st, sub_type, super_type, super_readonly, prov)
	if super_readonly then
		emit(st, constraint_mod.sub(sub_type, super_type, prov))   -- covariant
	else
		emit(st, constraint_mod.eq(sub_type, super_type, prov))    -- invariant
	end
end

-- T-CSub-Record (Spec C, three-region).  Width subtyping with the one variance
-- rule, optional-presence checks, and index-signature subtyping (keys
-- contravariant, values per the readonly/mutable rule).  No positional branch.
--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CSub_Record_Width(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag ~= "record" or db.tag ~= "record" then return end
	-- (1) Named-field obligations (per supertype field k).
	for k, fb in pairs(db.fields) do
		local fa = da.fields[k]
		if fa ~= nil then
			if fa.optional and not fb.optional then
				record_error(st, "T-CSub-Record-Width",
					"optional field cannot satisfy required field: " .. k)
			else
				alt_field_subgoal(st, fa.type, fb.type, fb.readonly, prov)
			end
		else
			if fb.optional then
				-- OK: supertype optional field may be absent.
			else
				-- Required field missing: covered by a string-keyed subtype index?
				local covered = false
				for j = 1, #da.indexes do
					local ix = da.indexes[j]
					if ix ~= nil and ix.key.tag == "const" and ix.key.name == "string" then
						alt_field_subgoal(st, ix.value, fb.type, fb.readonly, prov)
						covered = true
						break
					end
				end
				if not covered then
					record_error(st, "T-CSub-Record-Width", "supertype demands missing field " .. k)
				end
			end
		end
	end
	-- (2) Index-signature obligations (per supertype index).  Keys contravariant;
	-- values per readonly/mutable variance.
	for i = 1, #db.indexes do
		local ixb = db.indexes[i]
		if ixb ~= nil then
			local witnessed = false
			if ixb.key.tag == "const" and ixb.key.name == "string" then
				for _k, fa in pairs(da.fields) do
					alt_field_subgoal(st, fa.type, ixb.value, ixb.readonly, prov)
					witnessed = true
				end
			end
			for j = 1, #da.indexes do
				local ixa = da.indexes[j]
				if ixa ~= nil then
					emit(st, constraint_mod.sub(ixb.key, ixa.key, prov))  -- key contra
					alt_field_subgoal(st, ixa.value, ixb.value, ixb.readonly, prov)
					witnessed = true
				end
			end
			if not witnessed and da.row == nil then
				record_error(st, "T-CSub-Record-Width", "no witness for required index signature")
			end
		end
	end
	-- (3) Subtype-only fields forgotten (width); open supertype row absorbs surplus.
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CSub_Union_L(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a)
	if da.tag ~= "union" then return end
	for i = 1, #da.xs do
		local x = da.xs[i]
		if x ~= nil then emit(st, constraint_mod.sub(x, b, prov)) end
	end
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CSub_Union_R(st, a, b, prov)
	local _ = prov
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if db.tag ~= "union" then return end
	local wa = subst_mod.walk(st.subst, da) --[[: V5Type ]]
	for i = 1, #db.xs do
		local bi = db.xs[i]
		if bi ~= nil and types_mod.equal(wa, bi) then return end
	end
	record_error(st, "T-CSub-Union-R", "no exact union branch matches")
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CSub_Mismatch(st, a, b, prov)
	local _ = prov
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag == "uvar" or db.tag == "uvar" then return end
	if da.tag == db.tag then return end
	record_error(st, "T-CSub-Mismatch", "sub kind mismatch " .. da.tag .. " vs " .. db.tag)
end

-- Top-level dispatch for CSub.  Priority per the doc:
--   1.  Either side uvar  -> T-CSub-TVar (route to CEq).
--   2.  Structurally equal -> T-CSub-Refl.
--   3.  Both arrow         -> T-CSub-Arrow.
--   4.  Both record        -> T-CSub-Record-Width.
--   5.  Union LHS          -> T-CSub-Union-L.
--   6.  Union RHS          -> T-CSub-Union-R.
--   7.  Both apps (or one) with named-Const head -> T-CSub-App-Var.
--   8.  Both apps, non-Const head -> T-CSub-App-Struct.
--   9.  Both const         -> T-CSub-Const-Var.
--   10. Otherwise (tag mismatch) -> T-CSub-Mismatch.
--: (AltState, V5Type, V5Type, Provenance) -> nil
local function step_csub(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag == "uvar" or db.tag == "uvar" then
		M.rule_T_CSub_TVar(st, da, db, prov); return
	end
	if types_mod.equal(da, db) then
		M.rule_T_CSub_Refl(st, da, db, prov); return
	end
	-- T-CSub-Atomic (Spec A): bottom/top edges + both-atom lattice are one
	-- relation.  never<:anything and anything<:unknown hold regardless of the
	-- other side; otherwise both must be lattice atoms.
	local da_never = da.tag == "const" and da.name == "never"
	local db_unknown = db.tag == "const" and db.name == "unknown"
	if da_never or db_unknown or (is_atom(da) and is_atom(db)) then
		M.rule_T_CSub_Atomic(st, da, db, prov); return
	end
	-- Union dispatch before arrow/record because a union side dominates.
	if da.tag == "union" then M.rule_T_CSub_Union_L(st, da, db, prov); return end
	if db.tag == "union" then M.rule_T_CSub_Union_R(st, da, db, prov); return end
	-- Intersection dispatch (LHS decomp before RHS conj).
	if da.tag == "intersection" then
		M.rule_T_CSub_Intersection_Decomp(st, da.parts, db, prov); return
	end
	if db.tag == "intersection" then
		M.rule_T_CSub_Intersection_Conj(st, da, db.parts, prov); return
	end
	if da.tag == "arrow" and db.tag == "arrow" then
		M.rule_T_CSub_Arrow(st, da, db, prov); return
	end
	-- Bare pack CSub (defensive; packs normally arise inside arrows): covariant.
	if da.tag == "pack" and db.tag == "pack" then
		M.rule_T_CSub_Pack(st, da, db, "co", prov); return
	end
	if da.tag == "record" and db.tag == "record" then
		M.rule_T_CSub_Record_Width(st, da, db, prov); return
	end
	if da.tag == "app" and db.tag == "app" then
		local ha, _aa = split_app(st, da)
		local hb, _bb = split_app(st, db)
		if ha.tag == "const" and hb.tag == "const" then
			M.rule_T_CSub_App_Var(st, da, db, prov); return
		end
		M.rule_T_CSub_App_Struct(st, da, db, prov); return
	end
	if da.tag == "const" and db.tag == "const" then
		M.rule_T_CSub_Const_Var(st, da, db, prov); return
	end
	M.rule_T_CSub_Mismatch(st, da, db, prov)
end

-- ────────────────────────────────────────────────────────────────────────────
-- Intersection rules (Phase 4) — alt interpreter
-- ────────────────────────────────────────────────────────────────────────────
--
-- Effects are types (TConst with "!" prefix); uniform treatment under
-- intersection.  Both interpreters call constraint_mod.flatten_parts so
-- canonicalization is byte-for-byte identical.

--: (AltState, V5Type[], V5Type[], Provenance) -> string
function M.rule_T_CIntersectionEq_Canonical(st, parts_a, parts_b, prov)
	local ca = constraint_mod.flatten_parts(parts_a)
	local cb = constraint_mod.flatten_parts(parts_b)
	if #ca ~= #cb then
		record_error(st, "T-CIntersectionEq-Canonical",
			"intersection arity mismatch after canonicalization: " ..
			tostring(#ca) .. " vs " .. tostring(#cb))
		return "error"
	end
	for i = 1, #ca do
		local av, bv = ca[i], cb[i]
		if av ~= nil and bv ~= nil then
			emit(st, constraint_mod.eq(av, bv, prov))
		end
	end
	return "done"
end

--: (AltState, V5Type[], V5Type, Provenance) -> string
function M.rule_T_CSub_Intersection_Decomp(st, parts_lhs, rhs, prov)
	local canon = constraint_mod.flatten_parts(parts_lhs)
	for i = 1, #canon do
		local p = canon[i]
		if p ~= nil and types_mod.equal(p, rhs) then return "done" end
	end
	for i = 1, #canon do
		local p = canon[i]
		if p ~= nil and p.tag ~= "uvar" then
			emit(st, constraint_mod.sub(p, rhs, prov))
			return "done"
		end
	end
	record_error(st, "T-CSub-Intersection-Decomp",
		"all LHS intersection parts are uvars; no disjunctive scheduler in v5.0")
	return "error"
end

--: (AltState, V5Type, V5Type[], Provenance) -> string
function M.rule_T_CSub_Intersection_Conj(st, lhs, parts_rhs, prov)
	local canon = constraint_mod.flatten_parts(parts_rhs)
	for i = 1, #canon do
		local p = canon[i]
		if p ~= nil then emit(st, constraint_mod.sub(lhs, p, prov)) end
	end
	return "done"
end

--: (AltState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CIntersectionMember_Direct(st, ty, part, _prov)
	local dty = subst_mod.deref(st.subst, ty) --[[: V5Type ]]
	if dty.tag == "uvar" then return "stuck" end
	if dty.tag == "intersection" then
		local canon = constraint_mod.flatten_parts(dty.parts)
		for i = 1, #canon do
			local p = canon[i]
			if p ~= nil and types_mod.equal(p, part) then return "done" end
		end
		record_error(st, "T-CIntersectionMember-Direct", "part not in intersection")
		return "error"
	end
	if types_mod.equal(dty, part) then return "done" end
	record_error(st, "T-CIntersectionMember-Direct",
		"ty is neither intersection nor equal to part (tag=" .. dty.tag .. ")")
	return "error"
end

-- ────────────────────────────────────────────────────────────────────────────
-- Construction phase rules
-- ────────────────────────────────────────────────────────────────────────────

--: (AltState, integer, Provenance) -> nil
function M.rule_T_CTOpen(st, tv, prov)
	local _ = prov
	local cur = subst_mod.binding(st.subst, tv)
	if cur ~= nil then return end -- idempotent
	-- Phase preserved (already Open by default).
	bind_and_wake(st, tv, types_mod.record({} --[[: { [string]: TField } ]]))
end

--: (AltState, integer, string, V5Type, Provenance) -> nil
function M.rule_T_CTSet_Open_Fresh(st, tv, key, ty, prov)
	local _ = prov
	if subst_mod.binding(st.subst, tv) ~= nil then return end
	if subst_mod.phase(st.subst, tv) ~= "open" then return end
	local fields = {} --[[: { [string]: TField } ]]
	fields[key] = types_mod.field(ty, false, false)
	bind_and_wake(st, tv, types_mod.record(fields))
end

--: (AltState, integer, string, V5Type, Provenance) -> nil
function M.rule_T_CTSet_Open_Extend(st, tv, key, ty, prov)
	local _ = prov
	local cur = subst_mod.binding(st.subst, tv)
	if cur == nil or cur.tag ~= "record" then return end
	if subst_mod.phase(st.subst, tv) ~= "open" then return end
	if cur.fields[key] ~= nil then return end
	-- The binding is monotone (no overwrite); to extend we mutate the
	-- field table in place.  This matches the substrate's "single source
	-- of truth" guarantee — the bound record IS the row.
	cur.fields[key] = types_mod.field(ty, false, false)
	-- Field extension is an observable change to ?t; wake watchers.
	local r = subst_mod.find(st.subst, tv)
	wake(st, r)
	-- head_watchers don't fire here: the head tag is already "record".
end

--: (AltState, integer, string, V5Type, Provenance) -> nil
function M.rule_T_CTSet_Open_Equate(st, tv, key, ty, prov)
	local cur = subst_mod.binding(st.subst, tv)
	if cur == nil or cur.tag ~= "record" then return end
	if subst_mod.phase(st.subst, tv) ~= "open" then return end
	local existing = cur.fields[key]
	if existing == nil then return end
	emit(st, constraint_mod.eq(existing.type, ty, prov))
end

--: (AltState, integer, string, V5Type, Provenance) -> nil
function M.rule_T_CTSet_Sealed_Reject(st, tv, key, _ty, _prov)
	if subst_mod.phase(st.subst, tv) ~= "sealed" then return end
	record_error(st, "T-CTSet-Sealed-Reject", "set on sealed table key=" .. key)
end

-- Top-level dispatch for CTableSet — picks one of the four T-CTSet-* rules.
--: (AltState, integer, string, V5Type, Provenance) -> nil
local function step_tset(st, tv, key, ty, prov)
	if subst_mod.phase(st.subst, tv) == "sealed" then
		M.rule_T_CTSet_Sealed_Reject(st, tv, key, ty, prov); return
	end
	local cur = subst_mod.binding(st.subst, tv)
	if cur == nil then
		M.rule_T_CTSet_Open_Fresh(st, tv, key, ty, prov); return
	end
	if cur.tag == "record" then
		if cur.fields[key] == nil then
			M.rule_T_CTSet_Open_Extend(st, tv, key, ty, prov); return
		end
		M.rule_T_CTSet_Open_Equate(st, tv, key, ty, prov); return
	end
	-- ?t bound to a non-record under Open: degenerate; defer to a CEq.
	if cur == nil then return end
	local cur_nn = cur --[[: V5Type ]]
	local fields = {} --[[: { [string]: TField } ]]
	fields[key] = types_mod.field(ty, false, false)
	local rec = types_mod.record(fields) --[[: V5Type ]]
	emit(st, constraint_mod.eq(cur_nn, rec, prov))
end

--: (AltState, integer, integer | nil, Provenance) -> nil
function M.rule_T_CTSeal(st, tv, _mu, _prov)
	if subst_mod.phase(st.subst, tv) == "sealed" then return end
	subst_mod.seal(st.subst, tv)
	-- Phase flip is an observable change; wake.  head_watchers don't
	-- consult phase, only rigid binding head.
	local r = subst_mod.find(st.subst, tv)
	wake(st, r)
end

-- ────────────────────────────────────────────────────────────────────────────
-- CRow rules (row-polymorphic records) — alt interpreter
-- ────────────────────────────────────────────────────────────────────────────
--
-- Independent encoding of the same rules as op_sem.lua's CRow section.
-- Row vars live on TRecord.row (a TRowVar or nil = closed).

-- Deref record_ty through UVars; returns (record, is_stuck).
--: (AltState, V5Type) -> (V5Type | nil, boolean)
local function alt_deref_to_record(st, ty)
	local t = subst_mod.deref(st.subst, ty) --[[: V5Type ]]
	if t.tag == "uvar" then return nil, true end
	if t.tag == "record" then return t, false end
	return nil, false
end

-- Watch a constraint on a row-var id in the alt state's row_watchers map.
--: (AltState, integer, integer) -> nil
local function alt_watch_rowvar(st, rv_id, cid)
	local w = st.row_watchers[rv_id]
	if w == nil then w = {} --[[: { [integer]: boolean } ]]; st.row_watchers[rv_id] = w end
	w[cid] = true
end

-- Drain row-var watchers and re-queue them (called by CRowClose).
--: (AltState, integer) -> nil
local function alt_wake_rowvar(st, rv_id)
	local w = st.row_watchers[rv_id]
	if w == nil then return end
	st.row_watchers[rv_id] = nil
	for cid in pairs(w) do
		local c = st.inert[cid]
		if c ~= nil then
			st.inert[cid] = nil
			emit(st, c)
			st.reactivations = st.reactivations + 1
		end
	end
end

-- T-CRowExtend dispatch.
-- Returns "done", "stuck", or records an error and returns "error".
--: (AltState, V5Type, string, V5Type, Provenance) -> string
function M.rule_T_CRowExtend(st, record_ty, key, field_ty, prov)
	local rec, stuck = alt_deref_to_record(st, record_ty)
	if stuck then return "stuck" end
	if rec == nil then
		local tag = subst_mod.deref(st.subst, record_ty).tag
		record_error(st, "T-CRowExtend", "record_ty is not a record: tag=" .. tag)
		return "error"
	end
	if rec.row ~= nil then
		-- Open row.
		if rec.fields[key] ~= nil then
			-- Lookup: equate existing with field_ty.
			local existing = rec.fields[key] --[[: TField ]]
			emit(st, constraint_mod.eq(existing.type, field_ty, prov))
			return "done"
		end
		-- Bind: extend the record's field table.
		rec.fields[key] = types_mod.field(field_ty, false, false)
		return "done"
	end
	-- Closed row.
	if rec.fields[key] ~= nil then
		-- Key already present: equate.
		local existing = rec.fields[key] --[[: TField ]]
		emit(st, constraint_mod.eq(existing.type, field_ty, prov))
		return "done"
	end
	-- Closed and missing: error.
	record_error(st, "T-CRowExtend-Closed", "closed record cannot extend: key=" .. key)
	return "error"
end

-- T-CRowLacks dispatch.
--: (AltState, V5Type, string, Provenance) -> string
function M.rule_T_CRowLacks(st, record_ty, key, _prov)
	local rec, stuck = alt_deref_to_record(st, record_ty)
	if stuck then return "stuck" end
	if rec == nil then
		record_error(st, "T-CRowLacks", "record_ty is not a record")
		return "error"
	end
	if rec.row ~= nil then
		-- Open row: park.
		return "stuck"
	end
	-- Closed row.
	if rec.fields[key] ~= nil then
		record_error(st, "T-CRowLacks-Closed-Fail", "row already contains key: " .. key)
		return "error"
	end
	return "done"
end

-- T-CRowClose dispatch.
--: (AltState, V5Type, Provenance) -> string
function M.rule_T_CRowClose(st, record_ty, _prov)
	local rec, stuck = alt_deref_to_record(st, record_ty)
	if stuck then return "stuck" end
	if rec == nil then
		record_error(st, "T-CRowClose", "record_ty is not a record")
		return "error"
	end
	local rrow = rec.row
	if rrow == nil then
		-- Already closed.
		return "done"
	end
	local rv_id = rrow.id
	rec.row = nil
	-- Wake CRowLacks constraints parked on this row-var.
	alt_wake_rowvar(st, rv_id)
	return "done"
end

-- Alt park helper for CRow constraints.
--: (AltState, AltConstraint) -> nil
local function alt_park_crow(st, c)
	st.inert[c.id] = c
	if c.tag == "crow_lacks" then
		local cl = c --[[: ConstraintRowLacks ]]
		local rt = subst_mod.deref(st.subst, cl.record_ty)
		if rt.tag == "uvar" then
			subst_mod.watch(st.subst, rt.id, c.id)
		elseif rt.tag == "record" then
			local rrow = rt.row
			if rrow ~= nil then
				alt_watch_rowvar(st, rrow.id, c.id)
			end
		end
	elseif c.tag == "crow_extend" then
		local cr = c --[[: ConstraintRowExtend ]]
		local rt = subst_mod.deref(st.subst, cr.record_ty)
		if rt.tag == "uvar" then subst_mod.watch(st.subst, rt.id, c.id) end
	elseif c.tag == "crow_close" then
		local cc2 = c --[[: ConstraintRowClose ]]
		local rt = subst_mod.deref(st.subst, cc2.record_ty)
		if rt.tag == "uvar" then subst_mod.watch(st.subst, rt.id, c.id) end
	end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Method dispatch
-- ────────────────────────────────────────────────────────────────────────────

-- These return a "status" string so the parity test's explicit calls (e.g.
-- T.eq(stuck_status, "stuck", ...)) can introspect.
--: (AltState, integer, string, integer, Provenance) -> string
function M.rule_T_CMCall_Open_Stuck(st, tv, key, ret, prov)
	-- Park the constraint.  Use a constraint object for parking.
	if subst_mod.phase(st.subst, tv) ~= "open" then return "noop" end
	local c = constraint_mod.method_call(tv, key, ret, prov) --[[: AltConstraint ]]
	park(st, c, tv, "normal")
	return "stuck"
end

--: (AltState, integer, string, integer, Provenance) -> nil
function M.rule_T_CMCall_Sealed_Field(st, tv, key, ret, prov)
	if subst_mod.phase(st.subst, tv) ~= "sealed" then return end
	local cur = subst_mod.binding(st.subst, tv)
	if cur == nil or cur.tag ~= "record" then return end
	local f_opt = cur.fields[key]
	if f_opt == nil then return end
	local f = f_opt.type --[[: V5Type ]]
	if f.tag ~= "arrow" then
		-- Per spec: "F[k] = Arrow(_, [τ_ret, ...])".  Non-arrow field is
		-- not addressed by an explicit rule; treat as missing for v5.0.
		record_error(st, "T-CMCall-Sealed-Field", "field is not arrow: " .. key)
		return
	end
	-- ret is a pack; first return is items[1].  Arity-0 ret yields `never`.
	local first_ret = f.ret.items[1]
	local never_ty = types_mod.const("never") --[[: V5Type ]]
	local fr = first_ret or never_ty --[[: V5Type ]]
	local ur = types_mod.uvar(ret) --[[: V5Type ]]
	emit(st, constraint_mod.eq(ur, fr, prov))
end

--: (AltState, integer, string, integer, Provenance) -> nil
function M.rule_T_CMCall_Sealed_Missing(st, tv, key, _ret, _prov)
	if subst_mod.phase(st.subst, tv) ~= "sealed" then return end
	local cur = subst_mod.binding(st.subst, tv)
	if cur ~= nil and cur.tag == "record" and cur.fields[key] ~= nil then return end
	record_error(st, "T-CMCall-Sealed-Missing", "no method " .. key)
end

-- Top-level dispatch for CMethodCall.
--: (AltState, integer, string, integer, Provenance) -> string
local function step_mcall(st, tv, key, ret, prov)
	if subst_mod.phase(st.subst, tv) == "open" then
		return M.rule_T_CMCall_Open_Stuck(st, tv, key, ret, prov)
	end
	local cur = subst_mod.binding(st.subst, tv)
	if cur ~= nil and cur.tag == "record" and cur.fields[key] ~= nil then
		M.rule_T_CMCall_Sealed_Field(st, tv, key, ret, prov)
		return "done"
	end
	M.rule_T_CMCall_Sealed_Missing(st, tv, key, ret, prov)
	return "done"
end

-- ────────────────────────────────────────────────────────────────────────────
-- Instantiation (CInst)
-- ────────────────────────────────────────────────────────────────────────────

-- Iterated substitution of fresh uvars for De Bruijn vars Var(0..n-1).  The
-- substrate's `instantiate(body, arg, depth)` decrements outer indices by 1
-- on each call; per the spec doc § "β-reduction (auxiliary)" we iterate
-- `instantiate(body, fresh_i, 0)` with depth 0 every time.
--: (V5Type, V5Type[]) -> V5Type
local function iter_instantiate(body, args)
	local cur = body --[[: V5Type ]]
	for i = 1, #args do
		local a = args[i]
		if a ~= nil then
			local nxt = types_mod.instantiate(cur, a, 0) --[[: V5Type ]]
			cur = nxt
		end
	end
	return cur
end

--: (AltState, AltScheme, V5Type, Provenance) -> nil
function M.rule_T_CInst_Mono(st, sch, target, prov)
	if sch.binders ~= 0 then return end
	emit(st, constraint_mod.eq(sch.body, target, prov))
end

--: (AltState, AltScheme, V5Type, Provenance) -> nil
function M.rule_T_CInst(st, sch, target, prov)
	local args = {} --[[: V5Type[] ]]
	for i = 1, sch.binders do
		local id = subst_mod.fresh(st.subst, "open")
		local u = types_mod.uvar(id) --[[: V5Type ]]
		args[i] = u
	end
	local body = iter_instantiate(sch.body, args) --[[: V5Type ]]
	emit(st, constraint_mod.eq(body, target, prov))
end

-- ────────────────────────────────────────────────────────────────────────────
-- CHKT (HKT application) + HOUnify
-- ────────────────────────────────────────────────────────────────────────────

-- Miller pattern check (v5.0 restricted): each arg after deref is UVar or
-- Const; args pairwise distinct under types.equal; free uvars of T are a
-- subset of the uvar-arg ids; ?F not free in T.
--: (AltState, V5Type, V5Type[], V5Type) -> (boolean, V5Type[] | nil)
local function miller_check(st, f_deref, args, result)
	if f_deref.tag ~= "uvar" then return false, nil end
	local fid = f_deref.id
	local derefs = {} --[[: V5Type[] ]]
	for i = 1, #args do
		local ai = args[i]
		if ai == nil then return false, nil end
		local d = subst_mod.deref(st.subst, ai) --[[: V5Type ]]
		if d.tag ~= "uvar" and d.tag ~= "const" then return false, nil end
		derefs[i] = d
	end
	-- pairwise distinct
	for i = 1, #derefs do
		for j = i + 1, #derefs do
			local di = derefs[i]; local dj = derefs[j]
			if di ~= nil and dj ~= nil and types_mod.equal(di, dj) then return false, nil end
		end
	end
	-- Build allowed uvar-id set from uvar args.
	local allowed = {} --[[: { [integer]: boolean } ]]
	for i = 1, #derefs do
		local d = derefs[i]
		if d ~= nil and d.tag == "uvar" then allowed[d.id] = true end
	end
	-- T's free uvars (after walking) must be ⊆ allowed (and != ?F).
	local rw = subst_mod.walk(st.subst, result) --[[: V5Type ]]
	local fv = {} --[[: { [integer]: boolean } ]]
	types_mod.collect_uvars(rw, fv)
	if fv[fid] then return false, nil end
	for id, _v in pairs(fv) do
		if not allowed[id] then return false, nil end
	end
	return true, derefs
end

-- Build λ…λ. body' by abstracting UVar(aᵢ.id) -> Var(n - i) for uvar args.
-- For Const args, the pattern requires uniqueness, but Const args don't
-- abstract (they're rigid) — the spec restricts args to UVar/Const, and
-- only UVar args correspond to abstracted positions.  Const args at
-- pattern positions act like rigid type constants and the resulting
-- lambda still binds n positions; the body just doesn't reference them.
-- (This is the v5.0 simplification per the spec.)
--: (AltState, V5Type, V5Type[]) -> V5Type
local function abstract_body(st, t, derefs_args)
	local n = #derefs_args
	-- Walk t once with σ to make all uvar references current.
	local walked = subst_mod.walk(st.subst, t) --[[: V5Type ]]
	-- For each uvar arg at position i (1-indexed), substitute UVar(arg.id)
	-- with Var(n - i).  We do this by recursive structural rewrite.
	-- Build replacement map id -> Var(n - i).
	local repl = {} --[[: { [integer]: V5Type } ]]
	for i = 1, n do
		local d = derefs_args[i]
		if d ~= nil and d.tag == "uvar" then
			local v = types_mod.var(n - i) --[[: V5Type ]]
			repl[d.id] = v
		end
	end
	-- Forward-declared (mutually recursive with rewrite_pack).
	local rewrite
	-- rewrite over a TPack → TPack (so it populates arrow args/ret cleanly).
	--: (TPack) -> TPack
	local function rewrite_pack(p)
		local items = {} --[[: V5Type[] ]]
		for i = 1, #p.items do
			local v = p.items[i]
			if v ~= nil and rewrite ~= nil then local rv = rewrite(v) --[[: V5Type ]]; items[i] = rv end
		end
		return { tag = "pack", items = items, rest = p.rest }
	end
	--: (V5Type) -> V5Type
	rewrite = function(x)
		if x.tag == "uvar" then
			local r = repl[x.id]
			if r ~= nil then return r end
			return x
		elseif x.tag == "var" or x.tag == "const" then
			return x
		elseif x.tag == "app" then
			local rf = rewrite(x.f) --[[: V5Type ]]
			local ra = rewrite(x.a) --[[: V5Type ]]
			return types_mod.app(rf, ra)
		elseif x.tag == "lambda" then
			-- v5.0 spec gap: nested lambdas need shift-aware rewrite.
			-- For v5.0 minimal-core we leave the inner lambda body
			-- as-is (the body's De Bruijn vars refer to its own
			-- binder; rewriting our outer-level uvars inside it is
			-- still safe because uvars and De Bruijn vars don't mix).
			local rb = rewrite(x.b) --[[: V5Type ]]
			return types_mod.lambda(x.k, rb)
		elseif x.tag == "record" then
			local out = {} --[[: { [string]: TField } ]]
			for k, v in pairs(x.fields) do
				if v ~= nil then
					local rv = rewrite(v.type) --[[: V5Type ]]
					out[k] = { type = rv, optional = v.optional, readonly = v.readonly }
				end
			end
			local idxs = {} --[[: TIndex[] ]]
			for i = 1, #x.indexes do
				local ix = x.indexes[i]
				if ix ~= nil then
					idxs[i] = { key = rewrite(ix.key), value = rewrite(ix.value), readonly = ix.readonly }
				end
			end
			return types_mod.record_full(out, idxs, x.row)
		elseif x.tag == "pack" then
			return rewrite_pack(x)
		elseif x.tag == "arrow" then
			return { tag = "arrow", args = rewrite_pack(x.args), ret = rewrite_pack(x.ret) }
		elseif x.tag == "union" then
			local xs = {} --[[: V5Type[] ]]
			for i = 1, #x.xs do
				local v = x.xs[i]
				if v ~= nil then
					local rv = rewrite(v) --[[: V5Type ]]
					xs[i] = rv
				end
			end
			return types_mod.union(xs)
		end
		return x
	end
	local body = rewrite(walked) --[[: V5Type ]]
	-- Wrap in n lambdas.
	for _i = 1, n do
		local nb = types_mod.lambda("*", body) --[[: V5Type ]]
		body = nb
	end
	return body
end

-- Returns "ok" (bound) or "miss" (Miller doesn't apply).
--: (AltState, V5Type, V5Type[], V5Type, Provenance) -> string
function M.rule_T_CHKT_Miller(st, f, args, result, _prov)
	local df = subst_mod.deref(st.subst, f) --[[: V5Type ]]
	if df.tag ~= "uvar" then return "miss" end
	local ok, derefs = miller_check(st, df, args, result)
	if not ok or derefs == nil then return "miss" end
	local lam = abstract_body(st, result, derefs) --[[: V5Type ]]
	bind_and_wake(st, df.id, lam)
	return "ok"
end

--: (AltState, V5Type, V5Type[], V5Type, Provenance) -> nil
function M.rule_T_CHKT_Reduce(st, f, args, result, prov)
	local df = subst_mod.deref(st.subst, f) --[[: V5Type ]]
	if df.tag ~= "lambda" then return end
	-- Walk down through up to length(args) lambdas, peeling one per arg.
	local cur = df --[[: V5Type ]]
	local i = 1
	while i <= #args and cur.tag == "lambda" do
		local ai = args[i]
		if ai == nil then break end
		local nxt = types_mod.instantiate(cur.b, ai, 0) --[[: V5Type ]]
		cur = nxt
		i = i + 1
	end
	-- If we exited because we ran out of args while cur is still lambda,
	-- emit a CEq directly — this surfaces as a shape mismatch per the
	-- spec gap on kind inference.
	emit(st, constraint_mod.eq(cur, result, prov))
end

--: (AltState, V5Type, V5Type[], V5Type, Provenance) -> nil
function M.rule_T_CHKT_Rigid_Mismatch(st, f, args, _result, _prov)
	local _ = args
	local df = subst_mod.deref(st.subst, f) --[[: V5Type ]]
	if df.tag == "uvar" or df.tag == "lambda" then return end
	record_error(st, "T-CHKT-Rigid-Mismatch", "HKT app on non-constructor: " .. df.tag)
end

--: (AltState, V5Type, V5Type[], V5Type, Provenance) -> nil
function M.rule_T_CHKT_Park(st, f, args, result, prov)
	local df = subst_mod.deref(st.subst, f) --[[: V5Type ]]
	if df.tag ~= "uvar" then return end
	-- Emit a HOUnify residue and park on head-rigidity of ?F.
	local id = (function()
		_G._op_sem_alt_hounify_next = (_G._op_sem_alt_hounify_next or 200000) + 1
		return _G._op_sem_alt_hounify_next
	end)()
	local c = { id = id, tag = "hounify", f = df, args = args, result = result, prov = prov }
	st.inert[c.id] = c
	subst_mod.watch_head(st.subst, df.id, c.id)
end

--: (AltState, AltConstraint) -> nil
function M.rule_T_HOUnify_Wake(st, c)
	-- Re-emit as CHKT.
	if c.tag ~= "hounify" then return end
	local ck = { id = c.id, tag = "chkt", f = c.f, args = c.args, result = c.result, prov = c.prov } --[[: AltConstraint ]]
	emit(st, ck)
end

--: (AltState, AltConstraint) -> nil
function M.rule_T_HOUnify_Stuck(st, c)
	local _ = c
	record_error(st, "T-HOUnify-Stuck",
		"ambiguous constructor variable: head shape never rigidified")
end

-- Top-level dispatch for CHKT.
--: (AltState, V5Type, V5Type[], V5Type, Provenance) -> nil
local function step_chkt(st, f, args, result, prov)
	local df = subst_mod.deref(st.subst, f)
	if df.tag == "lambda" then
		M.rule_T_CHKT_Reduce(st, f, args, result, prov); return
	end
	if df.tag ~= "uvar" then
		M.rule_T_CHKT_Rigid_Mismatch(st, f, args, result, prov); return
	end
	-- ?F is unbound uvar.  Try Miller first.
	local status = M.rule_T_CHKT_Miller(st, f, args, result, prov)
	if status == "ok" then return end
	M.rule_T_CHKT_Park(st, f, args, result, prov)
end

-- ────────────────────────────────────────────────────────────────────────────
-- Spec B — match types (independent encoding)
-- ────────────────────────────────────────────────────────────────────────────
--
-- Independently transcribed from §"Pattern evaluation" + the v4 oracle
-- `lib/type/static/match.lua`.  Captures are pattern-local binder indices
-- (TCapture(idx)); discovery returns a `{ idx -> V5Type }` table and the arm
-- result is rewritten by replacing TCapture with its binding.  The literal leaf
-- defers to the atomic lattice (atomic_sub over real TLiteral) — no `$Lit` stub.

--:: AltGuard = { [string]: (boolean | nil) }
--:: AltBinds = { [integer]: V5Type }

-- A literal value widens to its base atom under the all-fields distribution.
--: (V5Type) -> V5Type
local function value_widen(t)
	if t.tag == "literal" then return types_mod.const(t.base) end
	return t
end

-- Combine two capture-binding tables; nil signals a conflicting binding (the
-- same idx forced to two non-equal types) which fails the arm.
--: (AltBinds | nil, AltBinds | nil) -> (AltBinds | nil)
local function combine_binds(x, y)
	if x == nil then return y end
	if y == nil then return x end
	local r = {} --[[: AltBinds ]]
	for i, v in pairs(x) do r[i] = v end
	for i, v in pairs(y) do
		local had = r[i]
		if had ~= nil and not types_mod.equal(had, v) then return nil end
		r[i] = v
	end
	return r
end

local rewrite_result
local rewrite_pack

-- rewrite_result(t, binds): produce a copy of `t` with each TCapture(idx)
-- replaced by binds[idx] (unbound captures pass through), splicing a pack-bound
-- capture that appears inside a pack.
--: (V5Type, AltBinds) -> V5Type
rewrite_result = function(t, binds)
	if t.tag == "capture" then
		local got = binds[t.idx] --[[: V5Type | nil ]]
		if got ~= nil then local g = got --[[: V5Type ]]; return g end
		return t
	elseif t.tag == "app" then
		return { tag = "app", f = rewrite_result(t.f, binds), a = rewrite_result(t.a, binds) }
	elseif t.tag == "arrow" then
		return { tag = "arrow", args = rewrite_pack(t.args, binds), ret = rewrite_pack(t.ret, binds) }
	elseif t.tag == "pack" then
		return rewrite_pack(t, binds)
	elseif t.tag == "record" then
		local fs = {} --[[: { [string]: TField } ]]
		for k, fv in pairs(t.fields) do
			if fv ~= nil then fs[k] = { type = rewrite_result(fv.type, binds), optional = fv.optional, readonly = fv.readonly } end
		end
		local ixs = {} --[[: TIndex[] ]]
		for i = 1, #t.indexes do
			local ix = t.indexes[i]
			if ix ~= nil then ixs[#ixs + 1] = { key = rewrite_result(ix.key, binds), value = rewrite_result(ix.value, binds), readonly = ix.readonly } end
		end
		return { tag = "record", fields = fs, indexes = ixs, row = t.row }
	elseif t.tag == "union" then
		local xs = {} --[[: V5Type[] ]]
		for i = 1, #t.xs do local v = t.xs[i]; if v ~= nil then xs[#xs + 1] = rewrite_result(v, binds) end end
		return { tag = "union", xs = xs }
	elseif t.tag == "intersection" then
		local ps = {} --[[: V5Type[] ]]
		for i = 1, #t.parts do local v = t.parts[i]; if v ~= nil then ps[#ps + 1] = rewrite_result(v, binds) end end
		return { tag = "intersection", parts = ps }
	end
	return t
end

-- rewrite_pack(p, binds): rewrite captures inside a pack; a capture bound to a
-- pack flattens (splices) into the positional items.
--: (TPack, AltBinds) -> TPack
rewrite_pack = function(p, binds)
	local items = {} --[[: V5Type[] ]]
	for i = 1, #p.items do
		local it = p.items[i]
		if it ~= nil then
			if it.tag == "capture" then
				local got = binds[it.idx] --[[: V5Type | nil ]]
				if got ~= nil and got.tag == "pack" then
					local gitems = got.items
					for j = 1, #gitems do local gj = gitems[j]; if gj ~= nil then items[#items + 1] = gj end end
				elseif got ~= nil then
					local g = got --[[: V5Type ]]; items[#items + 1] = g
				else
					items[#items + 1] = it
				end
			else
				items[#items + 1] = rewrite_result(it, binds)
			end
		end
	end
	return { tag = "pack", items = items, rest = p.rest }
end

local pat_match
local eval_match
local pat_match_pack
local pat_match_record_intersection

-- pat_match(st, ty, pat, guard): first-order pattern unification.  Returns
-- (fires, binds | nil).  `guard` is the coinductive cycle set keyed by
-- (derefed-ty identity, pattern identity).
--: (AltState, V5Type, V5Type, AltGuard) -> (boolean, AltBinds | nil)
pat_match = function(st, ty, pat, guard)
	local vty = subst_mod.deref(st.subst, ty) --[[: V5Type ]]
	local vpat = subst_mod.deref(st.subst, pat) --[[: V5Type ]]

	-- A capture pattern binds (idx >= 0) or is the `_` wildcard (idx < 0).
	if vpat.tag == "capture" then
		if vpat.idx < 0 then return true, {} end
		local r = {} --[[: AltBinds ]]
		r[vpat.idx] = vty
		return true, r
	end

	-- A match scrutinee is first evaluated, then re-matched.
	if vty.tag == "match" then
		local red = eval_match(st, vty.param, vty.arms, guard)
		return pat_match(st, red, vpat, guard)
	end

	-- Atom leaf: const / literal.  Widening + literal equality is the atomic
	-- lattice (atomic_sub), the same Spec A relation used by CSub — never stubbed.
	if is_atom(vpat) and (is_atom(vty) or (vty.tag == "const" and vty.name == "never")) then
		if atomic_sub(vty, vpat) then return true, {} end
		return false, nil
	end

	-- Arrow pattern: scrutinee must be an arrow; match the arg + ret packs.  An
	-- empty closed args pattern (`()` in `() -> %R`) is a param-count wildcard:
	-- it matches any args (v4 `() -> %R` matches any function).
	if vpat.tag == "arrow" then
		if vty.tag ~= "arrow" then return false, nil end
		local ba = {} --[[: AltBinds ]]
		local pa = pack_resolve(st, vpat.args) --[[: V5Type ]]
		local any_args = pa.tag == "pack" and #pa.items == 0 and pa.rest == nil
		if not any_args then
			local oka, sba = pat_match_pack(st, vty.args, vpat.args, guard)
			if not oka then return false, nil end
			ba = sba
		end
		local okr, br = pat_match_pack(st, vty.ret, vpat.ret, guard)
		if not okr then return false, nil end
		return true, combine_binds(ba, br)
	end

	-- Record pattern.
	if vpat.tag == "record" then
		if vty.tag == "intersection" then
			return pat_match_record_intersection(st, vty, vpat, guard)
		end
		if vty.tag ~= "record" then return false, nil end
		local gk = tostring(vty) .. "#" .. tostring(vpat)
		if guard[gk] then return true, {} end  -- coinductive: assume match
		guard[gk] = true
		local acc = {} --[[: AltBinds | nil ]]
		local seen_fields = {} --[[: { [string]: boolean } ]]
		local rest_binder = nil --[[: integer | nil ]]
		for fname, pfield in pairs(vpat.fields) do
			if pfield ~= nil then
				if fname == "..." then
					if pfield.type.tag == "capture" then rest_binder = pfield.type.idx end
				else
					local sfield = vty.fields[fname]
					if sfield == nil then guard[gk] = nil; return false, nil end
					local ok, sub = pat_match(st, sfield.type, pfield.type, guard)
					if not ok then guard[gk] = nil; return false, nil end
					acc = combine_binds(acc, sub)
					if acc == nil then guard[gk] = nil; return false, nil end
					seen_fields[fname] = true
				end
			end
		end
		-- Indexers: match in order.
		for i = 1, #vpat.indexes do
			local pix = vpat.indexes[i]
			local six = vty.indexes[i]
			if pix ~= nil then
				if six == nil then guard[gk] = nil; return false, nil end
				local okk, subk = pat_match(st, six.key, pix.key, guard)
				if not okk then guard[gk] = nil; return false, nil end
				acc = combine_binds(acc, subk)
				if acc == nil then guard[gk] = nil; return false, nil end
				local okv, subv = pat_match(st, six.value, pix.value, guard)
				if not okv then guard[gk] = nil; return false, nil end
				acc = combine_binds(acc, subv)
				if acc == nil then guard[gk] = nil; return false, nil end
			end
		end
		-- Rest capture: a closed record of the not-yet-matched fields.
		if rest_binder ~= nil then
			local rb = rest_binder --[[: integer ]]
			local leftover = {} --[[: { [string]: TField } ]]
			for fname, sfield in pairs(vty.fields) do
				if sfield ~= nil and not seen_fields[fname] then
					leftover[fname] = { type = sfield.type, optional = sfield.optional, readonly = sfield.readonly }
				end
			end
			local one = {} --[[: AltBinds ]]
			local recval = types_mod.record(leftover) --[[: V5Type ]]
			one[rb] = recval
			acc = combine_binds(acc, one)
			if acc == nil then guard[gk] = nil; return false, nil end
		end
		guard[gk] = nil
		return true, acc
	end

	-- App-spine pattern (effect extraction): match head-first; an intersection
	-- scrutinee uses intersection elimination (any member that matches fires).
	if vpat.tag == "app" then
		if vty.tag == "intersection" then
			for i = 1, #vty.parts do
				local m = vty.parts[i]
				if m ~= nil then
					local ok, sub = pat_match(st, m, vpat, guard)
					if ok then return true, sub or {} end
				end
			end
			return false, nil
		end
		if vty.tag ~= "app" then return false, nil end
		local okf, bf = pat_match(st, vty.f, vpat.f, guard)
		if not okf then return false, nil end
		local oka, ba = pat_match(st, vty.a, vpat.a, guard)
		if not oka then return false, nil end
		return true, combine_binds(bf, ba)
	end

	-- Intersection scrutinee against any remaining pattern: intersection
	-- elimination — fire if some member matches.
	if vty.tag == "intersection" then
		for i = 1, #vty.parts do
			local m = vty.parts[i]
			if m ~= nil then
				local ok, sub = pat_match(st, m, vpat, guard)
				if ok then return true, sub or {} end
			end
		end
		return false, nil
	end

	-- Otherwise: structural equality decides.
	if types_mod.equal(vty, vpat) then return true, {} end
	return false, nil
end

-- pat_match_pack(st, sp, pp, guard): match a scrutinee pack `sp` against a
-- pattern pack `pp`.  A pattern capture among the items acts as `(...%P)` /
-- `() -> %R`: a single trailing capture binds the remaining tail (or, alone,
-- the whole pack: arity-1 → single type, arity-n → a pack, arity-0 → never).
--: (AltState, V5Type, V5Type, AltGuard) -> (boolean, AltBinds | nil)
pat_match_pack = function(st, sp, pp, guard)
	local s = pack_resolve(st, sp) --[[: V5Type ]]
	local p = pack_resolve(st, pp) --[[: V5Type ]]
	if s.tag ~= "pack" or p.tag ~= "pack" then return false, nil end
	local sn = #s.items
	local pn = #p.items
	local acc = {} --[[: AltBinds | nil ]]

	if p.rest ~= nil then
		-- Open pattern pack: prefix matches, tail absorbed.
		if sn < pn then return false, nil end
		for i = 1, pn do
			local ok, sub = pat_match(st, s.items[i], p.items[i], guard)
			if not ok then return false, nil end
			acc = combine_binds(acc, sub)
			if acc == nil then return false, nil end
		end
		return true, acc
	end

	-- Closed pattern pack: look for a single capture position acting as `...%P`.
	local cap_at = nil --[[: integer | nil ]]
	for i = 1, pn do
		local it = p.items[i]
		if it ~= nil and it.tag == "capture" then cap_at = i; break end
	end
	if cap_at ~= nil then
		local before = cap_at - 1
		local after = pn - cap_at
		if sn < before + after then return false, nil end
		for i = 1, before do
			local ok, sub = pat_match(st, s.items[i], p.items[i], guard)
			if not ok then return false, nil end
			acc = combine_binds(acc, sub); if acc == nil then return false, nil end
		end
		for j = 0, after - 1 do
			local ok, sub = pat_match(st, s.items[sn - j], p.items[pn - j], guard)
			if not ok then return false, nil end
			acc = combine_binds(acc, sub); if acc == nil then return false, nil end
		end
		local cap = p.items[cap_at]
		if cap ~= nil and cap.idx >= 0 then
			-- Single capture as sole item over a 0/1/n scrutinee: () -> %R shape.
			local bound = types_mod.const("never") --[[: V5Type ]]
			local mid_count = sn - before - after
			if pn == 1 and before == 0 and after == 0 then
				if sn == 1 then local v = s.items[1]; if v ~= nil then bound = v end
				elseif sn > 1 then local bp = types_mod.pack(s.items, nil) --[[: V5Type ]]; bound = bp
				end
			else
				local mid = {} --[[: V5Type[] ]]
				for i = before + 1, before + mid_count do local v = s.items[i]; if v ~= nil then mid[#mid + 1] = v end end
				local bp2 = types_mod.pack(mid, nil) --[[: V5Type ]]; bound = bp2
			end
			local one = {} --[[: AltBinds ]]
			local cidx = cap.idx --[[: integer ]]
			one[cidx] = bound
			acc = combine_binds(acc, one); if acc == nil then return false, nil end
		end
		return true, acc
	end

	-- No capture: exact positional arity.
	if sn ~= pn then return false, nil end
	for i = 1, pn do
		local ok, sub = pat_match(st, s.items[i], p.items[i], guard)
		if not ok then return false, nil end
		acc = combine_binds(acc, sub); if acc == nil then return false, nil end
	end
	return true, acc
end

-- pat_match_record_intersection: field-merging structural match for an
-- intersection scrutinee — each pattern field is looked up in every record
-- member; a closed member missing it fails, an open member missing it is
-- neutral (skipped).
--: (AltState, V5Type, V5Type, AltGuard) -> (boolean, AltBinds | nil)
pat_match_record_intersection = function(st, vty, vpat, guard)
	-- internal: caller routes here only for intersection scrutinee + record pattern
	if vty.tag ~= "intersection" or vpat.tag ~= "record" then return false, nil end
	local members = vty.parts
	local pfields = vpat.fields
	local gk = tostring(vty) .. "#" .. tostring(vpat)
	if guard[gk] then return true, {} end
	guard[gk] = true
	local acc = {} --[[: AltBinds | nil ]]
	for fname, pfield in pairs(pfields) do
		if pfield ~= nil and fname ~= "..." then
			local found = nil --[[: V5Type | nil ]]
			local forbidden = false
			for i = 1, #members do
				local m = subst_mod.deref(st.subst, members[i]) --[[: V5Type ]]
				if m.tag == "record" then
					local mf = m.fields[fname]
					if mf ~= nil then found = mf.type
					elseif m.row == nil then forbidden = true end
				end
			end
			if forbidden then guard[gk] = nil; return false, nil end
			if found == nil then guard[gk] = nil; return false, nil end
			local fty = found --[[: V5Type ]]
			local ok, sub = pat_match(st, fty, pfield.type, guard)
			if not ok then guard[gk] = nil; return false, nil end
			acc = combine_binds(acc, sub)
			if acc == nil then guard[gk] = nil; return false, nil end
		end
	end
	guard[gk] = nil
	return true, acc
end

-- eval_match(st, param, arms, guard): evaluate `match param { arms }`.  A union
-- scrutinee distributes (union of per-member evaluations).  Each arm is tried
-- in order; an all-fields arm distributes per field.  Fallthrough → never.
--: (AltState, V5Type, TMatchArm[], AltGuard) -> V5Type
eval_match = function(st, param, arms, guard)
	local vp = subst_mod.deref(st.subst, param) --[[: V5Type ]]
	local never_t = types_mod.const("never") --[[: V5Type ]]

	-- Coinductive evaluation guard: re-entry on an in-progress (param, arms)
	-- node returns never.
	local ek = "eval#" .. tostring(vp) .. "#" .. tostring(arms)
	if guard[ek] then return never_t end
	guard[ek] = true

	if vp.tag == "union" then
		local rs = {} --[[: V5Type[] ]]
		for i = 1, #vp.xs do local m = vp.xs[i]; if m ~= nil then rs[#rs + 1] = eval_match(st, m, arms, guard) end end
		guard[ek] = nil
		if #rs == 0 then return never_t end
		if #rs == 1 then local r = rs[1]; if r ~= nil then return r end end
		return types_mod.union(rs)
	end

	for ai = 1, #arms do
		local arm = arms[ai]
		if arm ~= nil then
			local vpat = subst_mod.deref(st.subst, arm.pattern) --[[: V5Type ]]
			if vpat.tag == "patallfields" then
				local kidx = vpat.k
				local vidx = vpat.v
				local res = {} --[[: V5Type[] ]]
				local pairs_list = {} --[[: { key: V5Type, value: V5Type }[] ]]
				if vp.tag == "const" and vp.name == "never" then
					-- zero iterations
				elseif vp.tag == "const" and (vp.name == "unknown" or vp.name == "any") then
					pairs_list[#pairs_list + 1] = { key = types_mod.const("unknown"), value = types_mod.const("unknown") }
				elseif vp.tag == "record" then
					for fname, fv in pairs(vp.fields) do
						if fv ~= nil and fname ~= "..." then
							pairs_list[#pairs_list + 1] = { key = types_mod.literal("string", fname), value = value_widen(fv.type) }
						end
					end
					for i = 1, #vp.indexes do
						local ix = vp.indexes[i]
						if ix ~= nil then pairs_list[#pairs_list + 1] = { key = ix.key, value = ix.value } end
					end
				else
					pairs_list[#pairs_list + 1] = { key = types_mod.const("unknown"), value = types_mod.const("unknown") }
				end
				for pi = 1, #pairs_list do
					local kv = pairs_list[pi]
					if kv ~= nil then
						local b = {} --[[: AltBinds ]]
						b[kidx] = kv.key
						b[vidx] = kv.value
						res[#res + 1] = rewrite_result(arm.result, b)
					end
				end
				guard[ek] = nil
				if #res == 0 then return never_t end
				if #res == 1 then local r = res[1]; if r ~= nil then return r end end
				return types_mod.union(res)
			end
			local ok, binds = pat_match(st, vp, arm.pattern, guard)
			if ok then
				guard[ek] = nil
				if binds ~= nil and next(binds) ~= nil then
					return rewrite_result(arm.result, binds)
				end
				return arm.result
			end
		end
	end
	guard[ek] = nil
	return never_t
end

M.pat_match  = pat_match
M.eval_match = eval_match

-- T-CMatchEval-Reduce: scrutinee rigid — evaluate and assert CEq(R, result).
--: (AltState, V5Type, TMatchArm[], V5Type, Provenance) -> nil
function M.rule_T_CMatchEval_Reduce(st, param, arms, result, prov)
	local guard = {} --[[: AltGuard ]]
	local r = eval_match(st, param, arms, guard)
	emit(st, constraint_mod.eq(r, result, prov))
end

-- ────────────────────────────────────────────────────────────────────────────
-- Solver step (S-Step dispatcher)
-- ────────────────────────────────────────────────────────────────────────────

--: (AltState, AltConstraint) -> string
function M.step(st, c)
	st.steps = st.steps + 1
	if c.tag == "ceq" then
		step_ceq(st, c.a, c.b, c.prov)
	elseif c.tag == "csub" then
		step_csub(st, c.a, c.b, c.prov)
	elseif c.tag == "topen" then
		M.rule_T_CTOpen(st, c.tv, c.prov)
	elseif c.tag == "tset" then
		step_tset(st, c.tv, c.key, c.ty, c.prov)
	elseif c.tag == "tseal" then
		M.rule_T_CTSeal(st, c.tv, c.mu, c.prov)
	elseif c.tag == "mcall" then
		-- step_mcall handles parking internally (rule_T_CMCall_Open_Stuck calls park).
		step_mcall(st, c.tv, c.key, c.ret, c.prov)
	elseif c.tag == "cinst" then
		if c.scheme.binders == 0 then
			M.rule_T_CInst_Mono(st, c.scheme, c.target, c.prov)
		else
			M.rule_T_CInst(st, c.scheme, c.target, c.prov)
		end
	elseif c.tag == "chkt" then
		step_chkt(st, c.f, c.args, c.result, c.prov)
	elseif c.tag == "hounify" then
		-- Already in inert by spec; if seen on the worklist via wake,
		-- retry by treating as CHKT.
		M.rule_T_HOUnify_Wake(st, c)
	elseif c.tag == "crow_extend" then
		local status = M.rule_T_CRowExtend(st, c.record_ty, c.key, c.field_ty, c.prov)
		if status == "stuck" then return "stuck" end
	elseif c.tag == "crow_lacks" then
		local status = M.rule_T_CRowLacks(st, c.record_ty, c.key, c.prov)
		if status == "stuck" then return "stuck" end
	elseif c.tag == "crow_close" then
		local status = M.rule_T_CRowClose(st, c.record_ty, c.prov)
		if status == "stuck" then return "stuck" end
	elseif c.tag == "cint_eq" then
		M.rule_T_CIntersectionEq_Canonical(st, c.parts_a, c.parts_b, c.prov)
	elseif c.tag == "cint_sub" then
		local canon_super = constraint_mod.flatten_parts(c.parts_super)
		local lhs_ty = types_mod.intersection(constraint_mod.flatten_parts(c.parts_sub)) --[[: V5Type ]]
		for i = 1, #canon_super do
			local p = canon_super[i]
			if p ~= nil then
				emit(st, constraint_mod.intersection_member(lhs_ty, p, c.prov))
			end
		end
	elseif c.tag == "cint_member" then
		local status = M.rule_T_CIntersectionMember_Direct(st, c.ty, c.part, c.prov)
		if status == "stuck" then return "stuck" end
	elseif c.tag == "cmatch" then
		-- T-CMatchEval-Park / -Reduce.  Park (stuck) on an unbound scrutinee head;
		-- reduce once it is rigid.
		local dp = subst_mod.deref(st.subst, c.param) --[[: V5Type ]]
		if dp.tag == "uvar" then return "stuck" end
		M.rule_T_CMatchEval_Reduce(st, c.param, c.arms, c.result, c.prov)
	end
	return "done"
end

-- ────────────────────────────────────────────────────────────────────────────
-- Coalescing-time simplifier (independent encoding)
-- ────────────────────────────────────────────────────────────────────────────
--
-- struct_sub(a, b): cheap structural subtyping used ONLY at coalescing to drop
-- dominated bounds.  Atom case delegates to the single atomic_sub lattice;
-- record/arrow handled at depth.  Conservative false otherwise.
--: (V5Type, V5Type) -> boolean
local function struct_sub(a, b)
	if a.tag == "const" and a.name == "never" then return true end
	if b.tag == "const" and b.name == "unknown" then return true end
	if is_atom(a) and is_atom(b) then return atomic_sub(a, b) end
	if types_mod.equal(a, b) then return true end
	if a.tag == "record" and b.tag == "record" then
		if b.row ~= nil then return false end
		-- Index signatures present: punt (cheap path covers named-field width only).
		if #a.indexes ~= 0 or #b.indexes ~= 0 then return false end
		for k, bv in pairs(b.fields) do
			local av = a.fields[k]
			if av == nil then return false end
			-- readonly supertype ⇒ covariant; mutable ⇒ requires both directions.
			if not struct_sub(av.type, bv.type) then return false end
			if not bv.readonly and not struct_sub(bv.type, av.type) then return false end
		end
		return true
	end
	if a.tag == "arrow" and b.tag == "arrow" then
		local aa, ba = a.args, b.args
		local ar, br = a.ret, b.ret
		-- Conservative: only closed equal-arity packs decide cheaply; open punts.
		if aa.rest ~= nil or ba.rest ~= nil or ar.rest ~= nil or br.rest ~= nil then return false end
		if #aa.items ~= #ba.items then return false end
		if #ar.items ~= #br.items then return false end
		for i = 1, #aa.items do
			local ai = aa.items[i]; local bi = ba.items[i]
			if ai == nil or bi == nil then return false end
			if not struct_sub(bi, ai) then return false end  -- contravariant
		end
		for i = 1, #ar.items do
			local ai = ar.items[i]; local bi = br.items[i]
			if ai == nil or bi == nil then return false end
			if not struct_sub(ai, bi) then return false end  -- covariant
		end
		return true
	end
	return false
end

-- meet(xs): intersection with dominated (less-specific) parts dropped — a part
-- e_j is dropped iff some e_i <: e_j.  join(xs): the dual for unions — a part
-- e_i is dropped iff e_i <: some wider e_j.
--: (V5Type[], boolean) -> V5Type
local function reduce_bounds(xs, is_meet)
	local n = #xs
	local keep = {} --[[: boolean[] ]]
	for i = 1, n do keep[i] = true end
	for i = 1, n do
		if keep[i] then
			for j = 1, n do
				if i ~= j and keep[j] then
					local xi = xs[i]; local xj = xs[j]
					if xi ~= nil and xj ~= nil and struct_sub(xi, xj) then
						-- xi <: xj.  meet keeps the narrower (drop xj);
						-- join keeps the wider (drop xi).
						if is_meet then keep[j] = false else keep[i] = false end
					end
				end
			end
		end
	end
	local out = {} --[[: V5Type[] ]]
	for i = 1, n do
		if keep[i] then local v = xs[i]; if v ~= nil then out[#out + 1] = v end end
	end
	if #out == 1 then local r = out[1]; if r ~= nil then return r end end
	if is_meet then return types_mod.intersection(out) end
	return types_mod.union(out)
end

-- S-Quiesce polar coalescing: bind each unbound bounded root by polarity.
-- Uppers present → ⋂ uppers (consumed/negative face); else ⋃ lowers
-- (produced/positive face).  Simplifier drops dominated bounds here only.
--: (AltState) -> nil
local function coalesce(st)
	local B = st.bounds
	local roots = {} --[[: { [integer]: boolean } ]]
	for r in pairs(B.upper) do roots[r] = true end
	for r in pairs(B.lower) do roots[r] = true end
	for r in pairs(roots) do
		local root = subst_mod.find(st.subst, r)
		if subst_mod.binding(st.subst, root) == nil then
			local ups = B.upper[root]
			local los = B.lower[root]
			--: V5Type | nil
			local out = nil
			if ups ~= nil and #ups > 0 then
				out = reduce_bounds(ups, true)
			elseif los ~= nil and #los > 0 then
				out = reduce_bounds(los, false)
			end
			if out ~= nil then bind_and_wake(st, root, out) end
		end
	end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Solver loop (S-Step / S-Park / S-Wake / S-Quiesce)
-- ────────────────────────────────────────────────────────────────────────────

--: (AltState) -> nil
function M.run(st)
	while st.head <= st.tail do
		local c = st.worklist[st.head]
		st.worklist[st.head] = nil
		st.head = st.head + 1
		if c ~= nil then
			local status = M.step(st, c)
			-- Park CRow constraints that returned "stuck".
			if status == "stuck" and
			   (c.tag == "crow_extend" or c.tag == "crow_lacks" or c.tag == "crow_close") then
				alt_park_crow(st, c)
			end
			if status == "stuck" and c.tag == "cint_member" then
				st.inert[c.id] = c
				local cm = c --[[: ConstraintIntMember ]]
				local dty = subst_mod.deref(st.subst, cm.ty)
				if dty.tag == "uvar" then
					subst_mod.watch(st.subst, dty.id, c.id)
				end
			end
			if status == "stuck" and c.tag == "cmatch" then
				-- T-CMatchEval-Park: park on the head-watcher of the scrutinee uvar.
				st.inert[c.id] = c
				local cmm = c --[[: ConstraintMatchEval ]]
				local dpm = subst_mod.deref(st.subst, cmm.param)
				if dpm.tag == "uvar" then subst_mod.watch_head(st.subst, dpm.id, c.id) end
			end
		end
	end
	-- S-Quiesce polar coalescing (Spec A): materialize bounded unbound roots,
	-- then drain anything the resulting binds woke (cache C bounds the work).
	coalesce(st)
	while st.head <= st.tail do
		local cw = st.worklist[st.head]
		st.worklist[st.head] = nil
		st.head = st.head + 1
		if cw ~= nil then
			local status = M.step(st, cw)
			if status == "stuck" and
			   (cw.tag == "crow_extend" or cw.tag == "crow_lacks" or cw.tag == "crow_close") then
				alt_park_crow(st, cw)
			end
			if status == "stuck" and cw.tag == "cint_member" then
				st.inert[cw.id] = cw
			end
			if status == "stuck" and cw.tag == "cmatch" then
				st.inert[cw.id] = cw
				local cmm = cw --[[: ConstraintMatchEval ]]
				local dpm = subst_mod.deref(st.subst, cmm.param)
				if dpm.tag == "uvar" then subst_mod.watch_head(st.subst, dpm.id, cw.id) end
			end
		end
	end
	-- S-Quiesce: report any inert HOUnify as ambiguous; CRowLacks still parked
	-- at quiescence means row never closed — soundness floor violation.
	for _cid, c in pairs(st.inert) do
		if c.tag == "hounify" then
			M.rule_T_HOUnify_Stuck(st, c)
		elseif c.tag == "crow_lacks" then
			local ckey = c.key or "?"
			record_error(st, "S-Quiesce-CRowLacks",
				"CRowLacks still unresolved at quiescence (row never closed): key=" .. ckey)
		elseif c.tag == "cint_member" then
			record_error(st, "S-Quiesce-CIntersectionMember",
				"CIntersectionMember stuck on unbound uvar (effect never inferred)")
		elseif c.tag == "cmatch" then
			-- T-CMatchEval-Stuck: scrutinee head never rigidified.  (Match-splitting
			-- at sealed bounds — doc gap #1 — is deferred; this conservative stuck
			-- error is the disposition, NOT a partial split.)
			record_error(st, "T-CMatchEval-Stuck",
				"match scrutinee never rigidified: cannot decide which arm fires")
		end
	end
end

--: (AltState, integer) -> V5Type
function M.resolve(st, tv)
	local u = types_mod.uvar(tv) --[[: V5Type ]]
	return subst_mod.walk(st.subst, u)
end

--: (AltState) -> integer
function M.error_count(st) return #st.errors end

M.variance = variance_mod

return M
