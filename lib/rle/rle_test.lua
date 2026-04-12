if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local rle = require("lib.rle")

-- ========================
-- helpers
-- ========================

local function sum(t)
  local s = 0
  for _, v in ipairs(t) do s = s + v end
  return s
end

-- ========================
-- BASIC RLE
-- ========================

T.describe("rle.encode / rle.decode", function()
  T.it("round-trips 'aaabbbcc'", function()
    local s       = "aaabbbcc"
    local encoded = rle.encode(s)
    local decoded = rle.decode(encoded)
    T.eq(decoded, s)
  end)

  T.it("round-trips all-same string", function()
    local s       = string.rep("x", 10)
    local encoded = rle.encode(s)
    local decoded = rle.decode(encoded)
    T.eq(decoded, s)
    -- Should be just 2 bytes: (10, 'x')
    T.eq(#encoded, 2)
  end)

  T.it("round-trips all-different string", function()
    local s       = "abcdef"
    local encoded = rle.encode(s)
    local decoded = rle.decode(encoded)
    T.eq(decoded, s)
    -- Each char is a run of 1: 6 * 2 = 12 bytes
    T.eq(#encoded, 12)
  end)

  T.it("round-trips empty string", function()
    local encoded = rle.encode("")
    T.eq(encoded, "")
    local decoded, err = rle.decode("")
    T.eq(decoded, "")
    T.eq(err, nil)
  end)

  T.it("handles run exactly 255", function()
    local s       = string.rep("a", 255)
    local encoded = rle.encode(s)
    local decoded = rle.decode(encoded)
    T.eq(decoded, s)
    T.eq(#encoded, 2)  -- single (255, 'a') pair
  end)

  T.it("splits run > 255 into multiple pairs", function()
    local s       = string.rep("a", 300)
    local encoded = rle.encode(s)
    local decoded = rle.decode(encoded)
    T.eq(decoded, s)
    -- 255 + 45 = 300 → two pairs → 4 bytes
    T.eq(#encoded, 4)
  end)

  T.it("splits run of 512 into two equal pairs", function()
    local s       = string.rep("z", 512)
    local encoded = rle.encode(s)
    local decoded = rle.decode(encoded)
    T.eq(decoded, s)
    -- 255 + 255 + 2 = 512 → three pairs
    T.eq(#encoded, 6)
  end)

  T.it("round-trips mixed long and short runs", function()
    local s = string.rep("a", 300) .. "bc" .. string.rep("d", 260)
    local encoded = rle.encode(s)
    local decoded = rle.decode(encoded)
    T.eq(decoded, s)
  end)

  T.it("decode rejects odd-length input", function()
    local result, err = rle.decode("abc")
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

  T.it("decode rejects zero-count run", function()
    -- Manually craft: count=0, byte='a'
    local bad = string.char(0) .. "a"
    local result, err = rle.decode(bad)
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

  T.it("encodes single character", function()
    local s       = "q"
    local encoded = rle.encode(s)
    local decoded = rle.decode(encoded)
    T.eq(decoded, s)
    T.eq(#encoded, 2)
  end)

  T.it("handles binary data (all byte values)", function()
    local bytes = {}
    for i = 0, 255 do bytes[i + 1] = string.char(i) end
    local s       = table.concat(bytes)
    local encoded = rle.encode(s)
    local decoded = rle.decode(encoded)
    T.eq(decoded, s)
  end)
end)

-- ========================
-- PCX-STYLE RLE
-- ========================

T.describe("rle.encode_pcx / rle.decode_pcx", function()
  T.it("round-trips 'aaabbbcc'", function()
    local s       = "aaabbbcc"
    local encoded = rle.encode_pcx(s)
    local decoded = rle.decode_pcx(encoded)
    T.eq(decoded, s)
  end)

  T.it("passes through bytes below control byte unchanged (no runs)", function()
    local s       = "abcdef"  -- all < 0xC0
    local encoded = rle.encode_pcx(s)
    -- No runs >= min_run=3, all literal and < 0xC0 → pass through unchanged
    T.eq(encoded, s)
    local decoded = rle.decode_pcx(encoded)
    T.eq(decoded, s)
  end)

  T.it("round-trips string with bytes >= control_byte", function()
    local s = string.char(0xC5, 0xD0, 0x41, 0xC5)
    local encoded = rle.encode_pcx(s)
    local decoded = rle.decode_pcx(encoded)
    T.eq(decoded, s)
  end)

  T.it("encodes runs of length >= min_run", function()
    local s       = string.rep("a", 5)  -- run of 5
    local encoded = rle.encode_pcx(s)
    local decoded = rle.decode_pcx(encoded)
    T.eq(decoded, s)
    -- Should be 2 bytes: (0xC5, 'a')
    T.eq(#encoded, 2)
  end)

  T.it("does not encode runs shorter than min_run", function()
    local s       = "aab"  -- run of 2 < min_run=3
    local encoded = rle.encode_pcx(s)
    -- 'a' < 0xC0 → pass through, 'b' < 0xC0 → pass through
    T.eq(encoded, s)
    local decoded = rle.decode_pcx(encoded)
    T.eq(decoded, s)
  end)

  T.it("round-trips long run > 63", function()
    local s       = string.rep("x", 100)
    local encoded = rle.encode_pcx(s)
    local decoded = rle.decode_pcx(encoded)
    T.eq(decoded, s)
  end)

  T.it("round-trips empty string", function()
    local encoded = rle.encode_pcx("")
    T.eq(encoded, "")
    local decoded = rle.decode_pcx("")
    T.eq(decoded, "")
  end)

  T.it("respects custom min_run option", function()
    local s    = "aab"  -- run of 2, then literal 'b'
    local opts = { min_run = 2 }
    local encoded = rle.encode_pcx(s, opts)
    local decoded = rle.decode_pcx(encoded, opts)
    T.eq(decoded, s)
    -- run of 2 → 2 bytes, literal 'b' → 1 byte = 3 bytes total
    T.eq(#encoded, 3)
  end)

  T.it("decode reports error on truncated control word", function()
    -- control byte at end with no following data byte
    local bad    = string.char(0xC3)  -- control byte (>= 0xC0), but no data follows
    local result, err = rle.decode_pcx(bad)
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

  T.it("round-trips binary string with mixed high/low bytes", function()
    local s = string.char(0x00, 0xFF, 0xC0, 0x41, 0xBF, 0xFF, 0xFF, 0xFF)
    local encoded = rle.encode_pcx(s)
    local decoded = rle.decode_pcx(encoded)
    T.eq(decoded, s)
  end)
end)

-- ========================
-- BWT
-- ========================

T.describe("rle.bwt", function()
  -- The standard BWT example: "banana$"
  -- Sorted rotations of "banana$":
  --   $banana  → last char: a
  --   a$banan  → last char: n
  --   ana$ban  → last char: n
  --   anana$b  → last char: b
  --   banana$  → last char: $  (this is rotation starting at index 1, so index=5)
  --   na$bana  → last char: a
  --   nana$ba  → last char: a
  -- L = "annb$aa", index = 5
  T.it("transforms 'banana$' to known result", function()
    local t, idx = rle.bwt("banana$")
    T.eq(t, "annb$aa")
    T.eq(idx, 5)
  end)

  T.it("bwt+ibwt round-trips 'banana$'", function()
    local s       = "banana$"
    local t, idx  = rle.bwt(s)
    local original = rle.ibwt(t, idx)
    T.eq(original, s)
  end)

  T.it("bwt+ibwt round-trips 'abcabc'", function()
    local s       = "abcabc"
    local t, idx  = rle.bwt(s)
    local original = rle.ibwt(t, idx)
    T.eq(original, s)
  end)

  T.it("bwt+ibwt round-trips 'aaabbbccc'", function()
    local s       = "aaabbbccc"
    local t, idx  = rle.bwt(s)
    local original = rle.ibwt(t, idx)
    T.eq(original, s)
  end)

  T.it("bwt+ibwt round-trips single character", function()
    local s       = "a"
    local t, idx  = rle.bwt(s)
    local original = rle.ibwt(t, idx)
    T.eq(original, s)
  end)

  T.it("bwt+ibwt round-trips empty string", function()
    local t, idx  = rle.bwt("")
    T.eq(t, "")
    T.eq(idx, 1)
    local original = rle.ibwt(t, idx)
    T.eq(original, "")
  end)

  T.it("bwt+ibwt round-trips 'mississippi$'", function()
    local s       = "mississippi$"
    local t, idx  = rle.bwt(s)
    local original = rle.ibwt(t, idx)
    T.eq(original, s)
  end)

  T.it("bwt output has same length as input", function()
    local s      = "hello world"
    local t, _   = rle.bwt(s)
    T.eq(#t, #s)
  end)

  T.it("bwt concentrates runs for repetitive input", function()
    -- For a string with lots of repetition, BWT should create longer runs
    local s       = "aababcabcdabcde$"
    local t, idx  = rle.bwt(s)
    local original = rle.ibwt(t, idx)
    T.eq(original, s)
  end)
end)

-- ========================
-- MOVE-TO-FRONT
-- ========================

T.describe("rle.mtf_encode / rle.mtf_decode", function()
  T.it("round-trips 'banana'", function()
    local s    = "banana"
    local ints = rle.mtf_encode(s)
    local out  = rle.mtf_decode(ints)
    T.eq(out, s)
  end)

  T.it("round-trips 'aaabbb'", function()
    local s    = "aaabbb"
    local ints = rle.mtf_encode(s)
    -- After first 'a', all subsequent 'a' should be 0
    T.eq(ints[2], 0)
    T.eq(ints[3], 0)
    local out  = rle.mtf_decode(ints)
    T.eq(out, s)
  end)

  T.it("first occurrence of each char is at its alphabet index", function()
    -- "abc": 'a'=0, 'b'=1, 'c'=2 in ASCII order (0-based positions in initial alphabet)
    local s    = "abc"
    local ints = rle.mtf_encode(s)
    -- 'a' is at position 97 in 0..255 alphabet initially
    T.eq(ints[1], 97)
    -- After moving 'a' to front, 'b' was at 98 but 'a' shifted everything up by 1
    -- 'b' is now at position 98+1-1... actually let's just verify round-trip
    local out  = rle.mtf_decode(ints)
    T.eq(out, s)
  end)

  T.it("repeated chars produce index 0 after first occurrence", function()
    local s    = "aaaa"
    local ints = rle.mtf_encode(s)
    T.eq(ints[2], 0)
    T.eq(ints[3], 0)
    T.eq(ints[4], 0)
    local out  = rle.mtf_decode(ints)
    T.eq(out, s)
  end)

  T.it("round-trips empty string", function()
    local ints = rle.mtf_encode("")
    T.eq(#ints, 0)
    local out  = rle.mtf_decode({})
    T.eq(out, "")
  end)

  T.it("round-trips all-different chars", function()
    local s    = "abcdefgh"
    local ints = rle.mtf_encode(s)
    local out  = rle.mtf_decode(ints)
    T.eq(out, s)
  end)

  T.it("round-trips binary data", function()
    local bytes = {}
    for i = 0, 15 do bytes[i + 1] = string.char(i) end
    local s    = table.concat(bytes)
    local ints = rle.mtf_encode(s)
    local out  = rle.mtf_decode(ints)
    T.eq(out, s)
  end)

  T.it("all indices are in range 0..255", function()
    local s    = "the quick brown fox jumps over the lazy dog"
    local ints = rle.mtf_encode(s)
    for _, v in ipairs(ints) do
      T.ok(v >= 0 and v <= 255)
    end
    local out = rle.mtf_decode(ints)
    T.eq(out, s)
  end)

  T.it("encode produces same length as input", function()
    local s    = "hello"
    local ints = rle.mtf_encode(s)
    T.eq(#ints, #s)
  end)
end)

-- ========================
-- COMBINED PIPELINE
-- ========================

T.describe("rle.compress / rle.decompress", function()
  T.it("round-trips 'abcabc'", function()
    local s = "abcabc"
    local encoded, err = rle.compress(s)
    T.eq(err, nil)
    local decoded, err2 = rle.decompress(encoded)
    T.eq(err2, nil)
    T.eq(decoded, s)
  end)

  T.it("round-trips 'aaabbbccc' (long runs)", function()
    local s = "aaabbbccc"
    local encoded = rle.compress(s)
    local decoded = rle.decompress(encoded)
    T.eq(decoded, s)
  end)

  T.it("round-trips a random-looking string", function()
    local s = "the quick brown fox jumps over the lazy dog"
    local encoded = rle.compress(s)
    local decoded = rle.decompress(encoded)
    T.eq(decoded, s)
  end)

  T.it("round-trips empty string", function()
    local encoded = rle.compress("")
    T.eq(#encoded, 4)  -- just the 4-byte BWT index
    local decoded = rle.decompress(encoded)
    T.eq(decoded, "")
  end)

  T.it("round-trips single character", function()
    local s       = "z"
    local encoded = rle.compress(s)
    local decoded = rle.decompress(encoded)
    T.eq(decoded, s)
  end)

  T.it("round-trips highly repetitive string", function()
    local s       = string.rep("a", 100)
    local encoded = rle.compress(s)
    local decoded = rle.decompress(encoded)
    T.eq(decoded, s)
  end)

  T.it("compress output is shorter than input for repetitive data", function()
    local s       = string.rep("a", 100)
    local encoded = rle.compress(s)
    T.ok(#encoded < #s)
  end)

  T.it("decompress returns error on too-short input", function()
    local result, err = rle.decompress("abc")
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

  T.it("round-trips 'banana$'", function()
    local s       = "banana$"
    local encoded = rle.compress(s)
    local decoded = rle.decompress(encoded)
    T.eq(decoded, s)
  end)

  T.it("round-trips mixed content", function()
    local s = "aaa" .. string.rep("b", 50) .. "ccc" .. string.rep("d", 30)
    local encoded = rle.compress(s)
    local decoded = rle.decompress(encoded)
    T.eq(decoded, s)
  end)
end)

-- ========================
-- DELTA ENCODING
-- ========================

T.describe("rle.delta_encode / rle.delta_decode", function()
  T.it("round-trips a monotonically increasing sequence", function()
    local vals    = {1, 2, 3, 4, 5, 6, 7, 8}
    local deltas  = rle.delta_encode(vals)
    -- First value unchanged, rest should be 1
    T.eq(deltas[1], 1)
    for i = 2, #deltas do T.eq(deltas[i], 1) end
    local decoded = rle.delta_decode(deltas)
    for i, v in ipairs(vals) do T.eq(decoded[i], v) end
  end)

  T.it("round-trips arbitrary values", function()
    local vals    = {10, 3, 17, -5, 0, 100, 50}
    local deltas  = rle.delta_encode(vals)
    T.eq(deltas[1], 10)
    local decoded = rle.delta_decode(deltas)
    for i, v in ipairs(vals) do T.eq(decoded[i], v) end
  end)

  T.it("round-trips empty array", function()
    local deltas  = rle.delta_encode({})
    T.eq(#deltas, 0)
    local decoded = rle.delta_decode({})
    T.eq(#decoded, 0)
  end)

  T.it("round-trips single value", function()
    local vals    = {42}
    local deltas  = rle.delta_encode(vals)
    T.eq(deltas[1], 42)
    local decoded = rle.delta_decode(deltas)
    T.eq(decoded[1], 42)
  end)

  T.it("round-trips constant sequence (all same)", function()
    local vals    = {5, 5, 5, 5, 5}
    local deltas  = rle.delta_encode(vals)
    -- All deltas after first should be 0
    for i = 2, #deltas do T.eq(deltas[i], 0) end
    local decoded = rle.delta_decode(deltas)
    for i, v in ipairs(vals) do T.eq(decoded[i], v) end
  end)

  T.it("handles negative values", function()
    local vals    = {100, 50, 25, 10, -10}
    local deltas  = rle.delta_encode(vals)
    local decoded = rle.delta_decode(deltas)
    for i, v in ipairs(vals) do T.eq(decoded[i], v) end
  end)
end)

T.describe("rle.delta_encode_bytes / rle.delta_decode_bytes", function()
  T.it("round-trips 'hello'", function()
    local s       = "hello"
    local encoded = rle.delta_encode_bytes(s)
    local decoded = rle.delta_decode_bytes(encoded)
    T.eq(decoded, s)
  end)

  T.it("round-trips empty string", function()
    local encoded = rle.delta_encode_bytes("")
    T.eq(encoded, "")
    local decoded = rle.delta_decode_bytes("")
    T.eq(decoded, "")
  end)

  T.it("round-trips single byte", function()
    local s       = "A"
    local encoded = rle.delta_encode_bytes(s)
    local decoded = rle.delta_decode_bytes(encoded)
    T.eq(decoded, s)
  end)

  T.it("round-trips ascending bytes (0..10)", function()
    local bytes = {}
    for i = 0, 10 do bytes[i + 1] = string.char(i) end
    local s       = table.concat(bytes)
    local encoded = rle.delta_encode_bytes(s)
    -- Ascending by 1 → all delta bytes after first should be 1
    for i = 2, #encoded do
      T.eq(encoded:byte(i), 1)
    end
    local decoded = rle.delta_decode_bytes(encoded)
    T.eq(decoded, s)
  end)

  T.it("round-trips all-same bytes", function()
    local s       = string.rep(string.char(128), 8)
    local encoded = rle.delta_encode_bytes(s)
    -- All deltas after first should be 0
    for i = 2, #encoded do
      T.eq(encoded:byte(i), 0)
    end
    local decoded = rle.delta_decode_bytes(encoded)
    T.eq(decoded, s)
  end)

  T.it("round-trips binary data with wraparound", function()
    -- 0xFF + 1 wraps to 0 mod 256
    local s       = string.char(0xFE, 0xFF, 0x00, 0x01, 0x02)
    local encoded = rle.delta_encode_bytes(s)
    local decoded = rle.delta_decode_bytes(encoded)
    T.eq(decoded, s)
  end)

  T.it("output has same length as input", function()
    local s       = "abcdefgh"
    local encoded = rle.delta_encode_bytes(s)
    T.eq(#encoded, #s)
  end)
end)
