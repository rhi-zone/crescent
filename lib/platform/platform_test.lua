if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local platform = require("lib.platform")
local sandbox  = require("lib.sandbox")
local png_mod  = require("lib.png")
local png_cap  = require("lib.platform.caps.png").png_cap
local render   = require("lib.platform.caps.render")
local fs_cap   = require("lib.platform.caps.fs").fs_cap
local base64   = require("lib.base64")
local tar      = require("lib.tar")

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

-- ── platform.load_card ────────────────────────────────────────────────────────

T.describe("platform.load_card", function ()
	T.it("loads script chunk from PNG", function ()
		local bytes = make_test_card("return 42")
		local path  = write_temp(bytes)
		local card, err = platform.load_card(path)
		os.remove(path)
		T.ok(card ~= nil, "card loaded: " .. tostring(err))
		T.eq(card.script, "return 42")
		T.eq(card.data,   nil)
	end)

	T.it("loads script and data chunks", function ()
		local bytes = make_test_card("return 1", { data = '{"name":"test"}' })
		local path  = write_temp(bytes)
		local card, err = platform.load_card(path)
		os.remove(path)
		T.ok(card ~= nil, tostring(err))
		T.eq(card.script, "return 1")
		T.eq(card.data,   '{"name":"test"}')
	end)

	T.it("returns error for non-existent file", function ()
		local card, err = platform.load_card("/tmp/no_such_file_xyz.png")
		T.ok(card == nil)
		T.ok(err ~= nil)
	end)

	T.it("returns error for PNG without script chunk", function ()
		local chunks = png_mod.read(MINIMAL_PNG_IDAT)
		local bytes  = png_mod.write(chunks)
		local path   = write_temp(bytes)
		local card, err = platform.load_card(path)
		os.remove(path)
		T.ok(card == nil)
		T.ok(err ~= nil and err:find("script"))
	end)
end)

-- ── platform.run_card ─────────────────────────────────────────────────────────

T.describe("platform.run_card", function ()
	T.it("runs script and returns result", function ()
		local bytes = make_test_card("return 7 + 8")
		local path  = write_temp(bytes)
		local card  = assert(platform.load_card(path))
		os.remove(path)
		local env = sandbox.env(sandbox.stdlib)
		local ok, result = platform.run_card(card, env)
		T.ok(ok)
		T.eq(result, 15)
	end)

	T.it("returns false + error for syntax error", function ()
		local bytes = make_test_card("invalid lua !!!")
		local path  = write_temp(bytes)
		local card  = assert(platform.load_card(path))
		os.remove(path)
		local env = sandbox.env(sandbox.stdlib)
		local ok, err = platform.run_card(card, env)
		T.ok(not ok)
		T.ok(type(err) == "string")
	end)

	T.it("sandbox blocks unauthorized require", function ()
		local bytes = make_test_card("return require('io')")
		local path  = write_temp(bytes)
		local card  = assert(platform.load_card(path))
		os.remove(path)
		local env = sandbox.env(sandbox.stdlib)
		local ok  = platform.run_card(card, env)
		T.ok(not ok, "unauthorized require should fail")
	end)

	T.it("capabilities are accessible inside script", function ()
		local bytes = make_test_card("return caps.answer")
		local path  = write_temp(bytes)
		local card  = assert(platform.load_card(path))
		os.remove(path)
		local env = sandbox.env(sandbox.stdlib, {
			globals = { caps = { answer = 99 } },
		})
		local ok, result = platform.run_card(card, env)
		T.ok(ok)
		T.eq(result, 99)
	end)
end)

-- ── caps.png ──────────────────────────────────────────────────────────────────

T.describe("caps.png", function ()
	T.it("reads tEXt chunks from a PNG file", function ()
		local bytes = make_test_card("return 1", { chara = "hello" })
		local path  = write_temp(bytes)
		local cap   = png_cap(path)
		T.eq(cap.text("chara"),  "hello")
		T.eq(cap.text("script"), "return 1")
		T.eq(cap.text("absent"), nil)
		os.remove(path)
	end)

	T.it("set_text writes back to disk and updates cache", function ()
		local bytes = make_test_card("return 1", { chara = "original" })
		local path  = write_temp(bytes)
		local cap   = png_cap(path)
		cap.set_text("chara", "updated")
		T.eq(cap.text("chara"), "updated")
		-- Confirm persisted: create a new cap from the same file
		local cap2 = png_cap(path)
		T.eq(cap2.text("chara"), "updated")
		os.remove(path)
	end)

	T.it("allowlist blocks denied chunks", function ()
		local bytes = make_test_card("return 1", { chara = "v", secret = "s" })
		local path  = write_temp(bytes)
		local cap   = png_cap(path, { allow = { "chara", "script" } })
		T.eq(cap.text("chara"), "v")
		local ok = pcall(function () cap.text("secret") end)
		T.ok(not ok, "denied chunk should error")
		os.remove(path)
	end)

	T.it("allowlist blocks set_text on denied chunks", function ()
		local bytes = make_test_card("return 1")
		local path  = write_temp(bytes)
		local cap   = png_cap(path, { allow = { "chara" } })
		local ok = pcall(function () cap.set_text("secret", "v") end)
		T.ok(not ok, "denied set_text should error")
		os.remove(path)
	end)
end)

-- ── caps.render ───────────────────────────────────────────────────────────────

T.describe("caps.render", function ()
	T.it("collect_session buffers pushed content", function ()
		local session, get_all = render.collect_session()
		local cap = render.render_cap(session)
		cap.push("hello")
		cap.push("world")
		local items = get_all()
		T.eq(#items, 2)
		T.eq(items[1], "hello")
		T.eq(items[2], "world")
	end)

	T.it("sse_session emits data frames", function ()
		local out = {}
		local session = render.sse_session(function (b) out[#out + 1] = b end)
		local cap = render.render_cap(session)
		cap.push("ping")
		T.eq(#out, 1)
		T.eq(out[1], "data: ping\n\n")
	end)

	T.it("sse_session JSON-encodes table content", function ()
		local out = {}
		local session = render.sse_session(function (b) out[#out + 1] = b end)
		local cap = render.render_cap(session)
		cap.push({ type = "msg", text = "hi" })
		T.eq(#out, 1)
		T.ok(out[1]:find('"type"') ~= nil, "JSON encoded")
	end)
end)

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

-- ── end-to-end: script uses caps inside sandbox ───────────────────────────────

T.describe("platform end-to-end", function ()
	T.it("script reads from caps.png and pushes to caps.render", function ()
		local script = [[
local data = caps.png.text("data")
caps.render.push("got: " .. tostring(data))
return "done"
]]
		local bytes = make_test_card(script, { data = "card-data" })
		local path  = write_temp(bytes)

		local session, get_all = render.collect_session()
		local env = sandbox.env(sandbox.stdlib, {
			globals = {
				caps = {
					png    = png_cap(path, { allow = { "script", "data" } }),
					render = render.render_cap(session),
				},
			},
		})
		local card = assert(platform.load_card(path))
		local ok, result = platform.run_card(card, env)
		os.remove(path)
		T.ok(ok, tostring(result))
		T.eq(result, "done")
		local items = get_all()
		T.eq(#items, 1)
		T.eq(items[1], "got: card-data")
	end)
end)

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
