-- lib/type/experiments/v5_perf/solver.lua
-- Worklist + inert set + tvar-indexed wake-up + monotone substitution.
--
-- No cycle detection (v5 severe items 3,4,8 collapse): pop a constraint,
-- try to make progress; if progress, extend substitution and wake watchers;
-- else move to inert with watchers on its blocking tvars.  Quiescence =
-- worklist empty.  Inert at quiescence = stuck errors.
--
-- Reactivation count: every time a constraint moves from inert back to the
-- worklist, increment stats.reactivations.
--
-- Caps-first: dependencies injected via opts.  No globals.

local types_mod      = require("lib.type.experiments.v5_perf.types")
local subst_mod      = require("lib.type.experiments.v5_perf.subst")
local constraint_mod = require("lib.type.experiments.v5_perf.constraint")

local M = {}

--:: SolverError = { c: V5Constraint, msg: string }
--:: SolverStats = { emissions: integer, reactivations: integer, progress_steps: integer, inert_added: integer, popped: integer, errors: SolverError[] }
--:: Solver = { subst: Subst, worklist: V5Constraint[], worklist_n: integer, inert: { [integer]: V5Constraint }, stats: SolverStats }

--: () -> Solver
function M.new()
	return {
		subst = subst_mod.new(),
		worklist = {} --[[: V5Constraint[] ]],
		worklist_head = 1,
		worklist_n = 0,
		inert = {} --[[: { [integer]: V5Constraint } ]],
		stats = {
			emissions = 0,
			reactivations = 0,
			progress_steps = 0,
			inert_added = 0,
			popped = 0,
			errors = {} --[[: SolverError[] ]],
		},
	}
end

--: (Solver, V5Constraint) -> nil
function M.emit(s, c)
	s.stats.emissions = s.stats.emissions + 1
	local n = s.worklist_n + 1
	s.worklist[n] = c
	s.worklist_n = n
end

-- FIFO pop: causality-preserving (sets-before-seal in source order).
--: (Solver) -> V5Constraint | nil
local function pop(s)
	local h = s.worklist_head
	if h > s.worklist_n then
		-- Empty: reset head/tail to keep indices small.
		s.worklist_head = 1
		s.worklist_n = 0
		return nil
	end
	local c = s.worklist[h]
	s.worklist[h] = nil
	s.worklist_head = h + 1
	s.stats.popped = s.stats.popped + 1
	return c
end

-- Attach c to every blocking tvar.  When any of them is extended,
-- the constraint is reawakened.
--: (Solver, V5Constraint, { [integer]: boolean }) -> nil
local function add_inert(s, c, blockers)
	s.inert[c.id] = c
	s.stats.inert_added = s.stats.inert_added + 1
	for tv in pairs(blockers) do
		subst_mod.watch(s.subst, tv, c.id)
	end
end

-- When a tvar is extended, wake every constraint watching it.  Each
-- waked constraint moves back to the worklist; reactivations++.
--: (Solver, integer) -> nil
local function wake(s, tvar_id)
	local watchers = subst_mod.drain_watchers(s.subst, tvar_id)
	if watchers == nil then return end
	for cid in pairs(watchers) do
		local c = s.inert[cid]
		if c ~= nil then
			s.inert[cid] = nil
			local n = s.worklist_n + 1
			s.worklist[n] = c
			s.worklist_n = n
			s.stats.reactivations = s.stats.reactivations + 1
		end
	end
end

-- Try CEq(a, b).  Returns "done" | "stuck" | "emit"; if emit, new
-- constraints are pushed via M.emit.
--: (Solver, V5Constraint) -> string
local function step_eq(s, c)
	if c.tag ~= "ceq" and c.tag ~= "csub" then return "done" end
	-- c.tag in {"ceq","csub"}: both carry a, b : V5Type.
	local ca = c.a
	local cb = c.b
	if ca == nil or cb == nil then return "done" end
	local a = subst_mod.deref(s.subst, ca) --[[: V5Type ]]
	local b = subst_mod.deref(s.subst, cb) --[[: V5Type ]]
	if a.tag == "uvar" and b.tag == "uvar" then
		if a.id == b.id then return "done" end
		local _winner, loser = subst_mod.union(s.subst, a.id, b.id)
		if loser ~= nil then wake(s, loser) end
		return "done"
	end
	if a.tag == "uvar" then
		if subst_mod.bind(s.subst, a.id, b) then wake(s, a.id) end
		return "done"
	end
	if b.tag == "uvar" then
		if subst_mod.bind(s.subst, b.id, a) then wake(s, b.id) end
		return "done"
	end
	if a.tag ~= b.tag then
		s.stats.errors[#s.stats.errors + 1] = { c = c, msg = "kind mismatch" }
		return "done"
	end
	if a.tag == "const" and b.tag == "const" then
		if a.name ~= b.name then
			s.stats.errors[#s.stats.errors + 1] = { c = c, msg = "const mismatch" }
		end
		return "done"
	end
	if a.tag == "arrow" and b.tag == "arrow" then
		if #a.args ~= #b.args or #a.rets ~= #b.rets then
			s.stats.errors[#s.stats.errors + 1] = { c = c, msg = "arity mismatch" }
			return "done"
		end
		for i = 1, #a.args do
			local av = a.args[i]
			local bv = b.args[i]
			if av ~= nil and bv ~= nil then M.emit(s, constraint_mod.eq(av, bv, c.prov)) end
		end
		for i = 1, #a.rets do
			local av = a.rets[i]
			local bv = b.rets[i]
			if av ~= nil and bv ~= nil then M.emit(s, constraint_mod.eq(av, bv, c.prov)) end
		end
		return "emit"
	end
	if a.tag == "record" and b.tag == "record" then
		for k, va in pairs(a.fields) do
			local vb = b.fields[k]
			if vb == nil then
				s.stats.errors[#s.stats.errors + 1] = { c = c, msg = "missing field " .. k }
			elseif va ~= nil then
				M.emit(s, constraint_mod.eq(va, vb, c.prov))
			end
		end
		for k, _ in pairs(b.fields) do
			if a.fields[k] == nil then
				s.stats.errors[#s.stats.errors + 1] = { c = c, msg = "extra field " .. k }
			end
		end
		return "emit"
	end
	if a.tag == "app" and b.tag == "app" then
		M.emit(s, constraint_mod.eq(a.f, b.f, c.prov))
		M.emit(s, constraint_mod.eq(a.a, b.a, c.prov))
		return "emit"
	end
	return "done"
end

--: (Solver, V5Constraint) -> string
local function step_table_open(s, c)
	-- Mark tv as open (it already is by default).  Always done.
	return "done"
end

--: (Solver, V5Constraint) -> string
local function step_table_set(s, c)
	if c.tag ~= "tset" then return "done" end
	local r = subst_mod.find(s.subst, c.tv)
	local phase = subst_mod.phase(s.subst, r)
	if phase == "sealed" then
		local existing = subst_mod.binding(s.subst, r)
		if existing == nil then
			s.stats.errors[#s.stats.errors + 1] = { c = c, msg = "set on sealed unbound tv" }
			return "done"
		end
		if existing.tag == "record" then
			local fv = existing.fields[c.key]
			if fv == nil then
				s.stats.errors[#s.stats.errors + 1] = { c = c, msg = "sealed table missing field " .. c.key }
				return "done"
			end
			M.emit(s, constraint_mod.eq(fv, c.ty, c.prov))
			return "emit"
		end
		return "done"
	end
	-- Open: extend the record-binding incrementally.  If unbound, install
	-- an empty record.  Then add the field.
	local b = subst_mod.binding(s.subst, r)
	if b == nil then
		local rec = types_mod.record({ [c.key] = c.ty }) --[[: V5Type ]]
		subst_mod.bind(s.subst, r, rec)
		wake(s, r)
		return "done"
	end
	if b.tag == "record" then
		local existing = b.fields[c.key]
		if existing == nil then
			b.fields[c.key] = c.ty
			-- Field added: wake watchers since the row shape changed.
			wake(s, r)
			return "done"
		end
		M.emit(s, constraint_mod.eq(existing, c.ty, c.prov))
		return "emit"
	end
	s.stats.errors[#s.stats.errors + 1] = { c = c, msg = "set on non-record tv" }
	return "done"
end

--: (Solver, V5Constraint) -> string
local function step_table_seal(s, c)
	if c.tag ~= "tseal" then return "done" end
	subst_mod.seal(s.subst, c.tv)
	wake(s, c.tv)
	return "done"
end

--: (Solver, V5Constraint) -> string
local function step_method_call(s, c)
	if c.tag ~= "mcall" then return "done" end
	local r = subst_mod.find(s.subst, c.tv)
	local b = subst_mod.binding(s.subst, r)
	if b == nil then
		return "stuck"
	end
	if b.tag ~= "record" then
		s.stats.errors[#s.stats.errors + 1] = { c = c, msg = "method call on non-record" }
		return "done"
	end
	local m = b.fields[c.key]
	if m == nil then
		if subst_mod.phase(s.subst, r) == "sealed" then
			s.stats.errors[#s.stats.errors + 1] = { c = c, msg = "no method " .. c.key }
			return "done"
		end
		return "stuck"
	end
	if m.tag == "arrow" and #m.rets >= 1 then
		local r1 = m.rets[1]
		if r1 ~= nil then
			local lhs = types_mod.uvar(c.ret) --[[: V5Type ]]
			M.emit(s, constraint_mod.eq(lhs, r1, c.prov))
		end
		return "emit"
	end
	return "done"
end

-- Dispatch by tag.
--: (Solver, V5Constraint) -> string
local function step(s, c)
	local tg = c.tag
	if tg == "ceq" or tg == "csub" then return step_eq(s, c) end
	if tg == "topen" then return step_table_open(s, c) end
	if tg == "tset"  then return step_table_set(s, c) end
	if tg == "tseal" then return step_table_seal(s, c) end
	if tg == "mcall" then return step_method_call(s, c) end
	s.stats.errors[#s.stats.errors + 1] = { c = c, msg = "unknown tag " .. tostring(tg) }
	return "done"
end

-- Collect blocker tvar ids from a stuck constraint.
--: (V5Constraint, { [integer]: boolean }) -> nil
local function collect_blockers(c, acc)
	if c.tag == "ceq" or c.tag == "csub" then
		if c.a.tag == "uvar" then acc[c.a.id] = true end
		if c.b.tag == "uvar" then acc[c.b.id] = true end
	elseif c.tag == "tset" or c.tag == "tseal" or c.tag == "topen" or c.tag == "mcall" then
		acc[c.tv] = true
	end
end

-- Run to quiescence.  Stops when worklist is empty.  Inert constraints
-- remaining are reported as stuck errors via s.stats.errors.
--: (Solver) -> nil
function M.solve(s)
	while true do
		local c = pop(s)
		if c == nil then break end
		local r = step(s, c)
		s.stats.progress_steps = s.stats.progress_steps + 1
		if r == "stuck" then
			local blockers = {} --[[: { [integer]: boolean } ]]
			collect_blockers(c, blockers)
			if next(blockers) == nil then
				s.stats.errors[#s.stats.errors + 1] = { c = c, msg = "stuck no-blocker" }
			else
				add_inert(s, c, blockers)
			end
		end
	end
end

return M
