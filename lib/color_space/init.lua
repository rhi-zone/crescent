if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- lib/color_space: advanced color science for LuaJIT
-- Covers: sRGB↔linear, XYZ (CIE 1931), Lab (CIELAB), LCH, OKLab, HSLuv,
--         ΔE76, CIEDE2000, and perceptual mixing.
-- All RGB inputs/outputs are normalized to [0, 1].
-- D65 illuminant throughout.

local M = {}
M._tier = "pure"

local sqrt  = math.sqrt
local abs   = math.abs
local floor = math.floor
local pi    = math.pi
local atan2 = math.atan2
local cos   = math.cos
local sin   = math.sin
local exp   = math.exp

-- atan2 in LuaJIT is math.atan2(y, x)
-- math.atan(y, x) is Lua 5.3+; use math.atan2 for LuaJIT compatibility.

----------------------------------------------------------------------
-- Clamp
----------------------------------------------------------------------

--: (number, number, number) -> number
local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

----------------------------------------------------------------------
-- sRGB ↔ linear RGB (gamma)
----------------------------------------------------------------------

-- Expand sRGB gamma to linear light.
-- Input: c ∈ [0, 1]  Output: linear ∈ [0, 1]
--: (number) -> number
function M.srgb_to_linear(c)
  c = clamp(c, 0, 1)
  if c <= 0.04045 then
    return c / 12.92
  else
    return ((c + 0.055) / 1.055) ^ 2.4
  end
end

-- Compress linear light to sRGB gamma.
-- Input: c ∈ [0, 1]  Output: sRGB ∈ [0, 1]
--: (number) -> number
function M.linear_to_srgb(c)
  c = clamp(c, 0, 1)
  if c <= 0.0031308 then
    return 12.92 * c
  elseif c >= 1 then
    return 1
  else
    return 1.055 * (c ^ (1 / 2.4)) - 0.055
  end
end

----------------------------------------------------------------------
-- sRGB ↔ XYZ (CIE 1931, D65 illuminant, sRGB primaries)
----------------------------------------------------------------------

-- sRGB → XYZ (IEC 61966-2-1 matrix)
-- Input: r, g, b ∈ [0, 1] (sRGB, gamma-encoded)
-- Output: X, Y, Z (CIE XYZ, D65)
--: (number, number, number) -> (number, number, number)
function M.rgb_to_xyz(r, g, b)
  -- linearize
  local rl = M.srgb_to_linear(r)
  local gl = M.srgb_to_linear(g)
  local bl = M.srgb_to_linear(b)
  -- sRGB → XYZ matrix (D65)
  local X = 0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl
  local Y = 0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl
  local Z = 0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl
  return X, Y, Z
end

-- XYZ → sRGB
-- Input: X, Y, Z (CIE XYZ, D65)
-- Output: r, g, b ∈ [0, 1] (sRGB, gamma-encoded, clamped)
--: (number, number, number) -> (number, number, number)
function M.xyz_to_rgb(X, Y, Z)
  -- XYZ → linear sRGB matrix
  local rl =  3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z
  local gl = -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z
  local bl =  0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z
  -- gamma encode + clamp
  local r = M.linear_to_srgb(clamp(rl, 0, 1))
  local g = M.linear_to_srgb(clamp(gl, 0, 1))
  local b = M.linear_to_srgb(clamp(bl, 0, 1))
  return r, g, b
end

----------------------------------------------------------------------
-- XYZ ↔ Lab (CIELAB, D65 white point)
----------------------------------------------------------------------

-- D65 reference white in XYZ
local D65_X = 0.95047
local D65_Y = 1.00000
local D65_Z = 1.08883

--: (number) -> number
local function lab_f(t)
  local delta = 6 / 29
  if t > delta * delta * delta then
    return t ^ (1 / 3)
  else
    return t / (3 * delta * delta) + 4 / 29
  end
end

--: (number) -> number
local function lab_f_inv(t)
  local delta = 6 / 29
  if t > delta then
    return t * t * t
  else
    return 3 * delta * delta * (t - 4 / 29)
  end
end

-- XYZ → Lab
--: (number, number, number) -> (number, number, number)
function M.xyz_to_lab(X, Y, Z)
  local fx = lab_f(X / D65_X)
  local fy = lab_f(Y / D65_Y)
  local fz = lab_f(Z / D65_Z)
  local L = 116 * fy - 16
  local a = 500 * (fx - fy)
  local b = 200 * (fy - fz)
  return L, a, b
end

-- Lab → XYZ
--: (number, number, number) -> (number, number, number)
function M.lab_to_xyz(L, a, b)
  local fy = (L + 16) / 116
  local fx = a / 500 + fy
  local fz = fy - b / 200
  local X = D65_X * lab_f_inv(fx)
  local Y = D65_Y * lab_f_inv(fy)
  local Z = D65_Z * lab_f_inv(fz)
  return X, Y, Z
end

----------------------------------------------------------------------
-- sRGB ↔ Lab (CIELAB)
----------------------------------------------------------------------

-- Input: r, g, b ∈ [0, 1] (sRGB)
-- Output: L ∈ [0, 100], a ∈ [-128, 127], b ∈ [-128, 127]
--: (number, number, number) -> (number, number, number)
function M.rgb_to_lab(r, g, b)
  local X, Y, Z = M.rgb_to_xyz(r, g, b)
  return M.xyz_to_lab(X, Y, Z)
end

-- Input: L, a, b (Lab)
-- Output: r, g, b ∈ [0, 1] (sRGB, clamped)
--: (number, number, number) -> (number, number, number)
function M.lab_to_rgb(L, a, b)
  local X, Y, Z = M.lab_to_xyz(L, a, b)
  return M.xyz_to_rgb(X, Y, Z)
end

----------------------------------------------------------------------
-- Lab ↔ LCH (polar form of Lab)
----------------------------------------------------------------------

-- Lab → LCH
-- Output: L ∈ [0, 100], C ≥ 0 (chroma), H ∈ [0, 360) (hue degrees)
--: (number, number, number) -> (number, number, number)
function M.lab_to_lch(L, a, b)
  local C = sqrt(a * a + b * b)
  local H = (atan2(b, a) * 180 / pi) % 360
  return L, C, H
end

-- LCH → Lab
--: (number, number, number) -> (number, number, number)
function M.lch_to_lab(L, C, H)
  local hr = H * pi / 180
  local a = C * cos(hr)
  local bv = C * sin(hr)
  return L, a, bv
end

-- sRGB → LCH (convenience)
--: (number, number, number) -> (number, number, number)
function M.rgb_to_lch(r, g, b)
  local L, a, bv = M.rgb_to_lab(r, g, b)
  return M.lab_to_lch(L, a, bv)
end

-- LCH → sRGB (convenience)
--: (number, number, number) -> (number, number, number)
function M.lch_to_rgb(L, C, H)
  local Lv, a, bv = M.lch_to_lab(L, C, H)
  return M.lab_to_rgb(Lv, a, bv)
end

----------------------------------------------------------------------
-- OKLab (Björn Ottosson, 2020)
-- Reference: https://bottosson.github.io/posts/oklab/
----------------------------------------------------------------------

-- sRGB → OKLab
-- Input: r, g, b ∈ [0, 1] (sRGB)
-- Output: L ∈ [0, 1], a ∈ [-0.5, 0.5], b ∈ [-0.5, 0.5] approximately
--: (number, number, number) -> (number, number, number)
function M.rgb_to_oklab(r, g, b)
  -- linearize sRGB
  local rl = M.srgb_to_linear(r)
  local gl = M.srgb_to_linear(g)
  local bl = M.srgb_to_linear(b)
  -- linear sRGB → LMS (OKLab M1 matrix)
  local l = 0.4122214708 * rl + 0.5363325363 * gl + 0.0514459929 * bl
  local m = 0.2119034982 * rl + 0.6806995451 * gl + 0.1073969566 * bl
  local s = 0.0883024619 * rl + 0.2817188376 * gl + 0.6299787005 * bl
  -- cube root
  local l_ = l ^ (1 / 3)
  local m_ = m ^ (1 / 3)
  local s_ = s ^ (1 / 3)
  -- LMS_gamma → OKLab (M2 matrix)
  local L =  0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
  local a =  1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
  local bv = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
  return L, a, bv
end

-- OKLab → sRGB
--: (number, number, number) -> (number, number, number)
function M.oklab_to_rgb(L, a, b)
  -- OKLab → LMS_gamma (inverse M2)
  local l_ = L + 0.3963377774 * a + 0.2158037573 * b
  local m_ = L - 0.1055613458 * a - 0.0638541728 * b
  local s_ = L - 0.0894841775 * a - 1.2914855480 * b
  -- cube
  local l = l_ * l_ * l_
  local m = m_ * m_ * m_
  local s = s_ * s_ * s_
  -- LMS → linear sRGB (inverse M1)
  local rl =  4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
  local gl = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
  local bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
  -- gamma encode + clamp
  local r = M.linear_to_srgb(clamp(rl, 0, 1))
  local g = M.linear_to_srgb(clamp(gl, 0, 1))
  local bv = M.linear_to_srgb(clamp(bl, 0, 1))
  return r, g, bv
end

----------------------------------------------------------------------
-- HSLuv (perceptually uniform HSL)
-- Reference: https://www.hsluv.org / https://github.com/hsluv/hsluv
-- Based on LCH projected onto the sRGB gamut boundary.
----------------------------------------------------------------------

-- sRGB primaries in XYZ (columns of the sRGB → XYZ matrix)
-- Used to compute the gamut bounds in Luv space.
--:: M_RGB_t = { [integer]: { [integer]: number } }
--: M_RGB_t
local M_RGB = {
  { 3.2409699419045226,  -1.5373831775700939, -0.4986107602930034  },
  { -0.9692436362808796,  1.8759675015077202,  0.0415550574071756  },
  { 0.0556300796969936,  -0.2039769588889765,  1.0569715142428786  },
}

local function y_to_l(Y)
  if Y <= 0.0088564516406 then  -- (6/29)^3
    return Y / 0.0011070564598  -- Y / (3*(6/29)^2) * 116 / 100... HSLuv uses L* [0,100]
  else
    return 116 * (Y ^ (1/3)) - 16
  end
end

local function l_to_y(L)
  if L <= 0.08 then  -- HSLuv threshold
    return L / 903.3  -- approximately (L/903.3) for low L
  else
    return ((L + 16) / 116) ^ 3
  end
end

-- Exact threshold constants for HSLuv
local KAPPA = 903.2962962962963  -- (29/3)^3
local EPSILON = 0.0088564516406   -- (6/29)^3

--: (number) -> number
local function y_to_l_hsluv(Y)
  if Y <= EPSILON then
    return Y * KAPPA
  else
    return 116 * (Y ^ (1/3)) - 16
  end
end

--: (number) -> number
local function l_to_y_hsluv(L)
  if L <= 8 then
    return L / KAPPA
  else
    return ((L + 16) / 116) ^ 3
  end
end

-- Compute the distance from the origin to the intersection of the
-- line (angle theta) with the sRGB gamut boundary in CIE LCH(uv).
-- Returns minimum distance across all 6 boundary lines.
--: (number, number) -> number
local function max_chroma_for_lh(L, H)
  local h_rad = H * pi / 180
  local sin_h = sin(h_rad)
  local cos_h = cos(h_rad)
  local sub1 = ((L + 16) / 116) ^ 3
  local sub2 = sub1 > EPSILON and sub1 or L / KAPPA

  local min_len = 1 / 0  -- infinity

  for i = 1, 3 do
    local m1 = M_RGB[i][1]
    local m2 = M_RGB[i][2]
    local m3 = M_RGB[i][3]
    for t = 0, 1 do
      local top1 = (284517 * m1 - 94839 * m3) * sub2
      local top2 = (838422 * m3 + 769860 * m2 + 731718 * m1) * L * sub2
                   - 769860 * t * L
      local bottom = (632260 * m3 - 126452 * m2) * sub2 + 126452 * t

      if bottom ~= 0 then
        local length = top2 / bottom / (sin_h - cos_h * top1 / bottom)
        if length > 0 then
          if length < min_len then
            min_len = length
          end
        end
      end
    end
  end
  return min_len
end

-- LCH(uv) to Luv
--: (number, number, number) -> (number, number, number)
local function lch_to_luv(L, C, H)
  local h_rad = H * pi / 180
  return L, C * cos(h_rad), C * sin(h_rad)
end

-- Luv to LCH(uv)
--: (number, number, number) -> (number, number, number)
local function luv_to_lch(L, U, V)
  local C = sqrt(U * U + V * V)
  local H = (atan2(V, U) * 180 / pi) % 360
  return L, C, H
end

-- XYZ to Luv
--: (number, number, number) -> (number, number, number)
local function xyz_to_luv(X, Y, Z)
  if X == 0 and Y == 0 and Z == 0 then
    return 0, 0, 0
  end
  local denom = X + 15 * Y + 3 * Z
  local u_ = 4 * X / denom
  local v_ = 9 * Y / denom
  -- D65 reference white u'_n, v'_n
  local un = 0.19783000664283
  local vn = 0.46831999493879
  local L = y_to_l_hsluv(Y)
  if L == 0 then return 0, 0, 0 end
  local U = 13 * L * (u_ - un)
  local V = 13 * L * (v_ - vn)
  return L, U, V
end

-- Luv to XYZ
--: (number, number, number) -> (number, number, number)
local function luv_to_xyz(L, U, V)
  if L == 0 then return 0, 0, 0 end
  local un = 0.19783000664283
  local vn = 0.46831999493879
  local u_ = U / (13 * L) + un
  local v_ = V / (13 * L) + vn
  local Y = l_to_y_hsluv(L)
  local X = -(9 * Y * u_) / ((u_ - 4) * v_ - u_ * v_)
  local Z = (9 * Y - 15 * v_ * Y - v_ * X) / (3 * v_)
  return X, Y, Z
end

-- sRGB → HSLuv
-- Output: H ∈ [0, 360), S ∈ [0, 100], L ∈ [0, 100]
--: (number, number, number) -> (number, number, number)
function M.rgb_to_hsluv(r, g, b)
  -- rgb → xyz → luv → lch(uv)
  local X, Y, Z = M.rgb_to_xyz(r, g, b)
  local L, U, V = xyz_to_luv(X, Y, Z)
  local _, C, H = luv_to_lch(L, U, V)
  -- special cases
  if L > 99.9999999 then return H, 0, 100 end
  if L < 0.0000001  then return H, 0, 0   end
  local max_c = max_chroma_for_lh(L, H)
  local S = C / max_c * 100
  return H, S, L
end

-- HSLuv → sRGB
-- Input: H ∈ [0, 360), S ∈ [0, 100], L ∈ [0, 100]
-- Output: r, g, b ∈ [0, 1]
--: (number, number, number) -> (number, number, number)
function M.hsluv_to_rgb(H, S, L)
  if L > 99.9999999 then return 1, 1, 1 end
  if L < 0.0000001  then return 0, 0, 0 end
  local max_c = max_chroma_for_lh(L, H)
  local C = max_c / 100 * S
  local lv, U, V = lch_to_luv(L, C, H)
  local X, Y, Z = luv_to_xyz(lv, U, V)
  return M.xyz_to_rgb(X, Y, Z)
end

----------------------------------------------------------------------
-- Delta-E (color difference)
----------------------------------------------------------------------

-- CIEDE76 — simple Euclidean distance in Lab
-- lab1, lab2: tables or 3 values {L, a, b}
--: ({ [integer]: number }, { [integer]: number }) -> number
function M.delta_e_76(lab1, lab2)
  local dL = lab1[1] - lab2[1]
  local da = lab1[2] - lab2[2]
  local db = lab1[3] - lab2[3]
  return sqrt(dL * dL + da * da + db * db)
end

-- CIEDE2000 — perceptual color difference (CIE 2001)
-- lab1, lab2: tables {L, a, b}
--: ({ [integer]: number }, { [integer]: number }) -> number
function M.delta_e_2000(lab1, lab2)
  local L1, a1, b1 = lab1[1], lab1[2], lab1[3]
  local L2, a2, b2 = lab2[1], lab2[2], lab2[3]

  -- Step 1: adjusted a'
  local C1 = sqrt(a1 * a1 + b1 * b1)
  local C2 = sqrt(a2 * a2 + b2 * b2)
  local C_avg7 = ((C1 + C2) / 2) ^ 7
  local k = 0.5 * (1 - sqrt(C_avg7 / (C_avg7 + 25 ^ 7)))
  local a1p = a1 * (1 + k)
  local a2p = a2 * (1 + k)

  -- Step 2: C', h'
  local C1p = sqrt(a1p * a1p + b1 * b1)
  local C2p = sqrt(a2p * a2p + b2 * b2)

  local h1p = (atan2(b1, a1p) * 180 / pi) % 360
  local h2p = (atan2(b2, a2p) * 180 / pi) % 360

  -- Step 3: ΔL', ΔC', Δh'
  local dLp = L2 - L1
  local dCp = C2p - C1p

  local dhp
  if C1p * C2p == 0 then
    dhp = 0
  elseif abs(h2p - h1p) <= 180 then
    dhp = h2p - h1p
  elseif h2p - h1p > 180 then
    dhp = h2p - h1p - 360
  else
    dhp = h2p - h1p + 360
  end

  local dHp = 2 * sqrt(C1p * C2p) * sin(dhp / 2 * pi / 180)

  -- Step 4: CIEDE2000
  local Lp_avg = (L1 + L2) / 2
  local Cp_avg = (C1p + C2p) / 2

  local hp_avg
  if C1p * C2p == 0 then
    hp_avg = h1p + h2p
  elseif abs(h1p - h2p) <= 180 then
    hp_avg = (h1p + h2p) / 2
  elseif h1p + h2p < 360 then
    hp_avg = (h1p + h2p + 360) / 2
  else
    hp_avg = (h1p + h2p - 360) / 2
  end

  local T = 1
    - 0.17 * cos((hp_avg - 30) * pi / 180)
    + 0.24 * cos(2 * hp_avg * pi / 180)
    + 0.32 * cos((3 * hp_avg + 6) * pi / 180)
    - 0.20 * cos((4 * hp_avg - 63) * pi / 180)

  local SL = 1 + 0.015 * (Lp_avg - 50) ^ 2 / sqrt(20 + (Lp_avg - 50) ^ 2)
  local SC = 1 + 0.045 * Cp_avg
  local SH = 1 + 0.015 * Cp_avg * T

  local Cp_avg7 = Cp_avg ^ 7
  local RC = 2 * sqrt(Cp_avg7 / (Cp_avg7 + 25 ^ 7))
  local d_theta = 30 * exp(-((hp_avg - 275) / 25) ^ 2)
  local RT = -sin(2 * d_theta * pi / 180) * RC

  local KL, KC, KH = 1, 1, 1
  local dE = sqrt(
    (dLp  / (KL * SL)) ^ 2 +
    (dCp  / (KC * SC)) ^ 2 +
    (dHp  / (KH * SH)) ^ 2 +
    RT * (dCp / (KC * SC)) * (dHp / (KH * SH))
  )
  return dE
end

----------------------------------------------------------------------
-- Perceptual mixing
----------------------------------------------------------------------

-- Mix two Lab colors at parameter t ∈ [0, 1]
-- lab1, lab2: tables {L, a, b}
-- Returns: table {L, a, b}
--: ({ [integer]: number }, { [integer]: number }, number) -> { [integer]: number }
function M.mix_lab(lab1, lab2, t)
  t = clamp(t, 0, 1)
  return {
    lab1[1] + (lab2[1] - lab1[1]) * t,
    lab1[2] + (lab2[2] - lab1[2]) * t,
    lab1[3] + (lab2[3] - lab1[3]) * t,
  }
end

-- Mix two OKLab colors at parameter t ∈ [0, 1]
-- c1, c2: tables {L, a, b}
-- Returns: table {L, a, b}
--: ({ [integer]: number }, { [integer]: number }, number) -> { [integer]: number }
function M.mix_oklab(c1, c2, t)
  t = clamp(t, 0, 1)
  return {
    c1[1] + (c2[1] - c1[1]) * t,
    c1[2] + (c2[2] - c1[2]) * t,
    c1[3] + (c2[3] - c1[3]) * t,
  }
end

return M
