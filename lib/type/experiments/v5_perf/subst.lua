-- lib/type/experiments/v5_perf/subst.lua
-- Substitution: TVarId -> (V5Type, Phase) with union-find + path compression.
--
-- Phase ::= "open" | "sealed".  Open tvars may still gain row fields;
-- sealed tvars are frozen.  Per-tvar phase is part of the binding (per
-- v5 severe item 1 closure).
--
-- Union-find: each tvar has a parent pointer.  Two tvars unify by pointing
-- one at the other.  Find walks to the root with path compression.  The
-- binding (V5Type, Phase) lives at the root.
--
-- Monotone: bindings never overwritten with a less-defined value; phases
-- only transition open -> sealed.  Single source of truth.

local types = require("lib.type.experiments.v5_perf.types")

local M = {}

M.OPEN   = "open"
M.SEALED = "sealed"

--:: Phase    = string
--:: WatchSet = { [integer]: boolean }
--:: Subst    = { parent: { [integer]: integer }, bind_type: { [integer]: V5Type }, bind_phase: { [integer]: Phase }, watchers: { [integer]: WatchSet }, head_watchers: { [integer]: WatchSet }, pack_bindings: { [integer]: V5Type }, next_id: integer }

-- pack_bindings: TPackVar id -> bound TPack (Spec B).  Stored on the
-- substitution exactly as the row-var bindings are; the pack CEq/CSub rules in
-- the op-sem bind it (single-rest invariant) and `types.deref_pack` splices it.

-- head_watchers: separate parked-map keyed by tvar id, holding constraint ids
-- that should be woken when the tvar's binding's HEAD (top-level constructor
-- tag) becomes rigid (i.e. non-uvar).  Distinct from `watchers`, which fires
-- when a tvar is bound at all (any binding, including uvar->uvar union).
-- HOUnify (head-rigidity dependent) uses head_watchers; CEq/CSub/CMethodCall
-- use watchers.  Per v5 severe item 4 closure: dynamic per-tvar phase, not
-- precomputed strata.
--: () -> Subst
function M.new()
	return {
		parent        = {} --[[: { [integer]: integer } ]],
		bind_type     = {} --[[: { [integer]: V5Type } ]],
		bind_phase    = {} --[[: { [integer]: Phase } ]],
		watchers      = {} --[[: { [integer]: WatchSet } ]],
		head_watchers = {} --[[: { [integer]: WatchSet } ]],
		pack_bindings = {} --[[: { [integer]: V5Type } ]],
		next_id       = 1,
	}
end

--: (Subst, Phase | nil) -> integer
function M.fresh(s, phase)
	local id = s.next_id
	s.next_id = id + 1
	s.parent[id] = id
	s.bind_phase[id] = phase or "open"
	return id
end

-- find with path compression. Returns root id.
--: (Subst, integer) -> integer
function M.find(s, id)
	local p = s.parent[id]
	if p == nil or p == id then return id end
	local r = M.find(s, p)
	if r ~= p then s.parent[id] = r end
	return r
end

-- Get binding (resolved V5Type or nil) at root.
--: (Subst, integer) -> V5Type | nil
function M.binding(s, id)
	return s.bind_type[M.find(s, id)]
end

--: (Subst, integer) -> Phase
function M.phase(s, id)
	local p = s.bind_phase[M.find(s, id)]
	if p == "sealed" then return "sealed" end
	return "open"
end

-- Bind a tvar to a V5Type. Returns true if a real extension occurred.
--: (Subst, integer, V5Type) -> boolean
function M.bind(s, id, ty)
	local r = M.find(s, id)
	if s.bind_type[r] ~= nil then return false end
	s.bind_type[r] = ty
	return true
end

--: (Subst, integer) -> nil
function M.seal(s, id)
	local r = M.find(s, id)
	s.bind_phase[r] = "sealed"
end

-- Unify two tvar roots (smaller-id wins for determinism).
-- Returns winner id, and loser id (or nil if same root).
--: (Subst, integer, integer) -> (integer, integer | nil)
function M.union(s, a, b)
	local ra, rb = M.find(s, a), M.find(s, b)
	if ra == rb then return ra, nil end
	local winner, loser = ra, rb
	if rb < ra then winner, loser = rb, ra end
	s.parent[loser] = winner
	-- Migrate watchers from loser onto winner.
	local lw = s.watchers[loser]
	if lw ~= nil then
		local ww = s.watchers[winner]
		if ww == nil then
			s.watchers[winner] = lw
		else
			for cid in pairs(lw) do ww[cid] = true end
		end
		s.watchers[loser] = nil
	end
	-- Migrate head-watchers from loser onto winner.
	local lhw = s.head_watchers[loser]
	if lhw ~= nil then
		local whw = s.head_watchers[winner]
		if whw == nil then
			s.head_watchers[winner] = lhw
		else
			for cid in pairs(lhw) do whw[cid] = true end
		end
		s.head_watchers[loser] = nil
	end
	-- Phase: sealed dominates open.
	if s.bind_phase[loser] == "sealed" then s.bind_phase[winner] = "sealed" end
	s.bind_phase[loser] = nil
	-- Binding: if loser had a binding and winner doesn't, transfer.
	local lb = s.bind_type[loser]
	if lb ~= nil and s.bind_type[winner] == nil then
		s.bind_type[winner] = lb
	end
	s.bind_type[loser] = nil
	return winner, loser
end

-- Add a constraint id to the watch list of tvar id.
--: (Subst, integer, integer) -> nil
function M.watch(s, tvar_id, cid)
	local r = M.find(s, tvar_id)
	local w = s.watchers[r]
	if w == nil then w = {} --[[: WatchSet ]]; s.watchers[r] = w end
	w[cid] = true
end

-- Drain the watch list for tvar id (called on extension). Returns the
-- table of cids to wake; caller is responsible for re-watching if the
-- constraint stays inert.
--: (Subst, integer) -> WatchSet | nil
function M.drain_watchers(s, tvar_id)
	local r = M.find(s, tvar_id)
	local w = s.watchers[r]
	s.watchers[r] = nil
	return w
end

-- Add a constraint id to the HEAD-watch list of tvar id.  These fire only
-- when the tvar's binding's TOP-LEVEL TAG becomes a non-uvar (i.e. the
-- head constructor is rigid).  Used by HOUnify to wait for ?F's head shape.
--: (Subst, integer, integer) -> nil
function M.watch_head(s, tvar_id, cid)
	local r = M.find(s, tvar_id)
	local w = s.head_watchers[r]
	if w == nil then w = {} --[[: WatchSet ]]; s.head_watchers[r] = w end
	w[cid] = true
end

-- Drain head-watchers for tvar id.  Caller decides (based on the new
-- binding's tag) whether to actually wake; this helper is shape-agnostic.
--: (Subst, integer) -> WatchSet | nil
function M.drain_head_watchers(s, tvar_id)
	local r = M.find(s, tvar_id)
	local w = s.head_watchers[r]
	s.head_watchers[r] = nil
	return w
end

-- Returns true if the tvar's current binding has a rigid head
-- (non-uvar top-level tag, after deref).  Used by the head-rigidity wake.
--: (Subst, integer) -> boolean
function M.head_is_rigid(s, tvar_id)
	local r = M.find(s, tvar_id)
	local b = s.bind_type[r]
	if b == nil then return false end
	-- Deref nested uvar bindings (single step is enough because bind
	-- chains are flattened through union-find).
	local cur = b
	while cur.tag == "uvar" do
		local rr = M.find(s, cur.id)
		local bb = s.bind_type[rr]
		if bb == nil then return false end
		cur = bb
	end
	return true
end

-- walk_pack(s, p): splice p's bound `rest` TPackVars through pack_bindings
-- (flattening their items), then walk each resolved item.  Returns a TPack.
-- Mirrors types.deref_pack but recurses M.walk into items for reporting.
--: (Subst, TPack) -> TPack
function M.walk_pack(s, p)
	-- Splice the rest chain first (collect raw items in order).
	local raw = {} --[[: V5Type[] ]]
	for i = 1, #p.items do
		local v = p.items[i]
		if v ~= nil then raw[#raw + 1] = v end
	end
	--: TPackVar | nil
	local rest = p.rest
	local seen = {} --[[: { [integer]: boolean } ]]
	local pb = s.pack_bindings
	while rest ~= nil do
		local bnd_opt = pb[rest.id] --[[: V5Type | nil ]]
		if bnd_opt == nil then break end
		if seen[rest.id] then break end
		seen[rest.id] = true
		local bnd = bnd_opt --[[: V5Type ]]
		if bnd.tag ~= "pack" then break end
		for i = 1, #bnd.items do
			local v = bnd.items[i]
			if v ~= nil then raw[#raw + 1] = v end
		end
		rest = bnd.rest
	end
	-- Walk each spliced item.
	local items = {} --[[: V5Type[] ]]
	for i = 1, #raw do
		local v = raw[i]
		if v ~= nil then local sh = M.walk(s, v) --[[: V5Type ]]; items[i] = sh end
	end
	return { tag = "pack", items = items, rest = rest }
end

-- Walk: replace every UVar in t with its current binding (recursively).
-- Used only at quiescence / for reporting. Allocates fresh nodes.
--: (Subst, V5Type) -> V5Type
function M.walk(s, t)
	if t.tag == "uvar" then
		local r = M.find(s, t.id)
		local b = s.bind_type[r]
		if b == nil then
			if r == t.id then return t end
			return { tag = "uvar", id = r }
		end
		return M.walk(s, b)
	elseif t.tag == "rowvar" or t.tag == "packvar" then
		-- Row / pack variables are not in the uvar substitution map; return as-is.
		return t
	elseif t.tag == "app" then
		local sf = M.walk(s, t.f) --[[: V5Type ]]
		local sa = M.walk(s, t.a) --[[: V5Type ]]
		return { tag = "app", f = sf, a = sa }
	elseif t.tag == "lambda" then
		local sb = M.walk(s, t.b) --[[: V5Type ]]
		return { tag = "lambda", k = t.k, b = sb }
	elseif t.tag == "record" then
		-- Three-region: walk each field's `.type` (attrs copied) and each index's
		-- key/value; `row` is a TRowVar, returned as-is.
		local out = {} --[[: { [string]: TField } ]]
		for fk, fv in pairs(t.fields) do
			if fv ~= nil then
				local sh = M.walk(s, fv.type) --[[: V5Type ]]
				out[fk] = { type = sh, optional = fv.optional, readonly = fv.readonly }
			end
		end
		local idxs = {} --[[: TIndex[] ]]
		for i = 1, #t.indexes do
			local ix = t.indexes[i]
			if ix ~= nil then
				idxs[i] = { key = M.walk(s, ix.key), value = M.walk(s, ix.value), readonly = ix.readonly }
			end
		end
		return { tag = "record", fields = out, indexes = idxs, row = t.row }
	elseif t.tag == "pack" then
		return M.walk_pack(s, t)
	elseif t.tag == "arrow" then
		return { tag = "arrow", args = M.walk_pack(s, t.args), ret = M.walk_pack(s, t.ret) }
	elseif t.tag == "union" then
		local xs = {} --[[: V5Type[] ]]
		for i = 1, #t.xs do
			local v = t.xs[i]
			if v ~= nil then local sh = M.walk(s, v) --[[: V5Type ]]; xs[i] = sh end
		end
		return { tag = "union", xs = xs }
	elseif t.tag == "intersection" then
		local parts = {} --[[: V5Type[] ]]
		for i = 1, #t.parts do
			local v = t.parts[i]
			if v ~= nil then local sh = M.walk(s, v) --[[: V5Type ]]; parts[i] = sh end
		end
		return { tag = "intersection", parts = parts }
	elseif t.tag == "match" then
		-- Spec B: walk the scrutinee and each arm's pattern/result for reporting.
		-- Captures are leaves returned as-is by the fallthrough.
		local arms = {} --[[: TMatchArm[] ]]
		for i = 1, #t.arms do
			local arm = t.arms[i]
			if arm ~= nil then
				arms[i] = { pattern = M.walk(s, arm.pattern), result = M.walk(s, arm.result) }
			end
		end
		return { tag = "match", param = M.walk(s, t.param), arms = arms }
	end
	return t
end

-- Shallow walk: resolve a single UVar one step (no recursion into children).
-- Hot-path: used in solver progress checks.
--: (Subst, V5Type) -> V5Type
function M.deref(s, t)
	local cur = t
	while cur.tag == "uvar" do
		local r = M.find(s, cur.id)
		local b = s.bind_type[r]
		if b == nil then
			if r == cur.id then return cur end
			return { tag = "uvar", id = r }
		end
		cur = b
	end
	return cur
end

return M
