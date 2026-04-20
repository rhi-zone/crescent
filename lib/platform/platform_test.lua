if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local platform = require("lib.platform")
local sandbox  = require("lib.sandbox")
local png_mod  = require("lib.png")
local fs_cap   = require("lib.platform.caps.fs").fs_cap
local base64   = require("lib.base64")
local tar      = require("lib.tar")
local json     = require("lib.json")

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Build a minimal valid PNG with a "script" tEXt chunk (and optional extra chunks).
-- Returns the raw PNG bytes.
local MINIMAL_PNG_IDAT = (function ()
	-- 1x1 white pixel, raw image data (filter byte 0 + RGBA): 5 bytes
	-- This is uncompressed, which is not valid PNG IDAT, but we only need
	-- the chunk structure to be readable by lib/png (IDAT is opaque).
	-- Use a known-good 1x1 PNG (zlib-compressed).
	local b = "\137PNG\r\n\26\n"
		.. "\0\0\0\rIHDR\0\0\0\1\0\0\0\1\8\2\0\0\0\144wS\222"
		.. "\0\0\0\12IDAT\8\215c\248\207\192\0\0\0\2\0\1\226!"
		.. "\188\51"
		.. "\0\0\0\0IEND\174B`\130"
	return b
end)()

local function make_test_card(script, extra_chunks)
	local chunks = png_mod.read(MINIMAL_PNG_IDAT)
	assert(chunks, "test PNG parse failed")
	chunks = png_mod.set_text(chunks, "script", script)
	if extra_chunks then
		for k, v in pairs(extra_chunks) do
			chunks = png_mod.set_text(chunks, k, v)
		end
	end
	return png_mod.write(chunks)
end

local function write_temp(bytes)
	local path = os.tmpname() .. ".png"
	local f = io.open(path, "wb")
	f:write(bytes)
	f:close()
	return path
end

-- ── caps.png ──────────────────────────────────────────────────────────────────

-- ── caps.fs ───────────────────────────────────────────────────────────────────

T.describe("caps.fs", function ()
	local function make_tmpdir()
		local dir = os.tmpname()
		os.remove(dir)
		os.execute("mkdir -p " .. dir)
		return dir
	end

	T.it("reads files inside root", function ()
		local dir = make_tmpdir()
		local f = io.open(dir .. "/hello.txt", "wb"); f:write("world"); f:close()
		local cap = fs_cap({ root = dir })
		local content, err = cap.read("hello.txt")
		T.ok(content == "world", "read: " .. tostring(err))
		os.execute("rm -rf " .. dir)
	end)

	T.it("blocks path traversal in read", function ()
		local dir = make_tmpdir()
		local cap = fs_cap({ root = dir })
		local content, err = cap.read("../etc/passwd")
		T.ok(content == nil)
		T.ok(err ~= nil and err:find("traversal"))
		os.execute("rm -rf " .. dir)
	end)

	T.it("blocks absolute paths", function ()
		local dir = make_tmpdir()
		local cap = fs_cap({ root = dir })
		local content, err = cap.read("/etc/passwd")
		T.ok(content == nil)
		T.ok(err ~= nil and err:find("absolute"))
		os.execute("rm -rf " .. dir)
	end)

	T.it("write is blocked without allow_write", function ()
		local dir = make_tmpdir()
		local cap = fs_cap({ root = dir })
		local ok, err = cap.write("out.txt", "data")
		T.ok(ok == nil)
		T.ok(err ~= nil and err:find("not granted"))
		os.execute("rm -rf " .. dir)
	end)

	T.it("write works with allow_write", function ()
		local dir = make_tmpdir()
		local cap = fs_cap({ root = dir, allow_write = true })
		local ok, err = cap.write("out.txt", "hello")
		T.ok(ok == true, tostring(err))
		local cap2 = fs_cap({ root = dir })
		T.eq(cap2.read("out.txt"), "hello")
		os.execute("rm -rf " .. dir)
	end)

	T.it("list returns filenames in directory", function ()
		local dir = make_tmpdir()
		local f1 = io.open(dir .. "/a.txt", "wb"); f1:write(""); f1:close()
		local f2 = io.open(dir .. "/b.txt", "wb"); f2:write(""); f2:close()
		local cap = fs_cap({ root = dir })
		local names, err = cap.list()
		T.ok(names ~= nil, tostring(err))
		T.ok(#names >= 2)
		os.execute("rm -rf " .. dir)
	end)
end)

-- ── App helpers ───────────────────────────────────────────────────────────────

-- Pure-Lua gzip wrapper using DEFLATE stored blocks (no compression).
-- Only used in tests to produce valid gzip data without needing system zlib.
local function gzip_store(data)
	local bit = require("bit")
	local band, bxor, rshift = bit.band, bit.bxor, bit.rshift

	-- CRC-32 table
	local crc_t = {}
	for i = 0, 255 do
		local c = i
		for _ = 1, 8 do
			if band(c, 1) == 1 then c = bxor(rshift(c, 1), 0xEDB88320) else c = rshift(c, 1) end
		end
		crc_t[i] = c
	end
	local function crc32(s)
		local c = 0xFFFFFFFF
		for i = 1, #s do
			c = bxor(rshift(c, 8), crc_t[band(bxor(c, s:byte(i)), 0xFF)])
		end
		local v = band(bxor(c, 0xFFFFFFFF), 0xFFFFFFFF)
		if v < 0 then v = v + 0x100000000 end
		return v
	end

	local function le32(n)
		if n < 0 then n = n + 0x100000000 end
		return string.char(n%256, math.floor(n/256)%256, math.floor(n/65536)%256, math.floor(n/16777216)%256)
	end
	local function le16(n)
		return string.char(n%256, math.floor(n/256)%256)
	end

	-- gzip header (no flags, OS=0xff)
	local header = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff"

	-- DEFLATE stored blocks (BTYPE=00, BFINAL depends on position)
	-- Max stored block payload = 65535
	local MAXBLOCK = 65535
	local blocks = {}
	local n = #data
	local pos = 1
	while pos <= n or n == 0 do
		local chunk_end = math.min(pos + MAXBLOCK - 1, n)
		local chunk = data:sub(pos, chunk_end)
		local len = #chunk
		local is_last = chunk_end >= n
		-- BFINAL=is_last, BTYPE=00 → byte = is_last ? 0x01 : 0x00
		blocks[#blocks+1] = string.char(is_last and 0x01 or 0x00)
		blocks[#blocks+1] = le16(len)
		blocks[#blocks+1] = le16(band(bxor(len, 0xFFFF), 0xFFFF))
		blocks[#blocks+1] = chunk
		if is_last then break end
		pos = chunk_end + 1
	end

	local crc = crc32(data)
	local trailer = le32(crc) .. le32(n % 0x100000000)
	return header .. table.concat(blocks) .. trailer
end

-- Build an iTXt chunk with keyword "lua" containing base64(gzip(tar(entries))).
-- entries: array of { name=string, data=string }
local function make_lua_itxt_chunk(entries_in)
	local tardata = assert(tar.write(entries_in))
	local gz      = gzip_store(tardata)
	local b64     = base64.encode(gz)
	-- iTXt layout: keyword \0 flag(0) method(0) lang \0 translated_kw \0 text
	local itxt_data = "lua\0\0\0\0\0" .. b64
	return { type = "iTXt", data = itxt_data }
end

-- Build a PNG with a "lua" iTXt app chunk.
-- files: { [path] = source_string, ... }
-- manifest: table (will be JSON-encoded)
local function make_test_app(files, manifest)
	local entries = {}
	-- manifest.json first
	local manifest_json = require("lib.json").encode(manifest)
	entries[#entries + 1] = { name = "manifest.json", data = manifest_json }
	for path, src in pairs(files) do
		entries[#entries + 1] = { name = path, data = src }
	end

	local chunks = assert(png_mod.read(MINIMAL_PNG_IDAT))
	local lua_chunk = make_lua_itxt_chunk(entries)
	-- Insert before IEND
	local new_chunks = {}
	for _, c in ipairs(chunks) do
		if c.type == "IEND" then
			new_chunks[#new_chunks + 1] = lua_chunk
		end
		new_chunks[#new_chunks + 1] = c
	end
	return png_mod.write(new_chunks)
end

-- ── platform.load_app ─────────────────────────────────────────────────────────

T.describe("platform.load_app", function ()
	T.it("loads app from lua iTXt chunk", function ()
		local manifest = { name = "test-app", version = "1.0.0", entry = { headless = "main.lua" } }
		local bytes = make_test_app({ ["main.lua"] = "return 42" }, manifest)
		local path  = write_temp(bytes)
		local app, err = platform.load_app(path)
		os.remove(path)
		T.ok(app ~= nil, "app loaded: " .. tostring(err))
		T.eq(app.manifest.name,    "test-app")
		T.eq(app.manifest.version, "1.0.0")
		T.ok(type(app.entries) == "table")
		T.ok(#app.entries >= 2)  -- manifest.json + main.lua
	end)

	T.it("returns error for PNG without lua iTXt chunk", function ()
		local bytes = make_test_card("return 1")
		local path  = write_temp(bytes)
		local app, err = platform.load_app(path)
		os.remove(path)
		T.ok(app == nil)
		T.ok(err ~= nil and err:find("lua"))
	end)

	T.it("returns error for non-existent file", function ()
		local app, err = platform.load_app("/tmp/no_such_app_xyz.png")
		T.ok(app == nil)
		T.ok(err ~= nil)
	end)
end)

-- ── platform.run_entry ────────────────────────────────────────────────────────

T.describe("platform.run_entry", function ()
	T.it("runs headless entrypoint and returns result", function ()
		local manifest = { name = "app", version = "1.0.0", entry = { headless = "run.lua" } }
		local bytes = make_test_app({ ["run.lua"] = "return 7 * 6" }, manifest)
		local path  = write_temp(bytes)
		local app   = assert(platform.load_app(path))
		os.remove(path)
		local env = sandbox.env(sandbox.stdlib)
		local ok, result = platform.run_entry(app, "headless", env)
		T.ok(ok, tostring(result))
		T.eq(result, 42)
	end)

	T.it("returns error for unknown entry key", function ()
		local manifest = { name = "app", version = "1.0.0", entry = { headless = "run.lua" } }
		local bytes = make_test_app({ ["run.lua"] = "return 1" }, manifest)
		local path  = write_temp(bytes)
		local app   = assert(platform.load_app(path))
		os.remove(path)
		local env = sandbox.env(sandbox.stdlib)
		local ok, err = platform.run_entry(app, "dom", env)
		T.ok(not ok)
		T.ok(err ~= nil and err:find("dom"))
	end)

	T.it("require resolves modules within the tarball", function ()
		local manifest = { name = "app", version = "1.0.0", entry = { headless = "main.lua" } }
		local files = {
			["main.lua"]        = "local u = require('shared.utils'); return u.double(21)",
			["shared/utils.lua"] = "local M = {}; function M.double(n) return n * 2 end; return M",
		}
		local bytes = make_test_app(files, manifest)
		local path  = write_temp(bytes)
		local app   = assert(platform.load_app(path))
		os.remove(path)
		local env = sandbox.env(sandbox.stdlib)
		local ok, result = platform.run_entry(app, "headless", env)
		T.ok(ok, tostring(result))
		T.eq(result, 42)
	end)

	T.it("require resolves init.lua convention within tarball", function ()
		local manifest = { name = "app", version = "1.0.0", entry = { headless = "main.lua" } }
		local files = {
			["main.lua"]            = "local u = require('shared.utils'); return u.value",
			["shared/utils/init.lua"] = "return { value = 99 }",
		}
		local bytes = make_test_app(files, manifest)
		local path  = write_temp(bytes)
		local app   = assert(platform.load_app(path))
		os.remove(path)
		local env = sandbox.env(sandbox.stdlib)
		local ok, result = platform.run_entry(app, "headless", env)
		T.ok(ok, tostring(result))
		T.eq(result, 99)
	end)

	T.it("sandbox blocks require for modules not in tarball and not allowlisted", function ()
		local manifest = { name = "app", version = "1.0.0", entry = { headless = "main.lua" } }
		local bytes = make_test_app({ ["main.lua"] = "return require('io')" }, manifest)
		local path  = write_temp(bytes)
		local app   = assert(platform.load_app(path))
		os.remove(path)
		local env = sandbox.env(sandbox.stdlib)  -- io not in stdlib modules
		local ok  = platform.run_entry(app, "headless", env)
		T.ok(not ok, "require('io') should fail in sandbox")
	end)

	T.it("tarball modules run in sandbox env, not global env (no ffi access)", function ()
		-- The tarball module tries to require("ffi"). If it ran with global
		-- privileges it would succeed. In the sandbox env ffi is not allowed.
		local manifest = { name = "app", version = "1.0.0", entry = { headless = "main.lua" } }
		local files = {
			["main.lua"]  = "local m = require('evil'); return m.result",
			["evil.lua"]  = "return { result = require('ffi') ~= nil }",
		}
		local bytes = make_test_app(files, manifest)
		local path  = write_temp(bytes)
		local app   = assert(platform.load_app(path))
		os.remove(path)
		local env = sandbox.env(sandbox.stdlib)  -- ffi not in allowed modules
		local ok  = platform.run_entry(app, "headless", env)
		T.ok(not ok, "tarball module require('ffi') must fail in sandbox env")
	end)

	T.it("caps not visible to tarball modules, only to entrypoint", function ()
		local manifest = { name = "app", version = "1.0.0", entry = { headless = "main.lua" } }
		local files = {
			["main.lua"]    = "local m = require('helper'); return m.saw_caps",
			["helper.lua"]  = "return { saw_caps = (caps ~= nil) }",
		}
		local bytes = make_test_app(files, manifest)
		local path  = write_temp(bytes)
		local app   = assert(platform.load_app(path))
		os.remove(path)
		local fake_caps = { time = { now = function() return 0 end } }
		local env = sandbox.env(sandbox.stdlib, { globals = { caps = fake_caps }, modules = {} })
		local ok, result = platform.run_entry(app, "headless", env)
		T.ok(ok, tostring(result))
		T.eq(result, false, "module must not see caps")
	end)

	T.it("entrypoint can still access caps directly", function ()
		local manifest = { name = "app", version = "1.0.0", entry = { headless = "main.lua" } }
		local files = { ["main.lua"] = "return caps ~= nil" }
		local bytes = make_test_app(files, manifest)
		local path  = write_temp(bytes)
		local app   = assert(platform.load_app(path))
		os.remove(path)
		local fake_caps = { time = { now = function() return 0 end } }
		local env = sandbox.env(sandbox.stdlib, { globals = { caps = fake_caps }, modules = {} })
		local ok, result = platform.run_entry(app, "headless", env)
		T.ok(ok, tostring(result))
		T.eq(result, true, "entrypoint must see caps")
	end)

	T.it("require same module twice returns cached result", function ()
		local manifest = { name = "app", version = "1.0.0", entry = { headless = "main.lua" } }
		local files = {
			-- counter increments on each load; caching means it should stay at 1
			["main.lua"]   = [[
				local c1 = require('counter')
				local c2 = require('counter')
				return c1 == c2
			]],
			["counter.lua"] = "return { n = 1 }",
		}
		local bytes = make_test_app(files, manifest)
		local path  = write_temp(bytes)
		local app   = assert(platform.load_app(path))
		os.remove(path)
		local env = sandbox.env(sandbox.stdlib)
		local ok, result = platform.run_entry(app, "headless", env)
		T.ok(ok, tostring(result))
		T.eq(result, true, "same require returns cached object")
	end)
end)

-- ── cap validation ────────────────────────────────────────────────────────────

T.describe("platform.run_entry cap validation", function ()
	-- Helper: build an app with the given manifest and a trivial main.lua.
	local function make_app(manifest)
		local bytes = make_test_app({ ["main.lua"] = "return true" }, manifest)
		local path  = write_temp(bytes)
		local app   = assert(platform.load_app(path))
		os.remove(path)
		return app
	end

	T.it("required per-entry cap present → ok", function ()
		local manifest = {
			name = "app", version = "1.0.0",
			entry = {
				dom = {
					main = "main.lua",
					caps = { render = { type = "render", required = true } },
				},
			},
		}
		local app = make_app(manifest)
		local env = sandbox.env(sandbox.stdlib, { globals = { render = {} } })
		local ok, err = platform.run_entry(app, "dom", env)
		T.ok(ok, tostring(err))
	end)

	T.it("required per-entry cap missing → error with cap name and type", function ()
		local manifest = {
			name = "app", version = "1.0.0",
			entry = {
				dom = {
					main = "main.lua",
					caps = { render = { type = "render", required = true } },
				},
			},
		}
		local app = make_app(manifest)
		local env = sandbox.env(sandbox.stdlib)  -- no globals.render
		local ok, err = platform.run_entry(app, "dom", env)
		T.ok(not ok)
		T.ok(err ~= nil and err:find("render"),   "err mentions cap name: " .. tostring(err))
	end)

	T.it("optional per-entry cap missing → ok", function ()
		local manifest = {
			name = "app", version = "1.0.0",
			entry = {
				dom = {
					main = "main.lua",
					caps = { llm_summary = { type = "llm", required = false } },
				},
			},
		}
		local app = make_app(manifest)
		local env = sandbox.env(sandbox.stdlib)  -- no globals.llm_summary
		local ok, err = platform.run_entry(app, "dom", env)
		T.ok(ok, tostring(err))
	end)

	T.it("top-level required cap missing → error", function ()
		local manifest = {
			name = "app", version = "1.0.0",
			caps  = { db = "required" },
			entry = { headless = "main.lua" },
		}
		local app = make_app(manifest)
		local env = sandbox.env(sandbox.stdlib)  -- no globals.db
		local ok, err = platform.run_entry(app, "headless", env)
		T.ok(not ok)
		T.ok(err ~= nil and err:find("db"), "err mentions cap name: " .. tostring(err))
	end)
end)

-- ── platform.load_and_run_entry ───────────────────────────────────────────────

T.describe("platform.load_and_run_entry", function ()
	T.it("loads and runs in one call", function ()
		local manifest = { name = "app", version = "1.0.0", entry = { headless = "main.lua" } }
		local bytes = make_test_app({ ["main.lua"] = "return 'hello'" }, manifest)
		local path  = write_temp(bytes)
		local env   = sandbox.env(sandbox.stdlib)
		local ok, result = platform.load_and_run_entry(path, "headless", env)
		os.remove(path)
		T.ok(ok, tostring(result))
		T.eq(result, "hello")
	end)

	T.it("returns error for non-existent file", function ()
		local env = sandbox.env(sandbox.stdlib)
		local ok, err = platform.load_and_run_entry("/tmp/no_such_app.png", "headless", env)
		T.ok(not ok)
		T.ok(err ~= nil)
	end)
end)

-- ── Scope resolution ─────────────────────────────────────────────────────────

T.describe("platform._resolve_data_path", function ()
	local resolve = platform._resolve_data_path

	T.it("defaults to user+app scope", function ()
		local p = resolve("kv", nil, { user_id = "u1", app_id = "myapp", data_dir = "/base" })
		T.eq(p, "/base/u1/myapp/kv.db")
	end)

	T.it("user-only scope", function ()
		local p = resolve("kv", { "user" }, { user_id = "u1", app_id = "myapp", data_dir = "/base" })
		T.eq(p, "/base/u1/kv.db")
	end)

	T.it("app-only scope", function ()
		local p = resolve("kv", { "app" }, { user_id = "u1", app_id = "myapp", data_dir = "/base" })
		T.eq(p, "/base/myapp/kv.db")
	end)

	T.it("empty scope (global)", function ()
		local p = resolve("kv", {}, { user_id = "u1", app_id = "myapp", data_dir = "/base" })
		T.eq(p, "/base/kv.db")
	end)

	T.it("defaults data_dir to ./data", function ()
		local p = resolve("kv", { "user", "app" }, { user_id = "u1", app_id = "a1" })
		T.eq(p, "./data/u1/a1/kv.db")
	end)
end)

-- ── make_caps ────────────────────────────────────────────────────────────────

T.describe("platform.make_caps", function ()
	-- Minimal app for self cap
	local function dummy_app()
		return { manifest = { name = "test-app", version = "1.0.0", entry = {} }, entries = {} }
	end

	T.it("constructs granted required caps", function ()
		local app = dummy_app()
		local decls = {
			self = { type = "self" },
			time = { type = "time" },
		}
		local grants = { self = true, time = true }
		local caps, revoke = platform.make_caps(app, decls, grants, {})
		T.ok(caps ~= nil, tostring(revoke))
		T.ok(caps.self ~= nil, "self cap present")
		T.ok(caps.time ~= nil, "time cap present")
		T.ok(type(caps.self.metadata) == "function", "self has metadata")
		T.ok(type(caps.self.entries) == "function", "self has entries")
		T.ok(type(caps.time.now) == "function", "time has now")
	end)

	T.it("returns error when required cap not granted", function ()
		local app = dummy_app()
		local decls = {
			self = { type = "self", required = true },
		}
		local caps, err = platform.make_caps(app, decls, {}, {})
		T.ok(caps == nil)
		T.ok(err:find("not granted") ~= nil)
	end)

	T.it("skips optional cap when not granted", function ()
		local app = dummy_app()
		local decls = {
			time = { type = "time", required = false },
		}
		local caps, revoke = platform.make_caps(app, decls, {}, {})
		T.ok(caps ~= nil, tostring(revoke))
		T.eq(caps.time, nil)
	end)

	T.it("constructs kv cap with scope resolution", function ()
		local app = dummy_app()
		local decls = {
			store = { type = "kv", scope = { "user" } },
		}
		local grants = { store = true }
		local ctx = { user_id = "u1", app_id = "a1", data_dir = "/tmp/test-data" }
		local caps, revoke = platform.make_caps(app, decls, grants, ctx)
		T.ok(caps ~= nil, tostring(revoke))
		T.ok(caps.store ~= nil, "kv cap present")
		T.ok(type(caps.store.get) == "function", "kv has get")
		T.ok(type(caps.store.set) == "function", "kv has set")
	end)

	T.it("constructs http_client cap with host restriction", function ()
		local app = dummy_app()
		local decls = {
			api = { type = "http_client", host = "example.com" },
		}
		local grants = { api = true }
		local caps, revoke = platform.make_caps(app, decls, grants, {})
		T.ok(caps ~= nil, tostring(revoke))
		T.ok(caps.api ~= nil)
		T.ok(type(caps.api.request) == "function", "http_client has request")
		T.ok(type(caps.api.request_stream) == "function", "http_client has request_stream")
	end)

	T.it("returns revoke functions for caps that support them", function ()
		local app = dummy_app()
		local decls = {
			server = { type = "http_server", port = 8080 },
		}
		local grants = { server = true }
		local caps, revoke = platform.make_caps(app, decls, grants, {})
		T.ok(caps ~= nil, tostring(revoke))
		T.ok(type(revoke) == "table")
		T.ok(type(revoke.server) == "function", "http_server has revoke fn")
	end)

	T.it("returns error for unknown required cap type", function ()
		local app = dummy_app()
		local decls = {
			mystery = { type = "unknown_thing", required = true },
		}
		local grants = { mystery = true }
		local caps, err = platform.make_caps(app, decls, grants, {})
		T.ok(caps == nil)
		T.ok(err:find("unknown cap type") ~= nil)
	end)

	T.it("skips unknown optional cap type", function ()
		local app = dummy_app()
		local decls = {
			mystery = { type = "unknown_thing", required = false },
		}
		local grants = { mystery = true }
		local caps, revoke = platform.make_caps(app, decls, grants, {})
		T.ok(caps ~= nil, tostring(revoke))
		T.eq(caps.mystery, nil)
	end)
end)

-- ── validate_caps ────────────────────────────────────────────────────────────

T.describe("platform.validate_caps", function ()
	T.it("accepts valid declarations", function ()
		local ok, err = platform.validate_caps({
			self = { type = "self" },
			time = { type = "time" },
		})
		T.ok(ok, tostring(err))
	end)

	T.it("rejects unknown cap type", function ()
		local ok, err = platform.validate_caps({
			bad = { type = "nonexistent" },
		})
		T.ok(not ok)
		T.ok(err:find("unknown cap type") ~= nil)
	end)

	T.it("rejects non-table declaration", function ()
		local ok, err = platform.validate_caps({
			bad = "just a string",
		})
		T.ok(not ok)
		T.ok(err:find("must be a table") ~= nil)
	end)

	T.it("rejects non-table input", function ()
		local ok, err = platform.validate_caps("not a table")
		T.ok(not ok)
		T.ok(err:find("must be a table") ~= nil)
	end)

	T.it("uses cap name as type when type field is absent", function ()
		local ok, err = platform.validate_caps({
			self = {},
			time = {},
		})
		T.ok(ok, tostring(err))
	end)
end)

-- ── run_app ──────────────────────────────────────────────────────────────────

T.describe("platform.run_app", function ()
	T.it("runs app with auto-granted caps", function ()
		local manifest = {
			name = "cap-app", version = "1.0.0",
			caps = { time = { type = "time" } },
			entry = { headless = "main.lua" },
		}
		local files = {
			["main.lua"] = "return type(caps.time.now())",
		}
		local bytes = make_test_app(files, manifest)
		local path = write_temp(bytes)
		local ok, result, revoke = platform.run_app(path, "headless")
		os.remove(path)
		T.ok(ok, tostring(result))
		T.eq(result, "number")
		T.ok(type(revoke) == "table")
	end)

	T.it("merges per-entry caps with top-level caps", function ()
		local manifest = {
			name = "merge-app", version = "1.0.0",
			caps = { self = { type = "self" } },
			entry = {
				headless = {
					main = "main.lua",
					caps = { time = { type = "time" } },
				},
			},
		}
		local files = {
			["main.lua"] = "return type(caps.time.now()) .. ':' .. type(caps.self.entries())",
		}
		local bytes = make_test_app(files, manifest)
		local path = write_temp(bytes)
		local ok, result = platform.run_app(path, "headless")
		os.remove(path)
		T.ok(ok, tostring(result))
		T.eq(result, "number:table")
	end)

	T.it("fails when required cap is denied by explicit grants", function ()
		local manifest = {
			name = "deny-app", version = "1.0.0",
			caps = { self = { type = "self" } },
			entry = { headless = "main.lua" },
		}
		local files = { ["main.lua"] = "return 1" }
		local bytes = make_test_app(files, manifest)
		local path = write_temp(bytes)
		local ok, err = platform.run_app(path, "headless", { grants = {} })
		os.remove(path)
		T.ok(not ok)
		T.ok(type(err) == "string" and err:find("not granted") ~= nil)
	end)

	T.it("works with no caps declared", function ()
		local manifest = {
			name = "no-caps-app", version = "1.0.0",
			entry = { headless = "main.lua" },
		}
		local files = { ["main.lua"] = "return 42" }
		local bytes = make_test_app(files, manifest)
		local path = write_temp(bytes)
		local ok, result = platform.run_app(path, "headless")
		os.remove(path)
		T.ok(ok, tostring(result))
		T.eq(result, 42)
	end)

	T.it("returns error for non-existent file", function ()
		local ok, err = platform.run_app("/tmp/no_such_app_xyz.png", "headless")
		T.ok(not ok)
		T.ok(err ~= nil)
	end)
end)
