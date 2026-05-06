if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: ColorObj = { _r: number, _g: number, _b: number, _a: number, to_rgb: (ColorObj) -> number, number, number, to_rgb01: (ColorObj) -> number, number, number, to_hsl: (ColorObj) -> number, number, number, to_hsv: (ColorObj) -> number, number, number, to_hex: (ColorObj) -> string, to_array: (ColorObj) -> { [integer]: number }, get_alpha: (ColorObj) -> number, lighten: (ColorObj, number) -> ColorObj, darken: (ColorObj, number) -> ColorObj, saturate: (ColorObj, number) -> ColorObj, desaturate: (ColorObj, number) -> ColorObj, rotate: (ColorObj, number) -> ColorObj, complement: (ColorObj) -> ColorObj, invert: (ColorObj) -> ColorObj, grayscale: (ColorObj) -> ColorObj, alpha: (ColorObj, number) -> ColorObj, mix: (ColorObj, ColorObj, number|nil) -> ColorObj, eq: (ColorObj, ColorObj) -> boolean }

-- Color object metatable
local Color = {}
Color.__index = Color

-- Internal constructor: stores RGB 0-255 + alpha 0-1
local function _color(r, g, b, a)
  local rv = r --[[:! number]]
  local gv = g --[[:! number]]
  local bv = b --[[:! number]]
  local av = a --[[:! number|nil]]
  return setmetatable({ _r = rv, _g = gv, _b = bv, _a = av or 1.0 }, Color)
end

-- Clamp a number to [lo, hi]
--: (number, number, number) -> number
local function clamp(x, lo, hi)
  local xv = x --[[:! number]]
  local lov = lo --[[:! number]]
  local hiv = hi --[[:! number]]
  if xv < lov then return lov end
  if xv > hiv then return hiv end
  return xv
end

-- Round to nearest integer
--: (number) -> number
local function round(x)
  local xv = x --[[:! number]]
  return math.floor(xv + 0.5)
end

----------------------------------------------------------------------
-- HSL/HSV helpers
----------------------------------------------------------------------

local function rgb_to_hsl(r, g, b)
  local r_ = r / 255
  local g_ = g / 255
  local b_ = b / 255
  local max = math.max(r_, g_, b_)
  local min = math.min(r_, g_, b_)
  local h = 0.0 --: number
  local s = 0.0 --: number
  local l = (max + min) / 2

  if max ~= min then
    local d = max - min
    s = l > 0.5 and d / (2 - max - min) or d / (max + min)
    if max == r_ then
      h = (g_ - b_) / d + (g_ < b_ and 6 or 0)
    elseif max == g_ then
      h = (b_ - r_) / d + 2
    else
      h = (r_ - g_) / d + 4
    end
    h = h * 60
  end
  return h, s * 100, l * 100
end

local function hsl_to_rgb(h, s, l)
  local h_ = h % 360
  local s_ = s / 100
  local l_ = l / 100
  if s_ == 0 then
    local v = round(l_ * 255)
    return v, v, v
  end
  local function hue2rgb(p, q, t)
    local pv = p --[[:! number]]
    local qv = q --[[:! number]]
    local tv = t --[[:! number]]
    local t1 = tv < 0 and tv + 1 or tv
    local t2 = t1 > 1 and t1 - 1 or t1
    local t2_ = t2 --[[:! number]]
    if t2_ < 1/6 then return pv + (qv - pv) * 6 * t2_ end
    if t2_ < 1/2 then return qv end
    if t2_ < 2/3 then return pv + (qv - pv) * (2/3 - t2_) * 6 end
    return pv
  end
  local q_ = (l_ < 0.5 and l_ * (1 + s_) or l_ + s_ - l_ * s_) --[[:! number]]
  local p_ = 2 * l_ - q_
  local r_ = hue2rgb(p_, q_, h_ / 360 + 1/3)
  local g_ = hue2rgb(p_, q_, h_ / 360)
  local b_ = hue2rgb(p_, q_, h_ / 360 - 1/3)
  return round(r_ * 255), round(g_ * 255), round(b_ * 255)
end

local function rgb_to_hsv(r, g, b)
  local r_ = r / 255
  local g_ = g / 255
  local b_ = b / 255
  local max = math.max(r_, g_, b_)
  local min = math.min(r_, g_, b_)
  local h = 0.0 --: number
  local v = max

  local d = max - min
  local s = max == 0 and 0.0 or d / max

  if max ~= min then
    if max == r_ then
      h = (g_ - b_) / d + (g_ < b_ and 6 or 0)
    elseif max == g_ then
      h = (b_ - r_) / d + 2
    else
      h = (r_ - g_) / d + 4
    end
    h = h * 60
  end
  return h, s * 100, v * 100
end

local function hsv_to_rgb(h, s, v)
  local h_ = h % 360
  local s_ = s / 100
  local v_ = v / 100
  local c = v_ * s_
  local x = c * (1 - math.abs((h_ / 60) % 2 - 1))
  local m = v_ - c
  local r = 0.0 --: number
  local g = 0.0 --: number
  local b = 0.0 --: number
  if h_ < 60 then      r, g, b = c, x, 0
  elseif h_ < 120 then r, g, b = x, c, 0
  elseif h_ < 180 then r, g, b = 0, c, x
  elseif h_ < 240 then r, g, b = 0, x, c
  elseif h_ < 300 then r, g, b = x, 0, c
  else                  r, g, b = c, 0, x
  end
  return round((r + m) * 255), round((g + m) * 255), round((b + m) * 255)
end

----------------------------------------------------------------------
-- Named CSS colors
----------------------------------------------------------------------

--:: NamedEntry = { [integer]: number }
local _NAMED_ORIG = {
  black   = { 0,   0,   0   },
  white   = { 255, 255, 255 },
  red     = { 255, 0,   0   },
  lime    = { 0,   255, 0   },
  blue    = { 0,   0,   255 },
  yellow  = { 255, 255, 0   },
  cyan    = { 0,   255, 255 },
  aqua    = { 0,   255, 255 },
  magenta = { 255, 0,   255 },
  fuchsia = { 255, 0,   255 },
  maroon  = { 128, 0,   0   },
  green   = { 0,   128, 0   },
  navy    = { 0,   0,   128 },
  olive   = { 128, 128, 0   },
  purple  = { 128, 0,   128 },
  teal    = { 0,   128, 128 },
  silver  = { 192, 192, 192 },
  gray    = { 128, 128, 128 },
  grey    = { 128, 128, 128 },
  orange  = { 255, 165, 0   },
}
local NAMED = _NAMED_ORIG --[[:! { [string]: NamedEntry }]]

----------------------------------------------------------------------
-- Constructors
----------------------------------------------------------------------

function M.rgb(r, g, b, a)
  local rv = r --[[:! number]]
  local gv = g --[[:! number]]
  local bv = b --[[:! number]]
  local av = a --[[:! number|nil]]
  return _color(
    round(clamp(rv, 0, 255)),
    round(clamp(gv, 0, 255)),
    round(clamp(bv, 0, 255)),
    av and clamp(av, 0, 1) or 1.0
  )
end

function M.rgb01(r, g, b, a)
  local rv = r --[[:! number]]
  local gv = g --[[:! number]]
  local bv = b --[[:! number]]
  local av = a --[[:! number|nil]]
  return _color(
    round(clamp(rv, 0, 1) * 255),
    round(clamp(gv, 0, 1) * 255),
    round(clamp(bv, 0, 1) * 255),
    av and clamp(av, 0, 1) or 1.0
  )
end

function M.hsl(h, s, l, a)
  local hv = h --[[:! number]]
  local sv = s --[[:! number]]
  local lv = l --[[:! number]]
  local av = a --[[:! number|nil]]
  local rgb = {hsl_to_rgb(hv, clamp(sv, 0, 100), clamp(lv, 0, 100))} --[[:! { [integer]: number }]]
  return _color(rgb[1], rgb[2], rgb[3], av and clamp(av, 0, 1) or 1.0)
end

function M.hsv(h, s, v, a)
  local hv = h --[[:! number]]
  local sv = s --[[:! number]]
  local vv = v --[[:! number]]
  local av = a --[[:! number|nil]]
  local rgb = {hsv_to_rgb(hv, clamp(sv, 0, 100), clamp(vv, 0, 100))} --[[:! { [integer]: number }]]
  return _color(rgb[1], rgb[2], rgb[3], av and clamp(av, 0, 1) or 1.0)
end

function M.hex(s)
  if type(s) ~= "string" then
    return nil, "hex: expected string, got " .. type(s)
  end
  local sv = s --[[:! string]]
  -- strip leading #
  local sv2 = (sv:sub(1, 1) == "#") and sv:sub(2) or sv
  local sv3 = sv2 --[[:! string]]
  -- expand shorthand
  local hex = "" --: string
  if #sv3 == 3 then
    hex = sv3:sub(1,1) .. sv3:sub(1,1) .. sv3:sub(2,2) .. sv3:sub(2,2) .. sv3:sub(3,3) .. sv3:sub(3,3)
  elseif #sv3 == 4 then
    hex = sv3:sub(1,1) .. sv3:sub(1,1) .. sv3:sub(2,2) .. sv3:sub(2,2) .. sv3:sub(3,3) .. sv3:sub(3,3) .. sv3:sub(4,4) .. sv3:sub(4,4)
  else
    hex = sv3
  end
  local hex_ = hex --[[:! string]]
  if #hex_ ~= 6 and #hex_ ~= 8 then
    return nil, "hex: invalid hex color string"
  end
  if hex_:find("[^0-9a-fA-F]") then
    return nil, "hex: invalid hex characters"
  end
  local r = tonumber(hex_:sub(1, 2), 16) or 0
  local g = tonumber(hex_:sub(3, 4), 16) or 0
  local b = tonumber(hex_:sub(5, 6), 16) or 0
  local a = 1.0 --: number
  if #hex_ == 8 then
    a = (tonumber(hex_:sub(7, 8), 16) or 0) / 255
  end
  return _color(r, g, b, a)
end

function M.named(name)
  if type(name) ~= "string" then
    return nil, "named: expected string, got " .. type(name)
  end
  local entry = NAMED[name:lower()]
  if not entry then
    return nil, "named: unknown color name '" .. name .. "'"
  end
  return _color(entry[1], entry[2], entry[3], 1.0)
end

----------------------------------------------------------------------
-- Conversions
----------------------------------------------------------------------

function Color:to_rgb()
  local self_ = self --[[:! ColorObj]]
  return self_._r, self_._g, self_._b
end

function Color:to_rgb01()
  local self_ = self --[[:! ColorObj]]
  return self_._r / 255, self_._g / 255, self_._b / 255
end

function Color:to_hsl()
  local self_ = self --[[:! ColorObj]]
  local hsl = {rgb_to_hsl(self_._r, self_._g, self_._b)} --[[:! { [integer]: number }]]
  return hsl[1], hsl[2], hsl[3]
end

function Color:to_hsv()
  local self_ = self --[[:! ColorObj]]
  local hsv = {rgb_to_hsv(self_._r, self_._g, self_._b)} --[[:! { [integer]: number }]]
  return hsv[1], hsv[2], hsv[3]
end

function Color:to_hex()
  local self_ = self --[[:! ColorObj]]
  return string.format("#%02x%02x%02x", self_._r, self_._g, self_._b)
end

function Color:to_array()
  local self_ = self --[[:! ColorObj]]
  return { self_._r, self_._g, self_._b }
end

function Color:get_alpha()
  local self_ = self --[[:! ColorObj]]
  return self_._a
end

----------------------------------------------------------------------
-- Manipulation (all return new Color)
----------------------------------------------------------------------

function Color:lighten(amount)
  local self_ = self --[[:! ColorObj]]
  local amtv = amount --[[:! number]]
  local hsl = {rgb_to_hsl(self_._r, self_._g, self_._b)} --[[:! { [integer]: number }]]
  local l2 = clamp(hsl[3] + amtv * 100, 0, 100)
  local rgb = {hsl_to_rgb(hsl[1], hsl[2], l2)} --[[:! { [integer]: number }]]
  return _color(rgb[1], rgb[2], rgb[3], self_._a)
end

function Color:darken(amount)
  local self_ = self --[[:! ColorObj]]
  local amtv = amount --[[:! number]]
  local hsl = {rgb_to_hsl(self_._r, self_._g, self_._b)} --[[:! { [integer]: number }]]
  local l2 = clamp(hsl[3] - amtv * 100, 0, 100)
  local rgb = {hsl_to_rgb(hsl[1], hsl[2], l2)} --[[:! { [integer]: number }]]
  return _color(rgb[1], rgb[2], rgb[3], self_._a)
end

function Color:saturate(amount)
  local self_ = self --[[:! ColorObj]]
  local amtv = amount --[[:! number]]
  local hsl = {rgb_to_hsl(self_._r, self_._g, self_._b)} --[[:! { [integer]: number }]]
  local s2 = clamp(hsl[2] + amtv * 100, 0, 100)
  local rgb = {hsl_to_rgb(hsl[1], s2, hsl[3])} --[[:! { [integer]: number }]]
  return _color(rgb[1], rgb[2], rgb[3], self_._a)
end

function Color:desaturate(amount)
  local self_ = self --[[:! ColorObj]]
  local amtv = amount --[[:! number]]
  local hsl = {rgb_to_hsl(self_._r, self_._g, self_._b)} --[[:! { [integer]: number }]]
  local s2 = clamp(hsl[2] - amtv * 100, 0, 100)
  local rgb = {hsl_to_rgb(hsl[1], s2, hsl[3])} --[[:! { [integer]: number }]]
  return _color(rgb[1], rgb[2], rgb[3], self_._a)
end

function Color:rotate(degrees)
  local self_ = self --[[:! ColorObj]]
  local degv = degrees --[[:! number]]
  local hsl = {rgb_to_hsl(self_._r, self_._g, self_._b)} --[[:! { [integer]: number }]]
  local h2 = (hsl[1] + degv) % 360
  local rgb = {hsl_to_rgb(h2, hsl[2], hsl[3])} --[[:! { [integer]: number }]]
  return _color(rgb[1], rgb[2], rgb[3], self_._a)
end

function Color:complement()
  local self_ = self --[[:! ColorObj]]
  return self_:rotate(180)
end

function Color:invert()
  local self_ = self --[[:! ColorObj]]
  return _color(255 - self_._r, 255 - self_._g, 255 - self_._b, self_._a)
end

function Color:grayscale()
  local self_ = self --[[:! ColorObj]]
  local hsl = {rgb_to_hsl(self_._r, self_._g, self_._b)} --[[:! { [integer]: number }]]
  local rgb = {hsl_to_rgb(hsl[1], 0, hsl[3])} --[[:! { [integer]: number }]]
  return _color(rgb[1], rgb[2], rgb[3], self_._a)
end

function Color:alpha(a)
  local self_ = self --[[:! ColorObj]]
  return _color(self_._r, self_._g, self_._b, clamp(a --[[:! number]], 0, 1))
end

function Color:mix(other, t)
  local self_ = self --[[:! ColorObj]]
  local other_ = other --[[:! ColorObj]]
  local t_ = (t or 0.5)
  local r = round(self_._r + (other_._r - self_._r) * t_)
  local g = round(self_._g + (other_._g - self_._g) * t_)
  local b = round(self_._b + (other_._b - self_._b) * t_)
  local a = self_._a + (other_._a - self_._a) * t_
  return _color(r, g, b, a)
end

----------------------------------------------------------------------
-- Equality and string representation
----------------------------------------------------------------------

function Color:eq(other)
  local self_ = self --[[:! ColorObj]]
  local other_ = other --[[:! ColorObj]]
  return self_._r == other_._r and self_._g == other_._g and self_._b == other_._b and self_._a == other_._a
end

function Color:__tostring()
  local self_ = self --[[:! ColorObj]]
  if self_._a < 1.0 then
    return string.format("rgba(%d, %d, %d, %.2f)", self_._r, self_._g, self_._b, self_._a)
  end
  return self_:to_hex()
end

function Color.__eq(a, b)
  local a_ = a --[[:! ColorObj]]
  local b_ = b --[[:! ColorObj]]
  return a_._r == b_._r and a_._g == b_._g and a_._b == b_._b and a_._a == b_._a
end

----------------------------------------------------------------------
-- Utilities
----------------------------------------------------------------------

function M.luminance(c)
  local c_ = c --[[:! ColorObj]]
  local function linearize(v)
    local v_ = v --[[:! number]] / 255
    return v_ <= 0.03928 and v_ / 12.92 or ((v_ + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * linearize(c_._r) + 0.7152 * linearize(c_._g) + 0.0722 * linearize(c_._b)
end

function M.contrast(c1, c2)
  local l1 = M.luminance(c1)
  local l2 = M.luminance(c2)
  local lighter = math.max(l1, l2)
  local darker = math.min(l1, l2)
  return (lighter + 0.05) / (darker + 0.05)
end

function M.distance(c1, c2)
  local c1_ = c1 --[[:! ColorObj]]
  local c2_ = c2 --[[:! ColorObj]]
  local dr = c1_._r - c2_._r
  local dg = c1_._g - c2_._g
  local db = c1_._b - c2_._b
  return math.sqrt(dr * dr + dg * dg + db * db)
end

function M.is_light(c)
  return M.luminance(c) > 0.5
end

function M.is_dark(c)
  return M.luminance(c) <= 0.5
end

function M.palette(c, kind)
  local c_ = c --[[:! ColorObj]]
  if kind == "complementary" then
    return { c_, c_:complement() }
  elseif kind == "triadic" then
    return { c_, c_:rotate(120), c_:rotate(240) }
  elseif kind == "analogous" then
    return { c_:rotate(-30), c_, c_:rotate(30) }
  elseif kind == "split_complementary" then
    return { c_, c_:rotate(150), c_:rotate(210) }
  else
    return nil, "palette: unknown kind '" .. tostring(kind) .. "'"
  end
end

return M
