-- lib/os_isolation/supervisor_main.lua
-- Entry point for the supervisor PROCESS spawned by fork_supervisor.lua's
-- start() -- run via `bin/cr lib/os_isolation/supervisor_main.lua`, never
-- required as a library. This is the trusted host-side infrastructure
-- process itself, not sandboxed content, so it talks to its stdin/stdout
-- fds directly via the same raw FFI read/write primitives fork_direct.lua
-- uses (kept consistent rather than mixing in buffered io.*).
--
-- Deliberately does nothing but this single-threaded request/response loop
-- -- that is the entire safety property fork_supervisor.lua relies on (a
-- process that never creates a second thread can never hit the
-- fork-without-exec multithreaded hazard documented in fork_direct.lua).
-- Do not add any other work to this file.
--
-- Wire protocol (both directions): 4-byte big-endian length prefix, then
-- that many bytes of JSON. Requests arrive on fd 0, responses go to fd 1.
--
--   {kind="spawn", code=<string>, args=<table|nil>}
--     -> fork()s a child (this process is single-threaded, so this fork is
--        exactly as safe as fork_direct.lua's precondition requires). The
--        child does NOT inherit the parent CALLER's Lua state -- only
--        `code` (compiled fresh via load()) and `args` (already
--        JSON-round-tripped to get here) are available to it. Child writes
--        its result_codec-encoded (ok, result) pair to a dedicated pipe and
--        exits; the supervisor does not wait for it here.
--     <- {ok=true, id=<integer>, pid=<integer>} | {ok=false, err=<string>}
--
--   {kind="join", id=<integer>}
--     -> blocks (waitpid) until that child exits, then reads its pipe to
--        EOF and relays the bytes verbatim as the response body -- the
--        supervisor does not decode/re-encode the child's result, so
--        result_codec's shape only needs to be understood by fork_direct's
--        child-side encoder and the caller's decoder, not by this file.
--     <- the child's raw result_codec payload, or
--        {ok=false, err=<string>} if `id` is unknown or already joined.
--
--   {kind="stop"}
--     -> no response; the loop exits and this process terminates. Any
--        outstanding (spawned-but-not-joined) children are NOT killed --
--        the caller must join or kill them first via interrupt_kill.lua.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi = require("ffi")
local json = require("lib.json")
local bit = require("bit")

ffi.cdef[[
	int pipe(int pipefd[2]);
	int fork(void);
	int waitpid(int pid, int *status, int options);
	int close(int fd);
	ssize_t read(int fd, void *buf, size_t count);
	ssize_t write(int fd, const void *buf, size_t count);
	void _exit(int status);
]]

-- TYPECHECKER WORKAROUND: same file-wide FFI-cdata-element-type ordering
-- dependency documented in fork_direct.lua. TODO.md has the matching entry.
local function _prime(fd)
	return ffi.C.close(fd)
end

local ENCODE_FAILURE_FALLBACK = '{"ok":false,"err":"supervisor_main: could not encode response"}'

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

--: (integer) -> string
local function read_all_to_eof(fd)
	local parts = {}
	local buf = ffi.new("char[65536]")
	while true do
		local n = ffi.C.read(fd, buf, 65536)
		if n <= 0 then break end
		parts[#parts + 1] = ffi.string(buf, n)
	end
	return table.concat(parts)
end

--:: ChildRecord = { pid: integer, read_fd: integer }
--:: SupervisorRequest = { kind: string, code?: string, args?: unknown, id?: integer }

local children = {} --[[: { [integer]: ChildRecord | nil } ]]
local next_id = 1

--: (boolean, unknown) -> string
local function child_payload(ok, result)
	if not ok then
		local encoded = json.encode({ ok = false, err = tostring(result) })
		return encoded or ENCODE_FAILURE_FALLBACK
	end
	local encoded = json.encode({ ok = true, result = result })
	if encoded then return encoded end
	local err_encoded = json.encode({ ok = false, err = "supervisor_main: could not encode child result" })
	return err_encoded or ENCODE_FAILURE_FALLBACK
end

--: (SupervisorRequest) -> string
local function handle_spawn(req)
	local code = req.code
	if type(code) ~= "string" then
		local encoded = json.encode({ ok = false, err = "supervisor_main: spawn requires a string `code`" })
		return encoded or ENCODE_FAILURE_FALLBACK
	end
	local fds = ffi.new("int[2]")
	if ffi.C.pipe(fds) ~= 0 then
		local encoded = json.encode({ ok = false, err = "supervisor_main: pipe() failed" })
		return encoded or ENCODE_FAILURE_FALLBACK
	end
	local pid = ffi.C.fork()
	if pid < 0 then
		_prime(fds[0]); _prime(fds[1])
		local encoded = json.encode({ ok = false, err = "supervisor_main: fork() failed" })
		return encoded or ENCODE_FAILURE_FALLBACK
	end
	if pid == 0 then
		_prime(fds[0])
		local fn, load_err = load(code, "@os_isolation_supervisor_child")
		local ok, result
		if not fn then
			ok, result = false, "supervisor_main: load() failed: " .. tostring(load_err)
		else
			local real_fn = fn
			ok, result = pcall(function() return real_fn(req.args) end)
		end
		write_all(fds[1], child_payload(ok, result))
		_prime(fds[1])
		ffi.C._exit(0)
	end
	_prime(fds[1])
	local id = next_id
	next_id = next_id + 1
	children[id] = { pid = pid, read_fd = fds[0] }
	local encoded = json.encode({ ok = true, id = id, pid = pid })
	return encoded or ENCODE_FAILURE_FALLBACK
end

--: (SupervisorRequest) -> string
local function handle_join(req)
	local child_id = req.id
	if not child_id then
		local encoded = json.encode({ ok = false, err = "supervisor_main: join requires an integer `id`" })
		return encoded or ENCODE_FAILURE_FALLBACK
	end
	local rec = children[child_id]
	if not rec then
		local encoded = json.encode({ ok = false, err = "supervisor_main: unknown or already-joined id " .. tostring(child_id) })
		return encoded or ENCODE_FAILURE_FALLBACK
	end
	children[child_id] = nil
	local payload = read_all_to_eof(rec.read_fd)
	_prime(rec.read_fd)
	local status = ffi.new("int[1]")
	ffi.C.waitpid(rec.pid, status, 0)
	if payload == "" then
		local encoded = json.encode({ ok = false, err = "supervisor_main: child produced no output (killed or crashed)" })
		return encoded or ENCODE_FAILURE_FALLBACK
	end
	return payload
end

-- Single-threaded request/response loop. This is the whole program.
while true do
	local req_bytes = read_frame(0)
	if not req_bytes then break end -- caller closed the pipe: exit
	local req_, req_err = json.decode(req_bytes)
	if not req_ or type(req_) ~= "table" then
		local encoded = json.encode({ ok = false, err = "supervisor_main: malformed request: " .. tostring(req_err) })
		write_frame(1, encoded or ENCODE_FAILURE_FALLBACK)
	else
		local req = req_ --[[: SupervisorRequest]]
		if req.kind == "spawn" then
			write_frame(1, handle_spawn(req))
		elseif req.kind == "join" then
			write_frame(1, handle_join(req))
		elseif req.kind == "stop" then
			break
		else
			local encoded = json.encode({ ok = false, err = "supervisor_main: unknown kind " .. tostring(req.kind) })
			write_frame(1, encoded or ENCODE_FAILURE_FALLBACK)
		end
	end
end
