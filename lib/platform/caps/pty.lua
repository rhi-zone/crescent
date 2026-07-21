-- lib/platform/caps/pty.lua
-- PTY capability: spawn processes with pseudo-terminal I/O, multiplexed
-- on the daemon's shared event loop via DaemonCtx.
--
-- Factory:
--   M.pty_cap(daemon_ctx, default_cmd?) -> cap, revoke_fn
--   default_cmd comes from the app's manifest cap declaration (`cmd` field on
--   the pty cap decl, see lib/platform/init.lua's pty build()); sandboxed apps
--   cannot read $SHELL themselves (caps-first), so the manifest is the only
--   configuration surface. Defaults to "/bin/sh" when the manifest omits it.
--
-- Cap API:
--   cap.spawn(cmd, opts?) -> PtyHandle | nil, err
--   cap.default_cmd       : string  -- manifest-configured shell, for apps
--                                       that want a sensible default command
--
-- PtyHandle API:
--   handle.read()              -> string | nil, err   (yields until data)
--   handle.write(data)         -> integer | nil, err  (yields if EAGAIN)
--   handle.resize(rows, cols)  -> true | nil, err
--   handle.close()             -> true | nil, err
--   handle.pid                 : integer
--
-- Environment: opts.env overlays the inherited environment (setenv per key),
-- it does not replace it. This preserves PATH, HOME, TERM, etc. by default.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi = require("ffi")
local pty_ffi = require("lib.pty_ffi")
local async = require("lib.async")

-- C declarations for child-process setup and reaping.
-- pty_ffi already cdefs fork, _exit, close, read, write, dup2, setsid.
-- LuaJIT ignores identical redeclarations; these are needed so the
-- typechecker (which does not track cdefs across requires) can see them.
ffi.cdef[[
	int execvp(const char *file, char *const argv[]);
	int waitpid(int pid, int *status, int options);
	void _exit(int status);
	int setenv(const char *name, const char *value, int overwrite);
	int kill(int pid, int sig);
]]

local WNOHANG = 1
local SIGKILL = 9

local M = {}

--:: require "lib.platform.caps.cap_types"

-- pty_cap(daemon_ctx, default_cmd?) -> (PtyCap, () -> nil) | (nil, string)
--: (DaemonCtx, string | nil) -> (PtyCap | nil, (() -> nil) | string | nil)
function M.pty_cap(daemon_ctx, default_cmd)
	if not daemon_ctx then
		return nil, "pty cap requires daemon_ctx"
	end

	local loop = daemon_ctx.loop
	local revoked = false
	local open_handles = {} --: { [integer]: PtyHandle | nil }
	local handle_count = 0

	--: (cmd: string, opts: PtySpawnOpts | nil) -> (PtyHandle | nil, string | nil)
	local function spawn(cmd, opts)
		if revoked then return nil, "pty: capability revoked" end
		if type(cmd) ~= "string" then return nil, "pty: cmd must be a string" end

		local spawn_args = opts and opts.args or nil
		local env = opts and opts.env or nil
		local rows = opts and opts.rows or nil
		local cols = opts and opts.cols or nil

		-- forkpty: creates PTY pair + forks
		local master_or_zero, pid_or_err = pty_ffi.forkpty()
		if not master_or_zero then
			return nil, pid_or_err
		end

		if master_or_zero == 0 then
			-- child process
			-- Overlay environment if provided (inherit parent, override per key)
			if env then
				for k, v in pairs(env) do
					ffi.C.setenv(k, v, 1)
				end
			end

			-- Build argv: cmd, args..., NULL
			local nargs = spawn_args and #spawn_args or 0
			local argv = ffi.new("const char*[?]", nargs + 2)
			argv[0] = cmd
			if spawn_args then
				for i = 1, nargs do
					argv[i] = spawn_args[i]
				end
			end
			argv[nargs + 1] = nil

			ffi.C.execvp(cmd, ffi.cast("char *const*", argv))
			-- execvp only returns on error
			ffi.C._exit(127)
		end

		-- parent
		local master_fd = master_or_zero --: integer
		local child_pid = pid_or_err --: integer
		local status_buf = ffi.new("int[1]")

		-- Set non-blocking for async I/O
		local nb_ok, nb_err = pty_ffi.set_nonblock(master_fd)
		if not nb_ok then
			pty_ffi.close(master_fd)
			ffi.C.waitpid(child_pid, status_buf, 0)
			return nil, nb_err
		end

		-- Set initial window size if provided
		if rows and cols then
			local ws_ok, ws_err = pty_ffi.set_winsize(master_fd, rows, cols)
			if not ws_ok then
				pty_ffi.close(master_fd)
				ffi.C.waitpid(child_pid, status_buf, 0)
				return nil, ws_err
			end
		end

		local closed = false
		local handle_id = handle_count + 1
		handle_count = handle_id

		-- Define handle methods as locals, then assemble the table.

		--: () -> (string | nil, string | nil)
		local function handle_read()
			if revoked then return nil, "pty: capability revoked" end
			if closed then return nil, "pty: handle closed" end
			while true do
				local data, err = pty_ffi.read(master_fd)
				if data then
					if data == "" then return nil, "eof" end
					return data
				end
				if pty_ffi.is_eagain(err) then
					local p, perr = loop:await_readable(master_fd)
					if not p then return nil, "pty: await_readable: " .. tostring(perr) end
					-- The poller may fire "fd closed" (HUP) when the child exits,
					-- even if data is still buffered. Catch the rejection and try
					-- one final read before propagating.
					local ok_await, await_err = pcall(async.await, p)
					if not ok_await then
						local final_data = pty_ffi.read(master_fd)
						if final_data and final_data ~= "" then
							return final_data
						end
						return nil, tostring(await_err)
					end
				else
					return nil, err
				end
			end
		end

		--: (data: string) -> (integer | nil, string | nil)
		local function handle_write(data)
			if revoked then return nil, "pty: capability revoked" end
			if closed then return nil, "pty: handle closed" end
			local total = #data
			local sent = 0
			while sent < total do
				local chunk = sent == 0 and data or data:sub(sent + 1)
				local n, err = pty_ffi.write(master_fd, chunk)
				if n then
					sent = sent + n
				elseif pty_ffi.is_eagain(err) then
					local p, perr = loop:await_writable(master_fd)
					if not p then return nil, "pty: await_writable: " .. tostring(perr) end
					async.await(p)
				else
					return nil, err
				end
			end
			return sent
		end

		--: (rows: integer, cols: integer) -> (true | nil, string | nil)
		local function handle_resize(r, c)
			if revoked then return nil, "pty: capability revoked" end
			if closed then return nil, "pty: handle closed" end
			return pty_ffi.set_winsize(master_fd, r, c)
		end

		-- Forward declaration; handle_close references open_handles[handle_id]
		-- which needs handle_id to be set first.
		--: () -> (true | nil, string | nil)
		local function handle_close()
			if closed then return nil, "pty: already closed" end
			closed = true
			open_handles[handle_id] = nil

			-- Close master fd (sends SIGHUP to child's process group)
			pty_ffi.close(master_fd)

			-- Reap child: non-blocking first, then SIGKILL if still running
			local wpid = ffi.C.waitpid(child_pid, status_buf, WNOHANG)
			if wpid == 0 then
				-- Still running after fd close; force kill and reap
				ffi.C.kill(child_pid, SIGKILL)
				ffi.C.waitpid(child_pid, status_buf, 0)
			end

			return true
		end

		--: PtyHandle
		local handle = {
			pid = child_pid,
			read = handle_read,
			write = handle_write,
			resize = handle_resize,
			close = handle_close,
		}

		open_handles[handle_id] = handle
		return handle
	end

	--: PtyCap
	local cap = {
		_type = "pty",
		spawn = spawn,
		default_cmd = default_cmd or "/bin/sh",
	}

	--: () -> nil
	local function revoke()
		revoked = true
		-- Close all open handles
		for _, h in pairs(open_handles) do
			if h then h.close() end
		end
	end

	return cap, revoke
end

return M
