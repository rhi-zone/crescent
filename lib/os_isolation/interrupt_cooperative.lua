-- lib/os_isolation/interrupt_cooperative.lua
-- Interrupt mechanism C: opt-in cooperative loop-instrumentation.
--
-- NOT a universal or default mechanism -- a mandatory version was rejected
-- in docs/genre-battery/sandboxing.md on overhead grounds (a hard
-- per-iteration cost ceiling makes it untenable for tiny loops that run
-- millions of times). This module exists for callers who explicitly opt in
-- and accept that per-iteration cost. Unlike lib/sandbox.run's
-- debug.sethook budget (confirmed non-viable as a security boundary once a
-- loop gets JIT-traced -- see sandboxing.md "Rejected: debug.sethook
-- count-hook budgets"), a checker call the author writes INLINE in their
-- own loop body is ordinary Lua code, not a VM hook -- it cannot be skipped
-- by tracing, because the trace has to include it to be correct. That is
-- also exactly why it is not a universal defense against a HOSTILE script:
-- an adversarial author simply omits the call. It is a real bound only for
-- a cooperative one.
--
-- API:
--   interrupt_cooperative.new(opts) -> checker
--     opts.budget         : integer | nil -- instruction-count-ish budget;
--                            checker:tick() counts calls to itself, not
--                            real VM instructions (see note below).
--     opts.deadline        : number | nil -- an absolute deadline in the
--                            same units opts.clock returns.
--     opts.clock            : (() -> number) | nil -- required if
--                            opts.deadline is set. Injected, not read from
--                            a global (os.clock) by default -- caps-first:
--                            this library does not reach for a global time
--                            source on the caller's behalf.
--     At least one of opts.budget / opts.deadline must be set.
--   checker:tick() -> nil
--     Call once per loop iteration. Raises (error(), not (nil, errmsg) --
--     this is meant to be caught the same way lib.sandbox.run's budget
--     errors are, by the pcall already wrapping the loop) once the budget
--     or deadline is exceeded.
--   checker:remaining() -> integer | nil
--     Iterations left before the instruction-ish budget fires, or nil if
--     no budget was configured.
--
-- Note on "instruction-count-ish": this counts calls to tick(), which the
-- author places once per loop iteration -- not raw VM instructions the way
-- lib.sandbox.run's debug.sethook budget counts. A loop body with more work
-- per iteration burns more real work per tick() than a cheap one; this
-- module does not and cannot normalize for that, same as any other
-- iteration counter.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

--:: Checker = { _budget: integer | nil, _count: integer, _deadline: number | nil, _clock: (() -> number) | nil }

local M = {}
local Checker = {}
Checker.__index = Checker

--: ({ budget?: integer, deadline?: number, clock?: () -> number }) -> (Checker | nil, string | nil)
function M.new(opts)
	opts = opts or {}
	if not opts.budget and not opts.deadline then
		return nil, "interrupt_cooperative.new: at least one of opts.budget / opts.deadline is required"
	end
	if opts.deadline and type(opts.clock) ~= "function" then
		return nil, "interrupt_cooperative.new: opts.deadline requires opts.clock (a () -> number time source)"
	end
	return setmetatable({
		_budget    = opts.budget,
		_count     = 0,
		_deadline  = opts.deadline,
		_clock     = opts.clock,
	}, Checker)
end

--: (Checker) -> nil
function Checker:tick()
	self._count = self._count + 1
	if self._budget and self._count > self._budget then
		error("interrupt_cooperative: budget exceeded (" .. self._budget .. " iterations)", 2)
	end
	if self._deadline and self._clock then
		if self._clock() >= self._deadline then
			error("interrupt_cooperative: deadline exceeded", 2)
		end
	end
end

--: (Checker) -> integer | nil
function Checker:remaining()
	if not self._budget then return nil end
	local left = self._budget - self._count
	return left > 0 and left or 0
end

return M
