-- lib/platform/daemon/pid.lua
-- PID file management for the platform daemon.
--
-- The PID file stores three lines: `pid`, `host`, `port`. `cr open` reads it
-- to discover an already-running daemon's URL without scanning ports.
--
-- "Is the process actually alive?" check uses `kill -0 <pid>` on Unix (sends
-- signal 0, which performs the permission/existence check but delivers no
-- signal). On Windows the check is a best-effort `tasklist` query. Stale PID
-- files (process dead) are treated as absent.
--
-- This module accepts I/O via injected functions per the caps-first rule.
-- The default factory uses io/os globals for convenience; callers that need
-- a sandbox-safe variant inject their own.

local M = {}

--:: PidInfo = { pid: integer, host: string, port: integer }
--:: PidOpts = {
--::   pid_file: string,
--::   read_fn:  (string) -> (string | nil, string | nil),
--::   write_fn: (string, string) -> (true | nil, string | nil),
--::   remove_fn: (string) -> (true | nil, string | nil),
--::   alive_fn: (integer) -> boolean,
--::   mkdir_fn: (string) -> (true | nil, string | nil),
--:: }

-- Default Unix alive check: `kill -0 <pid>` (no signal sent, just permission
-- check). Returns true if process exists. On Windows, falls back to tasklist.
--: (integer) -> boolean
local function default_alive(pid)
	if package.config:sub(1, 1) == "\\" then
		-- Windows: tasklist /FI "PID eq N" — present in output means alive.
		local cmd = ('tasklist /FI "PID eq %d" /NH 2>NUL'):format(pid)
		local h = io.popen(cmd)
		if not h then return false end
		local out = h:read("*a") or ""
		h:close()
		return out:find(tostring(pid), 1, true) ~= nil
	end
	-- Use os.execute "kill -0 PID" instead of FFI signal() to stay portable.
	local r = os.execute(("kill -0 %d 2>/dev/null"):format(pid))
	-- Lua 5.1: 0 on success. Lua 5.2+: true on success.
	return r == 0 or r == true
end

--: (string) -> (string | nil, string | nil)
local function default_read(path)
	local f, err = io.open(path, "rb")
	if not f then return nil, err end
	local data = f:read("*a")
	f:close()
	if not data then return nil, "read failed" end
	return data, nil
end

--: (string, string) -> (true | nil, string | nil)
local function default_write(path, data)
	local f, err = io.open(path, "wb")
	if not f then return nil, err end
	f:write(data)
	f:close()
	return true, nil
end

--: (string) -> (true | nil, string | nil)
local function default_remove(path)
	local ok = os.remove(path)
	if not ok then return nil, "remove failed" end
	return true, nil
end

--: (string) -> (true | nil, string | nil)
local function default_mkdir(path)
	-- Quote path so spaces are safe; mkdir -p is idempotent.
	local sep = package.config:sub(1, 1)
	local cmd
	if sep == "\\" then
		cmd = ('if not exist "%s" mkdir "%s"'):format(path, path)
	else
		cmd = ('mkdir -p %q'):format(path)
	end
	local ok = os.execute(cmd)
	if ok == 0 or ok == true then return true, nil end
	return nil, "mkdir failed"
end

-- Build a pid module bound to a specific file path and I/O functions.
-- All I/O caps default to the io/os globals for convenience.
--: (PidOpts | { pid_file: string }) -> { read: () -> (PidInfo | nil, string | nil), write: (PidInfo) -> (true | nil, string | nil), clear: () -> (true | nil, string | nil) }
function M.make(opts)
	local pid_file = opts.pid_file
	local read_fn   = opts.read_fn   or default_read
	local write_fn  = opts.write_fn  or default_write
	local remove_fn = opts.remove_fn or default_remove
	local alive_fn  = opts.alive_fn  or default_alive
	local mkdir_fn  = opts.mkdir_fn  or default_mkdir

	local self = {}

	--- Read the PID file. Returns nil + reason if absent, malformed, or
	--- the process is no longer alive (stale).
	--: () -> (PidInfo | nil, string | nil)
	function self.read()
		local data, err = read_fn(pid_file)
		if not data then return nil, err end
		local lines = {} --: { [integer]: string }
		for line in (data .. "\n"):gmatch("([^\n]*)\n") do
			if line ~= "" then lines[#lines + 1] = line end
		end
		if #lines < 3 then return nil, "malformed pid file" end
		local pid  = tonumber(lines[1])
		local host = lines[2]
		local port = tonumber(lines[3])
		if not pid or not port or not host then
			return nil, "malformed pid/port"
		end
		if not alive_fn(math.floor(pid)) then return nil, "stale pid" end
		local info = {
			pid  = math.floor(pid),
			host = host,
			port = math.floor(port),
		} --: PidInfo
		return info, nil
	end

	--- Write the PID file. Creates the parent directory.
	--: (PidInfo) -> (true | nil, string | nil)
	function self.write(info)
		local dir = pid_file:match("^(.*)[/\\][^/\\]+$")
		if dir then
			local ok, derr = mkdir_fn(dir)
			if not ok then return nil, derr end
		end
		local body = tostring(info.pid) .. "\n"
			.. info.host .. "\n"
			.. tostring(info.port) .. "\n"
		return write_fn(pid_file, body)
	end

	--- Remove the PID file. Idempotent.
	--: () -> (true | nil, string | nil)
	function self.clear()
		-- Best-effort: missing file is success.
		local _, err = remove_fn(pid_file)
		if err and not err:find("No such") and not err:find("cannot find") then
			-- Real error vs missing-file: only surface real errors.
			return nil, err
		end
		return true, nil
	end

	return self
end

return M
