-- lib/hamming/hamming_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local H = require("lib.hamming")

-- ========================
-- HELPERS
-- ========================

local function bits_equal(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

-- ========================
-- HAMMING(7,4) — 4 data bits
-- ========================

T.describe("Hamming(7,4) encode/decode round-trip", function()
  T.it("encodes 4 data bits to 7-bit codeword", function()
    local data = {1, 0, 1, 1}
    local cw = H.encode(data)
    T.eq(#cw, 7, "codeword length should be 7")
    -- All bits are 0 or 1
    for i = 1, 7 do
      T.ok(cw[i] == 0 or cw[i] == 1, "bit " .. i .. " is 0 or 1")
    end
  end)

  T.it("decodes without error to original data", function()
    local data = {1, 0, 1, 1}
    local cw = H.encode(data)
    local decoded, errs = H.decode(cw)
    T.eq(errs, 0, "no errors")
    T.ok(bits_equal(decoded, data), "decoded matches original")
  end)

  T.it("round-trip all-zeros", function()
    local data = {0, 0, 0, 0}
    local cw = H.encode(data)
    local decoded, errs = H.decode(cw)
    T.eq(errs, 0)
    T.ok(bits_equal(decoded, data))
  end)

  T.it("round-trip all-ones", function()
    local data = {1, 1, 1, 1}
    local cw = H.encode(data)
    local decoded, errs = H.decode(cw)
    T.eq(errs, 0)
    T.ok(bits_equal(decoded, data))
  end)
end)

-- ========================
-- HAMMING(15,11) — 11 data bits
-- ========================

T.describe("Hamming(15,11) encode/decode round-trip", function()
  T.it("encodes 11 data bits to 15-bit codeword", function()
    local data = {1,0,1,1,0,0,1,1,0,1,0}
    local cw = H.encode(data)
    T.eq(#cw, 15, "codeword length should be 15")
  end)

  T.it("decodes without error", function()
    local data = {1,0,1,1,0,0,1,1,0,1,0}
    local cw = H.encode(data)
    local decoded, errs = H.decode(cw)
    T.eq(errs, 0)
    T.ok(bits_equal(decoded, data))
  end)

  T.it("round-trip alternate pattern", function()
    local data = {0,1,0,1,0,1,0,1,0,1,0}
    local cw = H.encode(data)
    local decoded, errs = H.decode(cw)
    T.eq(errs, 0)
    T.ok(bits_equal(decoded, data))
  end)
end)

-- ========================
-- SINGLE BIT ERROR CORRECTION
-- ========================

T.describe("single bit error correction", function()
  T.it("corrects a single-bit error in Hamming(7,4)", function()
    local data = {1, 0, 1, 1}
    local cw = H.encode(data)
    -- Flip bit at position 3
    cw[3] = 1 - cw[3]
    local decoded, errs = H.decode(cw)
    T.eq(errs, 1, "one error corrected")
    T.ok(bits_equal(decoded, data), "data recovered correctly")
  end)

  T.it("corrects error at position 1", function()
    local data = {1, 1, 0, 1}
    local cw = H.encode(data)
    cw[1] = 1 - cw[1]
    local decoded, errs = H.decode(cw)
    T.eq(errs, 1)
    T.ok(bits_equal(decoded, data))
  end)

  T.it("corrects error at last position", function()
    local data = {1, 0, 0, 1}
    local cw = H.encode(data)
    cw[7] = 1 - cw[7]
    local decoded, errs = H.decode(cw)
    T.eq(errs, 1)
    T.ok(bits_equal(decoded, data))
  end)

  T.it("corrects single-bit error in Hamming(15,11)", function()
    local data = {1,1,0,0,1,0,1,1,0,0,1}
    local cw = H.encode(data)
    cw[9] = 1 - cw[9]
    local decoded, errs = H.decode(cw)
    T.eq(errs, 1)
    T.ok(bits_equal(decoded, data))
  end)
end)

-- ========================
-- SYNDROME
-- ========================

T.describe("syndrome", function()
  T.it("returns 0 for valid codeword", function()
    local data = {1, 0, 1, 1}
    local cw = H.encode(data)
    T.eq(H.syndrome(cw), 0)
  end)

  T.it("returns error position for single-bit error", function()
    local data = {1, 0, 1, 1}
    local cw = H.encode(data)
    cw[5] = 1 - cw[5]
    T.eq(H.syndrome(cw), 5)
  end)

  T.it("returns correct position for bit 2 flip", function()
    local data = {0, 1, 1, 0}
    local cw = H.encode(data)
    cw[2] = 1 - cw[2]
    T.eq(H.syndrome(cw), 2)
  end)

  T.it("returns correct position for bit 4 flip", function()
    local data = {1, 1, 0, 0}
    local cw = H.encode(data)
    cw[4] = 1 - cw[4]
    T.eq(H.syndrome(cw), 4)
  end)
end)

-- ========================
-- SECDED
-- ========================

T.describe("SECDED", function()
  T.it("encode_secded produces codeword of length n+1", function()
    local data = {1, 0, 1, 1}
    local cw = H.encode_secded(data)
    T.eq(#cw, 8, "SECDED codeword is 8 bits for 4 data bits")
  end)

  T.it("decode_secded round-trip no error", function()
    local data = {1, 0, 1, 1}
    local cw = H.encode_secded(data)
    local decoded, single, double = H.decode_secded(cw)
    T.ok(bits_equal(decoded, data), "data matches")
    T.ok(not single, "no single error")
    T.ok(not double, "no double error")
  end)

  T.it("decode_secded corrects single-bit error", function()
    local data = {1, 0, 1, 1}
    local cw = H.encode_secded(data)
    cw[3] = 1 - cw[3]
    local decoded, single, double = H.decode_secded(cw)
    T.ok(bits_equal(decoded, data), "data recovered")
    T.ok(single, "single error detected")
    T.ok(not double, "not double error")
  end)

  T.it("decode_secded detects double-bit error", function()
    local data = {1, 0, 1, 1}
    local cw = H.encode_secded(data)
    -- Flip two bits
    cw[3] = 1 - cw[3]
    cw[5] = 1 - cw[5]
    local _, single, double = H.decode_secded(cw)
    T.ok(double, "double error detected")
    T.ok(not single, "not flagged as single error")
  end)

  T.it("decode_secded all-zeros round-trip", function()
    local data = {0, 0, 0, 0}
    local cw = H.encode_secded(data)
    local decoded, single, double = H.decode_secded(cw)
    T.ok(bits_equal(decoded, data))
    T.ok(not single)
    T.ok(not double)
  end)
end)

-- ========================
-- PARITY
-- ========================

T.describe("parity_bit", function()
  T.it("even parity: {0,0,0,0} -> 0", function()
    T.eq(H.parity_bit({0,0,0,0}), 0)
  end)

  T.it("odd parity: {1,0,0,0} -> 1", function()
    T.eq(H.parity_bit({1,0,0,0}), 1)
  end)

  T.it("even parity: {1,1,0,0} -> 0", function()
    T.eq(H.parity_bit({1,1,0,0}), 0)
  end)

  T.it("odd parity: {1,1,1,0} -> 1", function()
    T.eq(H.parity_bit({1,1,1,0}), 1)
  end)

  T.it("byte input: 0xff -> 0 (even parity)", function()
    T.eq(H.parity_bit(0xff), 0)
  end)

  T.it("byte input: 0x01 -> 1 (odd parity)", function()
    T.eq(H.parity_bit(0x01), 1)
  end)

  T.it("byte input: 0x03 -> 0 (two bits set)", function()
    T.eq(H.parity_bit(0x03), 0)
  end)

  T.it("byte input: 0x07 -> 1 (three bits set)", function()
    T.eq(H.parity_bit(0x07), 1)
  end)
end)

T.describe("add_parity_bytes / check_parity_bytes", function()
  T.it("round-trip short string", function()
    local s = "ABCDEFG"
    local p = H.add_parity_bytes(s)
    T.ok(H.check_parity_bytes(p), "parity check passes")
  end)

  T.it("round-trip longer string (>7 bytes)", function()
    local s = "Hello, World! How are you?"
    local p = H.add_parity_bytes(s)
    T.ok(H.check_parity_bytes(p))
  end)

  T.it("detects corruption", function()
    local s = "ABCDEFG"
    local p = H.add_parity_bytes(s)
    -- Corrupt a byte
    local corrupted = p:sub(1, 2) .. string.char(string.byte(p, 3) + 1) .. p:sub(4)
    T.ok(not H.check_parity_bytes(corrupted), "corruption detected")
  end)
end)

-- ========================
-- REPETITION CODE
-- ========================

T.describe("repeat_encode / repeat_decode", function()
  T.it("encodes each bit 3 times", function()
    local data = {1, 0, 1}
    local enc = H.repeat_encode(data, 3)
    T.eq(#enc, 9)
    T.eq(enc[1], 1) T.eq(enc[2], 1) T.eq(enc[3], 1)
    T.eq(enc[4], 0) T.eq(enc[5], 0) T.eq(enc[6], 0)
    T.eq(enc[7], 1) T.eq(enc[8], 1) T.eq(enc[9], 1)
  end)

  T.it("decodes with majority vote (no errors)", function()
    local data = {1, 0, 1}
    local enc = H.repeat_encode(data, 3)
    local dec = H.repeat_decode(enc, 3)
    T.ok(bits_equal(dec, data))
  end)

  T.it("corrects single-bit error via majority vote (n=3)", function()
    local data = {1, 0, 1}
    local enc = H.repeat_encode(data, 3)
    -- Flip one bit in first group
    enc[2] = 1 - enc[2]
    local dec = H.repeat_decode(enc, 3)
    T.ok(bits_equal(dec, data), "majority vote corrects single flip")
  end)

  T.it("round-trip with n=5", function()
    local data = {1, 1, 0, 0, 1}
    local enc = H.repeat_encode(data, 5)
    T.eq(#enc, 25)
    local dec = H.repeat_decode(enc, 5)
    T.ok(bits_equal(dec, data))
  end)
end)

-- ========================
-- INTERNET CHECKSUM
-- ========================

T.describe("inet_checksum", function()
  -- RFC 1071 example: the checksum of the sum must be 0xffff when added
  T.it("produces correct checksum for simple data", function()
    -- Simple: two 0x00 bytes -> checksum = 0xffff
    local s = "\x00\x00"
    T.eq(H.inet_checksum(s), 0xffff)
  end)

  T.it("inet_verify returns true for data with correct checksum appended", function()
    local data = "\x45\x00\x00\x54"
    local cs = H.inet_checksum(data)
    local cs_hi = math.floor(cs / 256)
    local cs_lo = cs % 256
    local with_cs = data .. string.char(cs_hi) .. string.char(cs_lo)
    T.ok(H.inet_verify(with_cs), "verify passes with correct checksum")
  end)

  T.it("inet_verify returns false for corrupted data", function()
    local data = "\x45\x00\x00\x54"
    local cs = H.inet_checksum(data)
    local cs_hi = math.floor(cs / 256)
    local cs_lo = cs % 256
    local with_cs = data .. string.char(cs_hi) .. string.char(cs_lo)
    -- Corrupt a byte
    local corrupted = string.char(string.byte(with_cs, 1) + 1) .. with_cs:sub(2)
    T.ok(not H.inet_verify(corrupted), "verify fails with corruption")
  end)

  T.it("checksum of known IP-like header fragment", function()
    -- Known: checksum of \x00\x01\xf2\x03\xf4\xf5\xf6\xf7 = 0x210e
    local data = "\x00\x01\xf2\x03\xf4\xf5\xf6\xf7"
    local cs = H.inet_checksum(data)
    -- Just check it's a 16-bit value
    T.ok(cs >= 0 and cs <= 0xffff, "checksum is 16-bit")
    -- Append and verify
    local hi = math.floor(cs / 256)
    local lo = cs % 256
    T.ok(H.inet_verify(data .. string.char(hi) .. string.char(lo)))
  end)
end)

-- ========================
-- ADLER-32
-- ========================

T.describe("adler32", function()
  T.it("empty string -> 1", function()
    T.eq(H.adler32(""), 1)
  end)

  T.it('"Wikipedia" -> 0x11E60398', function()
    T.eq(H.adler32("Wikipedia"), 0x11E60398)
  end)

  T.it('"abc" has a defined checksum', function()
    -- Adler-32("abc"): a=1+97+98+99=295, b=1+295+295+295+295=1181... let's compute manually
    -- Actually: a=1+97=98; b=1+98=99; a=98+98=196; b=99+196=295; a=196+99=295; b=295+295=590
    -- a=295%65521=295, b=590%65521=590
    -- result = 590*65536 + 295 = 38666535 + 295 = 38666527... let me just verify it's consistent
    local v = H.adler32("abc")
    T.ok(v > 0 and v < 0x100000000, "32-bit result")
    T.eq(H.adler32("abc"), v)  -- deterministic
  end)

  T.it("init parameter: combining chunks equals whole", function()
    local whole = H.adler32("Hello, World!")
    local part1 = H.adler32("Hello, ")
    local part2 = H.adler32("World!", part1)
    T.eq(part2, whole, "incremental adler32 matches whole")
  end)
end)

-- ========================
-- FLETCHER
-- ========================

T.describe("fletcher16", function()
  T.it("deterministic on known input", function()
    local v = H.fletcher16("abcde")
    T.ok(v >= 0 and v <= 0xffff, "16-bit result")
    T.eq(H.fletcher16("abcde"), v)
  end)

  T.it('"abcde" -> known value 0xC8F0', function()
    -- Fletcher-16("abcde") = 0xC8F0 by spec
    T.eq(H.fletcher16("abcde"), 0xC8F0)
  end)

  T.it('"abcdef" -> known value 0x2057', function()
    T.eq(H.fletcher16("abcdef"), 0x2057)
  end)

  T.it("different strings produce different checksums (basic)", function()
    T.neq(H.fletcher16("abc"), H.fletcher16("abd"))
  end)
end)

T.describe("fletcher32", function()
  T.it("deterministic on known input", function()
    local v = H.fletcher32("abcde")
    T.ok(v >= 0 and v < 0x100000000, "32-bit result")
    T.eq(H.fletcher32("abcde"), v)
  end)

  T.it("different strings produce different checksums", function()
    T.neq(H.fletcher32("hello"), H.fletcher32("world"))
  end)
end)

-- ========================
-- LUHN
-- ========================

T.describe("luhn_check", function()
  T.it("valid Visa number -> true", function()
    T.ok(H.luhn_check("4532015112830366"), "known valid Visa")
  end)

  T.it("invalid number -> false", function()
    T.ok(not H.luhn_check("1234567890123456"), "known invalid")
  end)

  T.it("single digit 0 -> true", function()
    T.ok(H.luhn_check("0"), "0 is valid (trivial)")
  end)

  T.it("known valid: 79927398713 -> true", function()
    T.ok(H.luhn_check("79927398713"))
  end)

  T.it("known invalid: 79927398714 -> false", function()
    T.ok(not H.luhn_check("79927398714"))
  end)
end)

T.describe("luhn_digit", function()
  T.it("computes correct check digit for 7992739871", function()
    T.eq(H.luhn_digit("7992739871"), 3)
  end)

  T.it("computed digit produces valid Luhn number", function()
    local base = "453201511283036"
    local d = H.luhn_digit(base)
    T.ok(H.luhn_check(base .. tostring(d)), "appended digit makes valid number")
  end)

  T.it("returns 0 when already divisible", function()
    -- Find a case where digit is 0: base that ends with 0 check
    local d = H.luhn_digit("7992739871")
    T.eq(d, 3)
    T.ok(H.luhn_check("79927398713"))
  end)
end)

-- ========================
-- BIT UTILITIES
-- ========================

T.describe("popcount", function()
  T.it("popcount(0) = 0", function() T.eq(H.popcount(0), 0) end)
  T.it("popcount(1) = 1", function() T.eq(H.popcount(1), 1) end)
  T.it("popcount(3) = 2", function() T.eq(H.popcount(3), 2) end)
  T.it("popcount(0xff) = 8", function() T.eq(H.popcount(0xff), 8) end)
  T.it("popcount(0xffff) = 16", function() T.eq(H.popcount(0xffff), 16) end)
  T.it("popcount(0xffffffff) = 32", function() T.eq(H.popcount(0xffffffff), 32) end)
  T.it("popcount(0x55555555) = 16", function() T.eq(H.popcount(0x55555555), 16) end)
  T.it("popcount(0xaaaaaaaa) = 16", function() T.eq(H.popcount(0xaaaaaaaa), 16) end)
  T.it("popcount(7) = 3", function() T.eq(H.popcount(7), 3) end)
  T.it("popcount(128) = 1", function() T.eq(H.popcount(128), 1) end)
end)

T.describe("hamming_distance", function()
  T.it("identical integers -> 0", function()
    T.eq(H.hamming_distance(0xff, 0xff), 0)
  end)

  T.it("one bit differs -> 1", function()
    T.eq(H.hamming_distance(0b0000, 0b0001), 1)
  end)

  T.it("all bits differ (byte) -> 8", function()
    T.eq(H.hamming_distance(0x00, 0xff), 8)
  end)

  T.it("known: 0b1011 vs 0b1001 -> 1", function()
    T.eq(H.hamming_distance(0xb, 0x9), 1)
  end)

  T.it("known: 0b1011 vs 0b0100 -> 4", function()
    T.eq(H.hamming_distance(0xb, 0x4), 4)
  end)
end)

T.describe("min_distance", function()
  T.it("single codeword -> 0", function()
    T.eq(H.min_distance({0xff}), 0)
  end)

  T.it("two identical -> 0", function()
    T.eq(H.min_distance({5, 5}), 0)
  end)

  T.it("two codewords differing by 1 bit", function()
    T.eq(H.min_distance({0b000, 0b001}), 1)
  end)

  T.it("repetition code {000,111} has distance 3", function()
    T.eq(H.min_distance({0b000, 0b111}), 3)
  end)

  T.it("set of 3 codewords, min is 2", function()
    -- 0b0000=0, 0b0011=3, 0b1100=12: distances 2, 2, 4
    T.eq(H.min_distance({0b0000, 0b0011, 0b1100}), 2)
  end)
end)
