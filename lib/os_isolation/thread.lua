-- lib/os_isolation/thread.lua
-- Isolation, implementation C: separate lua_State per OS thread, same
-- process. Each unit gets its own independent LuaJIT VM (own globals, own
-- GC heap, own package.loaded) -- NOT a lua_newthread() coroutine of a
-- shared parent, which would share the parent's GC/global_State and give no
-- real isolation. This module always calls its own top-level
-- luaL_newstate().
--
-- WHAT THIS GIVES: GC/heap separation between isolated units (one unit's
-- Lua-level state, including its module cache, cannot be reached or
-- corrupted by another). WHAT IT DOES NOT GIVE: fault containment (all
-- units share one process address space -- an FFI/C-level bug in one unit
-- can corrupt the whole process regardless of separate lua_States) or a
-- cheap forced-stop (pthread_cancel's deferred-mode cancellation points are
-- never hit by a tight compute loop with no blocking syscalls, and async
-- cancellation is documented unsafe for arbitrary code -- see
-- docs/genre-battery/sandboxing.md). interrupt_kill.lua cannot stop a unit
-- spawned here -- SIGKILL is process-granularity only. interrupt_ptrace.lua
-- ALSO cannot, despite once being documented as the mechanism that could:
-- suspending a thread by its Linux tid (handle.tid below) via ptrace, from
-- the SAME process that spawned it (the only process that ever has that
-- tid), fails with EPERM unconditionally on Linux -- the kernel's
-- ptrace_attach() hard-refuses same-thread-group self-attach regardless of
-- privilege or environment. See interrupt_ptrace.lua's module header for
-- the full root-cause citation. No interrupt mechanism in this repo can
-- force-stop a running thread.lua unit from its own process; only
-- cooperative (interrupt_cooperative.lua) or waiting for it to finish
-- (join()) are real options here.
--
-- MECHANISM (pure FFI, no vendored C shim): create a second lua_State via
-- luaL_newstate() -- an ordinary FFI call against symbols this repo's own
-- vendored LuaJIT binary already exports (verified: luaL_newstate,
-- luaL_openlibs, luaL_loadstring, lua_pcall, lua_close, lua_tonumber,
-- lua_tolstring, lua_pushlstring, lua_setfield, lua_getfield are all
-- reachable via ffi.C against bin/luajit-bin). Run a small bootstrap chunk
-- ON that new state, from the ORIGINAL (calling) thread, that builds an FFI
-- callback (ffi.cast("void *(*)(void *)", entry_fn)) -- the callback is
-- created while running Lua code that belongs to the NEW state, so it is
-- registered in that state's own callback slot table. Hand the raw function
-- pointer to pthread_create() as the thread's start routine. This is the
-- pattern LuaJIT's own author (Mike Pall) described directly for this exact
-- scenario:
--   https://www.freelists.org/post/luajit/How-a-LuaJIT-FFI-script-can-turn-itself-into-multithreaded-application
-- and that github.com/luapower/pthread + github.com/luapower/luastate
-- implement as real, running code -- also pure FFI, no vendored C. Neither
-- LuaJIT's ext_ffi_semantics.html / ext_ffi_api.html nor lj_ccallback.c
-- states a "callback can only be invoked by its creating OS thread"
-- restriction; that premise, assumed earlier in this module's design, does
-- not hold.
--
-- OPEN SAFETY QUESTION -- read before relying on this in production (also
-- recorded in docs/genre-battery/sandboxing.md, not just here): the
-- callback's FIRST invocation happens on the brand-new pthread, a thread
-- LuaJIT's own runtime has never seen before, executing a trampoline that
-- was generated while running on a DIFFERENT OS thread (the caller's). No
-- primary source found (not the mailing list post, not the LuaJIT FFI docs,
-- not lj_ccallback.c) confirms or rules out a GC-phase or reentrancy hazard
-- specific to that first foreign-thread invocation. github.com/luapower/pthread
-- is real, exercised code -- evidence this runs, not a safety proof.
--
-- FOLLOW-UP INVESTIGATION (searched github.com/luapower/pthread's own issue
-- tracker -- empty, no relevant reports -- and LuaJIT/LuaJIT's issue tracker
-- directly, not just the one old mailing-list thread): found a REAL, CONFIRMED,
-- FIXED bug in exactly this category -- LuaJIT/LuaJIT#1498, "FFI callback
-- invoked from C leaves cur_L stale -- crash in lj_trace_exit when the
-- compiled callback takes a trace exit" (filed 2026-07-31, fixed 2026-08-01,
-- commit 4886b676a698acc4bbdf54adfabb3e33a8c020e8). Its precondition: an
-- FFI-cast Lua function invoked from C with no active Lua VM frame on the C
-- stack, where the callback's own state (cts->L) differs from global_State's
-- cur_L (which tracks "last thread that entered the VM" and is NOT updated
-- by the FFI callback entry path) -- concretely, this arises when one
-- global_State is shared by multiple coroutines/threads and the FFI callback
-- fires on one that isn't the one cur_L currently points to; a subsequent
-- JIT-compiled trace exit inside the callback then restores state against
-- the WRONG lua_State, segfaulting (if its cframe is NULL) or silently
-- corrupting an unrelated thread's stack (if not). This is a structurally
-- close cousin of this module's mechanism (an FFI callback invoked with no
-- Lua frame active, on a thread the VM didn't just enter through) -- but
-- ANALYSIS OF THIS MODULE'S OWN SHAPE (not the upstream fix) shows the
-- precondition does not arise here: each spawn() creates its OWN independent
-- global_State via its own luaL_newstate() call (never shared with another
-- spawn(), never given coroutines by this module), and the bootstrap chunk's
-- synchronous lua_pcall (line ~249, run on the CALLING thread before
-- pthread_create) already sets that global_State's cur_L to this L before
-- the new pthread is even created -- so when the callback fires for the
-- first (and only) time on the new pthread, cur_L already correctly points
-- at the only lua_State that global_State has ever had. This reasoning does
-- NOT rule out every possible hazard (in particular: it does not by itself
-- cover #1506, "`store to dead GC object` in FFI callback", still OPEN
-- upstream as of 2026-08-14 -- a callback-anchoring/GC-liveness issue, a
-- different mechanism than #1498's cur_L staleness, not analyzed here in the
-- same depth) -- but it is a concrete, source-grounded reason the SPECIFIC
-- known bug closest to this module's pattern does not apply to this
-- module's specific code shape, not just an absence of evidence either way.
--
-- ACTIONABLE, NOT YET DONE: this repo's own vendored LuaJIT binary
-- (bin/luajit-bin, built by .github/workflows/build-vendored.yml tracking
-- the v2.1 branch, last updated 2026-07-25 per commit c651bc4e) PREDATES the
-- #1498 fix (merged 2026-08-01) by about a week. Re-running that workflow
-- would pick up the fix (and whatever else landed on v2.1 since), which is a
-- straightforwardly good idea given how close #1498 sits to this module's
-- mechanism -- but that workflow re-vendors LuaJIT + sqlite3 + zlib +
-- libressl + wepoll together across every platform this repo supports, a
-- repo-wide infrastructure change outside this module's scope to trigger
-- unilaterally. Left as an explicit recommendation, not done as part of this
-- investigation.
--
-- EMPIRICAL: lib/os_isolation/thread_stress_test.lua is a permanent
-- regression test (not a throwaway script) built specifically to exercise
-- this hazard -- concurrent spawns under deliberate GC pressure on BOTH the
-- parent and child sides, asserting exact per-thread result correctness (so
-- cross-thread corruption would show up as a wrong value, not require a
-- crash to notice). Beyond that file's own runs, this investigation ran it
-- repeatedly by hand (20 serial invocations, 8 parallel invocations of the
-- 40-thread-concurrent + 60-serial-cycle suite; plus a one-off heavier
-- variant, 150 concurrently spawned threads under GC pressure, run singly
-- and as 6 parallel copies) -- combined, several thousand additional
-- spawn/join cycles under deliberate concurrent GC pressure this session,
-- on top of this module's earlier "dozens of spawn/join cycles, trivial to
-- 200M+ loop iterations" testing. Zero crashes, zero corruption, zero wrong
-- results, in any run. This is still not a safety proof (absence of a crash
-- in N runs never is), but it is real adversarial exercise of the exact
-- mechanism, not merely "nobody has written about this."
--
-- The full-test-suite occasional-slowdown finding from earlier testing (see
-- prior revision of this comment) was NOT reproduced by the additional
-- parallel runs above -- a further data point against it being the hazard
-- this section is about, but not a resolution: it was observed rarely
-- before, so a handful of clean parallel runs now doesn't rule it back in
-- or out. Treat this implementation as carrying a genuinely open question,
-- narrowed by the above but not closed, not as fully vetted.
--
-- Only Lua SOURCE CODE (a string) and JSON-representable args cross into
-- the new state -- like fork_supervisor.lua and unlike fork_direct.lua, a
-- fresh lua_State has no access to the caller's closures/upvalues.
--
-- API:
--   thread.spawn(code, args?) -> handle | (nil, errmsg)
--     code : Lua source, compiled fresh with load() inside the new state.
--     args : JSON-representable value, passed as the loaded chunk's ...
--   handle.tid  : integer | nil -- the child's Linux thread id (gettid()),
--                 written by the child itself as its first action, for
--                 interrupt_ptrace.lua targeting. Best-effort: written with
--                 a plain (non-atomic) word store from the child thread and
--                 read with a plain load from the caller -- there is a real
--                 but narrow window where a caller reads it before the
--                 child has written it (handle.tid is nil until then).
--                 Linux only; nil on every other platform.
--   handle.join() -> ok, result | (nil, errmsg)
--     Blocks (pthread_join) until the child returns, then reads its
--     result_codec-shaped JSON back off the child lua_State's own stack --
--     safe to do from the caller thread at this point because pthread_join
--     establishes a happens-before edge; no concurrent access to the child
--     state occurs after it returns. Closes the child lua_State.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi = require("ffi")
local json = require("lib.json")
local codec = require("lib.os_isolation.result_codec")

ffi.cdef[[
	typedef struct lua_State lua_State;
	typedef unsigned long pthread_t;
	lua_State *luaL_newstate(void);
	void luaL_openlibs(lua_State *L);
	int luaL_loadstring(lua_State *L, const char *s);
	int lua_pcall(lua_State *L, int nargs, int nresults, int errfunc);
	void lua_close(lua_State *L);
	double lua_tonumber(lua_State *L, int idx);
	const char *lua_tolstring(lua_State *L, int idx, size_t *len);
	void lua_pushlstring(lua_State *L, const char *s, size_t len);
	void lua_setfield(lua_State *L, int idx, const char *k);
	void lua_getfield(lua_State *L, int idx, const char *k);
	int pthread_create(pthread_t *thread, void *attr, void *(*start_routine)(void *), void *arg);
	int pthread_join(pthread_t thread, void **retval);
]]

local LUA_GLOBALSINDEX = -10002

local M = {}

-- TYPECHECKER WORKAROUND: same file-wide FFI-cdata-element-type ordering
-- dependency documented in fork_direct.lua -- an unannotated ffi.C caller
-- must appear before any `--:`-annotated function that will end up passing
-- ffi.new(...)-typed cdata into ffi.string/ffi.cast, or that cdata resolves
-- `?` for the rest of the file. TODO.md has the matching entry shared with
-- fork_direct.lua's identical workaround.
local function _prime(L)
	return ffi.C.lua_close(L)
end

-- Bootstrap chunk run ON the new lua_State, FROM the calling thread (this
-- is an ordinary synchronous lua_pcall -- nothing about building the
-- callback itself happens on the new pthread). It reads __CODE / __ARGS_JSON
-- (pushed as globals on the new state before this runs), builds the actual
-- work into an FFI callback, and returns the callback's address as a Lua
-- number so the caller can hand it to pthread_create. The __TID_BUF global
-- carries the raw address of a shared int[1] the caller allocated, so the
-- FIRST thing the callback does on the new pthread is report its own
-- gettid() into it (see module header: best-effort, not synchronized).
local BOOTSTRAP = [==[
	-- Unconditional, not the usual repo-wide "already present?" guard: this
	-- runs in a lua_State this module JUST created via luaL_newstate(), which
	-- starts from LuaJIT's stock compiled-in default package.path -- NOT
	-- bin/cr's customized one (that customization happens in cr.lua, which
	-- only ever runs in the CALLING lua_State, never propagates to a fresh
	-- luaL_newstate()). The repo-wide guard idiom (`if not
	-- package.path:find("?/init.lua", ...)`) is unsafe here specifically:
	-- LuaJIT's own stock default already contains a literal
	-- "/usr/local/share/lua/5.1/?/init.lua" entry, which matches that same
	-- find() check by coincidence, so the guard wrongly concludes "already
	-- set up" and skips adding the repo-relative entry that's actually
	-- needed -- confirmed by reproduction: require("lib.json") inside this
	-- bootstrap failed with exactly the stock search path list, no
	-- repo-relative entries, when the guarded form was used. Since this
	-- lua_State is always pristine (created fresh, this bootstrap runs on it
	-- exactly once), an unconditional prepend is correct and simpler than a
	-- guard that would need a different, state-specific marker.
	package.path = "./?/init.lua;" .. package.path
	local ffi = require("ffi")
	local json = require("lib.json")
	ffi.cdef[[
		long syscall(long number, ...);
	]]

	local SYS_GETTID = ({ x64 = 186, arm64 = 178 })[jit.arch]

	local function entry()
		if SYS_GETTID and __TID_BUF_ADDR and __TID_BUF_ADDR ~= 0 then
			local ok_tid = pcall(function()
				local buf = ffi.cast("int *", ffi.cast("intptr_t", __TID_BUF_ADDR))
				buf[0] = tonumber(ffi.C.syscall(SYS_GETTID))
			end)
		end
		local ok, result = pcall(function()
			local args = __ARGS_JSON and __ARGS_JSON ~= "" and json.decode(__ARGS_JSON) or nil
			local fn, load_err = load(__CODE, "@os_isolation_thread_child")
			if not fn then error("os_isolation.thread: load() failed: " .. tostring(load_err)) end
			return fn(args)
		end)
		local payload
		if ok then
			local encoded = json.encode({ ok = true, result = result })
			payload = encoded or json.encode({ ok = false, err = "os_isolation.thread: could not encode result" })
		else
			payload = json.encode({ ok = false, err = tostring(result) })
		end
		__RESULT_JSON = payload
	end

	local cb = ffi.cast("void *(*)(void *)", entry)
	return tonumber(ffi.cast("intptr_t", cb))
]==]

--:: ThreadHandle = { tid: () -> (integer | nil), join: () -> (boolean, unknown) }

--: (unknown, unknown) -> (ThreadHandle | nil, string | nil)
function M.spawn(code_, args)
	if type(code_) ~= "string" then
		return nil, "thread.spawn: code must be a string (see module header -- closures cannot cross into a fresh lua_State)"
	end
	local code = code_ --[[: string]]

	local L = ffi.C.luaL_newstate()
	if L == nil then
		return nil, "thread.spawn: luaL_newstate() failed"
	end
	ffi.C.luaL_openlibs(L)

	ffi.C.lua_pushlstring(L, code, #code)
	ffi.C.lua_setfield(L, LUA_GLOBALSINDEX, "__CODE")

	local args_json = ""
	if args ~= nil then
		local encoded, err = json.encode(args)
		if not encoded then
			_prime(L)
			return nil, "thread.spawn: could not encode args: " .. tostring(err)
		end
		args_json = encoded
	end
	ffi.C.lua_pushlstring(L, args_json, #args_json)
	ffi.C.lua_setfield(L, LUA_GLOBALSINDEX, "__ARGS_JSON")

	local tid_buf = ffi.new("int[1]", -1) -- -1 until the child reports itself
	local tid_addr = tostring(tonumber(ffi.cast("intptr_t", tid_buf)))
	ffi.C.lua_pushlstring(L, tid_addr, #tid_addr)
	ffi.C.lua_setfield(L, LUA_GLOBALSINDEX, "__TID_BUF_ADDR_STR")
	-- __TID_BUF_ADDR_STR crosses as a string (Lua numbers round-trip losslessly
	-- as decimal only up to 2^53; a pointer address fits, but string is exact
	-- either way) -- converted back to a number by a one-line prelude appended
	-- to BOOTSTRAP below, since the raw literal must exist as a real Lua value
	-- inside the new state, not just as text substituted into BOOTSTRAP's source
	-- (substituting an address into a Lua source string egested via tostring()
	-- introduces no correctness cost here, but keeping it a pushed global,
	-- as with __CODE/__ARGS_JSON, keeps the crossing mechanism uniform).
	local full_bootstrap = "__TID_BUF_ADDR = tonumber(__TID_BUF_ADDR_STR)\n" .. BOOTSTRAP

	if ffi.C.luaL_loadstring(L, full_bootstrap) ~= 0 then
		local len = ffi.new("size_t[1]")
		local msg = ffi.string(ffi.C.lua_tolstring(L, -1, len), tonumber(len[0]))
		_prime(L)
		return nil, "thread.spawn: bootstrap load() failed: " .. msg
	end
	if ffi.C.lua_pcall(L, 0, 1, 0) ~= 0 then
		local len = ffi.new("size_t[1]")
		local msg = ffi.string(ffi.C.lua_tolstring(L, -1, len), tonumber(len[0]))
		_prime(L)
		return nil, "thread.spawn: bootstrap pcall() failed: " .. msg
	end

	local ptr_num = ffi.C.lua_tonumber(L, -1)
	local fnptr = ffi.cast("void *(*)(void *)", ffi.cast("intptr_t", ptr_num))

	local thread_id = ffi.new("pthread_t[1]")
	if ffi.C.pthread_create(thread_id, nil, fnptr, nil) ~= 0 then
		_prime(L)
		return nil, "thread.spawn: pthread_create() failed"
	end

	local joined = false

	--: () -> integer | nil
	local function tid()
		local v = tid_buf[0]
		if not v or v < 0 then return nil end
		return v
	end

	--: () -> (boolean, unknown)
	local function join()
		if joined then
			return false, "thread: handle already joined"
		end
		joined = true
		ffi.C.pthread_join(thread_id[0], nil)
		-- Safe from here on: pthread_join establishes happens-before, the
		-- child thread is done, no concurrent access to L remains.
		ffi.C.lua_getfield(L, LUA_GLOBALSINDEX, "__RESULT_JSON")
		local len = ffi.new("size_t[1]")
		local cstr = ffi.C.lua_tolstring(L, -1, len)
		local payload = cstr ~= nil and ffi.string(cstr, tonumber(len[0])) or ""
		_prime(L)
		if payload == "" then
			return false, "thread: child produced no result (crashed before setting __RESULT_JSON)"
		end
		return codec.decode(payload)
	end

	return { tid = tid, join = join }
end

return M
