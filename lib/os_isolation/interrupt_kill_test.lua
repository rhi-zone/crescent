-- lib/os_isolation/interrupt_kill_test.lua

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local interrupt_kill = require("lib.os_isolation.interrupt_kill")
local fork_direct = require("lib.os_isolation.fork_direct")

T.describe("interrupt_kill.kill / is_alive", function()
	T.it("actually stops a real child running an unconditional infinite loop", function()
		local h = fork_direct.spawn(function()
			local i = 0
			while true do i = i + 1 end
		end, {})

		-- The pre-kill assertion runs inside a nested pcall so a failure
		-- here still falls through to kill()/join() below. T.it wraps the
		-- whole test body in its own pcall ("failures are caught and
		-- recorded; subsequent it() blocks run" -- lib/test/assert.lua) --
		-- without this inner guard, a failure here would skip straight past
		-- the kill and leak this child as a permanent orphan: reparented to
		-- init on the worker's exit, spinning at ~100% CPU with nothing
		-- left to stop it, and indistinguishable in `ps`/`/proc` from a
		-- live worker since it never execs (COW fork_direct child, same
		-- cmdline as the parent). Reproduced directly: a parent that exits
		-- without join()/kill() leaves exactly this orphan behind. This is
		-- the confirmed root cause of the "unstraced 99%-cpu worker"
		-- investigation -- see TODO.md.
		local pre_ok, pre_err = pcall(T.ok, interrupt_kill.is_alive(h.pid))

		local ok, err = interrupt_kill.kill(h.pid)
		T.ok(ok, err)

		-- Reap via join() -- the child never got to write a result, since
		-- SIGKILL is unconditional and gives it no chance to run its
		-- pcall's normal exit path.
		local jok, jerr = h.join()
		T.fail(jok)
		T.ok(jerr:find("no output"))

		if not pre_ok then error(pre_err, 0) end
	end)

	T.it("is_alive returns false for a pid that has been killed AND reaped", function()
		local h = fork_direct.spawn(function() return 1 end, {})
		h.join() -- normal exit, reaps the pid
		T.eq(interrupt_kill.is_alive(h.pid), false)
	end)

	T.it("kill() on an already-dead, unreaped pid still succeeds (zombies are signalable)", function()
		local h = fork_direct.spawn(function() return 1 end, {})
		-- give the child a moment to exit on its own before join() reaps it
		os.execute("sleep 0.05")
		local ok = interrupt_kill.kill(h.pid) -- zombie: kill() still returns success
		T.ok(ok)
		h.join()
	end)
end)
