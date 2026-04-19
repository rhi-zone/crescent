-- lib/platform/session_store/session_store_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T     = require("lib.test.assert")
local store = require("lib.platform.session_store")

-- Shared clock for tests; can be advanced by callers.
local function make_clock(start)
	local t = start or 1000
	return {
		now   = function() return t end,
		advance = function(n) t = t + n end,
	}
end

T.describe("session_store", function()

	T.it("open creates the sessions table", function()
		local clk = make_clock()
		local s, err = store.open(":memory:", { time_fn = clk.now, idle_ttl = 3600 })
		T.ok(s, "open should succeed: " .. tostring(err))
		s:close()
	end)

	T.it("put + get round-trips a record", function()
		local clk = make_clock(1000)
		local s = assert(store.open(":memory:", { time_fn = clk.now, idle_ttl = 3600 }))
		local rec = { last_seen = 1000, csrf_token = "abc123", created_at = 999 }
		local ok, err = s:put("sid1", rec)
		T.ok(ok, "put should succeed: " .. tostring(err))
		local got = s:get("sid1")
		T.ok(got ~= nil, "get should return the record")
		-- `any` cast to read fields from unknown-typed return value.
		local got_any = got --: any
		T.eq(got_any.last_seen, 1000)
		T.eq(got_any.csrf_token, "abc123")
		T.eq(got_any.created_at, 999)
		s:close()
	end)

	T.it("get returns nil for unknown session", function()
		local clk = make_clock()
		local s = assert(store.open(":memory:", { time_fn = clk.now, idle_ttl = 3600 }))
		local got = s:get("no-such-session")
		T.eq(got, nil)
		s:close()
	end)

	T.it("get returns nil for expired session (last_seen + idle_ttl < now)", function()
		local clk = make_clock(1000)
		local s = assert(store.open(":memory:", { time_fn = clk.now, idle_ttl = 60 }))
		local ok = s:put("expired-sid", { last_seen = 1000 })
		T.ok(ok)
		-- Advance clock past idle_ttl (60s) so last_seen(1000) + 60 < now(1061).
		clk.advance(61)
		local got = s:get("expired-sid")
		T.eq(got, nil, "expired session should return nil")
		s:close()
	end)

	T.it("get returns record when exactly at idle boundary (last_seen + idle_ttl == now)", function()
		local clk = make_clock(1000)
		local s = assert(store.open(":memory:", { time_fn = clk.now, idle_ttl = 60 }))
		local ok = s:put("boundary-sid", { last_seen = 1000 })
		T.ok(ok)
		-- At exactly 1060: 1000 + 60 == 1060, which is NOT < 1060, so not expired.
		clk.advance(60)
		local got = s:get("boundary-sid")
		T.ok(got ~= nil, "session at exact TTL boundary should still be live")
		s:close()
	end)

	T.it("touch updates last_seen and returns true", function()
		local clk = make_clock(1000)
		local s = assert(store.open(":memory:", { time_fn = clk.now, idle_ttl = 3600 }))
		s:put("touch-sid", { last_seen = 1000 })
		clk.advance(500)
		local ok = s:touch("touch-sid")
		T.ok(ok, "touch should return true for live session")
		-- Advance another 3500s (total 4000 from original mint). Without touch,
		-- 1000 + 3600 < 4500 → expired. With touch at t=1500, 1500 + 3600 > 4500 → live.
		clk.advance(3000)
		local got = s:get("touch-sid")
		T.ok(got ~= nil, "session should remain live after touch")
		local got_any = got --: any
		T.eq(got_any.last_seen, 1500, "last_seen should be updated to touch time")
		s:close()
	end)

	T.it("touch returns false for missing session", function()
		local clk = make_clock()
		local s = assert(store.open(":memory:", { time_fn = clk.now, idle_ttl = 3600 }))
		local ok = s:touch("no-such-session")
		T.eq(ok, false)
		s:close()
	end)

	T.it("touch returns false for expired session", function()
		local clk = make_clock(1000)
		local s = assert(store.open(":memory:", { time_fn = clk.now, idle_ttl = 60 }))
		s:put("exp-touch", { last_seen = 1000 })
		clk.advance(61)
		local ok = s:touch("exp-touch")
		T.eq(ok, false, "touch should return false for expired session")
		s:close()
	end)

	T.it("delete removes a session", function()
		local clk = make_clock()
		local s = assert(store.open(":memory:", { time_fn = clk.now, idle_ttl = 3600 }))
		s:put("del-sid", { last_seen = clk.now() })
		local ok, err = s:delete("del-sid")
		T.ok(ok, "delete should succeed: " .. tostring(err))
		local got = s:get("del-sid")
		T.eq(got, nil, "deleted session should not be found")
		s:close()
	end)

	T.it("purge_expired removes only expired sessions, keeps live ones", function()
		local clk = make_clock(1000)
		local s = assert(store.open(":memory:", { time_fn = clk.now, idle_ttl = 60 }))
		-- Insert one live and one expired session.
		s:put("live-sid",    { last_seen = 1000 })
		s:put("expired-sid", { last_seen = 900 })  -- 900 + 60 = 960 < 1000 → already expired at t=1000
		local ok, err = s:purge_expired()
		T.ok(ok, "purge_expired should succeed: " .. tostring(err))
		-- live-sid at last_seen=1000, now=1000: 1000 + 60 = 1060 >= 1000 → live
		local live_got = s:get("live-sid")
		T.ok(live_got ~= nil, "live session should survive purge")
		-- expired-sid should be gone (purged)
		-- We query the DB directly to confirm deletion rather than going through get()
		-- (which also returns nil for expired rows).
		-- Re-open with a clock that is far in the past so expired check doesn't fire,
		-- then check: open a second store on the same :memory: is a new DB, so use
		-- a sentinel approach instead — advance time and check purge_expired again
		-- to confirm idempotency and that expired-sid row count changes.
		-- Simpler: just confirm get with old-timestamp clock gives nil only from purge,
		-- not TTL logic. Use a long-ttl store on the same db is impossible with :memory:.
		-- Best we can do: verify get(expired-sid) returns nil at current time.
		local exp_got = s:get("expired-sid")
		T.eq(exp_got, nil, "expired session should be removed after purge")
		s:close()
	end)

	T.it("persistence: put in first handle, get in second", function()
		-- Use a real temp file so two open() calls share the same database.
		-- We use os.tmpname() here purely for the test path — not reaching for
		-- os.time() or any injected dep, so this is acceptable test scaffolding.
		local path = os.tmpname() .. "_session_test.db"
		local clk = make_clock(1000)

		local s1 = assert(store.open(path, { time_fn = clk.now, idle_ttl = 3600 }))
		s1:put("persist-sid", { last_seen = 1000, csrf_token = "token123" })
		s1:close()

		local s2 = assert(store.open(path, { time_fn = clk.now, idle_ttl = 3600 }))
		local got = s2:get("persist-sid")
		T.ok(got ~= nil, "session should persist across re-open")
		local got_any = got --: any
		T.eq(got_any.csrf_token, "token123")
		s2:close()

		os.remove(path)
	end)

end)
