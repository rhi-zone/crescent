-- circuit_breaker: fault-tolerant service call wrapper
-- Implements the circuit breaker pattern with CLOSED/OPEN/HALF_OPEN states.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

--:: State = "closed" | "open" | "half_open"
--:: CBClock = () -> number
--:: CBIsFailure = (result: unknown, err: unknown) -> boolean
--:: CBOnChange = (from: string, to: string) -> nil
--:: CB = { _failure_threshold: number, _success_threshold: number, _timeout: number, _on_state_change: CBOnChange | nil, _clock: CBClock, _is_failure: CBIsFailure, _state: string, _failures: integer, _successes: integer, _last_failure_time: number | nil, ... }

local STATE_CLOSED    = "closed"
local STATE_OPEN      = "open"
local STATE_HALF_OPEN = "half_open"

-- Default failure predicate: fail if second return value is non-nil
local function default_is_failure(result, err)
	return err ~= nil
end

-- Create a new circuit breaker.
-- opts:
--   failure_threshold  number   (default 5)  — failures before tripping
--   success_threshold  number   (default 1)  — successes in half_open to close
--   timeout            number   (default 30) — seconds before half_open retry
--   on_state_change    function(from, to)    — optional callback
--   clock              function() -> number  — injectable clock (required)
--   is_failure         function(result, err) -> bool — custom failure predicate
function M.new(opts)
	opts = opts or {}
	local cb = {
		_failure_threshold = opts.failure_threshold or 5,
		_success_threshold = opts.success_threshold or 1,
		_timeout           = opts.timeout or 30,
		_on_state_change   = opts.on_state_change,
		_clock             = opts.clock,
		_is_failure        = opts.is_failure or default_is_failure,
		_state             = STATE_CLOSED,
		_failures          = 0,
		_successes         = 0,
		_last_failure_time = nil,
	}
	setmetatable(cb, { __index = M })
	return cb
end

-- Internal: transition to a new state, firing callback if set.
local function transition(self, new_state)
	local cb = self --[[:! CB]]
	local old_state = cb._state
	if old_state == new_state then return end
	cb._state = new_state
	if cb._on_state_change then
		cb._on_state_change(old_state, new_state)
	end
end

-- Execute fn through the circuit breaker.
-- Returns the results of fn on success, or nil, errmsg on failure/open circuit.
function M.call(self, fn)
	local cb = self --[[:! CB]]
	-- Check if OPEN and whether timeout has elapsed
	if cb._state == STATE_OPEN then
		local now = cb._clock()
		if cb._last_failure_time and (now - cb._last_failure_time) >= cb._timeout then
			transition(cb, STATE_HALF_OPEN)
			cb._successes = 0
		else
			return nil, "circuit breaker is open"
		end
	end

	-- Execute fn (catch throws via pcall)
	-- LuaJIT: no table.pack; capture all returns via select
	local pok, r1, r2, r3, r4, r5 = pcall(fn)

	if not pok then
		-- fn threw an error (r1 is the error message here)
		cb._failures = cb._failures + 1
		cb._last_failure_time = cb._clock()
		if cb._state == STATE_HALF_OPEN then
			transition(cb, STATE_OPEN)
			cb._successes = 0
		elseif cb._failures >= cb._failure_threshold then
			transition(cb, STATE_OPEN)
		end
		return nil, tostring(r1)
	end

	-- fn returned normally; r1..r5 are its actual return values
	-- Check the failure predicate
	if cb._is_failure(r1, r2) then
		cb._failures = cb._failures + 1
		local t2 = cb._clock()
		cb._last_failure_time = t2 --[[:! number]]
		if cb._state == STATE_HALF_OPEN then
			transition(cb, STATE_OPEN)
			cb._successes = 0
		elseif cb._failures >= cb._failure_threshold then
			transition(cb, STATE_OPEN)
		end
		-- Return the original (failed) results to the caller
		return r1, r2, r3, r4, r5
	end

	-- Success
	if cb._state == STATE_HALF_OPEN then
		cb._successes = cb._successes + 1
		if cb._successes >= cb._success_threshold then
			transition(cb, STATE_CLOSED)
			cb._failures = 0
			cb._successes = 0
		end
	else
		-- CLOSED: reset failure count on success
		cb._failures = 0
	end

	return r1, r2, r3, r4, r5
end

-- Return current state string: "closed", "open", or "half_open"
function M:state()
	return self._state
end

-- Return the current failure count
function M:failure_count()
	return self._failures
end

-- Return the current success count (meaningful in half_open)
function M:success_count()
	return self._successes
end

-- Return timestamp of last failure or nil
function M:last_failure_time()
	return self._last_failure_time
end

-- Force the circuit to closed state and reset all counters
function M:reset()
	self._failures = 0
	self._successes = 0
	self._last_failure_time = nil
	transition(self, STATE_CLOSED)
end

-- Force the circuit open (useful for testing or manual intervention)
function M:trip()
	self._last_failure_time = self._clock()
	transition(self, STATE_OPEN)
end

-- Wrap fn permanently; returns a function that calls cb:call(fn)
function M:wrap(fn)
	local self_ = self
	return function(...)
		-- fn may take arguments; capture via closure over varargs
		local args = { ... }
		local nargs = select("#", ...)
		return self_:call(function() return fn(unpack(args, 1, nargs)) end)
	end
end

return M
