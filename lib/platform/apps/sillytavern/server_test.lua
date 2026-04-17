-- lib/platform/apps/sillytavern/server_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local json   = require("lib.format.json")
local server = require("lib.platform.apps.sillytavern.server")

-- ── Helpers ────────────────────────────────────────────────────────────────

local function make_fs(files, err)
	return {
		list = function(_) return files, err end,
		read = function(_) return nil, "read not implemented in stub" end,
	}
end

local function make_req(path, query)
	return { method = "GET", path = path, query = query, headers = {} }
end

local function make_res()
	return { status = nil, headers = {}, body = nil }
end

local function call(app, path, query)
	local req = make_req(path, query)
	local res = make_res()
	app.handler(req, res)
	return res, res.body and json.decode(res.body)
end

-- A small fake character directory.
local FAKE_FILES = {
	"Alice.png", "Bob.png", "Charlie.png", "alice_v2.png",
	"readme.txt",          -- non-image; must be excluded
	"Zara.webp",           -- webp allowed
	"thumb.jpg",           -- jpg allowed
}

-- ── Unit helpers ────────────────────────────────────────────────────────────

T.describe("sillytavern server helpers", function()
	T.it("name_from_file strips single extension", function()
		T.eq(server._name_from_file("alice.png"), "alice")
		T.eq(server._name_from_file("Bob.webp"),  "Bob")
	end)

	T.it("name_from_file strips only the last extension", function()
		T.eq(server._name_from_file("alice.card.png"), "alice.card")
	end)

	T.it("name_from_file returns the filename unchanged when no extension", function()
		T.eq(server._name_from_file("nodot"), "nodot")
	end)

	T.it("matches is case-insensitive substring", function()
		T.ok(server._matches("Alice in Wonderland", "alice"))
		T.ok(server._matches("Alice in Wonderland", "WONDER"))
		T.ok(not server._matches("Alice", "bob"))
	end)

	T.it("matches returns true for empty / nil query", function()
		T.ok(server._matches("Alice", ""))
		T.ok(server._matches("Alice", nil))
	end)

	T.it("parse_query parses key=value pairs", function()
		local p = server._parse_query("q=hello&limit=10")
		T.eq(p.q, "hello")
		T.eq(p.limit, "10")
	end)

	T.it("parse_query decodes percent-encoding", function()
		local p = server._parse_query("q=hello%20world")
		T.eq(p.q, "hello world")
	end)
end)

-- ── GET /discover ───────────────────────────────────────────────────────────

T.describe("GET /discover", function()
	T.it("returns all entries under default limit", function()
		local app = server.create({ characters = make_fs(FAKE_FILES) })
		local res, data = call(app, "/discover")
		T.eq(res.status, 200)
		T.ok(data.entries)
		-- readme.txt excluded; 6 image files remain (4 PNG + webp + jpg).
		T.eq(data.total, 6)
		T.eq(data.source_name, "SillyTavern")
		T.eq(data.limit, 200)
		T.eq(data.offset, 0)
	end)

	T.it("excludes non-image files", function()
		local app = server.create({ characters = make_fs({ "foo.txt", "bar.lua", "card.png" }) })
		local _, data = call(app, "/discover")
		T.eq(data.total, 1)
		T.eq(data.entries[1].name, "card")
	end)

	T.it("entries are sorted alphabetically by name", function()
		local app = server.create({ characters = make_fs(FAKE_FILES) })
		local _, data = call(app, "/discover")
		local names = {}
		for i = 1, #data.entries do names[i] = data.entries[i].name end
		-- Sorted case-insensitively: alice, Alice_v2 (both "alice*"), Bob, Charlie, Zara/thumb
		-- Just verify strictly ascending order.
		for i = 2, #names do
			T.ok(names[i-1]:lower() <= names[i]:lower(),
				"not sorted: " .. names[i-1] .. " > " .. names[i])
		end
	end)

	T.it("paginates with limit", function()
		local app = server.create({ characters = make_fs(FAKE_FILES) })
		local _, data = call(app, "/discover", "limit=2")
		T.eq(#data.entries, 2)
		T.eq(data.total, 6)
		T.eq(data.limit, 2)
		T.eq(data.offset, 0)
	end)

	T.it("paginates with offset", function()
		local app = server.create({ characters = make_fs(FAKE_FILES) })
		local _, data1 = call(app, "/discover", "limit=2")
		local _, data2 = call(app, "/discover", "limit=2&offset=2")
		-- The two pages must not overlap.
		local ids1 = {}
		for _, e in ipairs(data1.entries) do ids1[e.id] = true end
		for _, e in ipairs(data2.entries) do
			T.ok(not ids1[e.id], "overlap: " .. e.id)
		end
		T.eq(data2.offset, 2)
	end)

	T.it("clamps overlarge limit to 500", function()
		local app = server.create({ characters = make_fs(FAKE_FILES) })
		local _, data = call(app, "/discover", "limit=99999")
		T.eq(data.limit, 500)
	end)

	T.it("clamps non-positive limit to 1", function()
		local app = server.create({ characters = make_fs(FAKE_FILES) })
		local _, data = call(app, "/discover", "limit=0")
		T.eq(data.limit, 1)
		T.eq(#data.entries, 1)
	end)

	T.it("search filters by name (case-insensitive)", function()
		local app = server.create({ characters = make_fs(FAKE_FILES) })
		local _, data = call(app, "/discover", "q=alice")
		-- "Alice.png" and "alice_v2.png" both match
		T.eq(data.total, 2)
		for _, e in ipairs(data.entries) do
			T.ok(e.name:lower():find("alice", 1, true), "unexpected entry: " .. e.name)
		end
	end)

	T.it("search with no match returns empty entries", function()
		local app = server.create({ characters = make_fs(FAKE_FILES) })
		local _, data = call(app, "/discover", "q=zzznomatch")
		T.eq(data.total, 0)
		T.eq(#data.entries, 0)
	end)

	T.it("total reflects search, not full dir", function()
		local app = server.create({ characters = make_fs(FAKE_FILES) })
		local _, data = call(app, "/discover", "q=bob&limit=1")
		T.eq(data.total, 1)
		T.eq(#data.entries, 1)
		T.eq(data.entries[1].name, "Bob")
	end)

	T.it("each entry has the expected fields", function()
		local app = server.create({ characters = make_fs({ "MyChar.png" }) })
		local _, data = call(app, "/discover")
		local e = data.entries[1]
		T.ok(e.id,   "entry must have id")
		T.ok(e.name, "entry must have name")
		T.eq(e.name, "MyChar")
		T.ok(e.tags ~= nil,    "entry must have tags array")
		-- description and thumb_url are nil in the stub; json.encode omits them.
	end)

	T.it("entry id is the original filename with extension", function()
		local app = server.create({ characters = make_fs({ "Cool Card.png" }) })
		local _, data = call(app, "/discover")
		T.eq(data.entries[1].id, "Cool Card.png")
	end)

	T.it("returns empty result when directory is inaccessible", function()
		local app = server.create({ characters = make_fs(nil, "permission denied") })
		local res, data = call(app, "/discover")
		T.eq(res.status, 200)
		T.eq(data.total, 0)
		T.eq(#data.entries, 0)
		T.ok(data.error and data.error:find("unavailable", 1, true))
	end)

	T.it("returns empty when directory is empty", function()
		local app = server.create({ characters = make_fs({}) })
		local _, data = call(app, "/discover")
		T.eq(data.total, 0)
		T.eq(#data.entries, 0)
	end)

	T.it("offset beyond total returns empty entries with correct total", function()
		local app = server.create({ characters = make_fs(FAKE_FILES) })
		local _, data = call(app, "/discover", "offset=9999")
		T.eq(data.total, 6)
		T.eq(#data.entries, 0)
	end)
end)

-- ── Non-discover endpoints ─────────────────────────────────────────────────

T.describe("other endpoints", function()
	T.it("GET / returns 404", function()
		local app = server.create({ characters = make_fs(FAKE_FILES) })
		local res = make_res()
		app.handler(make_req("/"), res)
		T.eq(res.status, 404)
	end)

	T.it("POST /discover returns 405", function()
		local app = server.create({ characters = make_fs(FAKE_FILES) })
		local req = { method = "POST", path = "/discover", headers = {} }
		local res = make_res()
		app.handler(req, res)
		T.eq(res.status, 405)
	end)
end)
