-- lib/platform/daemon/app_loader_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local app_loader = require("lib.platform.daemon.app_loader")

T.describe("app_loader._collect_entry_caps", function()
	T.it("returns top-level caps when no entry is present", function()
		local caps = app_loader._collect_entry_caps({
			caps = {
				http_server = { type = "http_server" },
				kv = "required",
			},
		}, "server")
		T.eq(caps.http_server.type, "http_server")
		-- Shorthand "required" expanded to a full decl.
		T.eq(caps.kv.type, "kv")
		T.eq(caps.kv.required, true)
	end)

	T.it("entry-level caps override top-level for same name", function()
		local caps = app_loader._collect_entry_caps({
			caps = { db = { type = "db", readonly = false } },
			entry = {
				server = {
					caps = { db = { type = "db", readonly = true } },
				},
			},
		}, "server")
		T.eq(caps.db.readonly, true)
	end)

	T.it("adds missing type field from key", function()
		local caps = app_loader._collect_entry_caps({
			caps = { http_server = { port = 0 } },
		}, "server")
		T.eq(caps.http_server.type, "http_server")
	end)

	T.it("returns empty when no caps declared", function()
		local caps = app_loader._collect_entry_caps({}, "server")
		T.eq(next(caps), nil)
	end)

	T.it("falls back to manifest.entries if manifest.entry missing", function()
		local caps = app_loader._collect_entry_caps({
			entries = {
				server = { caps = { self = "required" } },
			},
		}, "server")
		T.eq(caps.self.type, "self")
		T.eq(caps.self.required, true)
	end)
end)

T.describe("app_loader._auto_grants", function()
	T.it("grants every declared cap", function()
		local grants = app_loader._auto_grants({
			http_server = { type = "http_server" },
			kv = { type = "kv" },
		})
		T.eq(grants.http_server, true)
		T.eq(grants.kv, true)
	end)

	T.it("empty decls -> empty grants", function()
		local grants = app_loader._auto_grants({})
		T.eq(next(grants), nil)
	end)
end)

T.describe("app_loader._make_http_server_override", function()
	T.it("override.build returns a daemon-mode http_server cap", function()
		local override, get_captured = app_loader._make_http_server_override("abc",
			function(id) return "http://app-" .. id .. ".test" end)
		local cap = override.build({ type = "http_server" })
		T.ok(cap, "cap returned")
		T.eq(cap.port, 0)
		T.eq(cap.url, "http://app-abc.test")
		T.eq(get_captured(), nil, "nothing captured before serve")

		local handler = function() end
		cap.serve(handler)
		T.eq(get_captured(), handler)
	end)

	T.it("app_url is optional; empty url fallback", function()
		local override, _ = app_loader._make_http_server_override("abc", nil)
		local cap = override.build({ type = "http_server" })
		T.eq(cap.url, "")
	end)
end)

T.describe("app_loader.make end-to-end failure modes", function()
	T.it("returns error when index_db is nil", function()
		local loader = app_loader.make({})
		local h, err = loader("anything")
		T.eq(h, nil)
		T.ok(err:find("no index_db"), "error mentions index_db")
	end)

	T.it("returns error when app not found in index", function()
		local fake_index = { get = function(_self, _id) return nil end }
		local loader = app_loader.make({ index_db = fake_index })
		local h, err = loader("missing-app")
		T.eq(h, nil)
		T.ok(err:find("not found"), "error mentions not found")
	end)

	T.it("returns error when load_app cannot read file", function()
		local fake_index = { get = function(_self, _id)
			return { path = "/nonexistent/path/does-not-exist.png" }
		end }
		local loader = app_loader.make({ index_db = fake_index })
		local h, err = loader("ghost")
		T.eq(h, nil)
		T.ok(err:find("load_app failed"), "error mentions load_app")
	end)
end)

T.describe("app_loader cap config merge", function()
	T.it("collect_entry_caps merged with get_cap_config overrides", function()
		-- This tests the merge logic in isolation: simulate what make() does.
		local decls = app_loader._collect_entry_caps({
			caps = { characters = { type = "fs", root = "~/SillyTavern/public/characters", readonly = true } }
		}, "server")

		-- Fake index_db with get_cap_config returning a root override.
		local fake_index = {
			get_cap_config = function(_self, _app_id, cap_name)
				if cap_name == "characters" then
					return { root = "/mnt/ssd/ai/SillyTavern/public/characters" }
				end
				return {}
			end,
		}

		for name, decl in pairs(decls) do
			local overrides = fake_index:get_cap_config("app1", name)
			for k, v in pairs(overrides) do decl[k] = v end
		end

		T.eq(decls.characters.root, "/mnt/ssd/ai/SillyTavern/public/characters")
		T.eq(decls.characters.readonly, true)  -- non-overridden field preserved
	end)

	T.it("get_cap_config absent on index_db is handled gracefully", function()
		-- index_db without get_cap_config (old interface / raw db handle).
		local fake_index = { get = function(_self, _id)
			return { path = "/nonexistent/path.png" }
		end }
		local loader = app_loader.make({ index_db = fake_index })
		-- Will fail at load_app, but the cap-config guard must not blow up first.
		local h, err = loader("any")
		T.eq(h, nil)
		T.ok(err:find("load_app failed"), "failed at load_app, not cap config guard")
	end)
end)
