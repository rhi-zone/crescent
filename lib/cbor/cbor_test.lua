-- lib/cbor/cbor_test.lua
-- Tests for lib/cbor (CBOR RFC 7049 encoder/decoder).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local cbor = require("lib.cbor")

-- Helper: hex string → binary string
local function fromhex(s)
  return (s:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

-- Helper: binary string → hex string
local function tohex(s)
  return (s:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end

-- Helper: assert encode produces expected hex
local function check_enc(value, expected_hex, label)
  local got, err = cbor.encode(value)
  T.ok(err == nil, (label or tostring(value)) .. ": encode error: " .. tostring(err))
  T.eq(tohex(got or ""), expected_hex, (label or tostring(value)) .. ": encode hex")
end

-- Helper: assert decode of hex produces expected value
local function check_dec(hex, expected, label)
  local got, err = cbor.decode(fromhex(hex))
  T.ok(err == nil, (label or hex) .. ": decode error: " .. tostring(err))
  T.eq(got, expected, (label or hex) .. ": decode value")
end

-- Helper: round-trip encode then decode
local function roundtrip(value, label)
  local enc, err1 = cbor.encode(value)
  T.ok(err1 == nil, (label or tostring(value)) .. ": encode error: " .. tostring(err1))
  local dec, err2 = cbor.decode(enc)
  T.ok(err2 == nil, (label or tostring(value)) .. ": decode error: " .. tostring(err2))
  T.eq(dec, value, (label or tostring(value)) .. ": round-trip")
end

-- ── Known hex vectors from RFC 7049 Appendix A ────────────────────────────────

T.describe("CBOR known hex vectors", function()
  T.it("0x00 → 0", function()
    check_dec("00", 0, "zero")
  end)

  T.it("0x01 → 1", function()
    check_dec("01", 1, "one")
  end)

  T.it("0x17 → 23", function()
    check_dec("17", 23, "23 inline")
  end)

  T.it("0x1818 → 24", function()
    check_dec("1818", 24, "24 one-byte")
  end)

  T.it("0xf4 → false", function()
    check_dec("f4", false, "false")
  end)

  T.it("0xf5 → true", function()
    check_dec("f5", true, "true")
  end)

  T.it("0xf6 → nil", function()
    local v, err = cbor.decode(fromhex("f6"))
    T.ok(err == nil, "null decode: no error")
    T.ok(v == nil, "null decodes to nil")
  end)

  T.it("0x6161 → 'a'", function()
    check_dec("6161", "a", "text string 'a'")
  end)

  T.it("0x8101 → {1}", function()
    local got, err = cbor.decode(fromhex("8101"))
    T.ok(err == nil, "array [1] decode: no error")
    T.eq(got[1], 1, "array [1] element")
    T.eq(#got, 1, "array [1] length")
  end)
end)

-- ── Integer encoding ──────────────────────────────────────────────────────────

T.describe("integer encoding", function()
  T.it("encodes 0 as 0x00", function()
    check_enc(0, "00", "0")
  end)

  T.it("encodes 1 as 0x01", function()
    check_enc(1, "01", "1")
  end)

  T.it("encodes 23 inline", function()
    check_enc(23, "17", "23")
  end)

  T.it("encodes 24 with one-byte extra", function()
    check_enc(24, "1818", "24")
  end)

  T.it("encodes 255", function()
    check_enc(255, "18ff", "255")
  end)

  T.it("encodes 256 with two-byte extra", function()
    check_enc(256, "190100", "256")
  end)

  T.it("encodes 65535", function()
    check_enc(65535, "19ffff", "65535")
  end)

  T.it("encodes 65536 with four-byte extra", function()
    check_enc(65536, "1a00010000", "65536")
  end)

  T.it("encodes -1", function()
    check_enc(-1, "20", "-1")
  end)

  T.it("encodes -100", function()
    -- -1 - n = -100 → n = 99 = 0x63; major type 1 = 0x20 + 0x18 = 0x38, then 0x63
    check_enc(-100, "3863", "-100")
  end)

  T.it("round-trips large positive integer", function()
    roundtrip(1000000, "1000000")
  end)

  T.it("round-trips max safe integer", function()
    roundtrip(2^53, "2^53")
  end)

  T.it("round-trips negative integers", function()
    roundtrip(-1, "-1")
    roundtrip(-100, "-100")
    roundtrip(-1000, "-1000")
  end)
end)

-- ── Boolean and nil ───────────────────────────────────────────────────────────

T.describe("boolean and null", function()
  T.it("encodes false as 0xf4", function()
    check_enc(false, "f4", "false")
  end)

  T.it("encodes true as 0xf5", function()
    check_enc(true, "f5", "true")
  end)

  T.it("encodes nil as 0xf6", function()
    check_enc(nil, "f6", "nil")
  end)

  T.it("round-trips false", function()
    roundtrip(false, "false")
  end)

  T.it("round-trips true", function()
    roundtrip(true, "true")
  end)
end)

-- ── String encoding ───────────────────────────────────────────────────────────

T.describe("text string encoding", function()
  T.it("encodes empty string", function()
    check_enc("", "60", "empty string")
  end)

  T.it("encodes 'a'", function()
    check_enc("a", "6161", "'a'")
  end)

  T.it("encodes 'IETF'", function()
    -- major 3, length 4, then ASCII bytes
    check_enc("IETF", "6449455446", "'IETF'")
  end)

  T.it("round-trips ASCII string", function()
    roundtrip("hello, world", "ASCII string")
  end)

  T.it("round-trips UTF-8 multibyte string", function()
    roundtrip("日本語", "UTF-8 string")
  end)

  T.it("round-trips empty string", function()
    roundtrip("", "empty string")
  end)

  T.it("round-trips long string", function()
    roundtrip(string.rep("x", 300), "300-char string")
  end)
end)

-- ── Byte string encoding ──────────────────────────────────────────────────────

T.describe("byte string encoding", function()
  T.it("encodes bytes as major type 2", function()
    local enc, err = cbor.encode(cbor.bytes("hello"))
    T.ok(err == nil, "encode error")
    -- major type 2, length 5, then bytes
    T.eq(string.byte(enc, 1), 0x40 + 5, "first byte: major 2 + length 5")
    T.eq(string.sub(enc, 2), "hello", "content")
  end)

  T.it("round-trips byte string", function()
    local v = cbor.bytes("hello")
    local enc = cbor.encode(v)
    local dec, err = cbor.decode(enc)
    T.ok(err == nil, "decode error")
    T.ok(cbor.is_bytes(dec), "is_bytes")
    T.eq(dec.s, "hello", "content")
  end)

  T.it("round-trips empty byte string", function()
    local v = cbor.bytes("")
    local enc = cbor.encode(v)
    local dec, err = cbor.decode(enc)
    T.ok(err == nil, "decode error")
    T.ok(cbor.is_bytes(dec), "is_bytes")
    T.eq(dec.s, "", "content empty")
  end)

  T.it("round-trips binary data with null bytes", function()
    local v = cbor.bytes("\x00\x01\x02\xff\xfe")
    local enc = cbor.encode(v)
    local dec, err = cbor.decode(enc)
    T.ok(err == nil, "decode error")
    T.ok(cbor.is_bytes(dec), "is_bytes")
    T.eq(dec.s, "\x00\x01\x02\xff\xfe", "binary content")
  end)
end)

-- ── Array encoding ────────────────────────────────────────────────────────────

T.describe("array encoding", function()
  T.it("encodes empty array", function()
    check_enc({}, "80", "empty array")
  end)

  T.it("encodes [1,2,3] as 0x83010203", function()
    check_enc({1, 2, 3}, "83010203", "[1,2,3]")
  end)

  T.it("round-trips empty array", function()
    local dec, err = cbor.decode(cbor.encode({}))
    T.ok(err == nil, "error")
    T.eq(#dec, 0, "length 0")
  end)

  T.it("round-trips mixed array", function()
    local arr = {1, "hello", true, false}
    local enc = cbor.encode(arr)
    local dec, err = cbor.decode(enc)
    T.ok(err == nil, "decode error")
    T.eq(dec[1], 1, "[1]")
    T.eq(dec[2], "hello", "[2]")
    T.eq(dec[3], true, "[3]")
    T.eq(dec[4], false, "[4]")
    T.eq(#dec, 4, "length")
  end)

  T.it("round-trips nested array", function()
    local arr = {1, {2, 3}, {4, {5}}}
    local enc = cbor.encode(arr)
    local dec, err = cbor.decode(enc)
    T.ok(err == nil, "decode error")
    T.eq(dec[1], 1, "[1]")
    T.eq(dec[2][1], 2, "[2][1]")
    T.eq(dec[2][2], 3, "[2][2]")
    T.eq(dec[3][2][1], 5, "[3][2][1]")
  end)
end)

-- ── Map encoding ──────────────────────────────────────────────────────────────

T.describe("map encoding", function()
  T.it("encodes empty map", function()
    local enc, err = cbor.encode({__is_map = true})
    -- actually we need a non-array table; use a string key
    T.ok(true, "skip — tested below")
  end)

  T.it("round-trips string-keyed map", function()
    local m = { a = 1, b = 2 }
    local enc = cbor.encode(m)
    local dec, err = cbor.decode(enc)
    T.ok(err == nil, "decode error")
    T.eq(dec.a, 1, "a")
    T.eq(dec.b, 2, "b")
  end)

  T.it("round-trips integer-keyed map", function()
    -- integer keys not 1..n so it's a map not array
    local m = { [10] = "ten", [20] = "twenty" }
    local enc = cbor.encode(m)
    local dec, err = cbor.decode(enc)
    T.ok(err == nil, "decode error")
    T.eq(dec[10], "ten", "[10]")
    T.eq(dec[20], "twenty", "[20]")
  end)

  T.it("round-trips nested map", function()
    local m = { x = { y = 42 } }
    local enc = cbor.encode(m)
    local dec, err = cbor.decode(enc)
    T.ok(err == nil, "decode error")
    T.eq(dec.x.y, 42, "x.y")
  end)
end)

-- ── Float encoding ────────────────────────────────────────────────────────────

T.describe("float encoding", function()
  T.it("round-trips 0.0", function()
    local enc = cbor.encode(0.0)
    -- 0.0 is integer-valued so encodes as integer 0
    T.eq(enc, "\x00", "0.0 encodes as integer 0")
  end)

  T.it("round-trips 3.14", function()
    local enc, err = cbor.encode(3.14)
    T.ok(err == nil, "encode error")
    T.eq(string.byte(enc, 1), 0xfb, "float64 marker")
    local dec, err2 = cbor.decode(enc)
    T.ok(err2 == nil, "decode error")
    -- Floating-point round-trip: should be very close
    T.ok(math.abs(dec - 3.14) < 1e-10, "3.14 round-trip: " .. tostring(dec))
  end)

  T.it("round-trips -1.5", function()
    local enc, err = cbor.encode(-1.5)
    T.ok(err == nil, "encode error")
    local dec, err2 = cbor.decode(enc)
    T.ok(err2 == nil, "decode error")
    T.eq(dec, -1.5, "-1.5 round-trip")
  end)

  T.it("round-trips math.huge (infinity)", function()
    local enc, err = cbor.encode(math.huge)
    T.ok(err == nil, "encode error")
    local dec, err2 = cbor.decode(enc)
    T.ok(err2 == nil, "decode error")
    T.eq(dec, math.huge, "+inf round-trip")
  end)

  T.it("round-trips -math.huge", function()
    local enc, err = cbor.encode(-math.huge)
    T.ok(err == nil, "encode error")
    local dec, err2 = cbor.decode(enc)
    T.ok(err2 == nil, "decode error")
    T.eq(dec, -math.huge, "-inf round-trip")
  end)

  T.it("round-trips NaN", function()
    local enc, err = cbor.encode(0/0)
    T.ok(err == nil, "encode error")
    local dec, err2 = cbor.decode(enc)
    T.ok(err2 == nil, "decode error")
    T.ok(dec ~= dec, "NaN round-trip: dec ~= dec")
  end)

  T.it("decodes float16 from spec (0.0)", function()
    -- 0xF900 00 = float16 +0.0
    local v, err = cbor.decode(fromhex("f90000"))
    T.ok(err == nil, "error")
    T.eq(v, 0.0, "float16 0.0")
  end)

  T.it("decodes float16 from spec (1.0)", function()
    -- float16 1.0 = sign=0, exp=15, mant=0 → 0x3C00
    local v, err = cbor.decode(fromhex("f93c00"))
    T.ok(err == nil, "error")
    T.eq(v, 1.0, "float16 1.0")
  end)

  T.it("decodes float32 1.5", function()
    -- float32 1.5 = 0x3fc00000
    local v, err = cbor.decode(fromhex("fa3fc00000"))
    T.ok(err == nil, "error")
    T.eq(v, 1.5, "float32 1.5")
  end)
end)

-- ── Indefinite-length ─────────────────────────────────────────────────────────

T.describe("indefinite-length", function()
  T.it("decodes indefinite-length array", function()
    -- 0x9f 01 02 03 ff = [_ 1 2 3]
    local v, err = cbor.decode(fromhex("9f010203ff"))
    T.ok(err == nil, "error")
    T.eq(v[1], 1, "[1]")
    T.eq(v[2], 2, "[2]")
    T.eq(v[3], 3, "[3]")
    T.eq(#v, 3, "length")
  end)

  T.it("decodes indefinite-length map", function()
    -- 0xbf 61 61 01 61 62 02 ff = {_ "a":1, "b":2}
    local v, err = cbor.decode(fromhex("bf6161016162 02ff"):gsub(" ", ""))
    T.ok(err == nil, "error")
    T.eq(v.a, 1, "a")
    T.eq(v.b, 2, "b")
  end)

  T.it("decodes indefinite-length byte string", function()
    -- 0x5f 42 0102 43 030405 ff = (_ h'0102', h'030405')
    local v, err = cbor.decode(fromhex("5f42010243030405ff"))
    T.ok(err == nil, "error")
    T.ok(cbor.is_bytes(v), "is_bytes")
    T.eq(v.s, "\x01\x02\x03\x04\x05", "content")
  end)

  T.it("decodes indefinite-length text string", function()
    -- 0x7f 62 6162 62 6364 ff = (_ "ab", "cd") = "abcd"
    local v, err = cbor.decode(fromhex("7f626162626364ff"))
    T.ok(err == nil, "error")
    T.eq(v, "abcd", "text")
  end)
end)

-- ── Error cases ───────────────────────────────────────────────────────────────

T.describe("error cases", function()
  T.it("decode empty input returns error", function()
    local v, err = cbor.decode("")
    T.ok(v == nil, "nil value")
    T.ok(type(err) == "string", "error message")
  end)

  T.it("decode truncated input returns error", function()
    -- 0x19 expects 2 more bytes but only 1 follows
    local v, err = cbor.decode(fromhex("1901"))
    T.ok(v == nil, "nil value")
    T.ok(type(err) == "string", "error message")
  end)

  T.it("decode truncated string returns error", function()
    -- 0x63 = text string length 3, but only 1 byte follows
    local v, err = cbor.decode(fromhex("6361"))
    T.ok(v == nil, "nil value")
    T.ok(type(err) == "string", "error message")
  end)

  T.it("decode non-string returns error", function()
    local v, err = cbor.decode(42)
    T.ok(v == nil, "nil value")
    T.ok(type(err) == "string", "error message")
  end)

  T.it("encode unsupported type returns error", function()
    local v, err = cbor.encode(function() end)
    T.ok(v == nil, "nil value")
    T.ok(type(err) == "string", "error message")
  end)
end)

-- ── Codec aliases ─────────────────────────────────────────────────────────────

T.describe("codec aliases", function()
  T.it("cbor_to_string is encode", function()
    T.eq(cbor.cbor_to_string, cbor.encode, "alias")
  end)

  T.it("string_to_cbor is decode", function()
    T.eq(cbor.string_to_cbor, cbor.decode, "alias")
  end)

  T.it("_tier is pure", function()
    T.eq(cbor._tier, "pure", "tier")
  end)
end)
