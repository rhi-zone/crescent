-- lib/noise/init.lua
-- Perlin noise, Simplex noise, and Fractal Brownian Motion.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.
--
-- API:
--   noise.perlin2(x, y)              -> ~[-1, 1]
--   noise.perlin3(x, y, z)           -> ~[-1, 1]
--   noise.simplex2(x, y)             -> ~[-1, 1]
--   noise.simplex3(x, y, z)          -> ~[-1, 1]
--   noise.fbm2(x, y, opts)           -> number
--   noise.fbm3(x, y, z, opts)        -> number
--   noise.seeded(seed)               -> module with same API
--   noise.normalize(v)               -> (v+1)/2, maps [-1,1] to [0,1]
--   noise._tier                      -> "pure"

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local floor = math.floor
local sqrt  = math.sqrt
local abs   = math.abs

-- ---------------------------------------------------------------------------
-- Permutation table helpers
-- ---------------------------------------------------------------------------

-- Ken Perlin's reference permutation (256 entries, values 0-255 shuffled).
local P_REF = {
  151,160,137, 91, 90, 15,131, 13,201, 95, 96, 53,194,233,  7,225,
  140, 36,103, 30, 69,142,  8, 99, 37,240, 21, 10, 23,190,  6,148,
  247,120,234, 75,  0, 26,197, 62, 94,252,219,203,117, 35, 11, 32,
   57,177, 33, 88,237,149, 56, 87,174, 20,125,136,171,168,  68,175,
   74,165, 71,134,139, 48, 27,166, 77,146,158,231, 83,111,229,122,
   60,211,133,230,220,105, 92, 41, 55, 46,245, 40,244,102,143, 54,
   65, 25, 63,161,  1,216, 80, 73,209, 76,132,187,208, 89, 18,169,
  200,196,135,130,116,188,159, 86,164,100,109,198,173,186,  3, 64,
   52,217,226,250,124,123,  5,202, 38,147,118,126,255, 82, 85,212,
  207,206, 59,227, 47, 16, 58, 17,182,189, 28, 42,223,183,170,213,
  119,248,152,  2, 44,154,163, 70,221,153,101,155,167, 43,172,  9,
  129, 22, 39,253, 19, 98,108,110, 79,113,224,232,178,185,112,104,
  218,246, 97,228,251, 34,242,193,238,210,144, 12,191,179,162,241,
   81, 51,145,235,249, 14,239,107, 49,192,214, 31,181,199,106,157,
  184, 84,204,176,115,121, 50, 45,127,  4,150,254,138,236,205, 93,
  222,114, 67, 29, 24, 72,243,141,128,195, 78, 66,215, 61,156,180,
}

-- Build a doubled permutation table (512 entries) from a 256-entry source.
-- perm[i] is 0-indexed: perm[0]..perm[511].
local function build_perm(src)
  local p = {}
  for i = 0, 255 do
    p[i]       = src[i + 1]  -- src is 1-indexed
    p[i + 256] = src[i + 1]
  end
  return p
end

-- Fisher-Yates shuffle seeded with a simple LCG.
local function shuffle(seed)
  local t = {}
  for i = 0, 255 do t[i] = i end
  local s = seed
  for i = 255, 1, -1 do
    -- LCG: next = (a*s + c) mod 2^32  (Numerical Recipes constants)
    s = (1664525 * s + 1013904223) % 0x100000000
    local j = s % (i + 1)
    t[i], t[j] = t[j], t[i]
  end
  return t
end

local function build_perm_seeded(seed)
  local arr = shuffle(seed)
  local p = {}
  for i = 0, 255 do
    p[i]       = arr[i]
    p[i + 256] = arr[i]
  end
  return p
end

-- ---------------------------------------------------------------------------
-- Improved Perlin noise (Ken Perlin, 2002)
-- ---------------------------------------------------------------------------

-- Fade: 6t^5 - 15t^4 + 10t^3  (C2 continuous)
local function fade(t)
  return t * t * t * (t * (t * 6 - 15) + 10)
end

local function lerp(t, a, b)
  return a + t * (b - a)
end

-- Gradient function: maps hash lower 4 bits to 12 gradient directions.
local function grad3(h, x, y, z)
  local h4 = h % 16
  local u = h4 < 8 and x or y
  local v
  if h4 < 4 then
    v = y
  elseif h4 == 12 or h4 == 14 then
    v = x
  else
    v = z
  end
  local a = (h4 % 2 == 0) and u or -u
  local b = (h4 % 4 < 2) and v or -v
  return a + b
end

local function make_perlin(perm)
  local function perlin3(x, y, z)
    -- Unit cube containing the point
    local xi = floor(x) % 256
    local yi = floor(y) % 256
    local zi = floor(z) % 256
    -- Fractional parts
    local xf = x - floor(x)
    local yf = y - floor(y)
    local zf = z - floor(z)
    -- Fade curves
    local u = fade(xf)
    local v = fade(yf)
    local w = fade(zf)
    -- Hash coordinates of 8 cube corners
    local a  = perm[xi]     + yi
    local aa = perm[a]      + zi
    local ab = perm[a + 1]  + zi
    local b  = perm[xi + 1] + yi
    local ba = perm[b]      + zi
    local bb = perm[b + 1]  + zi
    -- Interpolate
    return lerp(w,
      lerp(v,
        lerp(u, grad3(perm[aa],     xf,   yf,   zf),
                grad3(perm[ba],     xf-1, yf,   zf)),
        lerp(u, grad3(perm[ab],     xf,   yf-1, zf),
                grad3(perm[bb],     xf-1, yf-1, zf))),
      lerp(v,
        lerp(u, grad3(perm[aa+1],   xf,   yf,   zf-1),
                grad3(perm[ba+1],   xf-1, yf,   zf-1)),
        lerp(u, grad3(perm[ab+1],   xf,   yf-1, zf-1),
                grad3(perm[bb+1],   xf-1, yf-1, zf-1))))
  end

  local function perlin2(x, y)
    return perlin3(x, y, 0)
  end

  return perlin2, perlin3
end

-- ---------------------------------------------------------------------------
-- Classic Simplex noise (2D and 3D)
-- ---------------------------------------------------------------------------

-- 2D simplex constants
local F2 = 0.5 * (sqrt(3) - 1)   -- skew factor
local G2 = (3 - sqrt(3)) / 6     -- unskew factor

-- 2D gradient table: 8 directions on a unit circle
local GRAD2 = {
  { 1,  1}, {-1,  1}, { 1, -1}, {-1, -1},
  { 1,  0}, {-1,  0}, { 0,  1}, { 0, -1},
}

-- 3D simplex constants
local F3 = 1 / 3
local G3 = 1 / 6

-- 3D gradient table: 12 midpoints of cube edges
local GRAD3 = {
  { 1, 1, 0}, {-1, 1, 0}, { 1,-1, 0}, {-1,-1, 0},
  { 1, 0, 1}, {-1, 0, 1}, { 1, 0,-1}, {-1, 0,-1},
  { 0, 1, 1}, { 0,-1, 1}, { 0, 1,-1}, { 0,-1,-1},
}

local function make_simplex(perm)
  local function simplex2(x, y)
    -- Skew input to triangular grid
    local s  = (x + y) * F2
    local i  = floor(x + s)
    local j  = floor(y + s)
    -- Unskew back to find cell origin
    local t  = (i + j) * G2
    local x0 = x - (i - t)
    local y0 = y - (j - t)
    -- Determine which triangle we are in
    local i1, j1
    if x0 > y0 then i1, j1 = 1, 0 else i1, j1 = 0, 1 end
    -- Offsets for middle and last corners
    local x1 = x0 - i1 + G2
    local y1 = y0 - j1 + G2
    local x2 = x0 - 1 + 2 * G2
    local y2 = y0 - 1 + 2 * G2
    -- Hashed gradient indices
    local ii = i % 256
    local jj = j % 256
    local gi0 = perm[ii      + perm[jj]]      % 8 + 1
    local gi1 = perm[ii + i1 + perm[jj + j1]] % 8 + 1
    local gi2 = perm[ii + 1  + perm[jj + 1]]  % 8 + 1
    -- Contributions from 3 corners
    local n0, n1, n2 = 0, 0, 0
    local t0 = 0.5 - x0*x0 - y0*y0
    if t0 >= 0 then
      t0 = t0 * t0
      local g = GRAD2[gi0]
      n0 = t0 * t0 * (g[1]*x0 + g[2]*y0)
    end
    local t1 = 0.5 - x1*x1 - y1*y1
    if t1 >= 0 then
      t1 = t1 * t1
      local g = GRAD2[gi1]
      n1 = t1 * t1 * (g[1]*x1 + g[2]*y1)
    end
    local t2 = 0.5 - x2*x2 - y2*y2
    if t2 >= 0 then
      t2 = t2 * t2
      local g = GRAD2[gi2]
      n2 = t2 * t2 * (g[1]*x2 + g[2]*y2)
    end
    -- Scale to [-1, 1] (factor from Gustavson's paper)
    return 70 * (n0 + n1 + n2)
  end

  local function simplex3(x, y, z)
    -- Skew to tetrahedral grid
    local s  = (x + y + z) * F3
    local i  = floor(x + s)
    local j  = floor(y + s)
    local k  = floor(z + s)
    local t  = (i + j + k) * G3
    -- Unskew cell origin
    local x0 = x - (i - t)
    local y0 = y - (j - t)
    local z0 = z - (k - t)
    -- Determine which tetrahedron we are in
    local i1, j1, k1, i2, j2, k2
    if x0 >= y0 then
      if y0 >= z0 then
        i1,j1,k1, i2,j2,k2 = 1,0,0, 1,1,0
      elseif x0 >= z0 then
        i1,j1,k1, i2,j2,k2 = 1,0,0, 1,0,1
      else
        i1,j1,k1, i2,j2,k2 = 0,0,1, 1,0,1
      end
    else
      if y0 < z0 then
        i1,j1,k1, i2,j2,k2 = 0,0,1, 0,1,1
      elseif x0 < z0 then
        i1,j1,k1, i2,j2,k2 = 0,1,0, 0,1,1
      else
        i1,j1,k1, i2,j2,k2 = 0,1,0, 1,1,0
      end
    end
    -- Offsets for remaining corners
    local x1 = x0 - i1 + G3
    local y1 = y0 - j1 + G3
    local z1 = z0 - k1 + G3
    local x2 = x0 - i2 + 2*G3
    local y2 = y0 - j2 + 2*G3
    local z2 = z0 - k2 + 2*G3
    local x3 = x0 - 1  + 3*G3
    local y3 = y0 - 1  + 3*G3
    local z3 = z0 - 1  + 3*G3
    -- Hashed gradient indices
    local ii = i % 256
    local jj = j % 256
    local kk = k % 256
    local gi0 = perm[ii      + perm[jj      + perm[kk]]]       % 12 + 1
    local gi1 = perm[ii + i1 + perm[jj + j1 + perm[kk + k1]]] % 12 + 1
    local gi2 = perm[ii + i2 + perm[jj + j2 + perm[kk + k2]]] % 12 + 1
    local gi3 = perm[ii + 1  + perm[jj + 1  + perm[kk + 1]]]  % 12 + 1
    -- Corner contributions
    local n0, n1, n2, n3 = 0, 0, 0, 0
    local t0 = 0.6 - x0*x0 - y0*y0 - z0*z0
    if t0 >= 0 then
      t0 = t0 * t0
      local g = GRAD3[gi0]
      n0 = t0 * t0 * (g[1]*x0 + g[2]*y0 + g[3]*z0)
    end
    local t1 = 0.6 - x1*x1 - y1*y1 - z1*z1
    if t1 >= 0 then
      t1 = t1 * t1
      local g = GRAD3[gi1]
      n1 = t1 * t1 * (g[1]*x1 + g[2]*y1 + g[3]*z1)
    end
    local t2 = 0.6 - x2*x2 - y2*y2 - z2*z2
    if t2 >= 0 then
      t2 = t2 * t2
      local g = GRAD3[gi2]
      n2 = t2 * t2 * (g[1]*x2 + g[2]*y2 + g[3]*z2)
    end
    local t3 = 0.6 - x3*x3 - y3*y3 - z3*z3
    if t3 >= 0 then
      t3 = t3 * t3
      local g = GRAD3[gi3]
      n3 = t3 * t3 * (g[1]*x3 + g[2]*y3 + g[3]*z3)
    end
    -- Scale to [-1, 1] (factor from Gustavson's paper)
    return 32 * (n0 + n1 + n2 + n3)
  end

  return simplex2, simplex3
end

-- ---------------------------------------------------------------------------
-- Fractal Brownian Motion
-- ---------------------------------------------------------------------------

local function make_fbm2(s2)
  return function(x, y, opts)
    opts = opts or {}
    local octaves     = opts.octaves     or 6
    local persistence = opts.persistence or 0.5
    local lacunarity  = opts.lacunarity  or 2.0
    local scale       = opts.scale       or 1.0
    local value     = 0
    local amplitude = 1.0 --: number
    local frequency = scale
    for _ = 1, octaves do
      value     = value + s2(x * frequency, y * frequency) * amplitude
      amplitude = amplitude * persistence
      frequency = frequency * lacunarity
    end
    return value
  end
end

local function make_fbm3(s3)
  return function(x, y, z, opts)
    opts = opts or {}
    local octaves     = opts.octaves     or 6
    local persistence = opts.persistence or 0.5
    local lacunarity  = opts.lacunarity  or 2.0
    local scale       = opts.scale       or 1.0
    local value     = 0
    local amplitude = 1.0 --: number
    local frequency = scale
    for _ = 1, octaves do
      value     = value + s3(x * frequency, y * frequency, z * frequency) * amplitude
      amplitude = amplitude * persistence
      frequency = frequency * lacunarity
    end
    return value
  end
end

-- ---------------------------------------------------------------------------
-- Module factory
-- ---------------------------------------------------------------------------

local function make_module(perm)
  local p2, p3     = make_perlin(perm)
  local s2, s3     = make_simplex(perm)
  return {
    perlin2   = p2,
    perlin3   = p3,
    simplex2  = s2,
    simplex3  = s3,
    fbm2      = make_fbm2(s2),
    fbm3      = make_fbm3(s3),
    normalize = nil, --: (number) -> number | nil
    seeded    = nil, --: (integer) -> { [string]: unknown } | nil
  }
end

-- ---------------------------------------------------------------------------
-- Public module
-- ---------------------------------------------------------------------------

local DEFAULT_PERM = build_perm(P_REF)
local M = make_module(DEFAULT_PERM)

M._tier = "pure"

M.normalize = function(v)
  return (v + 1) * 0.5
end

M.seeded = function(seed)
  local perm = build_perm_seeded(seed)
  local m    = make_module(perm)
  m._tier    = "pure"
  m.normalize = M.normalize
  m.seeded    = M.seeded
  return m
end

return M
