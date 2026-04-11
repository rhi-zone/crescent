-- lib/lz4/lz4_test.lua
-- Tests for lib.lz4: LZ4 block and frame compression/decompression.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local lz4 = require("lib.lz4")

-- ── tier ─────────────────────────────────────────────────────────────────────

T.describe("lib.lz4", function()
	T.describe("tier", function()
		T.it("_tier is 'pure'", function()
			T.eq(lz4._tier, "pure")
		end)

		T.it("has codec aliases", function()
			T.eq(lz4.encode, lz4.compress)
			T.eq(lz4.decode, lz4.decompress)
		end)
	end)

	-- ── decompress_block ────────────────────────────────────────────────────

	T.describe("decompress_block", function()
		T.it("empty input returns empty string", function()
			local out, err = lz4.decompress_block("")
			T.eq(err, nil)
			T.eq(out, "")
		end)

		T.it("hand-crafted 2-literal block: token=0x20, 'a', 'b'", function()
			-- token high nibble=2 (2 literals), low nibble=0 (match_len prefix=0)
			-- This is the last sequence so no match offset follows.
			local compressed = "\x20ab"
			local out, err = lz4.decompress_block(compressed)
			T.eq(err, nil)
			T.eq(out, "ab")
		end)

		T.it("hand-crafted single literal: token=0x10, 'x'", function()
			local compressed = "\x10x"
			local out, err = lz4.decompress_block(compressed)
			T.eq(err, nil)
			T.eq(out, "x")
		end)

		T.it("hand-crafted literals then match back-reference", function()
			-- Encode "abcdabcd" manually:
			--   First sequence: 4 literals "abcd", then match offset=4, match_len=4
			--   token: lit_nibble=4, match_nibble=0 (4+0=4) → 0x40
			--   literals: "abcd"
			--   offset: 4 LE → "\x04\x00"
			--   match extra: none (nibble=0, len=4+0=4)
			--   Second (last) sequence: 0 literals, no match
			--   token: 0x00
			local compressed = "\x40abcd\x04\x00\x00"
			local out, err = lz4.decompress_block(compressed)
			T.eq(err, nil)
			T.eq(out, "abcdabcd")
		end)

		T.it("invalid zero offset returns error", function()
			-- 4 literals + match with offset=0 (invalid)
			local compressed = "\x40abcd\x00\x00\x00"
			local out, err = lz4.decompress_block(compressed)
			T.eq(out, nil)
			T.ok(err ~= nil)
		end)

		T.it("non-string input returns error", function()
			local out, err = lz4.decompress_block(42)
			T.eq(out, nil)
			T.ok(err ~= nil)
		end)

		T.it("truncated match offset returns error", function()
			-- token = 0x10 (1 literal, match nibble=0 → but NOT last sequence since ip <= clen after literal)
			-- 1 literal byte "a", then only 1 byte for offset (needs 2)
			-- token 0x10: lit=1, match_nibble=0 → match_len=4
			-- After reading literal "a", ip=3 but we only have 1 byte left for offset → truncated
			local compressed = "\x10a\x04"  -- only 1 byte offset instead of 2
			local out, err = lz4.decompress_block(compressed)
			T.eq(out, nil)
			T.ok(err ~= nil)
		end)

		T.it("round-trip compress_block/decompress_block: short string", function()
			local input = "hello world"
			local c, cerr = lz4.compress_block(input)
			T.eq(cerr, nil)
			T.ok(c ~= nil)
			local d, derr = lz4.decompress_block(c)
			T.eq(derr, nil)
			T.eq(d, input)
		end)

		T.it("round-trip compress_block/decompress_block: highly repetitive", function()
			local input = string.rep("a", 100)
			local c, cerr = lz4.compress_block(input)
			T.eq(cerr, nil)
			-- Should compress well (much smaller than input)
			T.ok(#c < #input)
			local d, derr = lz4.decompress_block(c)
			T.eq(derr, nil)
			T.eq(d, input)
		end)

		T.it("round-trip compress_block/decompress_block: repeated pattern", function()
			local input = string.rep("abcdefgh", 20)
			local c, cerr = lz4.compress_block(input)
			T.eq(cerr, nil)
			local d, derr = lz4.decompress_block(c)
			T.eq(derr, nil)
			T.eq(d, input)
		end)

		T.it("round-trip compress_block/decompress_block: single byte", function()
			local input = "z"
			local c, cerr = lz4.compress_block(input)
			T.eq(cerr, nil)
			local d, derr = lz4.decompress_block(c)
			T.eq(derr, nil)
			T.eq(d, input)
		end)

		T.it("round-trip compress_block/decompress_block: binary data", function()
			-- Build a string with all byte values
			local parts = {}
			for i = 0, 255 do parts[i + 1] = string.char(i) end
			local input = table.concat(parts)
			local c, cerr = lz4.compress_block(input)
			T.eq(cerr, nil)
			local d, derr = lz4.decompress_block(c)
			T.eq(derr, nil)
			T.eq(d, input)
		end)
	end)

	-- ── compress_block / decompress_block round-trips ───────────────────────

	T.describe("compress_block / decompress_block round-trips", function()
		T.it("empty string", function()
			local c, cerr = lz4.compress_block("")
			T.eq(cerr, nil)
			local d, derr = lz4.decompress_block(c)
			T.eq(derr, nil)
			T.eq(d, "")
		end)

		T.it("Lorem ipsum-style text", function()
			local input = "The quick brown fox jumps over the lazy dog. "
				.. "Pack my box with five dozen liquor jugs. "
				.. "How vexingly quick daft zebras jump!"
			local c, cerr = lz4.compress_block(input)
			T.eq(cerr, nil)
			local d, derr = lz4.decompress_block(c)
			T.eq(derr, nil)
			T.eq(d, input)
		end)

		T.it("medium text with repetitions", function()
			local input = string.rep("hello world! ", 50)
			local c, cerr = lz4.compress_block(input)
			T.eq(cerr, nil)
			-- Repetitive — should compress
			T.ok(#c < #input)
			local d, derr = lz4.decompress_block(c)
			T.eq(derr, nil)
			T.eq(d, input)
		end)

		T.it("all-zeros string", function()
			local input = string.rep("\x00", 200)
			local c, cerr = lz4.compress_block(input)
			T.eq(cerr, nil)
			T.ok(#c < #input)
			local d, derr = lz4.decompress_block(c)
			T.eq(derr, nil)
			T.eq(d, input)
		end)

		T.it("non-string input returns error", function()
			local c, err = lz4.compress_block(nil)
			T.eq(c, nil)
			T.ok(err ~= nil)
		end)
	end)

	-- ── frame compress / decompress ─────────────────────────────────────────

	T.describe("frame compress / decompress", function()
		T.it("round-trip empty string", function()
			local c, cerr = lz4.compress("")
			T.eq(cerr, nil)
			local d, derr = lz4.decompress(c)
			T.eq(derr, nil)
			T.eq(d, "")
		end)

		T.it("round-trip short string", function()
			local input = "hello, LZ4!"
			local c, cerr = lz4.compress(input)
			T.eq(cerr, nil)
			local d, derr = lz4.decompress(c)
			T.eq(derr, nil)
			T.eq(d, input)
		end)

		T.it("round-trip repetitive data", function()
			local input = string.rep("abcabc", 100)
			local c, cerr = lz4.compress(input)
			T.eq(cerr, nil)
			local d, derr = lz4.decompress(c)
			T.eq(derr, nil)
			T.eq(d, input)
		end)

		T.it("round-trip binary data", function()
			local parts = {}
			for i = 0, 255 do parts[i + 1] = string.char(i) end
			local input = table.concat(parts)
			local c, cerr = lz4.compress(input)
			T.eq(cerr, nil)
			local d, derr = lz4.decompress(c)
			T.eq(derr, nil)
			T.eq(d, input)
		end)

		T.it("frame starts with correct magic bytes", function()
			local c, cerr = lz4.compress("test")
			T.eq(cerr, nil)
			-- Magic = 0x184D2204 → bytes 04 22 4D 18
			T.eq(string.byte(c, 1), 0x04)
			T.eq(string.byte(c, 2), 0x22)
			T.eq(string.byte(c, 3), 0x4D)
			T.eq(string.byte(c, 4), 0x18)
		end)

		T.it("wrong magic returns error", function()
			local d, err = lz4.decompress("XXXX" .. string.rep("\x00", 10))
			T.eq(d, nil)
			T.ok(err ~= nil)
			T.ok(err:find("magic") ~= nil or err:find("invalid") ~= nil)
		end)

		T.it("too-short input returns error", function()
			local d, err = lz4.decompress("abc")
			T.eq(d, nil)
			T.ok(err ~= nil)
		end)

		T.it("non-string input returns error", function()
			local d, err = lz4.decompress(false)
			T.eq(d, nil)
			T.ok(err ~= nil)
		end)

		T.it("encode/decode aliases work", function()
			local input = "alias test"
			local c, cerr = lz4.encode(input)
			T.eq(cerr, nil)
			local d, derr = lz4.decode(c)
			T.eq(derr, nil)
			T.eq(d, input)
		end)

		T.it("round-trip long text", function()
			local input = string.rep(
				"The quick brown fox jumps over the lazy dog. ",
				200
			)
			local c, cerr = lz4.compress(input)
			T.eq(cerr, nil)
			-- Should compress well
			T.ok(#c < #input / 2)
			local d, derr = lz4.decompress(c)
			T.eq(derr, nil)
			T.eq(d, input)
		end)
	end)
end)
