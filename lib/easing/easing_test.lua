if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local easing = require("lib.easing")

local EPS = 1e-10

local function near(a, b) return math.abs(a - b) < EPS end

-- Helper: assert boundary conditions f(0)==0, f(1)==1
local function check_boundaries(name, fn)
  T.ok(near(fn(0), 0), name .. "(0) should be 0")
  T.ok(near(fn(1), 1), name .. "(1) should be 1")
end

-- Helper: assert mirror symmetry in_X(t) == 1 - out_X(1-t)
local function check_mirror(in_fn, out_fn, name)
  for _, t in ipairs({ 0, 0.1, 0.25, 0.5, 0.75, 0.9, 1 }) do
    local a = in_fn(t)
    local b = 1 - out_fn(1 - t)
    T.ok(near(a, b), name .. " mirror at t=" .. t)
  end
end

-- ---------------------------------------------------------------------------

T.describe("lib.easing", function()

  T.describe("tier", function()
    T.it("M._tier is 'pure'", function()
      T.eq(easing._tier, "pure")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("linear", function()
    T.it("boundary conditions", function()
      check_boundaries("linear", easing.linear)
    end)
    T.it("f(t) == t", function()
      for _, t in ipairs({ 0, 0.1, 0.25, 0.5, 0.75, 0.9, 1 }) do
        T.ok(near(easing.linear(t), t), "linear(" .. t .. ")")
      end
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("quad", function()
    T.it("boundary conditions", function()
      check_boundaries("in_quad",     easing.in_quad)
      check_boundaries("out_quad",    easing.out_quad)
      check_boundaries("in_out_quad", easing.in_out_quad)
    end)
    T.it("in_quad slow start: f(0.5) < 0.5", function()
      T.ok(easing.in_quad(0.5) < 0.5, "in_quad(0.5) < 0.5")
    end)
    T.it("out_quad fast start: f(0.5) > 0.5", function()
      T.ok(easing.out_quad(0.5) > 0.5, "out_quad(0.5) > 0.5")
    end)
    T.it("in_out_quad midpoint ≈ 0.5", function()
      T.ok(near(easing.in_out_quad(0.5), 0.5), "in_out_quad(0.5) ≈ 0.5")
    end)
    T.it("mirror symmetry", function()
      check_mirror(easing.in_quad, easing.out_quad, "quad")
    end)
    T.it("in_quad exact value at 0.5", function()
      T.ok(near(easing.in_quad(0.5), 0.25), "in_quad(0.5)==0.25")
    end)
    T.it("out_quad exact value at 0.5", function()
      T.ok(near(easing.out_quad(0.5), 0.75), "out_quad(0.5)==0.75")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("cubic", function()
    T.it("boundary conditions", function()
      check_boundaries("in_cubic",     easing.in_cubic)
      check_boundaries("out_cubic",    easing.out_cubic)
      check_boundaries("in_out_cubic", easing.in_out_cubic)
    end)
    T.it("in_cubic slow start", function()
      T.ok(easing.in_cubic(0.5) < 0.5)
    end)
    T.it("out_cubic fast start", function()
      T.ok(easing.out_cubic(0.5) > 0.5)
    end)
    T.it("in_out_cubic midpoint ≈ 0.5", function()
      T.ok(near(easing.in_out_cubic(0.5), 0.5))
    end)
    T.it("mirror symmetry", function()
      check_mirror(easing.in_cubic, easing.out_cubic, "cubic")
    end)
    T.it("in_cubic exact value at 0.5", function()
      T.ok(near(easing.in_cubic(0.5), 0.125), "in_cubic(0.5)==0.125")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("quart", function()
    T.it("boundary conditions", function()
      check_boundaries("in_quart",     easing.in_quart)
      check_boundaries("out_quart",    easing.out_quart)
      check_boundaries("in_out_quart", easing.in_out_quart)
    end)
    T.it("in_quart slower than in_cubic at 0.5", function()
      T.ok(easing.in_quart(0.5) < easing.in_cubic(0.5))
    end)
    T.it("in_out_quart midpoint ≈ 0.5", function()
      T.ok(near(easing.in_out_quart(0.5), 0.5))
    end)
    T.it("mirror symmetry", function()
      check_mirror(easing.in_quart, easing.out_quart, "quart")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("quint", function()
    T.it("boundary conditions", function()
      check_boundaries("in_quint",     easing.in_quint)
      check_boundaries("out_quint",    easing.out_quint)
      check_boundaries("in_out_quint", easing.in_out_quint)
    end)
    T.it("in_quint slower than in_quart at 0.5", function()
      T.ok(easing.in_quint(0.5) < easing.in_quart(0.5))
    end)
    T.it("in_out_quint midpoint ≈ 0.5", function()
      T.ok(near(easing.in_out_quint(0.5), 0.5))
    end)
    T.it("mirror symmetry", function()
      check_mirror(easing.in_quint, easing.out_quint, "quint")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("sine", function()
    T.it("boundary conditions", function()
      check_boundaries("in_sine",     easing.in_sine)
      check_boundaries("out_sine",    easing.out_sine)
      check_boundaries("in_out_sine", easing.in_out_sine)
    end)
    T.it("in_sine slow start", function()
      T.ok(easing.in_sine(0.5) < 0.5)
    end)
    T.it("out_sine fast start", function()
      T.ok(easing.out_sine(0.5) > 0.5)
    end)
    T.it("in_out_sine midpoint ≈ 0.5", function()
      T.ok(near(easing.in_out_sine(0.5), 0.5))
    end)
    T.it("out_sine exact: sin(π/4) at t=0.5", function()
      local expected = math.sin(math.pi / 4)
      T.ok(near(easing.out_sine(0.5), expected))
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("expo", function()
    T.it("boundary conditions (special-cased)", function()
      check_boundaries("in_expo",     easing.in_expo)
      check_boundaries("out_expo",    easing.out_expo)
      check_boundaries("in_out_expo", easing.in_out_expo)
    end)
    T.it("in_expo slow start", function()
      T.ok(easing.in_expo(0.5) < 0.5)
    end)
    T.it("out_expo fast start", function()
      T.ok(easing.out_expo(0.5) > 0.5)
    end)
    T.it("in_out_expo midpoint ≈ 0.5", function()
      T.ok(near(easing.in_out_expo(0.5), 0.5))
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("circ", function()
    T.it("boundary conditions", function()
      check_boundaries("in_circ",     easing.in_circ)
      check_boundaries("out_circ",    easing.out_circ)
      check_boundaries("in_out_circ", easing.in_out_circ)
    end)
    T.it("in_circ slow start", function()
      T.ok(easing.in_circ(0.5) < 0.5)
    end)
    T.it("out_circ fast start", function()
      T.ok(easing.out_circ(0.5) > 0.5)
    end)
    T.it("in_out_circ midpoint ≈ 0.5", function()
      T.ok(near(easing.in_out_circ(0.5), 0.5))
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("back", function()
    T.it("boundary conditions", function()
      check_boundaries("in_back",     easing.in_back)
      check_boundaries("out_back",    easing.out_back)
      check_boundaries("in_out_back", easing.in_out_back)
    end)
    T.it("in_back overshoots: value < 0 near t=0.3", function()
      -- with s=1.70158, in_back dips below zero before t reaches ~0.3
      -- actually it goes negative for small t values: check near t=0.2
      T.ok(easing.in_back(0.2) < 0, "in_back overshoots negative")
    end)
    T.it("out_back overshoots: value > 1 near t=0.7", function()
      T.ok(easing.out_back(0.8) > 1, "out_back overshoots above 1")
    end)
    T.it("in_out_back midpoint ≈ 0.5", function()
      T.ok(near(easing.in_out_back(0.5), 0.5))
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("elastic", function()
    T.it("boundary conditions", function()
      check_boundaries("in_elastic",     easing.in_elastic)
      check_boundaries("out_elastic",    easing.out_elastic)
      check_boundaries("in_out_elastic", easing.in_out_elastic)
    end)
    T.it("in_elastic oscillates: can go negative", function()
      -- elastic spring pulls back; somewhere in (0,1) value is < 0
      local found_negative = false
      for i = 1, 99 do
        local t = i / 100
        if easing.in_elastic(t) < 0 then
          found_negative = true
          break
        end
      end
      T.ok(found_negative, "in_elastic should oscillate below 0")
    end)
    T.it("out_elastic oscillates: can go above 1", function()
      local found_above = false
      for i = 1, 99 do
        local t = i / 100
        if easing.out_elastic(t) > 1 then
          found_above = true
          break
        end
      end
      T.ok(found_above, "out_elastic should oscillate above 1")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("bounce", function()
    T.it("boundary conditions", function()
      check_boundaries("in_bounce",     easing.in_bounce)
      check_boundaries("out_bounce",    easing.out_bounce)
      check_boundaries("in_out_bounce", easing.in_out_bounce)
    end)
    T.it("out_bounce always in [0, 1]", function()
      for i = 0, 100 do
        local t = i / 100
        local v = easing.out_bounce(t)
        T.ok(v >= 0 and v <= 1, "out_bounce(" .. t .. ") in [0,1]")
      end
    end)
    T.it("in_bounce always in [0, 1]", function()
      for i = 0, 100 do
        local t = i / 100
        local v = easing.in_bounce(t)
        T.ok(v >= 0 and v <= 1, "in_bounce(" .. t .. ") in [0,1]")
      end
    end)
    T.it("in_out_bounce always in [0, 1]", function()
      for i = 0, 100 do
        local t = i / 100
        local v = easing.in_out_bounce(t)
        T.ok(v >= 0 and v <= 1, "in_out_bounce(" .. t .. ") in [0,1]")
      end
    end)
    T.it("in_out_bounce midpoint ≈ 0.5", function()
      T.ok(near(easing.in_out_bounce(0.5), 0.5))
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("get", function()
    T.it("get('linear') returns the linear function", function()
      T.eq(easing.get("linear"), easing.linear)
    end)
    T.it("get('in_quad') returns in_quad", function()
      T.eq(easing.get("in_quad"), easing.in_quad)
    end)
    T.it("get('out_elastic') returns out_elastic", function()
      T.eq(easing.get("out_elastic"), easing.out_elastic)
    end)
    T.it("get('nonexistent') returns nil", function()
      T.eq(easing.get("nonexistent"), nil)
    end)
    T.it("get('') returns nil", function()
      T.eq(easing.get(""), nil)
    end)
    T.it("returned function works correctly", function()
      local fn = easing.get("in_quad")
      T.ok(near(fn(0.5), 0.25))
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("interpolate", function()
    T.it("t=0 returns from", function()
      T.ok(near(easing.interpolate(0, 0, 100), 0))
    end)
    T.it("t=1 returns to", function()
      T.ok(near(easing.interpolate(1, 0, 100), 100))
    end)
    T.it("t=0.5 linear returns midpoint", function()
      T.ok(near(easing.interpolate(0.5, 0, 100, "linear"), 50))
    end)
    T.it("default (no ease_fn) uses linear", function()
      T.ok(near(easing.interpolate(0.5, 0, 100), 50))
    end)
    T.it("accepts function as ease_fn", function()
      local v = easing.interpolate(0.5, 0, 100, easing.in_quad)
      T.ok(near(v, 25), "in_quad at 0.5 of [0,100] = 25")
    end)
    T.it("accepts string ease_fn name", function()
      local v = easing.interpolate(0.5, 0, 100, "in_quad")
      T.ok(near(v, 25), "in_quad string name at 0.5 of [0,100] = 25")
    end)
    T.it("works with non-zero from value", function()
      local v = easing.interpolate(0.5, 50, 150, "linear")
      T.ok(near(v, 100))
    end)
    T.it("works with negative range", function()
      local v = easing.interpolate(0.5, -100, 100, "linear")
      T.ok(near(v, 0))
    end)
    T.it("works with reverse range (to < from)", function()
      local v = easing.interpolate(0.5, 100, 0, "linear")
      T.ok(near(v, 50))
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("names", function()
    T.it("returns a table", function()
      T.ok(type(easing.names()) == "table")
    end)
    T.it("contains 'linear'", function()
      local ns = easing.names()
      local found = false
      for _, n in ipairs(ns) do if n == "linear" then found = true end end
      T.ok(found)
    end)
    T.it("contains 'in_quad'", function()
      local ns = easing.names()
      local found = false
      for _, n in ipairs(ns) do if n == "in_quad" then found = true end end
      T.ok(found)
    end)
    T.it("contains 'out_quad'", function()
      local ns = easing.names()
      local found = false
      for _, n in ipairs(ns) do if n == "out_quad" then found = true end end
      T.ok(found)
    end)
    T.it("contains 'in_out_bounce'", function()
      local ns = easing.names()
      local found = false
      for _, n in ipairs(ns) do if n == "in_out_bounce" then found = true end end
      T.ok(found)
    end)
    T.it("count >= 30", function()
      local ns = easing.names()
      local count = #ns
      T.ok(count >= 30, "names count >= 30, got " .. count)
    end)
    T.it("every name resolves via get()", function()
      local ns = easing.names()
      for _, n in ipairs(ns) do
        T.ok(type(easing.get(n)) == "function", "get(" .. n .. ") is a function")
      end
    end)
  end)

end)
