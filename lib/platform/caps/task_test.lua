if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi = require("ffi")
if ffi.os ~= "Linux" and ffi.os ~= "OSX" then return end

local T = require("lib.test.assert")
local async = require("lib.async")

local ok_io_poll, io_poll = pcall(require, "lib.io_poll")
if not ok_io_poll then return end

local ok_task_cap, task_mod = pcall(require, "lib.platform.caps.task")
if not ok_task_cap then return end

-- Build a real daemon_ctx for testing, same shape as pty_test.lua.
--: () -> { poller: unknown, loop: { run_until: (unknown, unknown) -> (unknown, unknown), queue: (unknown, () -> unknown) -> nil, sleep: (unknown, number) -> unknown, await_readable: (unknown, integer, unknown | nil) -> (unknown | nil, string | nil, (() -> nil) | nil), await_writable: (unknown, integer, unknown | nil) -> (unknown | nil, string | nil, (() -> nil) | nil), ... }, register_fd: (integer, () -> nil) -> (() -> nil), schedule: (() -> nil) -> nil }
local function make_daemon_ctx()
	local poller = io_poll.new()
	local loop = async.loop(poller)
	return {
		poller = poller,
		loop = loop,
		--: (fd: integer, on_readable: () -> nil) -> (() -> nil)
		register_fd = function(fd, on_readable)
			local _, remove_fn, err = poller:add(fd, on_readable, nil, true)
			if err then error("daemon_ctx.register_fd: " .. err) end
			--: () -> nil
			return function()
				if remove_fn then remove_fn() end
			end
		end,
		--: (fn: () -> nil) -> nil
		schedule = function(fn)
			loop:queue(fn)
		end,
	}
end

T.describe("task cap", function()
	T.describe("spawn + completion", function()
		T.it("spawns a task that completes synchronously", function()
			local ctx = make_daemon_ctx()
			local cap, revoke = task_mod.task_cap(ctx)
			T.ok(cap, "cap created")
			T.eq(cap._type, "task")

			local ran = false

			local outer = async.async(function()
				local handle, err = cap.spawn(function()
					ran = true
				end)
				T.ok(handle, "handle returned: " .. tostring(err))
				-- Task body runs synchronously during spawn (no yields),
				-- so it should already be done.
				T.ok(handle.done(), "task is done after synchronous body")
				return true
			end)

			local p = outer()
			local val, err = ctx.loop:run_until(p)
			T.ok(val, "outer completed: " .. tostring(err))
			T.ok(ran, "task body executed")
			revoke()
		end)
	end)

	T.describe("spawn with yielding", function()
		T.it("spawns a task that yields via loop:sleep and completes", function()
			local ctx = make_daemon_ctx()
			local cap, revoke = task_mod.task_cap(ctx)

			local completed = false

			local outer = async.async(function()
				local handle, err = cap.spawn(function()
					async.await(ctx.loop:sleep(10))
					completed = true
				end)
				T.ok(handle, "handle returned: " .. tostring(err))
				T.fail(handle.done(), "task not done yet (sleeping)")

				-- Wait long enough for the task to finish.
				async.await(ctx.loop:sleep(50))
				T.ok(handle.done(), "task done after sleep")
				return true
			end)

			local p = outer()
			local val, err = ctx.loop:run_until(p)
			T.ok(val, "outer completed: " .. tostring(err))
			T.ok(completed, "task body completed after yield")
			revoke()
		end)
	end)

	T.describe("cancellation", function()
		T.it("cancels a yielding task", function()
			local ctx = make_daemon_ctx()
			local cap, revoke = task_mod.task_cap(ctx)

			local reached_after_sleep = false

			local outer = async.async(function()
				local handle, err = cap.spawn(function()
					async.await(ctx.loop:sleep(5000))
					reached_after_sleep = true
				end)
				T.ok(handle, "handle returned: " .. tostring(err))
				T.fail(handle.done(), "task not done yet")

				local ok_c, cerr = handle.cancel()
				T.ok(ok_c, "cancel returned true: " .. tostring(cerr))
				T.ok(handle.done(), "task done after cancel")
				return true
			end)

			local p = outer()
			local val, err = ctx.loop:run_until(p)
			T.ok(val, "outer completed: " .. tostring(err))
			T.fail(reached_after_sleep, "code after sleep was not reached")
			revoke()
		end)

		T.it("cancel on already-done task is harmless", function()
			local ctx = make_daemon_ctx()
			local cap, revoke = task_mod.task_cap(ctx)

			local outer = async.async(function()
				local handle, err = cap.spawn(function()
					-- no-op, completes immediately
				end)
				T.ok(handle, "handle returned: " .. tostring(err))
				T.ok(handle.done(), "task already done")

				local ok_c, cerr = handle.cancel()
				T.ok(ok_c, "cancel on done task returned true: " .. tostring(cerr))
				T.ok(handle.done(), "still done")
				return true
			end)

			local p = outer()
			local val, err = ctx.loop:run_until(p)
			T.ok(val, "outer completed: " .. tostring(err))
			revoke()
		end)
	end)

	T.describe("revocation", function()
		T.it("cancels all active tasks on revoke", function()
			local ctx = make_daemon_ctx()
			local cap, revoke = task_mod.task_cap(ctx)

			local reached_1 = false
			local reached_2 = false

			local outer = async.async(function()
				local h1, e1 = cap.spawn(function()
					async.await(ctx.loop:sleep(5000))
					reached_1 = true
				end)
				T.ok(h1, "h1 returned: " .. tostring(e1))

				local h2, e2 = cap.spawn(function()
					async.await(ctx.loop:sleep(5000))
					reached_2 = true
				end)
				T.ok(h2, "h2 returned: " .. tostring(e2))

				T.fail(h1.done(), "h1 not done")
				T.fail(h2.done(), "h2 not done")

				revoke()

				T.ok(h1.done(), "h1 done after revoke")
				T.ok(h2.done(), "h2 done after revoke")
				return true
			end)

			local p = outer()
			local val, err = ctx.loop:run_until(p)
			T.ok(val, "outer completed: " .. tostring(err))
			T.fail(reached_1, "task 1 body not reached after revoke")
			T.fail(reached_2, "task 2 body not reached after revoke")
		end)

		T.it("rejects spawn after revoke", function()
			local ctx = make_daemon_ctx()
			local cap, revoke = task_mod.task_cap(ctx)

			revoke()

			local handle, err = cap.spawn(function() end)
			T.fail(handle, "spawn should fail after revoke")
			T.ok(err:find("revoked"), "error mentions revoked: " .. tostring(err))
		end)
	end)

	T.describe("error isolation", function()
		T.it("task error does not crash the loop", function()
			local ctx = make_daemon_ctx()
			local cap, revoke = task_mod.task_cap(ctx)

			local other_completed = false

			local outer = async.async(function()
				local h_err, e1 = cap.spawn(function()
					error("intentional test error")
				end)
				T.ok(h_err, "error task handle returned: " .. tostring(e1))
				-- The erroring task should be done (rejected).
				T.ok(h_err.done(), "error task is done")

				-- Spawn another task to prove the loop is still working.
				local h_ok, e2 = cap.spawn(function()
					async.await(ctx.loop:sleep(10))
					other_completed = true
				end)
				T.ok(h_ok, "second handle returned: " .. tostring(e2))

				async.await(ctx.loop:sleep(50))
				T.ok(h_ok.done(), "second task done")
				return true
			end)

			local p = outer()
			local val, err = ctx.loop:run_until(p)
			T.ok(val, "outer completed: " .. tostring(err))
			T.ok(other_completed, "second task completed despite first erroring")
			revoke()
		end)
	end)

	T.describe("requires daemon_ctx", function()
		T.it("returns error without daemon_ctx", function()
			local cap, err = task_mod.task_cap(nil)
			T.fail(cap, "should fail without daemon_ctx")
			T.ok(err, "error message returned")
		end)
	end)

	T.describe("spawn validation", function()
		T.it("rejects non-function argument", function()
			local ctx = make_daemon_ctx()
			local cap, revoke = task_mod.task_cap(ctx)

			local handle, err = cap.spawn("not a function")
			T.fail(handle, "should reject non-function")
			T.ok(err:find("fn must be a function"), "error mentions fn: " .. tostring(err))
			revoke()
		end)
	end)
end)
