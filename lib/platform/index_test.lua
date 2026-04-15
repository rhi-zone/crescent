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

end)
