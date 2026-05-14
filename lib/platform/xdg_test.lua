-- lib/platform/xdg_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local xdg = require("lib.platform.xdg")

-- Stash the original getenv so each test can swap a fresh fake in.
local real_getenv = xdg._getenv

local function with_env(env_map, fn)
	xdg._getenv = function(name) return env_map[name] end
	local ok, err = pcall(fn)
	xdg._getenv = real_getenv
	if not ok then error(err, 0) end
end

T.describe("xdg defaults (no env vars set)", function()
	-- On Windows the defaults differ; gate by platform.
	if xdg.is_windows() then
		T.it("data_home defaults to LOCALAPPDATA/crescent", function()
			with_env({ USERPROFILE = "C:/Users/test" }, function()
				T.eq(xdg.data_home(), "C:/Users/test/AppData/Local/crescent")
			end)
		end)
	else
		T.it("data_home defaults to $HOME/.local/share/crescent", function()
			with_env({ HOME = "/home/u" }, function()
				T.eq(xdg.data_home(), "/home/u/.local/share/crescent")
			end)
		end)

		T.it("state_home defaults to $HOME/.local/state/crescent", function()
			with_env({ HOME = "/home/u" }, function()
				T.eq(xdg.state_home(), "/home/u/.local/state/crescent")
			end)
		end)

		T.it("config_home defaults to $HOME/.config/crescent", function()
			with_env({ HOME = "/home/u" }, function()
				T.eq(xdg.config_home(), "/home/u/.config/crescent")
			end)
		end)

		T.it("cache_home defaults to $HOME/.cache/crescent", function()
			with_env({ HOME = "/home/u" }, function()
				T.eq(xdg.cache_home(), "/home/u/.cache/crescent")
			end)
		end)

		T.it("bin_home defaults to $HOME/.local/bin", function()
			with_env({ HOME = "/home/u" }, function()
				T.eq(xdg.bin_home(), "/home/u/.local/bin")
			end)
		end)
	end
end)

T.describe("xdg env var overrides (unix)", function()
	if xdg.is_windows() then return end

	T.it("XDG_DATA_HOME is respected", function()
		with_env({ HOME = "/home/u", XDG_DATA_HOME = "/data" }, function()
			T.eq(xdg.data_home(), "/data/crescent")
		end)
	end)

	T.it("XDG_STATE_HOME is respected", function()
		with_env({ HOME = "/home/u", XDG_STATE_HOME = "/state" }, function()
			T.eq(xdg.state_home(), "/state/crescent")
		end)
	end)

	T.it("XDG_CONFIG_HOME is respected", function()
		with_env({ HOME = "/home/u", XDG_CONFIG_HOME = "/cfg" }, function()
			T.eq(xdg.config_home(), "/cfg/crescent")
		end)
	end)

	T.it("XDG_CACHE_HOME is respected", function()
		with_env({ HOME = "/home/u", XDG_CACHE_HOME = "/cache" }, function()
			T.eq(xdg.cache_home(), "/cache/crescent")
		end)
	end)

	T.it("XDG_BIN_HOME is respected", function()
		with_env({ HOME = "/home/u", XDG_BIN_HOME = "/usr/local/bin" }, function()
			T.eq(xdg.bin_home(), "/usr/local/bin")
		end)
	end)

	T.it("empty XDG_DATA_HOME falls back to default", function()
		with_env({ HOME = "/home/u", XDG_DATA_HOME = "" }, function()
			T.eq(xdg.data_home(), "/home/u/.local/share/crescent")
		end)
	end)
end)

T.describe("xdg CRESCENT_HOME override", function()
	T.it("CRESCENT_HOME beats XDG_DATA_HOME", function()
		with_env({ HOME = "/home/u", XDG_DATA_HOME = "/data", CRESCENT_HOME = "/opt/cr" }, function()
			T.eq(xdg.data_home(), "/opt/cr")
		end)
	end)

	if not xdg.is_windows() then
		T.it("CRESCENT_HOME does NOT affect state_home", function()
			with_env({ HOME = "/home/u", CRESCENT_HOME = "/opt/cr" }, function()
				T.eq(xdg.state_home(), "/home/u/.local/state/crescent")
			end)
		end)

		T.it("CRESCENT_HOME does NOT affect config_home", function()
			with_env({ HOME = "/home/u", CRESCENT_HOME = "/opt/cr" }, function()
				T.eq(xdg.config_home(), "/home/u/.config/crescent")
			end)
		end)
	end
end)

T.describe("xdg.apps_dir / xdg.db_dir", function()
	if xdg.is_windows() then return end

	T.it("apps_dir = state_home() .. /apps", function()
		with_env({ HOME = "/home/u" }, function()
			T.eq(xdg.apps_dir(), "/home/u/.local/state/crescent/apps")
		end)
	end)

	T.it("db_dir = state_home() .. /db", function()
		with_env({ HOME = "/home/u" }, function()
			T.eq(xdg.db_dir(), "/home/u/.local/state/crescent/db")
		end)
	end)

	T.it("apps_dir follows XDG_STATE_HOME override", function()
		with_env({ HOME = "/home/u", XDG_STATE_HOME = "/var/state" }, function()
			T.eq(xdg.apps_dir(), "/var/state/crescent/apps")
		end)
	end)
end)

T.describe("xdg.is_windows", function()
	T.it("is_windows reflects package.config separator", function()
		local sep = package.config:sub(1, 1)
		T.eq(xdg.is_windows(), sep == "\\")
	end)
end)

T.describe("xdg.legacy_path_if_present", function()
	T.it("returns legacy path when ~/.crescent exists and new dir does not", function()
		with_env({ HOME = "/home/u" }, function()
			local seen = {}
			local function exists(p) seen[p] = true; return p == "/home/u/.crescent" end
			T.eq(xdg.legacy_path_if_present(exists), "/home/u/.crescent")
		end)
	end)

	T.it("returns nil when new XDG dir already exists", function()
		with_env({ HOME = "/home/u" }, function()
			local function exists(_) return true end
			T.eq(xdg.legacy_path_if_present(exists), nil)
		end)
	end)

	T.it("returns nil when legacy dir absent", function()
		with_env({ HOME = "/home/u" }, function()
			local function exists(_) return false end
			T.eq(xdg.legacy_path_if_present(exists), nil)
		end)
	end)

	T.it("returns nil when HOME is unset", function()
		with_env({}, function()
			local function exists(_) return true end
			T.eq(xdg.legacy_path_if_present(exists), nil)
		end)
	end)
end)
