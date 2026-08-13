-- lib/os_isolation/thread_test.lua

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local thread = require("lib.os_isolation.thread")

T.describe("thread.spawn / handle.join", function()
	T.it("runs code on a separate OS thread and returns its result", function()
		local h, err = thread.spawn("local a = ...; return a * 2", 21)
		T.ok(h, err)
		local ok, result = h.join()
		T.ok(ok)
		T.eq(result, 42)
	end)

	T.it("propagates a runtime error from the child as (false, message)", function()
		local h = thread.spawn("error('boom')")
		local ok, err = h.join()
		T.fail(ok)
		T.ok(err:find("boom"))
	end)

	T.it("propagates a load() syntax error from the child as (false, message)", function()
		local h = thread.spawn("this is not valid lua )(")
		local ok, err = h.join()
		T.fail(ok)
		T.ok(type(err) == "string")
	end)

	T.it("child has its OWN independent globals (real separate lua_State, not a shared coroutine)", function()
		-- If this were lua_newthread() (a coroutine of the SAME lua_State),
		-- setting a global inside the child would be visible in the parent's
		-- _G too, since coroutines share the parent's globals table. A real
		-- separate lua_State does not.
		_G.thread_test_sentinel = "parent" --[[: string | nil]]
		local h = thread.spawn([[
			thread_test_sentinel = "child"
			return thread_test_sentinel
		]])
		local ok, result = h.join()
		T.ok(ok)
		T.eq(result, "child")
		T.eq(_G.thread_test_sentinel, "parent")
		_G.thread_test_sentinel = nil
	end)

	T.it("rejects a non-string code argument (closures cannot cross into a fresh lua_State)", function()
		local h, err = thread.spawn(function() end)
		T.eq(h, nil)
		T.ok(err:find("must be a string"))
	end)

	T.it("join() twice on the same handle is an error, not a hang or crash", function()
		local h = thread.spawn("return 1")
		local ok1 = h.join()
		T.ok(ok1)
		local ok2, err2 = h.join()
		T.fail(ok2)
		T.ok(err2:find("already joined"))
	end)

	T.it("args round-trip through JSON (tables, not just scalars)", function()
		local h = thread.spawn("local t = ...; return t.x + t.y", { x = 2, y = 3 })
		local ok, result = h.join()
		T.ok(ok)
		T.eq(result, 5)
	end)
end)

T.describe("thread handle.tid", function()
	T.it("reports a positive Linux tid after join (Linux) or nil (non-Linux)", function()
		local h = thread.spawn("return 1")
		local ok = h.join()
		T.ok(ok)
		local tid = h.tid()
		if tid ~= nil then
			T.ok(tid > 0)
			T.ok(tid ~= 0)
		end
	end)
end)
