if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local arabic = require("lib.arabic")

-- Base letters used across tests (all in U+0621-U+064A).
local HAMZA = 0x0621    -- Non_Joining
local ALEF  = 0x0627    -- Right_Joining
local BEH   = 0x0628    -- Dual_Joining
local TEH   = 0x062A    -- Dual_Joining
local DAL   = 0x062F    -- Right_Joining
local LAM   = 0x0644    -- Dual_Joining
local FATHA = 0x064E    -- Transparent (combining mark)
local TATWEEL = 0x0640  -- Join_Causing

-- ================================================================
-- classify_codepoint
-- ================================================================

T.describe("arabic.classify_codepoint", function()
  T.it("classifies dual-joining letters as D", function()
    T.eq(arabic.classify_codepoint(BEH), "D")
    T.eq(arabic.classify_codepoint(TEH), "D")
    T.eq(arabic.classify_codepoint(LAM), "D")
  end)
  T.it("classifies right-joining letters as R", function()
    T.eq(arabic.classify_codepoint(ALEF), "R")
    T.eq(arabic.classify_codepoint(DAL), "R")
  end)
  T.it("classifies HAMZA as U (non-joining)", function()
    T.eq(arabic.classify_codepoint(HAMZA), "U")
  end)
  T.it("classifies TATWEEL as C (join-causing)", function()
    T.eq(arabic.classify_codepoint(TATWEEL), "C")
  end)
  T.it("classifies harakat as T (transparent)", function()
    T.eq(arabic.classify_codepoint(FATHA), "T")
  end)
  T.it("defaults uncovered codepoints (e.g. space) to U", function()
    T.eq(arabic.classify_codepoint(0x20), "U")
  end)
  T.it("rejects non-integer codepoints", function()
    local t, err = arabic.classify_codepoint(1.5)
    T.eq(t, nil)
    T.ok(err)
  end)
end)

-- ================================================================
-- shape_codepoints
-- ================================================================

T.describe("arabic.shape_codepoints", function()
  T.it("shapes a lone dual-joining letter as isolated", function()
    local shaped, err = arabic.shape_codepoints({ BEH })
    T.ok(shaped, err)
    T.eq(shaped[1].form, "isolated")
    T.eq(shaped[1].codepoint, 0xFE8F)
  end)
  T.it("shapes two dual-joining letters as initial + final", function()
    local shaped, err = arabic.shape_codepoints({ BEH, TEH })
    T.ok(shaped, err)
    T.eq(shaped[1].form, "initial")
    T.eq(shaped[1].codepoint, 0xFE91)
    T.eq(shaped[2].form, "final")
    T.eq(shaped[2].codepoint, 0xFE96)
  end)
  T.it("shapes three dual-joining letters as initial + medial + final", function()
    local shaped, err = arabic.shape_codepoints({ BEH, TEH, BEH })
    T.ok(shaped, err)
    T.eq(shaped[1].form, "initial")
    T.eq(shaped[2].form, "medial")
    T.eq(shaped[2].codepoint, 0xFE98)
    T.eq(shaped[3].form, "final")
  end)
  T.it("right-joining letters never take initial/medial forms", function()
    -- BEH DAL BEH: DAL can receive from the first BEH (-> final) but
    -- cannot send forward, so the second BEH gets no join from prev.
    local shaped, err = arabic.shape_codepoints({ BEH, DAL, BEH })
    T.ok(shaped, err)
    T.eq(shaped[1].form, "initial")
    T.eq(shaped[2].form, "final")
    T.eq(shaped[2].codepoint, 0xFEAA)
    T.eq(shaped[3].form, "isolated")
  end)
  T.it("a lone right-joining letter is isolated", function()
    local shaped, err = arabic.shape_codepoints({ ALEF })
    T.ok(shaped, err)
    T.eq(shaped[1].form, "isolated")
    T.eq(shaped[1].codepoint, 0xFE8D)
  end)
  T.it("transparent marks are invisible to joining but pass through unshaped", function()
    local shaped, err = arabic.shape_codepoints({ BEH, FATHA, TEH })
    T.ok(shaped, err)
    T.eq(shaped[1].form, "initial")   -- joins across the mark to TEH
    T.eq(shaped[2].form, nil)
    T.eq(shaped[2].codepoint, FATHA)  -- unchanged
    T.eq(shaped[3].form, "final")
  end)
  T.it("join-causing TATWEEL propagates joins but has no shape of its own", function()
    local shaped, err = arabic.shape_codepoints({ BEH, TATWEEL, TEH })
    T.ok(shaped, err)
    T.eq(shaped[1].form, "initial")
    T.eq(shaped[2].form, nil)
    T.eq(shaped[2].codepoint, TATWEEL)
    T.eq(shaped[3].form, "final")
  end)
  T.it("non-joining HAMZA blocks joining on both sides", function()
    local shaped, err = arabic.shape_codepoints({ BEH, HAMZA, TEH })
    T.ok(shaped, err)
    T.eq(shaped[1].form, "isolated")
    T.eq(shaped[3].form, "isolated")
  end)
  T.it("whitespace naturally breaks joining runs (word boundary)", function()
    local shaped, err = arabic.shape_codepoints({ BEH, TEH, 0x20, BEH, TEH })
    T.ok(shaped, err)
    T.eq(shaped[1].form, "initial")
    T.eq(shaped[2].form, "final")
    T.eq(shaped[4].form, "initial")
    T.eq(shaped[5].form, "final")
  end)
  T.it("letters outside the FE70-FEFF-mapped set keep their codepoint", function()
    -- U+066E DOTLESS BEH is Dual_Joining but has no presentation form.
    local shaped, err = arabic.shape_codepoints({ 0x066E })
    T.ok(shaped, err)
    T.eq(shaped[1].form, "isolated")
    T.eq(shaped[1].codepoint, 0x066E) -- unchanged: no form exists
  end)
  T.it("rejects invalid UTF-8", function()
    local shaped, err = arabic.shape_codepoints("\xff\xfe")
    T.eq(shaped, nil)
    T.ok(err)
  end)
end)

-- ================================================================
-- shape (string convenience)
-- ================================================================

T.describe("arabic.shape", function()
  T.it("round-trips through UTF-8 with the same codepoint count", function()
    local utf8 = require("lib.encode.utf8")
    local text = utf8.char(BEH, TEH)
    local shaped, err = arabic.shape(text)
    T.ok(shaped, err)
    local count = 0
    for _ in utf8.codes(shaped) do count = count + 1 end
    T.eq(count, 2)
  end)
end)

-- ================================================================
-- apply_lam_alef_ligatures
-- ================================================================

T.describe("arabic.apply_lam_alef_ligatures", function()
  T.it("collapses LAM + ALEF into the isolated ligature at start of text", function()
    local out, err = arabic.apply_lam_alef_ligatures({ LAM, ALEF })
    T.ok(out, err)
    T.eq(#out, 1)
    T.eq(out[1], 0xFEFB)
  end)
  T.it("collapses LAM + ALEF into the final ligature when preceded by a joining letter", function()
    local out, err = arabic.apply_lam_alef_ligatures({ BEH, LAM, ALEF })
    T.ok(out, err)
    T.eq(#out, 2)
    T.eq(out[1], BEH)
    T.eq(out[2], 0xFEFC)
  end)
  T.it("covers all four alef variants", function()
    local ALEF_MADDA = 0x0622
    local ALEF_HAMZA_ABOVE = 0x0623
    local ALEF_HAMZA_BELOW = 0x0625
    local out1 = arabic.apply_lam_alef_ligatures({ LAM, ALEF_MADDA })
    T.eq(out1[1], 0xFEF5)
    local out2 = arabic.apply_lam_alef_ligatures({ LAM, ALEF_HAMZA_ABOVE })
    T.eq(out2[1], 0xFEF7)
    local out3 = arabic.apply_lam_alef_ligatures({ LAM, ALEF_HAMZA_BELOW })
    T.eq(out3[1], 0xFEF9)
  end)
  T.it("does not collapse LAM when not followed by an alef variant", function()
    local out, err = arabic.apply_lam_alef_ligatures({ LAM, BEH })
    T.ok(out, err)
    T.eq(#out, 2)
    T.eq(out[1], LAM)
    T.eq(out[2], BEH)
  end)
  T.it("leaves unrelated text untouched", function()
    local out, err = arabic.apply_lam_alef_ligatures({ BEH, TEH, DAL })
    T.ok(out, err)
    T.eq(#out, 3)
    T.eq(out[1], BEH)
    T.eq(out[2], TEH)
    T.eq(out[3], DAL)
  end)
  T.it("rejects invalid UTF-8", function()
    local out, err = arabic.apply_lam_alef_ligatures("\xff\xfe")
    T.eq(out, nil)
    T.ok(err)
  end)
end)
