-- lib/stb/stb_test.lua
-- Tests for the stb package: tier selection, resize, decode stub.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local stb = require("lib.stb")

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Assert pixel at (x, y) in a raw pixel string (0-indexed, row-major) equals expected channels.
-- Calls T.eq per channel so failures print the actual byte value.
local function assert_pixel(pixels, w, x, y, ch, expected, label)
  local off = (y * w + x) * ch + 1
  for i = 1, ch do
    local got = string.byte(pixels, off + i - 1)
    T.eq(got, expected[i], (label or "") .. " ch" .. i)
  end
end

-- ── Tier selection ────────────────────────────────────────────────────────────

T.describe("stb: tier selection", function()
  T.it("M._tier is a valid string", function()
    local valid = { vendored = true, ["system-vips"] = true, ["pure-lua"] = true }
    T.ok(valid[stb._tier], "expected valid tier, got: " .. tostring(stb._tier))
  end)

  T.it("M.decode is callable", function()
    T.ok(type(stb.decode) == "function", "decode must be a function")
  end)

  T.it("M.resize is callable", function()
    T.ok(type(stb.resize) == "function", "resize must be a function")
  end)
end)

-- ── Decode stub ───────────────────────────────────────────────────────────────

T.describe("stb: decode", function()
  T.it("non-PNG data returns nil, err", function()
    local result, err = stb.decode("not an image")
    T.eq(result, nil)
    T.ok(type(err) == "string", "expected error string")
  end)

  T.it("PNG magic returns nil, err with informative message", function()
    -- Pure-lua tier recognizes PNG magic but cannot decode it yet.
    -- Vendored tier would actually decode — but no binary present in test env.
    local png_magic = "\137PNG\r\n\26\n" .. string.rep("\0", 16)
    local result, err = stb.decode(png_magic)
    -- Either decoded successfully (vendored tier) or returned nil+err (pure-lua/system-vips).
    if result == nil then
      T.ok(type(err) == "string", "expected error string for PNG on pure-lua tier")
    else
      -- vendored binary decoded it; check return types
      T.ok(type(result) == "string")
    end
  end)

  T.it("empty input returns nil, err", function()
    local result, err = stb.decode("")
    T.eq(result, nil)
    T.ok(type(err) == "string")
  end)
end)

-- ── Nearest-neighbor resize ───────────────────────────────────────────────────
-- Build test images as raw pixel bytes (channels=3, RGB).

-- 2×2 image: four distinct colored pixels
-- TL=red(255,0,0), TR=green(0,255,0), BL=blue(0,0,255), BR=white(255,255,255)
local function make_2x2()
  return string.char(
    255, 0,   0,    -- (0,0) red
    0,   255, 0,    -- (1,0) green
    0,   0,   255,  -- (0,1) blue
    255, 255, 255   -- (1,1) white
  )
end

T.describe("stb: resize 2x2 -> 4x4 (upscale)", function()
  local src = make_2x2()
  local dst, err = stb.resize(src, 2, 2, 4, 4, 3)

  T.it("returns a string without error", function()
    T.ok(dst ~= nil, "resize failed: " .. tostring(err))
    T.ok(type(dst) == "string")
  end)

  T.it("output length is 4*4*3 bytes", function()
    if dst then T.eq(#dst, 4 * 4 * 3) end
  end)

  T.it("top-left 2x2 block maps to source pixel (0,0)=red", function()
    if not dst then return end
    -- Nearest-neighbor: dst(0,0) → src(0,0)=red; dst(1,0) → src(0,0)=red
    assert_pixel(dst, 4, 0, 0, 3, {255, 0, 0}, "(0,0)")
    assert_pixel(dst, 4, 1, 0, 3, {255, 0, 0}, "(1,0)")
    assert_pixel(dst, 4, 0, 1, 3, {255, 0, 0}, "(0,1)")
    assert_pixel(dst, 4, 1, 1, 3, {255, 0, 0}, "(1,1)")
  end)

  T.it("top-right 2x2 block maps to source pixel (1,0)=green", function()
    if not dst then return end
    assert_pixel(dst, 4, 2, 0, 3, {0, 255, 0}, "(2,0)")
    assert_pixel(dst, 4, 3, 0, 3, {0, 255, 0}, "(3,0)")
    assert_pixel(dst, 4, 2, 1, 3, {0, 255, 0}, "(2,1)")
    assert_pixel(dst, 4, 3, 1, 3, {0, 255, 0}, "(3,1)")
  end)

  T.it("bottom-left 2x2 block maps to source pixel (0,1)=blue", function()
    if not dst then return end
    assert_pixel(dst, 4, 0, 2, 3, {0, 0, 255}, "(0,2)")
    assert_pixel(dst, 4, 1, 2, 3, {0, 0, 255}, "(1,2)")
    assert_pixel(dst, 4, 0, 3, 3, {0, 0, 255}, "(0,3)")
    assert_pixel(dst, 4, 1, 3, 3, {0, 0, 255}, "(1,3)")
  end)

  T.it("bottom-right 2x2 block maps to source pixel (1,1)=white", function()
    if not dst then return end
    assert_pixel(dst, 4, 2, 2, 3, {255, 255, 255}, "(2,2)")
    assert_pixel(dst, 4, 3, 2, 3, {255, 255, 255}, "(3,2)")
    assert_pixel(dst, 4, 2, 3, 3, {255, 255, 255}, "(2,3)")
    assert_pixel(dst, 4, 3, 3, 3, {255, 255, 255}, "(3,3)")
  end)
end)

T.describe("stb: resize 4x4 -> 2x2 (downscale)", function()
  -- Build a 4×4 image with 4 uniform quadrants matching the 2×2 test.
  -- TL quadrant=red, TR=green, BL=blue, BR=white.
  local function make_4x4()
    local rows = {}
    -- Row 0, 1: TL=red, TR=green
    for _ = 0, 1 do
      rows[#rows + 1] = string.char(255, 0, 0, 255, 0, 0, 0, 255, 0, 0, 255, 0)
    end
    -- Row 2, 3: BL=blue, BR=white
    for _ = 2, 3 do
      rows[#rows + 1] = string.char(0, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255, 255)
    end
    return table.concat(rows)
  end

  local src = make_4x4()
  local dst, err = stb.resize(src, 4, 4, 2, 2, 3)

  T.it("returns a string without error", function()
    T.ok(dst ~= nil, "resize failed: " .. tostring(err))
    T.ok(type(dst) == "string")
  end)

  T.it("output length is 2*2*3 bytes", function()
    if dst then T.eq(#dst, 2 * 2 * 3) end
  end)

  T.it("top-left pixel is red", function()
    if dst then assert_pixel(dst, 2, 0, 0, 3, {255, 0, 0}, "(0,0)") end
  end)

  T.it("top-right pixel is green", function()
    if dst then assert_pixel(dst, 2, 1, 0, 3, {0, 255, 0}, "(1,0)") end
  end)

  T.it("bottom-left pixel is blue", function()
    if dst then assert_pixel(dst, 2, 0, 1, 3, {0, 0, 255}, "(0,1)") end
  end)

  T.it("bottom-right pixel is white", function()
    if dst then assert_pixel(dst, 2, 1, 1, 3, {255, 255, 255}, "(1,1)") end
  end)
end)

T.describe("stb: resize grayscale (channels=1)", function()
  -- 2×2 grayscale: TL=0, TR=64, BL=128, BR=255
  local src = string.char(0, 64, 128, 255)
  local dst, err = stb.resize(src, 2, 2, 4, 4, 1)

  T.it("returns a string without error", function()
    T.ok(dst ~= nil, "resize failed: " .. tostring(err))
  end)

  T.it("output length is 4*4*1 bytes", function()
    if dst then T.eq(#dst, 16) end
  end)

  T.it("top-left block is 0", function()
    if dst then
      T.eq(string.byte(dst, 1), 0)
      T.eq(string.byte(dst, 2), 0)
    end
  end)

  T.it("bottom-right block is 255", function()
    if dst then
      T.eq(string.byte(dst, 16), 255)
      T.eq(string.byte(dst, 15), 255)
    end
  end)
end)
