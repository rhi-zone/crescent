-- lib/cr/open.lua
-- `cr open` — launch the crescent library in the user's default browser.
--
-- Flow:
--   1. Check the daemon PID file. If a daemon is already running, reuse it.
--   2. Otherwise spawn `cr daemon` in the background and wait briefly for
--      the PID file to appear (signals readiness without polling the port).
--   3. Open the daemon URL with the platform's default-browser launcher
--      (`xdg-open` / `open` / `start`).
--
-- `cr open <file>` — file-import variant is not yet wired through the
-- import-card pipeline. For now it logs a note and falls through to the
-- plain library URL. TODO.md tracks the real handler.
--
-- The OS-talking calls (popen, execute) live HERE in the CLI entry by
-- design — keeps caps-first discipline. Library code under lib/cr/ that is
-- itself a CLI command is treated as an entry point, not as a reusable
-- library; the open/daemon-spawn primitives are not exported for sandboxed
-- callers.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local xdg = require("lib.platform.xdg")
local pid_mod = require("lib.platform.daemon.pid")

local M = {}

--: () -> string
local function platform()
	if package.config:sub(1, 1) == "\\" then return "windows" end
	-- Best-effort uname check (no FFI to keep this cheap).
	local h = io.popen("uname -s 2>/dev/null")
	if h then
		local raw = h:read("*l") or ""
		h:close()
		local os_name = raw:lower()
		if os_name:find("darwin", 1, true) then return "macos" end
	end
	return "linux"
end

--: (string) -> (true | nil, string | nil)
local function open_url(url)
	local plat = platform()
	local cmd
	if plat == "windows" then
		-- start "" "URL" — empty title arg is required when URL is quoted.
		cmd = ('start "" "%s"'):format(url)
	elseif plat == "macos" then
		cmd = ('open %q >/dev/null 2>&1'):format(url)
	else
		cmd = ('xdg-open %q >/dev/null 2>&1'):format(url)
	end
	local ok = os.execute(cmd)
	if ok == 0 or ok == true then return true, nil end
	return nil, "failed to launch browser (" .. cmd .. ")"
end

--- Sleep for `secs` seconds. Uses `select` on POSIX, `timeout` on Windows.
--- This is a polling step — small fractional sleeps are fine.
--: (number) -> nil
local function sleep(secs)
	if package.config:sub(1, 1) == "\\" then
		-- Windows timeout is 1-second granular; round up.
		local s = math.max(1, math.ceil(secs))
		os.execute(("timeout /T %d /NOBREAK >NUL"):format(s))
	else
		-- `select 0` with timeout — portable across BSD/Linux shells.
		os.execute(("sleep %s"):format(tostring(secs)))
	end
end

--- Spawn `cr daemon` in the background and wait for its PID file.
--- Returns the PidInfo on success, nil + reason on timeout.
--: (string, number) -> ({ pid: integer, host: string, port: integer } | nil, string | nil)
local function spawn_daemon(cr_bin, timeout_secs)
	local plat = platform()
	local cmd
	if plat == "windows" then
		-- start /B: same console, no new window. Detach via setsid-equivalent.
		cmd = ('start /B "" "%s" daemon >NUL 2>&1'):format(cr_bin)
	else
		-- nohup + & to detach. Redirect to /dev/null so the child doesn't
		-- inherit our stdout/stderr (would block on exit otherwise).
		cmd = ('nohup %q daemon >/dev/null 2>&1 &'):format(cr_bin)
	end
	io.stderr:write("cr open: starting daemon...\n")
	os.execute(cmd)

	local pid_io = pid_mod.make({ pid_file = xdg.pid_file() })
	local deadline = timeout_secs
	local step = 0.2 --: number
	local elapsed = 0.0 --: number
	while elapsed < deadline do
		sleep(step)
		elapsed = elapsed + step
		local info = pid_io.read()
		if info then return info, nil end
	end
	return nil, "daemon did not become ready within " .. tostring(timeout_secs) .. "s"
end

--- Resolve the path to the `cr` binary. Prefers `CR_BIN` env, falls back
--- to whatever invoked us (arg[-1] in some loaders), then to a bare "cr"
--- which relies on PATH.
--: () -> string
local function cr_bin_path()
	local env_bin = os.getenv("CR_BIN")
	if env_bin and env_bin ~= "" then return env_bin end
	-- arg[-1] is the interpreter, arg[0] is the script — neither is "cr"
	-- when invoked through the dispatcher. Fall back to PATH lookup.
	return "cr"
end

--- Main entry. `argv[1]`, if present, is treated as a target — currently
--- only file paths are recognised, and they emit a "not yet implemented"
--- note before falling through to the library URL.
--: ({ [integer]: string }) -> boolean
function M.main(argv)
	-- Step 1: discover or start daemon.
	local pid_io = pid_mod.make({ pid_file = xdg.pid_file() })
	local info = pid_io.read()
	if not info then
		local spawned, serr = spawn_daemon(cr_bin_path(), 5)
		if not spawned then
			io.stderr:write("cr open: " .. tostring(serr) .. "\n")
			os.exit(1)
		end
		info = spawned
	end

	-- Step 2: build URL. If the user passed a file path, note the deferral.
	local target = argv and argv[1]
	if target and target ~= "" then
		-- Is it a path that exists? (Cheap heuristic — we just check open().)
		local f = io.open(target, "rb")
		if f then
			f:close()
			io.stderr:write(
				"cr open: import of " .. target .. " not yet implemented — "
				.. "drag the file into the library window after it opens.\n"
			)
		else
			io.stderr:write(
				"cr open: argument " .. target .. " is not a readable file; "
				.. "opening library URL.\n"
			)
		end
	end

	local url = ("http://%s:%d/"):format(info.host, info.port)
	local ok, err = open_url(url)
	if not ok then
		io.stderr:write("cr open: " .. tostring(err) .. "\n")
		io.write(url .. "\n")  -- print URL so user can copy/paste
		os.exit(1)
	end
	io.write("cr open: " .. url .. "\n")
	return true
end

return M
