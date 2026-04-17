-- lib/platform/index_test.lua
if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local index = require("lib.platform.index")

-- Use in-memory SQLite for tests.
local DB_PATH = ":memory:"

T.describe("platform index", function()

	T.describe("open", function()
		T.it("opens an in-memory database", function()
			local idx, err = index.open(DB_PATH)
			T.ok(idx, "open returned nil: " .. tostring(err))
			idx:close()
		end)
	end)

	T.describe("install", function()
		T.it("installs an app and returns its id", function()
			local idx = index.open(DB_PATH)
			local manifest = {
				name = "Test App",
				version = "1.0.0",
				meta = { tags = { "test", "demo" } },
			}
			local id, err = idx:install("/path/to/app.png", manifest, 1000000)
			T.ok(id, "install returned nil: " .. tostring(err))
			T.ok(id > 0, "id should be positive")
			idx:close()
		end)

		T.it("rejects missing app_path", function()
			local idx = index.open(DB_PATH)
			local id, err = idx:install("", { name = "x" }, 1000)
			T.ok(not id)
			T.ok(err:find("app_path"))
			idx:close()
		end)

		T.it("rejects missing manifest", function()
			local idx = index.open(DB_PATH)
			local id, err = idx:install("/x.png", "not a table", 1000)
			T.ok(not id)
			T.ok(err:find("manifest"))
			idx:close()
		end)

		T.it("rejects missing timestamp", function()
			local idx = index.open(DB_PATH)
			local id, err = idx:install("/x.png", { name = "x" })
			T.ok(not id)
			T.ok(err:find("timestamp"))
			idx:close()
		end)

		T.it("replaces existing app with same path", function()
			local idx = index.open(DB_PATH)
			local m1 = { name = "App v1", meta = { tags = { "old" } } }
			local m2 = { name = "App v2", meta = { tags = { "new" } } }
			idx:install("/app.png", m1, 1000)
			idx:install("/app.png", m2, 2000)
			local all = idx:list()
			T.eq(#all, 1, "should have one entry after replace")
			T.eq(all[1].name, "App v2")
			idx:close()
		end)

		T.it("derives name from path if manifest.name is nil", function()
			local idx = index.open(DB_PATH)
			idx:install("/some/dir/coolapp.png", { version = "1.0" }, 1000)
			local all = idx:list()
			T.eq(#all, 1)
			T.eq(all[1].name, "coolapp")
			idx:close()
		end)

		T.it("preserves id on reinstall at the same path", function()
			-- Previously INSERT OR REPLACE created a new AUTOINCREMENT id
			-- on every reinstall, which would orphan derived rows
			-- (app_tags, apps_fts) pointing at the old id. We now UPDATE in
			-- place for same-path reinstalls.
			local idx = index.open(DB_PATH)
			local id1 = idx:install("/app.png", { name = "v1" }, 1000)
			local id2 = idx:install("/app.png", { name = "v2" }, 2000)
			T.eq(id1, id2, "id must be stable across reinstall")
			idx:close()
		end)

		T.it("syncs app_tags rows with the manifest's tags", function()
			local idx = index.open(DB_PATH)
			local id = idx:install("/app.png", {
				name = "A", meta = { tags = { "one", "two" } },
			}, 1000)
			local iter = idx._db:query(
				"SELECT t.name FROM app_tags at JOIN tags t ON t.id = at.tag_id " ..
				"WHERE at.app_id = ? ORDER BY t.name", id)
			local names = {}
			for n in iter do names[#names + 1] = n end
			T.eq(#names, 2)
			T.eq(names[1], "one")
			T.eq(names[2], "two")
			idx:close()
		end)

		T.it("reinstall replaces tag associations (no stale rows)", function()
			local idx = index.open(DB_PATH)
			local id = idx:install("/app.png", {
				name = "A", meta = { tags = { "keep", "drop" } },
			}, 1000)
			idx:install("/app.png", {
				name = "A", meta = { tags = { "keep", "added" } },
			}, 2000)
			local iter = idx._db:query(
				"SELECT t.name FROM app_tags at JOIN tags t ON t.id = at.tag_id " ..
				"WHERE at.app_id = ? ORDER BY t.name", id)
			local names = {}
			for n in iter do names[#names + 1] = n end
			T.eq(#names, 2)
			T.eq(names[1], "added")
			T.eq(names[2], "keep")
			idx:close()
		end)
	end)

	T.describe("get", function()
		T.it("returns installed app by id", function()
			local idx = index.open(DB_PATH)
			local manifest = {
				name = "Get Test",
				version = "2.0",
				meta = { tags = { "alpha" } },
			}
			local id = idx:install("/get.png", manifest, 5000)
			local row = idx:get(id)
			T.ok(row)
			T.eq(row.id, id)
			T.eq(row.name, "Get Test")
			T.eq(row.path, "/get.png")
			T.ok(row.manifest)
			T.eq(row.manifest.version, "2.0")
			T.eq(row.tags[1], "alpha")
			T.eq(row.installed_at, 5000)
			idx:close()
		end)

		T.it("returns nil for nonexistent id", function()
			local idx = index.open(DB_PATH)
			T.ok(not idx:get(9999))
			idx:close()
		end)
	end)

	T.describe("uninstall", function()
		T.it("removes an app by id", function()
			local idx = index.open(DB_PATH)
			local id = idx:install("/rm.png", { name = "Gone" }, 1000)
			T.ok(idx:get(id))
			idx:uninstall(id)
			T.ok(not idx:get(id))
			idx:close()
		end)

		T.it("cleans up app_tags and apps_fts rows", function()
			local idx = index.open(DB_PATH)
			local id = idx:install("/rm.png", {
				name = "Gone", meta = { tags = { "x", "y" } },
			}, 1000)
			idx:uninstall(id)
			local at_iter = idx._db:query(
				"SELECT COUNT(*) FROM app_tags WHERE app_id = ?", id)
			T.eq(at_iter(), 0, "app_tags rows left behind after uninstall")
			local fts_iter = idx._db:query(
				"SELECT COUNT(*) FROM apps_fts WHERE rowid = ?", id)
			T.eq(fts_iter(), 0, "apps_fts row left behind after uninstall")
			idx:close()
		end)
	end)

	T.describe("apps_fts search", function()
		T.it("trigram matches on name", function()
			local idx = index.open(DB_PATH)
			idx:install("/alice.png", { name = "Alice" }, 1000)
			idx:install("/bob.png",   { name = "Bob"   }, 1001)
			local iter = idx._db:query(
				"SELECT rowid FROM apps_fts WHERE apps_fts MATCH 'ali'")
			local hits = {}
			for id in iter do hits[#hits + 1] = id end
			T.eq(#hits, 1)
			idx:close()
		end)

		T.it("trigram matches on description", function()
			local idx = index.open(DB_PATH)
			idx:install("/a.png", {
				name = "A", meta = { description = "Roleplay dungeon" },
			}, 1000)
			idx:install("/b.png", { name = "B" }, 1001)
			local iter = idx._db:query(
				"SELECT COUNT(*) FROM apps_fts WHERE apps_fts MATCH 'dung'")
			T.eq(iter(), 1)
			idx:close()
		end)

		T.it("is case-insensitive", function()
			local idx = index.open(DB_PATH)
			idx:install("/a.png", { name = "AliceInWonderland" }, 1000)
			local iter = idx._db:query(
				"SELECT COUNT(*) FROM apps_fts WHERE apps_fts MATCH 'WONDER'")
			T.eq(iter(), 1)
			idx:close()
		end)

		T.it("reinstall updates the FTS row (no stale matches)", function()
			local idx = index.open(DB_PATH)
			idx:install("/a.png", { name = "OldName" }, 1000)
			idx:install("/a.png", { name = "NewName" }, 2000)
			local iter_old = idx._db:query(
				"SELECT COUNT(*) FROM apps_fts WHERE apps_fts MATCH 'OldN'")
			T.eq(iter_old(), 0, "stale FTS row matches old name")
			local iter_new = idx._db:query(
				"SELECT COUNT(*) FROM apps_fts WHERE apps_fts MATCH 'NewN'")
			T.eq(iter_new(), 1, "updated FTS row should match new name")
			idx:close()
		end)
	end)

	T.describe("list", function()
		T.it("returns all apps sorted by name", function()
			local idx = index.open(DB_PATH)
			idx:install("/b.png", { name = "Bravo", meta = { tags = { "x" } } }, 1000)
			idx:install("/a.png", { name = "Alpha", meta = { tags = { "x" } } }, 1001)
			idx:install("/c.png", { name = "Charlie", meta = { tags = { "y" } } }, 1002)
			local all = idx:list()
			T.eq(#all, 3)
			T.eq(all[1].name, "Alpha")
			T.eq(all[2].name, "Bravo")
			T.eq(all[3].name, "Charlie")
			idx:close()
		end)

		T.it("filters by tag", function()
			local idx = index.open(DB_PATH)
			idx:install("/a.png", { name = "A", meta = { tags = { "chat", "ai" } } }, 1000)
			idx:install("/b.png", { name = "B", meta = { tags = { "game" } } }, 1001)
			idx:install("/c.png", { name = "C", meta = { tags = { "chat" } } }, 1002)
			local chat_apps = idx:list({ tag = "chat" })
			T.eq(#chat_apps, 2)
			T.eq(chat_apps[1].name, "A")
			T.eq(chat_apps[2].name, "C")

			local game_apps = idx:list({ tag = "game" })
			T.eq(#game_apps, 1)
			T.eq(game_apps[1].name, "B")

			local none = idx:list({ tag = "nonexistent" })
			T.eq(#none, 0)
			idx:close()
		end)

		T.it("returns empty list for empty database", function()
			local idx = index.open(DB_PATH)
			T.eq(#idx:list(), 0)
			idx:close()
		end)
	end)

	T.describe("search", function()
		T.it("searches by name substring", function()
			local idx = index.open(DB_PATH)
			idx:install("/a.png", { name = "Alice Character" }, 1000)
			idx:install("/b.png", { name = "Bob Character" }, 1001)
			idx:install("/c.png", { name = "Charlie Bot" }, 1002)

			local results = idx:search("Character")
			T.eq(#results, 2)
			T.eq(results[1].name, "Alice Character")
			T.eq(results[2].name, "Bob Character")

			local bots = idx:search("Bot")
			T.eq(#bots, 1)
			T.eq(bots[1].name, "Charlie Bot")

			local none = idx:search("zzz")
			T.eq(#none, 0)
			idx:close()
		end)

		T.it("search is case-insensitive", function()
			local idx = index.open(DB_PATH)
			idx:install("/a.png", { name = "Alice" }, 1000)
			local results = idx:search("alice")
			T.eq(#results, 1)
			T.eq(results[1].name, "Alice")
			idx:close()
		end)
	end)

	T.describe("grants", function()
		T.it("get_grants returns empty table when no decisions stored", function()
			local idx = index.open(DB_PATH)
			local id = idx:install("/a.png", { name = "App" }, 1000)
			local g = idx:get_grants(id)
			T.eq(type(g), "table")
			T.eq(next(g), nil)
			idx:close()
		end)

		T.it("set_grant + get_grants round-trips grant=true", function()
			local idx = index.open(DB_PATH)
			local id = idx:install("/a.png", { name = "App" }, 1000)
			local ok, err = idx:set_grant(id, "characters", true)
			T.ok(ok, tostring(err))
			local g = idx:get_grants(id)
			T.eq(g.characters, true)
			idx:close()
		end)

		T.it("set_grant + get_grants round-trips granted=false", function()
			local idx = index.open(DB_PATH)
			local id = idx:install("/a.png", { name = "App" }, 1000)
			idx:set_grant(id, "net", false)
			local g = idx:get_grants(id)
			T.eq(g.net, false)
			idx:close()
		end)

		T.it("set_grant replaces previous decision", function()
			local idx = index.open(DB_PATH)
			local id = idx:install("/a.png", { name = "App" }, 1000)
			idx:set_grant(id, "db", true)
			idx:set_grant(id, "db", false)
			local g = idx:get_grants(id)
			T.eq(g.db, false)
			idx:close()
		end)

		T.it("clear_grants removes all decisions", function()
			local idx = index.open(DB_PATH)
			local id = idx:install("/a.png", { name = "App" }, 1000)
			idx:set_grant(id, "db", true)
			idx:set_grant(id, "fs", false)
			idx:clear_grants(id)
			local g = idx:get_grants(id)
			T.eq(next(g), nil)
			idx:close()
		end)

		T.it("uninstall clears grant rows", function()
			local idx = index.open(DB_PATH)
			local id = idx:install("/a.png", { name = "App" }, 1000)
			idx:set_grant(id, "db", true)
			idx:uninstall(id)
			local g = idx:get_grants(id)
			T.eq(next(g), nil)
			idx:close()
		end)

		T.it("grants are independent per app", function()
			local idx = index.open(DB_PATH)
			local id1 = idx:install("/a.png", { name = "App1" }, 1000)
			local id2 = idx:install("/b.png", { name = "App2" }, 1001)
			idx:set_grant(id1, "db", true)
			idx:set_grant(id2, "db", false)
			T.eq(idx:get_grants(id1).db, true)
			T.eq(idx:get_grants(id2).db, false)
			idx:close()
		end)
	end)

	T.describe("cap config", function()
		T.it("get_cap_config returns empty table when no overrides set", function()
			local idx = index.open(DB_PATH)
			local id = idx:install("/a.png", { name = "App" }, 1000)
			local cfg = idx:get_cap_config(id, "characters")
			T.eq(type(cfg), "table")
			T.eq(next(cfg), nil)
			idx:close()
		end)

		T.it("set_cap_config persists and get_cap_config retrieves", function()
			local idx = index.open(DB_PATH)
			local id = idx:install("/a.png", { name = "App" }, 1000)
			local ok, err = idx:set_cap_config(id, "characters", { root = "/mnt/ssd/ai/SillyTavern/public/characters" })
			T.ok(ok, tostring(err))
			local cfg = idx:get_cap_config(id, "characters")
			T.eq(cfg.root, "/mnt/ssd/ai/SillyTavern/public/characters")
			idx:close()
		end)

		T.it("set_cap_config replaces previous overrides", function()
			local idx = index.open(DB_PATH)
			local id = idx:install("/a.png", { name = "App" }, 1000)
			idx:set_cap_config(id, "db", { path = "/old/path.db" })
			idx:set_cap_config(id, "db", { path = "/new/path.db" })
			local cfg = idx:get_cap_config(id, "db")
			T.eq(cfg.path, "/new/path.db")
			idx:close()
		end)

		T.it("set_cap_config rejects non-table overrides", function()
			local idx = index.open(DB_PATH)
			local id = idx:install("/a.png", { name = "App" }, 1000)
			local ok, err = idx:set_cap_config(id, "db", "bad")
			T.ok(not ok)
			T.ok(err and err:find("table", 1, true))
			idx:close()
		end)

		T.it("reset_cap_config reverts to empty overrides", function()
			local idx = index.open(DB_PATH)
			local id = idx:install("/a.png", { name = "App" }, 1000)
			idx:set_cap_config(id, "characters", { root = "/mnt/x" })
			idx:reset_cap_config(id, "characters")
			local cfg = idx:get_cap_config(id, "characters")
			T.eq(next(cfg), nil)
			idx:close()
		end)

		T.it("uninstall clears cap config rows", function()
			local idx = index.open(DB_PATH)
			local id = idx:install("/a.png", { name = "App" }, 1000)
			idx:set_cap_config(id, "characters", { root = "/mnt/x" })
			idx:uninstall(id)
			-- Re-open to confirm row is gone (in-memory so reopen = fresh db,
			-- just check the method works cleanly on a missing app_id).
			local cfg = idx:get_cap_config(id, "characters")
			T.eq(next(cfg), nil)
			idx:close()
		end)

		T.it("configs for different caps are independent", function()
			local idx = index.open(DB_PATH)
			local id = idx:install("/a.png", { name = "App" }, 1000)
			idx:set_cap_config(id, "characters", { root = "/chars" })
			idx:set_cap_config(id, "meta_cache", { path = "/cache.db" })
			T.eq(idx:get_cap_config(id, "characters").root, "/chars")
			T.eq(idx:get_cap_config(id, "meta_cache").path, "/cache.db")
			idx:close()
		end)
	end)

end)
