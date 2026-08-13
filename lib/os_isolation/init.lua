-- lib/os_isolation/init.lua
-- OS-level process/thread isolation and forced interruption.
--
-- Distinct from lib/sandbox: lib/sandbox restricts what a Lua script can
-- REACH (require whitelist + curated globals) while running in the SAME OS
-- process/thread as the caller -- a capability-restriction mechanism.
-- lib/os_isolation is about a genuinely different failure domain -- fault
-- containment and hard external stop -- via OS-level boundaries (separate
-- processes, separate lua_States) that lib/sandbox cannot provide on its
-- own, since a capability restriction inside one process can neither
-- survive an FFI/C-level crash nor be forcibly halted from outside if it
-- hangs. The two compose: run lib.sandbox-restricted code INSIDE an
-- lib.os_isolation-isolated child for both properties at once.
--
-- Full sourced design reasoning: docs/genre-battery/sandboxing.md
-- ("Decided direction" section). This module implements:
--
--   Isolation (three independent implementations -- never one wrapping
--   the other, per this repo's tiering convention):
--     fork_direct     -- direct fork(), no exec(), same LuaJIT image.
--                        Cheap; requires a single-threaded caller (see that
--                        file's header for the precondition and its limits).
--     fork_supervisor -- a single-threaded supervisor process forks on the
--                        caller's behalf; safe regardless of the caller's
--                        threading, at the cost of only Lua source (not
--                        closures) crossing the boundary.
--     thread          -- separate lua_State per OS thread, same process.
--                        GC/heap separation only -- NOT fault containment
--                        (shared address space) and NOT a cheap
--                        forced-stop. Built via a pure-FFI callback
--                        pattern, no vendored C -- see that file's header
--                        for the mechanism AND for one genuinely open
--                        safety question it carries (first callback
--                        invocation happening on a foreign OS thread is
--                        exercised by real prior art, not proven safe by
--                        any primary source found -- do not read this
--                        implementation as fully vetted).
--
--   Interruption (four independent, user-selectable mechanisms):
--     interrupt_kill        -- SIGKILL. Process granularity only -- targets
--                               fork_direct/fork_supervisor pids, not a
--                               thread.lua unit (SIGKILL cannot stop one
--                               thread of a multithreaded process on
--                               Linux -- see that file's header).
--     interrupt_ptrace      -- PTRACE_SEIZE/INTERRUPT suspend-and-resume,
--                               non-destructive. Linux only. The one
--                               mechanism that can target a thread.lua
--                               unit's tid while it runs, in addition to a
--                               real pid.
--     interrupt_cooperative -- opt-in, caller-instrumented loop checks.
--                               Not a defense against a hostile script.
--
-- This module does NOT decide what code runs inside an isolated child, nor
-- what capabilities it gets -- pair fork_direct.spawn / fork_supervisor:spawn
-- / thread.spawn with lib.sandbox.env / lib.sandbox.run inside the child
-- function/code for that.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

M.fork_direct           = require("lib.os_isolation.fork_direct")
M.fork_supervisor       = require("lib.os_isolation.fork_supervisor")
M.thread                = require("lib.os_isolation.thread")
M.interrupt_kill        = require("lib.os_isolation.interrupt_kill")
M.interrupt_ptrace      = require("lib.os_isolation.interrupt_ptrace")
M.interrupt_cooperative = require("lib.os_isolation.interrupt_cooperative")

return M
