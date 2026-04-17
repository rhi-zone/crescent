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

local function make_fs_with_png(filename, png_bytes)
	return {
		list = function(_) return { filename } end,
		read = function(f)
			if f == filename then return png_bytes end
			return nil, "not found"
		end,
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

-- ── Metadata cache ────────────────────────────────────────────────────────

T.describe("metadata cache", function()
	local sqlite = require("lib.sqlite")
	local card_mod = require("lib.formats.ccv2.card")

	-- Build a minimal in-memory SQLite db and initialise the schema.
	local function make_cache_db()
		local db, err = sqlite.open(":memory:")
		T.ok(db, "sqlite open: " .. tostring(err))
		local cap = {
			execute = function(_, ...) return db:execute(...) end,
			query   = function(_, ...) return db:query(...) end,
		}
		return cap, db
	end

	T.it("init_cache creates the schema without error", function()
		local cap = make_cache_db()
		local result = server._init_cache(cap)
		T.ok(result ~= nil, "init_cache must return db on success")
	end)

	T.it("init_cache returns nil for nil input", function()
		T.eq(server._init_cache(nil), nil)
	end)

	T.it("ensure_cached falls back to filename-derived name when no db", function()
		local fs = make_fs(FAKE_FILES)
		local meta = server._ensure_cached(nil, fs, { "Alice.png" })
		T.eq(meta["Alice.png"].name, "Alice")
	end)

	T.it("ensure_cached reads PNG and populates cache on miss", function()
		local cap = make_cache_db()
		server._init_cache(cap)

		-- Build a real CCv2 card PNG in-memory.
		local card_bytes, err = card_mod.to_png({ name = "Aria", description = "A helpful mage", tags = { "fantasy", "magic" } })
		T.ok(card_bytes, "to_png failed: " .. tostring(err))

		local fs = make_fs_with_png("Aria.png", card_bytes)
		local meta = server._ensure_cached(cap, fs, { "Aria.png" })

		T.eq(meta["Aria.png"].name,        "Aria")
		T.eq(meta["Aria.png"].description, "A helpful mage")
		T.ok(#meta["Aria.png"].tags >= 2,  "expected 2 tags")
	end)

	T.it("ensure_cached returns cache hit on second call without re-reading", function()
		local cap = make_cache_db()
		server._init_cache(cap)

		local read_count = 0
		local fs = {
			list = function(_) return { "Bob.png" } end,
			read = function(_)
				read_count = read_count + 1
				local bytes, err2 = card_mod.to_png({ name = "Bob", tags = {} })
				return bytes, err2
			end,
		}

		server._ensure_cached(cap, fs, { "Bob.png" })
		T.eq(read_count, 1, "first call should read the file")

		server._ensure_cached(cap, fs, { "Bob.png" })
		T.eq(read_count, 1, "second call must use cache, not re-read")
	end)

	T.it("ensure_cached falls back to filename name when PNG has no chara chunk", function()
		local cap = make_cache_db()
		server._init_cache(cap)
		-- A PNG with no chara chunk (make_fs returns nil for read).
		local fs = {
			list = function(_) return { "plain.png" } end,
			read = function(_) return nil, "no file" end,
		}
		local meta = server._ensure_cached(cap, fs, { "plain.png" })
		T.eq(meta["plain.png"].name, "plain")
	end)

	T.it("/discover uses cached name in entries", function()
		local cap = make_cache_db()
		local card_bytes = assert(card_mod.to_png({ name = "Real Name", description = "desc", tags = { "a" } }))
		local fs = make_fs_with_png("weird_filename.png", card_bytes)
		local app = server.create({ characters = fs, meta_cache = cap })
		local _, data = call(app, "/discover")
		T.eq(#data.entries, 1)
		T.eq(data.entries[1].name,        "Real Name")
		T.eq(data.entries[1].description, "desc")
		T.ok(#data.entries[1].tags >= 1)
	end)
end)

-- ── Card detail page (GET / ?entry=) ──────────────────────────────────────

T.describe("GET / card detail page", function()
	T.it("returns 400 without ?entry=", function()
		local app = server.create({ characters = make_fs(FAKE_FILES) })
		local res = make_res()
		app.handler(make_req("/"), res)
		T.eq(res.status, 400)
	end)

	T.it("returns 200 HTML with card name in title", function()
		local app = server.create({ characters = make_fs({ "Alice.png" }) })
		local res = make_res()
		app.handler(make_req("/", "entry=Alice.png"), res)
		T.eq(res.status, 200)
		T.ok(res.headers["Content-Type"][1]:find("text/html", 1, true))
		T.ok(res.body:find("Alice", 1, true))
	end)

	T.it("shows cached name when available", function()
		local card_mod = require("lib.formats.ccv2.card")
		local card_bytes = assert(card_mod.to_png({ name = "Real Name", description = "test desc", tags = {} }))
		local fs = make_fs_with_png("weird.png", card_bytes)
		local app = server.create({ characters = fs })
		local res = make_res()
		app.handler(make_req("/", "entry=weird.png"), res)
		T.eq(res.status, 200)
		T.ok(res.body:find("Real Name", 1, true), "should show cached name")
		T.ok(res.body:find("test desc", 1, true), "should show description")
	end)

	T.it("page includes download link for the card PNG", function()
		local app = server.create({ characters = make_fs({ "Bob.png" }) })
		local res = make_res()
		app.handler(make_req("/", "entry=Bob.png"), res)
		T.eq(res.status, 200)
		T.ok(res.body:find("/card/Bob.png", 1, true), "page must link to /card/:id")
	end)

	T.it("falls back to filename-derived name for uncached entry", function()
		local app = server.create({ characters = make_fs({ "Zara.webp" }) })
		local res = make_res()
		app.handler(make_req("/", "entry=Zara.webp"), res)
		T.eq(res.status, 200)
		T.ok(res.body:find("Zara", 1, true))
	end)
end)

-- ── GET /card/:id — raw PNG bytes ──────────────────────────────────────────

T.describe("GET /card/:id", function()
	local card_mod = require("lib.formats.ccv2.card")

	T.it("returns PNG bytes for a known file", function()
		local card_bytes = assert(card_mod.to_png({ name = "Alice", tags = {} }))
		local fs = make_fs_with_png("Alice.png", card_bytes)
		local app = server.create({ characters = fs })
		local res = make_res()
		app.handler(make_req("/card/Alice.png"), res)
		T.eq(res.status, 200)
		T.ok(res.headers["Content-Type"][1]:find("image/png", 1, true))
		T.eq(res.body, card_bytes)
	end)

	T.it("returns 404 for unknown file", function()
		local app = server.create({ characters = make_fs(FAKE_FILES) })
		local res = make_res()
		app.handler(make_req("/card/NoSuch.png"), res)
		T.eq(res.status, 404)
	end)

	T.it("omits Content-Disposition so img tags load inline", function()
		local card_bytes = assert(card_mod.to_png({ name = "Bob", tags = {} }))
		local fs = make_fs_with_png("Bob.png", card_bytes)
		local app = server.create({ characters = fs })
		local res = make_res()
		app.handler(make_req("/card/Bob.png"), res)
		T.eq(res.status, 200)
		T.eq(res.headers["Content-Disposition"], nil)
	end)
end)

-- ── GET /thumb/:filename ───────────────────────────────────────────────────

T.describe("GET /thumb/:filename", function()
	local card_mod = require("lib.formats.ccv2.card")

	T.it("returns PNG bytes for a valid card", function()
		local card_bytes = assert(card_mod.to_png({ name = "Alice", tags = {} }))
		local fs = make_fs_with_png("Alice.png", card_bytes)
		local app = server.create({ characters = fs })
		local res = make_res()
		app.handler(make_req("/thumb/Alice.png"), res)
		T.eq(res.status, 200)
		T.eq(res.headers["Content-Type"] and res.headers["Content-Type"][1], "image/png")
		T.eq(res.body, card_bytes)
	end)

	T.it("returns 404 for unknown filename", function()
		local app = server.create({ characters = make_fs(FAKE_FILES) })
		local res = make_res()
		app.handler(make_req("/thumb/missing.png"), res)
		T.eq(res.status, 404)
	end)

	T.it("returns 400 for missing filename", function()
		local app = server.create({ characters = make_fs(FAKE_FILES) })
		local res = make_res()
		app.handler(make_req("/thumb/"), res)
		T.eq(res.status, 400)
	end)

	T.it("omits Content-Disposition", function()
		local card_bytes = assert(card_mod.to_png({ name = "Bob", tags = {} }))
		local fs = make_fs_with_png("Bob.png", card_bytes)
		local app = server.create({ characters = fs })
		local res = make_res()
		app.handler(make_req("/thumb/Bob.png"), res)
		T.eq(res.headers["Content-Disposition"], nil)
	end)
end)

-- ── Other endpoints ────────────────────────────────────────────────────────

T.describe("other endpoints", function()
	T.it("GET /unknown returns 404", function()
		local app = server.create({ characters = make_fs(FAKE_FILES) })
		local res = make_res()
		app.handler(make_req("/unknown"), res)
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
