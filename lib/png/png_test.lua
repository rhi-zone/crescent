-- lib/png/png_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local PNG = require("lib.png")

-- ── Minimal PNG fixture ───────────────────────────────────────────────────────
-- Build a structurally valid PNG from scratch (1×1 px, no real image data).
-- IHDR: width=1, height=1, bit_depth=8, color_type=2 (RGB), rest 0.
-- IDAT: one fake compressed byte (0x00) — not a real zlib stream, but enough
--       for chunk round-trip tests that never decode image data.
-- IEND: empty.

local bit = require("bit")

local function write_u32(n)
	if n < 0 then n = n + 0x100000000 end
	local d = n % 256; n = math.floor(n / 256)
	local c = n % 256; n = math.floor(n / 256)
	local b = n % 256; n = math.floor(n / 256)
	return string.char(n % 256, b, c, d)
end

local crc_table = {}
do
	for i = 0, 255 do
		local c = i
		for _ = 1, 8 do
			if bit.band(c, 1) ~= 0 then
				c = bit.bxor(bit.rshift(c, 1), 0xEDB88320)
			else
				c = bit.rshift(c, 1)
			end
		end
		crc_table[i] = c
	end
end
local function crc32(s)
	local crc = bit.bnot(0)
	for i = 1, #s do
		local b = string.byte(s, i)
		crc = bit.bxor(bit.rshift(crc, 8), crc_table[bit.band(bit.bxor(crc, b), 0xFF)])
	end
	return bit.bnot(crc)
end

local function make_chunk(t, data)
	data = data or ""
	return write_u32(#data) .. t .. data .. write_u32(crc32(t .. data))
end

local IHDR_DATA = write_u32(1) .. write_u32(1) .. "\8\2\0\0\0"  -- 1×1, 8-bit RGB
local FAKE_IDAT = "\0"  -- not a valid zlib stream, but opaque for these tests

local function make_png(extra_chunks)
	local parts = { "\137PNG\r\n\26\n", make_chunk("IHDR", IHDR_DATA) }
	if extra_chunks then
		for _, c in ipairs(extra_chunks) do
			parts[#parts + 1] = make_chunk(c.type, c.data)
		end
	end
	parts[#parts + 1] = make_chunk("IDAT", FAKE_IDAT)
	parts[#parts + 1] = make_chunk("IEND", "")
	return table.concat(parts)
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("png.read", function()
	T.it("rejects non-PNG bytes", function()
		local ok, err = PNG.read("not a png")
		T.eq(ok, nil)
		T.ok(err:find("not a PNG"))
	end)

	T.it("reads chunks in order", function()
		local chunks = PNG.read(make_png())
		T.ok(chunks)
		T.eq(chunks[1].type, "IHDR")
		T.eq(chunks[2].type, "IDAT")
		T.eq(chunks[3].type, "IEND")
	end)

	T.it("IHDR data is preserved verbatim", function()
		local chunks = PNG.read(make_png())
		T.eq(chunks[1].data, IHDR_DATA)
	end)

	T.it("IDAT data is passed through opaquely", function()
		local chunks = PNG.read(make_png())
		T.eq(chunks[2].data, FAKE_IDAT)
	end)

	T.it("IEND data is empty", function()
		local chunks = PNG.read(make_png())
		T.eq(chunks[3].data, "")
	end)

	T.it("reads tEXt chunks between IDAT and IEND", function()
		local extra = { { type = "tEXt", data = "Author\0Alice" } }
		local chunks = PNG.read(make_png(extra))
		T.eq(#chunks, 4)  -- IHDR, tEXt, IDAT, IEND
		T.eq(chunks[2].type, "tEXt")
	end)
end)

T.describe("png.write", function()
	T.it("write then read roundtrips chunks", function()
		local original = PNG.read(make_png())
		local bytes = PNG.write(original)
		local roundtrip = PNG.read(bytes)
		T.eq(#roundtrip, #original)
		for i = 1, #original do
			T.eq(roundtrip[i].type, original[i].type)
			T.eq(roundtrip[i].data, original[i].data)
		end
	end)

	T.it("write produces valid PNG signature", function()
		local chunks = PNG.read(make_png())
		local bytes = PNG.write(chunks)
		T.eq(bytes:sub(1, 8), "\137PNG\r\n\26\n")
	end)

	T.it("write recalculates correct CRC", function()
		-- Corrupt a chunk's data then rewrite — CRC should be correct for new data.
		local chunks = PNG.read(make_png())
		chunks[1].data = IHDR_DATA  -- same value, but forces recompute
		local bytes = PNG.write(chunks)
		-- If CRC were wrong, a strict reader would reject it.
		-- We verify by reading back and checking data integrity.
		local back = PNG.read(bytes)
		T.eq(back[1].data, IHDR_DATA)
	end)
end)

T.describe("png.parse_text / build_text", function()
	T.it("parse_text extracts keyword and text", function()
		local entry = PNG.parse_text("Comment\0hello world")
		T.ok(entry)
		T.eq(entry.keyword, "Comment")
		T.eq(entry.text, "hello world")
	end)

	T.it("parse_text handles empty text", function()
		local entry = PNG.parse_text("Key\0")
		T.ok(entry)
		T.eq(entry.keyword, "Key")
		T.eq(entry.text, "")
	end)

	T.it("parse_text returns nil+err on missing NUL", function()
		local entry, err = PNG.parse_text("nokeywordsep")
		T.eq(entry, nil)
		T.ok(err)
	end)

	T.it("build_text produces NUL-separated data", function()
		local data = PNG.build_text("Author", "Bob")
		T.eq(data, "Author\0Bob")
	end)

	T.it("parse_text(build_text(...)) roundtrips", function()
		local data = PNG.build_text("Source", "camera")
		local entry = PNG.parse_text(data)
		T.eq(entry.keyword, "Source")
		T.eq(entry.text, "camera")
	end)
end)

T.describe("png.get_text", function()
	T.it("returns nil when keyword absent", function()
		local chunks = PNG.read(make_png())
		T.eq(PNG.get_text(chunks, "Author"), nil)
	end)

	T.it("returns text when keyword present", function()
		local extra = { { type = "tEXt", data = "Author\0Alice" } }
		local chunks = PNG.read(make_png(extra))
		T.eq(PNG.get_text(chunks, "Author"), "Alice")
	end)

	T.it("returns first match when multiple entries share keyword", function()
		local extra = {
			{ type = "tEXt", data = "Tag\0first" },
			{ type = "tEXt", data = "Tag\0second" },
		}
		local chunks = PNG.read(make_png(extra))
		T.eq(PNG.get_text(chunks, "Tag"), "first")
	end)

	T.it("does not match different keyword", function()
		local extra = { { type = "tEXt", data = "Author\0Alice" } }
		local chunks = PNG.read(make_png(extra))
		T.eq(PNG.get_text(chunks, "Comment"), nil)
	end)
end)

T.describe("png.set_text", function()
	T.it("inserts new tEXt chunk before IEND when absent", function()
		local chunks = PNG.read(make_png())
		local out = PNG.set_text(chunks, "Author", "Bob")
		T.eq(PNG.get_text(out, "Author"), "Bob")
	end)

	T.it("IEND remains last after insert", function()
		local chunks = PNG.read(make_png())
		local out = PNG.set_text(chunks, "Key", "val")
		T.eq(out[#out].type, "IEND")
	end)

	T.it("replaces existing tEXt chunk in-place", function()
		local extra = { { type = "tEXt", data = "Author\0Alice" } }
		local chunks = PNG.read(make_png(extra))
		local out = PNG.set_text(chunks, "Author", "Bob")
		T.eq(PNG.get_text(out, "Author"), "Bob")
	end)

	T.it("replacement does not duplicate the keyword", function()
		local extra = { { type = "tEXt", data = "Author\0Alice" } }
		local chunks = PNG.read(make_png(extra))
		local out = PNG.set_text(chunks, "Author", "Bob")
		local count = 0
		for _, c in ipairs(out) do
			if c.type == "tEXt" then
				local e = PNG.parse_text(c.data)
				if e and e.keyword == "Author" then count = count + 1 end
			end
		end
		T.eq(count, 1)
	end)

	T.it("does not modify original chunks", function()
		local chunks = PNG.read(make_png())
		local before = #chunks
		PNG.set_text(chunks, "Key", "val")
		T.eq(#chunks, before)
	end)

	T.it("preserves unrelated tEXt chunks", function()
		local extra = { { type = "tEXt", data = "Comment\0hi" } }
		local chunks = PNG.read(make_png(extra))
		local out = PNG.set_text(chunks, "Author", "Bob")
		T.eq(PNG.get_text(out, "Comment"), "hi")
		T.eq(PNG.get_text(out, "Author"), "Bob")
	end)
end)

T.describe("png.remove_text", function()
	T.it("removes tEXt chunk with matching keyword", function()
		local extra = { { type = "tEXt", data = "Author\0Alice" } }
		local chunks = PNG.read(make_png(extra))
		local out = PNG.remove_text(chunks, "Author")
		T.eq(PNG.get_text(out, "Author"), nil)
	end)

	T.it("removes all instances of keyword", function()
		local extra = {
			{ type = "tEXt", data = "Tag\0a" },
			{ type = "tEXt", data = "Tag\0b" },
		}
		local chunks = PNG.read(make_png(extra))
		local out = PNG.remove_text(chunks, "Tag")
		T.eq(PNG.get_text(out, "Tag"), nil)
	end)

	T.it("preserves unrelated tEXt chunks", function()
		local extra = {
			{ type = "tEXt", data = "Author\0Alice" },
			{ type = "tEXt", data = "Comment\0hi" },
		}
		local chunks = PNG.read(make_png(extra))
		local out = PNG.remove_text(chunks, "Author")
		T.eq(PNG.get_text(out, "Author"), nil)
		T.eq(PNG.get_text(out, "Comment"), "hi")
	end)

	T.it("is a no-op when keyword absent", function()
		local chunks = PNG.read(make_png())
		local out = PNG.remove_text(chunks, "Missing")
		T.eq(#out, #chunks)
	end)

	T.it("does not modify original chunks", function()
		local extra = { { type = "tEXt", data = "Author\0Alice" } }
		local chunks = PNG.read(make_png(extra))
		local before = #chunks
		PNG.remove_text(chunks, "Author")
		T.eq(#chunks, before)
	end)
end)

-- ── iTXt tests ───────────────────────────────────────────────────────────────

T.describe("png.parse_itxt / build_itxt", function()
	T.it("parse_itxt extracts all fields", function()
		-- keyword\0 flag(0) method(0) lang\0 tkey\0 text
		local data = "Comment\0\0\0en\0Kommentar\0hello world"
		local entry = PNG.parse_itxt(data)
		T.ok(entry)
		T.eq(entry.keyword, "Comment")
		T.eq(entry.text, "hello world")
		T.eq(entry.language_tag, "en")
		T.eq(entry.translated_keyword, "Kommentar")
		T.eq(entry.compressed, false)
	end)

	T.it("parse_itxt handles empty optional fields", function()
		local data = "Key\0\0\0\0\0some text"
		local entry = PNG.parse_itxt(data)
		T.ok(entry)
		T.eq(entry.keyword, "Key")
		T.eq(entry.language_tag, "")
		T.eq(entry.translated_keyword, "")
		T.eq(entry.text, "some text")
		T.eq(entry.compressed, false)
	end)

	T.it("parse_itxt handles empty text", function()
		local data = "Key\0\0\0\0\0"
		local entry = PNG.parse_itxt(data)
		T.ok(entry)
		T.eq(entry.keyword, "Key")
		T.eq(entry.text, "")
	end)

	T.it("parse_itxt reports compressed flag", function()
		local data = "Key\0\1\0\0\0compressed-data"
		local entry = PNG.parse_itxt(data)
		T.ok(entry)
		T.eq(entry.compressed, true)
	end)

	T.it("parse_itxt returns nil+err on missing keyword NUL", function()
		local entry, err = PNG.parse_itxt("nokeywordsep")
		T.eq(entry, nil)
		T.ok(err)
	end)

	T.it("parse_itxt returns nil+err on truncated data", function()
		local entry, err = PNG.parse_itxt("K\0")
		T.eq(entry, nil)
		T.ok(err)
	end)

	T.it("parse_itxt returns nil+err on missing language_tag NUL", function()
		local entry, err = PNG.parse_itxt("K\0\0\0no-null-here")
		T.eq(entry, nil)
		T.ok(err)
	end)

	T.it("parse_itxt returns nil+err on missing translated_keyword NUL", function()
		local entry, err = PNG.parse_itxt("K\0\0\0\0no-null-here")
		T.eq(entry, nil)
		T.ok(err)
	end)

	T.it("build_itxt produces correct layout", function()
		local data = PNG.build_itxt("Author", "Bob")
		T.eq(data, "Author\0\0\0\0\0Bob")
	end)

	T.it("build_itxt with opts", function()
		local data = PNG.build_itxt("Author", "Bob", {
			language_tag = "en",
			translated_keyword = "Autor",
		})
		T.eq(data, "Author\0\0\0en\0Autor\0Bob")
	end)

	T.it("parse_itxt(build_itxt(...)) roundtrips", function()
		local data = PNG.build_itxt("Source", "camera", {
			language_tag = "en",
			translated_keyword = "Quelle",
		})
		local entry = PNG.parse_itxt(data)
		T.eq(entry.keyword, "Source")
		T.eq(entry.text, "camera")
		T.eq(entry.language_tag, "en")
		T.eq(entry.translated_keyword, "Quelle")
		T.eq(entry.compressed, false)
	end)
end)

T.describe("png.get_itxt", function()
	T.it("returns nil when keyword absent", function()
		local chunks = PNG.read(make_png())
		T.eq(PNG.get_itxt(chunks, "Author"), nil)
	end)

	T.it("returns text when keyword present", function()
		local extra = { { type = "iTXt", data = PNG.build_itxt("Author", "Alice") } }
		local chunks = PNG.read(make_png(extra))
		T.eq(PNG.get_itxt(chunks, "Author"), "Alice")
	end)

	T.it("returns first match when multiple entries share keyword", function()
		local extra = {
			{ type = "iTXt", data = PNG.build_itxt("Tag", "first") },
			{ type = "iTXt", data = PNG.build_itxt("Tag", "second") },
		}
		local chunks = PNG.read(make_png(extra))
		T.eq(PNG.get_itxt(chunks, "Tag"), "first")
	end)

	T.it("does not match different keyword", function()
		local extra = { { type = "iTXt", data = PNG.build_itxt("Author", "Alice") } }
		local chunks = PNG.read(make_png(extra))
		T.eq(PNG.get_itxt(chunks, "Comment"), nil)
	end)

	T.it("skips compressed iTXt chunks", function()
		-- Build a compressed iTXt manually (flag=1)
		local data = "Author\0\1\0\0\0compressed-data"
		local extra = { { type = "iTXt", data = data } }
		local chunks = PNG.read(make_png(extra))
		T.eq(PNG.get_itxt(chunks, "Author"), nil)
	end)
end)

T.describe("png.set_itxt", function()
	T.it("inserts new iTXt chunk before IEND when absent", function()
		local chunks = PNG.read(make_png())
		local out = PNG.set_itxt(chunks, "Author", "Bob")
		T.eq(PNG.get_itxt(out, "Author"), "Bob")
	end)

	T.it("IEND remains last after insert", function()
		local chunks = PNG.read(make_png())
		local out = PNG.set_itxt(chunks, "Key", "val")
		T.eq(out[#out].type, "IEND")
	end)

	T.it("replaces existing iTXt chunk in-place", function()
		local extra = { { type = "iTXt", data = PNG.build_itxt("Author", "Alice") } }
		local chunks = PNG.read(make_png(extra))
		local out = PNG.set_itxt(chunks, "Author", "Bob")
		T.eq(PNG.get_itxt(out, "Author"), "Bob")
	end)

	T.it("replacement does not duplicate the keyword", function()
		local extra = { { type = "iTXt", data = PNG.build_itxt("Author", "Alice") } }
		local chunks = PNG.read(make_png(extra))
		local out = PNG.set_itxt(chunks, "Author", "Bob")
		local count = 0
		for _, c in ipairs(out) do
			if c.type == "iTXt" then
				local e = PNG.parse_itxt(c.data)
				if e and e.keyword == "Author" then count = count + 1 end
			end
		end
		T.eq(count, 1)
	end)

	T.it("does not modify original chunks", function()
		local chunks = PNG.read(make_png())
		local before = #chunks
		PNG.set_itxt(chunks, "Key", "val")
		T.eq(#chunks, before)
	end)

	T.it("preserves unrelated iTXt chunks", function()
		local extra = { { type = "iTXt", data = PNG.build_itxt("Comment", "hi") } }
		local chunks = PNG.read(make_png(extra))
		local out = PNG.set_itxt(chunks, "Author", "Bob")
		T.eq(PNG.get_itxt(out, "Comment"), "hi")
		T.eq(PNG.get_itxt(out, "Author"), "Bob")
	end)

	T.it("forwards opts to build_itxt", function()
		local chunks = PNG.read(make_png())
		local out = PNG.set_itxt(chunks, "Author", "Bob", { language_tag = "en" })
		-- Find the iTXt chunk and parse it
		for _, c in ipairs(out) do
			if c.type == "iTXt" then
				local e = PNG.parse_itxt(c.data)
				if e and e.keyword == "Author" then
					T.eq(e.language_tag, "en")
				end
			end
		end
	end)
end)

T.describe("png.remove_itxt", function()
	T.it("removes iTXt chunk with matching keyword", function()
		local extra = { { type = "iTXt", data = PNG.build_itxt("Author", "Alice") } }
		local chunks = PNG.read(make_png(extra))
		local out = PNG.remove_itxt(chunks, "Author")
		T.eq(PNG.get_itxt(out, "Author"), nil)
	end)

	T.it("removes all instances of keyword", function()
		local extra = {
			{ type = "iTXt", data = PNG.build_itxt("Tag", "a") },
			{ type = "iTXt", data = PNG.build_itxt("Tag", "b") },
		}
		local chunks = PNG.read(make_png(extra))
		local out = PNG.remove_itxt(chunks, "Tag")
		T.eq(PNG.get_itxt(out, "Tag"), nil)
	end)

	T.it("preserves unrelated iTXt chunks", function()
		local extra = {
			{ type = "iTXt", data = PNG.build_itxt("Author", "Alice") },
			{ type = "iTXt", data = PNG.build_itxt("Comment", "hi") },
		}
		local chunks = PNG.read(make_png(extra))
		local out = PNG.remove_itxt(chunks, "Author")
		T.eq(PNG.get_itxt(out, "Author"), nil)
		T.eq(PNG.get_itxt(out, "Comment"), "hi")
	end)

	T.it("is a no-op when keyword absent", function()
		local chunks = PNG.read(make_png())
		local out = PNG.remove_itxt(chunks, "Missing")
		T.eq(#out, #chunks)
	end)

	T.it("does not modify original chunks", function()
		local extra = { { type = "iTXt", data = PNG.build_itxt("Author", "Alice") } }
		local chunks = PNG.read(make_png(extra))
		local before = #chunks
		PNG.remove_itxt(chunks, "Author")
		T.eq(#chunks, before)
	end)
end)
