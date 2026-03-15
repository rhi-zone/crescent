if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local config = require("lib.pkg.config")

-- ── helpers ───────────────────────────────────────────────────────────────────

local function make_tmpfile()
	local path = os.tmpname()
	return path
end

local function write_file(path, content)
	local f = io.open(path, "w")
	f:write(content)
	f:close()
end

-- ── config._load_from_path ────────────────────────────────────────────────────

T.describe("config._load_from_path", function()

	T.it("returns defaults when file does not exist", function()
		local cfg = config._load_from_path("/tmp/nonexistent_crescent_config_xyz.lua")
		T.eq(type(cfg.registries), "table")
		T.eq(type(cfg.auth), "table")
		T.eq(#cfg.registries, 0)
	end)

	T.it("parses registries list", function()
		local path = make_tmpfile()
		write_file(path, [[return { registries = { "https://corp.example.com/pkgs" } }]])
		local cfg = config._load_from_path(path)
		T.eq(#cfg.registries, 1)
		T.eq(cfg.registries[1], "https://corp.example.com/pkgs")
		os.remove(path)
	end)

	T.it("parses auth table", function()
		local path = make_tmpfile()
		write_file(path, [[return { auth = { ["corp.example.com"] = { token = "tok123" } } }]])
		local cfg = config._load_from_path(path)
		T.ok(cfg.auth["corp.example.com"] ~= nil)
		T.eq(cfg.auth["corp.example.com"].token, "tok123")
		os.remove(path)
	end)

	T.it("returns defaults when file returns non-table", function()
		local path = make_tmpfile()
		write_file(path, [[return "not a table"]])
		local cfg = config._load_from_path(path)
		T.eq(#cfg.registries, 0)
		os.remove(path)
	end)

	T.it("returns defaults when file has a runtime error", function()
		local path = make_tmpfile()
		write_file(path, [[error("boom")]])
		local cfg = config._load_from_path(path)
		T.eq(#cfg.registries, 0)
		os.remove(path)
	end)

	T.it("returns empty registries when field is not a table", function()
		local path = make_tmpfile()
		write_file(path, [[return { registries = "bad" }]])
		local cfg = config._load_from_path(path)
		T.eq(#cfg.registries, 0)
		os.remove(path)
	end)

end)
