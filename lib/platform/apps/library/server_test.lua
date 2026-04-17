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
		T.it("returns all apps under default limit", function()
			local idx = make_test_index()
			local app = server.create({ index_db = idx._db })
			local res, data = call(app, "GET", "/api/apps")
			T.eq(res.status, 200)
			T.ok(data.apps)
			T.eq(#data.apps, 3)
			T.eq(data.total, 3)
			T.eq(data.limit, 200)
			T.eq(data.offset, 0)
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
			T.eq(data.total, 0)
			idx:close()
		end)

		T.it("returns empty list when no db", function()
			local app = server.create({ index_db = nil })
			local res, data = call(app, "GET", "/api/apps")
			T.eq(res.status, 200)
			T.eq(#data.apps, 0)
			T.eq(data.total, 0)
		end)

		T.it("paginates with limit", function()
			local idx = make_test_index()
			local app = server.create({ index_db = idx._db })
			local res, data = call(app, "GET", "/api/apps", "limit=2")
			T.eq(res.status, 200)
			T.eq(#data.apps, 2)
			T.eq(data.total, 3)
			T.eq(data.limit, 2)
			T.eq(data.offset, 0)
			T.eq(data.apps[1].name, "Alice")
			T.eq(data.apps[2].name, "Calculator")
			idx:close()
		end)

		T.it("paginates with offset", function()
			local idx = make_test_index()
			local app = server.create({ index_db = idx._db })
			local res, data = call(app, "GET", "/api/apps", "limit=2&offset=2")
			T.eq(res.status, 200)
			T.eq(#data.apps, 1)
			T.eq(data.total, 3)
			T.eq(data.offset, 2)
			T.eq(data.apps[1].name, "Dungeon Master")
			idx:close()
		end)

		T.it("clamps oversize limit to 500", function()
			local idx = make_test_index()
			local app = server.create({ index_db = idx._db })
			local res, data = call(app, "GET", "/api/apps", "limit=999999")
			T.eq(res.status, 200)
			T.eq(data.limit, 500)
			idx:close()
		end)

		T.it("clamps non-positive limit to 1", function()
			local idx = make_test_index()
			local app = server.create({ index_db = idx._db })
			local res, data = call(app, "GET", "/api/apps", "limit=0")
			T.eq(res.status, 200)
			T.eq(data.limit, 1)
			T.eq(#data.apps, 1)
			idx:close()
		end)

		T.it("total reflects filter, not full table", function()
			local idx = make_test_index()
			local app = server.create({ index_db = idx._db })
			local res, data = call(app, "GET", "/api/apps", "tag=ai&limit=1")
			T.eq(res.status, 200)
			-- Two apps match tag=ai; page size is 1 so apps has one row.
			T.eq(data.total, 2)
			T.eq(#data.apps, 1)
			T.eq(data.limit, 1)
			idx:close()
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

	-- ── GET /api/sources ───────────────────────────────────────────────────

	T.describe("GET /api/sources", function()
		T.it("returns empty list when no sources configured", function()
			local app = server.create({ index_db = nil })
			local res, data = call(app, "GET", "/api/sources")
			T.eq(res.status, 200)
			T.ok(data.sources)
			T.eq(#data.sources, 0)
		end)

		T.it("returns registered source ids and names", function()
			local app = server.create({
				index_db = nil,
				sources = {
					{ id = "st", name = "SillyTavern", discover = function(_) return { entries = {} } end },
					{ id = "steam", name = "Steam",       discover = function(_) return { entries = {} } end },
				},
			})
			local res, data = call(app, "GET", "/api/sources")
			T.eq(res.status, 200)
			T.eq(#data.sources, 2)
			T.eq(data.sources[1].id, "st")
			T.eq(data.sources[1].name, "SillyTavern")
			T.eq(data.sources[2].id, "steam")
		end)
	end)

	-- ── GET /api/sources/:id/discover ──────────────────────────────────────

	T.describe("GET /api/sources/:id/discover", function()
		local function make_source(id, entries)
			return {
				id = id, name = id,
				discover = function(params)
					local limit = tonumber(params.limit) or 10
					local page = {}
					for i = 1, math.min(limit, #entries) do page[i] = entries[i] end
					return { source_name = id, total = #entries, limit = limit, offset = 0, entries = page }
				end,
			}
		end

		T.it("proxies to the source's discover function", function()
			local entries = { { id = "a.png", name = "Alice", tags = {}, description = nil } }
			local app = server.create({
				index_db = nil,
				sources = { make_source("st", entries) },
			})
			local res, data = call(app, "GET", "/api/sources/st/discover")
			T.eq(res.status, 200)
			T.eq(data.source_name, "st")
			T.eq(#data.entries, 1)
			T.eq(data.entries[1].name, "Alice")
		end)

		T.it("passes query params to discover function", function()
			local received = {}
			local app = server.create({
				index_db = nil,
				sources = {{
					id = "st", name = "SillyTavern",
					discover = function(params)
						received.q = params.q
						received.limit = params.limit
						return { entries = {}, total = 0, limit = 10, offset = 0 }
					end,
				}},
			})
			call(app, "GET", "/api/sources/st/discover", "q=hello&limit=5")
			T.eq(received.q, "hello")
			T.eq(received.limit, "5")
		end)

		T.it("returns 404 for unknown source id", function()
			local app = server.create({ index_db = nil })
			local res = make_res()
			app.handler(make_req("GET", "/api/sources/unknown/discover"), res)
			T.eq(res.status, 404)
		end)

		T.it("handles percent-encoded source id in path", function()
			local app = server.create({
				index_db = nil,
				sources = {{ id = "my source", name = "My Source", discover = function(_) return { entries = {} } end }},
			})
			local res, data = call(app, "GET", "/api/sources/my%20source/discover")
			T.eq(res.status, 200)
			T.ok(data.entries ~= nil)
		end)

		T.it("rewrites thumb_url to library proxy path when source has handler", function()
			local entries = { { id = "Bob.png", name = "Bob" }, { id = "Alice.png", name = "Alice" } }
			local stub_handler = function(req, res)
				res.status = 200
				res.headers["Content-Type"] = { "image/png" }
				res.body = "PNG"
			end
			local app = server.create({
				index_db = nil,
				sources = {{
					id = "st", name = "SillyTavern",
					discover = function(_) return { entries = entries, total = 2, limit = 10, offset = 0 } end,
					handler = stub_handler,
				}},
			})
			local res, data = call(app, "GET", "/api/sources/st/discover")
			T.eq(res.status, 200)
			T.eq(data.entries[1].thumb_url, "/api/sources/st/thumb/Bob.png")
			T.eq(data.entries[2].thumb_url, "/api/sources/st/thumb/Alice.png")
		end)

		T.it("does not rewrite thumb_url when source has no handler", function()
			local entries = { { id = "x.png", name = "X", thumb_url = "http://external/x.png" } }
			local app = server.create({
				index_db = nil,
				sources = {{
					id = "ext", name = "External",
					discover = function(_) return { entries = entries, total = 1, limit = 10, offset = 0 } end,
				}},
			})
			local _, data = call(app, "GET", "/api/sources/ext/discover")
			T.eq(data.entries[1].thumb_url, "http://external/x.png")
		end)
	end)

	-- ── GET /api/sources/:id/thumb/:entry_id ────────────────────────────────
	T.describe("GET /api/sources/:id/thumb/:entry_id", function()
		local function make_source_with_thumb(id)
			return {
				id = id, name = id,
				discover = function(_) return { entries = {}, total = 0, limit = 10, offset = 0 } end,
				handler = function(req, res)
					local filename = (req.path or ""):match("^/thumb/(.+)$")
					if filename == "Bob.png" then
						res.status = 200
						res.headers["Content-Type"] = { "image/png" }
						res.body = "PNG:" .. filename
					else
						res.status = 404
						res.body = "not found"
					end
				end,
			}
		end

		T.it("proxies to source handler at /thumb/:entry_id", function()
			local app = server.create({
				index_db = nil,
				sources = { make_source_with_thumb("st") },
			})
			local res = make_res()
			app.handler(make_req("GET", "/api/sources/st/thumb/Bob.png"), res)
			T.eq(res.status, 200)
			T.eq(res.body, "PNG:Bob.png")
		end)

		T.it("returns 404 when source has no handler", function()
			local app = server.create({
				index_db = nil,
				sources = {{
					id = "st", name = "st",
					discover = function(_) return { entries = {} } end,
				}},
			})
			local res = make_res()
			app.handler(make_req("GET", "/api/sources/st/thumb/Bob.png"), res)
			T.eq(res.status, 404)
		end)

		T.it("returns 404 for unknown source", function()
			local app = server.create({ index_db = nil })
			local res = make_res()
			app.handler(make_req("GET", "/api/sources/unknown/thumb/Bob.png"), res)
			T.eq(res.status, 404)
		end)

		T.it("percent-decodes entry_id before forwarding", function()
			local received_path = nil
			local app = server.create({
				index_db = nil,
				sources = {{
					id = "st", name = "st",
					discover = function(_) return { entries = {} } end,
					handler = function(req, res)
						received_path = req.path
						res.status = 200
						res.body = ""
					end,
				}},
			})
			app.handler(make_req("GET", "/api/sources/st/thumb/My%20Card.png"), make_res())
			T.eq(received_path, "/thumb/My Card.png")
		end)
	end)

end)
