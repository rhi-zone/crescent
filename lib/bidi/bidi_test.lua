if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local bidi = require("lib.bidi")
local utf8 = require("lib.encode.utf8")

-- Hebrew letters (all R, block U+0590-U+05FF).
local ALEF = 0x05D0
local BET = 0x05D1
local GIMEL = 0x05D2

--: ({ [integer]: integer }) -> string
local function cps_to_hex(cps)
  local parts = {}
  for i = 1, #cps do parts[i] = string.format("%X", cps[i]) end
  return table.concat(parts, ",")
end

--: (string) -> { [integer]: integer }
local function string_to_cps(s)
  local cps = {}
  for _, cp in utf8.codes(s) do
    if cp then cps[#cps + 1] = cp end
  end
  return cps
end

--: (string, string, { base_level?: integer } | nil) -> nil
local function assert_visual_hex(text, expected_hex, opts)
  local result, rerr = bidi.resolve(text, opts)
  T.ok(result, rerr)
  local visual, verr = bidi.reorder(text, result.levels)
  T.ok(visual, verr)
  T.eq(cps_to_hex(string_to_cps(visual)), expected_hex)
end

T.describe("bidi.char_type", function()
  T.it("classifies ASCII letters as L", function()
    T.eq(bidi.char_type(65), "L") -- 'A'
    T.eq(bidi.char_type(122), "L") -- 'z'
  end)
  T.it("classifies ASCII digits as EN", function()
    T.eq(bidi.char_type(48), "EN") -- '0'
  end)
  T.it("classifies space as WS", function()
    T.eq(bidi.char_type(0x20), "WS")
  end)
  T.it("classifies ASCII punctuation as ON", function()
    T.eq(bidi.char_type(0x21), "ON") -- '!'
  end)
  T.it("classifies Hebrew letters as R", function()
    T.eq(bidi.char_type(ALEF), "R")
  end)
  T.it("classifies Arabic letters as AL", function()
    T.eq(bidi.char_type(0x0628), "AL") -- BEH
  end)
  T.it("classifies Arabic-Indic digits as AN", function()
    T.eq(bidi.char_type(0x0661), "AN") -- ARABIC-INDIC DIGIT ONE
  end)
  T.it("classifies explicit bidi controls", function()
    T.eq(bidi.char_type(0x202A), "LRE")
    T.eq(bidi.char_type(0x202B), "RLE")
    T.eq(bidi.char_type(0x202C), "PDF")
    T.eq(bidi.char_type(0x202D), "LRO")
    T.eq(bidi.char_type(0x202E), "RLO")
    T.eq(bidi.char_type(0x2066), "LRI")
    T.eq(bidi.char_type(0x2067), "RLI")
    T.eq(bidi.char_type(0x2068), "FSI")
    T.eq(bidi.char_type(0x2069), "PDI")
  end)
  T.it("defaults unknown codepoints to L", function()
    T.eq(bidi.char_type(0x3042), "L") -- HIRAGANA A, outside the bounded table
  end)
  T.it("rejects invalid codepoints", function()
    local t, err = bidi.char_type(-1)
    T.eq(t, nil)
    T.ok(err)
  end)
end)

T.describe("bidi.resolve / bidi.reorder: pure LTR", function()
  T.it("keeps LTR text in logical order with level 0", function()
    local result = bidi.resolve("hello")
    T.eq(result.paragraph_level, 0)
    for i = 1, #result.levels do T.eq(result.levels[i], 0) end
    assert_visual_hex("hello", cps_to_hex(string_to_cps("hello")))
  end)
end)

T.describe("bidi.resolve / bidi.reorder: pure RTL", function()
  T.it("resolves Hebrew text to level 1 and reverses visual order", function()
    local text = utf8.char(ALEF, BET, GIMEL)
    local result = bidi.resolve(text)
    T.eq(result.paragraph_level, 1)
    T.eq(result.levels[1], 1)
    T.eq(result.levels[2], 1)
    T.eq(result.levels[3], 1)
    assert_visual_hex(text, cps_to_hex({ GIMEL, BET, ALEF }))
  end)
end)

T.describe("bidi.resolve / bidi.reorder: mixed LTR/RTL", function()
  T.it("keeps the RTL run internally reversed inside an LTR paragraph", function()
    local text = "abc" .. utf8.char(ALEF, BET, GIMEL) .. "def"
    local result = bidi.resolve(text)
    T.eq(result.paragraph_level, 0)
    -- "abc" and "def" stay at level 0; the Hebrew run is bumped to level 1.
    T.eq(result.levels[1], 0)
    T.eq(result.levels[4], 1)
    T.eq(result.levels[6], 1)
    T.eq(result.levels[7], 0)
    local a, b, c = 0x61, 0x62, 0x63
    local d, e, f = 0x64, 0x65, 0x66
    assert_visual_hex(text, cps_to_hex({ a, b, c, GIMEL, BET, ALEF, d, e, f }))
  end)
end)

T.describe("bidi.resolve / bidi.reorder: numbers in RTL context", function()
  T.it("keeps digits in ascending reading order inside RTL text", function()
    local text = utf8.char(ALEF, BET) .. "123" .. utf8.char(GIMEL)
    local result = bidi.resolve(text)
    T.eq(result.paragraph_level, 1)
    T.eq(result.types[3], "EN")
    T.eq(result.types[4], "EN")
    T.eq(result.types[5], "EN")
    -- digits get level para+1 (EN bumps by 2 from an even seq level, or by
    -- 1 from odd — here seq level 1 (odd) -> digits at level 2).
    T.eq(result.levels[3], 2)
    T.eq(result.levels[4], 2)
    T.eq(result.levels[5], 2)
    local one, two, three = 0x31, 0x32, 0x33
    assert_visual_hex(text, cps_to_hex({ GIMEL, one, two, three, BET, ALEF }))
  end)
end)

T.describe("bidi.resolve / bidi.reorder: explicit embedding controls", function()
  T.it("RLE...PDF embeds an RTL run inside LTR text", function()
    local text = "ab" .. utf8.char(0x202B, ALEF, BET, 0x202C) .. "cd"
    local result = bidi.resolve(text)
    T.eq(result.paragraph_level, 0)
    T.eq(result.types[3], "RLE")
    T.eq(result.types[6], "PDF")
    T.eq(result.levels[1], 0) -- 'a'
    T.eq(result.levels[2], 0) -- 'b'
    T.eq(result.levels[4], 1) -- ALEF, pushed to next odd level
    T.eq(result.levels[5], 1) -- BET
    T.eq(result.levels[7], 0) -- 'c'
    T.eq(result.levels[8], 0) -- 'd'
    local a, b, c, d = 0x61, 0x62, 0x63, 0x64
    assert_visual_hex(text, cps_to_hex({ a, b, 0x202B, 0x202C, BET, ALEF, c, d }))
  end)

  T.it("LRO forces override to L even for Hebrew (affects resolved level)", function()
    -- result.types reports each character's ORIGINAL classification (R for
    -- Hebrew, unaffected by override) — overrides act on level resolution,
    -- not on the reported type. LRO pushes level 2 (next even level above
    -- para level 1) and overrides enclosed characters to behave as L; L at
    -- an even level does not bump per I1, so the level stays 2.
    local text = utf8.char(0x202D, ALEF, BET, 0x202C) -- LRO ... PDF
    local result = bidi.resolve(text)
    T.eq(result.types[2], "R")
    T.eq(result.levels[2], 2)
    T.eq(result.levels[3], 2)

    -- Contrast: LRE (no override) leaves R as R, which DOES bump by I1 at
    -- the even embedding level, landing one level higher.
    local text2 = utf8.char(0x202A, ALEF, BET, 0x202C) -- LRE ... PDF
    local result2 = bidi.resolve(text2)
    T.eq(result2.levels[2], 3)
    T.eq(result2.levels[3], 3)
  end)

  T.it("RLI...PDI isolates an RTL run without leaking direction", function()
    local text = "a" .. utf8.char(0x2067, ALEF, BET, 0x2069) .. "b"
    local result = bidi.resolve(text)
    T.eq(result.paragraph_level, 0)
    T.eq(result.types[2], "RLI")
    T.eq(result.types[5], "PDI")
  end)
end)

T.describe("bidi.resolve / bidi.reorder: punctuation between RTL and LTR", function()
  T.it("resolves neutral punctuation via surrounding strong context", function()
    -- Hebrew + '!' + Latin, natural (Hebrew-first) paragraph direction.
    local text = utf8.char(ALEF, BET) .. "!ab"
    local result = bidi.resolve(text)
    T.eq(result.paragraph_level, 1)
    T.eq(result.types[3], "ON")
    local a, b, bang = 0x61, 0x62, 0x21
    assert_visual_hex(text, cps_to_hex({ a, b, bang, BET, ALEF }))
  end)

  T.it("same text under a forced LTR base level reorders differently", function()
    local text = utf8.char(ALEF, BET) .. "!ab"
    local result = bidi.resolve(text, { base_level = 0 })
    T.eq(result.paragraph_level, 0)
    local a, b, bang = 0x61, 0x62, 0x21
    assert_visual_hex(text, cps_to_hex({ BET, ALEF, bang, a, b }), { base_level = 0 })
  end)
end)

T.describe("bidi.text_to_visual_order", function()
  T.it("composes resolve and reorder", function()
    local visual, err = bidi.text_to_visual_order(utf8.char(ALEF, BET, GIMEL))
    T.ok(visual, err)
    T.eq(cps_to_hex(string_to_cps(visual)), cps_to_hex({ GIMEL, BET, ALEF }))
  end)
end)

T.describe("bidi.resolve: error handling", function()
  T.it("rejects invalid UTF-8", function()
    local result, err = bidi.resolve("\xff\xfe")
    T.eq(result, nil)
    T.ok(err)
  end)
end)
