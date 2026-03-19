local T = require("lib.test.assert")
local iter = require("lib.iter")

-- Helper: deep-equal assertion for arrays
local function arr_eq(got, expected, msg)
  T.eq(#got, #expected, (msg or "") .. " (length)")
  for i = 1, #expected do
    T.eq(got[i], expected[i], (msg or "") .. " [" .. i .. "]")
  end
end

T.describe("iter.range", function()
  T.it("ascending range", function()
    arr_eq(iter.to_array(iter.range(1, 5)), {1, 2, 3, 4, 5})
  end)

  T.it("descending range", function()
    arr_eq(iter.to_array(iter.range(5, 1)), {5, 4, 3, 2, 1})
  end)

  T.it("range with step", function()
    arr_eq(iter.to_array(iter.range(0, 10, 3)), {0, 3, 6, 9})
  end)

  T.it("descending range with negative step", function()
    arr_eq(iter.to_array(iter.range(10, 0, -3)), {10, 7, 4, 1})
  end)

  T.it("empty range (start > stop, positive step)", function()
    arr_eq(iter.to_array(iter.range(5, 1, 1)), {})
  end)

  T.it("empty range (start < stop, negative step)", function()
    arr_eq(iter.to_array(iter.range(1, 5, -1)), {})
  end)

  T.it("single element", function()
    arr_eq(iter.to_array(iter.range(3, 3)), {3})
  end)

  T.it("errors on zero step", function()
    T.throws(function() iter.range(1, 5, 0) end)
  end)
end)

T.describe("iter.values / iter.from", function()
  T.it("iterates array values", function()
    arr_eq(iter.to_array(iter.values({10, 20, 30})), {10, 20, 30})
  end)

  T.it("empty array", function()
    arr_eq(iter.to_array(iter.values({})), {})
  end)

  T.it("from is a synonym for values", function()
    T.ok(iter.from == iter.values)
  end)
end)

T.describe("iter.keys", function()
  T.it("iterates table keys", function()
    local result = iter.to_array(iter.keys({a = 1, b = 2}))
    table.sort(result)
    arr_eq(result, {"a", "b"})
  end)

  T.it("empty table", function()
    arr_eq(iter.to_array(iter.keys({})), {})
  end)
end)

T.describe("iter.map", function()
  T.it("transforms values", function()
    arr_eq(iter.to_array(iter.map(function(x) return x * 2 end, iter.range(1, 4))), {2, 4, 6, 8})
  end)

  T.it("works with for..in", function()
    local result = {}
    for v in iter.map(function(x) return x .. "!" end, iter.values({"a", "b", "c"})) do
      result[#result + 1] = v
    end
    arr_eq(result, {"a!", "b!", "c!"})
  end)

  T.it("empty iterator", function()
    arr_eq(iter.to_array(iter.map(function(x) return x end, iter.values({}))), {})
  end)
end)

T.describe("iter.filter", function()
  T.it("keeps matching values", function()
    arr_eq(iter.to_array(iter.filter(function(x) return x % 2 == 0 end, iter.range(1, 10))),
      {2, 4, 6, 8, 10})
  end)

  T.it("nothing matches", function()
    arr_eq(iter.to_array(iter.filter(function() return false end, iter.range(1, 5))), {})
  end)

  T.it("everything matches", function()
    arr_eq(iter.to_array(iter.filter(function() return true end, iter.range(1, 3))), {1, 2, 3})
  end)
end)

T.describe("iter.take", function()
  T.it("takes first n values", function()
    arr_eq(iter.to_array(iter.take(3, iter.range(1, 100))), {1, 2, 3})
  end)

  T.it("take 0", function()
    arr_eq(iter.to_array(iter.take(0, iter.range(1, 5))), {})
  end)

  T.it("take more than available", function()
    arr_eq(iter.to_array(iter.take(10, iter.range(1, 3))), {1, 2, 3})
  end)
end)

T.describe("iter.skip", function()
  T.it("skips first n values", function()
    arr_eq(iter.to_array(iter.skip(3, iter.range(1, 5))), {4, 5})
  end)

  T.it("skip 0", function()
    arr_eq(iter.to_array(iter.skip(0, iter.range(1, 3))), {1, 2, 3})
  end)

  T.it("skip more than available", function()
    arr_eq(iter.to_array(iter.skip(10, iter.range(1, 3))), {})
  end)
end)

T.describe("iter.zip", function()
  T.it("pairs up equal-length iterators", function()
    local a, b = {}, {}
    for x, y in iter.zip(iter.range(1, 3), iter.range(10, 12)) do
      a[#a + 1] = x
      b[#b + 1] = y
    end
    arr_eq(a, {1, 2, 3})
    arr_eq(b, {10, 11, 12})
  end)

  T.it("stops at shorter iterator", function()
    local a, b = {}, {}
    for x, y in iter.zip(iter.range(1, 2), iter.range(10, 15)) do
      a[#a + 1] = x
      b[#b + 1] = y
    end
    arr_eq(a, {1, 2})
    arr_eq(b, {10, 11})
  end)
end)

T.describe("iter.chain", function()
  T.it("concatenates two iterators", function()
    arr_eq(iter.to_array(iter.chain(iter.range(1, 3), iter.range(7, 9))), {1, 2, 3, 7, 8, 9})
  end)

  T.it("first empty", function()
    arr_eq(iter.to_array(iter.chain(iter.values({}), iter.range(1, 3))), {1, 2, 3})
  end)

  T.it("second empty", function()
    arr_eq(iter.to_array(iter.chain(iter.range(1, 3), iter.values({}))), {1, 2, 3})
  end)
end)

T.describe("iter.flat_map", function()
  T.it("maps and flattens", function()
    arr_eq(iter.to_array(iter.flat_map(
      function(x) return iter.range(1, x) end,
      iter.range(1, 3)
    )), {1, 1, 2, 1, 2, 3})
  end)

  T.it("empty inner", function()
    arr_eq(iter.to_array(iter.flat_map(
      function() return iter.values({}) end,
      iter.range(1, 3)
    )), {})
  end)
end)

T.describe("iter.enumerate", function()
  T.it("adds index to values", function()
    local indices, vals = {}, {}
    for i, v in iter.enumerate(iter.values({"a", "b", "c"})) do
      indices[#indices + 1] = i
      vals[#vals + 1] = v
    end
    arr_eq(indices, {1, 2, 3})
    arr_eq(vals, {"a", "b", "c"})
  end)
end)

T.describe("iter.fold", function()
  T.it("reduces with accumulator", function()
    local result = iter.fold(function(acc, x) return acc + x end, 0, iter.range(1, 5))
    T.eq(result, 15)
  end)

  T.it("string concatenation", function()
    local result = iter.fold(function(acc, x) return acc .. x end, "", iter.values({"a", "b", "c"}))
    T.eq(result, "abc")
  end)
end)

T.describe("iter.sum", function()
  T.it("sums numbers", function()
    T.eq(iter.sum(iter.range(1, 10)), 55)
  end)

  T.it("empty is 0", function()
    T.eq(iter.sum(iter.values({})), 0)
  end)
end)

T.describe("iter.count", function()
  T.it("counts elements", function()
    T.eq(iter.count(iter.range(1, 7)), 7)
  end)

  T.it("empty is 0", function()
    T.eq(iter.count(iter.values({})), 0)
  end)
end)

T.describe("iter.to_array", function()
  T.it("collects into array", function()
    arr_eq(iter.to_array(iter.range(1, 3)), {1, 2, 3})
  end)
end)

T.describe("iter.each", function()
  T.it("calls fn on each value", function()
    local seen = {}
    iter.each(function(x) seen[#seen + 1] = x end, iter.range(1, 3))
    arr_eq(seen, {1, 2, 3})
  end)
end)

T.describe("iter.any", function()
  T.it("true when match exists", function()
    T.ok(iter.any(function(x) return x > 3 end, iter.range(1, 5)))
  end)

  T.it("false when no match", function()
    T.ok(not iter.any(function(x) return x > 10 end, iter.range(1, 5)))
  end)

  T.it("short-circuits", function()
    local count = 0
    iter.any(function(x) count = count + 1; return x == 2 end, iter.range(1, 100))
    T.eq(count, 2)
  end)
end)

T.describe("iter.all", function()
  T.it("true when all match", function()
    T.ok(iter.all(function(x) return x > 0 end, iter.range(1, 5)))
  end)

  T.it("false when one fails", function()
    T.ok(not iter.all(function(x) return x < 3 end, iter.range(1, 5)))
  end)

  T.it("short-circuits", function()
    local count = 0
    iter.all(function(x) count = count + 1; return x < 3 end, iter.range(1, 100))
    T.eq(count, 3)
  end)
end)

T.describe("iter.find", function()
  T.it("finds first match", function()
    T.eq(iter.find(function(x) return x > 3 end, iter.range(1, 10)), 4)
  end)

  T.it("returns nil when no match", function()
    T.eq(iter.find(function(x) return x > 100 end, iter.range(1, 5)), nil)
  end)
end)

T.describe("composability", function()
  T.it("filter(pred, map(fn, range))", function()
    local result = iter.to_array(iter.filter(
      function(x) return x % 2 == 0 end,
      iter.map(function(x) return x * x end, iter.range(1, 10))
    ))
    -- squares of 1..10 that are even: 4, 16, 36, 64, 100
    arr_eq(result, {4, 16, 36, 64, 100})
  end)

  T.it("sum(take(n, range))", function()
    T.eq(iter.sum(iter.take(5, iter.range(1, 100))), 15)
  end)

  T.it("fold(fn, acc, filter(pred, values))", function()
    local result = iter.fold(
      function(acc, x) return acc + x end,
      0,
      iter.filter(function(x) return x > 2 end, iter.values({1, 2, 3, 4, 5}))
    )
    T.eq(result, 12)
  end)
end)

T.describe("works with standard Lua iterators", function()
  T.it("count with pairs", function()
    local t = {a = 1, b = 2, c = 3}
    T.eq(iter.count(pairs(t)), 3)
  end)

  T.it("to_array with ipairs keys", function()
    -- ipairs returns index, value; the first return (index) is the "value" seen by combinators
    arr_eq(iter.to_array(iter.take(3, ipairs({"a", "b", "c", "d"}))), {1, 2, 3})
  end)
end)
