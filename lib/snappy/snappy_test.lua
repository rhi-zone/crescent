-- lib/snappy/snappy_test.lua
-- Comprehensive tests for lib/snappy.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local snappy = require("lib.snappy")

T.describe("lib.snappy", function()

  T.describe("tier", function()
    T.it("is pure", function()
      T.eq(snappy._tier, "pure")
    end)
  end)

  T.describe("decompress", function()

    T.it("decodes a hand-crafted literal block", function()
      -- varint(4) = \x04
      -- literal tag: length 4 → tag = (4-1) << 2 | 0x00 = 0x0c
      -- followed by "test"
      local compressed = "\x04\x0c" .. "test"
      local result, err = snappy.decompress(compressed)
      T.eq(err, nil)
      T.eq(result, "test")
    end)

    T.it("decodes a single byte literal", function()
      -- varint(1) = \x01
      -- literal tag: length 1 → tag = 0 << 2 | 0x00 = 0x00
      local compressed = "\x01\x00" .. "A"
      local result, err = snappy.decompress(compressed)
      T.eq(err, nil)
      T.eq(result, "A")
    end)

    T.it("decodes a hand-crafted copy-2 block", function()
      -- Encode "abcdabcd" manually:
      --   varint(8) = \x08
      --   literal tag for 4 bytes: (4-1)<<2 = 0x0c, then "abcd"
      --   copy-2 tag: length=4, offset=4 → tag = ((4-1)<<2)|0x02 = 0x0e, offset LE = \x04\x00
      local compressed = "\x08" .. "\x0c" .. "abcd" .. "\x0e\x04\x00"
      local result, err = snappy.decompress(compressed)
      T.eq(err, nil)
      T.eq(result, "abcdabcd")
    end)

    T.it("decodes a hand-crafted copy-1 block", function()
      -- "abcdabcd" using copy-1:
      --   varint(8) = \x08
      --   literal: 4 bytes "abcd" → tag = 0x0c
      --   copy-1: length=4, offset=4
      --     len_field = 4 - 4 = 0
      --     off_lo3 = 4 & 7 = 4, off_hi8 = 4 >> 3 = 0
      --     tag = (4<<5) | (0<<2) | 0x01 = 0x81
      --     next byte = 0
      local tag_byte = (4 * 32) + (0 * 4) + 1  -- 0x81
      local compressed = "\x08" .. "\x0c" .. "abcd" .. string.char(tag_byte, 0)
      local result, err = snappy.decompress(compressed)
      T.eq(err, nil)
      T.eq(result, "abcdabcd")
    end)

    T.it("decodes overlapping copy (run-length expansion)", function()
      -- "aaaaaa" (6 bytes) using copy-2:
      --   varint(6) = \x06
      --   literal: 1 byte "a" → tag = 0x00
      --   copy-2: length=5, offset=1 → tag = ((5-1)<<2)|0x02 = 0x12, offset LE = \x01\x00
      local compressed = "\x06" .. "\x00" .. "a" .. "\x12\x01\x00"
      local result, err = snappy.decompress(compressed)
      T.eq(err, nil)
      T.eq(result, "aaaaaa")
    end)

    T.it("returns nil,errmsg on empty input", function()
      local result, err = snappy.decompress("")
      T.eq(result, nil)
      T.ok(type(err) == "string")
    end)

    T.it("returns nil,errmsg on truncated varint", function()
      -- A varint with MSB set but no continuation byte
      local result, err = snappy.decompress("\x80")
      T.eq(result, nil)
      T.ok(type(err) == "string")
    end)

    T.it("returns nil,errmsg on truncated literal data", function()
      -- varint(10) but only 3 literal bytes follow
      local compressed = "\x0a\x27" .. "abc"  -- tag for 10 bytes but only 3 present
      local result, err = snappy.decompress(compressed)
      T.eq(result, nil)
      T.ok(type(err) == "string")
    end)

    T.it("returns nil,errmsg on output length mismatch", function()
      -- varint says 5 bytes, but we only produce 4
      local compressed = "\x05\x0c" .. "test"  -- says 5 but emits 4
      local result, err = snappy.decompress(compressed)
      T.eq(result, nil)
      T.ok(type(err) == "string")
    end)

    T.it("returns nil,errmsg on copy with zero offset", function()
      -- varint(4), literal 1 byte, then copy-2 with offset=0
      local compressed = "\x04\x00" .. "a" .. "\x0e\x00\x00"
      local result, err = snappy.decompress(compressed)
      T.eq(result, nil)
      T.ok(type(err) == "string")
    end)

    T.it("returns nil,errmsg when passed non-string", function()
      local result, err = snappy.decompress(42)
      T.eq(result, nil)
      T.ok(type(err) == "string")
    end)

  end)

  T.describe("compress/decompress round-trips", function()

    T.it("round-trips empty string", function()
      local compressed, cerr = snappy.compress("")
      T.eq(cerr, nil)
      T.ok(type(compressed) == "string")
      local result, derr = snappy.decompress(compressed)
      T.eq(derr, nil)
      T.eq(result, "")
    end)

    T.it("round-trips a single byte", function()
      local input = "X"
      local compressed, cerr = snappy.compress(input)
      T.eq(cerr, nil)
      local result, derr = snappy.decompress(compressed)
      T.eq(derr, nil)
      T.eq(result, input)
    end)

    T.it("round-trips a short ASCII string", function()
      local input = "Hello, world!"
      local compressed, cerr = snappy.compress(input)
      T.eq(cerr, nil)
      local result, derr = snappy.decompress(compressed)
      T.eq(derr, nil)
      T.eq(result, input)
    end)

    T.it("round-trips a highly repetitive string (triggers copy elements)", function()
      local input = string.rep("a", 1000)
      local compressed, cerr = snappy.compress(input)
      T.eq(cerr, nil)
      local result, derr = snappy.decompress(compressed)
      T.eq(derr, nil)
      T.eq(result, input)
    end)

    T.it("round-trips a string with repeated patterns", function()
      local input = string.rep("abcdefgh", 100)
      local compressed, cerr = snappy.compress(input)
      T.eq(cerr, nil)
      local result, derr = snappy.decompress(compressed)
      T.eq(derr, nil)
      T.eq(result, input)
    end)

    T.it("round-trips medium text with repetition", function()
      local input = "The quick brown fox jumps over the lazy dog. "
        .. string.rep("The quick brown fox jumps over the lazy dog. ", 20)
      local compressed, cerr = snappy.compress(input)
      T.eq(cerr, nil)
      local result, derr = snappy.decompress(compressed)
      T.eq(derr, nil)
      T.eq(result, input)
    end)

    T.it("round-trips binary data (all byte values)", function()
      local bytes = {}
      for i = 0, 255 do bytes[i + 1] = string.char(i) end
      local input = table.concat(bytes)
      local compressed, cerr = snappy.compress(input)
      T.eq(cerr, nil)
      local result, derr = snappy.decompress(compressed)
      T.eq(derr, nil)
      T.eq(result, input)
    end)

    T.it("round-trips binary data repeated (exercises back-references)", function()
      local bytes = {}
      for i = 0, 255 do bytes[i + 1] = string.char(i) end
      local block = table.concat(bytes)
      local input = block .. block .. block
      local compressed, cerr = snappy.compress(input)
      T.eq(cerr, nil)
      local result, derr = snappy.decompress(compressed)
      T.eq(derr, nil)
      T.eq(result, input)
    end)

    T.it("round-trips a string of all zeros", function()
      local input = string.rep("\x00", 500)
      local compressed, cerr = snappy.compress(input)
      T.eq(cerr, nil)
      local result, derr = snappy.decompress(compressed)
      T.eq(derr, nil)
      T.eq(result, input)
    end)

    T.it("round-trips a longer lorem-ipsum-style text", function()
      local input = string.rep(
        "Lorem ipsum dolor sit amet, consectetur adipiscing elit. "
        .. "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. ",
        10
      )
      local compressed, cerr = snappy.compress(input)
      T.eq(cerr, nil)
      local result, derr = snappy.decompress(compressed)
      T.eq(derr, nil)
      T.eq(result, input)
    end)

  end)

  T.describe("compression ratio", function()

    T.it("compresses repetitive input to less than 50% of original size", function()
      local input = string.rep("a", 1000)
      local compressed, cerr = snappy.compress(input)
      T.eq(cerr, nil)
      T.ok(#compressed < #input * 0.5)
    end)

    T.it("compresses repeated-pattern input to less than 20% of original size", function()
      local input = string.rep("abcd", 500)
      local compressed, cerr = snappy.compress(input)
      T.eq(cerr, nil)
      T.ok(#compressed < #input * 0.20)
    end)

  end)

  T.describe("is_valid", function()

    T.it("returns true for valid compressed data", function()
      local compressed, _ = snappy.compress("hello")
      T.ok(snappy.is_valid(compressed))
    end)

    T.it("returns false for empty string", function()
      T.ok(not snappy.is_valid(""))
    end)

    T.it("returns false for non-string", function()
      T.ok(not snappy.is_valid(nil))
      T.ok(not snappy.is_valid(42))
    end)

    T.it("returns false for truncated varint", function()
      T.ok(not snappy.is_valid("\x80"))
    end)

    T.it("returns true for hand-crafted valid data", function()
      -- varint(4) + literal tag + "test"
      T.ok(snappy.is_valid("\x04\x0c" .. "test"))
    end)

  end)

  T.describe("aliases", function()

    T.it("encode is compress", function()
      T.eq(snappy.encode, snappy.compress)
    end)

    T.it("decode is decompress", function()
      T.eq(snappy.decode, snappy.decompress)
    end)

    T.it("encode/decode round-trip works", function()
      local input = "alias test string"
      local compressed, _ = snappy.encode(input)
      local result, err = snappy.decode(compressed)
      T.eq(err, nil)
      T.eq(result, input)
    end)

  end)

end)
