if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- lib/pkg/config.lua — user config loader
--
-- Loads ~/.crescent/config.lua if it exists.
-- Returns a config table with defaults filled in.
--
-- config.lua format:
--   return {
--     registries = { "https://corp.internal/lua-pkgs" },
--     auth = { ["corp.internal"] = { token = "..." } },
--   }

local M = {}

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
	local home = os.getenv("HOME") or ""
	local path = home .. "/.crescent/config.lua"
	return load_from_path(path)
end

-- Exposed for testing.
M._load_from_path = load_from_path

return M
