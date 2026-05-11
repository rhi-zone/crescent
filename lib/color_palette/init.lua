if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- lib/color_palette: color palette generation, harmony, quantization, accessibility.
-- Colors are plain tables {r,g,b} with all channels in [0, 1].
-- All functions return (result) on success, (nil, errmsg) on error.

--:: Color = { r: number, g: number, b: number }

local M = {}
M._tier = "pure"

local floor = math.floor
local sqrt  = math.sqrt
local abs   = math.abs
local max   = math.max
local min   = math.min

----------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------

--: (x: number, lo: number, hi: number) -> number
local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

-- RGB (0..1) → HSL (h 0..1, s 0..1, l 0..1)
--: (r: number, g: number, b: number) -> (number, number, number)
local function rgb_to_hsl_norm(r, g, b)
  local mx = max(r, g, b)
  local mn = min(r, g, b)
  local l = (mx + mn) * 0.5
  local h, s
  if mx == mn then
    h, s = 0.0, 0.0
  else
    local d = mx - mn
    s = l > 0.5 and d / (2 - mx - mn) or d / (mx + mn)
    if mx == r then
      h = (g - b) / d + (g < b and 6 or 0)
    elseif mx == g then
      h = (b - r) / d + 2
    else
      h = (r - g) / d + 4
    end
    h = h / 6
  end
  local h_ = h --[[:! number]]
  local s_ = s --[[:! number]]
  return h_, s_, l
end

-- HSL (h 0..1, s 0..1, l 0..1) → RGB (0..1)
--: (h: number, s: number, l: number) -> (number, number, number)
local function hsl_norm_to_rgb(h, s, l)
  if s == 0 then return l, l, l end
  --: (p: number, q: number, t: number) -> number
  local function hue2rgb(p, q, t)
    local tv = t --: number
    if tv < 0 then tv = tv + 1 end
    if tv > 1 then tv = tv - 1 end
    if tv < 1/6 then return p + (q - p) * 6 * tv end
    if tv < 1/2 then return q end
    if tv < 2/3 then return p + (q - p) * (2/3 - tv) * 6 end
    return p
  end
  local q = l < 0.5 and l * (1 + s) or l + s - l * s
  local p = 2 * l - q
  return hue2rgb(p, q, h + 1/3), hue2rgb(p, q, h), hue2rgb(p, q, h - 1/3)
end

-- sRGB linearize (for luminance / contrast)
--: (v: number) -> number
local function linearize(v)
  if v <= 0.04045 then return v / 12.92 end
  return ((v + 0.055) / 1.055) ^ 2.4
end

-- Perceived luminance (WCAG 2.x)
--: (c: Color) -> number
local function luminance(c)
  return 0.2126 * linearize(c.r) + 0.7152 * linearize(c.g) + 0.0722 * linearize(c.b)
end

-- RGB (0..1) → Lab
--: (r: number, g: number, b: number) -> (number, number, number)
local function rgb_to_lab(r, g, b)
  local rl = linearize(r)
  local gl = linearize(g)
  local bl = linearize(b)
  local X = (0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl) / 0.95047
  local Y = (0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl) / 1.00000
  local Z = (0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl) / 1.08883
  --: (t: number) -> number
  local function f(t)
    if t > 0.008856 then return t ^ (1/3) end
    return 7.787 * t + 16/116
  end
  local fx, fy, fz = f(X), f(Y), f(Z)
  return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)
end

----------------------------------------------------------------------
-- Constructors
----------------------------------------------------------------------

-- Create a color from r,g,b in [0,1]
--: (r: number, g: number, b: number) -> Color
function M.rgb(r, g, b)
  return { r = clamp(r, 0, 1), g = clamp(g, 0, 1), b = clamp(b, 0, 1) }
end

-- Create a color from h,s,l in [0,1]
--: (h: number, s: number, l: number) -> Color
function M.hsl(h, s, l)
  local rgb = { hsl_norm_to_rgb(h % 1.0, clamp(s, 0, 1), clamp(l, 0, 1)) }
  local r_ = rgb[1] --[[:! number]]
  local g_ = rgb[2] --[[:! number]]
  local b_ = rgb[3] --[[:! number]]
  return { r = clamp(r_, 0, 1), g = clamp(g_, 0, 1), b = clamp(b_, 0, 1) }
end

-- Parse a hex color string (#rgb, #rrggbb)
--: (str: string) -> (Color | nil, string | nil)
function M.hex(str)
  if type(str) ~= "string" then
    return nil, "hex: expected string, got " .. type(str)
  end
  local s = str --: string
  if s:sub(1, 1) == "#" then s = s:sub(2) end
  local s2 = s --[[:! string]]
  if #s2 == 3 then
    local r1 = s2:sub(1,1)
    local g1 = s2:sub(2,2)
    local b1 = s2:sub(3,3)
    s2 = r1..r1..g1..g1..b1..b1
  end
  local s = s2 --[[:! string]]
  if #s ~= 6 then
    return nil, "hex: invalid hex color '" .. str .. "'"
  end
  if s:find("[^0-9a-fA-F]") then
    return nil, "hex: invalid hex characters in '" .. str .. "'"
  end
  local r = (tonumber(s:sub(1,2), 16) or 0) / 255
  local g = (tonumber(s:sub(3,4), 16) or 0) / 255
  local b = (tonumber(s:sub(5,6), 16) or 0) / 255
  return { r = r, g = g, b = b }
end

----------------------------------------------------------------------
-- Conversions
----------------------------------------------------------------------

-- Color {r,g,b} → {h,s,l} all in [0,1]
--: (c: Color) -> { h: number, s: number, l: number }
function M.to_hsl(c)
  local h, s, l = rgb_to_hsl_norm(c.r, c.g, c.b)
  return { h = h, s = s, l = l }
end

-- Color {r,g,b} → "#rrggbb" hex string
--: (c: Color) -> string
function M.to_hex(c)
  local r = floor(clamp(c.r, 0, 1) * 255 + 0.5)
  local g = floor(clamp(c.g, 0, 1) * 255 + 0.5)
  local b = floor(clamp(c.b, 0, 1) * 255 + 0.5)
  return string.format("#%02x%02x%02x", r, g, b)
end

----------------------------------------------------------------------
-- Color harmony (input/output colors as {r,g,b})
----------------------------------------------------------------------

--: (c: Color, degrees: number) -> Color
local function rotate_hue(c, degrees)
  local h, s, l = rgb_to_hsl_norm(c.r, c.g, c.b)
  h = (h + degrees / 360) % 1
  local rgb = { hsl_norm_to_rgb(h, s, l) }
  local r_ = rgb[1] --[[:! number]]
  local g_ = rgb[2] --[[:! number]]
  local b_ = rgb[3] --[[:! number]]
  return { r = clamp(r_, 0, 1), g = clamp(g_, 0, 1), b = clamp(b_, 0, 1) }
end

-- Single complementary color (hue + 180°)
--: (c: Color) -> Color
function M.complementary(c)
  return rotate_hue(c, 180)
end

-- Split complementary: {base, +150°, +210°}
--: (c: Color) -> { [integer]: Color }
function M.split_complementary(c)
  return { c, rotate_hue(c, 150), rotate_hue(c, 210) }
end

-- Triadic: {base, +120°, +240°}
--: (c: Color) -> { [integer]: Color }
function M.triadic(c)
  return { c, rotate_hue(c, 120), rotate_hue(c, 240) }
end

-- Tetradic: {base, +90°, +180°, +270°}
--: (c: Color) -> { [integer]: Color }
function M.tetradic(c)
  return { c, rotate_hue(c, 90), rotate_hue(c, 180), rotate_hue(c, 270) }
end

-- Analogous: n colors spaced step° apart, centered on base hue
-- opts: {n=5, step=30}
--: (c: Color, opts: { n: integer | nil, step: number | nil } | nil) -> { [integer]: Color }
function M.analogous(c, opts)
  local opts_ = (opts or {}) --[[:! { n: integer | nil, step: number | nil }]]
  local n    = opts_.n    or 5
  local step = opts_.step or 30
  local result = {} --: { [integer]: Color }
  local h, s, l = rgb_to_hsl_norm(c.r, c.g, c.b)
  local center = h
  for i = 1, n do
    local offset = (i - 1 - (n - 1) / 2) * step / 360
    local hi = (center + offset) % 1
    local rgb = { hsl_norm_to_rgb(hi, s, l) }
    local r_ = rgb[1] --[[:! number]]; local g_ = rgb[2] --[[:! number]]; local b_ = rgb[3] --[[:! number]]
    result[i] = { r = clamp(r_, 0, 1), g = clamp(g_, 0, 1), b = clamp(b_, 0, 1) }
  end
  return result
end

-- Monochromatic: n colors with same hue, spread across lightness
-- opts: {n=5}
--: (c: Color, opts: { n: integer | nil } | nil) -> { [integer]: Color }
function M.monochromatic(c, opts)
  local opts_ = (opts or {}) --[[:! { n: integer | nil }]]
  local n = opts_.n or 5
  local h, s, _ = rgb_to_hsl_norm(c.r, c.g, c.b)
  local result = {} --: { [integer]: Color }
  for i = 1, n do
    local l = (i - 1) / (n - 1)
    local rgb = { hsl_norm_to_rgb(h, s, l) }
    local r_ = rgb[1] --[[:! number]]; local g_ = rgb[2] --[[:! number]]; local b_ = rgb[3] --[[:! number]]
    result[i] = { r = clamp(r_, 0, 1), g = clamp(g_, 0, 1), b = clamp(b_, 0, 1) }
  end
  return result
end

----------------------------------------------------------------------
-- Tint / shade / tone scales
----------------------------------------------------------------------

-- n tints: interpolate from c toward white
--: (c: Color, n: integer) -> { [integer]: Color }
function M.tints(c, n)
  local result = {} --: { [integer]: Color }
  for i = 1, n do
    local t = (i - 1) / (n - 1)
    result[i] = {
      r = c.r + (1 - c.r) * t,
      g = c.g + (1 - c.g) * t,
      b = c.b + (1 - c.b) * t,
    }
  end
  return result
end

-- n shades: interpolate from c toward black
--: (c: Color, n: integer) -> { [integer]: Color }
function M.shades(c, n)
  local result = {} --: { [integer]: Color }
  for i = 1, n do
    local t = (i - 1) / (n - 1)
    result[i] = {
      r = c.r * (1 - t),
      g = c.g * (1 - t),
      b = c.b * (1 - t),
    }
  end
  return result
end

-- n tones: interpolate from c toward gray (0.5, 0.5, 0.5)
--: (c: Color, n: integer) -> { [integer]: Color }
function M.tones(c, n)
  local result = {} --: { [integer]: Color }
  for i = 1, n do
    local t = (i - 1) / (n - 1)
    result[i] = {
      r = c.r + (0.5 - c.r) * t,
      g = c.g + (0.5 - c.g) * t,
      b = c.b + (0.5 - c.b) * t,
    }
  end
  return result
end

----------------------------------------------------------------------
-- Interpolation and gradient
----------------------------------------------------------------------

-- Interpolate between c1 and c2 at t ∈ [0,1]
--: (c1: Color, c2: Color, t: number) -> Color
function M.interpolate(c1, c2, t)
  t = clamp(t, 0, 1)
  return {
    r = c1.r + (c2.r - c1.r) * t,
    g = c1.g + (c2.g - c1.g) * t,
    b = c1.b + (c2.b - c1.b) * t,
  }
end

-- Generate n evenly-spaced colors from c1 to c2 (inclusive)
function M.gradient(c1, c2, n)
  if n < 2 then
    return { c1 }
  end
  local result = {}
  for i = 1, n do
    local t = (i - 1) / (n - 1)
    result[i] = M.interpolate(c1, c2, t)
  end
  return result
end

----------------------------------------------------------------------
-- Palette manipulation
----------------------------------------------------------------------

-- Sort a palette by a key: "hue", "luminance", "r", "g", "b"
--: (palette: { [integer]: Color }, key: string) -> ({ [integer]: Color } | nil, string | nil)
function M.sort(palette, key)
  local result = {} --: { [integer]: Color }
  for i, c in ipairs(palette) do result[i] = c end
  local key_fn --: ((c: Color) -> number) | nil
  if key == "hue" then
    --: (c: Color) -> number
    key_fn = function(c)
      local cv = c --[[:! Color]]
      local h, _, _ = rgb_to_hsl_norm(cv.r, cv.g, cv.b)
      return h
    end
  elseif key == "luminance" then
    key_fn = luminance
  elseif key == "r" then
    key_fn = function(c) local cv = c --[[:! Color]]; return cv.r end
  elseif key == "g" then
    key_fn = function(c) local cv = c --[[:! Color]]; return cv.g end
  elseif key == "b" then
    key_fn = function(c) local cv = c --[[:! Color]]; return cv.b end
  else
    return nil, "sort: unknown key '" .. tostring(key) .. "'"
  end
  local kfn = key_fn --[[:! (c: Color) -> number]]
  local result_ = (result --[[:! { [integer]: Color }]])
  for i = 2, #result_ do
    local v = result_[i]; local j = i - 1
    while j >= 1 and kfn(result_[j]) > kfn(v) do result_[j + 1] = result_[j]; j = j - 1 end
    result_[j + 1] = v
  end
  return result_
end

-- Remove near-duplicate colors using Euclidean RGB distance threshold
--: (palette: { [integer]: Color }, threshold: number | nil) -> { [integer]: Color }
function M.deduplicate(palette, threshold)
  threshold = threshold or 0.05
  local result = {} --: { [integer]: Color }
  for _, c in ipairs(palette) do
    local c_ = c --[[:! Color]]
    local dup = false
    for _, existing in ipairs(result) do
      local existing_ = existing --[[:! Color]]
      local dr = c_.r - existing_.r
      local dg = c_.g - existing_.g
      local db = c_.b - existing_.b
      if sqrt(dr*dr + dg*dg + db*db) < (threshold --[[:! number]]) then
        dup = true
        break
      end
    end
    if not dup then
      result[#result + 1] = c_
    end
  end
  return result
end

----------------------------------------------------------------------
-- Color quantization (median cut)
----------------------------------------------------------------------

--: (pixels: { [integer]: Color }, ch: string) -> number
local function channel_range(pixels, ch)
  local lo = pixels[1][ch] --[[:! number]]
  local hi = lo
  for i = 2, #pixels do
    local v = pixels[i][ch] --[[:! number]]
    if v < lo then lo = v end
    if v > hi then hi = v end
  end
  return hi - lo
end

--: (pixels: { [integer]: Color }) -> Color
local function average_color(pixels)
  local sr, sg, sb = 0.0, 0.0, 0.0 --: number
  local n = #pixels
  for _, p in ipairs(pixels) do
    sr = sr + p.r
    sg = sg + p.g
    sb = sb + p.b
  end
  return { r = sr / n, g = sg / n, b = sb / n }
end

-- Median-cut quantization: reduce pixels to n representative colors
--: (pixels: { [integer]: Color }, n: integer | nil) -> { [integer]: Color }
function M.quantize(pixels, n)
  if #pixels == 0 then return {} end
  n = n or 8

  -- Start with all pixels in one bucket
  local buckets = { pixels } --: { [integer]: { [integer]: Color } }

  -- Split the widest-range bucket until we have n buckets
  while #buckets < n do
    -- Find bucket with highest range
    local best_i, best_range, best_ch = 1, -1, "r"
    for i, bucket in ipairs(buckets) do
      local rr = channel_range(bucket, "r")
      local rg = channel_range(bucket, "g")
      local rb = channel_range(bucket, "b")
      local bmax = max(rr, rg, rb)
      if bmax > best_range then
        best_range = bmax
        best_i = i
        if rr >= rg and rr >= rb then best_ch = "r"
        elseif rg >= rr and rg >= rb then best_ch = "g"
        else best_ch = "b"
        end
      end
    end
    if best_range == 0 then break end

    -- Split best bucket along best_ch at median
    local bucket = table.remove(buckets, best_i) --[[:! { [integer]: Color }]]
    local ch = best_ch
    table.sort(bucket, function(a, b)
      local av = a --[[:! Color]]; local bv = b --[[:! Color]]
      return av[ch] --[[:! number]] < bv[ch] --[[:! number]]
    end)
    local mid = floor(#bucket / 2)
    local left, right = {}, {} --: { [integer]: Color }
    for i = 1, mid do left[i] = bucket[i] end
    for i = mid + 1, #bucket do right[#right + 1] = bucket[i] end
    if #left > 0 then buckets[#buckets + 1] = left end
    if #right > 0 then buckets[#buckets + 1] = right end
  end

  -- Average each bucket
  local result = {} --: { [integer]: Color }
  for _, bucket in ipairs(buckets) do
    local bkt = bucket --[[:! { [integer]: Color }]]
    result[#result + 1] = average_color(bkt)
  end
  return result
end

----------------------------------------------------------------------
-- Accessibility
----------------------------------------------------------------------

-- WCAG contrast ratio between fg and bg (both {r,g,b} in [0,1])
--: (fg: Color, bg: Color) -> number
function M.contrast_ratio(fg, bg)
  local l1 = luminance(fg)
  local l2 = luminance(bg)
  local lighter = max(l1, l2)
  local darker  = min(l1, l2)
  return (lighter + 0.05) / (darker + 0.05)
end

-- Check WCAG contrast level: "AA" (4.5:1) or "AAA" (7:1)
--: (fg: Color, bg: Color, level: string) -> (boolean | nil, string | nil)
function M.check_contrast(fg, bg, level)
  local ratio = M.contrast_ratio(fg, bg)
  if level == "AA" then
    return ratio >= 4.5
  elseif level == "AAA" then
    return ratio >= 7.0
  else
    return nil, "check_contrast: unknown level '" .. tostring(level) .. "'"
  end
end

-- Pick the candidate foreground color with the highest contrast against bg
--: (bg: Color, candidates: { [integer]: Color }) -> Color | nil
function M.best_foreground(bg, candidates)
  local best = candidates[1] --: Color | nil
  local best_ratio = -1.0 --: number
  for _, fg in ipairs(candidates) do
    local r = M.contrast_ratio(fg, bg)
    if r > best_ratio then
      best_ratio = r
      best = fg --[[:! Color]]
    end
  end
  return best
end

----------------------------------------------------------------------
-- Color distance
----------------------------------------------------------------------

-- Distance between two colors using "euclidean" (RGB) or "cie76" (Lab ΔE)
--: (c1: Color, c2: Color, method: string | nil) -> (number | nil, string | nil)
function M.distance(c1, c2, method)
  method = method or "euclidean"
  if method == "euclidean" then
    local dr = c1.r - c2.r
    local dg = c1.g - c2.g
    local db = c1.b - c2.b
    return sqrt(dr*dr + dg*dg + db*db)
  elseif method == "cie76" then
    local lab1 = { rgb_to_lab(c1.r, c1.g, c1.b) }
    local lab2 = { rgb_to_lab(c2.r, c2.g, c2.b) }
    local L1 = lab1[1] --[[:! number]]; local a1 = lab1[2] --[[:! number]]; local b1 = lab1[3] --[[:! number]]
    local L2 = lab2[1] --[[:! number]]; local a2 = lab2[2] --[[:! number]]; local b2 = lab2[3] --[[:! number]]
    local dL = L1 - L2
    local da = a1 - a2
    local db_ = b1 - b2
    return sqrt(dL*dL + da*da + db_*db_)
  else
    return nil, "distance: unknown method '" .. tostring(method) .. "'"
  end
end

-- Find the nearest color in palette to target
--: (target: Color, palette: { [integer]: Color }) -> Color | nil
function M.nearest(target, palette)
  local best = palette[1] --: Color | nil
  local best_dist = math.huge --: number
  for _, c in ipairs(palette) do
    local d = M.distance(target, c, "euclidean")
    local d_ = d --[[:! number]]
    if d_ < best_dist then
      best_dist = d_
      best = c --[[:! Color]]
    end
  end
  return best
end

----------------------------------------------------------------------
-- Export
----------------------------------------------------------------------

-- Convert palette to list of "#rrggbb" hex strings
function M.to_hex_list(palette)
  local result = {}
  for i, c in ipairs(palette) do
    result[i] = M.to_hex(c)
  end
  return result
end

-- Convert palette to CSS custom properties
-- e.g. to_css_vars(palette, "color") → "--color-0: #ff0000;\n--color-1: #0000ff;\n..."
function M.to_css_vars(palette, prefix)
  prefix = prefix or "color"
  local parts = {}
  for i, c in ipairs(palette) do
    parts[i] = string.format("--%s-%d: %s;", prefix, i - 1, M.to_hex(c))
  end
  return table.concat(parts, "\n")
end

----------------------------------------------------------------------
-- Preset palettes
-- A few commonly-used swatches (stored as {r,g,b})
----------------------------------------------------------------------

M.palettes = {}

-- Google Material Design red shades (100–900)
M.palettes.material_red = {
  M.hex("#ffcdd2"),  -- 100
  M.hex("#ef9a9a"),  -- 200
  M.hex("#e57373"),  -- 300
  M.hex("#ef5350"),  -- 400 (actually 400)
  M.hex("#f44336"),  -- 500
  M.hex("#e53935"),  -- 600
  M.hex("#d32f2f"),  -- 700
  M.hex("#c62828"),  -- 800
  M.hex("#b71c1c"),  -- 900
}

-- Tailwind CSS blue shades (100–900)
M.palettes.tailwind_blue = {
  M.hex("#dbeafe"),  -- 100
  M.hex("#bfdbfe"),  -- 200
  M.hex("#93c5fd"),  -- 300
  M.hex("#60a5fa"),  -- 400
  M.hex("#3b82f6"),  -- 500
  M.hex("#2563eb"),  -- 600
  M.hex("#1d4ed8"),  -- 700
  M.hex("#1e40af"),  -- 800
  M.hex("#1e3a8a"),  -- 900
}

-- Solarized (Ethan Schoonover)
M.palettes.solarized = {
  M.hex("#002b36"),  -- base03
  M.hex("#073642"),  -- base02
  M.hex("#586e75"),  -- base01
  M.hex("#657b83"),  -- base00
  M.hex("#839496"),  -- base0
  M.hex("#93a1a1"),  -- base1
  M.hex("#eee8d5"),  -- base2
  M.hex("#fdf6e3"),  -- base3
  M.hex("#b58900"),  -- yellow
  M.hex("#cb4b16"),  -- orange
  M.hex("#dc322f"),  -- red
  M.hex("#d33682"),  -- magenta
  M.hex("#6c71c4"),  -- violet
  M.hex("#268bd2"),  -- blue
  M.hex("#2aa198"),  -- cyan
  M.hex("#859900"),  -- green
}

-- Nord (Arctic Ice Studio)
M.palettes.nord = {
  M.hex("#2e3440"),
  M.hex("#3b4252"),
  M.hex("#434c5e"),
  M.hex("#4c566a"),
  M.hex("#d8dee9"),
  M.hex("#e5e9f0"),
  M.hex("#eceff4"),
  M.hex("#8fbcbb"),
  M.hex("#88c0d0"),
  M.hex("#81a1c1"),
  M.hex("#5e81ac"),
  M.hex("#bf616a"),
  M.hex("#d08770"),
  M.hex("#ebcb8b"),
  M.hex("#a3be8c"),
  M.hex("#b48ead"),
}

-- Catppuccin Mocha (accent colors only)
M.palettes.catppuccin_mocha = {
  M.hex("#f38ba8"),  -- red
  M.hex("#fab387"),  -- peach
  M.hex("#f9e2af"),  -- yellow
  M.hex("#a6e3a1"),  -- green
  M.hex("#94e2d5"),  -- teal
  M.hex("#89dceb"),  -- sky
  M.hex("#89b4fa"),  -- blue
  M.hex("#cba6f7"),  -- mauve
}

return M
