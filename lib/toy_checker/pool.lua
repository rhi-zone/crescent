if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

-- toy_checker.pool — the saturation worklist. Producers are registered by
-- (judgment, mode-signature) key, never by a hardcoded if/elseif on judgment
-- name inside the loop; the loop only ever does a table lookup. See
-- init.lua for why most "in" positions do NOT block scheduling here (only
-- Instantiate's scheme position and Sub's "actual" position do) — that's
-- a real finding, not an oversight, documented at the top of init.lua.

local ir = require("lib.toy_checker.ir")
--:: require "lib.toy_checker.ir"

local Pool = {}
Pool.__index = Pool

--:: ProducerFn = (Obligation, PoolObj) -> (string, string | nil)
--:: ProducerEntry = { fn: ProducerFn, blocking: { [integer]: integer } }
--:: RunResult = { verdict: "proved" } | { verdict: "refuted", message: string, obligation: Obligation, trail: { [integer]: string } } | { verdict: "stuck", message: string, obligations: { [integer]: Obligation } }
--:: UvarType = { kind: "uvar", id: integer, bound: Type | nil }
--:: Pending = UvarType | { kind: "scheme_cell", id: integer, bound: Scheme | nil }
--:: PoolObj = { queue: { [integer]: Obligation }, obligations: { [integer]: Obligation }, producers: { [string]: ProducerEntry }, waiters: { [integer]: { [integer]: Obligation } }, next_id: integer, register: (PoolObj, string, ProducerFn, { [integer]: integer } | nil) -> nil, submit: (PoolObj, string, { [integer]: ObligationArg }, integer | nil, string | nil, Env | nil) -> integer, bind: (PoolObj, UvarType, Type) -> nil, resolve: (PoolObj, SchemeCell, Scheme) -> nil, _wake: (PoolObj, integer) -> nil, _ready: (PoolObj, Obligation) -> (boolean, ObligationArg | nil), trail: (PoolObj, Obligation) -> { [integer]: string }, run: (PoolObj) -> RunResult }

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

-- Bind a uvar's out-position cell, waking anything deferred on it.
--: (PoolObj, UvarType, Type) -> nil
function Pool:bind(uvar, ty)
	uvar.bound = ty
	self:_wake(uvar.id)
end

-- Resolve a scheme_cell's out-position value, waking anything deferred on it.
--: (PoolObj, SchemeCell, Scheme) -> nil
function Pool:resolve(cell, value)
	cell.bound = value
	self:_wake(cell.id)
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
			elseif verdict ~= "proved" then
				error("toy_checker: producer for " .. ob.judgment .. " returned invalid verdict '" .. verdict .. "'", 2)
			end
		end
	end
	error("toy_checker: unreachable — while true loop only exits via return", 2) --[[: RunResult]]
end

return Pool
