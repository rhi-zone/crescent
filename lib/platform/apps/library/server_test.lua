-- lib/platform/apps/library/server_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local json = require("lib.format.json")
local server = require("lib.platform.apps.library.server")
local index = require("lib.platform.index")

-- ── Test helpers ────────────────────────────────────────────────────────────

local function make_req(method, path, query)
	return { method = method, path = path, query = query, headers = {} }
end

local function make_res()
	return { status = nil, headers = {}, body = nil }
end

local function call(app, method, path, query)
	local req = make_req(method, path, query)
	local res = make_res()
	app.handler(req, res)
	return res, res.body and json.decode(res.body)
end

-- Build a test index with sample apps.
local function make_test_index()
	local idx = index.open(":memory:")
	idx:install("/apps/alice.png", {
		name = "Alice",
		meta = { description = "A helpful AI", tags = { "ai", "chat" } },
	}, 1000)
	idx:install("/apps/calc.png", {
		name = "Calculator",
		meta = { description = "Math tool", tags = { "utility", "math" } },
	}, 2000)
	idx:install("/apps/dungeon.png", {
		name = "Dungeon Master",
		meta = { description = "RPG adventure", tags = { "ai", "roleplay", "chat" } },
	}, 3000)
	return idx
end

-- ── Static file serving ─────────────────────────────────────────────────────

T.describe("library server", function()

	T.describe("static files", function()
		T.it("serves index.html at /", function()
			local app = server.create({ index_db = nil })
			local res = call(app, "GET", "/")
			T.eq(res.status, 200)
			T.ok(res.headers["Content-Type"][1]:find("text/html"))
			T.ok(res.body:find("<!DOCTYPE html>"))
		end)

		T.it("serves app.js", function()
			local app = server.create({ index_db = nil })
			local res = call(app, "GET", "/app.js")
			T.eq(res.status, 200)
			T.ok(res.headers["Content-Type"][1]:find("javascript"))
			T.ok(res.body:find("fetch"))
		end)

		T.it("serves style.css", function()
			local app = server.create({ index_db = nil })
			local res = call(app, "GET", "/style.css")
			T.eq(res.status, 200)
			T.ok(res.headers["Content-Type"][1]:find("text/css"))
		end)

		T.it("returns nil for unknown paths", function()
			local app = server.create({ index_db = nil })
			local req = make_req("GET", "/unknown")
			local res = make_res()
			local handled = app.handler(req, res)
			T.eq(handled, nil)
		end)
	end)

	-- ── API: list apps ──────────────────────────────────────────────────────

	T.describe("GET /api/apps", function()
		T.it("returns all apps", function()
			local idx = make_test_index()
			local app = server.create({ index_db = idx._db })
			local res, data = call(app, "GET", "/api/apps")
			T.eq(res.status, 200)
			T.ok(data.apps)
			T.eq(#data.apps, 3)
			T.eq(data.apps[1].name, "Alice")
			T.eq(data.apps[2].name, "Calculator")
			T.eq(data.apps[3].name, "Dungeon Master")
			idx:close()
		end)

		T.it("returns empty list when no apps", function()
			local idx = index.open(":memory:")
			local app = server.create({ index_db = idx._db })
			local res, data = call(app, "GET", "/api/apps")
			T.eq(res.status, 200)
			T.eq(#data.apps, 0)
			idx:close()
		end)

		T.it("returns empty list when no db", function()
			local app = server.create({ index_db = nil })
			local res, data = call(app, "GET", "/api/apps")
			T.eq(res.status, 200)
			T.eq(#data.apps, 0)
		end)

		T.it("filters by tag", function()
			local idx = make_test_index()
			local app = server.create({ index_db = idx._db })
			local res, data = call(app, "GET", "/api/apps", "tag=ai")
			T.eq(res.status, 200)
			T.eq(#data.apps, 2)
			T.eq(data.apps[1].name, "Alice")
			T.eq(data.apps[2].name, "Dungeon Master")
			idx:close()
		end)

		T.it("searches by name", function()
			local idx = make_test_index()
			local app = server.create({ index_db = idx._db })
			local res, data = call(app, "GET", "/api/apps", "q=calc")
			T.eq(res.status, 200)
			T.eq(#data.apps, 1)
			T.eq(data.apps[1].name, "Calculator")
			idx:close()
		end)

		T.it("searches and filters by tag simultaneously", function()
			local idx = make_test_index()
			local app = server.create({ index_db = idx._db })
			local res, data = call(app, "GET", "/api/apps", "tag=chat&q=dun")
			T.eq(res.status, 200)
			T.eq(#data.apps, 1)
			T.eq(data.apps[1].name, "Dungeon Master")
			idx:close()
		end)

		T.it("returns description and tags in response", function()
			local idx = make_test_index()
			local app = server.create({ index_db = idx._db })
			local res, data = call(app, "GET", "/api/apps")
			local alice = data.apps[1]
			T.eq(alice.description, "A helpful AI")
			T.ok(#alice.tags >= 2)
			idx:close()
		end)

		T.it("returns path in response", function()
			local idx = make_test_index()
			local app = server.create({ index_db = idx._db })
			local res, data = call(app, "GET", "/api/apps")
			T.eq(data.apps[1].path, "/apps/alice.png")
			idx:close()
		end)
	end)

	-- ── Query string parsing ────────────────────────────────────────────────

	T.describe("parse_query", function()
		T.it("parses key=value pairs", function()
			local p = server._parse_query("tag=ai&q=hello")
			T.eq(p.tag, "ai")
			T.eq(p.q, "hello")
		end)

		T.it("handles empty string", function()
			local p = server._parse_query("")
			T.eq(next(p), nil)
		end)

		T.it("handles nil", function()
			local p = server._parse_query(nil)
			T.eq(next(p), nil)
		end)

		T.it("decodes percent-encoded values", function()
			local p = server._parse_query("q=hello%20world")
			T.eq(p.q, "hello world")
		end)

		T.it("decodes + as space", function()
			local p = server._parse_query("q=hello+world")
			T.eq(p.q, "hello world")
		end)

		T.it("handles key without value", function()
			local p = server._parse_query("verbose")
			T.eq(p.verbose, "")
		end)
	end)

	-- ── create returns handler ──────────────────────────────────────────────

	T.describe("create", function()
		T.it("returns table with handler function", function()
			local app = server.create({ index_db = nil })
			T.eq(type(app), "table")
			T.eq(type(app.handler), "function")
		end)
	end)

end)
