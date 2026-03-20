if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local utf8 = require("lib.encode.utf8")

T.describe("utf8.char", function()
  T.it("encodes ASCII", function()
    T.eq(utf8.char(65), "A")
    T.eq(utf8.char(0x7f), "\x7f")
  end)
  T.it("encodes 2-byte sequence", function()
    -- U+00E9 LATIN SMALL LETTER E WITH ACUTE: 0xC3 0xA9
    T.eq(utf8.char(0xe9), "\xc3\xa9")
  end)
  T.it("encodes 3-byte sequence", function()
    -- U+4E2D CJK: 0xE4 0xB8 0xAD
    T.eq(utf8.char(0x4e2d), "\xe4\xb8\xad")
  end)
  T.it("encodes 4-byte sequence", function()
    -- U+1F600 GRINNING FACE: 0xF0 0x9F 0x98 0x80
    T.eq(utf8.char(0x1f600), "\xf0\x9f\x98\x80")
  end)
  T.it("encodes multiple codepoints", function()
    T.eq(utf8.char(65, 66, 67), "ABC")
  end)
end)

T.describe("utf8.codepoint", function()
  T.it("decodes ASCII", function()
    T.eq(utf8.codepoint("A"), 65)
  end)
  T.it("decodes 2-byte sequence", function()
    T.eq(utf8.codepoint("\xc3\xa9"), 0xe9)
  end)
  T.it("decodes 3-byte sequence", function()
    T.eq(utf8.codepoint("\xe4\xb8\xad"), 0x4e2d)
  end)
  T.it("decodes 4-byte sequence", function()
    T.eq(utf8.codepoint("\xf0\x9f\x98\x80"), 0x1f600)
  end)
  T.it("decodes range of codepoints", function()
    local a, b = utf8.codepoint("AB", 1, 2)
    T.eq(a, 65)
    T.eq(b, 66)
  end)
  T.it("returns nil, err for invalid sequence (continuation byte at start)", function()
    local v, err = utf8.codepoint("\x80")
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)
  T.it("returns nil, err for invalid lead byte mid-string", function()
    -- 0xFF is not a valid UTF-8 lead byte
    local v, err = utf8.codepoint("\xff")
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)
end)

T.describe("utf8.codes", function()
  T.it("iterates ASCII string", function()
    local positions, cps = {}, {}
    for p, c in utf8.codes("ABC") do
      positions[#positions+1] = p
      cps[#cps+1] = c
    end
    T.eq(#positions, 3)
    T.eq(positions[1], 1); T.eq(positions[2], 2); T.eq(positions[3], 3)
    T.eq(cps[1], 65); T.eq(cps[2], 66); T.eq(cps[3], 67)
  end)
  T.it("iterates mixed ASCII and multi-byte", function()
    -- "A" + U+00E9 + "Z"
    local s = "A\xc3\xa9Z"
    local positions, cps = {}, {}
    for p, c in utf8.codes(s) do
      positions[#positions+1] = p
      cps[#cps+1] = c
    end
    T.eq(#positions, 3)
    T.eq(positions[1], 1); T.eq(positions[2], 2); T.eq(positions[3], 4)
    T.eq(cps[1], 65); T.eq(cps[2], 0xe9); T.eq(cps[3], 90)
  end)
  T.it("iterates 3-byte character", function()
    local s = "\xe4\xb8\xad"
    local count = 0
    local got_cp
    for _, c in utf8.codes(s) do
      count = count + 1
      got_cp = c
    end
    T.eq(count, 1)
    T.eq(got_cp, 0x4e2d)
  end)
  T.it("iterates 4-byte character", function()
    local s = "\xf0\x9f\x98\x80"
    local count = 0
    local got_cp
    for _, c in utf8.codes(s) do
      count = count + 1
      got_cp = c
    end
    T.eq(count, 1)
    T.eq(got_cp, 0x1f600)
  end)
  T.it("stops on invalid byte (no throw)", function()
    -- iterator must not throw on invalid input
    local ok, err = pcall(function()
      for _ in utf8.codes("\xff\x80") do end
    end)
    T.ok(ok, err)
  end)
  T.it("empty string produces no iterations", function()
    local count = 0
    for _ in utf8.codes("") do count = count + 1 end
    T.eq(count, 0)
  end)
end)

T.describe("utf8.len", function()
  T.it("counts ASCII characters", function()
    T.eq(utf8.len("ABC"), 3)
  end)
  T.it("counts multi-byte characters", function()
    T.eq(utf8.len("A\xc3\xa9Z"), 3)
    T.eq(utf8.len("\xe4\xb8\xad"), 1)
    T.eq(utf8.len("\xf0\x9f\x98\x80"), 1)
  end)
  T.it("returns 0 for empty string", function()
    T.eq(utf8.len(""), 0)
  end)
  T.it("returns nil, pos for invalid sequence", function()
    local v, pos = utf8.len("\x80")
    T.eq(v, nil)
    T.ok(pos ~= nil)
  end)
end)

T.describe("utf8.is_valid", function()
  T.it("accepts valid ASCII", function()
    T.ok(utf8.is_valid("hello"))
  end)
  T.it("accepts valid 2-byte sequences", function()
    T.ok(utf8.is_valid("\xc3\xa9"))
  end)
  T.it("accepts valid 3-byte sequences", function()
    T.ok(utf8.is_valid("\xe4\xb8\xad"))
  end)
  T.it("accepts valid 4-byte sequences", function()
    T.ok(utf8.is_valid("\xf0\x9f\x98\x80"))
  end)
  T.it("rejects lone continuation byte", function()
    T.ok(not utf8.is_valid("\x80"))
  end)
  T.it("rejects truncated 2-byte sequence", function()
    T.ok(not utf8.is_valid("\xc3"))
  end)
  T.it("rejects overlong sequence lead byte 0xFF", function()
    T.ok(not utf8.is_valid("\xff"))
  end)
  T.it("accepts UTF-8 BOM prefix", function()
    T.ok(utf8.is_valid("\xef\xbb\xbfhello"))
  end)
end)

T.describe("utf8 round-trip", function()
  T.it("char/codepoint round-trips 2-byte", function()
    local encoded = utf8.char(0xe9)
    T.eq(utf8.codepoint(encoded), 0xe9)
  end)
  T.it("char/codepoint round-trips 3-byte", function()
    local encoded = utf8.char(0x4e2d)
    T.eq(utf8.codepoint(encoded), 0x4e2d)
  end)
  T.it("char/codepoint round-trips 4-byte", function()
    local encoded = utf8.char(0x1f600)
    T.eq(utf8.codepoint(encoded), 0x1f600)
  end)
end)
