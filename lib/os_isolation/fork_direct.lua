-- lib/os_isolation/fork_direct.lua
-- Process isolation, implementation A: direct fork() from the calling
-- process, no exec() — the child stays in the same LuaJIT binary image as
-- the parent (cheap: page-table copy, COW-deferred; no dynamic-linker or
-- interpreter-startup cost per spawn, unlike fork_supervisor.lua's
-- fork()+exec() of a fresh bin/cr).
--
-- PRECONDITION (caller responsibility — this library does not and cannot
-- fully enforce it): the calling process must be single-threaded at the
-- moment spawn() runs. POSIX pthread_atfork(3): if any other thread held a
-- lock at fork time, that lock stays held forever in the child, and the
-- child is restricted to async-signal-safe calls for the rest of its life —
-- a restriction that never lifts for a fork-without-exec child. Whether a
-- given host process is single-threaded is a decision made by the code
-- embedding crescent, not something this library controls (see
-- docs/genre-battery/sandboxing.md, "Decided direction", implementation
-- (a)). On Linux, spawn() reads /proc/self/status and REFUSES to fork
-- (returns nil, errmsg) if it observes more than one thread — a real,
-- checkable safety net, but a best-effort one: a thread started between the
-- check and the fork() syscall is still a hazard this cannot see, and on
-- non-Linux platforms (no /proc) the check cannot run at all, so spawn()
-- proceeds unchecked there. The precondition is real either way.
--
-- fork()'s LuaJIT-safety is itself undocumented upstream (searched the
-- LuaJIT mailing list/issue tracker for "fork" as a syscall: zero hits —
-- silence, not endorsement; see docs/genre-battery/sandboxing.md §3). This
-- implementation carries that substrate risk; it is not a claim the risk is
-- resolved.
--
-- API:
--   fork_direct.thread_count() -> integer | nil
--     Best-effort thread count of the CALLING process (Linux only, via
--     /proc/self/status). nil means "could not determine" — treat as
--     "unknown," never as "one."
--   fork_direct.spawn(fn) -> handle | (nil, errmsg)
--     fn is called in the child with no arguments; its upvalues are already
--     present in the child via COW (no serialization needed for INPUTS).
--     handle.pid       : integer, the child's real OS pid (for
--                         interrupt_kill / interrupt_ptrace).
--     handle.join()  -> ok, result | (nil, errmsg)
--       Blocks until the child exits. `result` is fn's pcall return value,
--       round-tripped through result_codec.lua — only JSON-representable
--       OUTPUTS survive. Calling join() twice on the same handle is an
--       error (nil, errmsg): the pipe has already been drained and closed.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi = require("ffi")
local codec = require("lib.os_isolation.result_codec")

ffi.cdef[[
	int pipe(int pipefd[2]);
	int fork(void);
	int waitpid(int pid, int *status, int options);
	int close(int fd);
	ssize_t read(int fd, void *buf, size_t count);
	ssize_t write(int fd, const void *buf, size_t count);
	void _exit(int status);
	int open(const char *pathname, int flags);
]]

local O_RDONLY = 0

-- TYPECHECKER WORKAROUND: an ffi.new(...)-typed local's cdata element type
-- (e.g. so ffi.string(buf, n) resolves buf's type instead of leaving it
-- `?`) only comes out concrete file-wide once at least one UNANNOTATED
-- (inference-mode) function in this file has called an `ffi.C.*` member —
-- confirmed by minimal repro (a `--:`-annotated function whose own body is
-- the first ffi.C.* call in the file leaves that cdata `?` for the rest of
-- the file, including inside ffi.string calls in OTHER functions; an
-- earlier unannotated ffi.C caller fixes it everywhere after). The natural
-- code has no priming call — every function below would just carry its own
-- `--:` signature with no ordering dependency. TODO.md has a matching entry
-- ("os_isolation FFI cdata priming workaround"); delete `_prime` and this
-- comment once the ordering dependency is fixed upstream in the
-- typechecker.
local M = {}

local function _prime(fd)
	return ffi.C.close(fd)
end

--: () -> integer | nil
function M.thread_count()
	if ffi.os ~= "Linux" then return nil end
	local fd = ffi.C.open("/proc/self/status", O_RDONLY)
	if fd < 0 then return nil end
	local buf = ffi.new("char[8192]")
	local n = ffi.C.read(fd, buf, 8192)
	_prime(fd)
	if n <= 0 then return nil end
	local s = ffi.string(buf, n)
	local count = s:match("\nThreads:%s*(%d+)")
	if not count then return nil end
	local num = tonumber(count)
	if not num then return nil end
	return math.floor(num)
end

--: (integer) -> string
local function read_all(fd)
	local parts = {}
	local buf = ffi.new("char[65536]")
	while true do
		local n = ffi.C.read(fd, buf, 65536)
		if n <= 0 then break end
		parts[#parts + 1] = ffi.string(buf, n)
	end
	return table.concat(parts)
end

--:: ForkDirectHandle = { pid: integer, join: () -> (boolean, unknown) }

--: (unknown) -> (ForkDirectHandle | nil, string | nil)
function M.spawn(fn_)
	if type(fn_) ~= "function" then
		return nil, "fork_direct.spawn: fn must be a function"
	end
	local fn = fn_ --[[: () -> unknown]]

	local n_threads = M.thread_count()
	if n_threads and n_threads > 1 then
		return nil, "fork_direct.spawn: refusing to fork -- process has " .. n_threads
			.. " threads (fork-without-exec is only safe single-threaded; see module header)"
	end

	local fds = ffi.new("int[2]")
	if ffi.C.pipe(fds) ~= 0 then
		return nil, "fork_direct.spawn: pipe() failed"
	end

	local pid = ffi.C.fork()
	if pid < 0 then
		_prime(fds[0]); _prime(fds[1])
		return nil, "fork_direct.spawn: fork() failed"
	end

	if pid == 0 then
		-- child: run fn, write the encoded (ok, result) pair back, exit.
		-- Async-signal-safe-only territory per the precondition above --
		-- deliberately minimal work here.
		_prime(fds[0])
		local ok, result = pcall(fn)
		local payload = codec.encode(ok, result)
		local written = 0
		while written < #payload do
			local n = ffi.C.write(fds[1], payload:sub(written + 1), #payload - written)
			if n <= 0 then break end
			written = written + n
		end
		_prime(fds[1])
		ffi.C._exit(0)
	end

	-- parent
	_prime(fds[1])
	local read_fd = fds[0]
	local joined = false

	--: () -> (boolean, unknown)
	local function join()
		if joined then
			return false, "fork_direct: handle already joined"
		end
		joined = true
		local payload = read_all(read_fd)
		_prime(read_fd)
		local status = ffi.new("int[1]")
		ffi.C.waitpid(pid, status, 0)
		if payload == "" then
			return false, "fork_direct: child produced no output (killed or crashed before writing a result)"
		end
		return codec.decode(payload)
	end

	return { pid = pid, join = join } --[[: ForkDirectHandle]]
end

return M
