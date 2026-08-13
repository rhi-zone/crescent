-- lib/os_isolation/fork_supervisor.lua
-- Process isolation, implementation B: a minimal, deliberately
-- single-threaded supervisor PROCESS (lib/os_isolation/supervisor_main.lua,
-- run via bin/cr) forks children on the caller's behalf. Sidesteps the
-- fork-without-exec multithreaded hazard documented in fork_direct.lua
-- entirely, regardless of what the CALLING process does, because the
-- supervisor's own process never has more than one thread by construction
-- -- it does nothing but a request/response loop, never creates a thread.
--
-- Trade-off vs fork_direct.lua: the supervisor is a genuinely separate OS
-- process (reached by THIS library fork()+exec()-ing bin/cr once, in
-- start()), so unlike fork_direct's child, a supervisor-spawned child does
-- NOT share the caller's in-memory Lua state via copy-on-write. Only Lua
-- SOURCE CODE (a string, compiled fresh with load() inside the child) and
-- JSON-representable args can cross the caller -> supervisor -> child
-- boundary -- arbitrary closures capturing upvalues cannot, because the
-- supervisor is a different process image entirely. Pick fork_direct when
-- the precondition (single-threaded caller) holds and closures are
-- convenient; pick fork_supervisor when the caller may be multithreaded, or
-- when spawning many children more cheaply than one exec-per-spawn matters
-- (the supervisor is exec'd once in start(), not once per spawn()).
--
-- Lifecycle (v1, deliberately simple -- not the final word on pool sizing,
-- see docs/genre-battery/sandboxing.md "still genuinely open" for what this
-- implementation resolved vs left open):
--   - One supervisor process per start() call. No pre-warmed pool, no
--     multi-supervisor scaling -- a caller wanting either builds it on top
--     by running multiple fork_supervisor instances.
--   - The supervisor's control loop is serialized one request at a time,
--     but spawn() does not block on the child finishing -- the supervisor
--     fork()s and replies immediately with the child's pid, so children
--     spawned through the same supervisor run CONCURRENTLY; only the
--     supervisor's own bookkeeping (assigning ids, issuing fork()) is
--     serial. join() blocks the control loop until that specific child
--     exits -- a caller wanting several children in flight must spawn()
--     all of them before join()-ing any of them.
--
-- API:
--   fork_supervisor.start(opts?) -> supervisor | (nil, errmsg)
--     opts.cr_path     : path to the bin/cr entry point (default "bin/cr",
--                        relative to the CALLING process's cwd -- this
--                        library does not search for it, matching every
--                        other bin/cr invocation documented in this repo's
--                        CLAUDE.md, which are all given repo-root-relative).
--     opts.script_path : path to supervisor_main.lua (default
--                        "lib/os_isolation/supervisor_main.lua", same
--                        repo-root-relative-cwd assumption).
--   supervisor.pid : integer, the supervisor process's own OS pid.
--   supervisor:spawn(code, args?) -> handle | (nil, errmsg)
--     code : Lua source (a string -- NOT a closure, see trade-off above)
--     args : JSON-representable table, passed as the loaded chunk's ...
--     handle.pid  : integer, the CHILD's real OS pid (for interrupt_kill /
--                   interrupt_ptrace -- distinct from supervisor.pid).
--     handle.id   : integer, the supervisor's bookkeeping id for join().
--     handle.join() -> ok, result | (nil, errmsg)
--   supervisor:stop() -> nil
--     Tells the supervisor process to exit. Does not kill any children
--     that are still outstanding (spawned but not joined) -- join or kill
--     them first.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi = require("ffi")
local bit = require("bit")
local json = require("lib.json")
local codec = require("lib.os_isolation.result_codec")

ffi.cdef[[
	int pipe(int pipefd[2]);
	int fork(void);
	int waitpid(int pid, int *status, int options);
	int close(int fd);
	int dup2(int oldfd, int newfd);
	ssize_t read(int fd, void *buf, size_t count);
	ssize_t write(int fd, const void *buf, size_t count);
	void _exit(int status);
	int execvp(const char *file, char *const argv[]);
]]

local M = {}
local Supervisor = {}
Supervisor.__index = Supervisor

-- TYPECHECKER WORKAROUND: same file-wide FFI-cdata-element-type ordering
-- dependency documented in fork_direct.lua. TODO.md has the matching entry.
local function _prime(fd)
	return ffi.C.close(fd)
end

--: (integer, string) -> boolean
local function write_all(fd, bytes)
	local written = 0
	while written < #bytes do
		local n = ffi.C.write(fd, bytes:sub(written + 1), #bytes - written)
		if n <= 0 then return false end
		written = written + n
	end
	return true
end

--: (integer, integer) -> string | nil
local function read_exact(fd, count)
	local parts = {}
	local remaining = count
	local buf = ffi.new("char[65536]")
	while remaining > 0 do
		local want = remaining < 65536 and remaining or 65536
		local n = ffi.C.read(fd, buf, want)
		if n <= 0 then return nil end
		parts[#parts + 1] = ffi.string(buf, n)
		remaining = remaining - n
	end
	return table.concat(parts)
end

--: (integer, string) -> boolean
local function write_frame(fd, payload)
	local len = #payload
	local header = string.char(
		bit.band(bit.rshift(len, 24), 0xff),
		bit.band(bit.rshift(len, 16), 0xff),
		bit.band(bit.rshift(len, 8), 0xff),
		bit.band(len, 0xff)
	)
	return write_all(fd, header) and write_all(fd, payload)
end

--: (integer) -> string | nil
local function read_frame(fd)
	local header = read_exact(fd, 4)
	if not header then return nil end
	local b1, b2, b3, b4 = header:byte(1, 4)
	if not b1 then return nil end
	if not b2 then return nil end
	if not b3 then return nil end
	if not b4 then return nil end
	local len = bit.bor(bit.lshift(b1, 24), bit.lshift(b2, 16), bit.lshift(b3, 8), b4)
	if len == 0 then return "" end
	return read_exact(fd, len)
end

--:: SupervisorHandle = { pid: integer, id: integer, join: () -> (boolean, unknown) }
--:: Supervisor = { pid: integer, _req_fd: integer, _resp_fd: integer, _stopped: boolean }

--: ({ cr_path?: string, script_path?: string } | nil) -> (Supervisor | nil, string | nil)
function M.start(opts)
	opts = opts or {}
	local cr_path = opts.cr_path or "bin/cr"
	local script_path = opts.script_path or "lib/os_isolation/supervisor_main.lua"

	local req_pipe = ffi.new("int[2]")   -- caller writes [1], supervisor reads [0] (its stdin)
	local resp_pipe = ffi.new("int[2]")  -- supervisor writes [1] (its stdout), caller reads [0]
	if ffi.C.pipe(req_pipe) ~= 0 then
		return nil, "fork_supervisor.start: pipe() failed"
	end
	if ffi.C.pipe(resp_pipe) ~= 0 then
		_prime(req_pipe[0]); _prime(req_pipe[1])
		return nil, "fork_supervisor.start: pipe() failed"
	end

	local pid = ffi.C.fork()
	if pid < 0 then
		_prime(req_pipe[0]); _prime(req_pipe[1])
		_prime(resp_pipe[0]); _prime(resp_pipe[1])
		return nil, "fork_supervisor.start: fork() failed"
	end

	if pid == 0 then
		-- becomes the supervisor process via exec -- this fork() is the
		-- ONE fork-without-exec this library ever does from the CALLER's
		-- process, and it happens only in start(), not per-spawn.
		_prime(req_pipe[1])
		_prime(resp_pipe[0])
		ffi.C.dup2(req_pipe[0], 0)
		ffi.C.dup2(resp_pipe[1], 1)
		_prime(req_pipe[0])
		_prime(resp_pipe[1])
		local argv = ffi.new("const char*[3]", cr_path, script_path, nil)
		ffi.C.execvp(cr_path, ffi.cast("char *const*", argv))
		ffi.C._exit(127) -- exec failed
	end

	-- caller (parent)
	_prime(req_pipe[0])
	_prime(resp_pipe[1])

	return setmetatable({
		pid       = pid,
		_req_fd   = req_pipe[1],
		_resp_fd  = resp_pipe[0],
		_stopped  = false,
	}, Supervisor)
end

--: (Supervisor, string, unknown) -> (SupervisorHandle | nil, string | nil)
function Supervisor:spawn(code, args)
	if self._stopped then
		return nil, "fork_supervisor: supervisor already stopped"
	end
	if type(code) ~= "string" then
		return nil, "fork_supervisor.spawn: code must be a string (see module header -- closures cannot cross a process boundary)"
	end
	local req = json.encode({ kind = "spawn", code = code, args = args })
	if not req then
		return nil, "fork_supervisor.spawn: could not encode request"
	end
	if not write_frame(self._req_fd, req) then
		return nil, "fork_supervisor.spawn: failed to send request to supervisor"
	end
	local resp_bytes = read_frame(self._resp_fd)
	if not resp_bytes then
		return nil, "fork_supervisor.spawn: supervisor closed the connection (died?)"
	end
	local resp_, resp_err = json.decode(resp_bytes)
	if not resp_ or type(resp_) ~= "table" then
		return nil, "fork_supervisor.spawn: malformed supervisor response: " .. tostring(resp_err)
	end
	local resp = resp_ --[[: { ok: boolean, id: integer, pid: integer, err: string } ]]
	if not resp.ok then
		return nil, resp.err or "fork_supervisor.spawn: malformed supervisor response"
	end

	local id = resp.id
	local pid = resp.pid
	local joined = false
	local sup = self

	--: () -> (boolean, unknown)
	local function join()
		if joined then
			return false, "fork_supervisor: handle already joined"
		end
		joined = true
		local jreq = json.encode({ kind = "join", id = id })
		if not jreq then
			return false, "fork_supervisor.join: could not encode join request"
		end
		if not write_frame(sup._req_fd, jreq) then
			return false, "fork_supervisor.join: failed to send join request to supervisor"
		end
		local jresp = read_frame(sup._resp_fd)
		if not jresp then
			return false, "fork_supervisor.join: supervisor closed the connection before responding"
		end
		return codec.decode(jresp)
	end

	return { pid = pid, id = id, join = join }
end

--: (Supervisor) -> nil
function Supervisor:stop()
	if self._stopped then return end
	self._stopped = true
	local req = json.encode({ kind = "stop" })
	if req then write_frame(self._req_fd, req) end
	_prime(self._req_fd)
	_prime(self._resp_fd)
	local status = ffi.new("int[1]")
	ffi.C.waitpid(self.pid, status, 0)
end

return M
