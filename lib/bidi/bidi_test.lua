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

-- Arabic letters (all AL, block U+0600-U+06FF).
local BEH = 0x0628
local TEH = 0x062A
local SEEN = 0x0633

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

--: (string, string, { base_direction?: string } | nil) -> nil
local function assert_visual_hex(text, expected_hex, opts)
  local result, rerr = bidi.resolve_levels(text, opts)
  T.ok(result, rerr)
  local visual, verr = bidi.reorder(text, result.levels)
  T.ok(visual, verr)
  T.eq(cps_to_hex(string_to_cps(visual)), expected_hex)
end

-- ================================================================
-- classify_codepoint
-- ================================================================

T.describe("bidi.classify_codepoint", function()
  T.it("classifies ASCII letters as L", function()
    T.eq(bidi.classify_codepoint(65), "L") -- 'A'
    T.eq(bidi.classify_codepoint(122), "L") -- 'z'
  end)
  T.it("classifies ASCII digits as EN", function()
    T.eq(bidi.classify_codepoint(48), "EN") -- '0'
  end)
  T.it("classifies space as WS", function()
    T.eq(bidi.classify_codepoint(0x20), "WS")
  end)
  T.it("classifies ASCII punctuation as ON", function()
    T.eq(bidi.classify_codepoint(0x21), "ON") -- '!'
  end)
  T.it("classifies Hebrew letters as R", function()
    T.eq(bidi.classify_codepoint(ALEF), "R")
  end)
  T.it("classifies Arabic letters as AL", function()
    T.eq(bidi.classify_codepoint(BEH), "AL")
  end)
  T.it("classifies Arabic-Indic digits as AN", function()
    T.eq(bidi.classify_codepoint(0x0661), "AN") -- ARABIC-INDIC DIGIT ONE
  end)
  T.it("classifies Extended Arabic-Indic digits as EN (not AN)", function()
    T.eq(bidi.classify_codepoint(0x06F1), "EN") -- EXTENDED ARABIC-INDIC DIGIT ONE
  end)
  T.it("classifies explicit bidi controls", function()
    T.eq(bidi.classify_codepoint(0x202A), "LRE")
    T.eq(bidi.classify_codepoint(0x202B), "RLE")
    T.eq(bidi.classify_codepoint(0x202C), "PDF")
    T.eq(bidi.classify_codepoint(0x202D), "LRO")
    T.eq(bidi.classify_codepoint(0x202E), "RLO")
    T.eq(bidi.classify_codepoint(0x2066), "LRI")
    T.eq(bidi.classify_codepoint(0x2067), "RLI")
    T.eq(bidi.classify_codepoint(0x2068), "FSI")
    T.eq(bidi.classify_codepoint(0x2069), "PDI")
  end)
  T.it("classifies Hebrew combining marks as NSM", function()
    T.eq(bidi.classify_codepoint(0x0591), "NSM") -- HEBREW ACCENT ETNAHTA
    T.eq(bidi.classify_codepoint(0x05B0), "NSM") -- HEBREW POINT SHEVA
    T.eq(bidi.classify_codepoint(0x05BF), "NSM")
    T.eq(bidi.classify_codepoint(0x05C7), "NSM")
  end)
  T.it("classifies Arabic combining marks as NSM", function()
    T.eq(bidi.classify_codepoint(0x064B), "NSM") -- ARABIC FATHATAN
    T.eq(bidi.classify_codepoint(0x0670), "NSM") -- ARABIC LETTER SUPERSCRIPT ALEF
  end)
  T.it("classifies Arabic Supplement as AL", function()
    T.eq(bidi.classify_codepoint(0x0750), "AL")
    T.eq(bidi.classify_codepoint(0x077F), "AL")
  end)
  T.it("classifies Hebrew Presentation Forms as R", function()
    T.eq(bidi.classify_codepoint(0xFB1D), "R")
    T.eq(bidi.classify_codepoint(0xFB4F), "R")
    T.eq(bidi.classify_codepoint(0xFB1E), "NSM")
    T.eq(bidi.classify_codepoint(0xFB29), "ES")
  end)
  T.it("classifies Arabic Presentation Forms-A as AL", function()
    T.eq(bidi.classify_codepoint(0xFB50), "AL")
    T.eq(bidi.classify_codepoint(0xFD3D), "AL")
  end)
  T.it("classifies Arabic Presentation Forms-B as AL", function()
    T.eq(bidi.classify_codepoint(0xFE70), "AL")
    T.eq(bidi.classify_codepoint(0xFEFC), "AL")
  end)
  T.it("classifies currency symbols as ET", function()
    T.eq(bidi.classify_codepoint(0x20AC), "ET") -- Euro sign
  end)
  T.it("classifies math minus as ES", function()
    T.eq(bidi.classify_codepoint(0x2212), "ES")
  end)
  T.it("classifies NEL as B", function()
    T.eq(bidi.classify_codepoint(0x0085), "B")
  end)
  T.it("classifies Arabic date separator as AL (not CS)", function()
    T.eq(bidi.classify_codepoint(0x060D), "AL")
  end)
  T.it("classifies Arabic semicolon as AL (not ON)", function()
    T.eq(bidi.classify_codepoint(0x061B), "AL")
  end)
  T.it("defaults unknown codepoints to L", function()
    T.eq(bidi.classify_codepoint(0x3042), "L") -- HIRAGANA A, outside the bounded table
  end)
  T.it("rejects invalid codepoints", function()
    local t, err = bidi.classify_codepoint(-1)
    T.eq(t, nil)
    T.ok(err)
  end)
end)

-- ================================================================
-- resolve_levels / reorder: pure LTR
-- ================================================================

T.describe("bidi.resolve_levels / bidi.reorder: pure LTR", function()
  T.it("keeps LTR text in logical order with level 0", function()
    local result = bidi.resolve_levels("hello")
    T.eq(result.paragraph_level, 0)
    for i = 1, #result.levels do T.eq(result.levels[i], 0) end
    assert_visual_hex("hello", cps_to_hex(string_to_cps("hello")))
  end)
end)

-- ================================================================
-- resolve_levels / reorder: pure RTL
-- ================================================================

T.describe("bidi.resolve_levels / bidi.reorder: pure RTL", function()
  T.it("resolves Hebrew text to level 1 and reverses visual order", function()
    local text = utf8.char(ALEF, BET, GIMEL)
    local result = bidi.resolve_levels(text)
    T.eq(result.paragraph_level, 1)
    T.eq(result.levels[1], 1)
    T.eq(result.levels[2], 1)
    T.eq(result.levels[3], 1)
    assert_visual_hex(text, cps_to_hex({ GIMEL, BET, ALEF }))
  end)
end)

-- ================================================================
-- resolve_levels / reorder: mixed LTR/RTL
-- ================================================================

T.describe("bidi.resolve_levels / bidi.reorder: mixed LTR/RTL", function()
  T.it("keeps the RTL run internally reversed inside an LTR paragraph", function()
    local text = "abc" .. utf8.char(ALEF, BET, GIMEL) .. "def"
    local result = bidi.resolve_levels(text)
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

-- ================================================================
-- Numbers in RTL context (W rules for EN/AN)
-- ================================================================

T.describe("bidi.resolve_levels / bidi.reorder: numbers in RTL context", function()
  T.it("keeps digits in ascending reading order inside RTL text", function()
    local text = utf8.char(ALEF, BET) .. "123" .. utf8.char(GIMEL)
    local result = bidi.resolve_levels(text)
    T.eq(result.paragraph_level, 1)
    T.eq(result.types[3], "EN")
    T.eq(result.types[4], "EN")
    T.eq(result.types[5], "EN")
    -- digits get level para+1 (EN bumps by 2 from an even seq level, or by
    -- 1 from odd -- here seq level 1 (odd) -> digits at level 2).
    T.eq(result.levels[3], 2)
    T.eq(result.levels[4], 2)
    T.eq(result.levels[5], 2)
    local one, two, three = 0x31, 0x32, 0x33
    assert_visual_hex(text, cps_to_hex({ GIMEL, one, two, three, BET, ALEF }))
  end)
end)

-- ================================================================
-- Mixed Arabic + Latin + European digits + Arabic-Indic digits
-- ================================================================

T.describe("bidi.resolve_levels: Arabic + Latin + mixed digits", function()
  T.it("classifies and levels Arabic-Indic digits as AN", function()
    -- Arabic letter + Arabic-Indic digit + space + Latin
    local text = utf8.char(BEH, 0x0661, 0x20) .. "x"
    local result = bidi.resolve_levels(text)
    T.eq(result.paragraph_level, 1)
    T.eq(result.types[1], "AL")
    T.eq(result.types[2], "AN")
  end)

  T.it("handles Arabic with European digits (W2: EN after AL -> AN)", function()
    -- Arabic letter + European digits => W2 converts EN to AN
    local text = utf8.char(BEH) .. "12"
    local result = bidi.resolve_levels(text)
    T.eq(result.paragraph_level, 1)
    -- After W2, the EN digits following AL become AN.
    -- After W3, AL becomes R.
    -- After I2 (odd level): AN bumps to level+1 = 2.
    T.eq(result.levels[2], 2)
    T.eq(result.levels[3], 2)
  end)

  T.it("Extended Arabic-Indic digits classified as EN", function()
    -- These are EN in the classification table (per UCD).
    T.eq(bidi.classify_codepoint(0x06F1), "EN")
    T.eq(bidi.classify_codepoint(0x06F2), "EN")
  end)
end)

-- ================================================================
-- Explicit embedding controls (LRE/RLE/PDF, LRO/RLO)
-- ================================================================

T.describe("bidi.resolve_levels / bidi.reorder: explicit embedding controls", function()
  T.it("RLE...PDF embeds an RTL run inside LTR text", function()
    local text = "ab" .. utf8.char(0x202B, ALEF, BET, 0x202C) .. "cd"
    local result = bidi.resolve_levels(text)
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
    -- Hebrew, unaffected by override) -- overrides act on level resolution,
    -- not on the reported type. LRO pushes level 2 (next even level above
    -- para level 1) and overrides enclosed characters to behave as L; L at
    -- an even level does not bump per I1, so the level stays 2.
    local text = utf8.char(0x202D, ALEF, BET, 0x202C) -- LRO ... PDF
    local result = bidi.resolve_levels(text)
    T.eq(result.types[2], "R")
    T.eq(result.levels[2], 2)
    T.eq(result.levels[3], 2)

    -- Contrast: LRE (no override) leaves R as R, which DOES bump by I1 at
    -- the even embedding level, landing one level higher.
    local text2 = utf8.char(0x202A, ALEF, BET, 0x202C) -- LRE ... PDF
    local result2 = bidi.resolve_levels(text2)
    T.eq(result2.levels[2], 3)
    T.eq(result2.levels[3], 3)
  end)

  T.it("nested RLE inside LRE", function()
    -- LRE + RLE + Hebrew + PDF + PDF
    local text = utf8.char(0x202A, 0x202B, ALEF, BET, 0x202C, 0x202C)
    local result = bidi.resolve_levels(text)
    -- LRE pushes to next even (2), RLE pushes to next odd (3)
    T.eq(result.levels[3], 3) -- ALEF at level 3
    T.eq(result.levels[4], 3) -- BET at level 3
  end)
end)

-- ================================================================
-- Isolate controls (LRI/RLI/FSI/PDI)
-- ================================================================

T.describe("bidi.resolve_levels: isolate controls", function()
  T.it("RLI...PDI isolates an RTL run without leaking direction", function()
    local text = "a" .. utf8.char(0x2067, ALEF, BET, 0x2069) .. "b"
    local result = bidi.resolve_levels(text)
    T.eq(result.paragraph_level, 0)
    T.eq(result.types[2], "RLI")
    T.eq(result.types[5], "PDI")
  end)

  T.it("LRI...PDI isolates an LTR run inside RTL", function()
    local text = utf8.char(ALEF, 0x2066) .. "abc" .. utf8.char(0x2069, BET)
    local result = bidi.resolve_levels(text)
    T.eq(result.paragraph_level, 1)
    -- "abc" inside the LRI should be at an even level
    T.eq(result.levels[3] % 2, 0)
    T.eq(result.levels[4] % 2, 0)
    T.eq(result.levels[5] % 2, 0)
  end)

  T.it("FSI determines direction from first strong in content", function()
    -- FSI + Hebrew + PDI => FSI acts as RLI (Hebrew is first strong => RTL)
    local text = "x" .. utf8.char(0x2068, ALEF, BET, 0x2069) .. "y"
    local result = bidi.resolve_levels(text)
    -- Hebrew inside should be at odd level (RTL)
    T.eq(result.levels[3] % 2, 1)
    T.eq(result.levels[4] % 2, 1)
  end)

  T.it("FSI with Latin content acts as LRI", function()
    -- FSI + Latin + PDI in RTL context => FSI acts as LRI
    local text = utf8.char(ALEF, 0x2068) .. "abc" .. utf8.char(0x2069, BET)
    local result = bidi.resolve_levels(text)
    T.eq(result.paragraph_level, 1)
    -- Latin inside FSI should be at an even level (LTR)
    T.eq(result.levels[3] % 2, 0)
    T.eq(result.levels[4] % 2, 0)
    T.eq(result.levels[5] % 2, 0)
  end)
end)

-- ================================================================
-- W1-W7 exercises
-- ================================================================

T.describe("weak type resolution (W1-W7)", function()
  T.it("W1: NSM after Hebrew letter inherits R", function()
    -- Hebrew letter + combining mark (NSM) => NSM becomes R
    local text = utf8.char(ALEF, 0x05B0) -- ALEF + SHEVA
    local result = bidi.resolve_levels(text)
    -- Both should be at level 1 (RTL)
    T.eq(result.levels[1], 1)
    T.eq(result.levels[2], 1)
  end)

  T.it("W1: NSM at start of sequence inherits sos", function()
    -- In an LTR paragraph, if the first char is NSM (after filtering), it
    -- inherits sos which is L (max(para_level, before_level) = 0 => L).
    -- Construct: LRE + NSM + PDF (so the NSM is inside a level-2 run
    -- where sos is L).
    local text = utf8.char(0x202A, 0x05B0, 0x202C)
    local result = bidi.resolve_levels(text)
    -- NSM at pos 2 should get sos type. The LRE pushes to next even (2).
    -- sos = max(2, 0) is even => "L". So NSM becomes L. L at even level 2
    -- => I1 no bump => level 2.
    T.eq(result.levels[2], 2)
  end)

  T.it("W2: EN after AL becomes AN", function()
    -- Arabic letter followed by digits: W2 converts EN to AN
    local text = utf8.char(BEH) .. "5"
    local result = bidi.resolve_levels(text)
    -- After W2: '5' (EN) follows AL => becomes AN.
    -- After I2 (odd level 1): AN bumps to 2.
    T.eq(result.levels[2], 2)
  end)

  T.it("W3: AL becomes R", function()
    local text = utf8.char(BEH)
    local result = bidi.resolve_levels(text)
    -- After W3, AL becomes R. R at odd level 1 => I2 no bump.
    T.eq(result.levels[1], 1)
  end)

  T.it("W4: ES between EN stays EN", function()
    -- "1+2" => ES between two EN => ES becomes EN (W4), all stay level 0
    local text = "1+2"
    local result = bidi.resolve_levels(text)
    T.eq(result.levels[1], 0) -- after W7: EN->L in L context
    T.eq(result.levels[2], 0)
    T.eq(result.levels[3], 0)
  end)

  T.it("W4: CS between same types resolves", function()
    -- "1,2" => CS between two EN => CS becomes EN (W4)
    local text = "1,2"
    local result = bidi.resolve_levels(text)
    T.eq(result.levels[1], 0)
    T.eq(result.levels[2], 0)
    T.eq(result.levels[3], 0)
  end)

  T.it("W5: ET adjacent to EN becomes EN", function()
    -- "$1" => ET followed by EN => ET becomes EN (W5)
    local text = "$1"
    local result = bidi.resolve_levels(text)
    -- Both become L after W7 (EN in L context -> L), level 0
    T.eq(result.levels[1], 0)
    T.eq(result.levels[2], 0)
  end)

  T.it("W5: ET after EN also becomes EN", function()
    -- "1%" => EN followed by ET => ET becomes EN (W5)
    local text = "1%"
    local result = bidi.resolve_levels(text)
    T.eq(result.levels[1], 0)
    T.eq(result.levels[2], 0)
  end)

  T.it("W6: isolated ES becomes ON", function()
    -- '+' not between EN: becomes ON via W6
    local text = "a+b"
    local result = bidi.resolve_levels(text)
    -- ES between L and L => W4 does nothing (not EN..EN). W6 => ON.
    -- N1: ON between L and L => L. Level 0.
    T.eq(result.levels[2], 0)
  end)

  T.it("W6: isolated CS between different types becomes ON", function()
    -- "a,b" => CS between two L chars => stays CS after W4 (not same type
    -- EN or AN), becomes ON in W6, resolves to L in N1.
    local text = "a,b"
    local result = bidi.resolve_levels(text)
    T.eq(result.levels[2], 0)
  end)

  T.it("W7: EN becomes L when nearest preceding strong is L", function()
    -- In LTR paragraph: "a1" => EN follows L => W7 turns EN to L
    local text = "a1"
    local result = bidi.resolve_levels(text)
    T.eq(result.levels[1], 0)
    T.eq(result.levels[2], 0)
  end)
end)

-- ================================================================
-- N1-N2 exercises
-- ================================================================

T.describe("neutral resolution (N1-N2)", function()
  T.it("N1: neutral between same-direction strong types inherits direction", function()
    -- Hebrew + '!' + Hebrew => ON between R and R => becomes R
    local text = utf8.char(ALEF) .. "!" .. utf8.char(BET)
    local result = bidi.resolve_levels(text)
    T.eq(result.paragraph_level, 1)
    T.eq(result.levels[1], 1) -- ALEF
    T.eq(result.levels[2], 1) -- '!' resolves to R (N1: R...R)
    T.eq(result.levels[3], 1) -- BET
  end)

  T.it("N1: neutral between L and L resolves to L", function()
    -- "a!b" => ON between L and L => L
    local text = "a!b"
    local result = bidi.resolve_levels(text)
    T.eq(result.levels[1], 0)
    T.eq(result.levels[2], 0)
    T.eq(result.levels[3], 0)
  end)

  T.it("N2: neutral between different-direction types uses embedding direction", function()
    -- In a forced LTR paragraph: Hebrew + '!' + Latin
    -- '!' is between R and L => N1 fails, N2 uses embedding dir (L) => level 0
    local text = utf8.char(ALEF, BET) .. "!ab"
    local result = bidi.resolve_levels(text, { base_direction = "ltr" })
    T.eq(result.paragraph_level, 0)
    T.eq(result.levels[3], 0)
  end)

  T.it("punctuation between RTL and LTR in RTL paragraph", function()
    local text = utf8.char(ALEF, BET) .. "!ab"
    local result = bidi.resolve_levels(text)
    T.eq(result.paragraph_level, 1)
    assert_visual_hex(text, cps_to_hex({ 0x61, 0x62, 0x21, BET, ALEF }))
  end)

  T.it("same text under a forced LTR base direction reorders differently", function()
    local text = utf8.char(ALEF, BET) .. "!ab"
    local result = bidi.resolve_levels(text, { base_direction = "ltr" })
    T.eq(result.paragraph_level, 0)
    local a, b, bang = 0x61, 0x62, 0x21
    assert_visual_hex(text, cps_to_hex({ BET, ALEF, bang, a, b }), { base_direction = "ltr" })
  end)
end)

-- ================================================================
-- reorder_to_visual convenience
-- ================================================================

T.describe("bidi.reorder_to_visual", function()
  T.it("composes resolve and reorder", function()
    local visual, err = bidi.reorder_to_visual(utf8.char(ALEF, BET, GIMEL))
    T.ok(visual, err)
    T.eq(cps_to_hex(string_to_cps(visual)), cps_to_hex({ GIMEL, BET, ALEF }))
  end)
end)

-- ================================================================
-- visual_runs
-- ================================================================

T.describe("bidi.visual_runs", function()
  T.it("returns a single LTR run for pure Latin text", function()
    local runs, err = bidi.visual_runs("hello")
    T.ok(runs, err)
    T.eq(#runs, 1)
    T.eq(runs[1].start, 1)
    T.eq(runs[1].stop, 5)
    T.eq(runs[1].level, 0)
  end)

  T.it("returns runs in visual order for mixed text", function()
    local text = "ab" .. utf8.char(ALEF, BET) .. "cd"
    local runs, err = bidi.visual_runs(text)
    T.ok(runs, err)
    -- Should have 3 runs: LTR "ab", RTL Hebrew, LTR "cd"
    T.eq(#runs, 3)
    T.eq(runs[1].level % 2, 0) -- first visual run is LTR
    T.eq(runs[2].level % 2, 1) -- middle is RTL
    T.eq(runs[3].level % 2, 0) -- last is LTR
  end)

  T.it("returns empty for empty input", function()
    local runs = bidi.visual_runs("")
    T.eq(#runs, 0)
  end)
end)

-- ================================================================
-- base_direction option
-- ================================================================

T.describe("base_direction option", function()
  T.it("forces LTR paragraph level", function()
    local text = utf8.char(ALEF, BET)
    local result = bidi.resolve_levels(text, { base_direction = "ltr" })
    T.eq(result.paragraph_level, 0)
  end)

  T.it("forces RTL paragraph level", function()
    local result = bidi.resolve_levels("hello", { base_direction = "rtl" })
    T.eq(result.paragraph_level, 1)
  end)

  T.it("auto detects from first strong character", function()
    local text = utf8.char(ALEF) .. "abc"
    local result = bidi.resolve_levels(text, { base_direction = "auto" })
    T.eq(result.paragraph_level, 1) -- ALEF is first strong => RTL
  end)

  T.it("auto is the default", function()
    local r1 = bidi.resolve_levels(utf8.char(ALEF) .. "abc")
    local r2 = bidi.resolve_levels(utf8.char(ALEF) .. "abc", { base_direction = "auto" })
    T.eq(r1.paragraph_level, r2.paragraph_level)
    for i = 1, #r1.levels do T.eq(r1.levels[i], r2.levels[i]) end
  end)
end)

-- ================================================================
-- N0: paired bracket resolution (BD16)
-- ================================================================

T.describe("N0: paired bracket resolution", function()
  T.it("case b: content matching embedding direction sets both brackets to it", function()
    -- Forced RTL paragraph (e=R). "(" HEBREW ")" between Latin: the
    -- enclosed Hebrew is R, matching e, so N0 case (b) sets both
    -- brackets to R. 'a'/'b' (L) bump by I1 at the odd seq level;
    -- brackets (now R) and the Hebrew letters stay at level 1.
    local text = "a(" .. utf8.char(ALEF, BET) .. ")b"
    local result = bidi.resolve_levels(text, { base_direction = "rtl" })
    T.eq(result.paragraph_level, 1)
    T.eq(result.levels[1], 2) -- 'a'
    T.eq(result.levels[2], 1) -- '(' -> R via N0(b)
    T.eq(result.levels[3], 1) -- ALEF
    T.eq(result.levels[4], 1) -- BET
    T.eq(result.levels[5], 1) -- ')' -> R via N0(b)
    T.eq(result.levels[6], 2) -- 'b'
  end)

  T.it("case c2: opposite content with matching preceding context falls back to embedding direction", function()
    -- LTR paragraph (e=L). "x(" HEBREW ")y": enclosed Hebrew is R,
    -- opposite of e. The nearest preceding strong before "(" is 'x'
    -- (L), which matches e (not opposite) -> N0 case (c2): both
    -- brackets resolve to e (L), hugging the surrounding LTR text.
    local text = "x(" .. utf8.char(ALEF, BET) .. ")y"
    local result = bidi.resolve_levels(text, { base_direction = "ltr" })
    T.eq(result.paragraph_level, 0)
    T.eq(result.levels[1], 0) -- 'x'
    T.eq(result.levels[2], 0) -- '(' -> L via N0(c2)
    T.eq(result.levels[3], 1) -- ALEF (R, bumps at even seq level)
    T.eq(result.levels[4], 1) -- BET
    T.eq(result.levels[5], 0) -- ')' -> L via N0(c2)
    T.eq(result.levels[6], 0) -- 'y'
  end)

  T.it("case c1: established opposite context forces both brackets opposite embedding, symmetrically", function()
    -- Forced LTR paragraph (e=L) but starting with Hebrew: HEBREW " ("
    -- HEBREW ") z". Enclosed content (BET) is R, opposite of e.
    -- Scanning backward from the opening bracket past the WS finds
    -- ALEF (R) as the established context -- also opposite of e -- so
    -- N0 case (c1) sets BOTH brackets to R.
    --
    -- This is the case that N0 actually adds over plain N1/N2: without
    -- pairing, N1 would resolve the neutral run "<WS>(" (bounded by
    -- ALEF=R before and BET=R after) to R, but the neutral run ")<WS>"
    -- (bounded by BET=R before and 'z'=L after) would mismatch and fall
    -- to N2's embedding direction L -- giving the two brackets of the
    -- SAME pair different resolved directions. N0 forces them to agree.
    local text = utf8.char(ALEF) .. " (" .. utf8.char(BET) .. ") z"
    local result = bidi.resolve_levels(text, { base_direction = "ltr" })
    T.eq(result.paragraph_level, 0)
    T.eq(result.levels[1], 1) -- ALEF (R)
    T.eq(result.levels[2], 1) -- ' ' -> R via N1 (bounded by R...R)
    T.eq(result.levels[3], 1) -- '(' -> R via N0(c1)
    T.eq(result.levels[4], 1) -- BET (R)
    T.eq(result.levels[5], 1) -- ')' -> R via N0(c1)
    T.eq(result.levels[6], 0) -- ' ' -> L via N2 (mismatch, embedding L)
    T.eq(result.levels[7], 0) -- 'z'
  end)

  T.it("case d: no strong type enclosed leaves brackets unresolved by N0 (N1/N2 still apply)", function()
    -- "a( )b": nothing but WS between the brackets -> N0 does not set
    -- them; the whole neutral run "( )" (ON, WS, ON) is bounded by
    -- L...L and resolves to L via plain N1, same as if N0 didn't exist.
    local text = "a( )b"
    local result = bidi.resolve_levels(text)
    T.eq(result.paragraph_level, 0)
    for i = 1, 5 do T.eq(result.levels[i], 0) end
  end)

  T.it("unmatched brackets are unaffected by N0 and still resolve via N1/N2", function()
    local text = "a)b"
    local result = bidi.resolve_levels(text)
    T.eq(result.paragraph_level, 0)
    T.eq(result.levels[1], 0)
    T.eq(result.levels[2], 0)
    T.eq(result.levels[3], 0)
  end)

  T.it("nested bracket pairs both resolve correctly (BD16 stack pairing)", function()
    -- "((a))" in LTR: all content is L, matches e -> both pairs
    -- resolve to L (case b), same as their surrounding context.
    local text = "((a))"
    local result = bidi.resolve_levels(text)
    for i = 1, 5 do T.eq(result.levels[i], 0) end
  end)
end)

-- ================================================================
-- Error handling
-- ================================================================

T.describe("bidi.resolve_levels: error handling", function()
  T.it("rejects invalid UTF-8", function()
    local result, err = bidi.resolve_levels("\xff\xfe")
    T.eq(result, nil)
    T.ok(err)
  end)
end)
