if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Color object metatable
local Color = {}
Color.__index = Color

-- Internal constructor: stores RGB 0-255 + alpha 0-1
local function _color(r, g, b, a)
  return setmetatable({ _r = r, _g = g, _b = b, _a = a or 1.0 }, Color)
end

-- Clamp a number to [lo, hi]
local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

-- Round to nearest integer
local function round(x)
  return math.floor(x + 0.5)
end

----------------------------------------------------------------------
-- HSL/HSV helpers
----------------------------------------------------------------------

local function rgb_to_hsl(r, g, b)
  r, g, b = r / 255, g / 255, b / 255
  local max = math.max(r, g, b)
  local min = math.min(r, g, b)
  local h, s
  local l = (max + min) / 2

  if max == min then
    h, s = 0, 0
  else
    local d = max - min
    s = l > 0.5 and d / (2 - max - min) or d / (max + min)
    if max == r then
      h = (g - b) / d + (g < b and 6 or 0)
    elseif max == g then
      h = (b - r) / d + 2
    else
      h = (r - g) / d + 4
    end
    h = h * 60
  end
  return h, s * 100, l * 100
end

local function hsl_to_rgb(h, s, l)
  h = h % 360
  s, l = s / 100, l / 100
  if s == 0 then
    local v = round(l * 255)
    return v, v, v
  end
  local function hue2rgb(p, q, t)
    if t < 0 then t = t + 1 end
    if t > 1 then t = t - 1 end
    if t < 1/6 then return p + (q - p) * 6 * t end
    if t < 1/2 then return q end
    if t < 2/3 then return p + (q - p) * (2/3 - t) * 6 end
    return p
  end
  local q = l < 0.5 and l * (1 + s) or l + s - l * s
  local p = 2 * l - q
  local r = hue2rgb(p, q, h / 360 + 1/3)
  local g = hue2rgb(p, q, h / 360)
  local b = hue2rgb(p, q, h / 360 - 1/3)
  return round(r * 255), round(g * 255), round(b * 255)
end

local function rgb_to_hsv(r, g, b)
  r, g, b = r / 255, g / 255, b / 255
  local max = math.max(r, g, b)
  local min = math.min(r, g, b)
  local h, s
  local v = max

  local d = max - min
  s = max == 0 and 0 or d / max

  if max == min then
    h = 0
  else
    if max == r then
      h = (g - b) / d + (g < b and 6 or 0)
    elseif max == g then
      h = (b - r) / d + 2
    else
      h = (r - g) / d + 4
    end
    h = h * 60
  end
  return h, s * 100, v * 100
end

local function hsv_to_rgb(h, s, v)
  h = h % 360
  s, v = s / 100, v / 100
  local c = v * s
  local x = c * (1 - math.abs((h / 60) % 2 - 1))
  local m = v - c
  local r, g, b
  if h < 60 then      r, g, b = c, x, 0
  elseif h < 120 then r, g, b = x, c, 0
  elseif h < 180 then r, g, b = 0, c, x
  elseif h < 240 then r, g, b = 0, x, c
  elseif h < 300 then r, g, b = x, 0, c
  else                 r, g, b = c, 0, x
  end
  return round((r + m) * 255), round((g + m) * 255), round((b + m) * 255)
end

----------------------------------------------------------------------
-- Named CSS colors
----------------------------------------------------------------------

local NAMED = {
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

----------------------------------------------------------------------
-- Constructors
----------------------------------------------------------------------

function M.rgb(r, g, b, a)
  return _color(
    round(clamp(r, 0, 255)),
    round(clamp(g, 0, 255)),
    round(clamp(b, 0, 255)),
    a and clamp(a, 0, 1) or 1.0
  )
end

function M.rgb01(r, g, b, a)
  return _color(
    round(clamp(r, 0, 1) * 255),
    round(clamp(g, 0, 1) * 255),
    round(clamp(b, 0, 1) * 255),
    a and clamp(a, 0, 1) or 1.0
  )
end

function M.hsl(h, s, l, a)
  local r, g, b = hsl_to_rgb(h, clamp(s, 0, 100), clamp(l, 0, 100))
  return _color(r, g, b, a and clamp(a, 0, 1) or 1.0)
end

function M.hsv(h, s, v, a)
  local r, g, b = hsv_to_rgb(h, clamp(s, 0, 100), clamp(v, 0, 100))
  return _color(r, g, b, a and clamp(a, 0, 1) or 1.0)
end

function M.hex(s)
  if type(s) ~= "string" then
    return nil, "hex: expected string, got " .. type(s)
  end
  -- strip leading #
  if s:sub(1, 1) == "#" then s = s:sub(2) end
  -- expand shorthand
  if #s == 3 then
    local r, g, b = s:sub(1,1), s:sub(2,2), s:sub(3,3)
    s = r .. r .. g .. g .. b .. b
  elseif #s == 4 then
    local r, g, b, a = s:sub(1,1), s:sub(2,2), s:sub(3,3), s:sub(4,4)
    s = r .. r .. g .. g .. b .. b .. a .. a
  end
  if #s ~= 6 and #s ~= 8 then
    return nil, "hex: invalid hex color string"
  end
  if s:find("[^0-9a-fA-F]") then
    return nil, "hex: invalid hex characters"
  end
  local r = tonumber(s:sub(1, 2), 16)
  local g = tonumber(s:sub(3, 4), 16)
  local b = tonumber(s:sub(5, 6), 16)
  local a = 1.0
  if #s == 8 then
    a = tonumber(s:sub(7, 8), 16) / 255
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
  return self._r, self._g, self._b
end

function Color:to_rgb01()
  return self._r / 255, self._g / 255, self._b / 255
end

function Color:to_hsl()
  return rgb_to_hsl(self._r, self._g, self._b)
end

function Color:to_hsv()
  return rgb_to_hsv(self._r, self._g, self._b)
end

function Color:to_hex()
  return string.format("#%02x%02x%02x", self._r, self._g, self._b)
end

function Color:to_array()
  return { self._r, self._g, self._b }
end

function Color:get_alpha()
  return self._a
end

----------------------------------------------------------------------
-- Manipulation (all return new Color)
----------------------------------------------------------------------

function Color:lighten(amount)
  local h, s, l = rgb_to_hsl(self._r, self._g, self._b)
  l = clamp(l + amount * 100, 0, 100)
  local r, g, b = hsl_to_rgb(h, s, l)
  return _color(r, g, b, self._a)
end

function Color:darken(amount)
  local h, s, l = rgb_to_hsl(self._r, self._g, self._b)
  l = clamp(l - amount * 100, 0, 100)
  local r, g, b = hsl_to_rgb(h, s, l)
  return _color(r, g, b, self._a)
end

function Color:saturate(amount)
  local h, s, l = rgb_to_hsl(self._r, self._g, self._b)
  s = clamp(s + amount * 100, 0, 100)
  local r, g, b = hsl_to_rgb(h, s, l)
  return _color(r, g, b, self._a)
end

function Color:desaturate(amount)
  local h, s, l = rgb_to_hsl(self._r, self._g, self._b)
  s = clamp(s - amount * 100, 0, 100)
  local r, g, b = hsl_to_rgb(h, s, l)
  return _color(r, g, b, self._a)
end

function Color:rotate(degrees)
  local h, s, l = rgb_to_hsl(self._r, self._g, self._b)
  h = (h + degrees) % 360
  local r, g, b = hsl_to_rgb(h, s, l)
  return _color(r, g, b, self._a)
end

function Color:complement()
  return self:rotate(180)
end

function Color:invert()
  return _color(255 - self._r, 255 - self._g, 255 - self._b, self._a)
end

function Color:grayscale()
  local h, _, l = rgb_to_hsl(self._r, self._g, self._b)
  local r, g, b = hsl_to_rgb(h, 0, l)
  return _color(r, g, b, self._a)
end

function Color:alpha(a)
  return _color(self._r, self._g, self._b, clamp(a, 0, 1))
end

function Color:mix(other, t)
  t = t or 0.5
  local r = round(self._r + (other._r - self._r) * t)
  local g = round(self._g + (other._g - self._g) * t)
  local b = round(self._b + (other._b - self._b) * t)
  local a = self._a + (other._a - self._a) * t
  return _color(r, g, b, a)
end

----------------------------------------------------------------------
-- Equality and string representation
----------------------------------------------------------------------

function Color:eq(other)
  return self._r == other._r and self._g == other._g and self._b == other._b and self._a == other._a
end

function Color:__tostring()
  if self._a < 1.0 then
    return string.format("rgba(%d, %d, %d, %.2f)", self._r, self._g, self._b, self._a)
  end
  return self:to_hex()
end

function Color.__eq(a, b)
  return a._r == b._r and a._g == b._g and a._b == b._b and a._a == b._a
end

----------------------------------------------------------------------
-- Utilities
----------------------------------------------------------------------

function M.luminance(c)
  local function linearize(v)
    v = v / 255
    return v <= 0.03928 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * linearize(c._r) + 0.7152 * linearize(c._g) + 0.0722 * linearize(c._b)
end

function M.contrast(c1, c2)
  local l1 = M.luminance(c1)
  local l2 = M.luminance(c2)
  local lighter = math.max(l1, l2)
  local darker = math.min(l1, l2)
  return (lighter + 0.05) / (darker + 0.05)
end

function M.distance(c1, c2)
  local dr = c1._r - c2._r
  local dg = c1._g - c2._g
  local db = c1._b - c2._b
  return math.sqrt(dr * dr + dg * dg + db * db)
end

function M.is_light(c)
  return M.luminance(c) > 0.5
end

function M.is_dark(c)
  return M.luminance(c) <= 0.5
end

function M.palette(c, kind)
  if kind == "complementary" then
    return { c, c:complement() }
  elseif kind == "triadic" then
    return { c, c:rotate(120), c:rotate(240) }
  elseif kind == "analogous" then
    return { c:rotate(-30), c, c:rotate(30) }
  elseif kind == "split_complementary" then
    return { c, c:rotate(150), c:rotate(210) }
  else
    return nil, "palette: unknown kind '" .. tostring(kind) .. "'"
  end
end

return M
