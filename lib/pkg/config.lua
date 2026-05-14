if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- lib/pkg/config.lua — user config loader
--
-- Loads $XDG_CONFIG_HOME/crescent/config.lua if it exists
-- (default $HOME/.config/crescent/config.lua). Resolved via lib.platform.xdg.
-- Returns a config table with defaults filled in.
--
-- config.lua format:
--   return {
--     registries = { "https://corp.internal/lua-pkgs" },
--     auth = { ["corp.internal"] = { token = "..." } },
--   }

local xdg = require("lib.platform.xdg")

local M = {}

local _migration_warned = false
local function maybe_warn_legacy()
	if _migration_warned then return end
	_migration_warned = true
	local home = os.getenv("HOME")
	if not home or home == "" then return end
	local legacy = home .. "/.crescent/config.lua"
	local f = io.open(legacy, "r")
	if not f then return end
	f:close()
	io.stderr:write("note: legacy " .. legacy .. " detected; pkg config now expected at "
		.. xdg.config_home() .. "/config.lua (no automatic migration)\n")
end

local function load_from_path(path)
	local fn, _err = loadfile(path)
	if not fn then return { registries = {}, auth = {} } end
	local ok, cfg = pcall(fn)
	if not ok or type(cfg) ~= "table" then return { registries = {}, auth = {} } end
	return {
		registries = type(cfg.registries) == "table" and cfg.registries or {},
		auth       = type(cfg.auth) == "table" and cfg.auth or {},
	}
end

-- Returns { registries=[...], auth={...} }
function M.load()
	maybe_warn_legacy()
	local path = xdg.config_home() .. "/config.lua"
	return load_from_path(path)
end

-- Exposed for testing.
M._load_from_path = load_from_path

return M
