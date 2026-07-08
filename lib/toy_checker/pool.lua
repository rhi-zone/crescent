if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

-- toy_checker.pool — the saturation worklist. Producers are registered by
-- (judgment, mode-signature) key, never by a hardcoded if/elseif on judgment
-- name inside the loop; the loop only ever does a table lookup. See
-- init.lua for the design rationale. Instantiate's scheme position is the
-- only statically-declared blocking position; Sub handles its own deferral
-- dynamically via the "deferred" verdict (see sub_producer in producers.lua).
--
-- CLP-style bound accumulation: uvars carry lower_bounds and upper_bounds
-- arrays. When Sub encounters a uvar operand, it records the known side as
-- a bound (lower or upper) via add_lower_bound / add_upper_bound rather
-- than collapsing to Unify. Cross-checks (new bound vs all opposite-side
-- bounds) are submitted as Sub obligations. When a ground lower bound
-- arrives, _try_resolve auto-resolves the uvar; Unify-triggered binds
-- verify accumulated bounds against the target.

local ir = require("lib.toy_checker.ir")
--:: require "lib.toy_checker.ir"

local Pool = {}
Pool.__index = Pool

--:: ProducerFn = (Obligation, PoolObj) -> (string, string | integer | nil)
--:: ProducerEntry = { fn: ProducerFn, blocking: { [integer]: integer } }
--:: RunResult = { verdict: "proved" } | { verdict: "refuted", message: string, obligation: Obligation, trail: { [integer]: string } } | { verdict: "stuck", message: string, obligations: { [integer]: Obligation } }
--:: UvarType = { kind: "uvar", id: integer, bound: Type | nil, lower_bounds: Type[], upper_bounds: Type[] }
--:: Pending = UvarType | { kind: "scheme_cell", id: integer, bound: Scheme | nil }
--:: PoolObj = { queue: { [integer]: Obligation }, obligations: { [integer]: Obligation }, producers: { [string]: ProducerEntry }, waiters: { [integer]: { [integer]: Obligation } }, next_id: integer, register: (PoolObj, string, ProducerFn, { [integer]: integer } | nil) -> nil, submit: (PoolObj, string, { [integer]: ObligationArg }, integer | nil, string | nil, Env | nil) -> integer, bind: (PoolObj, UvarType, Type, integer | nil) -> nil, resolve: (PoolObj, SchemeCell, Scheme) -> nil, add_lower_bound: (PoolObj, UvarType, Type, integer | nil) -> nil, add_upper_bound: (PoolObj, UvarType, Type, integer | nil) -> nil, _try_resolve: (PoolObj, UvarType) -> nil, _wake: (PoolObj, integer) -> nil, _ready: (PoolObj, Obligation) -> (boolean, ObligationArg | nil), trail: (PoolObj, Obligation) -> { [integer]: string }, run: (PoolObj) -> RunResult }

--: (ObligationArg) -> boolean
local function is_pending(v)
	return (v.kind == "uvar" or v.kind == "scheme_cell") and v.bound == nil
end

--: () -> PoolObj
function Pool.new()
	local self = setmetatable({
		queue = {},
		obligations = {},
		producers = {},
		waiters = {},
		next_id = 0,
	}, Pool)
	return self
end

--: (string, Modes) -> string
local function signature_key(judgment, modes)
	return judgment .. ":" .. table.concat(modes, ",")
end

-- Register a producer for a judgment. `blocking` (optional) lists 1-based
-- argument indices (must be "in" positions) that must already be resolved
-- (non-pending) before the pool will run this producer; positions not
-- listed are handed to the producer however pending they are, and the
-- producer is expected to cope (typically: bind eagerly, see Unify/Sub).
--: (PoolObj, string, ProducerFn, { [integer]: integer } | nil) -> nil
function Pool:register(judgment, producer_fn, blocking)
	local modes = ir.JUDGMENT_MODES[judgment]
	if not modes then error("toy_checker: unknown judgment '" .. judgment .. "'", 2) end
	self.producers[signature_key(judgment, modes)] = { fn = producer_fn, blocking = blocking or {} }
end

-- Enqueue a new obligation. `env` is the ambient typing context for
-- Infer/Check only (see init.lua OWNER-CALL on env threading) — every other
-- judgment ignores it.
--: (PoolObj, string, { [integer]: ObligationArg }, integer | nil, string | nil, Env | nil) -> integer
function Pool:submit(judgment, args, parent, desc, env)
	local modes = ir.JUDGMENT_MODES[judgment]
	if not modes then error("toy_checker: unknown judgment '" .. judgment .. "'", 2) end
	if #args ~= #modes then
		error("toy_checker: " .. judgment .. " expects " .. #modes .. " args, got " .. #args, 2)
	end
	self.next_id = self.next_id + 1
	local id = self.next_id
	local ob = { id = id, judgment = judgment, modes = modes, args = args, parent = parent, desc = desc or judgment, env = env }
	self.obligations[id] = ob
	self.queue[#self.queue + 1] = ob
	return id
end

-- Bind a uvar's value cell. When the uvar has accumulated bounds (from
-- CLP-style accumulate-mode Sub obligations), verify or transfer them:
--   - target is another uvar → transfer all bounds to the target (which
--     triggers cross-checks and may auto-resolve the target).
--   - target is a concrete/compound type → submit Sub obligations to verify
--     every accumulated bound against the target.
--: (PoolObj, UvarType, Type, integer | nil) -> nil
function Pool:bind(uvar, ty, parent_id)
	if uvar.bound then return end -- already resolved, skip
	local target = ir.deref(ty) --[[: Type]]
	if target.kind == "uvar" and target.id == uvar.id then return end -- self-bind, noop
	if target.kind == "uvar" and not target.bound then
		-- Binding uvar to another uvar: transfer bounds to target.
		for _, lb in ipairs(uvar.lower_bounds) do
			self:add_lower_bound(target --[[: UvarType]], lb, parent_id)
		end
		for _, ub in ipairs(uvar.upper_bounds) do
			self:add_upper_bound(target --[[: UvarType]], ub, parent_id)
		end
	else
		-- Binding to a concrete/compound type: verify bounds hold.
		for _, lb in ipairs(uvar.lower_bounds) do
			self:submit("Sub", { lb, target }, parent_id, "bind: verify lower bound")
		end
		for _, ub in ipairs(uvar.upper_bounds) do
			self:submit("Sub", { target, ub }, parent_id, "bind: verify upper bound")
		end
	end
	uvar.bound = ty
	self:_wake(uvar.id)
end

-- Resolve a scheme_cell's out-position value, waking anything deferred on it.
--: (PoolObj, SchemeCell, Scheme) -> nil
function Pool:resolve(cell, value)
	cell.bound = value
	self:_wake(cell.id)
end

-- ========================
-- CLP-style bound accumulation
-- ========================

-- Record `ty` as a lower bound on `uvar` (meaning ty <: uvar). Cross-check
-- the new bound against all existing upper bounds, then attempt resolution.
--: (PoolObj, UvarType, Type, integer | nil) -> nil
function Pool:add_lower_bound(uvar, ty, parent_id)
	local repr = ir.deref(uvar) --[[: Type]]
	if repr.kind ~= "uvar" then
		-- Already resolved — just verify the bound against the resolved value.
		self:submit("Sub", { ty, repr }, parent_id, "bound vs resolved var")
		return
	end
	repr.lower_bounds[#repr.lower_bounds + 1] = ty
	-- Cross-check: new lower bound must be <: every existing upper bound.
	for _, ub in ipairs(repr.upper_bounds) do
		self:submit("Sub", { ty, ub }, parent_id, "cross-check: new lower vs existing upper")
	end
	self:_try_resolve(repr --[[: UvarType]])
end

-- Record `ty` as an upper bound on `uvar` (meaning uvar <: ty). Cross-check
-- the new bound against all existing lower bounds, then attempt resolution.
--: (PoolObj, UvarType, Type, integer | nil) -> nil
function Pool:add_upper_bound(uvar, ty, parent_id)
	local repr = ir.deref(uvar) --[[: Type]]
	if repr.kind ~= "uvar" then
		-- Already resolved — just verify the resolved value against the bound.
		self:submit("Sub", { repr, ty }, parent_id, "resolved var vs bound")
		return
	end
	repr.upper_bounds[#repr.upper_bounds + 1] = ty
	-- Cross-check: every existing lower bound must be <: new upper bound.
	for _, lb in ipairs(repr.lower_bounds) do
		self:submit("Sub", { lb, ty }, parent_id, "cross-check: existing lower vs new upper")
	end
	self:_try_resolve(repr --[[: UvarType]])
end

-- OWNER-CALL D — resolution strategy for bounded uvars.
--
-- When to auto-resolve a uvar from its accumulated bounds? This toy resolves
-- to the first fully-ground lower bound. Upper bounds serve as consistency
-- checks only (verified via cross-check Sub obligations, not used to pick
-- the resolved type).
--
-- Alternatives not chosen:
--   - Resolve to the GLB/LUB of all bounds (requires lattice meet/join
--     machinery this toy doesn't have).
--   - Never auto-resolve; let only Unify bind uvars (breaks existing tests
--     where the uvar's only resolution path is through accumulated bounds
--     that chain via Unify — the ECS test needs auto-resolve so that a
--     uvar bound to another uvar with a transferred ground lower bound
--     actually resolves).
--   - Delay resolution until both a lower and upper bound exist (too
--     conservative — many uvars never get an upper bound).
--
-- Known limitation: if a non-ground lower bound (e.g. Store<?a>) later
-- becomes ground when its internal uvar resolves, _try_resolve is NOT
-- re-triggered on the outer uvar. Resolution from compound bounds only
-- works when the bound is already ground at the time it's recorded. The
-- typical resolution path for compound-typed uvars is through Unify (from
-- structural matching), not from bound accumulation alone.
--: (PoolObj, UvarType) -> nil
function Pool:_try_resolve(uvar)
	if uvar.bound then return end -- already resolved
	for _, lb in ipairs(uvar.lower_bounds) do
		if ir.is_ground(lb) then
			self:bind(uvar, lb)
			return
		end
	end
end

--: (PoolObj, integer) -> nil
function Pool:_wake(id)
	local w = self.waiters[id]
	if not w then return end
	self.waiters[id] = nil
	for _, ob in ipairs(w) do
		self.queue[#self.queue + 1] = ob
	end
end

--: (PoolObj, Obligation) -> (boolean, ObligationArg | nil)
function Pool:_ready(ob)
	local entry = self.producers[signature_key(ob.judgment, ob.modes)]
	if not entry then return true end -- surfaced as a hard error in run() below
	for _, idx in ipairs(entry.blocking) do
		local a = ob.args[idx]
		if a.kind == "uvar" or a.kind == "scheme_cell" then
			if is_pending(a --[[: Pending]]) then return false, a end
		end
	end
	return true
end

-- Provenance trail from `ob` up through its parents, root last.
--: (PoolObj, Obligation) -> { [integer]: string }
function Pool:trail(ob)
	local t = {}
	local cur = ob
	while cur do
		t[#t + 1] = cur.desc .. " (#" .. cur.id .. " " .. cur.judgment .. ")"
		cur = cur.parent and self.obligations[cur.parent] or nil
	end
	return t
end

-- Drain the worklist. Returns a result table:
--   { verdict = "proved" }
--   { verdict = "refuted", message = string, obligation = Obligation, trail = string[] }
--   { verdict = "stuck", message = string, obligations = Obligation[] }
-- "stuck" means the queue emptied but obligations are still waiting on
-- unification variables/schemes that nothing will ever resolve — a real,
-- distinct outcome from both success and refutation.
--: (PoolObj) -> RunResult
function Pool:run()
	while true do
		if #self.queue == 0 then
			if next(self.waiters) == nil then
				return { verdict = "proved" }
			end
			local stuck = {}
			for _, list in pairs(self.waiters) do
				for _, ob in ipairs(list) do stuck[#stuck + 1] = ob end
			end
			return {
				verdict = "stuck",
				message = "saturation stalled: " .. #stuck .. " obligation(s) waiting on a variable nothing will resolve",
				obligations = stuck,
			}
		end
		-- table.remove's return is stdlib-typed `unknown` regardless of the
		-- input array's element type; read the element via a plain indexed
		-- access (already `Obligation`-typed) instead, then discard-shift
		-- with table.remove — avoids ever needing a cast on the untyped
		-- return (see lib/automata/init.lua for the same `queue[1]` idiom).
		local maybe_ob = self.queue[1]
		if not maybe_ob then error("toy_checker: internal error — queue non-empty but head is nil", 2) end
		local ob = maybe_ob
		table.remove(self.queue, 1)
		local ready, blocker = self:_ready(ob)
		if not ready and blocker then
			local id = blocker.id
			self.waiters[id] = self.waiters[id] or {}
			table.insert(self.waiters[id], ob)
		else
			local entry = self.producers[signature_key(ob.judgment, ob.modes)]
			if not entry then
				error("toy_checker: no producer registered for " .. signature_key(ob.judgment, ob.modes), 2)
			end
			local verdict, message = entry.fn(ob, self)
			if verdict == "refuted" then
				return { verdict = "refuted", message = message or "refuted", obligation = ob, trail = self:trail(ob) }
			elseif verdict == "deferred" then
				-- Producer requests explicit deferral on a specific uvar id
				-- (returned as the second value). Used by Sub when both operands
				-- are unresolved uvars — see sub_producer in producers.lua.
				local defer_id = message --[[: integer]]
				self.waiters[defer_id] = self.waiters[defer_id] or {}
				table.insert(self.waiters[defer_id], ob)
			elseif verdict ~= "proved" then
				error("toy_checker: producer for " .. ob.judgment .. " returned invalid verdict '" .. verdict .. "'", 2)
			end
		end
	end
	error("toy_checker: unreachable — while true loop only exits via return", 2) --[[: RunResult]]
end

return Pool
