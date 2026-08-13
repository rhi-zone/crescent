-- lib/os_isolation/interrupt_kill.lua
-- Interrupt mechanism A: process kill (SIGKILL).
--
-- Real, kernel-enforced, unconditional -- but ONLY for genuine separate OS
-- processes (fork_direct.lua / fork_supervisor.lua child pids), never for
-- an OS thread (thread.lua units). On Linux, SIGKILL and any signal with
-- terminate/stop/continue disposition only isolate at PROCESS granularity,
-- not thread granularity (pthread_kill(3): "if the disposition of the
-- signal is 'stop', 'continue', or 'terminate', this action will affect
-- the whole process"; ptrace(2): a stopping signal to any thread of a
-- multithreaded process stops all its threads). This module targets real
-- pids only; it has nothing to offer a thread-granularity target and does
-- not pretend to -- interrupt_ptrace.lua is the mechanism that can target a
-- thread.lua unit's tid.
--
-- API:
--   interrupt_kill.kill(pid) -> true | (nil, errmsg)
--     Sends SIGKILL. Unconditional and unmaskable by the target -- there is
--     no "did it refuse" case, only "did the kill() syscall itself fail"
--     (e.g. pid does not exist, or is not a child/owned process).
--   interrupt_kill.is_alive(pid) -> boolean
--     Signal 0 probe (kill(pid, 0)): true if the process exists and is
--     signalable, false otherwise. Does not reap zombies -- pair with
--     handle.join() (fork_direct/fork_supervisor) to reap.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi = require("ffi")

ffi.cdef[[
	int kill(int pid, int sig);
]]

local SIGKILL = 9

local M = {}

--: (integer) -> (true | nil, string | nil)
function M.kill(pid)
	if ffi.C.kill(pid, SIGKILL) ~= 0 then
		return nil, "interrupt_kill.kill: kill(" .. tostring(pid) .. ", SIGKILL) failed"
	end
	return true
end

--: (integer) -> boolean
function M.is_alive(pid)
	return ffi.C.kill(pid, 0) == 0
end

return M
