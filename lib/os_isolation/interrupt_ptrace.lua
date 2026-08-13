-- lib/os_isolation/interrupt_ptrace.lua
-- Interrupt mechanism B: ptrace-based process suspend/resume.
--
-- Non-destructive alternative to interrupt_kill.lua: PTRACE_SEIZE +
-- PTRACE_INTERRUPT pauses a target WITHOUT killing it (resumable via
-- PTRACE_CONT), where SIGKILL only ever terminates. Targets a pid (integer)
-- in either sense this module's siblings produce: a real CHILD PROCESS from
-- fork_direct.lua / fork_supervisor.lua, OR a Linux thread id (tid) from
-- thread.lua's handle.tid() -- ptrace(2) addresses both the same way on
-- Linux (a tid IS a pid from the kernel's point of view; self-attach from a
-- sibling thread in the same thread group is explicitly permitted per
-- ptrace(2), "If the calling thread and the target thread are in the same
-- thread group, access is always allowed"). interrupt_kill.lua's SIGKILL
-- cannot do this for a thread.lua target (SIGKILL and friends are
-- process-granularity only on Linux, per that module's header) -- this is
-- the one interrupt mechanism that actually works against a thread.lua
-- unit while it runs.
--
-- Linux-specific: ptrace(2)'s request constants and self-attach permission
-- rules are Linux uapi, not portable (e.g. macOS's ptrace has a different,
-- incompatible request enum). This module reports unavailable via
-- (nil, errmsg) rather than attempting the syscall on any non-Linux
-- platform -- per this repo's tiering convention, checked at load time via
-- M.available(), no pure-Lua fallback exists because ptrace is inherently a
-- syscall with no non-syscall equivalent.
--
-- Debugger-grade tool: only one tracer may attach to a tracee at a time --
-- suspend() fails if the target is already being traced by something else
-- (an actual debugger, strace, another interrupt_ptrace caller, etc.).
--
-- OBSERVED PLATFORM CAVEAT (found writing this module's own tests, not
-- merely theoretical): ptrace(2) documents same-thread-group self-attach as
-- "always allowed," independent of Yama's ptrace_scope. In THIS repo's own
-- sandboxed dev/CI environment, attaching to a real CHILD PROCESS (a
-- fork_direct/fork_supervisor pid) succeeds with no special privilege, but
-- attaching to a sibling THREAD's tid (a thread.lua unit) fails with EPERM
-- despite that documented exemption -- confirmed via errno, not assumed.
-- The container/sandbox's security layering (Yama, seccomp, or a stripped
-- effective capability set -- CapEff was observed all-zero even though
-- CapBnd listed cap_sys_ptrace) is evidently stricter here than bare
-- ptrace(2) semantics promise. Treat "PTRACE against a thread.lua unit
-- works" as environment-dependent, not guaranteed by this module alone --
-- suspend()/resume()/detach() report the errno and, specifically for EPERM,
-- a one-line note pointing at this caveat rather than a bare "failed."
--
-- API:
--   interrupt_ptrace.available() -> true | (nil, errmsg)
--     Load-time-computed tier probe. False/errmsg on non-Linux, or if the
--     ptrace() symbol could not be bound.
--   interrupt_ptrace.suspend(pid) -> true | (nil, errmsg)
--     PTRACE_SEIZE then PTRACE_INTERRUPT. Target must be a process this
--     caller is permitted to trace (child of the caller, or same-uid with
--     ptrace_scope permitting it -- see ptrace(2) "Ptrace access mode
--     checking").
--   interrupt_ptrace.resume(pid) -> true | (nil, errmsg)
--     PTRACE_CONT -- target continues running, still attached.
--   interrupt_ptrace.detach(pid) -> true | (nil, errmsg)
--     PTRACE_DETACH -- target continues running, no longer attached (a
--     later suspend() re-attaches from scratch).

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi = require("ffi")

local M = {}
M._tier = "unavailable" --[[: "ffi" | "unavailable" ]]
local _unavailable_reason = "interrupt_ptrace: not Linux (ptrace request constants are Linux-specific uapi)"

if ffi.os == "Linux" then
	local ok = pcall(function()
		ffi.cdef[[
			long ptrace(int request, int pid, void *addr, void *data);
			char *strerror(int errnum);
		]]
	end)
	if ok then
		M._tier = "ffi"
	else
		_unavailable_reason = "interrupt_ptrace: could not bind ptrace() via FFI"
	end
end

local EPERM = 1

--: (string) -> string
local function errno_suffix(action)
	local errnum = ffi.errno()
	local msg = ffi.string(ffi.C.strerror(errnum))
	local perm_note = errnum == EPERM
		and " -- EPERM: ptrace(2) documents same-thread-group self-attach as always allowed, but a container/sandbox security layer (Yama ptrace_scope, seccomp, missing CAP_SYS_PTRACE) can still deny it in practice; this is an environment permission outcome, not necessarily a bug in the caller"
		or ""
	return action .. " failed: errno " .. errnum .. " (" .. msg .. ")" .. perm_note
end

-- linux/ptrace.h request numbers -- stable across architectures for these.
local PTRACE_CONT      = 7
local PTRACE_DETACH    = 17
local PTRACE_SEIZE     = 0x4206
local PTRACE_INTERRUPT = 0x4207

--: () -> (true | nil, string | nil)
function M.available()
	if M._tier == "ffi" then return true end
	return nil, _unavailable_reason
end

--: (integer) -> (true | nil, string | nil)
function M.suspend(pid)
	local ok, err = M.available()
	if not ok then return nil, err end
	if ffi.C.ptrace(PTRACE_SEIZE, pid, nil, nil) ~= 0 then
		return nil, "interrupt_ptrace.suspend: " .. errno_suffix("PTRACE_SEIZE(" .. tostring(pid) .. ")")
	end
	if ffi.C.ptrace(PTRACE_INTERRUPT, pid, nil, nil) ~= 0 then
		return nil, "interrupt_ptrace.suspend: " .. errno_suffix("PTRACE_INTERRUPT(" .. tostring(pid) .. ")")
	end
	return true
end

--: (integer) -> (true | nil, string | nil)
function M.resume(pid)
	local ok, err = M.available()
	if not ok then return nil, err end
	if ffi.C.ptrace(PTRACE_CONT, pid, nil, nil) ~= 0 then
		return nil, "interrupt_ptrace.resume: PTRACE_CONT(" .. tostring(pid) .. ") failed"
	end
	return true
end

--: (integer) -> (true | nil, string | nil)
function M.detach(pid)
	local ok, err = M.available()
	if not ok then return nil, err end
	if ffi.C.ptrace(PTRACE_DETACH, pid, nil, nil) ~= 0 then
		return nil, "interrupt_ptrace.detach: PTRACE_DETACH(" .. tostring(pid) .. ") failed"
	end
	return true
end

return M
