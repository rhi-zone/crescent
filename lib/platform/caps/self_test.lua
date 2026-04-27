if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local png_mod = require("lib.png")
local self_mod = require("lib.platform.caps.self")
local self_cap = self_mod.self_cap
local self_write_cap = self_mod.self_write_cap

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Build a minimal valid PNG and return its chunks (with tEXt metadata).
local MINIMAL_PNG = "\137PNG\r\n\26\n"
	.. "\0\0\0\rIHDR\0\0\0\1\0\0\0\1\8\2\0\0\0\144wS\222"
	.. "\0\0\0\12IDAT\8\215c\248\207\192\0\0\0\2\0\1\226!"
	.. "\188\51"
	.. "\0\0\0\0IEND\174B`\130"

local function make_chunks(extra)
	local chunks = png_mod.read(MINIMAL_PNG)
	assert(chunks, "test PNG parse failed")
	if extra then
		for k, v in pairs(extra) do
			chunks = png_mod.set_text(chunks, k, v)
		end
	end
	return chunks
end

local function make_entries(files)
	local entries = {}
	for i = 1, #files do
		entries[i] = { name = files[i][1], data = files[i][2], mode = 420, size = #files[i][2], mtime = 0, typeflag = "0" }
	end
	return entries
end

-- ── Tests ────────────────────────────────────────────────────────────────────

T.describe("caps.self", function()
	T.it("metadata reads tEXt chunks from app.chunks", function()
		local app = {
			path = "test.png",
			chunks = make_chunks({ title = "My App", version = "1.0" }),
			entries = {},
			manifest = {},
		}
		local cap = self_cap(app)
		T.eq(cap.metadata("title"), "My App")
		T.eq(cap.metadata("version"), "1.0")
	end)

	T.it("metadata returns nil for missing keyword", function()
		local app = {
			path = "test.png",
			chunks = make_chunks({ title = "My App" }),
			entries = {},
			manifest = {},
		}
		local cap = self_cap(app)
		T.eq(cap.metadata("absent"), nil)
	end)

	T.it("metadata returns nil when app has no chunks (tar.gz source)", function()
		local app = {
			path = "test.tar.gz",
			chunks = nil,
			entries = {},
			manifest = {},
		}
		local cap = self_cap(app)
		T.eq(cap.metadata("anything"), nil)
	end)

	T.it("entries returns list of tarball entry paths", function()
		local app = {
			path = "test.png",
			chunks = nil,
			entries = make_entries({
				{ "manifest.json", '{}' },
				{ "main.lua", 'return 1' },
				{ "assets/icon.png", 'PNG...' },
			}),
			manifest = {},
		}
		local cap = self_cap(app)
		local paths = cap.entries()
		T.eq(#paths, 3)
		T.eq(paths[1], "manifest.json")
		T.eq(paths[2], "main.lua")
		T.eq(paths[3], "assets/icon.png")
	end)

	T.it("entry returns content of a specific tarball entry", function()
		local app = {
			path = "test.png",
			chunks = nil,
			entries = make_entries({
				{ "manifest.json", '{"name":"test"}' },
				{ "main.lua", 'print("hello")' },
			}),
			manifest = {},
		}
		local cap = self_cap(app)
		T.eq(cap.entry("main.lua"), 'print("hello")')
		T.eq(cap.entry("manifest.json"), '{"name":"test"}')
	end)

	T.it("entry returns nil for missing path", function()
		local app = {
			path = "test.png",
			chunks = nil,
			entries = make_entries({ { "main.lua", "x" } }),
			manifest = {},
		}
		local cap = self_cap(app)
		T.eq(cap.entry("absent.lua"), nil)
	end)

	T.it("app_id is exposed as a field when opts.app_id is provided", function()
		local app = { path = "x", chunks = nil, entries = {}, manifest = {} }
		local cap = self_cap(app, { app_id = "42" })
		T.eq(cap.app_id, "42")
	end)

	T.it("app_id is nil when opts is omitted (CLI / no-daemon case)", function()
		local app = { path = "x", chunks = nil, entries = {}, manifest = {} }
		local cap = self_cap(app)
		T.eq(cap.app_id, nil)
	end)

	T.it("revoke disables all methods", function()
		local app = {
			path = "test.png",
			chunks = make_chunks({ title = "App" }),
			entries = make_entries({ { "main.lua", "x" } }),
			manifest = {},
		}
		local cap, revoke = self_cap(app)
		-- Works before revoke
		T.eq(cap.metadata("title"), "App")
		T.eq(type(cap.entries()), "table")
		T.eq(cap.entry("main.lua"), "x")

		revoke()

		-- All methods return nil, "capability revoked" after revoke
		local val, err = cap.metadata("title")
		T.eq(val, nil)
		T.eq(err, "capability revoked")

		val, err = cap.entries()
		T.eq(val, nil)
		T.eq(err, "capability revoked")

		val, err = cap.entry("main.lua")
		T.eq(val, nil)
		T.eq(err, "capability revoked")
	end)
end)

-- ── self_write tests ─────────────────────────────────────────────────────────
-- Write to a real temp file so round-trip via re-reading disk is exercised.

local function tmp_png_path()
	return os.tmpname() .. ".png"
end

local function write_test_png(path, chunks)
	local bytes = png_mod.write(chunks)
	local f = assert(io.open(path, "wb"))
	f:write(bytes)
	f:close()
end

local function read_png_chunks(path)
	local f = assert(io.open(path, "rb"))
	local bytes = f:read("*a")
	f:close()
	return assert(png_mod.read(bytes))
end

local function list_tmp_siblings(path)
	local dir, base = path:match("^(.*)/([^/]+)$")
	if not dir then dir, base = ".", path end
	local p = assert(io.popen('ls -1 "' .. dir .. '" 2>/dev/null'))
	local matches = {}
	local prefix = base .. ".tmp."
	for name in p:lines() do
		if name:sub(1, #prefix) == prefix then
			matches[#matches + 1] = name
		end
	end
	p:close()
	return matches
end

T.describe("caps.self_write", function()
	T.it("write_metadata writes an iTXt chunk visible via metadata()", function()
		local path = tmp_png_path()
		write_test_png(path, make_chunks())
		local app = {
			path = path,
			chunks = read_png_chunks(path),
			entries = {},
			manifest = {},
		}
		local cap = self_write_cap(app)
		local ok, err = cap.write_metadata("chara", "hello")
		T.eq(ok, true)
		T.eq(err, nil)
		T.eq(cap.metadata("chara"), "hello")
		os.remove(path)
	end)

	T.it("round-trip: write, re-open file, new cap sees new value", function()
		local path = tmp_png_path()
		write_test_png(path, make_chunks())
		local app1 = {
			path = path,
			chunks = read_png_chunks(path),
			entries = {},
			manifest = {},
		}
		local cap1, revoke1 = self_write_cap(app1)
		T.eq(cap1.write_metadata("chara", "persisted"), true)
		revoke1()
		-- Fresh read of the file on disk.
		local app2 = {
			path = path,
			chunks = read_png_chunks(path),
			entries = {},
			manifest = {},
		}
		local cap2 = self_write_cap(app2)
		T.eq(cap2.metadata("chara"), "persisted")
		os.remove(path)
	end)

	T.it("write_metadata returns (nil, revoked) after revoke", function()
		local path = tmp_png_path()
		write_test_png(path, make_chunks())
		local app = {
			path = path,
			chunks = read_png_chunks(path),
			entries = {},
			manifest = {},
		}
		local cap, revoke = self_write_cap(app)
		revoke()
		local val, err = cap.write_metadata("chara", "x")
		T.eq(val, nil)
		T.eq(err, "capability revoked")
		os.remove(path)
	end)

	T.it("write_metadata errors on tar-only app (no image container)", function()
		local app = {
			path = "unused.tar.gz",
			chunks = nil,
			entries = {},
			manifest = {},
		}
		local cap = self_write_cap(app)
		local val, err = cap.write_metadata("chara", "x")
		T.eq(val, nil)
		T.eq(err, "app has no image container")
	end)

	T.it("unknown keyword creates a new chunk readable via metadata()", function()
		local path = tmp_png_path()
		write_test_png(path, make_chunks())
		local app = {
			path = path,
			chunks = read_png_chunks(path),
			entries = {},
			manifest = {},
		}
		local cap = self_write_cap(app)
		T.eq(cap.metadata("newkey"), nil)
		T.eq(cap.write_metadata("newkey", "v"), true)
		T.eq(cap.metadata("newkey"), "v")
		os.remove(path)
	end)

	T.it("overwriting an existing keyword replaces its value", function()
		local path = tmp_png_path()
		write_test_png(path, make_chunks())
		local app = {
			path = path,
			chunks = read_png_chunks(path),
			entries = {},
			manifest = {},
		}
		local cap = self_write_cap(app)
		T.eq(cap.write_metadata("chara", "v1"), true)
		T.eq(cap.metadata("chara"), "v1")
		T.eq(cap.write_metadata("chara", "v2"), true)
		T.eq(cap.metadata("chara"), "v2")
		os.remove(path)
	end)

	T.it("successful write leaves no temp file behind", function()
		local path = tmp_png_path()
		write_test_png(path, make_chunks())
		local app = {
			path = path,
			chunks = read_png_chunks(path),
			entries = {},
			manifest = {},
		}
		local cap = self_write_cap(app)
		T.eq(cap.write_metadata("chara", "v"), true)
		local leftovers = list_tmp_siblings(path)
		T.eq(#leftovers, 0)
		os.remove(path)
	end)

	T.it("self_write exposes the same read methods as self", function()
		local path = tmp_png_path()
		write_test_png(path, make_chunks({ title = "T" }))
		local app = {
			path = path,
			chunks = read_png_chunks(path),
			entries = make_entries({ { "main.lua", "body" } }),
			manifest = {},
		}
		local cap = self_write_cap(app, { app_id = "abc" })
		T.eq(cap.app_id, "abc")
		T.eq(cap.metadata("title"), "T")
		T.eq(cap.entries()[1], "main.lua")
		T.eq(cap.entry("main.lua"), "body")
		os.remove(path)
	end)
end)

T.describe("caps.self risk", function()
	T.it("readonly self has low severity", function()
		local result = self_mod.risk({ type = "self" })
		T.eq(result.severity, "low")
	end)

	T.it("writable self has medium severity", function()
		local result = self_mod.risk({ type = "self", writable = true })
		T.eq(result.severity, "medium")
	end)

	T.it("self_write type has medium severity", function()
		local result = self_mod.risk({ type = "self_write" })
		T.eq(result.severity, "medium")
	end)
end)
