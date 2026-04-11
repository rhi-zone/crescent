if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local color = require("lib.color")

-- Helper: check RGB within tolerance (rounding)
local function rgb_eq(c, er, eg, eb, msg)
  local r, g, b = c:to_rgb()
  T.eq(r, er, (msg or "") .. " R")
  T.eq(g, eg, (msg or "") .. " G")
  T.eq(b, eb, (msg or "") .. " B")
end

-- Helper: approximate float equality
local function approx(a, b, eps, msg)
  eps = eps or 0.5
  T.ok(math.abs(a - b) <= eps, (msg or "") .. ": expected ~" .. b .. ", got " .. a)
end

----------------------------------------------------------------------
T.describe("constructors", function()
----------------------------------------------------------------------

  T.it("rgb clamps and rounds", function()
    local c = color.rgb(255, 128, 0)
    rgb_eq(c, 255, 128, 0, "rgb")
  end)

  T.it("rgb clamps out-of-range", function()
    local c = color.rgb(300, -10, 128)
    rgb_eq(c, 255, 0, 128, "rgb clamp")
  end)

  T.it("rgb01 maps 0-1 to 0-255", function()
    local c = color.rgb01(1.0, 0.5, 0.0)
    rgb_eq(c, 255, 128, 0, "rgb01")
  end)

  T.it("rgb01 clamps", function()
    local c = color.rgb01(1.5, -0.5, 0.5)
    rgb_eq(c, 255, 0, 128, "rgb01 clamp")
  end)

  T.it("hsl creates correct color", function()
    -- red = hsl(0, 100, 50)
    local c = color.hsl(0, 100, 50)
    rgb_eq(c, 255, 0, 0, "hsl red")
  end)

  T.it("hsl green", function()
    local c = color.hsl(120, 100, 50)
    rgb_eq(c, 0, 255, 0, "hsl green")
  end)

  T.it("hsl blue", function()
    local c = color.hsl(240, 100, 50)
    rgb_eq(c, 0, 0, 255, "hsl blue")
  end)

  T.it("hsl white", function()
    local c = color.hsl(0, 0, 100)
    rgb_eq(c, 255, 255, 255, "hsl white")
  end)

  T.it("hsl black", function()
    local c = color.hsl(0, 0, 0)
    rgb_eq(c, 0, 0, 0, "hsl black")
  end)

  T.it("hsv creates correct color", function()
    local c = color.hsv(0, 100, 100)
    rgb_eq(c, 255, 0, 0, "hsv red")
  end)

  T.it("hsv green", function()
    local c = color.hsv(120, 100, 100)
    rgb_eq(c, 0, 255, 0, "hsv green")
  end)

  T.it("hsv blue", function()
    local c = color.hsv(240, 100, 100)
    rgb_eq(c, 0, 0, 255, "hsv blue")
  end)

  T.it("hex with #", function()
    local c = color.hex("#ff8000")
    rgb_eq(c, 255, 128, 0, "hex #")
  end)

  T.it("hex without #", function()
    local c = color.hex("ff8000")
    rgb_eq(c, 255, 128, 0, "hex no #")
  end)

  T.it("hex shorthand", function()
    local c = color.hex("#f80")
    rgb_eq(c, 255, 136, 0, "hex short")
  end)

  T.it("hex uppercase", function()
    local c = color.hex("#FF8000")
    rgb_eq(c, 255, 128, 0, "hex upper")
  end)

  T.it("hex black", function()
    local c = color.hex("#000000")
    rgb_eq(c, 0, 0, 0, "hex black")
  end)

  T.it("hex white", function()
    local c = color.hex("#ffffff")
    rgb_eq(c, 255, 255, 255, "hex white")
  end)

  T.it("named red", function()
    local c = color.named("red")
    rgb_eq(c, 255, 0, 0, "named red")
  end)

  T.it("named blue", function()
    local c = color.named("blue")
    rgb_eq(c, 0, 0, 255, "named blue")
  end)

  T.it("named is case insensitive", function()
    local c = color.named("Red")
    rgb_eq(c, 255, 0, 0, "named Red")
  end)

  T.it("named grey/gray", function()
    local c1 = color.named("gray")
    local c2 = color.named("grey")
    T.ok(c1:eq(c2), "gray == grey")
  end)

  T.it("named all 16 basic CSS colors exist", function()
    local names = {
      "black", "white", "red", "lime", "blue", "yellow", "cyan", "magenta",
      "maroon", "green", "navy", "olive", "purple", "teal", "silver", "gray",
    }
    for _, n in ipairs(names) do
      local c, err = color.named(n)
      T.ok(c, "named " .. n .. " exists: " .. tostring(err))
    end
  end)
end)

----------------------------------------------------------------------
T.describe("conversions", function()
----------------------------------------------------------------------

  T.it("to_rgb returns integers", function()
    local c = color.rgb(100, 150, 200)
    local r, g, b = c:to_rgb()
    T.eq(r, 100)
    T.eq(g, 150)
    T.eq(b, 200)
  end)

  T.it("to_rgb01 returns floats", function()
    local c = color.rgb(255, 0, 128)
    local r, g, b = c:to_rgb01()
    T.eq(r, 1.0)
    T.eq(g, 0.0)
    approx(b, 128/255, 0.001, "to_rgb01 blue")
  end)

  T.it("to_hsl for red", function()
    local c = color.rgb(255, 0, 0)
    local h, s, l = c:to_hsl()
    approx(h, 0, 0.1, "hsl h")
    approx(s, 100, 0.1, "hsl s")
    approx(l, 50, 0.1, "hsl l")
  end)

  T.it("to_hsl for gray", function()
    local c = color.rgb(128, 128, 128)
    local h, s, l = c:to_hsl()
    approx(h, 0, 0.1, "gray h")
    approx(s, 0, 0.1, "gray s")
    approx(l, 50, 1.0, "gray l")
  end)

  T.it("to_hsv for red", function()
    local c = color.rgb(255, 0, 0)
    local h, s, v = c:to_hsv()
    approx(h, 0, 0.1, "hsv h")
    approx(s, 100, 0.1, "hsv s")
    approx(v, 100, 0.1, "hsv v")
  end)

  T.it("to_hex returns lowercase", function()
    local c = color.rgb(255, 128, 0)
    T.eq(c:to_hex(), "#ff8000")
  end)

  T.it("to_hex for black", function()
    T.eq(color.rgb(0, 0, 0):to_hex(), "#000000")
  end)

  T.it("to_hex for white", function()
    T.eq(color.rgb(255, 255, 255):to_hex(), "#ffffff")
  end)

  T.it("to_array", function()
    local c = color.rgb(10, 20, 30)
    local a = c:to_array()
    T.eq(a[1], 10)
    T.eq(a[2], 20)
    T.eq(a[3], 30)
  end)

  T.it("RGB -> HSL -> RGB roundtrip", function()
    local c = color.rgb(123, 45, 67)
    local h, s, l = c:to_hsl()
    local c2 = color.hsl(h, s, l)
    local r, g, b = c2:to_rgb()
    local r0, g0, b0 = c:to_rgb()
    approx(r, r0, 1, "roundtrip R")
    approx(g, g0, 1, "roundtrip G")
    approx(b, b0, 1, "roundtrip B")
  end)

  T.it("RGB -> HSV -> RGB roundtrip", function()
    local c = color.rgb(200, 100, 50)
    local h, s, v = c:to_hsv()
    local c2 = color.hsv(h, s, v)
    local r, g, b = c2:to_rgb()
    local r0, g0, b0 = c:to_rgb()
    approx(r, r0, 1, "roundtrip R")
    approx(g, g0, 1, "roundtrip G")
    approx(b, b0, 1, "roundtrip B")
  end)

  T.it("hex roundtrip", function()
    local c = color.hex("#abcdef")
    T.eq(c:to_hex(), "#abcdef")
  end)
end)

----------------------------------------------------------------------
T.describe("manipulation", function()
----------------------------------------------------------------------

  T.it("lighten", function()
    local c = color.rgb(255, 0, 0)
    local lighter = c:lighten(0.2)
    local _, _, l0 = c:to_hsl()
    local _, _, l1 = lighter:to_hsl()
    T.ok(l1 > l0, "lighten increases lightness")
  end)

  T.it("darken", function()
    local c = color.rgb(255, 0, 0)
    local darker = c:darken(0.2)
    local _, _, l0 = c:to_hsl()
    local _, _, l1 = darker:to_hsl()
    T.ok(l1 < l0, "darken decreases lightness")
  end)

  T.it("lighten black by 1.0 gives white", function()
    local c = color.rgb(0, 0, 0):lighten(1.0)
    rgb_eq(c, 255, 255, 255, "lighten black")
  end)

  T.it("darken white by 0.5 gives gray", function()
    local c = color.rgb(255, 255, 255):darken(0.5)
    local _, _, l = c:to_hsl()
    approx(l, 50, 1, "darken white l")
  end)

  T.it("saturate", function()
    local c = color.hsl(0, 50, 50)
    local c2 = c:saturate(0.2)
    local _, s, _ = c2:to_hsl()
    approx(s, 70, 1, "saturate s")
  end)

  T.it("desaturate", function()
    local c = color.hsl(0, 50, 50)
    local c2 = c:desaturate(0.2)
    local _, s, _ = c2:to_hsl()
    approx(s, 30, 1, "desaturate s")
  end)

  T.it("rotate hue", function()
    local c = color.hsl(0, 100, 50)
    local c2 = c:rotate(120)
    local h, _, _ = c2:to_hsl()
    approx(h, 120, 1, "rotate h")
  end)

  T.it("rotate wraps around", function()
    local c = color.hsl(350, 100, 50)
    local c2 = c:rotate(20)
    local h, _, _ = c2:to_hsl()
    approx(h, 10, 1, "rotate wrap h")
  end)

  T.it("complement", function()
    local c = color.hsl(60, 100, 50)
    local c2 = c:complement()
    local h, _, _ = c2:to_hsl()
    approx(h, 240, 1, "complement h")
  end)

  T.it("invert", function()
    local c = color.rgb(255, 0, 128)
    local inv = c:invert()
    rgb_eq(inv, 0, 255, 127, "invert")
  end)

  T.it("invert black -> white", function()
    local c = color.rgb(0, 0, 0):invert()
    rgb_eq(c, 255, 255, 255, "invert black")
  end)

  T.it("invert white -> black", function()
    local c = color.rgb(255, 255, 255):invert()
    rgb_eq(c, 0, 0, 0, "invert white")
  end)

  T.it("grayscale", function()
    local c = color.rgb(255, 0, 0):grayscale()
    local _, s, _ = c:to_hsl()
    approx(s, 0, 0.1, "grayscale s")
  end)

  T.it("grayscale preserves lightness", function()
    local c = color.rgb(255, 0, 0)
    local g = c:grayscale()
    local _, _, l0 = c:to_hsl()
    local _, _, l1 = g:to_hsl()
    approx(l1, l0, 1, "grayscale l")
  end)

  T.it("alpha", function()
    local c = color.rgb(255, 0, 0)
    local c2 = c:alpha(0.5)
    T.eq(c2:get_alpha(), 0.5)
    rgb_eq(c2, 255, 0, 0, "alpha rgb unchanged")
  end)

  T.it("alpha clamps", function()
    local c = color.rgb(255, 0, 0):alpha(2.0)
    T.eq(c:get_alpha(), 1.0)
  end)

  T.it("mix 50/50", function()
    local c1 = color.rgb(0, 0, 0)
    local c2 = color.rgb(255, 255, 255)
    local mixed = c1:mix(c2, 0.5)
    rgb_eq(mixed, 128, 128, 128, "mix 50/50")
  end)

  T.it("mix 0 = self", function()
    local c1 = color.rgb(255, 0, 0)
    local c2 = color.rgb(0, 0, 255)
    local mixed = c1:mix(c2, 0)
    rgb_eq(mixed, 255, 0, 0, "mix 0")
  end)

  T.it("mix 1 = other", function()
    local c1 = color.rgb(255, 0, 0)
    local c2 = color.rgb(0, 0, 255)
    local mixed = c1:mix(c2, 1)
    rgb_eq(mixed, 0, 0, 255, "mix 1")
  end)

  T.it("manipulation preserves alpha", function()
    local c = color.rgb(255, 0, 0):alpha(0.5)
    T.eq(c:lighten(0.1):get_alpha(), 0.5)
    T.eq(c:darken(0.1):get_alpha(), 0.5)
    T.eq(c:saturate(0.1):get_alpha(), 0.5)
    T.eq(c:desaturate(0.1):get_alpha(), 0.5)
    T.eq(c:rotate(30):get_alpha(), 0.5)
    T.eq(c:complement():get_alpha(), 0.5)
    T.eq(c:invert():get_alpha(), 0.5)
    T.eq(c:grayscale():get_alpha(), 0.5)
  end)
end)

----------------------------------------------------------------------
T.describe("utilities", function()
----------------------------------------------------------------------

  T.it("luminance of white = 1", function()
    approx(color.luminance(color.rgb(255, 255, 255)), 1.0, 0.001, "white lum")
  end)

  T.it("luminance of black = 0", function()
    approx(color.luminance(color.rgb(0, 0, 0)), 0.0, 0.001, "black lum")
  end)

  T.it("contrast black/white = 21", function()
    local ratio = color.contrast(color.rgb(0, 0, 0), color.rgb(255, 255, 255))
    approx(ratio, 21, 0.1, "contrast bw")
  end)

  T.it("contrast same color = 1", function()
    local c = color.rgb(128, 128, 128)
    approx(color.contrast(c, c), 1.0, 0.01, "contrast same")
  end)

  T.it("contrast is symmetric", function()
    local c1 = color.rgb(255, 0, 0)
    local c2 = color.rgb(0, 0, 255)
    local r1 = color.contrast(c1, c2)
    local r2 = color.contrast(c2, c1)
    approx(r1, r2, 0.001, "contrast symmetric")
  end)

  T.it("distance same = 0", function()
    local c = color.rgb(100, 100, 100)
    approx(color.distance(c, c), 0, 0.001, "distance same")
  end)

  T.it("distance black/white", function()
    local d = color.distance(color.rgb(0, 0, 0), color.rgb(255, 255, 255))
    approx(d, math.sqrt(255*255*3), 0.1, "distance bw")
  end)

  T.it("is_light white", function()
    T.ok(color.is_light(color.rgb(255, 255, 255)))
  end)

  T.it("is_dark black", function()
    T.ok(color.is_dark(color.rgb(0, 0, 0)))
  end)

  T.it("is_light/is_dark are complementary", function()
    local c = color.rgb(200, 200, 200)
    T.ok(color.is_light(c) ~= color.is_dark(c), "complementary")
  end)

  T.it("palette complementary", function()
    local p = color.palette(color.hsl(0, 100, 50), "complementary")
    T.eq(#p, 2)
    local h, _, _ = p[2]:to_hsl()
    approx(h, 180, 1, "complement h")
  end)

  T.it("palette triadic", function()
    local p = color.palette(color.hsl(0, 100, 50), "triadic")
    T.eq(#p, 3)
    local h2, _, _ = p[2]:to_hsl()
    local h3, _, _ = p[3]:to_hsl()
    approx(h2, 120, 1, "triadic h2")
    approx(h3, 240, 1, "triadic h3")
  end)

  T.it("palette analogous", function()
    local p = color.palette(color.hsl(60, 100, 50), "analogous")
    T.eq(#p, 3)
    local h1, _, _ = p[1]:to_hsl()
    local h3, _, _ = p[3]:to_hsl()
    approx(h1, 30, 1, "analogous h1")
    approx(h3, 90, 1, "analogous h3")
  end)

  T.it("palette split_complementary", function()
    local p = color.palette(color.hsl(0, 100, 50), "split_complementary")
    T.eq(#p, 3)
    local h2, _, _ = p[2]:to_hsl()
    local h3, _, _ = p[3]:to_hsl()
    approx(h2, 150, 1, "split h2")
    approx(h3, 210, 1, "split h3")
  end)

  T.it("palette unknown kind returns nil", function()
    local p, err = color.palette(color.rgb(0,0,0), "unknown")
    T.eq(p, nil)
    T.ok(err, "error message")
  end)
end)

----------------------------------------------------------------------
T.describe("equality and tostring", function()
----------------------------------------------------------------------

  T.it("eq same color", function()
    local c1 = color.rgb(255, 128, 0)
    local c2 = color.rgb(255, 128, 0)
    T.ok(c1:eq(c2))
  end)

  T.it("eq different color", function()
    local c1 = color.rgb(255, 128, 0)
    local c2 = color.rgb(0, 128, 255)
    T.ok(not c1:eq(c2))
  end)

  T.it("__eq metamethod", function()
    local c1 = color.rgb(10, 20, 30)
    local c2 = color.rgb(10, 20, 30)
    T.ok(c1 == c2, "== works")
  end)

  T.it("tostring opaque", function()
    local c = color.rgb(255, 128, 0)
    T.eq(tostring(c), "#ff8000")
  end)

  T.it("tostring with alpha", function()
    local c = color.rgb(255, 0, 0):alpha(0.5)
    local s = tostring(c)
    T.ok(s:find("rgba"), "contains rgba")
  end)
end)

----------------------------------------------------------------------
T.describe("error cases", function()
----------------------------------------------------------------------

  T.it("hex invalid string", function()
    local c, err = color.hex("xyz")
    T.eq(c, nil)
    T.ok(err, "error message")
  end)

  T.it("hex wrong length", function()
    local c, err = color.hex("#12345")
    T.eq(c, nil)
    T.ok(err, "error message")
  end)

  T.it("hex non-string", function()
    local c, err = color.hex(123)
    T.eq(c, nil)
    T.ok(err, "error message")
  end)

  T.it("named unknown", function()
    local c, err = color.named("notacolor")
    T.eq(c, nil)
    T.ok(err, "error message")
  end)

  T.it("named non-string", function()
    local c, err = color.named(42)
    T.eq(c, nil)
    T.ok(err, "error message")
  end)
end)

----------------------------------------------------------------------
T.describe("edge cases", function()
----------------------------------------------------------------------

  T.it("hue wrapping negative", function()
    local c = color.hsl(0, 100, 50):rotate(-30)
    local h, _, _ = c:to_hsl()
    approx(h, 330, 1, "negative rotate")
  end)

  T.it("grayscale color has zero saturation in HSL", function()
    local c = color.rgb(128, 128, 128)
    local _, s, _ = c:to_hsl()
    approx(s, 0, 0.1, "gray saturation")
  end)

  T.it("grayscale color has zero saturation in HSV", function()
    local c = color.rgb(128, 128, 128)
    local _, s, _ = c:to_hsv()
    approx(s, 0, 0.1, "gray saturation hsv")
  end)

  T.it("mix preserves alpha", function()
    local c1 = color.rgb(0, 0, 0):alpha(0.0)
    local c2 = color.rgb(255, 255, 255):alpha(1.0)
    local mixed = c1:mix(c2, 0.5)
    approx(mixed:get_alpha(), 0.5, 0.01, "mix alpha")
  end)

  T.it("hex with alpha", function()
    local c = color.hex("#ff000080")
    rgb_eq(c, 255, 0, 0, "hex alpha rgb")
    approx(c:get_alpha(), 128/255, 0.01, "hex alpha value")
  end)
end)
