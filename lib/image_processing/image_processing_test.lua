if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local M = require("lib.image_processing")

local function abs(x) return x < 0 and -x or x end

-- ──────────────────────────────────────────────────────────────────
-- Construction and basic access
-- ──────────────────────────────────────────────────────────────────

T.describe("image_processing.new", function()
  T.it("creates a zero-filled image by default", function()
    local img = M.new(4, 3, 3)
    T.eq(img.width, 4)
    T.eq(img.height, 3)
    T.eq(img.channels, 3)
    T.eq(#img.data, 4 * 3 * 3)
    T.eq(img.data[1], 0)
  end)

  T.it("returns nil,err when args missing", function()
    local img, err = M.new(nil, 3, 3)
    T.eq(img, nil)
    T.ok(err)
  end)
end)

T.describe("from_bytes / to_bytes", function()
  T.it("round-trips a 2x2 RGB image", function()
    local bytes = string.char(
      10, 20, 30,   40, 50, 60,
      70, 80, 90,  100,110,120
    )
    local img = M.from_bytes(2, 2, 3, bytes)
    T.eq(img.width, 2)
    T.eq(img.height, 2)
    T.eq(img.channels, 3)
    T.eq(img:to_bytes(), bytes)
  end)

  T.it("returns nil,err if byte_string is not a string", function()
    local img, err = M.from_bytes(2, 2, 3, {1,2,3})
    T.eq(img, nil)
    T.ok(err)
  end)
end)

T.describe("get / set", function()
  T.it("get returns correct pixel components", function()
    local img = M.new(3, 3, 3)
    img.data[1+3] = 100   -- pixel (2,1): red channel
    img.data[2+3] = 150   -- pixel (2,1): green channel
    img.data[3+3] = 200   -- pixel (2,1): blue channel
    local r, g, b = img:get(2, 1)
    T.eq(r, 100)
    T.eq(g, 150)
    T.eq(b, 200)
  end)

  T.it("set writes correct pixel", function()
    local img = M.new(3, 3, 3)
    img:set(2, 3, 11, 22, 33)
    local r, g, b = img:get(2, 3)
    T.eq(r, 11)
    T.eq(g, 22)
    T.eq(b, 33)
  end)

  T.it("get returns nil,err out of bounds", function()
    local img = M.new(3, 3, 3)
    local v, err = img:get(0, 1)
    T.eq(v, nil)
    T.ok(err)
  end)

  T.it("set returns nil,err out of bounds", function()
    local img = M.new(3, 3, 3)
    local v, err = img:set(4, 1, 1, 2, 3)
    T.eq(v, nil)
    T.ok(err)
  end)

  T.it("RGBA get includes alpha", function()
    local img = M.new(2, 2, 4)
    img:set(1, 1, 10, 20, 30, 128)
    local r, g, b, a = img:get(1, 1)
    T.eq(r, 10)
    T.eq(g, 20)
    T.eq(b, 30)
    T.eq(a, 128)
  end)
end)

-- ──────────────────────────────────────────────────────────────────
-- Color space
-- ──────────────────────────────────────────────────────────────────

T.describe("rgb_to_grayscale", function()
  T.it("converts 3-channel image to 1-channel", function()
    local img = M.new(2, 2, 3)
    img:set(1, 1, 255, 0, 0)
    img:set(2, 1, 0, 255, 0)
    img:set(1, 2, 0, 0, 255)
    img:set(2, 2, 128, 128, 128)
    local gray = M.rgb_to_grayscale(img)
    T.eq(gray.channels, 1)
    T.eq(gray.width, 2)
    T.eq(gray.height, 2)
    -- white pixel should be brighter than blue pixel
    local r1 = gray:get(1, 1)  -- red heavy
    local g1 = gray:get(2, 1)  -- green heavy
    local b1 = gray:get(1, 2)  -- blue heavy
    -- Rec.709 coefficients: R=0.2126, G=0.7152, B=0.0722
    T.ok(g1 > r1, "green channel brighter than red in grayscale")
    T.ok(r1 > b1, "red channel brighter than blue in grayscale")
  end)

  T.it("1-channel input passes through", function()
    local img = M.new(2, 2, 1)
    img.data = {10, 20, 30, 40}
    local gray = M.rgb_to_grayscale(img)
    T.eq(gray.data[1], 10)
    T.eq(gray.data[4], 40)
  end)
end)

T.describe("grayscale_to_rgb", function()
  T.it("expands 1-channel to 3-channel", function()
    local img = M.new(2, 1, 1)
    img.data = {100, 200}
    local rgb = M.grayscale_to_rgb(img)
    T.eq(rgb.channels, 3)
    local r, g, b = rgb:get(1, 1)
    T.eq(r, 100)
    T.eq(g, 100)
    T.eq(b, 100)
    r, g, b = rgb:get(2, 1)
    T.eq(r, 200)
    T.eq(g, 200)
    T.eq(b, 200)
  end)

  T.it("returns nil,err for non-grayscale input", function()
    local img = M.new(2, 2, 3)
    local out, err = M.grayscale_to_rgb(img)
    T.eq(out, nil)
    T.ok(err)
  end)
end)

T.describe("rgb_to_hsv / hsv_to_rgb round-trip", function()
  T.it("round-trips red", function()
    local h, s, v = M.rgb_to_hsv(255, 0, 0)
    T.ok(abs(h - 0) < 1 or abs(h - 360) < 1, "hue ~0 for red")
    T.ok(abs(s - 1) < 0.01, "saturation ~1")
    T.ok(abs(v - 1) < 0.01, "value ~1")
    local r, g, b = M.hsv_to_rgb(h, s, v)
    T.ok(abs(r - 255) <= 1)
    T.ok(abs(g - 0)   <= 1)
    T.ok(abs(b - 0)   <= 1)
  end)

  T.it("round-trips green", function()
    local h, s, v = M.rgb_to_hsv(0, 255, 0)
    T.ok(abs(h - 120) < 1)
    local r, g, b = M.hsv_to_rgb(h, s, v)
    T.ok(abs(r - 0)   <= 1)
    T.ok(abs(g - 255) <= 1)
    T.ok(abs(b - 0)   <= 1)
  end)

  T.it("round-trips blue", function()
    local h, s, v = M.rgb_to_hsv(0, 0, 255)
    T.ok(abs(h - 240) < 1)
    local r, g, b = M.hsv_to_rgb(h, s, v)
    T.ok(abs(r - 0)   <= 1)
    T.ok(abs(g - 0)   <= 1)
    T.ok(abs(b - 255) <= 1)
  end)

  T.it("round-trips gray (zero saturation)", function()
    local h, s, v = M.rgb_to_hsv(128, 128, 128)
    T.ok(abs(s) < 0.01)
    local r, g, b = M.hsv_to_rgb(h, s, v)
    T.ok(abs(r - 128) <= 1)
    T.ok(abs(g - 128) <= 1)
    T.ok(abs(b - 128) <= 1)
  end)
end)

-- ──────────────────────────────────────────────────────────────────
-- Pixel-level operations
-- ──────────────────────────────────────────────────────────────────

T.describe("brightness", function()
  T.it("adds delta to all channels", function()
    local img = M.new(2, 1, 3)
    img:set(1, 1, 100, 100, 100)
    img:set(2, 1, 200, 200, 200)
    local out = M.brightness(img, 50)
    local r, g, b = out:get(1, 1)
    T.eq(r, 150)
    T.eq(g, 150)
    T.eq(b, 150)
  end)

  T.it("clamps to 0-255", function()
    local img = M.new(1, 1, 3)
    img:set(1, 1, 250, 10, 250)
    local out = M.brightness(img, 50)
    local r, g, b = out:get(1, 1)
    T.eq(r, 255)
    T.eq(g, 60)
    T.eq(b, 255)
  end)

  T.it("negative delta darkens", function()
    local img = M.new(1, 1, 1)
    img.data[1] = 50
    local out = M.brightness(img, -100)
    T.eq(out.data[1], 0)
  end)
end)

T.describe("contrast", function()
  T.it("increases contrast above 128", function()
    local img = M.new(1, 1, 1)
    img.data[1] = 200
    local out = M.contrast(img, 2)
    -- (200-128)*2+128 = 272 → 255
    T.eq(out.data[1], 255)
  end)

  T.it("decreases contrast below 128", function()
    local img = M.new(1, 1, 1)
    img.data[1] = 50
    local out = M.contrast(img, 0.5)
    -- (50-128)*0.5+128 = 89
    T.eq(out.data[1], 89)
  end)
end)

T.describe("invert", function()
  T.it("inverts all channels", function()
    local img = M.new(1, 1, 3)
    img:set(1, 1, 0, 128, 255)
    local out = M.invert(img)
    local r, g, b = out:get(1, 1)
    T.eq(r, 255)
    T.eq(g, 127)
    T.eq(b, 0)
  end)

  T.it("preserves alpha for RGBA", function()
    local img = M.new(1, 1, 4)
    img:set(1, 1, 0, 0, 0, 200)
    local out = M.invert(img)
    local r, g, b, a = out:get(1, 1)
    T.eq(r, 255)
    T.eq(g, 255)
    T.eq(b, 255)
    T.eq(a, 200)
  end)
end)

T.describe("threshold", function()
  T.it("binarizes grayscale image", function()
    local img = M.new(4, 1, 1)
    img.data = {50, 127, 128, 200}
    local out = M.threshold(img, 128)
    T.eq(out.data[1], 0)
    T.eq(out.data[2], 0)
    T.eq(out.data[3], 255)
    T.eq(out.data[4], 255)
  end)

  T.it("returns nil,err for non-grayscale", function()
    local img = M.new(2, 2, 3)
    local out, err = M.threshold(img, 128)
    T.eq(out, nil)
    T.ok(err)
  end)
end)

T.describe("gamma", function()
  T.it("gamma=1 is identity", function()
    local img = M.new(1, 1, 1)
    img.data[1] = 128
    local out = M.gamma(img, 1)
    T.eq(out.data[1], 128)
  end)

  T.it("gamma<1 darkens midtones (inv_g > 1)", function()
    local img = M.new(1, 1, 1)
    img.data[1] = 128
    local out = M.gamma(img, 0.5)
    -- inv_g = 1/0.5 = 2; (128/255)^2 * 255 ≈ 64
    T.ok(out.data[1] < 128, "gamma<1 should darken midtones, got " .. tostring(out.data[1]))
  end)

  T.it("gamma>1 brightens midtones (inv_g < 1)", function()
    local img = M.new(1, 1, 1)
    img.data[1] = 128
    local out = M.gamma(img, 2)
    -- inv_g = 0.5; (128/255)^0.5 * 255 ≈ 181
    T.ok(out.data[1] > 128, "gamma>1 should brighten midtones, got " .. tostring(out.data[1]))
  end)

  T.it("black and white are invariant", function()
    local img = M.new(1, 2, 1)
    img.data = {0, 255}
    local out = M.gamma(img, 2.2)
    T.eq(out.data[1], 0)
    T.eq(out.data[2], 255)
  end)
end)

-- ──────────────────────────────────────────────────────────────────
-- Geometric transforms
-- ──────────────────────────────────────────────────────────────────

T.describe("crop", function()
  T.it("returns correct size", function()
    local img = M.new(10, 10, 3)
    local out = M.crop(img, 2, 3, 6, 8)
    T.eq(out.width, 5)
    T.eq(out.height, 6)
  end)

  T.it("copies correct pixels", function()
    -- 4x4 grayscale, filled with y*10+x
    local img = M.new(4, 4, 1)
    for y = 1, 4 do
      for x = 1, 4 do
        img:set(x, y, y * 10 + x)
      end
    end
    local out = M.crop(img, 2, 2, 3, 3)
    T.eq(out.width, 2)
    T.eq(out.height, 2)
    T.eq(out:get(1, 1), 22)
    T.eq(out:get(2, 1), 23)
    T.eq(out:get(1, 2), 32)
    T.eq(out:get(2, 2), 33)
  end)

  T.it("returns nil,err out of bounds", function()
    local img = M.new(4, 4, 1)
    local out, err = M.crop(img, 0, 1, 3, 3)
    T.eq(out, nil)
    T.ok(err)
  end)
end)

T.describe("flip_h", function()
  T.it("mirrors pixel positions horizontally", function()
    local img = M.new(3, 2, 1)
    for y = 1, 2 do
      for x = 1, 3 do
        img:set(x, y, x * 10 + y)
      end
    end
    local out = M.flip_h(img)
    -- original (1,1) = 11, should now be at (3,1)
    T.eq(out:get(3, 1), 11)
    T.eq(out:get(2, 1), 21)
    T.eq(out:get(1, 1), 31)
  end)
end)

T.describe("flip_v", function()
  T.it("mirrors pixel positions vertically", function()
    local img = M.new(2, 3, 1)
    for y = 1, 3 do
      for x = 1, 2 do
        img:set(x, y, y * 10 + x)
      end
    end
    local out = M.flip_v(img)
    -- original row 1 should now be row 3
    T.eq(out:get(1, 3), 11)
    T.eq(out:get(2, 3), 12)
    T.eq(out:get(1, 1), 31)
  end)
end)

T.describe("rotate_90", function()
  T.it("n=0 is identity", function()
    local img = M.new(3, 2, 1)
    for y = 1, 2 do
      for x = 1, 3 do
        img:set(x, y, y * 10 + x)
      end
    end
    local out = M.rotate_90(img, 0)
    T.eq(out.width, 3)
    T.eq(out.height, 2)
    T.eq(out:get(1, 1), 11)
    T.eq(out:get(3, 2), 23)
  end)

  T.it("n=1 rotates clockwise: width and height swap", function()
    local img = M.new(4, 3, 1)
    local out = M.rotate_90(img, 1)
    T.eq(out.width, 3)
    T.eq(out.height, 4)
  end)

  T.it("n=2 is 180-degree rotation", function()
    local img = M.new(3, 2, 1)
    for y = 1, 2 do
      for x = 1, 3 do
        img:set(x, y, y * 10 + x)
      end
    end
    local out = M.rotate_90(img, 2)
    -- top-left corner should be old bottom-right
    T.eq(out:get(1, 1), 23)
    T.eq(out:get(3, 2), 11)
  end)

  T.it("n=4 is identity", function()
    local img = M.new(3, 2, 1)
    for y = 1, 2 do
      for x = 1, 3 do
        img:set(x, y, y * 10 + x)
      end
    end
    local out = M.rotate_90(img, 4)
    T.eq(out:get(1, 1), 11)
    T.eq(out:get(3, 2), 23)
  end)
end)

T.describe("scale_nearest", function()
  T.it("returns correct output size", function()
    local img = M.new(4, 4, 3)
    local out = M.scale_nearest(img, 8, 6)
    T.eq(out.width, 8)
    T.eq(out.height, 6)
    T.eq(out.channels, 3)
  end)

  T.it("top-left pixel is preserved", function()
    local img = M.new(4, 4, 1)
    img:set(1, 1, 77)
    local out = M.scale_nearest(img, 8, 8)
    T.eq(out:get(1, 1), 77)
  end)

  T.it("spot-check scaled pixel value", function()
    -- 2x2 image: all same color
    local img = M.new(2, 2, 1)
    img.data = {99, 99, 99, 99}
    local out = M.scale_nearest(img, 4, 4)
    T.eq(out:get(3, 3), 99)
  end)
end)

-- ──────────────────────────────────────────────────────────────────
-- Convolution / filters
-- ──────────────────────────────────────────────────────────────────

T.describe("blur_box", function()
  T.it("output has same size as input", function()
    local img = M.new(10, 8, 3)
    local out = M.blur_box(img, 1)
    T.eq(out.width, 10)
    T.eq(out.height, 8)
    T.eq(out.channels, 3)
  end)

  T.it("bright center pixel is blurred toward surrounding dark pixels", function()
    -- 5x5 black image with one bright white center pixel
    local img = M.new(5, 5, 1)
    img:set(3, 3, 255)
    local out = M.blur_box(img, 1)
    local before = 255
    local after = out:get(3, 3)
    T.ok(after < before, "center pixel should be dimmer after box blur, got " .. tostring(after))
  end)
end)

T.describe("edge_detect", function()
  T.it("finds edges in gradient image", function()
    -- 5x5 image: left half black, right half white
    local img = M.new(10, 5, 1)
    for y = 1, 5 do
      for x = 1, 10 do
        img:set(x, y, x <= 5 and 0 or 255)
      end
    end
    local out = M.edge_detect(img)
    T.eq(out.channels, 1)
    -- pixels near the edge (x=5 or x=6) should have high magnitude
    local edge_val = out:get(5, 3)
    local non_edge_val = out:get(1, 3)
    T.ok(edge_val > non_edge_val, "edge pixel should have higher magnitude than non-edge")
  end)
end)

-- ──────────────────────────────────────────────────────────────────
-- Histogram
-- ──────────────────────────────────────────────────────────────────

T.describe("histogram", function()
  T.it("counts sum to width*height for grayscale", function()
    local img = M.new(4, 4, 1)
    -- fill with various values
    for i = 1, 16 do img.data[i] = (i * 16) % 256 end
    local hist = M.histogram(img)
    local total = 0
    for i = 0, 255 do total = total + (hist[i] or 0) end
    T.eq(total, 16)
  end)

  T.it("returns correct bin for known pixel value", function()
    local img = M.new(3, 1, 1)
    img.data = {100, 100, 200}
    local hist = M.histogram(img)
    T.eq(hist[100], 2)
    T.eq(hist[200], 1)
    T.eq(hist[0], 0)
  end)

  T.it("returns per-channel histograms for RGB", function()
    local img = M.new(2, 1, 3)
    img:set(1, 1, 10, 20, 30)
    img:set(2, 1, 10, 20, 30)
    local hists = M.histogram(img)
    T.eq(type(hists), "table")
    T.eq(hists[1][10], 2)
    T.eq(hists[2][20], 2)
    T.eq(hists[3][30], 2)
  end)
end)

T.describe("equalize", function()
  T.it("output has same dimensions", function()
    local img = M.new(8, 8, 1)
    for i = 1, 64 do img.data[i] = i % 64 end
    local out = M.equalize(img)
    T.eq(out.width, 8)
    T.eq(out.height, 8)
  end)

  T.it("spreads histogram more uniformly", function()
    -- Image with all pixels in range [0, 63] — low contrast
    local img = M.new(16, 1, 1)
    for i = 1, 16 do img.data[i] = (i - 1) * 4 end  -- 0,4,8,...,60
    local out = M.equalize(img)
    -- After equalization the range should be wider: min should be 0, max should be 255
    local mn, mx = 255, 0
    for i = 1, 16 do
      if out.data[i] < mn then mn = out.data[i] end
      if out.data[i] > mx then mx = out.data[i] end
    end
    T.ok(mx > 200, "equalized max should be near 255, got " .. tostring(mx))
  end)
end)

-- ──────────────────────────────────────────────────────────────────
-- Drawing
-- ──────────────────────────────────────────────────────────────────

T.describe("fill", function()
  T.it("fills entire image with a color", function()
    local img = M.new(3, 3, 3)
    local out = M.fill(img, 100, 150, 200)
    for y = 1, 3 do
      for x = 1, 3 do
        local r, g, b = out:get(x, y)
        T.eq(r, 100)
        T.eq(g, 150)
        T.eq(b, 200)
      end
    end
  end)
end)

T.describe("draw_rect", function()
  T.it("draws an outline rectangle", function()
    local img = M.new(5, 5, 3)
    local out = M.draw_rect(img, 2, 2, 4, 4, 255, 0, 0)
    -- corners should be red
    local r, g, b = out:get(2, 2)
    T.eq(r, 255)
    T.eq(g, 0)
    T.eq(b, 0)
    -- interior center should NOT be red
    r, g, b = out:get(3, 3)
    T.eq(r, 0)
    T.eq(g, 0)
    T.eq(b, 0)
  end)
end)

T.describe("fill_rect", function()
  T.it("fills a rectangle", function()
    local img = M.new(5, 5, 3)
    local out = M.fill_rect(img, 2, 2, 4, 4, 0, 255, 0)
    -- interior center should be green
    local r, g, b = out:get(3, 3)
    T.eq(r, 0)
    T.eq(g, 255)
    T.eq(b, 0)
    -- outside should be black
    r, g, b = out:get(1, 1)
    T.eq(r, 0)
    T.eq(g, 0)
    T.eq(b, 0)
  end)
end)

T.describe("apply_lut", function()
  T.it("maps pixel values through lookup table", function()
    local img = M.new(2, 1, 1)
    img.data = {0, 255}
    local lut = {}
    for i = 0, 255 do lut[i] = 255 - i end
    local out = M.apply_lut(img, lut)
    T.eq(out.data[1], 255)
    T.eq(out.data[2], 0)
  end)
end)
