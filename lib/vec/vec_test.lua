if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

local T = require("lib.test.assert")
local vec = require("lib.vec")

local function approx(a, b, tol)
  tol = tol or 1e-10
  T.ok(math.abs(a - b) < tol, "expected " .. a .. " ≈ " .. b)
end

T.describe("vec", function()
  T.it("has a known _tier", function()
    T.ok(vec._tier == "ffi" or vec._tier == "pure", "_tier is ffi or pure")
  end)

  T.it("new from table", function()
    local v = vec.new({1, 2, 3})
    approx(vec.get(v, 1), 1)
    approx(vec.get(v, 2), 2)
    approx(vec.get(v, 3), 3)
    T.eq(vec.len(v), 3)
  end)

  T.it("zeros", function()
    local v = vec.zeros(4)
    T.eq(vec.len(v), 4)
    for i = 1, 4 do
      approx(vec.get(v, i), 0)
    end
  end)

  T.it("ones", function()
    local v = vec.ones(3)
    T.eq(vec.len(v), 3)
    for i = 1, 3 do
      approx(vec.get(v, i), 1)
    end
  end)

  T.it("len returns dimension", function()
    T.eq(vec.len(vec.new({5, 6})), 2)
    T.eq(vec.len(vec.zeros(10)), 10)
  end)

  T.it("add element-wise", function()
    local a = vec.new({1, 2, 3})
    local b = vec.new({4, 5, 6})
    local c = vec.add(a, b)
    approx(vec.get(c, 1), 5)
    approx(vec.get(c, 2), 7)
    approx(vec.get(c, 3), 9)
  end)

  T.it("sub element-wise", function()
    local a = vec.new({10, 20, 30})
    local b = vec.new({1, 2, 3})
    local c = vec.sub(a, b)
    approx(vec.get(c, 1), 9)
    approx(vec.get(c, 2), 18)
    approx(vec.get(c, 3), 27)
  end)

  T.it("mul element-wise", function()
    local a = vec.new({2, 3, 4})
    local b = vec.new({5, 6, 7})
    local c = vec.mul(a, b)
    approx(vec.get(c, 1), 10)
    approx(vec.get(c, 2), 18)
    approx(vec.get(c, 3), 28)
  end)

  T.it("scale by scalar", function()
    local a = vec.new({1, 2, 3})
    local c = vec.scale(a, 3)
    approx(vec.get(c, 1), 3)
    approx(vec.get(c, 2), 6)
    approx(vec.get(c, 3), 9)
  end)

  T.it("dot product", function()
    local a = vec.new({1, 2, 3})
    local b = vec.new({4, 5, 6})
    approx(vec.dot(a, b), 32)
  end)

  T.it("norm L2", function()
    local v = vec.new({3, 4})
    approx(vec.norm(v), 5)
  end)

  T.it("norm1 L1", function()
    local v = vec.new({3, -4})
    approx(vec.norm1(v), 7)
  end)

  T.it("sum and mean", function()
    local v = vec.new({2, 4, 6})
    approx(vec.sum(v), 12)
    approx(vec.mean(v), 4)
  end)

  T.it("min, max, argmin, argmax", function()
    local v = vec.new({5, 1, 8, 3})
    approx(vec.min(v), 1)
    approx(vec.max(v), 8)
    T.eq(vec.argmin(v), 2)
    T.eq(vec.argmax(v), 3)
  end)

  T.it("cosine similarity: identical vectors", function()
    local a = vec.new({1, 2, 3})
    approx(vec.cosine(a, a), 1.0)
  end)

  T.it("cosine similarity: orthogonal vectors", function()
    local a = vec.new({1, 0})
    local b = vec.new({0, 1})
    approx(vec.cosine(a, b), 0.0)
  end)

  T.it("distance", function()
    local a = vec.new({0, 0})
    local b = vec.new({3, 4})
    approx(vec.distance(a, b), 5)
  end)

  T.it("normalize produces unit vector", function()
    local v = vec.new({3, 4})
    local u = vec.normalize(v)
    approx(vec.norm(u), 1.0)
    approx(vec.get(u, 1), 0.6)
    approx(vec.get(u, 2), 0.8)
  end)

  T.it("neg negates all elements", function()
    local v = vec.new({1, -2, 3})
    local n = vec.neg(v)
    approx(vec.get(n, 1), -1)
    approx(vec.get(n, 2), 2)
    approx(vec.get(n, 3), -3)
  end)

  T.it("get and set", function()
    local v = vec.new({10, 20, 30})
    approx(vec.get(v, 2), 20)
    vec.set(v, 2, 99)
    approx(vec.get(v, 2), 99)
  end)

  T.it("to_table round-trip", function()
    local t = {1.5, 2.5, 3.5}
    local v = vec.new(t)
    local t2 = vec.to_table(v)
    T.eq(#t2, 3)
    for i = 1, 3 do
      approx(t2[i], t[i])
    end
  end)

  T.it("to_string format", function()
    local v = vec.new({1, 2, 3})
    local s = vec.to_string(v)
    T.ok(s:find("1", 1, true) ~= nil, "contains 1")
    T.ok(s:find("2", 1, true) ~= nil, "contains 2")
    T.ok(s:find("3", 1, true) ~= nil, "contains 3")
    T.ok(s:sub(1, 1) == "[" and s:sub(-1) == "]", "bracketed")
  end)

  T.it("div element-wise", function()
    local a = vec.new({10, 20, 30})
    local b = vec.new({2, 5, 10})
    local c = vec.div(a, b)
    approx(vec.get(c, 1), 5)
    approx(vec.get(c, 2), 4)
    approx(vec.get(c, 3), 3)
  end)

  T.it("random produces values in [0,1)", function()
    math.randomseed(42)
    local v = vec.random(100)
    T.eq(vec.len(v), 100)
    for i = 1, 100 do
      local x = vec.get(v, i)
      T.ok(x >= 0 and x < 1, "value in [0,1): " .. x)
    end
  end)

  T.it("linspace produces evenly spaced values", function()
    local v = vec.linspace(0, 10, 5)
    T.eq(vec.len(v), 5)
    approx(vec.get(v, 1), 0)
    approx(vec.get(v, 2), 2.5)
    approx(vec.get(v, 3), 5)
    approx(vec.get(v, 4), 7.5)
    approx(vec.get(v, 5), 10)
  end)

  T.it("linspace n=1", function()
    local v = vec.linspace(5, 10, 1)
    T.eq(vec.len(v), 1)
    approx(vec.get(v, 1), 5)
  end)

  T.it("empty vector edge cases (n=0)", function()
    local v = vec.zeros(0)
    T.eq(vec.len(v), 0)
    approx(vec.sum(v), 0)
    approx(vec.norm(v), 0)
    approx(vec.norm1(v), 0)
    T.eq(vec.min(v), math.huge)
    T.eq(vec.max(v), -math.huge)
    T.eq(vec.argmin(v), 0)
    T.eq(vec.argmax(v), 0)
    T.eq(vec.to_string(v), "[]")
    T.eq(#vec.to_table(v), 0)

    -- arithmetic on empty vectors
    local v2 = vec.zeros(0)
    local a = vec.add(v, v2)
    T.eq(vec.len(a), 0)
    approx(vec.dot(v, v2), 0)
    approx(vec.distance(v, v2), 0)
  end)

  T.it("large vector (n=1000)", function()
    local t = {}
    for i = 1, 1000 do t[i] = i end
    local v = vec.new(t)
    T.eq(vec.len(v), 1000)
    approx(vec.get(v, 1), 1)
    approx(vec.get(v, 1000), 1000)
    approx(vec.sum(v), 500500)
    approx(vec.mean(v), 500.5)
    approx(vec.min(v), 1)
    approx(vec.max(v), 1000)
    T.eq(vec.argmin(v), 1)
    T.eq(vec.argmax(v), 1000)

    -- arithmetic
    local doubled = vec.scale(v, 2)
    approx(vec.get(doubled, 500), 1000)
    approx(vec.sum(doubled), 1001000)
  end)
end)
