-- lib/noise_gen/init.lua
-- Procedural noise generation: Value, Perlin, Simplex, Worley, and fractal
-- variants (fBm, turbulence, domain warping, ridged noise).
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.
--
-- API:
--   N.value2d(x, y, seed)              -> float in [-1, 1]
--   N.value3d(x, y, z, seed)           -> float in [-1, 1]
--   N.perlin2d(x, y, seed)             -> float in [-1, 1]
--   N.perlin3d(x, y, z, seed)          -> float in [-1, 1]
--   N.simplex2d(x, y, seed)            -> float in [-1, 1]
--   N.simplex3d(x, y, z, seed)         -> float in [-1, 1]
--   N.worley2d(x, y, seed, opts)       -> float in [0, 1] (k-th distance)
--   N.fbm2d(x, y, seed, opts)          -> float
--   N.turbulence2d(x, y, seed, opts)   -> float
--   N.warp2d(x, y, seed, opts)         -> float
--   N.ridged2d(x, y, seed, opts)       -> float in [0, 1]
--   N.map2d(width, height, opts)       -> 2D array, map[y][x] in [-1, 1]
--   N.normalize(map)                   -> map with values in [0, 1] (in-place)
--   N._tier                            -> "pure"

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit   = require("bit")
local floor = math.floor
local sqrt  = math.sqrt
local abs   = math.abs
local max   = math.max
local min   = math.min

local bxor    = bit.bxor
local rshift  = bit.rshift
local band    = bit.band

-- ---------------------------------------------------------------------------
-- Hash utilities
-- ---------------------------------------------------------------------------

-- Integer hash mixing: produces a float in [0, 1).
local function hash2(x, y, seed)
  local ix = floor(x)
  local iy = floor(y)
  local n = ix * 1619 + iy * 31337 + seed * 1013
  n = bxor(n, rshift(n, 13))
  n = n * (n * n * 60493 + 19990303) + 1376312589
  return band(n, 0x7fffffff) / 0x7fffffff
end

local function hash3(x, y, z, seed)
  local ix = floor(x)
  local iy = floor(y)
  local iz = floor(z)
  local n = ix * 1619 + iy * 31337 + iz * 6971 + seed * 1013
  n = bxor(n, rshift(n, 13))
  n = n * (n * n * 60493 + 19990303) + 1376312589
  return band(n, 0x7fffffff) / 0x7fffffff
end

-- Hash returning float in [-1, 1].
local function hash2s(x, y, seed)
  return hash2(x, y, seed) * 2 - 1
end

local function hash3s(x, y, z, seed)
  return hash3(x, y, z, seed) * 2 - 1
end

-- ---------------------------------------------------------------------------
-- Interpolation helpers
-- ---------------------------------------------------------------------------

local function fade(t)
  return t * t * t * (t * (t * 6 - 15) + 10)
end

local function lerp(t, a, b)
  return a + t * (b - a)
end

-- Bilinear interpolation
local function bilerp(u, v, aa, ba, ab, bb)
  return lerp(v, lerp(u, aa, ba), lerp(u, ab, bb))
end

-- ---------------------------------------------------------------------------
-- Permutation table helpers (seeded)
-- ---------------------------------------------------------------------------

local function build_perm_seeded(seed)
  local t = {}
  for i = 0, 255 do t[i] = i end
  local s = seed
  for i = 255, 1, -1 do
    s = (1664525 * s + 1013904223) % 0x100000000
    local j = s % (i + 1)
    t[i], t[j] = t[j], t[i]
  end
  local p = {}
  for i = 0, 255 do
    p[i]       = t[i]
    p[i + 256] = t[i]
  end
  return p
end

-- Cache of permutation tables by seed to avoid rebuilding each call.
-- We keep up to 8 entries (LRU would be overkill for typical usage).
local perm_cache   = {}
local perm_keys    = {}  -- ordered insertion list
local PERM_CACHE_MAX = 8

local function get_perm(seed)
  local p = perm_cache[seed]
  if p then return p end
  p = build_perm_seeded(seed)
  if #perm_keys >= PERM_CACHE_MAX then
    local oldest = perm_keys[1]
    perm_cache[oldest] = nil
    table.remove(perm_keys, 1)
  end
  perm_cache[seed] = p
  perm_keys[#perm_keys + 1] = seed
  return p
end

-- ---------------------------------------------------------------------------
-- Value noise
-- ---------------------------------------------------------------------------

local function value2d(x, y, seed)
  local x0 = floor(x)
  local y0 = floor(y)
  local xf = x - x0
  local yf = y - y0
  local u  = fade(xf)
  local v  = fade(yf)
  local aa = hash2s(x0,   y0,   seed)
  local ba = hash2s(x0+1, y0,   seed)
  local ab = hash2s(x0,   y0+1, seed)
  local bb = hash2s(x0+1, y0+1, seed)
  return bilerp(u, v, aa, ba, ab, bb)
end

local function value3d(x, y, z, seed)
  local x0 = floor(x)
  local y0 = floor(y)
  local z0 = floor(z)
  local xf = x - x0
  local yf = y - y0
  local zf = z - z0
  local u  = fade(xf)
  local v  = fade(yf)
  local w  = fade(zf)
  local aaa = hash3s(x0,   y0,   z0,   seed)
  local baa = hash3s(x0+1, y0,   z0,   seed)
  local aba = hash3s(x0,   y0+1, z0,   seed)
  local bba = hash3s(x0+1, y0+1, z0,   seed)
  local aab = hash3s(x0,   y0,   z0+1, seed)
  local bab = hash3s(x0+1, y0,   z0+1, seed)
  local abb = hash3s(x0,   y0+1, z0+1, seed)
  local bbb = hash3s(x0+1, y0+1, z0+1, seed)
  return lerp(w,
    bilerp(u, v, aaa, baa, aba, bba),
    bilerp(u, v, aab, bab, abb, bbb))
end

-- ---------------------------------------------------------------------------
-- Improved Perlin noise (Ken Perlin, 2002)
-- ---------------------------------------------------------------------------

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
  local b = (h4 % 4 < 2)  and v or -v
  return a + b
end

local function perlin3d(x, y, z, seed)
  local perm = get_perm(seed)
  local xi = floor(x) % 256
  local yi = floor(y) % 256
  local zi = floor(z) % 256
  local xf = x - floor(x)
  local yf = y - floor(y)
  local zf = z - floor(z)
  local u  = fade(xf)
  local v  = fade(yf)
  local w  = fade(zf)
  local a  = perm[xi]     + yi
  local aa = perm[a]      + zi
  local ab = perm[a + 1]  + zi
  local b  = perm[xi + 1] + yi
  local ba = perm[b]      + zi
  local bb = perm[b + 1]  + zi
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

local function perlin2d(x, y, seed)
  return perlin3d(x, y, 0, seed)
end

-- ---------------------------------------------------------------------------
-- Simplex noise (2D and 3D)
-- ---------------------------------------------------------------------------

local F2 = 0.5 * (sqrt(3) - 1)
local G2 = (3 - sqrt(3)) / 6

local GRAD2 = {
  { 1,  1}, {-1,  1}, { 1, -1}, {-1, -1},
  { 1,  0}, {-1,  0}, { 0,  1}, { 0, -1},
}

local F3 = 1 / 3
local G3 = 1 / 6

local GRAD3S = {
  { 1, 1, 0}, {-1, 1, 0}, { 1,-1, 0}, {-1,-1, 0},
  { 1, 0, 1}, {-1, 0, 1}, { 1, 0,-1}, {-1, 0,-1},
  { 0, 1, 1}, { 0,-1, 1}, { 0, 1,-1}, { 0,-1,-1},
}

local function simplex2d(x, y, seed)
  local perm = get_perm(seed)
  local s  = (x + y) * F2
  local i  = floor(x + s)
  local j  = floor(y + s)
  local t  = (i + j) * G2
  local x0 = x - (i - t)
  local y0 = y - (j - t)
  local i1, j1
  if x0 > y0 then i1, j1 = 1, 0 else i1, j1 = 0, 1 end
  local x1 = x0 - i1 + G2
  local y1 = y0 - j1 + G2
  local x2 = x0 - 1 + 2 * G2
  local y2 = y0 - 1 + 2 * G2
  local ii = i % 256
  local jj = j % 256
  local gi0 = perm[ii      + perm[jj]]      % 8 + 1
  local gi1 = perm[ii + i1 + perm[jj + j1]] % 8 + 1
  local gi2 = perm[ii + 1  + perm[jj + 1]]  % 8 + 1
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
  return 70 * (n0 + n1 + n2)
end

local function simplex3d(x, y, z, seed)
  local perm = get_perm(seed)
  local s  = (x + y + z) * F3
  local i  = floor(x + s)
  local j  = floor(y + s)
  local k  = floor(z + s)
  local t  = (i + j + k) * G3
  local x0 = x - (i - t)
  local y0 = y - (j - t)
  local z0 = z - (k - t)
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
  local x1 = x0 - i1 + G3
  local y1 = y0 - j1 + G3
  local z1 = z0 - k1 + G3
  local x2 = x0 - i2 + 2*G3
  local y2 = y0 - j2 + 2*G3
  local z2 = z0 - k2 + 2*G3
  local x3 = x0 - 1  + 3*G3
  local y3 = y0 - 1  + 3*G3
  local z3 = z0 - 1  + 3*G3
  local ii = i % 256
  local jj = j % 256
  local kk = k % 256
  local gi0 = perm[ii      + perm[jj      + perm[kk]]]       % 12 + 1
  local gi1 = perm[ii + i1 + perm[jj + j1 + perm[kk + k1]]] % 12 + 1
  local gi2 = perm[ii + i2 + perm[jj + j2 + perm[kk + k2]]] % 12 + 1
  local gi3 = perm[ii + 1  + perm[jj + 1  + perm[kk + 1]]]  % 12 + 1
  local n0, n1, n2, n3 = 0, 0, 0, 0
  local t0 = 0.6 - x0*x0 - y0*y0 - z0*z0
  if t0 >= 0 then
    t0 = t0 * t0
    local g = GRAD3S[gi0]
    n0 = t0 * t0 * (g[1]*x0 + g[2]*y0 + g[3]*z0)
  end
  local t1 = 0.6 - x1*x1 - y1*y1 - z1*z1
  if t1 >= 0 then
    t1 = t1 * t1
    local g = GRAD3S[gi1]
    n1 = t1 * t1 * (g[1]*x1 + g[2]*y1 + g[3]*z1)
  end
  local t2 = 0.6 - x2*x2 - y2*y2 - z2*z2
  if t2 >= 0 then
    t2 = t2 * t2
    local g = GRAD3S[gi2]
    n2 = t2 * t2 * (g[1]*x2 + g[2]*y2 + g[3]*z2)
  end
  local t3 = 0.6 - x3*x3 - y3*y3 - z3*z3
  if t3 >= 0 then
    t3 = t3 * t3
    local g = GRAD3S[gi3]
    n3 = t3 * t3 * (g[1]*x3 + g[2]*y3 + g[3]*z3)
  end
  return 32 * (n0 + n1 + n2 + n3)
end

-- ---------------------------------------------------------------------------
-- Worley noise (cellular / Voronoi)
-- ---------------------------------------------------------------------------

-- Return x and y components of the random point inside cell (cx, cy).
-- Both components are in [0, 1) relative to cell origin.
local function cell_point(cx, cy, seed)
  local h1 = hash2(cx, cy,     seed)
  local h2 = hash2(cx, cy + 1, seed + 7919)
  return h1, h2
end

local function dist_euclidean(dx, dy)
  return sqrt(dx*dx + dy*dy)
end

local function dist_manhattan(dx, dy)
  return abs(dx) + abs(dy)
end

local function dist_chebyshev(dx, dy)
  local adx = abs(dx)
  local ady = abs(dy)
  return adx > ady and adx or ady
end

-- Approximate normalization constants for 2D Worley nearest-point distances.
-- These bring F1 roughly into [0, 1] for the respective metrics.
local WORLEY_NORM = {
  euclidean = 1.0,   -- max F1 ≈ 0.7 in practice; we keep it [0,1] via clamp
  manhattan = 1.0,
  chebyshev = 1.0,
}

local function worley2d(x, y, seed, opts)
  opts = opts or {}
  local k      = opts.k      or 1
  local metric = opts.metric or "euclidean"

  local dist_fn
  if metric == "manhattan" then
    dist_fn = dist_manhattan
  elseif metric == "chebyshev" then
    dist_fn = dist_chebyshev
  else
    dist_fn = dist_euclidean
  end

  local cx0 = floor(x)
  local cy0 = floor(y)

  -- Collect distances from all 9 surrounding cells.
  local dists = {}
  for dcx = -1, 1 do
    for dcy = -1, 1 do
      local cx = cx0 + dcx
      local cy = cy0 + dcy
      local px, py = cell_point(cx, cy, seed)
      -- Point world position
      local wpx = cx + px
      local wpy = cy + py
      local d   = dist_fn(x - wpx, y - wpy)
      dists[#dists + 1] = d
    end
  end

  -- Partial sort to find k-th smallest (insertion sort on small array).
  for i = 2, #dists do
    local v = dists[i]
    local j = i - 1
    while j >= 1 and dists[j] > v do
      dists[j + 1] = dists[j]
      j = j - 1
    end
    dists[j + 1] = v
  end

  local fk = dists[k] or dists[#dists]
  -- Max theoretical F1 for Euclidean in unit grid ≈ sqrt(2)/2 ≈ 0.707.
  -- We normalize so that value is clamped to [0, 1].
  if metric == "euclidean" then
    fk = fk / (sqrt(2) / 2)
  elseif metric == "manhattan" then
    fk = fk / 2.0
  elseif metric == "chebyshev" then
    fk = fk / 1.0
  end
  if fk > 1 then fk = 1 end
  return fk
end

-- ---------------------------------------------------------------------------
-- Fractal Brownian Motion (fBm)
-- ---------------------------------------------------------------------------

local function fbm2d(x, y, seed, opts)
  opts = opts or {}
  local octaves     = opts.octaves     or 6
  local lacunarity  = opts.lacunarity  or 2.0
  local persistence = opts.persistence or 0.5
  local noise_fn    = opts.noise_fn    or perlin2d
  local value     = 0
  local amplitude = 1.0
  local frequency = 1.0
  for _ = 1, octaves do
    value     = value + noise_fn(x * frequency, y * frequency, seed) * amplitude
    amplitude = amplitude * persistence
    frequency = frequency * lacunarity
  end
  return value
end

-- ---------------------------------------------------------------------------
-- Turbulence (sum of absolute values of octaves)
-- ---------------------------------------------------------------------------

local function turbulence2d(x, y, seed, opts)
  opts = opts or {}
  local octaves     = opts.octaves     or 6
  local lacunarity  = opts.lacunarity  or 2.0
  local persistence = opts.persistence or 0.5
  local noise_fn    = opts.noise_fn    or perlin2d
  local value     = 0
  local amplitude = 1.0
  local frequency = 1.0
  for _ = 1, octaves do
    value     = value + abs(noise_fn(x * frequency, y * frequency, seed)) * amplitude
    amplitude = amplitude * persistence
    frequency = frequency * lacunarity
  end
  return value
end

-- ---------------------------------------------------------------------------
-- Ridged noise (inverted fBm — sharp ridges)
-- ---------------------------------------------------------------------------

local function ridged2d(x, y, seed, opts)
  opts = opts or {}
  local octaves     = opts.octaves     or 6
  local lacunarity  = opts.lacunarity  or 2.0
  local persistence = opts.persistence or 0.5
  local noise_fn    = opts.noise_fn    or perlin2d
  local value     = 0
  local amplitude = 1.0
  local frequency = 1.0
  local weight    = 1.0
  for _ = 1, octaves do
    local signal = noise_fn(x * frequency, y * frequency, seed)
    -- Invert and square to create ridges
    signal = (1 - abs(signal)) * weight
    value  = value + signal * amplitude
    weight = signal
    if weight < 0 then weight = 0 end
    amplitude = amplitude * persistence
    frequency = frequency * lacunarity
  end
  -- Normalize: with default settings output is roughly in [0, ~2]; map to [0, 1]
  local max_val = 0
  local a2 = 1.0
  for _ = 1, octaves do
    max_val = max_val + a2
    a2 = a2 * persistence
  end
  return value / max_val
end

-- ---------------------------------------------------------------------------
-- Domain warping
-- ---------------------------------------------------------------------------

local function warp2d(x, y, seed, opts)
  opts = opts or {}
  local strength = opts.strength or 1.0
  local noise_fn = opts.noise_fn or perlin2d
  -- Warp x and y by two independent noise fields.
  local wx = noise_fn(x, y, seed)
  local wy = noise_fn(x + 5.2, y + 1.3, seed + 1)
  return noise_fn(x + strength * wx, y + strength * wy, seed + 2)
end

-- ---------------------------------------------------------------------------
-- 2D noise map generation
-- ---------------------------------------------------------------------------

local function map2d(width, height, opts)
  opts = opts or {}
  local scale   = opts.scale   or 0.01
  local seed    = opts.seed    or 0
  local octaves = opts.octaves or 1
  local fn      = opts.fn      or perlin2d

  -- Choose evaluator: plain noise or fBm.
  local eval
  if octaves > 1 then
    local fbm_opts = {
      octaves     = octaves,
      lacunarity  = opts.lacunarity  or 2.0,
      persistence = opts.persistence or 0.5,
      noise_fn    = fn,
    }
    eval = function(x, y)
      return fbm2d(x, y, seed, fbm_opts)
    end
  else
    eval = function(x, y)
      return fn(x, y, seed)
    end
  end

  local map = {}
  for row = 1, height do
    local r = {}
    local wy = (row - 1) * scale
    for col = 1, width do
      r[col] = eval((col - 1) * scale, wy)
    end
    map[row] = r
  end
  return map
end

-- ---------------------------------------------------------------------------
-- Normalize a map in-place to [0, 1]
-- ---------------------------------------------------------------------------

local function normalize(map)
  local lo =  math.huge
  local hi = -math.huge
  for _, row in ipairs(map) do
    for _, v in ipairs(row) do
      if v < lo then lo = v end
      if v > hi then hi = v end
    end
  end
  local range = hi - lo
  if range == 0 then
    for _, row in ipairs(map) do
      for j = 1, #row do row[j] = 0.5 end
    end
  else
    local inv = 1 / range
    for _, row in ipairs(map) do
      for j = 1, #row do row[j] = (row[j] - lo) * inv end
    end
  end
  return map
end

-- ---------------------------------------------------------------------------
-- Public module
-- ---------------------------------------------------------------------------

local M = {}

M._tier       = "pure"
M.value2d     = value2d
M.value3d     = value3d
M.perlin2d    = perlin2d
M.perlin3d    = perlin3d
M.simplex2d   = simplex2d
M.simplex3d   = simplex3d
M.worley2d    = worley2d
M.fbm2d       = fbm2d
M.turbulence2d = turbulence2d
M.ridged2d    = ridged2d
M.warp2d      = warp2d
M.map2d       = map2d
M.normalize   = normalize

return M
