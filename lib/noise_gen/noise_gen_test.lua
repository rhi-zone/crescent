-- lib/noise_gen/noise_gen_test.lua
-- Tests for lib/noise_gen

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local N = require("lib.noise_gen")

local function in_range(v, lo, hi)
  return v >= lo and v <= hi
end

-- ---------------------------------------------------------------------------
-- Module metadata
-- ---------------------------------------------------------------------------

T.describe("noise_gen module", function()
  T.it("exports _tier = 'pure'", function()
    T.eq(N._tier, "pure")
  end)

  T.it("exports all expected functions", function()
    T.ok(type(N.value2d)      == "function")
    T.ok(type(N.value3d)      == "function")
    T.ok(type(N.perlin2d)     == "function")
    T.ok(type(N.perlin3d)     == "function")
    T.ok(type(N.simplex2d)    == "function")
    T.ok(type(N.simplex3d)    == "function")
    T.ok(type(N.worley2d)     == "function")
    T.ok(type(N.fbm2d)        == "function")
    T.ok(type(N.turbulence2d) == "function")
    T.ok(type(N.ridged2d)     == "function")
    T.ok(type(N.warp2d)       == "function")
    T.ok(type(N.map2d)        == "function")
    T.ok(type(N.normalize)    == "function")
  end)
end)

-- ---------------------------------------------------------------------------
-- Value noise
-- ---------------------------------------------------------------------------

T.describe("value2d", function()
  T.it("returns value in [-1, 1]", function()
    for i = 0, 9 do
      local v = N.value2d(i * 0.7, i * 1.3, 42)
      T.ok(in_range(v, -1, 1), "value2d out of range: " .. tostring(v))
    end
  end)

  T.it("is deterministic (same seed → same value)", function()
    local v1 = N.value2d(1.5, 2.5, 100)
    local v2 = N.value2d(1.5, 2.5, 100)
    T.eq(v1, v2)
  end)

  T.it("different seeds produce different values", function()
    local v1 = N.value2d(1.5, 2.5, 1)
    local v2 = N.value2d(1.5, 2.5, 2)
    T.neq(v1, v2)
  end)

  T.it("is continuous (nearby points have close values)", function()
    local v1 = N.value2d(3.0,     2.0, 0)
    local v2 = N.value2d(3.001,   2.0, 0)
    T.ok(math.abs(v1 - v2) < 0.02, "value2d not continuous: diff=" .. tostring(math.abs(v1-v2)))
  end)
end)

T.describe("value3d", function()
  T.it("returns value in [-1, 1]", function()
    for i = 0, 9 do
      local v = N.value3d(i * 0.7, i * 1.3, i * 0.5, 42)
      T.ok(in_range(v, -1, 1), "value3d out of range: " .. tostring(v))
    end
  end)

  T.it("is deterministic", function()
    local v1 = N.value3d(1.1, 2.2, 3.3, 7)
    local v2 = N.value3d(1.1, 2.2, 3.3, 7)
    T.eq(v1, v2)
  end)

  T.it("different seeds produce different values", function()
    local v1 = N.value3d(1.1, 2.2, 3.3, 7)
    local v2 = N.value3d(1.1, 2.2, 3.3, 8)
    T.neq(v1, v2)
  end)
end)

-- ---------------------------------------------------------------------------
-- Perlin noise
-- ---------------------------------------------------------------------------

T.describe("perlin2d", function()
  T.it("returns value in [-1, 1]", function()
    for i = 0, 9 do
      local v = N.perlin2d(i * 1.1, i * 0.9, 0)
      T.ok(in_range(v, -1, 1), "perlin2d out of range: " .. tostring(v))
    end
  end)

  T.it("is deterministic", function()
    local v1 = N.perlin2d(2.5, 3.5, 55)
    local v2 = N.perlin2d(2.5, 3.5, 55)
    T.eq(v1, v2)
  end)

  T.it("different seeds produce different values", function()
    local v1 = N.perlin2d(2.5, 3.5, 1)
    local v2 = N.perlin2d(2.5, 3.5, 2)
    T.neq(v1, v2)
  end)

  -- Gradient noise property: at integer coordinates the gradient dot product
  -- is zero → value is near 0.
  T.it("is near 0 at integer coordinates (gradient property)", function()
    for ix = 1, 5 do
      for iy = 1, 5 do
        local v = N.perlin2d(ix, iy, 0)
        T.ok(math.abs(v) < 0.01,
          "perlin2d not near 0 at integer coords ("..ix..","..iy.."): "..tostring(v))
      end
    end
  end)

  T.it("is continuous", function()
    local v1 = N.perlin2d(5.0,   3.0, 0)
    local v2 = N.perlin2d(5.001, 3.0, 0)
    T.ok(math.abs(v1 - v2) < 0.01, "perlin2d not continuous: diff="..tostring(math.abs(v1-v2)))
  end)
end)

T.describe("perlin3d", function()
  T.it("returns value in [-1, 1]", function()
    for i = 0, 9 do
      local v = N.perlin3d(i * 0.6, i * 0.8, i * 1.2, 3)
      T.ok(in_range(v, -1, 1), "perlin3d out of range: " .. tostring(v))
    end
  end)

  T.it("is deterministic", function()
    local v1 = N.perlin3d(1.1, 2.2, 3.3, 99)
    local v2 = N.perlin3d(1.1, 2.2, 3.3, 99)
    T.eq(v1, v2)
  end)

  T.it("is near 0 at integer coordinates", function()
    local v = N.perlin3d(2, 3, 4, 0)
    T.ok(math.abs(v) < 0.01,
      "perlin3d not near 0 at integer coords: " .. tostring(v))
  end)
end)

-- ---------------------------------------------------------------------------
-- Simplex noise
-- ---------------------------------------------------------------------------

T.describe("simplex2d", function()
  T.it("returns value in a reasonable range", function()
    local lo, hi = math.huge, -math.huge
    for i = 0, 19 do
      local v = N.simplex2d(i * 0.7, i * 1.1, 11)
      if v < lo then lo = v end
      if v > hi then hi = v end
      T.ok(in_range(v, -1.5, 1.5), "simplex2d out of bounds: "..tostring(v))
    end
  end)

  T.it("is deterministic", function()
    local v1 = N.simplex2d(3.7, 1.2, 42)
    local v2 = N.simplex2d(3.7, 1.2, 42)
    T.eq(v1, v2)
  end)

  T.it("different seeds produce different values", function()
    local v1 = N.simplex2d(3.7, 1.2, 42)
    local v2 = N.simplex2d(3.7, 1.2, 43)
    T.neq(v1, v2)
  end)

  T.it("is continuous", function()
    local v1 = N.simplex2d(4.0,   2.0, 0)
    local v2 = N.simplex2d(4.001, 2.0, 0)
    T.ok(math.abs(v1 - v2) < 0.01,
      "simplex2d not continuous: diff="..tostring(math.abs(v1-v2)))
  end)
end)

T.describe("simplex3d", function()
  T.it("returns value in a reasonable range", function()
    for i = 0, 9 do
      local v = N.simplex3d(i * 0.5, i * 0.8, i * 1.1, 7)
      T.ok(in_range(v, -1.5, 1.5), "simplex3d out of bounds: "..tostring(v))
    end
  end)

  T.it("is deterministic", function()
    local v1 = N.simplex3d(1.1, 2.2, 3.3, 17)
    local v2 = N.simplex3d(1.1, 2.2, 3.3, 17)
    T.eq(v1, v2)
  end)
end)

-- ---------------------------------------------------------------------------
-- Worley noise
-- ---------------------------------------------------------------------------

T.describe("worley2d", function()
  T.it("returns non-negative value", function()
    for i = 0, 9 do
      local v = N.worley2d(i * 0.9, i * 1.1, 5)
      T.ok(v >= 0, "worley2d negative: " .. tostring(v))
    end
  end)

  T.it("returns value in [0, 1]", function()
    for i = 0, 9 do
      local v = N.worley2d(i * 1.3, i * 0.7, 5)
      T.ok(in_range(v, 0, 1), "worley2d out of [0,1]: " .. tostring(v))
    end
  end)

  T.it("is deterministic", function()
    local v1 = N.worley2d(2.5, 3.5, 8)
    local v2 = N.worley2d(2.5, 3.5, 8)
    T.eq(v1, v2)
  end)

  T.it("different seeds produce different values", function()
    local v1 = N.worley2d(2.5, 3.5, 8)
    local v2 = N.worley2d(2.5, 3.5, 9)
    T.neq(v1, v2)
  end)

  T.it("manhattan metric works and returns [0,1]", function()
    local v = N.worley2d(1.5, 2.5, 3, {metric="manhattan"})
    T.ok(in_range(v, 0, 1), "worley2d manhattan out of [0,1]: "..tostring(v))
  end)

  T.it("chebyshev metric works and returns [0,1]", function()
    local v = N.worley2d(1.5, 2.5, 3, {metric="chebyshev"})
    T.ok(in_range(v, 0, 1), "worley2d chebyshev out of [0,1]: "..tostring(v))
  end)

  T.it("k=2 returns larger or equal distance than k=1", function()
    local f1 = N.worley2d(2.5, 3.5, 5, {k=1})
    local f2 = N.worley2d(2.5, 3.5, 5, {k=2})
    T.ok(f2 >= f1, "k=2 not >= k=1: f1="..tostring(f1).." f2="..tostring(f2))
  end)
end)

-- ---------------------------------------------------------------------------
-- fBm
-- ---------------------------------------------------------------------------

T.describe("fbm2d", function()
  T.it("returns a number (no error)", function()
    local v = N.fbm2d(1.5, 2.5, 0)
    T.ok(type(v) == "number")
  end)

  T.it("is deterministic", function()
    local v1 = N.fbm2d(1.5, 2.5, 42)
    local v2 = N.fbm2d(1.5, 2.5, 42)
    T.eq(v1, v2)
  end)

  T.it("different seeds give different values", function()
    local v1 = N.fbm2d(1.5, 2.5, 42)
    local v2 = N.fbm2d(1.5, 2.5, 43)
    T.neq(v1, v2)
  end)

  T.it("more octaves changes value relative to 1 octave", function()
    local v1 = N.fbm2d(3.7, 8.1, 0, {octaves=1})
    local v6 = N.fbm2d(3.7, 8.1, 0, {octaves=6})
    T.neq(v1, v6)
  end)

  T.it("accepts custom noise_fn (value2d)", function()
    local v = N.fbm2d(1.5, 2.5, 0, {noise_fn = N.value2d})
    T.ok(type(v) == "number")
  end)

  T.it("is continuous", function()
    local v1 = N.fbm2d(3.0,   2.0, 0)
    local v2 = N.fbm2d(3.001, 2.0, 0)
    T.ok(math.abs(v1 - v2) < 0.05,
      "fbm2d not continuous: diff=" .. tostring(math.abs(v1-v2)))
  end)
end)

-- ---------------------------------------------------------------------------
-- Turbulence
-- ---------------------------------------------------------------------------

T.describe("turbulence2d", function()
  T.it("returns non-negative value", function()
    for i = 0, 9 do
      local v = N.turbulence2d(i * 1.1, i * 0.9, 0)
      T.ok(v >= 0, "turbulence2d negative: "..tostring(v))
    end
  end)

  T.it("is deterministic", function()
    local v1 = N.turbulence2d(2.2, 3.3, 55)
    local v2 = N.turbulence2d(2.2, 3.3, 55)
    T.eq(v1, v2)
  end)

  T.it("1-octave turbulence equals |perlin2d|", function()
    local x, y, seed = 2.3, 1.7, 10
    local tp = N.turbulence2d(x, y, seed, {octaves=1})
    local p  = math.abs(N.perlin2d(x, y, seed))
    T.ok(math.abs(tp - p) < 1e-10, "turbulence mismatch: tp="..tp.." p="..p)
  end)
end)

-- ---------------------------------------------------------------------------
-- Ridged noise
-- ---------------------------------------------------------------------------

T.describe("ridged2d", function()
  T.it("returns value in [0, 1]", function()
    for i = 0, 9 do
      local v = N.ridged2d(i * 0.8, i * 1.2, 3)
      T.ok(in_range(v, 0, 1), "ridged2d out of [0,1]: "..tostring(v))
    end
  end)

  T.it("is deterministic", function()
    local v1 = N.ridged2d(1.1, 2.2, 7)
    local v2 = N.ridged2d(1.1, 2.2, 7)
    T.eq(v1, v2)
  end)

  T.it("different seeds produce different values", function()
    local v1 = N.ridged2d(1.1, 2.2, 7)
    local v2 = N.ridged2d(1.1, 2.2, 8)
    T.neq(v1, v2)
  end)
end)

-- ---------------------------------------------------------------------------
-- Domain warping
-- ---------------------------------------------------------------------------

T.describe("warp2d", function()
  T.it("returns a number", function()
    local v = N.warp2d(1.5, 2.5, 0)
    T.ok(type(v) == "number")
  end)

  T.it("is deterministic", function()
    local v1 = N.warp2d(1.5, 2.5, 33)
    local v2 = N.warp2d(1.5, 2.5, 33)
    T.eq(v1, v2)
  end)

  T.it("different seeds produce different values", function()
    local v1 = N.warp2d(1.5, 2.5, 33)
    local v2 = N.warp2d(1.5, 2.5, 34)
    T.neq(v1, v2)
  end)

  T.it("strength=0 reduces to plain noise", function()
    -- With strength 0, warp displaces by 0, so result equals noise at (x,y)
    local v_warp  = N.warp2d(2.3, 1.7, 0, {strength=0})
    local v_plain = N.perlin2d(2.3, 1.7, 2)  -- seed+2 as used internally
    T.ok(math.abs(v_warp - v_plain) < 1e-10,
      "warp strength=0 not equal to base noise: "..tostring(v_warp).." vs "..tostring(v_plain))
  end)
end)

-- ---------------------------------------------------------------------------
-- map2d
-- ---------------------------------------------------------------------------

T.describe("map2d", function()
  T.it("returns correct dimensions", function()
    local m = N.map2d(10, 8)
    T.eq(#m, 8)
    T.eq(#m[1], 10)
    T.eq(#m[8], 10)
  end)

  T.it("all values are numbers", function()
    local m = N.map2d(5, 5)
    for _, row in ipairs(m) do
      for _, v in ipairs(row) do
        T.ok(type(v) == "number", "map2d value not a number: "..tostring(v))
      end
    end
  end)

  T.it("values are in [-1, 1] with default settings", function()
    local m = N.map2d(8, 8, {seed=0, scale=0.1})
    for _, row in ipairs(m) do
      for _, v in ipairs(row) do
        T.ok(in_range(v, -1.5, 1.5), "map2d value out of range: "..tostring(v))
      end
    end
  end)

  T.it("is deterministic", function()
    local m1 = N.map2d(4, 4, {seed=7, scale=0.1})
    local m2 = N.map2d(4, 4, {seed=7, scale=0.1})
    for i = 1, 4 do
      for j = 1, 4 do
        T.eq(m1[i][j], m2[i][j])
      end
    end
  end)

  T.it("different seeds produce different maps", function()
    local m1 = N.map2d(4, 4, {seed=1, scale=0.1})
    local m2 = N.map2d(4, 4, {seed=2, scale=0.1})
    local any_diff = false
    for i = 1, 4 do
      for j = 1, 4 do
        if m1[i][j] ~= m2[i][j] then any_diff = true end
      end
    end
    T.ok(any_diff, "different seeds produced identical maps")
  end)

  T.it("octaves>1 uses fBm and produces different values than 1 octave", function()
    local m1 = N.map2d(4, 4, {seed=0, scale=0.1, octaves=1})
    local m6 = N.map2d(4, 4, {seed=0, scale=0.1, octaves=6})
    local any_diff = false
    for i = 1, 4 do
      for j = 1, 4 do
        if m1[i][j] ~= m6[i][j] then any_diff = true end
      end
    end
    T.ok(any_diff, "octaves=6 map identical to octaves=1")
  end)

  T.it("accepts custom fn (value2d)", function()
    local m = N.map2d(4, 4, {fn=N.value2d, scale=0.1})
    T.eq(#m, 4)
    T.eq(#m[1], 4)
  end)
end)

-- ---------------------------------------------------------------------------
-- normalize
-- ---------------------------------------------------------------------------

T.describe("normalize", function()
  T.it("all values are in [0, 1] after normalize", function()
    local m = N.map2d(16, 16, {seed=0, scale=0.05})
    N.normalize(m)
    for _, row in ipairs(m) do
      for _, v in ipairs(row) do
        T.ok(in_range(v, 0, 1), "normalize value out of [0,1]: "..tostring(v))
      end
    end
  end)

  T.it("modifies map in place and returns it", function()
    local m = N.map2d(4, 4)
    local ret = N.normalize(m)
    T.ok(ret == m, "normalize did not return the same table")
  end)

  T.it("min value becomes 0 and max becomes 1", function()
    local m = N.map2d(8, 8, {seed=5, scale=0.2})
    N.normalize(m)
    local lo, hi = math.huge, -math.huge
    for _, row in ipairs(m) do
      for _, v in ipairs(row) do
        if v < lo then lo = v end
        if v > hi then hi = v end
      end
    end
    T.ok(math.abs(lo) < 1e-10, "normalize min not 0: "..tostring(lo))
    T.ok(math.abs(hi - 1) < 1e-10, "normalize max not 1: "..tostring(hi))
  end)

  T.it("flat map (all same value) produces 0.5", function()
    local m = {{5, 5}, {5, 5}}
    N.normalize(m)
    T.eq(m[1][1], 0.5)
    T.eq(m[2][2], 0.5)
  end)
end)

-- ---------------------------------------------------------------------------
-- Cross-cutting: continuity of all 2D noise functions
-- ---------------------------------------------------------------------------

T.describe("continuity of 2D noise functions", function()
  local funcs = {
    {"value2d",  function(x, y) return N.value2d(x, y, 0)  end},
    {"perlin2d", function(x, y) return N.perlin2d(x, y, 0) end},
    {"simplex2d",function(x, y) return N.simplex2d(x, y, 0) end},
  }
  local delta = 0.001
  local threshold = 0.01
  for _, entry in ipairs(funcs) do
    local name, fn = entry[1], entry[2]
    T.it(name .. " |f(x+0.001,y) - f(x,y)| < 0.01", function()
      for i = 1, 5 do
        local x = i * 1.17
        local y = i * 0.83
        local diff = math.abs(fn(x + delta, y) - fn(x, y))
        T.ok(diff < threshold,
          name .. " continuity fail at ("..x..","..y.."): diff="..tostring(diff))
      end
    end)
  end
end)
