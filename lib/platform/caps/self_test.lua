if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local png_mod = require("lib.png")
local self_cap = require("lib.platform.caps.self").self_cap

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
