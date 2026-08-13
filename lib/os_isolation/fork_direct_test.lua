-- lib/os_isolation/fork_direct_test.lua

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local fork_direct = require("lib.os_isolation.fork_direct")
local thread = require("lib.os_isolation.thread")

T.describe("fork_direct.spawn", function()
	T.it("runs fn in a real child process and returns its result", function()
		local h, err = fork_direct.spawn(function() return 21 * 2 end)
		T.ok(h, err)
		T.ok(h.pid > 0)
		local ok, result = h.join()
		T.ok(ok)
		T.eq(result, 42)
	end)

	T.it("child sees the parent's closure state via COW (no serialization needed for inputs)", function()
		local captured = { 1, 2, 3 }
		local h = fork_direct.spawn(function()
			local sum = 0
			for _, v in ipairs(captured) do sum = sum + v end
			return sum
		end)
		local ok, result = h.join()
		T.ok(ok)
		T.eq(result, 6)
	end)

	T.it("propagates a runtime error from the child as (false, message)", function()
		local h = fork_direct.spawn(function() error("kaboom") end)
		local ok, err = h.join()
		T.fail(ok)
		T.ok(err:find("kaboom"))
	end)

	T.it("child process does NOT mutate parent-visible globals (real process isolation)", function()
		_G.fork_direct_sentinel = "parent" --[[: string | nil]]
		local h = fork_direct.spawn(function()
			_G.fork_direct_sentinel = "child"
			return _G.fork_direct_sentinel
		end)
		local ok, result = h.join()
		T.ok(ok)
		T.eq(result, "child") -- true inside the child's own copy
		T.eq(_G.fork_direct_sentinel, "parent") -- unaffected in the parent
		_G.fork_direct_sentinel = nil
	end)

	T.it("join() twice on the same handle is an error, not a hang or crash", function()
		local h = fork_direct.spawn(function() return 1 end)
		local ok1 = h.join()
		T.ok(ok1)
		local ok2, err2 = h.join()
		T.fail(ok2)
		T.ok(err2:find("already joined"))
	end)

	T.it("rejects a non-function argument", function()
		local h, err = fork_direct.spawn("not a function")
		T.eq(h, nil)
		T.ok(err:find("must be a function"))
	end)
end)

T.describe("fork_direct.thread_count", function()
	T.it("returns 1 (or nil on non-Linux) for this single-threaded test process", function()
		local n = fork_direct.thread_count()
		if n ~= nil then
			T.eq(n, 1)
		end
	end)
end)

T.describe("fork_direct precondition enforcement (documented, checkable case)", function()
	T.it("refuses to fork when the calling process is genuinely multithreaded, and reports why", function()
		-- Uses thread.lua to put a second real OS thread into this process,
		-- then calls fork_direct.spawn FROM that second thread while the
		-- main thread is still alive (blocked in thread.join()'s
		-- pthread_join) -- this is the exact documented hazard case:
		-- fork-without-exec from a multithreaded process. Confirms the
		-- best-effort /proc/self/status check actually catches it, per this
		-- task's "fail safely/detectably rather than silently corrupt state
		-- where that's checkable" requirement.
		local code = [[
			if not package.path:find("?/init.lua", 1, true) then
				package.path = "./?/init.lua;" .. package.path
			end
			local fork_direct = require("lib.os_isolation.fork_direct")
			local n = fork_direct.thread_count()
			local h, err = fork_direct.spawn(function() return 1 end)
			return { n = n, spawn_ok = (h ~= nil), err = err }
		]]
		local handle, herr = thread.spawn(code)
		T.ok(handle, herr)
		local ok, result = handle.join()
		T.ok(ok)
		T.eq(result.spawn_ok, false)
		T.ok(result.n == nil or result.n > 1)
		T.ok(result.err and result.err:find("threads"))
	end)
end)
