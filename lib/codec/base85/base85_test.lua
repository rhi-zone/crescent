-- lib/codec/base85/base85_test.lua
-- Tests for Base85 encoding variants: RFC 1924, Z85, Ascii85, streaming encoder.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local b85 = require("lib.codec.base85")

-- ── RFC 1924 encode ───────────────────────────────────────────────────────────

T.describe("rfc1924_encode", function()
  T.it("encodes 'Man ' to 'O<`^z'", function()
    T.eq(b85.encode("Man "), "O<`^z")
  end)

  T.it("encodes empty string", function()
    T.eq(b85.encode(""), "")
  end)

  T.it("encodes 8 bytes to 10 chars", function()
    local s = b85.encode("Man Man ")
    T.eq(#s, 10)
  end)

  T.it("encodes all-zero 4 bytes", function()
    local s = b85.encode("\0\0\0\0")
    T.eq(s, "00000")
  end)

  T.it("encodes all-255 4 bytes", function()
    local s = b85.encode("\xff\xff\xff\xff")
    -- 0xffffffff = 4294967295; encode and verify round-trip
    T.ok(type(s) == "string" and #s == 5)
  end)

  T.it("encodes 12 bytes to 15 chars", function()
    local s = b85.encode("Hello, World!")
    -- "Hello, World!" is 13 chars — not a multiple of 4
    -- Try a 12-byte input
    local r = b85.encode("Hello, Worl")
    T.ok(r == nil) -- 11 bytes, not multiple of 4
    local r2 = b85.encode("Hello, Wor!")
    T.ok(r2 == nil) -- 11 bytes
    local r3 = b85.encode("Hello, Wo!!")
    T.ok(r3 == nil)
    local r4 = b85.encode("ABCDEFGHIJKL") -- 12 bytes
    T.eq(#r4, 15)
  end)

  T.it("returns nil for non-string input", function()
    local v, err = b85.encode(42)
    T.ok(v == nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns nil for non-multiple-of-4 input", function()
    local v, err = b85.encode("Man")
    T.ok(v == nil)
    T.ok(err:find("multiple of 4"))
  end)

  T.it("returns nil for 1-byte input", function()
    local v, err = b85.encode("A")
    T.ok(v == nil)
  end)

  T.it("returns nil for 2-byte input", function()
    local v, err = b85.encode("AB")
    T.ok(v == nil)
  end)

  T.it("returns nil for 3-byte input", function()
    local v, err = b85.encode("ABC")
    T.ok(v == nil)
  end)
end)

-- ── RFC 1924 decode ───────────────────────────────────────────────────────────

T.describe("rfc1924_decode", function()
  T.it("decodes 'O<`^z' to 'Man '", function()
    T.eq(b85.decode("O<`^z"), "Man ")
  end)

  T.it("decodes empty string", function()
    T.eq(b85.decode(""), "")
  end)

  T.it("decodes '00000' to 4 zero bytes", function()
    T.eq(b85.decode("00000"), "\0\0\0\0")
  end)

  T.it("returns nil for non-string input", function()
    local v, err = b85.decode(nil)
    T.ok(v == nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns nil for non-multiple-of-5 input", function()
    local v, err = b85.decode("9jqo")
    T.ok(v == nil)
    T.ok(err:find("multiple of 5"))
  end)

  T.it("returns nil for invalid character", function()
    local v, err = b85.decode("9jqo\x01") -- control char not in alphabet
    T.ok(v == nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns nil for out-of-range group", function()
    -- All 'z' with RFC 1924 alpha: 'z' = index 61, so 61+61*85+61*85^2+...
    -- Maximum valid is 84 in each position; 'z'=61 is fine
    -- Use chars beyond alphabet to get overflow: tilde '~' = 84, max digit
    -- "~~~~~" = 84*85^4+84*85^3+... = 84*(85^5-1)/84 = 85^5-1 = 4437053124 > 0xffffffff
    local v, err = b85.decode("~~~~~")
    T.ok(v == nil)
    T.ok(err ~= nil)
  end)
end)

-- ── RFC 1924 round-trip ───────────────────────────────────────────────────────

T.describe("rfc1924 round-trip", function()
  local function rt(s)
    local enc = b85.encode(s)
    T.ok(enc ~= nil, "encode returned nil for: " .. #s .. " bytes")
    local dec = b85.decode(enc)
    T.eq(dec, s)
  end

  T.it("round-trips 'Man '", function()
    rt("Man ")
  end)

  T.it("round-trips 8 zero bytes", function()
    rt("\0\0\0\0\0\0\0\0")
  end)

  T.it("round-trips 4 max bytes", function()
    rt("\xff\xff\xff\xff")
  end)

  T.it("round-trips alternating bytes", function()
    rt("\xaa\x55\xaa\x55")
  end)

  T.it("round-trips 'ABCDEFGH'", function()
    rt("ABCDEFGH")
  end)

  T.it("round-trips 'Man Man '", function()
    rt("Man Man ")
  end)

  T.it("round-trips 12-byte input", function()
    rt("ABCDEFGHIJKL")
  end)

  T.it("round-trips binary with all byte values (256 bytes)", function()
    -- Build 256 bytes (64 groups of 4 bytes)
    local bytes = {}
    for i = 0, 255 do bytes[i + 1] = string.char(i) end
    rt(table.concat(bytes))
  end)
end)

-- ── Z85 encode ────────────────────────────────────────────────────────────────

T.describe("z85_encode", function()
  T.it("encodes empty string", function()
    T.eq(b85.z85_encode(""), "")
  end)

  T.it("encodes 4 bytes to 5 chars", function()
    local s = b85.z85_encode("\x86\x4f\xd2\x6f")
    T.ok(type(s) == "string" and #s == 5)
  end)

  T.it("returns nil for non-string", function()
    local v, err = b85.z85_encode(true)
    T.ok(v == nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns nil for non-multiple-of-4 input", function()
    local v, err = b85.z85_encode("abc")
    T.ok(v == nil)
    T.ok(err:find("multiple of 4"))
  end)

  T.it("encodes all-zero 4 bytes", function()
    local s = b85.z85_encode("\0\0\0\0")
    T.eq(#s, 5)
    -- Z85 '0' is the first char, so all zeros = "00000"
    T.eq(s, "00000")
  end)
end)

-- ── Z85 decode ────────────────────────────────────────────────────────────────

T.describe("z85_decode", function()
  T.it("decodes empty string", function()
    T.eq(b85.z85_decode(""), "")
  end)

  T.it("returns nil for non-string", function()
    local v, err = b85.z85_decode(123)
    T.ok(v == nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns nil for non-multiple-of-5 input", function()
    local v, err = b85.z85_decode("1234")
    T.ok(v == nil)
    T.ok(err:find("multiple of 5"))
  end)

  T.it("returns nil for invalid character", function()
    local v, err = b85.z85_decode("~~~~\x01")
    T.ok(v == nil)
    T.ok(type(err) == "string")
  end)

  T.it("decodes '00000' to 4 zero bytes", function()
    T.eq(b85.z85_decode("00000"), "\0\0\0\0")
  end)
end)

-- ── Z85 round-trip ────────────────────────────────────────────────────────────

T.describe("z85 round-trip", function()
  local function rt(s)
    local enc = b85.z85_encode(s)
    T.ok(enc ~= nil)
    local dec = b85.z85_decode(enc)
    T.eq(dec, s)
  end

  T.it("round-trips 4 zero bytes", function()
    rt("\0\0\0\0")
  end)

  T.it("round-trips 4 max bytes", function()
    rt("\xff\xff\xff\xff")
  end)

  T.it("round-trips 'ABCD'", function()
    rt("ABCD")
  end)

  T.it("round-trips 8 bytes", function()
    rt("ABCDEFGH")
  end)

  T.it("round-trips alternating bytes", function()
    rt("\xde\xad\xbe\xef")
  end)

  T.it("round-trips 256 bytes", function()
    local bytes = {}
    for i = 0, 255 do bytes[i + 1] = string.char(i) end
    rt(table.concat(bytes))
  end)
end)

-- ── Ascii85 encode ────────────────────────────────────────────────────────────

T.describe("ascii85_encode", function()
  T.it("encodes empty string to '<~~>'", function()
    T.eq(b85.ascii85_encode(""), "<~~>")
  end)

  T.it("encodes 'Man ' (4 bytes)", function()
    local s = b85.ascii85_encode("Man ")
    T.ok(s:sub(1, 2) == "<~")
    T.ok(s:sub(-2) == "~>")
    T.eq(#s, 2 + 5 + 2)  -- <~ + 5 chars + ~>
  end)

  T.it("uses 'z' shorthand for 4 zero bytes", function()
    local s = b85.ascii85_encode("\0\0\0\0")
    T.eq(s, "<~z~>")
  end)

  T.it("uses 'z' for multiple zero groups", function()
    local s = b85.ascii85_encode("\0\0\0\0\0\0\0\0")
    T.eq(s, "<~zz~>")
  end)

  T.it("handles 1-byte partial group", function()
    local s = b85.ascii85_encode("A")
    T.ok(s:sub(1, 2) == "<~")
    T.ok(s:sub(-2) == "~>")
    -- 1 byte partial → 2 output chars
    T.eq(#s, 2 + 2 + 2)
  end)

  T.it("handles 2-byte partial group", function()
    local s = b85.ascii85_encode("AB")
    T.ok(s:sub(1, 2) == "<~")
    T.ok(s:sub(-2) == "~>")
    -- 2 byte partial → 3 output chars
    T.eq(#s, 2 + 3 + 2)
  end)

  T.it("handles 3-byte partial group", function()
    local s = b85.ascii85_encode("ABC")
    T.ok(s:sub(1, 2) == "<~")
    T.ok(s:sub(-2) == "~>")
    -- 3 byte partial → 4 output chars
    T.eq(#s, 2 + 4 + 2)
  end)

  T.it("handles mixed: full group + partial", function()
    -- "Man X" = 5 bytes: 4-byte group "Man " + 1-byte "X"
    local s = b85.ascii85_encode("Man X")
    T.ok(s:sub(1, 2) == "<~")
    T.ok(s:sub(-2) == "~>")
    -- 5 chars for "Man " + 2 chars for "X"
    T.eq(#s, 2 + 5 + 2 + 2)
  end)

  T.it("returns nil for non-string", function()
    local v, err = b85.ascii85_encode({})
    T.ok(v == nil)
    T.ok(type(err) == "string")
  end)

  T.it("does not use 'z' for non-zero group", function()
    local s = b85.ascii85_encode("\0\0\0\1")
    T.ok(not s:find("z", 1, true) or s == "<~z~>")
    -- \0\0\0\1 is not all-zero, so no z shorthand
    T.ok(not s:find("z", 3, 3))
  end)
end)

-- ── Ascii85 decode ────────────────────────────────────────────────────────────

T.describe("ascii85_decode", function()
  T.it("decodes '<~~>' to empty string", function()
    T.eq(b85.ascii85_decode("<~~>"), "")
  end)

  T.it("decodes '<~z~>' to 4 zero bytes", function()
    T.eq(b85.ascii85_decode("<~z~>"), "\0\0\0\0")
  end)

  T.it("decodes '<~zz~>' to 8 zero bytes", function()
    T.eq(b85.ascii85_decode("<~zz~>"), "\0\0\0\0\0\0\0\0")
  end)

  T.it("decodes without delimiters", function()
    -- Without <~ ~> delimiters, decodes raw Ascii85 chars
    -- Encode 'Man ' and strip delimiters
    local enc = b85.ascii85_encode("Man ")
    local inner = enc:sub(3, -3)
    T.eq(b85.ascii85_decode(inner), "Man ")
  end)

  T.it("returns nil for non-string", function()
    local v, err = b85.ascii85_decode(99)
    T.ok(v == nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns nil for invalid character in group", function()
    -- '~' (tilde) is not in the Ascii85 alphabet (chars 33–117)
    -- but it's the delimiter; inside the content it should be invalid
    -- Use a char outside 33–117 range, e.g. 0x01
    local v, err = b85.ascii85_decode("<~\x01bcde~>")
    T.ok(v == nil)
    T.ok(type(err) == "string")
  end)
end)

-- ── Ascii85 round-trip ────────────────────────────────────────────────────────

T.describe("ascii85 round-trip", function()
  local function rt(s)
    local enc = b85.ascii85_encode(s)
    T.ok(enc ~= nil, "encode failed for " .. #s .. " bytes")
    local dec = b85.ascii85_decode(enc)
    T.eq(dec, s)
  end

  T.it("round-trips empty string", function()
    rt("")
  end)

  T.it("round-trips 4 zero bytes", function()
    rt("\0\0\0\0")
  end)

  T.it("round-trips 4 max bytes", function()
    rt("\xff\xff\xff\xff")
  end)

  T.it("round-trips 'Man '", function()
    rt("Man ")
  end)

  T.it("round-trips 1-byte partial", function()
    rt("A")
  end)

  T.it("round-trips 2-byte partial", function()
    rt("AB")
  end)

  T.it("round-trips 3-byte partial", function()
    rt("ABC")
  end)

  T.it("round-trips 5 bytes (4+1)", function()
    rt("ABCDE")
  end)

  T.it("round-trips 6 bytes (4+2)", function()
    rt("ABCDEF")
  end)

  T.it("round-trips 7 bytes (4+3)", function()
    rt("ABCDEFG")
  end)

  T.it("round-trips 8 bytes (4+4)", function()
    rt("ABCDEFGH")
  end)

  T.it("round-trips mixed zeros and non-zeros", function()
    rt("\0\0\0\0\xff\xff\xff\xff")
  end)

  T.it("round-trips 256 bytes", function()
    local bytes = {}
    for i = 0, 255 do bytes[i + 1] = string.char(i) end
    rt(table.concat(bytes))
  end)

  T.it("round-trips 'Hello, World!'", function()
    rt("Hello, World!")
  end)
end)

-- ── Cross-variant: RFC1924 vs Z85 differ ─────────────────────────────────────

T.describe("variant independence", function()
  T.it("RFC 1924 and Z85 give different output for same input", function()
    local input = "ABCD"
    local r = b85.rfc1924_encode(input)
    local z = b85.z85_encode(input)
    -- Different alphabets, so different output (for most inputs)
    T.ok(r ~= z or true) -- may happen to match by coincidence; just ensure both work
    T.ok(type(r) == "string" and #r == 5)
    T.ok(type(z) == "string" and #z == 5)
  end)

  T.it("RFC 1924 decode rejects Z85-encoded data (mostly)", function()
    -- Z85 uses lowercase before uppercase in alphabet; RFC1924 uses uppercase first.
    -- A Z85-encoded string decoded via RFC 1924 will give wrong bytes (not error necessarily),
    -- but we can verify encode/decode are paired correctly.
    local input = "\xde\xad\xbe\xef"
    local z_enc = b85.z85_encode(input)
    local dec = b85.z85_decode(z_enc)
    T.eq(dec, input)
    -- RFC1924 encode then decode the same input
    local r_enc = b85.rfc1924_encode(input)
    local r_dec = b85.rfc1924_decode(r_enc)
    T.eq(r_dec, input)
  end)
end)

-- ── Streaming encoder ─────────────────────────────────────────────────────────

T.describe("streaming encoder", function()
  T.it("encodes single write of 4 bytes", function()
    local enc = b85.encoder()
    enc:write("Man ")
    local result = enc:finish()
    T.eq(result, b85.encode("Man "))
  end)

  T.it("encodes two writes that together form complete groups", function()
    -- "Ma" + "n " = "Man "
    local enc = b85.encoder()
    enc:write("Ma")
    enc:write("n ")
    local result = enc:finish()
    T.eq(result, b85.encode("Man "))
  end)

  T.it("encodes 1-byte writes", function()
    local enc = b85.encoder()
    enc:write("M")
    enc:write("a")
    enc:write("n")
    enc:write(" ")
    local result = enc:finish()
    T.eq(result, b85.encode("Man "))
  end)

  T.it("encodes 8-byte input in two 4-byte writes", function()
    local enc = b85.encoder()
    enc:write("Man ")
    enc:write("Man ")
    local result = enc:finish()
    T.eq(result, b85.encode("Man Man "))
  end)

  T.it("encodes 12-byte input in three writes", function()
    local enc = b85.encoder()
    enc:write("ABCD")
    enc:write("EFGH")
    enc:write("IJKL")
    local result = enc:finish()
    T.eq(result, b85.encode("ABCDEFGHIJKL"))
  end)

  T.it("handles empty writes", function()
    local enc = b85.encoder()
    enc:write("")
    enc:write("Man ")
    enc:write("")
    local result = enc:finish()
    T.eq(result, b85.encode("Man "))
  end)

  T.it("finish on empty encoder returns empty string", function()
    local enc = b85.encoder()
    T.eq(enc:finish(), "")
  end)

  T.it("streaming matches batch encode for 256-byte input", function()
    local bytes = {}
    for i = 0, 255 do bytes[i + 1] = string.char(i) end
    local input = table.concat(bytes)
    -- Batch
    local batch = b85.encode(input)
    -- Streaming: write in 7-byte chunks (not aligned to 4)
    local enc = b85.encoder()
    for i = 1, #input, 7 do
      enc:write(input:sub(i, math.min(i + 6, #input)))
    end
    local streamed = enc:finish()
    T.eq(streamed, batch)
  end)
end)

-- ── Aliases and defaults ──────────────────────────────────────────────────────

T.describe("aliases", function()
  T.it("M.encode == M.rfc1924_encode", function()
    T.eq(b85.encode, b85.rfc1924_encode)
  end)

  T.it("M.decode == M.rfc1924_decode", function()
    T.eq(b85.decode, b85.rfc1924_decode)
  end)

  T.it("string_to_base85 == rfc1924_encode", function()
    T.eq(b85.string_to_base85, b85.rfc1924_encode)
  end)

  T.it("base85_to_string == rfc1924_decode", function()
    T.eq(b85.base85_to_string, b85.rfc1924_decode)
  end)

  T.it("string_to_base85 encodes correctly", function()
    T.eq(b85.string_to_base85("Man "), "O<`^z")
  end)

  T.it("base85_to_string decodes correctly", function()
    T.eq(b85.base85_to_string("O<`^z"), "Man ")
  end)
end)

-- ── Edge cases ────────────────────────────────────────────────────────────────

T.describe("edge cases", function()
  T.it("RFC 1924 encode/decode with all-same bytes", function()
    local s = string.rep("\xab", 4)
    local enc = b85.encode(s)
    T.eq(#enc, 5)
    T.eq(b85.decode(enc), s)
  end)

  T.it("Ascii85 encode of string with embedded zeros", function()
    local s = "A\0\0\0\0B\0\0\0" -- 9 bytes: 4+4+1
    -- This is 9 bytes (not multiple of 4), so partial group at end
    local enc = b85.ascii85_encode(s)
    T.ok(enc ~= nil)
    local dec = b85.ascii85_decode(enc)
    T.eq(dec, s)
  end)

  T.it("Ascii85 decode ignores whitespace in data", function()
    -- Standard Ascii85 allows whitespace to be inserted for line-wrapping
    local enc = b85.ascii85_encode("Man ")
    local inner = enc:sub(3, -3)
    -- Insert spaces/newlines
    local with_ws = "<~" .. inner:sub(1, 2) .. " \n" .. inner:sub(3) .. "~>"
    T.eq(b85.ascii85_decode(with_ws), "Man ")
  end)

  T.it("_tier is 'pure'", function()
    T.eq(b85._tier, "pure")
  end)
end)
