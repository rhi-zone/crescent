-- lib/os_isolation/interrupt_ptrace.lua
-- Interrupt mechanism B: ptrace-based process suspend/resume.
--
-- Non-destructive alternative to interrupt_kill.lua: PTRACE_SEIZE +
-- PTRACE_INTERRUPT pauses a target WITHOUT killing it (resumable via
-- PTRACE_CONT), where SIGKILL only ever terminates. Targets a pid (integer)
-- in either sense this module's siblings produce: a real CHILD PROCESS from
-- fork_direct.lua / fork_supervisor.lua, OR a Linux thread id (tid) from
-- thread.lua's handle.tid() -- a tid IS a pid from the kernel's point of
-- view, and ptrace(2)'s request constants apply to both alike. HOWEVER,
-- the two targets are NOT symmetric in practice: see "THREAD.LUA TARGETS
-- CANNOT WORK" below -- this module's coverage of thread.lua units is
-- fundamentally narrower than its header once claimed.
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
-- THREAD.LUA TARGETS CANNOT WORK -- root cause diagnosed, not environmental
-- (2026-08-14 investigation; corrects this module's original header, which
-- wrongly blamed a "container/sandbox security layer"). suspend() against a
-- thread.lua unit's own tid, called from the SAME process that spawned that
-- thread (the only way any caller could ever get that tid in the first
-- place -- thread.lua is pthread-based, in-process, not fork-based), fails
-- with EPERM UNCONDITIONALLY, on every Linux kernel, at every privilege
-- level, in every environment -- this is NOT the "container/sandbox denies
-- an otherwise-permitted case" story this module originally told.
--
-- Root cause, cited: Linux kernel/ptrace.c's ptrace_attach() (the function
-- backing BOTH PTRACE_ATTACH and PTRACE_SEIZE) contains, before it ever
-- calls the permission-check helper __ptrace_may_access():
--     if (unlikely(task->flags & PF_KTHREAD)) return -EPERM;
--     if (same_thread_group(task, current)) return -EPERM;
-- i.e. the kernel unconditionally REFUSES to let one thread ptrace-attach a
-- sibling thread in its own thread group. This is separate from, and prior
-- to, the "ptrace access mode checking" algorithm ptrace(2) describes with
-- "If the calling thread and the target thread are in the same thread
-- group, access is always allowed" -- that sentence is true, but it
-- describes __ptrace_may_access() / security_ptrace_access_check(), the
-- permission helper also used for things like /proc/<pid>/mem access; it is
-- NOT the whole story for the actual attach syscall, which has its own,
-- separate, unconditional same-thread-group rejection layered in front.
-- Verified two ways on this machine (not guessed): (1) read the actual
-- kernel source for ptrace_attach() and confirmed the same_thread_group()
-- check above; (2) reproduced empirically in bare C (no Lua/FFI involved,
-- ruling out any TID-capture bug in this repo's own code) -- a pthread
-- sibling obtained its own tid via a raw SYS_gettid syscall, and the main
-- thread's PTRACE_SEIZE against that genuine tid failed with EPERM every
-- time, with strace confirming the syscall itself (not some wrapper) is
-- what returns EPERM. A separate control reproduction confirmed
-- parent-process-vs-real-child-process ptrace (the fork_direct/
-- fork_supervisor case) succeeds with no special privilege, exactly as
-- documented below -- the failure is specific to the same-thread-group
-- case, not a general breakage of ptrace on this machine.
-- Ruled out, specifically: Yama ptrace_scope (this machine has it at `1`,
-- but same_thread_group() short-circuits ptrace_attach() before Yama's
-- LSM hook is even reached -- Yama is provably not the cause here, though
-- it separately DOES restrict the cross-process case, confirmed in the
-- same investigation); a container or seccomp filter (this shell is not
-- inside a container -- no /.dockerenv, cgroup path is the host's
-- `init.scope`, not a container cgroup -- and Seccomp: 0 in
-- /proc/self/status); a missing CAP_SYS_PTRACE (irrelevant -- the
-- unconditional check fires before any capability check); a pthread_t
-- vs. kernel-tid confusion in thread.lua's own code (checked -- thread.lua
-- already captures the real kernel tid via a raw `syscall(SYS_gettid)`,
-- not pthread_self(), so that hypothesis does not apply here; also
-- independently ruled out by the pure-C reproduction above, which used no
-- Lua/FFI code path at all and hit the identical EPERM).
-- Practical consequence: there is no configuration knob (ptrace_scope,
-- capabilities, container privilege) that makes suspend() succeed against
-- a thread.lua tid when called from that thread's own process -- it is not
-- a deployment requirement to document, it is a permanent architectural
-- dead end for this specific pairing. The only way ptrace COULD ever
-- suspend a thread.lua unit is via a genuinely separate OS process acting
-- as tracer (not the process that spawned the thread) -- which then
-- reintroduces the ordinary cross-process ptrace permission rules
-- (Yama/capabilities) this module already handles correctly for
-- fork_direct/fork_supervisor pids. That is a different architecture (a
-- dedicated tracer-process helper), not a fix to this module, and is not
-- implemented here.
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
		and " -- EPERM: two distinct causes are possible and cannot be told apart from errno alone. (1) If the target is a thread.lua tid belonging to THIS SAME PROCESS, this is unconditional and permanent: Linux's kernel/ptrace.c ptrace_attach() refuses same-thread-group self-attach outright (`if (same_thread_group(task, current)) return -EPERM;`), before any capability or LSM check runs -- no privilege, capability, or ptrace_scope setting changes this outcome; see interrupt_ptrace.lua's module header for the full citation. (2) If the target is a genuinely separate process (fork_direct/fork_supervisor pid) or a thread owned by a different process, this is the ordinary cross-process ptrace permission check, and IS environment/config-dependent: Yama's ptrace_scope (see /proc/sys/kernel/yama/ptrace_scope; 0=classic, 1=restricted-to-descendants, 2=admin-only, 3=no-attach), CAP_SYS_PTRACE, or a same-uid/parent-child relationship requirement can each cause this and can each be adjusted in deployment"
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
