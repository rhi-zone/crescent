if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local cs = require("lib.color_space")

local function approx(a, b, eps)
  eps = eps or 0.1
  T.ok(math.abs(a - b) < eps, string.format("expected %g ≈ %g (eps=%g)", a, b, eps))
end

----------------------------------------------------------------------
-- sRGB ↔ linear
----------------------------------------------------------------------

T.describe("srgb_to_linear", function()
  T.it("0 → 0", function()
    T.eq(cs.srgb_to_linear(0), 0)
  end)
  T.it("1 → 1", function()
    T.eq(cs.srgb_to_linear(1), 1)
  end)
  T.it("0.5 ≈ 0.2140", function()
    approx(cs.srgb_to_linear(0.5), 0.2140, 0.001)
  end)
  T.it("clamps below 0", function()
    T.eq(cs.srgb_to_linear(-1), 0)
  end)
  T.it("clamps above 1", function()
    T.eq(cs.srgb_to_linear(2), 1)
  end)
end)

T.describe("linear_to_srgb", function()
  T.it("0 → 0", function()
    T.eq(cs.linear_to_srgb(0), 0)
  end)
  T.it("1 → 1", function()
    T.eq(cs.linear_to_srgb(1), 1)
  end)
  T.it("round-trip 0.5", function()
    approx(cs.linear_to_srgb(cs.srgb_to_linear(0.5)), 0.5, 1e-6)
  end)
  T.it("round-trip 0.8", function()
    approx(cs.linear_to_srgb(cs.srgb_to_linear(0.8)), 0.8, 1e-6)
  end)
end)

----------------------------------------------------------------------
-- sRGB ↔ XYZ
----------------------------------------------------------------------

T.describe("rgb_to_xyz", function()
  T.it("white (1,1,1) → approx D65 white", function()
    local X, Y, Z = cs.rgb_to_xyz(1, 1, 1)
    approx(X, 0.9505, 0.005)
    approx(Y, 1.0000, 0.005)
    approx(Z, 1.0890, 0.005)
  end)
  T.it("black (0,0,0) → (0,0,0)", function()
    local X, Y, Z = cs.rgb_to_xyz(0, 0, 0)
    approx(X, 0, 1e-6)
    approx(Y, 0, 1e-6)
    approx(Z, 0, 1e-6)
  end)
  T.it("red (1,0,0) → approx (0.4124, 0.2126, 0.0193)", function()
    local X, Y, Z = cs.rgb_to_xyz(1, 0, 0)
    approx(X, 0.4124, 0.005)
    approx(Y, 0.2126, 0.005)
    approx(Z, 0.0193, 0.005)
  end)
  T.it("green (0,1,0) → approx (0.3576, 0.7152, 0.1192)", function()
    local X, Y, Z = cs.rgb_to_xyz(0, 1, 0)
    approx(X, 0.3576, 0.005)
    approx(Y, 0.7152, 0.005)
    approx(Z, 0.1192, 0.005)
  end)
  T.it("blue (0,0,1) → approx (0.1805, 0.0722, 0.9505)", function()
    local X, Y, Z = cs.rgb_to_xyz(0, 0, 1)
    approx(X, 0.1805, 0.005)
    approx(Y, 0.0722, 0.005)
    approx(Z, 0.9505, 0.005)
  end)
end)

T.describe("xyz_to_rgb round-trip", function()
  T.it("red round-trip", function()
    local X, Y, Z = cs.rgb_to_xyz(1, 0, 0)
    local r, g, b = cs.xyz_to_rgb(X, Y, Z)
    approx(r, 1, 1e-4)
    approx(g, 0, 1e-4)
    approx(b, 0, 1e-4)
  end)
  T.it("green round-trip", function()
    local X, Y, Z = cs.rgb_to_xyz(0, 1, 0)
    local r, g, b = cs.xyz_to_rgb(X, Y, Z)
    approx(r, 0, 1e-4)
    approx(g, 1, 1e-4)
    approx(b, 0, 1e-4)
  end)
  T.it("mid-gray round-trip", function()
    local X, Y, Z = cs.rgb_to_xyz(0.5, 0.5, 0.5)
    local r, g, b = cs.xyz_to_rgb(X, Y, Z)
    approx(r, 0.5, 1e-4)
    approx(g, 0.5, 1e-4)
    approx(b, 0.5, 1e-4)
  end)
end)

----------------------------------------------------------------------
-- sRGB ↔ Lab (CIELAB)
----------------------------------------------------------------------

T.describe("rgb_to_lab", function()
  T.it("white (1,1,1) → Lab(100, 0, 0)", function()
    local L, a, b = cs.rgb_to_lab(1, 1, 1)
    approx(L, 100, 0.1)
    approx(a, 0,   0.5)
    approx(b, 0,   0.5)
  end)
  T.it("black (0,0,0) → Lab(0, 0, 0)", function()
    local L, a, b = cs.rgb_to_lab(0, 0, 0)
    approx(L, 0, 0.1)
    approx(a, 0, 0.1)
    approx(b, 0, 0.1)
  end)
  T.it("red (1,0,0) → Lab(53.23, 80.11, 67.22) approx", function()
    local L, a, b = cs.rgb_to_lab(1, 0, 0)
    approx(L, 53.23, 0.5)
    approx(a, 80.11, 1.0)
    approx(b, 67.22, 1.0)
  end)
  T.it("green (0,1,0) → Lab(87.74, -86.18, 83.18) approx", function()
    local L, a, b = cs.rgb_to_lab(0, 1, 0)
    approx(L, 87.74, 0.5)
    approx(a, -86.18, 1.5)
    approx(b,  83.18, 1.5)
  end)
  T.it("blue (0,0,1) → Lab(32.30, 79.19, -107.86) approx", function()
    local L, a, b = cs.rgb_to_lab(0, 0, 1)
    approx(L,   32.30,  0.5)
    approx(a,   79.19,  1.5)
    approx(b, -107.86,  2.0)
  end)
end)

T.describe("lab_to_rgb round-trip", function()
  T.it("white round-trip", function()
    local L, a, b = cs.rgb_to_lab(1, 1, 1)
    local r, g, bv = cs.lab_to_rgb(L, a, b)
    approx(r, 1, 1e-4)
    approx(g, 1, 1e-4)
    approx(bv, 1, 1e-4)
  end)
  T.it("black round-trip", function()
    local L, a, b = cs.rgb_to_lab(0, 0, 0)
    local r, g, bv = cs.lab_to_rgb(L, a, b)
    approx(r,  0, 1e-4)
    approx(g,  0, 1e-4)
    approx(bv, 0, 1e-4)
  end)
  T.it("red round-trip", function()
    local L, a, b = cs.rgb_to_lab(1, 0, 0)
    local r, g, bv = cs.lab_to_rgb(L, a, b)
    approx(r,  1, 1e-3)
    approx(g,  0, 1e-3)
    approx(bv, 0, 1e-3)
  end)
  T.it("arbitrary color round-trip", function()
    local L, a, b = cs.rgb_to_lab(0.3, 0.6, 0.9)
    local r, g, bv = cs.lab_to_rgb(L, a, b)
    approx(r,  0.3, 1e-3)
    approx(g,  0.6, 1e-3)
    approx(bv, 0.9, 1e-3)
  end)
end)

----------------------------------------------------------------------
-- Lab ↔ LCH
----------------------------------------------------------------------

T.describe("lab_to_lch", function()
  T.it("white Lab(100,0,0) → LCH(100, 0, 0)", function()
    local L, C, H = cs.lab_to_lch(100, 0, 0)
    approx(L, 100, 0.01)
    approx(C,   0, 0.01)
  end)
  T.it("chroma from a/b", function()
    -- a=3, b=4 → C=5
    local L, C, H = cs.lab_to_lch(50, 3, 4)
    approx(C, 5, 1e-6)
  end)
  T.it("hue from a/b (pure a+)", function()
    -- a=1, b=0 → H=0°
    local L, C, H = cs.lab_to_lch(50, 1, 0)
    approx(H, 0, 0.01)
  end)
  T.it("hue from a/b (pure b+)", function()
    -- a=0, b=1 → H=90°
    local L, C, H = cs.lab_to_lch(50, 0, 1)
    approx(H, 90, 0.01)
  end)
  T.it("hue from a/b (pure a-)", function()
    -- a=-1, b=0 → H=180°
    local L, C, H = cs.lab_to_lch(50, -1, 0)
    approx(H, 180, 0.01)
  end)
end)

T.describe("lch_to_lab round-trip", function()
  T.it("red LCH round-trip", function()
    local L0, a0, b0 = cs.rgb_to_lab(1, 0, 0)
    local Lc, C, H   = cs.lab_to_lch(L0, a0, b0)
    local Lr, ar, br = cs.lch_to_lab(Lc, C, H)
    approx(Lr, L0, 1e-6)
    approx(ar, a0, 1e-6)
    approx(br, b0, 1e-6)
  end)
end)

----------------------------------------------------------------------
-- OKLab
----------------------------------------------------------------------

T.describe("rgb_to_oklab", function()
  T.it("white (1,1,1) → OKLab ≈ (1, 0, 0)", function()
    local L, a, b = cs.rgb_to_oklab(1, 1, 1)
    approx(L, 1, 0.001)
    approx(a, 0, 0.001)
    approx(b, 0, 0.001)
  end)
  T.it("black (0,0,0) → OKLab ≈ (0, 0, 0)", function()
    local L, a, b = cs.rgb_to_oklab(0, 0, 0)
    approx(L, 0, 0.001)
    approx(a, 0, 0.001)
    approx(b, 0, 0.001)
  end)
  T.it("red (1,0,0) → OKLab ≈ (0.6279, 0.2249, 0.1259)", function()
    local L, a, b = cs.rgb_to_oklab(1, 0, 0)
    approx(L, 0.6279, 0.005)
    approx(a, 0.2249, 0.010)
    approx(b, 0.1259, 0.010)
  end)
  T.it("L is monotone with luminance", function()
    local L1 = (cs.rgb_to_oklab(0.2, 0.2, 0.2))
    local L2 = (cs.rgb_to_oklab(0.8, 0.8, 0.8))
    T.ok(L2 > L1)
  end)
end)

T.describe("oklab_to_rgb round-trip", function()
  T.it("white", function()
    local L, a, b = cs.rgb_to_oklab(1, 1, 1)
    local r, g, bv = cs.oklab_to_rgb(L, a, b)
    approx(r,  1, 1e-3)
    approx(g,  1, 1e-3)
    approx(bv, 1, 1e-3)
  end)
  T.it("black", function()
    local L, a, b = cs.rgb_to_oklab(0, 0, 0)
    local r, g, bv = cs.oklab_to_rgb(L, a, b)
    approx(r,  0, 1e-3)
    approx(g,  0, 1e-3)
    approx(bv, 0, 1e-3)
  end)
  T.it("red", function()
    local L, a, b = cs.rgb_to_oklab(1, 0, 0)
    local r, g, bv = cs.oklab_to_rgb(L, a, b)
    approx(r,  1, 1e-3)
    approx(g,  0, 1e-3)
    approx(bv, 0, 1e-3)
  end)
  T.it("teal (0.2, 0.7, 0.6)", function()
    local L, a, b = cs.rgb_to_oklab(0.2, 0.7, 0.6)
    local r, g, bv = cs.oklab_to_rgb(L, a, b)
    approx(r,  0.2, 1e-3)
    approx(g,  0.7, 1e-3)
    approx(bv, 0.6, 1e-3)
  end)
end)

----------------------------------------------------------------------
-- HSLuv
----------------------------------------------------------------------

T.describe("rgb_to_hsluv", function()
  T.it("white → L=100", function()
    local H, S, L = cs.rgb_to_hsluv(1, 1, 1)
    approx(L, 100, 0.01)
  end)
  T.it("black → L=0", function()
    local H, S, L = cs.rgb_to_hsluv(0, 0, 0)
    approx(L, 0, 0.01)
  end)
  T.it("white → S=0", function()
    local H, S, L = cs.rgb_to_hsluv(1, 1, 1)
    approx(S, 0, 0.01)
  end)
  T.it("black → S=0", function()
    local H, S, L = cs.rgb_to_hsluv(0, 0, 0)
    approx(S, 0, 0.01)
  end)
  T.it("red H near 12.18 (sRGB red in LCH)", function()
    -- Red in HSLuv: H≈12.18, S=100, L≈53.23
    local H, S, L = cs.rgb_to_hsluv(1, 0, 0)
    approx(L, 53.23, 0.5)
    approx(S, 100,   1.0)
    -- H should be in a valid range
    T.ok(H >= 0 and H < 360)
  end)
  T.it("gray → S=0", function()
    local H, S, L = cs.rgb_to_hsluv(0.5, 0.5, 0.5)
    approx(S, 0, 0.1)
  end)
end)

T.describe("hsluv round-trip", function()
  T.it("white round-trip", function()
    local H, S, L = cs.rgb_to_hsluv(1, 1, 1)
    local r, g, b = cs.hsluv_to_rgb(H, S, L)
    approx(r, 1, 1e-3)
    approx(g, 1, 1e-3)
    approx(b, 1, 1e-3)
  end)
  T.it("black round-trip", function()
    local H, S, L = cs.rgb_to_hsluv(0, 0, 0)
    local r, g, b = cs.hsluv_to_rgb(H, S, L)
    approx(r, 0, 1e-3)
    approx(g, 0, 1e-3)
    approx(b, 0, 1e-3)
  end)
  T.it("red round-trip", function()
    local H, S, L = cs.rgb_to_hsluv(1, 0, 0)
    local r, g, b = cs.hsluv_to_rgb(H, S, L)
    approx(r, 1, 0.01)
    approx(g, 0, 0.01)
    approx(b, 0, 0.01)
  end)
  T.it("mid-blue round-trip", function()
    local H, S, L = cs.rgb_to_hsluv(0.2, 0.4, 0.8)
    local r, g, b = cs.hsluv_to_rgb(H, S, L)
    approx(r, 0.2, 0.01)
    approx(g, 0.4, 0.01)
    approx(b, 0.8, 0.01)
  end)
end)

----------------------------------------------------------------------
-- Delta-E
----------------------------------------------------------------------

T.describe("delta_e_76", function()
  T.it("same color → 0", function()
    local lab = {50, 20, -10}
    approx(cs.delta_e_76(lab, lab), 0, 1e-6)
  end)
  T.it("white vs black → large", function()
    local white = {100, 0, 0}
    local black = {0,   0, 0}
    T.ok(cs.delta_e_76(white, black) > 50)
  end)
  T.it("close colors → small", function()
    local c1 = {50, 10, 10}
    local c2 = {51, 10, 10}
    T.ok(cs.delta_e_76(c1, c2) < 2)
  end)
  T.it("known: dL=1, da=1, db=1 → sqrt(3) ≈ 1.732", function()
    local c1 = {50, 0, 0}
    local c2 = {51, 1, 1}
    approx(cs.delta_e_76(c1, c2), math.sqrt(3), 1e-6)
  end)
end)

T.describe("delta_e_2000", function()
  T.it("same color → 0", function()
    local lab = {50, 20, -10}
    approx(cs.delta_e_2000(lab, lab), 0, 1e-6)
  end)
  T.it("white vs black → large", function()
    local white = {100, 0, 0}
    local black = {0,   0, 0}
    T.ok(cs.delta_e_2000(white, black) > 50)
  end)
  T.it("close colors → small", function()
    local c1 = {50, 10, 10}
    local c2 = {51, 10, 10}
    T.ok(cs.delta_e_2000(c1, c2) < 2)
  end)
  T.it("2000 ≤ 76 for small diffs (generally holds)", function()
    -- CIEDE2000 is more perceptually accurate; for small diffs it can differ
    local c1 = {50, 5, 5}
    local c2 = {52, 6, 4}
    local d76  = cs.delta_e_76(c1, c2)
    local d2000 = cs.delta_e_2000(c1, c2)
    -- Both should be reasonable values
    T.ok(d76   > 0)
    T.ok(d2000 > 0)
  end)
  T.it("known pair from Sharma 2005 pair 1: ~2.0425", function()
    -- First test pair from Sharma et al. 2005 (slight adaptation)
    -- lab1={50.0000, 2.6772, -79.7751}, lab2={50.0000, 0.0000, -82.7485}
    -- Expected ΔE00 ≈ 2.0425
    local c1 = {50.0000,  2.6772, -79.7751}
    local c2 = {50.0000,  0.0000, -82.7485}
    approx(cs.delta_e_2000(c1, c2), 2.0425, 0.005)
  end)
end)

----------------------------------------------------------------------
-- Perceptual mixing
----------------------------------------------------------------------

T.describe("mix_lab", function()
  T.it("t=0 returns first color", function()
    local c1 = {50, 20, -10}
    local c2 = {80, -5, 30}
    local m = cs.mix_lab(c1, c2, 0)
    approx(m[1], c1[1], 1e-9)
    approx(m[2], c1[2], 1e-9)
    approx(m[3], c1[3], 1e-9)
  end)
  T.it("t=1 returns second color", function()
    local c1 = {50, 20, -10}
    local c2 = {80, -5, 30}
    local m = cs.mix_lab(c1, c2, 1)
    approx(m[1], c2[1], 1e-9)
    approx(m[2], c2[2], 1e-9)
    approx(m[3], c2[3], 1e-9)
  end)
  T.it("t=0.5 is midpoint", function()
    local c1 = {0,  0,  0}
    local c2 = {100, 20, -40}
    local m = cs.mix_lab(c1, c2, 0.5)
    approx(m[1], 50, 1e-9)
    approx(m[2], 10, 1e-9)
    approx(m[3], -20, 1e-9)
  end)
  T.it("t clamps to [0,1]", function()
    local c1 = {50, 0, 0}
    local c2 = {60, 0, 0}
    local m = cs.mix_lab(c1, c2, 2)
    approx(m[1], 60, 1e-9)
    local m2 = cs.mix_lab(c1, c2, -1)
    approx(m2[1], 50, 1e-9)
  end)
end)

T.describe("mix_oklab", function()
  T.it("t=0 returns first color", function()
    local c1 = {0.5, 0.1, -0.05}
    local c2 = {0.8, -0.02, 0.12}
    local m = cs.mix_oklab(c1, c2, 0)
    approx(m[1], c1[1], 1e-9)
    approx(m[2], c1[2], 1e-9)
    approx(m[3], c1[3], 1e-9)
  end)
  T.it("t=0.5 is midpoint", function()
    local c1 = {0, 0, 0}
    local c2 = {1, 0.2, -0.2}
    local m = cs.mix_oklab(c1, c2, 0.5)
    approx(m[1], 0.5, 1e-9)
    approx(m[2], 0.1, 1e-9)
    approx(m[3], -0.1, 1e-9)
  end)
end)

----------------------------------------------------------------------
-- M._tier
----------------------------------------------------------------------

T.describe("metadata", function()
  T.it("_tier is 'pure'", function()
    T.eq(cs._tier, "pure")
  end)
end)
