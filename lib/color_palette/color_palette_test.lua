if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local cp = require("lib.color_palette")

local function approx(a, b, eps)
  eps = eps or 1e-4
  return math.abs(a - b) < eps
end

local function color_approx(c1, c2, eps)
  eps = eps or 0.01
  return approx(c1.r, c2.r, eps) and approx(c1.g, c2.g, eps) and approx(c1.b, c2.b, eps)
end

----------------------------------------------------------------------
T.describe("hex parsing", function()
  T.it("parses #rrggbb", function()
    local c = cp.hex("#ff8000")
    T.ok(approx(c.r, 1.0, 0.01), "r")
    T.ok(approx(c.g, 0.502, 0.01), "g")
    T.ok(approx(c.b, 0.0, 0.01), "b")
  end)

  T.it("parses #rgb shorthand", function()
    local c = cp.hex("#f80")
    T.ok(approx(c.r, 1.0, 0.01), "r")
    T.ok(approx(c.g, 0.533, 0.01), "g")
    T.ok(approx(c.b, 0.0, 0.01), "b")
  end)

  T.it("returns nil on invalid input", function()
    local c, err = cp.hex("not_a_color")
    T.eq(c, nil)
    T.ok(type(err) == "string", "error message")
  end)
end)

----------------------------------------------------------------------
T.describe("to_hex output", function()
  T.it("formats #rrggbb correctly", function()
    T.eq(cp.to_hex(cp.rgb(1, 0, 0)), "#ff0000")
    T.eq(cp.to_hex(cp.rgb(0, 0, 1)), "#0000ff")
    T.eq(cp.to_hex(cp.rgb(0, 0, 0)), "#000000")
    T.eq(cp.to_hex(cp.rgb(1, 1, 1)), "#ffffff")
  end)
end)

----------------------------------------------------------------------
T.describe("rgb/hsl round-trip", function()
  T.it("rgb → to_hsl → hsl → rgb stays the same", function()
    local orig = cp.rgb(0.2, 0.6, 0.9)
    local hsl  = cp.to_hsl(orig)
    local back = cp.hsl(hsl.h, hsl.s, hsl.l)
    T.ok(color_approx(orig, back, 0.01), "round-trip mismatch")
  end)

  T.it("gray has zero saturation", function()
    local g = cp.rgb(0.5, 0.5, 0.5)
    local hsl = cp.to_hsl(g)
    T.ok(approx(hsl.s, 0, 0.01), "saturation should be 0")
  end)
end)

----------------------------------------------------------------------
T.describe("complementary", function()
  T.it("shifts hue by 0.5 (180°)", function()
    local base = cp.hsl(0.0, 1.0, 0.5)  -- red
    local comp = cp.complementary(base)
    local hsl = cp.to_hsl(comp)
    T.ok(approx(hsl.h, 0.5, 0.02), "complementary hue should be ~0.5")
  end)
end)

----------------------------------------------------------------------
T.describe("triadic", function()
  T.it("returns 3 colors 120° apart", function()
    local base = cp.hsl(0.0, 1.0, 0.5)
    local triad = cp.triadic(base)
    T.eq(#triad, 3)
    local h0 = cp.to_hsl(triad[1]).h
    local h1 = cp.to_hsl(triad[2]).h
    local h2 = cp.to_hsl(triad[3]).h
    T.ok(approx((h1 - h0 + 1) % 1, 1/3, 0.02), "second color +1/3")
    T.ok(approx((h2 - h0 + 1) % 1, 2/3, 0.02), "third color +2/3")
  end)
end)

----------------------------------------------------------------------
T.describe("analogous", function()
  T.it("returns n colors", function()
    local base = cp.hsl(0.5, 0.8, 0.5)
    local analog = cp.analogous(base, { n = 5, step = 30 })
    T.eq(#analog, 5)
  end)

  T.it("colors are within step range of base", function()
    local base = cp.hsl(0.5, 0.8, 0.5)
    local step = 30
    local analog = cp.analogous(base, { n = 5, step = step })
    local base_h = cp.to_hsl(base).h
    for _, c in ipairs(analog) do
      local h = cp.to_hsl(c).h
      local diff = math.abs(((h - base_h + 0.5) % 1) - 0.5) * 360
      T.ok(diff <= step * 2 + 1, "hue within 2*step of base")
    end
  end)
end)

----------------------------------------------------------------------
T.describe("monochromatic", function()
  T.it("returns n colors with same hue", function()
    local base = cp.hsl(0.3, 0.7, 0.5)
    local mono = cp.monochromatic(base, { n = 5 })
    T.eq(#mono, 5)
    local base_h = cp.to_hsl(base).h
    for _, c in ipairs(mono) do
      local h = cp.to_hsl(c).h
      -- gray (s=0) hue is undefined; skip pure black/white
      local hsl = cp.to_hsl(c)
      if hsl.s > 0.01 then
        T.ok(approx(h, base_h, 0.05), "hue preserved")
      end
    end
  end)

  T.it("spans from dark to light", function()
    local base = cp.hsl(0.3, 0.7, 0.5)
    local mono = cp.monochromatic(base, { n = 5 })
    local l0 = cp.to_hsl(mono[1]).l
    local l4 = cp.to_hsl(mono[5]).l
    T.ok(l4 > l0, "last is lighter than first")
  end)
end)

----------------------------------------------------------------------
T.describe("tints", function()
  T.it("returns n steps toward white", function()
    local base = cp.rgb(1, 0, 0)
    local t = cp.tints(base, 5)
    T.eq(#t, 5)
    -- first is original color
    T.ok(color_approx(t[1], base, 0.01), "first is base")
    -- last is white
    T.ok(color_approx(t[5], cp.rgb(1, 1, 1), 0.01), "last is white")
  end)
end)

----------------------------------------------------------------------
T.describe("shades", function()
  T.it("returns n steps toward black", function()
    local base = cp.rgb(1, 0, 0)
    local s = cp.shades(base, 5)
    T.eq(#s, 5)
    T.ok(color_approx(s[1], base, 0.01), "first is base")
    T.ok(color_approx(s[5], cp.rgb(0, 0, 0), 0.01), "last is black")
  end)
end)

----------------------------------------------------------------------
T.describe("gradient", function()
  T.it("returns n interpolated colors", function()
    local c1 = cp.rgb(0, 0, 0)
    local c2 = cp.rgb(1, 1, 1)
    local grad = cp.gradient(c1, c2, 5)
    T.eq(#grad, 5)
    T.ok(color_approx(grad[1], c1, 0.01), "first is c1")
    T.ok(color_approx(grad[5], c2, 0.01), "last is c2")
    T.ok(color_approx(grad[3], cp.rgb(0.5, 0.5, 0.5), 0.01), "midpoint is gray")
  end)
end)

----------------------------------------------------------------------
T.describe("contrast_ratio", function()
  T.it("white on black is ~21:1", function()
    local white = cp.rgb(1, 1, 1)
    local black = cp.rgb(0, 0, 0)
    local ratio = cp.contrast_ratio(white, black)
    T.ok(approx(ratio, 21.0, 0.1), "white/black ~21:1, got " .. ratio)
  end)

  T.it("same color is 1:1", function()
    local c = cp.rgb(0.5, 0.3, 0.7)
    local ratio = cp.contrast_ratio(c, c)
    T.ok(approx(ratio, 1.0, 0.01), "same color ratio ~1")
  end)
end)

----------------------------------------------------------------------
T.describe("check_contrast", function()
  T.it("white/black passes AA (4.5:1)", function()
    local white = cp.rgb(1, 1, 1)
    local black = cp.rgb(0, 0, 0)
    T.ok(cp.check_contrast(white, black, "AA"), "white/black passes AA")
  end)

  T.it("white/black passes AAA (7:1)", function()
    local white = cp.rgb(1, 1, 1)
    local black = cp.rgb(0, 0, 0)
    T.ok(cp.check_contrast(white, black, "AAA"), "white/black passes AAA")
  end)

  T.it("low contrast fails AA", function()
    local c1 = cp.rgb(0.9, 0.9, 0.9)
    local c2 = cp.rgb(0.8, 0.8, 0.8)
    T.ok(not cp.check_contrast(c1, c2, "AA"), "low contrast fails AA")
  end)
end)

----------------------------------------------------------------------
T.describe("best_foreground", function()
  T.it("picks white on dark background", function()
    local bg    = cp.rgb(0.1, 0.1, 0.1)
    local white = cp.rgb(1, 1, 1)
    local black = cp.rgb(0, 0, 0)
    local best  = cp.best_foreground(bg, { white, black })
    T.ok(color_approx(best, white, 0.01), "white has higher contrast on dark bg")
  end)

  T.it("picks black on light background", function()
    local bg    = cp.rgb(0.9, 0.9, 0.9)
    local white = cp.rgb(1, 1, 1)
    local black = cp.rgb(0, 0, 0)
    local best  = cp.best_foreground(bg, { white, black })
    T.ok(color_approx(best, black, 0.01), "black has higher contrast on light bg")
  end)
end)

----------------------------------------------------------------------
T.describe("distance euclidean", function()
  T.it("same color = 0", function()
    local c = cp.rgb(0.4, 0.5, 0.6)
    T.ok(approx(cp.distance(c, c, "euclidean"), 0, 1e-9), "same color distance 0")
  end)

  T.it("black to white = sqrt(3)", function()
    local d = cp.distance(cp.rgb(0,0,0), cp.rgb(1,1,1), "euclidean")
    T.ok(approx(d, math.sqrt(3), 0.001), "black-white distance sqrt(3)")
  end)
end)

----------------------------------------------------------------------
T.describe("nearest", function()
  T.it("finds closest color in palette", function()
    local target  = cp.rgb(0.9, 0.1, 0.1)
    local palette = {
      cp.rgb(1, 0, 0),
      cp.rgb(0, 1, 0),
      cp.rgb(0, 0, 1),
    }
    local found = cp.nearest(target, palette)
    T.ok(color_approx(found, cp.rgb(1, 0, 0), 0.01), "nearest is red")
  end)
end)

----------------------------------------------------------------------
T.describe("sort by hue", function()
  T.it("orders colors by ascending hue", function()
    local red   = cp.hsl(0.0,  1, 0.5)
    local green = cp.hsl(0.33, 1, 0.5)
    local blue  = cp.hsl(0.67, 1, 0.5)
    local sorted = cp.sort({ blue, red, green }, "hue")
    T.eq(#sorted, 3)
    local h0 = cp.to_hsl(sorted[1]).h
    local h1 = cp.to_hsl(sorted[2]).h
    local h2 = cp.to_hsl(sorted[3]).h
    T.ok(h0 <= h1 and h1 <= h2, "sorted ascending by hue")
  end)
end)

----------------------------------------------------------------------
T.describe("deduplicate", function()
  T.it("removes near-duplicates", function()
    local red1  = cp.rgb(1.0, 0.0, 0.0)
    local red2  = cp.rgb(0.99, 0.01, 0.0)  -- very close to red1
    local blue  = cp.rgb(0.0, 0.0, 1.0)
    local result = cp.deduplicate({ red1, red2, blue }, 0.05)
    T.eq(#result, 2, "only 2 distinct colors")
  end)

  T.it("keeps distinct colors", function()
    local red  = cp.rgb(1, 0, 0)
    local blue = cp.rgb(0, 0, 1)
    local result = cp.deduplicate({ red, blue }, 0.05)
    T.eq(#result, 2, "both kept")
  end)
end)

----------------------------------------------------------------------
T.describe("quantize", function()
  T.it("returns n colors", function()
    local pixels = {}
    for i = 1, 100 do
      pixels[i] = { r = (i % 10) / 10, g = ((i * 3) % 10) / 10, b = ((i * 7) % 10) / 10 }
    end
    local result = cp.quantize(pixels, 5)
    T.ok(#result <= 5, "at most n colors")
    T.ok(#result >= 1, "at least 1 color")
  end)

  T.it("handles single color cluster", function()
    local pixels = {}
    for i = 1, 20 do
      pixels[i] = { r = 1, g = 0, b = 0 }
    end
    local result = cp.quantize(pixels, 3)
    T.ok(#result >= 1, "at least 1 result")
    -- Average of all-red should be red
    T.ok(approx(result[1].r, 1, 0.01), "quantized to red")
  end)
end)

----------------------------------------------------------------------
T.describe("to_hex_list", function()
  T.it("produces correct format", function()
    local palette = { cp.rgb(1, 0, 0), cp.rgb(0, 0, 1) }
    local list = cp.to_hex_list(palette)
    T.eq(#list, 2)
    T.eq(list[1], "#ff0000")
    T.eq(list[2], "#0000ff")
  end)
end)

----------------------------------------------------------------------
T.describe("to_css_vars", function()
  T.it("produces correct CSS custom properties", function()
    local palette = { cp.rgb(1, 0, 0), cp.rgb(0, 0, 1) }
    local css = cp.to_css_vars(palette, "color")
    T.ok(css:find("%-%-color%-0: #ff0000;"), "--color-0 line")
    T.ok(css:find("%-%-color%-1: #0000ff;"), "--color-1 line")
  end)

  T.it("defaults prefix to 'color'", function()
    local palette = { cp.rgb(0, 1, 0) }
    local css = cp.to_css_vars(palette)
    T.ok(css:find("%-%-color%-0:"), "default prefix")
  end)
end)

----------------------------------------------------------------------
T.describe("preset palettes", function()
  T.it("material_red has 9 shades", function()
    T.eq(#cp.palettes.material_red, 9)
  end)

  T.it("tailwind_blue has 9 shades", function()
    T.eq(#cp.palettes.tailwind_blue, 9)
  end)

  T.it("all preset colors are valid (r,g,b in [0,1])", function()
    local all = {}
    for _, pal in pairs(cp.palettes) do
      for _, c in ipairs(pal) do all[#all+1] = c end
    end
    for _, c in ipairs(all) do
      T.ok(c.r >= 0 and c.r <= 1, "r in range")
      T.ok(c.g >= 0 and c.g <= 1, "g in range")
      T.ok(c.b >= 0 and c.b <= 1, "b in range")
    end
  end)
end)
