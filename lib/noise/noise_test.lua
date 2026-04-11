-- lib/noise/noise_test.lua
-- Comprehensive tests for lib.noise (Perlin, Simplex, fBm, seeded, normalize).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T     = require("lib.test.assert")
local noise = require("lib.noise")

local abs = math.abs

T.describe("lib.noise", function()

  -- -------------------------------------------------------------------------
  T.describe("tier", function()
    T.it("_tier is 'pure'", function()
      T.eq(noise._tier, "pure")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("perlin2", function()
    T.it("returns a number", function()
      T.eq(type(noise.perlin2(0.5, 0.5)), "number")
    end)

    T.it("returns 0 at integer coordinates (0,0)", function()
      T.ok(abs(noise.perlin2(0, 0)) < 1e-10, "perlin2(0,0) should be 0")
    end)

    T.it("returns 0 at integer coordinates (1,0)", function()
      T.ok(abs(noise.perlin2(1, 0)) < 1e-10, "perlin2(1,0) should be 0")
    end)

    T.it("returns 0 at integer coordinates (0,1)", function()
      T.ok(abs(noise.perlin2(0, 1)) < 1e-10, "perlin2(0,1) should be 0")
    end)

    T.it("returns 0 at integer coordinates (3,7)", function()
      T.ok(abs(noise.perlin2(3, 7)) < 1e-10, "perlin2(3,7) should be 0")
    end)

    T.it("output at (0.5,0.5) is in [-1, 1]", function()
      local v = noise.perlin2(0.5, 0.5)
      T.ok(v >= -1 and v <= 1, "expected value in [-1,1], got " .. v)
    end)

    T.it("is reproducible: same input gives same output", function()
      T.eq(noise.perlin2(1.23, 4.56), noise.perlin2(1.23, 4.56))
    end)

    T.it("smooth: nearby points differ by < 0.01 with delta 0.001", function()
      local v1 = noise.perlin2(1.5, 2.5)
      local v2 = noise.perlin2(1.501, 2.5)
      T.ok(abs(v1 - v2) < 0.01, "smoothness violated: delta=" .. abs(v1 - v2))
    end)

    T.it("samples across a grid are all in [-2, 2]", function()
      for ix = 0, 10 do
        for iy = 0, 10 do
          local v = noise.perlin2(ix * 0.3 + 0.1, iy * 0.3 + 0.1)
          T.ok(abs(v) <= 2, "out of range at " .. ix .. "," .. iy .. ": " .. v)
        end
      end
    end)

    T.it("different non-integer inputs give different values", function()
      local v1 = noise.perlin2(0.25, 0.25)
      local v2 = noise.perlin2(0.75, 0.75)
      T.neq(v1, v2)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("perlin3", function()
    T.it("returns a number", function()
      T.eq(type(noise.perlin3(0.5, 0.5, 0.5)), "number")
    end)

    T.it("returns 0 at integer coordinates (0,0,0)", function()
      T.ok(abs(noise.perlin3(0, 0, 0)) < 1e-10, "perlin3(0,0,0) should be 0")
    end)

    T.it("returns 0 at integer coordinates (2,3,4)", function()
      T.ok(abs(noise.perlin3(2, 3, 4)) < 1e-10, "perlin3(2,3,4) should be 0")
    end)

    T.it("output at (0.5,0.5,0.5) is in [-1, 1]", function()
      local v = noise.perlin3(0.5, 0.5, 0.5)
      T.ok(v >= -1 and v <= 1, "expected [-1,1], got " .. v)
    end)

    T.it("is reproducible", function()
      T.eq(noise.perlin3(1.1, 2.2, 3.3), noise.perlin3(1.1, 2.2, 3.3))
    end)

    T.it("smooth: nearby points differ by < 0.01 with delta 0.001", function()
      local v1 = noise.perlin3(1.5, 2.5, 3.5)
      local v2 = noise.perlin3(1.501, 2.5, 3.5)
      T.ok(abs(v1 - v2) < 0.01, "smoothness violated: delta=" .. abs(v1 - v2))
    end)

    T.it("grid samples all in [-2, 2]", function()
      for ix = 0, 5 do
        for iy = 0, 5 do
          for iz = 0, 5 do
            local v = noise.perlin3(ix*0.4+0.1, iy*0.4+0.1, iz*0.4+0.1)
            T.ok(abs(v) <= 2, "out of range: " .. v)
          end
        end
      end
    end)

    T.it("perlin2(x,y) == perlin3(x,y,0)", function()
      -- perlin2 is defined as perlin3(x,y,0)
      T.eq(noise.perlin2(0.4, 0.7), noise.perlin3(0.4, 0.7, 0))
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("simplex2", function()
    T.it("returns a number", function()
      T.eq(type(noise.simplex2(0.5, 0.5)), "number")
    end)

    T.it("output at various points is in [-1, 1]", function()
      local pts = {
        {0.1, 0.2}, {0.5, 0.5}, {-1.3, 2.7}, {10.5, -3.2}, {0, 0},
      }
      for _, p in ipairs(pts) do
        local v = noise.simplex2(p[1], p[2])
        T.ok(abs(v) <= 1.1, "out of range at (" .. p[1] .. "," .. p[2] .. "): " .. v)
      end
    end)

    T.it("is reproducible", function()
      T.eq(noise.simplex2(3.14, 2.72), noise.simplex2(3.14, 2.72))
    end)

    T.it("smooth: nearby points differ by < 0.01 with delta 0.001", function()
      local v1 = noise.simplex2(2.3, 4.1)
      local v2 = noise.simplex2(2.301, 4.1)
      T.ok(abs(v1 - v2) < 0.01, "smoothness violated: delta=" .. abs(v1 - v2))
    end)

    T.it("grid of 100 samples all in [-1.1, 1.1]", function()
      for ix = 0, 9 do
        for iy = 0, 9 do
          local v = noise.simplex2(ix*0.5 - 2.5, iy*0.5 - 2.5)
          T.ok(abs(v) <= 1.1, "out of range: " .. v)
        end
      end
    end)

    T.it("different inputs give different values", function()
      T.neq(noise.simplex2(0.1, 0.2), noise.simplex2(0.9, 0.8))
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("simplex3", function()
    T.it("returns a number", function()
      T.eq(type(noise.simplex3(0.5, 0.5, 0.5)), "number")
    end)

    T.it("output at various points is in [-1.1, 1.1]", function()
      local pts = {
        {0.1, 0.2, 0.3}, {0.5, 0.5, 0.5}, {-1, 2, -3}, {5, 5, 5},
      }
      for _, p in ipairs(pts) do
        local v = noise.simplex3(p[1], p[2], p[3])
        T.ok(abs(v) <= 1.1, "out of range at (" .. p[1] .. "," .. p[2] .. "," .. p[3] .. "): " .. v)
      end
    end)

    T.it("is reproducible", function()
      T.eq(noise.simplex3(1.1, 2.2, 3.3), noise.simplex3(1.1, 2.2, 3.3))
    end)

    T.it("smooth: nearby points differ by < 0.01 with delta 0.001", function()
      local v1 = noise.simplex3(1.5, 2.5, 3.5)
      local v2 = noise.simplex3(1.501, 2.5, 3.5)
      T.ok(abs(v1 - v2) < 0.01, "smoothness violated: delta=" .. abs(v1 - v2))
    end)

    T.it("grid samples in [-1.1, 1.1]", function()
      for ix = 0, 4 do
        for iy = 0, 4 do
          for iz = 0, 4 do
            local v = noise.simplex3(ix*0.5-1.0, iy*0.5-1.0, iz*0.5-1.0)
            T.ok(abs(v) <= 1.1, "out of range: " .. v)
          end
        end
      end
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("fbm2", function()
    T.it("returns a number", function()
      T.eq(type(noise.fbm2(0.5, 0.5)), "number")
    end)

    T.it("is reproducible", function()
      T.eq(noise.fbm2(1.0, 2.0), noise.fbm2(1.0, 2.0))
    end)

    T.it("more octaves changes the value", function()
      local v1 = noise.fbm2(0.5, 0.5, { octaves = 1 })
      local v2 = noise.fbm2(0.5, 0.5, { octaves = 6 })
      T.neq(v1, v2)
    end)

    T.it("persistence 0 gives only first octave", function()
      local v1 = noise.fbm2(0.5, 0.5, { octaves = 6, persistence = 0 })
      local v2 = noise.fbm2(0.5, 0.5, { octaves = 1, persistence = 0 })
      T.eq(v1, v2)
    end)

    T.it("scale affects output", function()
      local v1 = noise.fbm2(1.0, 1.0, { octaves = 1, scale = 1.0 })
      local v2 = noise.fbm2(1.0, 1.0, { octaves = 1, scale = 2.0 })
      T.neq(v1, v2)
    end)

    T.it("default opts produce reasonable range", function()
      -- fBm with 6 octaves, persistence 0.5 sums to at most ~2 * first octave amplitude
      for ix = 0, 9 do
        local v = noise.fbm2(ix * 0.3, ix * 0.2)
        T.ok(abs(v) <= 4, "fbm2 wildly out of range: " .. v)
      end
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("fbm3", function()
    T.it("returns a number", function()
      T.eq(type(noise.fbm3(0.5, 0.5, 0.5)), "number")
    end)

    T.it("is reproducible", function()
      T.eq(noise.fbm3(1.0, 2.0, 3.0), noise.fbm3(1.0, 2.0, 3.0))
    end)

    T.it("more octaves changes the value", function()
      local v1 = noise.fbm3(0.3, 0.7, 1.1, { octaves = 1 })
      local v2 = noise.fbm3(0.3, 0.7, 1.1, { octaves = 6 })
      T.neq(v1, v2)
    end)

    T.it("persistence 0 gives only first octave", function()
      local v1 = noise.fbm3(0.3, 0.7, 1.1, { octaves = 6, persistence = 0 })
      local v2 = noise.fbm3(0.3, 0.7, 1.1, { octaves = 1, persistence = 0 })
      T.eq(v1, v2)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("seeded", function()
    T.it("different seeds produce different perlin2 values", function()
      local n1 = noise.seeded(1)
      local n2 = noise.seeded(2)
      T.neq(n1.perlin2(0.5, 0.5), n2.perlin2(0.5, 0.5))
    end)

    T.it("different seeds produce different simplex2 values", function()
      local n1 = noise.seeded(42)
      local n2 = noise.seeded(99)
      T.neq(n1.simplex2(0.5, 0.5), n2.simplex2(0.5, 0.5))
    end)

    T.it("same seed gives same values (reproducibility)", function()
      local na = noise.seeded(7)
      local nb = noise.seeded(7)
      T.eq(na.perlin2(0.3, 0.7), nb.perlin2(0.3, 0.7))
      T.eq(na.simplex3(0.3, 0.7, 1.1), nb.simplex3(0.3, 0.7, 1.1))
    end)

    T.it("seeded module has perlin2", function()
      T.eq(type(noise.seeded(1).perlin2), "function")
    end)

    T.it("seeded module has perlin3", function()
      T.eq(type(noise.seeded(1).perlin3), "function")
    end)

    T.it("seeded module has simplex2", function()
      T.eq(type(noise.seeded(1).simplex2), "function")
    end)

    T.it("seeded module has simplex3", function()
      T.eq(type(noise.seeded(1).simplex3), "function")
    end)

    T.it("seeded module has fbm2", function()
      T.eq(type(noise.seeded(1).fbm2), "function")
    end)

    T.it("seeded module has fbm3", function()
      T.eq(type(noise.seeded(1).fbm3), "function")
    end)

    T.it("seeded module has _tier = 'pure'", function()
      T.eq(noise.seeded(1)._tier, "pure")
    end)

    T.it("seeded differs from default module", function()
      -- The default permutation vs a seeded one should differ at some point
      local ns = noise.seeded(12345)
      T.neq(ns.perlin2(0.5, 0.5), noise.perlin2(0.5, 0.5))
    end)

    T.it("seed 0 works without error", function()
      local n0 = noise.seeded(0)
      T.eq(type(n0.perlin2(0.5, 0.5)), "number")
    end)

    T.it("seeded fbm2 is reproducible", function()
      local na = noise.seeded(3)
      local nb = noise.seeded(3)
      T.eq(na.fbm2(1.0, 2.0), nb.fbm2(1.0, 2.0))
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("normalize", function()
    T.it("normalize(-1) == 0", function()
      T.ok(abs(noise.normalize(-1) - 0) < 1e-12, "normalize(-1) should be 0")
    end)

    T.it("normalize(0) == 0.5", function()
      T.ok(abs(noise.normalize(0) - 0.5) < 1e-12, "normalize(0) should be 0.5")
    end)

    T.it("normalize(1) == 1", function()
      T.ok(abs(noise.normalize(1) - 1) < 1e-12, "normalize(1) should be 1")
    end)

    T.it("normalize maps perlin2 output to [0, 1] range", function()
      for ix = 0, 9 do
        local v = noise.normalize(noise.perlin2(ix * 0.3 + 0.1, ix * 0.2 + 0.1))
        T.ok(v >= 0 and v <= 1, "normalized value out of [0,1]: " .. v)
      end
    end)
  end)

end)
