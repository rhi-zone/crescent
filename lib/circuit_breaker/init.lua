-- circuit_breaker: fault-tolerant service call wrapper
-- Implements the circuit breaker pattern with CLOSED/OPEN/HALF_OPEN states.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

--:: State = "closed" | "open" | "half_open"

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
	local old_state = self._state
	if old_state == new_state then return end
	self._state = new_state
	if self._on_state_change then
		self._on_state_change(old_state, new_state)
	end
end

-- Execute fn through the circuit breaker.
-- Returns the results of fn on success, or nil, errmsg on failure/open circuit.
function M:call(fn)
	-- Check if OPEN and whether timeout has elapsed
	if self._state == STATE_OPEN then
		local now = self._clock()
		if self._last_failure_time and (now - self._last_failure_time) >= self._timeout then
			transition(self, STATE_HALF_OPEN)
			self._successes = 0
		else
			return nil, "circuit breaker is open"
		end
	end

	-- Execute fn (catch throws via pcall)
	-- LuaJIT: no table.pack; capture all returns via select
	local pok, r1, r2, r3, r4, r5 = pcall(fn)

	if not pok then
		-- fn threw an error (r1 is the error message here)
		self._failures = self._failures + 1
		self._last_failure_time = self._clock()
		if self._state == STATE_HALF_OPEN then
			transition(self, STATE_OPEN)
			self._successes = 0
		elseif self._failures >= self._failure_threshold then
			transition(self, STATE_OPEN)
		end
		return nil, tostring(r1)
	end

	-- fn returned normally; r1..r5 are its actual return values
	-- Check the failure predicate
	if self._is_failure(r1, r2) then
		self._failures = self._failures + 1
		self._last_failure_time = self._clock()
		if self._state == STATE_HALF_OPEN then
			transition(self, STATE_OPEN)
			self._successes = 0
		elseif self._failures >= self._failure_threshold then
			transition(self, STATE_OPEN)
		end
		-- Return the original (failed) results to the caller
		return r1, r2, r3, r4, r5
	end

	-- Success
	if self._state == STATE_HALF_OPEN then
		self._successes = self._successes + 1
		if self._successes >= self._success_threshold then
			transition(self, STATE_CLOSED)
			self._failures = 0
			self._successes = 0
		end
	else
		-- CLOSED: reset failure count on success
		self._failures = 0
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
