if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local stream = require("lib.stream")

-- Helper: deep_eq for tables (simple, non-recursive)
local function tbl_eq(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return a == b end
  if #a ~= #b then return false end
  for i = 1, #a do
    if not tbl_eq(a[i], b[i]) then return false end
  end
  return true
end

-- ============================================================
-- Source constructors
-- ============================================================

T.describe("from_array", function()
  T.it("collects array elements in order", function()
    local r = stream.from_array({ 10, 20, 30 }):to_array()
    T.eq(#r, 3)
    T.eq(r[1], 10)
    T.eq(r[2], 20)
    T.eq(r[3], 30)
  end)

  T.it("handles empty array", function()
    local r = stream.from_array({}):to_array()
    T.eq(#r, 0)
  end)
end)

T.describe("range", function()
  T.it("generates inclusive range", function()
    local r = stream.range(1, 5):to_array()
    T.eq(#r, 5)
    T.eq(r[1], 1)
    T.eq(r[5], 5)
  end)

  T.it("supports step", function()
    local r = stream.range(1, 10, 3):to_array()
    T.ok(tbl_eq(r, { 1, 4, 7, 10 }))
  end)

  T.it("supports negative step", function()
    local r = stream.range(5, 1, -1):to_array()
    T.ok(tbl_eq(r, { 5, 4, 3, 2, 1 }))
  end)

  T.it("empty when start > stop with positive step", function()
    local r = stream.range(5, 1):to_array()
    T.eq(#r, 0)
  end)
end)

T.describe("of", function()
  T.it("creates stream from varargs", function()
    local r = stream.of(1, 2, 3):to_array()
    T.eq(#r, 3)
    T.eq(r[1], 1)
    T.eq(r[3], 3)
  end)

  T.it("handles single element", function()
    local r = stream.of(42):to_array()
    T.eq(#r, 1)
    T.eq(r[1], 42)
  end)
end)

T.describe("empty", function()
  T.it("produces no elements", function()
    T.eq(stream.empty():count(), 0)
  end)

  T.it("first returns nil", function()
    T.eq(stream.empty():first(), nil)
  end)
end)

T.describe("repeat_", function()
  T.it("produces infinite stream, usable with take", function()
    local r = stream.repeat_(7):take(4):to_array()
    T.ok(tbl_eq(r, { 7, 7, 7, 7 }))
  end)
end)

T.describe("generate", function()
  T.it("calls fn for each element", function()
    local i = 0
    local r = stream.generate(function() i = i + 1; return i end):take(3):to_array()
    T.ok(tbl_eq(r, { 1, 2, 3 }))
  end)
end)

T.describe("iterate", function()
  T.it("produces seed then fn(seed) repeatedly", function()
    local r = stream.iterate(1, function(x) return x * 2 end):take(5):to_array()
    T.ok(tbl_eq(r, { 1, 2, 4, 8, 16 }))
  end)
end)

T.describe("from_string", function()
  T.it("yields one character at a time", function()
    local r = stream.from_string("abc"):to_array()
    T.eq(#r, 3)
    T.eq(r[1], "a")
    T.eq(r[2], "b")
    T.eq(r[3], "c")
  end)

  T.it("handles empty string", function()
    T.eq(stream.from_string(""):count(), 0)
  end)
end)

T.describe("from_iter", function()
  T.it("wraps ipairs iterator", function()
    local t = { "a", "b", "c" }
    local r = stream.from_iter(ipairs(t)):to_array()
    T.eq(#r, 3)
    T.eq(r[1], "a")
    T.eq(r[2], "b")
    T.eq(r[3], "c")
  end)
end)

-- ============================================================
-- Transformations
-- ============================================================

T.describe("map", function()
  T.it("transforms elements", function()
    local r = stream.from_array({ 1, 2, 3 }):map(function(x) return x * 10 end):to_array()
    T.ok(tbl_eq(r, { 10, 20, 30 }))
  end)
end)

T.describe("filter", function()
  T.it("keeps matching elements", function()
    local r = stream.from_array({ 1, 2, 3, 4, 5 }):filter(function(x) return x % 2 == 1 end):to_array()
    T.ok(tbl_eq(r, { 1, 3, 5 }))
  end)

  T.it("returns empty when nothing matches", function()
    local r = stream.from_array({ 2, 4 }):filter(function(x) return x > 10 end):to_array()
    T.eq(#r, 0)
  end)
end)

T.describe("take", function()
  T.it("takes first n elements", function()
    local r = stream.range(1, 100):take(3):to_array()
    T.ok(tbl_eq(r, { 1, 2, 3 }))
  end)

  T.it("handles take more than available", function()
    local r = stream.from_array({ 1, 2 }):take(5):to_array()
    T.ok(tbl_eq(r, { 1, 2 }))
  end)

  T.it("take(0) gives empty", function()
    T.eq(stream.range(1, 10):take(0):count(), 0)
  end)
end)

T.describe("drop", function()
  T.it("skips first n elements", function()
    local r = stream.from_array({ 1, 2, 3, 4, 5 }):drop(2):to_array()
    T.ok(tbl_eq(r, { 3, 4, 5 }))
  end)

  T.it("drop all gives empty", function()
    T.eq(stream.from_array({ 1, 2 }):drop(5):count(), 0)
  end)
end)

T.describe("take_while", function()
  T.it("takes while predicate holds", function()
    local r = stream.from_array({ 1, 2, 3, 4, 1 }):take_while(function(x) return x < 4 end):to_array()
    T.ok(tbl_eq(r, { 1, 2, 3 }))
  end)
end)

T.describe("drop_while", function()
  T.it("drops while predicate holds", function()
    local r = stream.from_array({ 1, 2, 3, 4, 1 }):drop_while(function(x) return x < 3 end):to_array()
    T.ok(tbl_eq(r, { 3, 4, 1 }))
  end)
end)

T.describe("flat_map", function()
  T.it("maps then flattens arrays", function()
    local r = stream.from_array({ 1, 2, 3 }):flat_map(function(x) return { x, x * 10 } end):to_array()
    T.ok(tbl_eq(r, { 1, 10, 2, 20, 3, 30 }))
  end)

  T.it("handles empty inner arrays", function()
    local r = stream.from_array({ 1, 2 }):flat_map(function() return {} end):to_array()
    T.eq(#r, 0)
  end)

  T.it("flattens inner streams", function()
    local r = stream.from_array({ 1, 2 }):flat_map(function(x) return stream.of(x, x + 10) end):to_array()
    T.ok(tbl_eq(r, { 1, 11, 2, 12 }))
  end)
end)

T.describe("flatten", function()
  T.it("flattens one level of arrays", function()
    local r = stream.from_array({ { 1, 2 }, { 3, 4 } }):flatten():to_array()
    T.ok(tbl_eq(r, { 1, 2, 3, 4 }))
  end)
end)

T.describe("zip", function()
  T.it("pairs elements from two streams", function()
    local r = stream.from_array({ 1, 2, 3 }):zip(stream.from_array({ "a", "b", "c" })):to_array()
    T.eq(#r, 3)
    T.ok(tbl_eq(r[1], { 1, "a" }))
    T.ok(tbl_eq(r[3], { 3, "c" }))
  end)

  T.it("stops at shorter stream", function()
    local r = stream.range(1, 10):zip(stream.of("x")):to_array()
    T.eq(#r, 1)
  end)
end)

T.describe("chain", function()
  T.it("concatenates two streams", function()
    local r = stream.of(1, 2):chain(stream.of(3, 4)):to_array()
    T.ok(tbl_eq(r, { 1, 2, 3, 4 }))
  end)

  T.it("handles empty first stream", function()
    local r = stream.empty():chain(stream.of(1)):to_array()
    T.ok(tbl_eq(r, { 1 }))
  end)
end)

T.describe("enumerate", function()
  T.it("produces 1-based index-value pairs", function()
    local r = stream.from_array({ "a", "b" }):enumerate():to_array()
    T.ok(tbl_eq(r[1], { 1, "a" }))
    T.ok(tbl_eq(r[2], { 2, "b" }))
  end)
end)

T.describe("unique", function()
  T.it("removes consecutive duplicates", function()
    local r = stream.from_array({ 1, 1, 2, 2, 3, 1 }):unique():to_array()
    T.ok(tbl_eq(r, { 1, 2, 3, 1 }))
  end)
end)

T.describe("dedup", function()
  T.it("removes all duplicates", function()
    local r = stream.from_array({ 1, 2, 3, 1, 2, 4 }):dedup():to_array()
    T.ok(tbl_eq(r, { 1, 2, 3, 4 }))
  end)
end)

T.describe("scan", function()
  T.it("produces running accumulation", function()
    local r = stream.from_array({ 1, 2, 3 }):scan(0, function(a, b) return a + b end):to_array()
    T.ok(tbl_eq(r, { 1, 3, 6 }))
  end)
end)

T.describe("chunks", function()
  T.it("groups into fixed-size arrays", function()
    local r = stream.range(1, 7):chunks(3):to_array()
    T.eq(#r, 3)
    T.ok(tbl_eq(r[1], { 1, 2, 3 }))
    T.ok(tbl_eq(r[2], { 4, 5, 6 }))
    T.ok(tbl_eq(r[3], { 7 }))
  end)

  T.it("empty stream gives empty chunks", function()
    T.eq(stream.empty():chunks(3):count(), 0)
  end)
end)

T.describe("intersperse", function()
  T.it("inserts separator between elements", function()
    local r = stream.from_array({ 1, 2, 3 }):intersperse(0):to_array()
    T.ok(tbl_eq(r, { 1, 0, 2, 0, 3 }))
  end)

  T.it("single element has no separator", function()
    local r = stream.of(1):intersperse(0):to_array()
    T.ok(tbl_eq(r, { 1 }))
  end)

  T.it("empty stream stays empty", function()
    T.eq(stream.empty():intersperse(0):count(), 0)
  end)
end)

T.describe("tap", function()
  T.it("calls side-effect function without changing elements", function()
    local seen = {}
    local r = stream.from_array({ 1, 2, 3 }):tap(function(x) seen[#seen + 1] = x end):to_array()
    T.ok(tbl_eq(r, { 1, 2, 3 }))
    T.ok(tbl_eq(seen, { 1, 2, 3 }))
  end)
end)

-- ============================================================
-- Terminal operations
-- ============================================================

T.describe("to_array", function()
  T.it("collects all elements", function()
    T.eq(#stream.range(1, 5):to_array(), 5)
  end)
end)

T.describe("reduce", function()
  T.it("folds over elements", function()
    T.eq(stream.range(1, 4):reduce(0, function(a, b) return a + b end), 10)
  end)

  T.it("returns init for empty stream", function()
    T.eq(stream.empty():reduce(42, function(a, b) return a + b end), 42)
  end)
end)

T.describe("for_each", function()
  T.it("consumes all elements", function()
    local sum = 0
    stream.range(1, 3):for_each(function(x) sum = sum + x end)
    T.eq(sum, 6)
  end)
end)

T.describe("count", function()
  T.it("counts elements", function()
    T.eq(stream.range(1, 10):count(), 10)
  end)

  T.it("returns 0 for empty", function()
    T.eq(stream.empty():count(), 0)
  end)
end)

T.describe("sum", function()
  T.it("sums numbers", function()
    T.eq(stream.from_array({ 1, 2, 3, 4 }):sum(), 10)
  end)

  T.it("returns 0 for empty", function()
    T.eq(stream.empty():sum(), 0)
  end)
end)

T.describe("min / max", function()
  T.it("finds minimum", function()
    T.eq(stream.from_array({ 3, 1, 4, 1, 5 }):min(), 1)
  end)

  T.it("finds maximum", function()
    T.eq(stream.from_array({ 3, 1, 4, 1, 5 }):max(), 5)
  end)

  T.it("returns nil for empty", function()
    T.eq(stream.empty():min(), nil)
    T.eq(stream.empty():max(), nil)
  end)
end)

T.describe("find", function()
  T.it("returns first match", function()
    T.eq(stream.range(1, 10):find(function(x) return x > 5 end), 6)
  end)

  T.it("returns nil when not found", function()
    T.eq(stream.range(1, 3):find(function(x) return x > 10 end), nil)
  end)
end)

T.describe("any / all / none", function()
  T.it("any returns true when match exists", function()
    T.ok(stream.range(1, 5):any(function(x) return x == 3 end))
  end)

  T.it("any returns false for empty", function()
    T.eq(stream.empty():any(function() return true end), false)
  end)

  T.it("all returns true when all match", function()
    T.ok(stream.range(1, 5):all(function(x) return x <= 5 end))
  end)

  T.it("all returns false when one fails", function()
    T.eq(stream.range(1, 5):all(function(x) return x < 3 end), false)
  end)

  T.it("all returns true for empty", function()
    T.ok(stream.empty():all(function() return false end))
  end)

  T.it("none returns true when nothing matches", function()
    T.ok(stream.range(1, 5):none(function(x) return x > 10 end))
  end)

  T.it("none returns false when match exists", function()
    T.eq(stream.range(1, 5):none(function(x) return x == 3 end), false)
  end)
end)

T.describe("first / last / nth", function()
  T.it("first returns first element", function()
    T.eq(stream.range(10, 20):first(), 10)
  end)

  T.it("first returns nil for empty", function()
    T.eq(stream.empty():first(), nil)
  end)

  T.it("last returns last element", function()
    T.eq(stream.range(1, 5):last(), 5)
  end)

  T.it("last returns nil for empty", function()
    T.eq(stream.empty():last(), nil)
  end)

  T.it("nth returns nth element", function()
    T.eq(stream.range(10, 20):nth(3), 12)
  end)

  T.it("nth returns nil when out of bounds", function()
    T.eq(stream.of(1):nth(5), nil)
  end)
end)

T.describe("join", function()
  T.it("joins with separator", function()
    T.eq(stream.from_array({ "a", "b", "c" }):join(", "), "a, b, c")
  end)

  T.it("joins with empty separator", function()
    T.eq(stream.from_array({ "x", "y" }):join(""), "xy")
  end)

  T.it("joins empty stream", function()
    T.eq(stream.empty():join(","), "")
  end)
end)

T.describe("to_map", function()
  T.it("collects into table by key function", function()
    local m = stream.from_array({ "hi", "bye", "ok" }):to_map(function(s) return s:sub(1, 1) end)
    T.eq(m["h"], "hi")
    T.eq(m["b"], "bye")
    T.eq(m["o"], "ok")
  end)
end)

T.describe("partition", function()
  T.it("splits into passing and failing", function()
    local p, f = stream.range(1, 6):partition(function(x) return x % 2 == 0 end)
    T.ok(tbl_eq(p, { 2, 4, 6 }))
    T.ok(tbl_eq(f, { 1, 3, 5 }))
  end)
end)

T.describe("group_by", function()
  T.it("groups by key function", function()
    local g = stream.from_array({ 1, 2, 3, 4, 5, 6 }):group_by(function(x) return x % 3 end)
    T.ok(tbl_eq(g[0], { 3, 6 }))
    T.ok(tbl_eq(g[1], { 1, 4 }))
    T.ok(tbl_eq(g[2], { 2, 5 }))
  end)
end)

-- ============================================================
-- Laziness and composition
-- ============================================================

T.describe("laziness", function()
  T.it("infinite stream with take does not hang", function()
    local r = stream.repeat_(1):take(5):to_array()
    T.eq(#r, 5)
  end)

  T.it("generate with take is lazy", function()
    local calls = 0
    local r = stream.generate(function() calls = calls + 1; return calls end):take(3):to_array()
    T.eq(calls, 3)
    T.ok(tbl_eq(r, { 1, 2, 3 }))
  end)

  T.it("filter on infinite stream with take works", function()
    -- even numbers from an infinite counter
    local i = 0
    local r = stream.generate(function() i = i + 1; return i end)
      :filter(function(x) return x % 2 == 0 end)
      :take(3)
      :to_array()
    T.ok(tbl_eq(r, { 2, 4, 6 }))
  end)
end)

T.describe("chained combinators", function()
  T.it("map + filter + take", function()
    local r = stream.range(1, 100)
      :map(function(x) return x * x end)
      :filter(function(x) return x % 2 == 1 end)
      :take(4)
      :to_array()
    T.ok(tbl_eq(r, { 1, 9, 25, 49 }))
  end)

  T.it("enumerate + filter + map", function()
    local r = stream.from_array({ "a", "b", "c", "d" })
      :enumerate()
      :filter(function(pair) return pair[1] % 2 == 1 end)
      :map(function(pair) return pair[2] end)
      :to_array()
    T.ok(tbl_eq(r, { "a", "c" }))
  end)

  T.it("drop + take + sum", function()
    T.eq(stream.range(1, 10):drop(3):take(4):sum(), 4 + 5 + 6 + 7)
  end)

  T.it("chain + map + reduce", function()
    local r = stream.of(1, 2):chain(stream.of(3, 4))
      :map(function(x) return x * 2 end)
      :reduce(0, function(a, b) return a + b end)
    T.eq(r, 20)
  end)

  T.it("scan + take on infinite stream", function()
    -- fibonacci via scan
    local r = stream.repeat_(1)
      :take(6)
      :scan(0, function(a, b) return a + b end)
      :to_array()
    T.ok(tbl_eq(r, { 1, 2, 3, 4, 5, 6 }))
  end)
end)

T.describe("empty stream operations", function()
  T.it("map on empty", function()
    T.eq(stream.empty():map(function(x) return x end):count(), 0)
  end)

  T.it("filter on empty", function()
    T.eq(stream.empty():filter(function() return true end):count(), 0)
  end)

  T.it("flat_map on empty", function()
    T.eq(stream.empty():flat_map(function(x) return { x } end):count(), 0)
  end)

  T.it("zip on empty", function()
    T.eq(stream.empty():zip(stream.of(1)):count(), 0)
  end)

  T.it("reduce on empty returns init", function()
    T.eq(stream.empty():reduce(99, function(a, b) return a + b end), 99)
  end)

  T.it("partition on empty", function()
    local p, f = stream.empty():partition(function() return true end)
    T.eq(#p, 0)
    T.eq(#f, 0)
  end)

  T.it("group_by on empty", function()
    local g = stream.empty():group_by(function(x) return x end)
    T.eq(next(g), nil)
  end)
end)
