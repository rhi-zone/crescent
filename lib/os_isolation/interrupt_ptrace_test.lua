-- lib/os_isolation/interrupt_ptrace_test.lua

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local interrupt_ptrace = require("lib.os_isolation.interrupt_ptrace")
local interrupt_kill = require("lib.os_isolation.interrupt_kill")
local fork_direct = require("lib.os_isolation.fork_direct")
local thread = require("lib.os_isolation.thread")

T.describe("interrupt_ptrace.available", function()
	T.it("reports true on Linux, (nil, errmsg) elsewhere -- never throws either way", function()
		local ok, err = interrupt_ptrace.available()
		if ok then
			T.eq(ok, true)
		else
			T.ok(type(err) == "string")
		end
	end)
end)

T.describe("interrupt_ptrace against a real child process (fork_direct)", function()
	T.it("suspends and resumes a running child without killing it", function()
		if not interrupt_ptrace.available() then
			T.skip("ptrace unavailable on this platform")
		end
		local h = fork_direct.spawn(function()
			local i = 0
			while true do i = i + 1 end
		end, {})

		-- Everything that can fail runs inside a nested pcall so the
		-- unconditional cleanup below still runs on assertion failure. This
		-- child is a real busy loop with nothing else to stop it -- T.it's
		-- own pcall ("failures are caught and recorded; subsequent it()
		-- blocks run") would otherwise skip straight past kill()/join() and
		-- leak it as a permanent orphan, reparented to init, spinning at
		-- ~100% CPU, indistinguishable in `ps` from a live worker (COW
		-- fork_direct child, never execs, same cmdline as the parent).
		-- Reproduced directly; this is the confirmed root cause of the
		-- "unstraced 99%-cpu worker" investigation -- see TODO.md.
		local ok, err = pcall(function()
			local sok, serr = interrupt_ptrace.suspend(h.pid)
			T.ok(sok, serr)
			T.ok(interrupt_kill.is_alive(h.pid)) -- suspended, not killed

			local rok, rerr = interrupt_ptrace.resume(h.pid)
			T.ok(rok, rerr)
		end)

		-- clean up: this child never exits on its own
		interrupt_kill.kill(h.pid)
		h.join()

		if not ok then error(err, 0) end
	end)

	T.it("suspend() on a nonexistent pid fails, not throws", function()
		if not interrupt_ptrace.available() then
			T.skip("ptrace unavailable on this platform")
		end
		-- an implausibly large pid, essentially guaranteed not to exist
		local ok, err = interrupt_ptrace.suspend(2000000000)
		T.fail(ok)
		T.ok(type(err) == "string")
	end)
end)

T.describe("interrupt_ptrace against a thread.lua unit's tid", function()
	T.it("fails with EPERM, deterministically -- not a skip-worthy environment quirk (see interrupt_ptrace.lua's module header: Linux's kernel/ptrace.c ptrace_attach() unconditionally refuses same-thread-group self-attach, verified via kernel source + a bare-C repro, independent of privilege/Yama/capabilities)", function()
		if not interrupt_ptrace.available() then
			T.skip("ptrace unavailable on this platform")
		end
		-- Bounded busy work (not an infinite loop): thread.lua has no
		-- forced-terminate mechanism, so a test target must finish on its
		-- own for join() to return; suspend/resume is exercised mid-flight
		-- via a short busy-wait before the child does its real work. Budget
		-- is deliberately modest (not hundreds of millions of iterations):
		-- under concurrent load (this test suite's own other processes
		-- competing for CPU) a huge fixed iteration count can legitimately
		-- take far longer than any reasonable poll window, which showed up
		-- during development as an apparent "hang" that was actually pure
		-- CPU-contention slowness, not a defect in thread.lua's mechanism
		-- -- confirmed by running the identical spawn/join in isolation
		-- (consistently sub-second) versus 8-way parallel (5/8 needed well
		-- over 10s of wall clock for the same iteration count). A modest
		-- budget keeps this test's own timing assumptions honest.
		local h = thread.spawn([[
			local budget = 30000000
			local i = 0
			while i < budget do i = i + 1 end
			return "done"
		]])

		-- Poll for the child to report its tid. This is an inherently
		-- racy, best-effort synchronization (documented in thread.lua's
		-- header) -- if it doesn't show up in a generous window, skip
		-- rather than fail: that outcome means this particular run didn't
		-- get to exercise the suspend/resume path in time, not that
		-- anything is broken (thread.spawn/join correctness is covered,
		-- without any timing dependency, in thread_test.lua).
		local tid
		for _ = 1, 100 do
			tid = h.tid()
			if tid then break end
			local t0 = os.clock()
			while os.clock() - t0 < 0.02 do end
		end
		if not tid then
			h.join()
			T.skip("child did not report a tid within the poll window (likely CPU contention from concurrent tests, not a defect -- see comment above)")
		end

		local sok, serr = interrupt_ptrace.suspend(tid)
		if not sok and serr and serr:find("errno 3 ") then
			-- ESRCH ("No such process"): the busy-work thread finished (and
			-- its tid became invalid) between h.tid() reporting it and this
			-- suspend() call -- a benign timing race in THIS TEST's margin,
			-- not a defect in interrupt_ptrace.lua (which correctly reports
			-- the syscall failure rather than hanging or corrupting state).
			h.join()
			T.skip("target thread finished before suspend() reached it (benign timing race, not a defect)")
		end
		-- EXPECTED, DETERMINISTIC OUTCOME: EPERM, always, on every Linux
		-- kernel and every privilege level -- not an environment quirk.
		-- Linux's kernel/ptrace.c ptrace_attach() (backing both
		-- PTRACE_ATTACH and PTRACE_SEIZE) contains
		-- `if (same_thread_group(task, current)) return -EPERM;` ahead of
		-- its permission-check helper, unconditionally refusing to let one
		-- thread ptrace-attach a sibling thread in its own thread group.
		-- Root-caused via kernel source + a bare-C (no Lua/FFI) repro --
		-- see interrupt_ptrace.lua's module header for the full citation.
		-- The identical mechanism against a real fork_direct/
		-- fork_supervisor pid IS exercised and expected to SUCCEED, above.
		T.fail(sok)
		T.ok(type(serr) == "string" and serr:find("EPERM") ~= nil, serr)

		-- Nothing to resume -- suspend() never attached. Clean up by
		-- letting the busy-work thread run to completion.
		local ok, result = h.join()
		T.ok(ok)
		T.eq(result, "done")
	end)
end)
