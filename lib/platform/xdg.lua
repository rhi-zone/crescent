-- lib/platform/xdg.lua
-- Resolve XDG Base Directory paths with platform-appropriate fallbacks.
--
-- Unix (Linux/macOS) layout follows the XDG Base Directory Specification:
--   data:   $XDG_DATA_HOME   (default $HOME/.local/share)   + /crescent
--   state:  $XDG_STATE_HOME  (default $HOME/.local/state)   + /crescent
--   config: $XDG_CONFIG_HOME (default $HOME/.config)        + /crescent
--   cache:  $XDG_CACHE_HOME  (default $HOME/.cache)         + /crescent
--   bin:    $XDG_BIN_HOME    (default $HOME/.local/bin)
--
-- $CRESCENT_HOME overrides the source/data dir (alternate to XDG_DATA_HOME/crescent).
-- It does NOT affect state/config/cache/bin — those follow their own env vars.
--
-- Windows folds source + state + config + cache + bin under
-- %LOCALAPPDATA%\crescent (overridable via $env:CRESCENT_HOME):
--   data   = %LOCALAPPDATA%\crescent
--   state  = %LOCALAPPDATA%\crescent\state
--   config = %LOCALAPPDATA%\crescent\config
--   cache  = %LOCALAPPDATA%\crescent\cache
--   bin    = %LOCALAPPDATA%\crescent\bin
--
-- Convenience accessors:
--   apps_dir() = state_home() .. "/apps"
--   db_dir()   = state_home() .. "/db"
--
-- All functions are caps-friendly: they only read environment via os.getenv.
-- Callers that need to mock the environment can use M._with_env (test helper).

local M = {}

--: (string, () -> string) -> string
local function env(name, default_fn)
	local v = M._getenv(name)
	if v and v ~= "" then return v end
	return default_fn()
end

--: () -> boolean
function M.is_windows()
	return package.config:sub(1, 1) == "\\"
end

--: () -> string
local function home()
	return M._getenv("HOME") or M._getenv("USERPROFILE") or "."
end

-- Indirection so tests can swap the environment lookup.
--: (string) -> (string | nil)
M._getenv = function(name) return os.getenv(name) end

--: () -> string
function M.data_home()
	if M.is_windows() then
		return env("CRESCENT_HOME", function()
			local lad = M._getenv("LOCALAPPDATA") or (home() .. "/AppData/Local")
			return lad .. "/crescent"
		end)
	end
	return env("CRESCENT_HOME", function()
		return env("XDG_DATA_HOME", function() return home() .. "/.local/share" end) .. "/crescent"
	end)
end

--: () -> string
function M.state_home()
	if M.is_windows() then return M.data_home() .. "/state" end
	return env("XDG_STATE_HOME", function() return home() .. "/.local/state" end) .. "/crescent"
end

--: () -> string
function M.config_home()
	if M.is_windows() then return M.data_home() .. "/config" end
	return env("XDG_CONFIG_HOME", function() return home() .. "/.config" end) .. "/crescent"
end

--: () -> string
function M.cache_home()
	if M.is_windows() then return M.data_home() .. "/cache" end
	return env("XDG_CACHE_HOME", function() return home() .. "/.cache" end) .. "/crescent"
end

--: () -> string
function M.bin_home()
	if M.is_windows() then return M.data_home() .. "/bin" end
	return env("XDG_BIN_HOME", function() return home() .. "/.local/bin" end)
end

--: () -> string
function M.apps_dir() return M.state_home() .. "/apps" end

--: () -> string
function M.db_dir() return M.state_home() .. "/db" end

-- Runtime dir for transient per-process state (PID files, sockets).
-- Linux: $XDG_RUNTIME_DIR/crescent (falls back to /tmp/crescent-$UID).
-- macOS: $TMPDIR/crescent (per-user temp; survives reasonably during session).
-- Windows: %LOCALAPPDATA%\crescent\runtime.
--: () -> string
function M.runtime_home()
	if M.is_windows() then return M.data_home() .. "/runtime" end
	local xrd = M._getenv("XDG_RUNTIME_DIR")
	if xrd and xrd ~= "" then return xrd .. "/crescent" end
	local tmp = M._getenv("TMPDIR")
	if tmp and tmp ~= "" then return tmp .. "/crescent" end
	-- Linux fallback: /tmp/crescent-<uid> (uid keeps it per-user when shared).
	local uid = M._getenv("UID") or M._getenv("USER") or "user"
	return "/tmp/crescent-" .. uid
end

--: () -> string
function M.pid_file() return M.runtime_home() .. "/daemon.pid" end

-- Migration helper: returns the legacy path (`$HOME/.crescent`) if it exists
-- and the current XDG data dir does not. Callers can warn the user.
--: ((string) -> boolean) -> (string | nil)
function M.legacy_path_if_present(exists_fn)
	local h = M._getenv("HOME")
	if not h or h == "" then return nil end
	local legacy = h .. "/.crescent"
	if not exists_fn(legacy) then return nil end
	local cur = M.data_home()
	if exists_fn(cur) then return nil end
	return legacy
end

return M
