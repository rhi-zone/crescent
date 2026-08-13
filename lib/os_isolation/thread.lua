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
-- docs/genre-battery/sandboxing.md). interrupt_ptrace.lua can suspend a
-- running unit by its Linux tid (see handle.tid below); interrupt_kill.lua
-- cannot -- SIGKILL is process-granularity only.
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
-- is real, exercised code -- evidence this runs, not a safety proof. This
-- module's own testing (dozens of spawn/join cycles, both trivial and
-- million-plus-iteration workloads) did not surface a crash or corruption,
-- which is also not a safety proof, only a data point. One CONCRETE
-- operational finding from that testing, distinct from the open safety
-- question above: this module's full test suite occasionally takes far
-- longer to complete than its normal sub-few-seconds run time -- most
-- reliably reproduced by running several full copies of the suite in
-- parallel (an artificial stress case), but also observed, less often, on
-- a single serial `bin/cr test` invocation. Isolated single-shot runs of
-- the individual workload each test uses (up to tens of millions of loop
-- iterations) consistently completed in well under a second on their own;
-- the slowdowns showed up specifically when running the FULL suite (many
-- spawn()s across many test files), which points at ordinary CPU
-- contention across many concurrently forked processes and pthreads rather
-- than a hang in the mechanism itself -- but this is circumstantial timing
-- evidence, not a proof.
-- Not confirmed as CPU contention beyond this circumstantial timing
-- evidence; also not ruled out as something worse. A caller running many
-- thread.lua units concurrently under heavy system load should not assume
-- a fixed short timeout is safe. Treat this implementation as carrying a
-- genuinely open question, not as
-- fully vetted.
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
