if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local M = require("lib.circuit_breaker")

-- Shared injectable clock
local time = 0
local function clock() return time end

local function reset_clock() time = 0 end

local function make_fail() return nil, "error" end
local function make_ok() return "ok" end

-- ── Basic state inspection ────────────────────────────────────────────────────

T.describe("circuit_breaker", function()

	T.it("starts in closed state", function()
		reset_clock()
		local cb = M.new({ clock = clock })
		T.eq(cb:state(), "closed")
		T.eq(cb:failure_count(), 0)
		T.eq(cb:success_count(), 0)
		T.eq(cb:last_failure_time(), nil)
	end)

	-- ── CLOSED behaviour ─────────────────────────────────────────────────────

	T.it("passes through successful calls in closed state", function()
		reset_clock()
		local cb = M.new({ clock = clock })
		local result = cb:call(make_ok)
		T.eq(result, "ok")
		T.eq(cb:state(), "closed")
	end)

	T.it("counts failures in closed state", function()
		reset_clock()
		local cb = M.new({ failure_threshold = 5, clock = clock })
		cb:call(make_fail)
		cb:call(make_fail)
		T.eq(cb:failure_count(), 2)
		T.eq(cb:state(), "closed")
	end)

	T.it("resets failure count on success in closed state", function()
		reset_clock()
		local cb = M.new({ failure_threshold = 5, clock = clock })
		cb:call(make_fail)
		cb:call(make_fail)
		T.eq(cb:failure_count(), 2)
		cb:call(make_ok)
		T.eq(cb:failure_count(), 0)
		T.eq(cb:state(), "closed")
	end)

	T.it("records last_failure_time on failure", function()
		reset_clock()
		time = 42
		local cb = M.new({ clock = clock })
		cb:call(make_fail)
		T.eq(cb:last_failure_time(), 42)
	end)

	-- ── Tripping ─────────────────────────────────────────────────────────────

	T.it("trips after failure_threshold failures", function()
		reset_clock()
		local cb = M.new({ failure_threshold = 3, clock = clock })
		cb:call(make_fail)
		cb:call(make_fail)
		T.eq(cb:state(), "closed")
		cb:call(make_fail)
		T.eq(cb:state(), "open")
	end)

	T.it("trips with default threshold of 5", function()
		reset_clock()
		local cb = M.new({ clock = clock })
		for _ = 1, 4 do cb:call(make_fail) end
		T.eq(cb:state(), "closed")
		cb:call(make_fail)
		T.eq(cb:state(), "open")
	end)

	-- ── OPEN behaviour ───────────────────────────────────────────────────────

	T.it("rejects calls immediately when open", function()
		reset_clock()
		local cb = M.new({ failure_threshold = 1, clock = clock })
		cb:call(make_fail)
		T.eq(cb:state(), "open")
		local calls = 0
		local _, err = cb:call(function() calls = calls + 1; return "ok" end)
		T.eq(calls, 0)
		T.eq(err, "circuit breaker is open")
	end)

	T.it("returns nil, errmsg when open", function()
		reset_clock()
		local cb = M.new({ failure_threshold = 1, clock = clock })
		cb:call(make_fail)
		local r, e = cb:call(make_ok)
		T.eq(r, nil)
		T.eq(e, "circuit breaker is open")
	end)

	-- ── HALF_OPEN behaviour ──────────────────────────────────────────────────

	T.it("transitions to half_open after timeout", function()
		reset_clock()
		local cb = M.new({ failure_threshold = 1, timeout = 10, clock = clock })
		cb:call(make_fail)
		T.eq(cb:state(), "open")
		time = 10
		-- A call attempt should transition to half_open (timeout elapsed)
		local calls = 0
		cb:call(function() calls = calls + 1; return "ok" end)
		T.eq(calls, 1)
		-- state should now be closed (success_threshold = 1)
		T.eq(cb:state(), "closed")
	end)

	T.it("half-open: allows one probe after timeout", function()
		reset_clock()
		local cb = M.new({ failure_threshold = 1, timeout = 10, clock = clock })
		cb:call(make_fail)
		time = 11
		local calls = 0
		cb:call(function() calls = calls + 1; return "ok" end)
		T.eq(calls, 1)
	end)

	T.it("closes after successful probe in half_open", function()
		reset_clock()
		local cb = M.new({ failure_threshold = 1, timeout = 10, clock = clock })
		cb:call(make_fail)
		time = 11
		cb:call(make_ok)
		T.eq(cb:state(), "closed")
	end)

	T.it("stays open if probe fails in half_open", function()
		reset_clock()
		local cb = M.new({ failure_threshold = 1, timeout = 10, clock = clock })
		cb:call(make_fail)
		time = 11
		cb:call(make_fail)
		T.eq(cb:state(), "open")
	end)

	T.it("does not transition to half_open before timeout", function()
		reset_clock()
		local cb = M.new({ failure_threshold = 1, timeout = 10, clock = clock })
		cb:call(make_fail)
		time = 9
		local _, err = cb:call(make_ok)
		T.eq(err, "circuit breaker is open")
		T.eq(cb:state(), "open")
	end)

	T.it("success_threshold > 1: requires multiple successes to close", function()
		reset_clock()
		local cb = M.new({
			failure_threshold = 1,
			success_threshold = 3,
			timeout = 10,
			clock = clock,
		})
		cb:call(make_fail)
		time = 11
		cb:call(make_ok)  -- probe → half_open, 1 success
		T.eq(cb:state(), "half_open")
		cb:call(make_ok)  -- 2 successes
		T.eq(cb:state(), "half_open")
		cb:call(make_ok)  -- 3 successes → closed
		T.eq(cb:state(), "closed")
	end)

	T.it("half_open: failure resets success counter and reopens", function()
		reset_clock()
		local cb = M.new({
			failure_threshold = 1,
			success_threshold = 3,
			timeout = 10,
			clock = clock,
		})
		cb:call(make_fail)
		time = 11
		cb:call(make_ok)   -- 1 success in half_open
		T.eq(cb:state(), "half_open")
		cb:call(make_fail) -- failure → back to open
		T.eq(cb:state(), "open")
		T.eq(cb:success_count(), 0)
	end)

	-- ── Thrown errors ────────────────────────────────────────────────────────

	T.it("counts thrown errors as failures", function()
		reset_clock()
		local cb = M.new({ failure_threshold = 2, clock = clock })
		cb:call(function() error("boom") end)
		T.eq(cb:failure_count(), 1)
		cb:call(function() error("boom") end)
		T.eq(cb:state(), "open")
	end)

	T.it("returns nil, errmsg when fn throws", function()
		reset_clock()
		local cb = M.new({ failure_threshold = 5, clock = clock })
		local r, e = cb:call(function() error("kaboom") end)
		T.eq(r, nil)
		T.ok(e ~= nil)
		T.ok(type(e) == "string")
	end)

	-- ── reset() ──────────────────────────────────────────────────────────────

	T.it("reset() forces closed and clears counters", function()
		reset_clock()
		local cb = M.new({ failure_threshold = 1, clock = clock })
		cb:call(make_fail)
		T.eq(cb:state(), "open")
		cb:reset()
		T.eq(cb:state(), "closed")
		T.eq(cb:failure_count(), 0)
		T.eq(cb:success_count(), 0)
		T.eq(cb:last_failure_time(), nil)
	end)

	T.it("reset() allows calls again", function()
		reset_clock()
		local cb = M.new({ failure_threshold = 1, clock = clock })
		cb:call(make_fail)
		cb:reset()
		local result = cb:call(make_ok)
		T.eq(result, "ok")
	end)

	-- ── trip() ───────────────────────────────────────────────────────────────

	T.it("trip() forces open state", function()
		reset_clock()
		local cb = M.new({ clock = clock })
		T.eq(cb:state(), "closed")
		cb:trip()
		T.eq(cb:state(), "open")
	end)

	T.it("trip() sets last_failure_time to current clock", function()
		reset_clock()
		time = 99
		local cb = M.new({ clock = clock })
		cb:trip()
		T.eq(cb:last_failure_time(), 99)
	end)

	T.it("trip() then timeout → half_open → closed", function()
		reset_clock()
		local cb = M.new({ timeout = 5, clock = clock })
		cb:trip()
		time = 5
		cb:call(make_ok)
		T.eq(cb:state(), "closed")
	end)

	-- ── wrap() ───────────────────────────────────────────────────────────────

	T.it("wrap() returns a callable", function()
		reset_clock()
		local cb = M.new({ clock = clock })
		local safe = cb:wrap(make_ok)
		T.ok(type(safe) == "function")
	end)

	T.it("wrap() delegates to call()", function()
		reset_clock()
		local cb = M.new({ clock = clock })
		local safe = cb:wrap(make_ok)
		local result = safe()
		T.eq(result, "ok")
	end)

	T.it("wrap() passes arguments to wrapped function", function()
		reset_clock()
		local cb = M.new({ clock = clock })
		local safe = cb:wrap(function(a, b) return a + b end)
		local result = safe(3, 4)
		T.eq(result, 7)
	end)

	T.it("wrap() counts failures through circuit breaker", function()
		reset_clock()
		local cb = M.new({ failure_threshold = 2, clock = clock })
		local safe = cb:wrap(make_fail)
		safe()
		safe()
		T.eq(cb:state(), "open")
	end)

	T.it("wrap() fast-fails when open", function()
		reset_clock()
		local cb = M.new({ failure_threshold = 1, clock = clock })
		local calls = 0
		local safe = cb:wrap(function() calls = calls + 1; return "ok" end)
		cb:trip()
		local _, err = safe()
		T.eq(calls, 0)
		T.eq(err, "circuit breaker is open")
	end)

	-- ── on_state_change callback ──────────────────────────────────────────────

	T.it("on_state_change fires on CLOSED → OPEN", function()
		reset_clock()
		local changes = {}
		local cb = M.new({
			failure_threshold = 2,
			clock = clock,
			on_state_change = function(from, to)
				changes[#changes + 1] = { from = from, to = to }
			end,
		})
		cb:call(make_fail)
		cb:call(make_fail)
		T.eq(#changes, 1)
		T.eq(changes[1].from, "closed")
		T.eq(changes[1].to, "open")
	end)

	T.it("on_state_change fires on OPEN → HALF_OPEN → CLOSED", function()
		reset_clock()
		local changes = {}
		local cb = M.new({
			failure_threshold = 1,
			timeout = 10,
			clock = clock,
			on_state_change = function(from, to)
				changes[#changes + 1] = { from = from, to = to }
			end,
		})
		cb:call(make_fail)
		time = 11
		cb:call(make_ok)
		T.eq(#changes, 3)
		T.eq(changes[1].from, "closed"); T.eq(changes[1].to, "open")
		T.eq(changes[2].from, "open");   T.eq(changes[2].to, "half_open")
		T.eq(changes[3].from, "half_open"); T.eq(changes[3].to, "closed")
	end)

	T.it("on_state_change fires on HALF_OPEN → OPEN on probe failure", function()
		reset_clock()
		local changes = {}
		local cb = M.new({
			failure_threshold = 1,
			timeout = 10,
			clock = clock,
			on_state_change = function(from, to)
				changes[#changes + 1] = { from = from, to = to }
			end,
		})
		cb:call(make_fail)  -- CLOSED → OPEN
		time = 11
		cb:call(make_fail)  -- OPEN → HALF_OPEN → OPEN
		T.eq(#changes, 3)
		T.eq(changes[2].from, "open");      T.eq(changes[2].to, "half_open")
		T.eq(changes[3].from, "half_open"); T.eq(changes[3].to, "open")
	end)

	T.it("on_state_change fires on reset() from open", function()
		reset_clock()
		local changes = {}
		local cb = M.new({
			failure_threshold = 1,
			clock = clock,
			on_state_change = function(from, to)
				changes[#changes + 1] = { from = from, to = to }
			end,
		})
		cb:call(make_fail)
		cb:reset()
		T.eq(#changes, 2)
		T.eq(changes[2].from, "open")
		T.eq(changes[2].to, "closed")
	end)

	-- ── custom is_failure predicate ───────────────────────────────────────────

	T.it("custom is_failure: treats non-200 status as failure", function()
		reset_clock()
		local cb = M.new({
			failure_threshold = 2,
			clock = clock,
			is_failure = function(result, _err)
				return type(result) == "table" and result.status ~= 200
			end,
		})
		cb:call(function() return { status = 503 } end)
		T.eq(cb:failure_count(), 1)
		cb:call(function() return { status = 200 } end)
		T.eq(cb:failure_count(), 0)  -- success resets
		cb:call(function() return { status = 404 } end)
		T.eq(cb:failure_count(), 1)
		cb:call(function() return { status = 500 } end)
		T.eq(cb:state(), "open")
	end)

	T.it("custom is_failure: never fails treats everything as success", function()
		reset_clock()
		local cb = M.new({
			failure_threshold = 1,
			clock = clock,
			is_failure = function(_r, _e) return false end,
		})
		cb:call(function() return nil, "error" end)
		T.eq(cb:state(), "closed")
	end)

	-- ── return value passthrough ──────────────────────────────────────────────

	T.it("call passes through multiple return values", function()
		reset_clock()
		local cb = M.new({ clock = clock })
		local a, b, c = cb:call(function() return 1, 2, 3 end)
		T.eq(a, 1)
		T.eq(b, 2)
		T.eq(c, 3)
	end)

	T.it("call passes through failed return values", function()
		reset_clock()
		local cb = M.new({ failure_threshold = 5, clock = clock })
		local r, e = cb:call(make_fail)
		T.eq(r, nil)
		T.eq(e, "error")
	end)

	-- ── _tier ────────────────────────────────────────────────────────────────

	T.it("_tier is 'pure'", function()
		T.eq(M._tier, "pure")
	end)

end)
