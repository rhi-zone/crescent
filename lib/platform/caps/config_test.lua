-- lib/platform/caps/config_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local json   = require("lib.json")
local config = require("lib.platform.caps.config")

-- ── helpers ───────────────────────────────────────────────────────────────────

-- Create a unique temp directory for test isolation.
local function tmpdir()
	local path = os.tmpname()
	-- os.tmpname() returns a file; remove it and use as dir name.
	os.remove(path)
	os.execute('mkdir -p "' .. path .. '/config"')
	return path
end

-- Remove a temp directory tree.
local function rmdir(path)
	os.execute('rm -rf "' .. path .. '"')
end

-- Write a file directly (bypassing the cap, for test setup).
local function write_raw(path, content)
	local f = assert(io.open(path, "wb"))
	f:write(content)
	f:close()
end

-- ── tests ─────────────────────────────────────────────────────────────────────

T.describe("config_cap", function()

	T.describe("defaults for missing files", function()
		T.it("theme returns empty string when file absent", function()
			local dir = tmpdir()
			local cap = config.config_cap({ dir = dir })
			T.eq(cap.theme.get(), "")
			rmdir(dir)
		end)

		T.it("ui returns empty table when file absent", function()
			local dir = tmpdir()
			local cap = config.config_cap({ dir = dir })
			local val = cap.ui.get()
			T.eq(type(val), "table")
			T.eq(next(val), nil)
			rmdir(dir)
		end)

		T.it("presets returns empty table when file absent", function()
			local dir = tmpdir()
			local cap = config.config_cap({ dir = dir })
			local val = cap.presets.get()
			T.eq(type(val), "table")
			rmdir(dir)
		end)

		T.it("lorebooks returns empty table when file absent", function()
			local dir = tmpdir()
			local cap = config.config_cap({ dir = dir })
			local val = cap.lorebooks.get()
			T.eq(type(val), "table")
			rmdir(dir)
		end)

		T.it("get(key) returns nil for unknown key", function()
			local dir = tmpdir()
			local cap = config.config_cap({ dir = dir })
			T.eq(cap.get("nonexistent").get(), nil)
			rmdir(dir)
		end)
	end)

	T.describe("reading existing files", function()
		T.it("reads theme from theme.txt", function()
			local dir = tmpdir()
			write_raw(dir .. "/config/theme.txt", "dark\n")
			local cap = config.config_cap({ dir = dir })
			T.eq(cap.theme.get(), "dark")
			rmdir(dir)
		end)

		T.it("reads ui from ui.json", function()
			local dir = tmpdir()
			write_raw(dir .. "/config/ui.json", '{"sidebar":true,"font":"mono"}')
			local cap = config.config_cap({ dir = dir })
			local val = cap.ui.get()
			T.eq(val.sidebar, true)
			T.eq(val.font, "mono")
			rmdir(dir)
		end)

		T.it("reads presets array from presets.json", function()
			local dir = tmpdir()
			write_raw(dir .. "/config/presets.json", '[{"name":"p1"},{"name":"p2"}]')
			local cap = config.config_cap({ dir = dir })
			local val = cap.presets.get()
			T.eq(#val, 2)
			T.eq(val[1].name, "p1")
			T.eq(val[2].name, "p2")
			rmdir(dir)
		end)

		T.it("reads lorebooks array from lorebooks.json", function()
			local dir = tmpdir()
			write_raw(dir .. "/config/lorebooks.json", '[{"title":"world1"}]')
			local cap = config.config_cap({ dir = dir })
			local val = cap.lorebooks.get()
			T.eq(#val, 1)
			T.eq(val[1].title, "world1")
			rmdir(dir)
		end)

		T.it("get(key) reads .json file", function()
			local dir = tmpdir()
			write_raw(dir .. "/config/custom.json", '{"x":42}')
			local cap = config.config_cap({ dir = dir })
			local val = cap.get("custom").get()
			T.eq(val.x, 42)
			rmdir(dir)
		end)

		T.it("get(key) reads .txt file when no .json present", function()
			local dir = tmpdir()
			write_raw(dir .. "/config/mykey.txt", "hello")
			local cap = config.config_cap({ dir = dir })
			T.eq(cap.get("mykey").get(), "hello")
			rmdir(dir)
		end)

		T.it("strips trailing newline from .txt files", function()
			local dir = tmpdir()
			write_raw(dir .. "/config/theme.txt", "light\n")
			local cap = config.config_cap({ dir = dir })
			T.eq(cap.theme.get(), "light")
			rmdir(dir)
		end)
	end)

	T.describe("cap.set", function()
		T.it("writes string value to .txt and updates signal", function()
			local dir = tmpdir()
			local cap = config.config_cap({ dir = dir })
			local ok, err = cap.set("theme", "solarized")
			T.ok(ok, tostring(err))
			T.eq(cap.theme.get(), "solarized")
			-- Verify file was written
			local f = io.open(dir .. "/config/theme.txt", "rb")
			T.ok(f ~= nil)
			if f then
				local content = f:read("*a")
				f:close()
				T.eq(content, "solarized")
			end
			rmdir(dir)
		end)

		T.it("writes table value to .json and updates signal", function()
			local dir = tmpdir()
			local cap = config.config_cap({ dir = dir })
			local ok, err = cap.set("ui", { font = "serif", size = 14 })
			T.ok(ok, tostring(err))
			local val = cap.ui.get()
			T.eq(val.font, "serif")
			T.eq(val.size, 14)
			-- Verify file was written as valid JSON
			local f = io.open(dir .. "/config/ui.json", "rb")
			T.ok(f ~= nil)
			if f then
				local content = f:read("*a")
				f:close()
				local decoded = json.decode(content)
				T.eq(decoded.font, "serif")
			end
			rmdir(dir)
		end)

		T.it("writes array value to .json", function()
			local dir = tmpdir()
			local cap = config.config_cap({ dir = dir })
			local presets = { { name = "a" }, { name = "b" } }
			local ok, err = cap.set("presets", presets)
			T.ok(ok, tostring(err))
			local val = cap.presets.get()
			T.eq(#val, 2)
			T.eq(val[1].name, "a")
			rmdir(dir)
		end)

		T.it("notifies signal subscribers on set", function()
			local dir = tmpdir()
			local cap = config.config_cap({ dir = dir })
			local seen = {}
			cap.theme.subscribe(function(v) seen[#seen + 1] = v end)
			cap.set("theme", "nord")
			T.eq(#seen, 1)
			T.eq(seen[1], "nord")
			rmdir(dir)
		end)

		T.it("creates config dir if missing", function()
			-- Use a dir that doesn't exist yet (no pre-created config subdir)
			local dir = os.tmpname()
			os.remove(dir)
			-- Don't pre-create the dir at all
			local cap = config.config_cap({ dir = dir })
			local ok, err = cap.set("theme", "auto")
			T.ok(ok, tostring(err))
			T.eq(cap.theme.get(), "auto")
			rmdir(dir)
		end)
	end)

	T.describe("cap.reload", function()
		T.it("reloads value from disk", function()
			local dir = tmpdir()
			write_raw(dir .. "/config/theme.txt", "original")
			local cap = config.config_cap({ dir = dir })
			T.eq(cap.theme.get(), "original")
			-- Mutate file externally
			write_raw(dir .. "/config/theme.txt", "updated")
			-- Signal not updated yet
			T.eq(cap.theme.get(), "original")
			-- Reload triggers read from disk
			cap.reload("theme")
			T.eq(cap.theme.get(), "updated")
			rmdir(dir)
		end)

		T.it("notifies subscribers on reload when value changed", function()
			local dir = tmpdir()
			write_raw(dir .. "/config/theme.txt", "v1")
			local cap = config.config_cap({ dir = dir })
			local seen = {}
			cap.theme.subscribe(function(v) seen[#seen + 1] = v end)
			write_raw(dir .. "/config/theme.txt", "v2")
			cap.reload("theme")
			T.eq(#seen, 1)
			T.eq(seen[1], "v2")
			rmdir(dir)
		end)
	end)

	T.describe("signal laziness", function()
		T.it("well-known keys are cached after first access", function()
			local dir = tmpdir()
			local cap = config.config_cap({ dir = dir })
			local s1 = cap.theme
			local s2 = cap.theme
			T.ok(s1 == s2, "same signal object returned on repeated access")
			rmdir(dir)
		end)

		T.it("cap.get returns same signal for same key", function()
			local dir = tmpdir()
			local cap = config.config_cap({ dir = dir })
			local s1 = cap.get("mykey")
			local s2 = cap.get("mykey")
			T.ok(s1 == s2, "same signal object for same key")
			rmdir(dir)
		end)
	end)

	T.describe("tilde expansion", function()
		T.it("expands ~ in dir path", function()
			local home = os.getenv("HOME")
			if not home then return end  -- skip if HOME not set
			-- Just ensure config_cap doesn't crash with ~ path
			-- We won't actually write to ~/.crescent in tests — just check construction works
			local cap = config.config_cap({ dir = "~/.crescent_test_never_created_xyz" })
			T.ok(cap ~= nil)
			-- theme signal should be accessible (returns default, file missing)
			local s = cap.theme
			T.ok(s ~= nil)
			T.eq(s.get(), "")
		end)
	end)

end)
