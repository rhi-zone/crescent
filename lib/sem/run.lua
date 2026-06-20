-- lib/sem/run.lua
-- Iterate the small-step relation to a value tuple, a fault, or step-budget
-- exhaustion; produce a canonical observation of the outcome.
--
-- This is the driver that makes step.lua's relation usable as an oracle: it
-- repeatedly applies `step` until the machine reaches a terminal control
-- (final-values, fault, or budget). The budget bounds nontermination — an
-- unbounded loop in the input program becomes a "budget" observation rather
-- than a hang, which Loop-α treats as admissible (the spec declines to commit).

--:: require "lib.sem.value"
--:: require "lib.sem.config"
--:: require "lib.sem.step"

local config = require("lib.sem.config")
local step_mod = require("lib.sem.step")

local M = {}

--:: Profile = { name: string, va: ValueAlgebra }

-- The outcome of a run, before canonicalisation into an Observation.
--::   ROk     = { kind: "ok", values: Value[], store: Store }
--::   RFault  = { kind: "fault", fault: Fault, store: Store }
--::   RBudget = { kind: "budget", store: Store }
--:: RunResult = ROk | RFault | RBudget

-- Build the initial machine for a top-level program body (a Stmt list). The
-- top frame has empty slots/varargs; the kont is empty so a top-level RETURN (or
-- fall-off) lands in `final`.
--: (Stmt[]) -> Machine
function M.initial(body)
	local env = { slots = {}, varargs = {} } --[[: Env]]
	return {
		focus = { f = "exec", code = body, pc = 1 },
		env = env, kont = {}, fault = nil, final = nil,
	}
end

-- run: drive `step` until terminal or budget. `budget` bounds the number of
-- reductions (default 100000). Returns a RunResult.
--: (Profile, Stmt[], integer | nil) -> RunResult
function M.run(profile, body, budget)
	local store = config.new_store()
	local m = M.initial(body)
	local max = budget or 100000
	for _ = 1, max do
		local fault = m.fault
		if fault ~= nil then
			return { kind = "fault", fault = fault, store = store }
		end
		local final = m.final
		if final ~= nil then
			return { kind = "ok", values = final, store = store }
		end
		m = step_mod.step(profile, store, m)
	end
	-- one last check after the loop (the final/fault may have been set on the
	-- last iteration's step result).
	local fault = m.fault
	if fault ~= nil then
		return { kind = "fault", fault = fault, store = store }
	end
	local final = m.final
	if final ~= nil then
		return { kind = "ok", values = final, store = store }
	end
	return { kind = "budget", store = store }
end

return M
