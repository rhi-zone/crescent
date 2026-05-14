-- lib/cr/uninstall.lua
-- `cr uninstall` — remove everything the installer puts on the system.
--
-- This command is the inverse of docs/public/install.{sh,ps1} plus the
-- launcher integration added in the same commit. It does NOT delete the
-- user's XDG state (apps, DBs, sessions) unless they explicitly opt in.
--
-- Removal targets:
--   - $XDG_BIN_HOME/cr symlink
--   - $XDG_DATA_HOME/icons/hicolor/scalable/apps/crescent.svg
--   - $XDG_DATA_HOME/applications/crescent.desktop
--   - $CRESCENT_HOME source tree (with confirmation)
--   - PID file in $XDG_RUNTIME_DIR/crescent/daemon.pid (cleanup of stale)
--   - $XDG_STATE_HOME/crescent + $XDG_DATA_HOME/crescent (--purge only)
--   - PATH entry added to ~/.bashrc / ~/.zshrc / etc. (best-effort grep)
--
-- macOS / Windows symmetric branches: removes the .app bundle / Start Menu
-- shortcut respectively when present.
--
-- Flags:
--   --purge    Also delete state (apps, DBs, sessions). Prompts before doing so.
--   --yes      Skip all confirmation prompts (for CI / scripts).
--
-- All filesystem touches go through os.remove / os.execute here; this is a
-- CLI entrypoint and is allowed to talk to the OS directly per the caps-first
-- carve-out for top-level commands.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local xdg = require("lib.platform.xdg")

local M = {}

--: () -> string
local function platform()
	if package.config:sub(1, 1) == "\\" then return "windows" end
	local h = io.popen("uname -s 2>/dev/null")
	if h then
		local raw = h:read("*l") or ""
		h:close()
		local os_name = raw:lower()
		if os_name:find("darwin", 1, true) then return "macos" end
	end
	return "linux"
end

--: (string) -> boolean
local function path_exists(p)
	local f = io.open(p, "rb")
	if f then f:close(); return true end
	-- Could be a directory or broken symlink — fall through to a stat-like.
	local sep = package.config:sub(1, 1)
	local cmd
	if sep == "\\" then
		cmd = ('if exist "%s" (exit 0) else (exit 1)'):format(p)
	else
		cmd = ('test -e %q || test -L %q'):format(p, p)
	end
	local r = os.execute(cmd)
	return r == 0 or r == true
end

--: (string) -> boolean
local function rm(p)
	if not path_exists(p) then return true end
	local sep = package.config:sub(1, 1)
	local cmd
	if sep == "\\" then
		-- /q quiet, /s recursive, /f force.
		cmd = ('rmdir /s /q "%s" 2>NUL || del /q /f "%s" 2>NUL'):format(p, p)
	else
		cmd = ('rm -rf %q'):format(p)
	end
	local r = os.execute(cmd)
	return r == 0 or r == true
end

--: (string) -> boolean
local function confirm(prompt)
	io.write(prompt .. " [y/N]: ")
	io.flush()
	local line = io.read("*l") or ""
	return line:match("^[Yy]") ~= nil
end

--: ({ verbose: boolean, yes: boolean, purge: boolean }, string) -> nil
local function remove_with_confirm(opts, path)
	if not path_exists(path) then
		if opts.verbose then io.write("  (absent) " .. path .. "\n") end
		return
	end
	if not opts.yes and not confirm("Remove " .. path .. "?") then
		io.write("  (skipped) " .. path .. "\n")
		return
	end
	if rm(path) then
		io.write("  removed   " .. path .. "\n")
	else
		io.stderr:write("  FAILED   " .. path .. "\n")
	end
end

--- Best-effort removal of the PATH-extending line added by install.sh.
--- Walks the standard rc files; removes the line if it references
--- $XDG_BIN_HOME. Does not back files up — user can `git diff` their dotfiles.
--: ({ verbose: boolean, yes: boolean, purge: boolean }, string) -> nil
local function strip_path_lines(opts, bin_dir)
	local rcs = {}
	local home = os.getenv("HOME")
	if not home then return end
	rcs[#rcs + 1] = home .. "/.bashrc"
	rcs[#rcs + 1] = home .. "/.zshrc"
	rcs[#rcs + 1] = home .. "/.profile"
	rcs[#rcs + 1] = home .. "/.config/fish/config.fish"

	for _, rc in ipairs(rcs) do
		local f = io.open(rc, "rb")
		if f then
			local content = f:read("*a") or ""
			f:close()
			-- Strip the install.sh-added stanza: a "# crescent" comment and
			-- the next line. Conservative — only touches the exact pattern.
			local pat = "\n# crescent %(XDG_BIN_HOME%)\n[^\n]*\n"
			local new_content, n = content:gsub(pat, "\n")
			if n > 0 then
				if opts.yes or confirm("Strip crescent PATH stanza from " .. rc .. "?") then
					local wf = io.open(rc, "wb")
					if wf then
						wf:write(new_content)
						wf:close()
						io.write("  stripped " .. rc .. "\n")
					end
				end
			end
		end
	end
end

--: ({ [integer]: string }) -> boolean
function M.main(argv)
	local opts = { verbose = false, yes = false, purge = false }
	for _, v in ipairs(argv or {}) do
		if v == "--yes" or v == "-y" then opts.yes = true
		elseif v == "--purge" then opts.purge = true
		elseif v == "--verbose" or v == "-v" then opts.verbose = true
		elseif v == "--help" or v == "-h" then
			io.write([[
usage: cr uninstall [--yes] [--purge]

Removes crescent installer artifacts:
  - $XDG_BIN_HOME/cr symlink
  - $XDG_DATA_HOME/applications/crescent.desktop (Linux)
  - $XDG_DATA_HOME/icons/hicolor/scalable/apps/crescent.svg (Linux)
  - $CRESCENT_HOME source tree (after confirmation)
  - Start Menu shortcut (Windows) / .app bundle (macOS) if present
  - PATH stanza added by install.sh to user shell rc files

--purge also deletes state (apps, DBs, sessions) under
  $XDG_STATE_HOME/crescent and $XDG_DATA_HOME/crescent state subdirs.

--yes skips all confirmation prompts.
]])
			return true
		end
	end

	local plat = platform()
	io.write("cr uninstall (platform: " .. plat .. ")\n")

	-- 1. Symlink in $XDG_BIN_HOME.
	local bin_dir = xdg.bin_home()
	remove_with_confirm(opts, bin_dir .. "/cr")
	if plat == "windows" then
		remove_with_confirm(opts, bin_dir .. "\\cr.bat")
		remove_with_confirm(opts, bin_dir .. "\\cr.ps1")
	end

	-- 2. Launcher integration.
	if plat == "linux" then
		local data = xdg.data_home() .. "/.."  -- back out the /crescent suffix
		-- Use XDG_DATA_HOME directly, not via data_home() which appends crescent.
		local xdg_data = os.getenv("XDG_DATA_HOME")
		if not xdg_data or xdg_data == "" then
			xdg_data = (os.getenv("HOME") or "") .. "/.local/share"
		end
		remove_with_confirm(opts, xdg_data .. "/applications/crescent.desktop")
		remove_with_confirm(opts, xdg_data .. "/icons/hicolor/scalable/apps/crescent.svg")
		-- Refresh icon/desktop caches (best-effort, ignore failures).
		os.execute("update-desktop-database " .. xdg_data .. "/applications >/dev/null 2>&1")
		os.execute("gtk-update-icon-cache " .. xdg_data .. "/icons/hicolor >/dev/null 2>&1")
		_ = data  -- silence unused
	elseif plat == "macos" then
		local home = os.getenv("HOME") or ""
		remove_with_confirm(opts, home .. "/Applications/Crescent.app")
	elseif plat == "windows" then
		local appdata = os.getenv("APPDATA") or ""
		remove_with_confirm(opts,
			appdata .. "\\Microsoft\\Windows\\Start Menu\\Programs\\Crescent.lnk")
	end

	-- 3. PID file (stale or otherwise).
	remove_with_confirm(opts, xdg.pid_file())

	-- 4. PATH stanza in rc files.
	if plat ~= "windows" then
		strip_path_lines(opts, bin_dir)
	end

	-- 5. Source tree (CRESCENT_HOME / data_home).
	remove_with_confirm(opts, xdg.data_home())

	-- 6. --purge: state dirs.
	if opts.purge then
		io.write("cr uninstall: --purge: removing state dirs\n")
		remove_with_confirm(opts, xdg.state_home())
		remove_with_confirm(opts, xdg.config_home())
		remove_with_confirm(opts, xdg.cache_home())
	else
		io.write("cr uninstall: state preserved under "
			.. xdg.state_home() .. " (use --purge to remove)\n")
	end

	io.write("cr uninstall: done.\n")
	return true
end

return M
