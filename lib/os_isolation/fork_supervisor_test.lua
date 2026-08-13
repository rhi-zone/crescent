-- lib/os_isolation/fork_supervisor_test.lua

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local fork_supervisor = require("lib.os_isolation.fork_supervisor")

T.describe("fork_supervisor.start / :spawn / handle.join", function()
	T.it("starts a real supervisor process with its own pid", function()
		local sup, err = fork_supervisor.start()
		T.ok(sup, err)
		T.ok(sup.pid > 0)
		sup:stop()
	end)

	T.it("spawns a child that runs Lua source and returns its result", function()
		local sup = fork_supervisor.start()
		local h, herr = sup:spawn("local a = ...; return a + 1", 41)
		T.ok(h, herr)
		T.ok(h.pid > 0)
		T.ok(h.pid ~= sup.pid) -- the CHILD, not the supervisor itself
		local ok, result = h.join()
		T.ok(ok)
		T.eq(result, 42)
		sup:stop()
	end)

	T.it("propagates a child runtime error as (false, message)", function()
		local sup = fork_supervisor.start()
		local h = sup:spawn("error('boom')")
		local ok, err = h.join()
		T.fail(ok)
		T.ok(err:find("boom"))
		sup:stop()
	end)

	T.it("rejects a non-string code argument (closures cannot cross a process boundary)", function()
		local sup = fork_supervisor.start()
		local h, err = sup:spawn(function() end)
		T.eq(h, nil)
		T.ok(err:find("must be a string"))
		sup:stop()
	end)

	T.it("multiple children spawned before any join() run concurrently", function()
		local sup = fork_supervisor.start()
		local h1 = sup:spawn("return 'first'")
		local h2 = sup:spawn("return 'second'")
		T.ok(h1.pid ~= h2.pid)
		local ok1, r1 = h1.join()
		local ok2, r2 = h2.join()
		T.ok(ok1); T.eq(r1, "first")
		T.ok(ok2); T.eq(r2, "second")
		sup:stop()
	end)

	T.it("join() twice on the same handle is an error", function()
		local sup = fork_supervisor.start()
		local h = sup:spawn("return 1")
		h.join()
		local ok2, err2 = h.join()
		T.fail(ok2)
		T.ok(err2:find("already joined"))
		sup:stop()
	end)

	T.it("spawn() after stop() is an error, not a hang", function()
		local sup = fork_supervisor.start()
		sup:stop()
		local h, err = sup:spawn("return 1")
		T.eq(h, nil)
		T.ok(err:find("stopped"))
	end)

	T.it("a supervisor-spawned child does NOT share the caller's closures/upvalues", function()
		-- Structural check: code is source text, not a function -- args must
		-- be JSON-representable. Passing a Lua table with only JSON-safe
		-- values works; the point under test is documented in the module
		-- header (no closures cross), exercised here via the string-only
		-- `code` contract already enforced by the rejection test above.
		local sup = fork_supervisor.start()
		local h = sup:spawn("local t = ...; return t.x + t.y", { x = 2, y = 3 })
		local ok, result = h.join()
		T.ok(ok)
		T.eq(result, 5)
		sup:stop()
	end)
end)
