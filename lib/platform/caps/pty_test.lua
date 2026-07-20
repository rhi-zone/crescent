if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi = require("ffi")
if ffi.os ~= "Linux" and ffi.os ~= "OSX" then return end

local T = require("lib.test.assert")
local async = require("lib.async")

local ok_io_poll, io_poll = pcall(require, "lib.io_poll")
if not ok_io_poll then return end

local ok_pty_cap, pty_mod = pcall(require, "lib.platform.caps.pty")
if not ok_pty_cap then return end

-- Build a real daemon_ctx for testing, same shape as lib/platform/daemon/cli.lua.
--: () -> { poller: unknown, loop: { run_until: (unknown, unknown) -> (unknown, unknown), queue: (unknown, () -> unknown) -> nil, await_readable: (unknown, integer, unknown | nil) -> (unknown | nil, string | nil, (() -> nil) | nil), await_writable: (unknown, integer, unknown | nil) -> (unknown | nil, string | nil, (() -> nil) | nil), ... }, register_fd: (integer, () -> nil) -> (() -> nil), schedule: (() -> nil) -> nil }
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

T.describe("pty cap", function()
	T.describe("spawn + read", function()
		T.it("reads output from a spawned command", function()
			local ctx = make_daemon_ctx()
			local cap, revoke = pty_mod.pty_cap(ctx)
			T.ok(cap, "cap created")
			T.eq(cap._type, "pty")

			local output_box = {} --: { [integer]: string }

			local reader = async.async(function()
				local handle, err = cap.spawn("echo", { args = { "hello_pty_cap" } })
				if not handle then error("spawn failed: " .. tostring(err)) end
				T.ok(handle.pid > 0, "child pid is positive")

				-- Read until EOF or error (child exits after echo)
				while true do
					local data, rerr = handle.read()
					if data then
						output_box[#output_box + 1] = data
					else
						break
					end
				end

				handle.close()
				return true
			end)

			local p = reader()
			local val, err = ctx.loop:run_until(p)
			T.ok(val, "async reader completed: " .. tostring(err))

			local output = table.concat(output_box)
			T.ok(output:find("hello_pty_cap"), "output contains 'hello_pty_cap', got: " .. tostring(output))
			revoke()
		end)
	end)

	T.describe("spawn + write + read round-trip", function()
		T.it("writes to stdin and reads echoed output via cat", function()
			local ctx = make_daemon_ctx()
			local cap, revoke = pty_mod.pty_cap(ctx)

			local output_box = {} --: { [integer]: string }
			local found = false

			local worker = async.async(function()
				local handle, err = cap.spawn("cat")
				if not handle then error("spawn failed: " .. tostring(err)) end

				-- Write data to cat's stdin via PTY
				local n, werr = handle.write("round_trip_test\n")
				T.ok(n, "write succeeded: " .. tostring(werr))

				-- Read output — cat echoes input back through the PTY.
				-- PTY line discipline echoes the write, and cat reads+writes it again,
				-- so we may get the string once or twice. Read a few chunks.
				for _ = 1, 10 do
					local data, rerr = handle.read()
					if data then
						output_box[#output_box + 1] = data
						if table.concat(output_box):find("round_trip_test") then
							found = true
							break
						end
					else
						break
					end
				end

				handle.close()
				return true
			end)

			local p = worker()
			local val, err = ctx.loop:run_until(p)
			T.ok(val, "async worker completed: " .. tostring(err))
			T.ok(found, "output contains 'round_trip_test', got: " .. table.concat(output_box))
			revoke()
		end)
	end)

	T.describe("resize", function()
		T.it("resizes the PTY window without error", function()
			local ctx = make_daemon_ctx()
			local cap, revoke = pty_mod.pty_cap(ctx)

			local worker = async.async(function()
				local handle, err = cap.spawn("cat")
				if not handle then error("spawn failed: " .. tostring(err)) end

				local ok_rs, rerr = handle.resize(40, 120)
				T.ok(ok_rs, "resize succeeded: " .. tostring(rerr))

				handle.close()
				return true
			end)

			local p = worker()
			local val, err = ctx.loop:run_until(p)
			T.ok(val, "async worker completed: " .. tostring(err))
			revoke()
		end)
	end)

	T.describe("initial window size", function()
		T.it("sets rows and cols at spawn time", function()
			local ctx = make_daemon_ctx()
			local cap, revoke = pty_mod.pty_cap(ctx)

			local worker = async.async(function()
				local handle, err = cap.spawn("cat", { rows = 30, cols = 100 })
				if not handle then error("spawn failed: " .. tostring(err)) end
				-- If set_winsize failed, spawn would have returned nil.
				-- Getting here means it worked.
				handle.close()
				return true
			end)

			local p = worker()
			local val, err = ctx.loop:run_until(p)
			T.ok(val, "spawn with rows/cols succeeded: " .. tostring(err))
			revoke()
		end)
	end)

	T.describe("close", function()
		T.it("returns error on double close", function()
			local ctx = make_daemon_ctx()
			local cap, revoke = pty_mod.pty_cap(ctx)

			local worker = async.async(function()
				local handle, err = cap.spawn("echo", { args = { "x" } })
				if not handle then error("spawn failed: " .. tostring(err)) end

				local ok1, err1 = handle.close()
				T.ok(ok1, "first close succeeded: " .. tostring(err1))

				local ok2, err2 = handle.close()
				T.fail(ok2, "second close should fail")
				T.ok(err2, "error message on double close")

				return true
			end)

			local p = worker()
			local val, err = ctx.loop:run_until(p)
			T.ok(val, "async worker completed: " .. tostring(err))
			revoke()
		end)
	end)

	T.describe("revocation", function()
		T.it("blocks spawn after revoke", function()
			local ctx = make_daemon_ctx()
			local cap, revoke = pty_mod.pty_cap(ctx)

			revoke()

			local handle, err = cap.spawn("echo")
			T.fail(handle, "spawn should fail after revoke")
			T.ok(err:find("revoked"), "error mentions revoked: " .. tostring(err))
		end)

		T.it("blocks read/write after revoke", function()
			local ctx = make_daemon_ctx()
			local cap, revoke = pty_mod.pty_cap(ctx)

			local worker = async.async(function()
				local handle, err = cap.spawn("cat")
				if not handle then error("spawn failed: " .. tostring(err)) end

				revoke()

				local data, rerr = handle.read()
				T.fail(data, "read should fail after revoke")
				T.ok(rerr:find("revoked"), "read error mentions revoked")

				local n, werr = handle.write("test")
				T.fail(n, "write should fail after revoke")
				T.ok(werr:find("revoked"), "write error mentions revoked")

				return true
			end)

			local p = worker()
			local val, err = ctx.loop:run_until(p)
			T.ok(val, "async worker completed: " .. tostring(err))
		end)
	end)

	T.describe("requires daemon_ctx", function()
		T.it("returns error without daemon_ctx", function()
			local cap, err = pty_mod.pty_cap(nil)
			T.fail(cap, "should fail without daemon_ctx")
			T.ok(err, "error message returned")
		end)
	end)
end)
