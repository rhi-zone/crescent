-- lib/count_min/count_min_test.lua
-- Tests for Count-Min Sketch (lib/count_min).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local cms = require("lib.count_min")

-- ---------------------------------------------------------------------------
-- Constructor: new(epsilon, delta)
-- ---------------------------------------------------------------------------

T.describe("count_min.new", function()
  T.it("returns a sketch for valid epsilon/delta", function()
    local s, err = cms.new(0.01, 0.01)
    T.ok(s ~= nil, "should return a sketch")
    T.ok(err == nil, "should have no error")
  end)

  T.it("dimensions match theoretical formula", function()
    local s = cms.new(0.01, 0.01)
    -- w = ceil(e / 0.01) = ceil(271.8...) = 272
    -- d = ceil(ln(100)) = ceil(4.60...) = 5
    T.ok(s:width()  >= 272, "width should be >= 272 for epsilon=0.01")
    T.ok(s:depth()  >= 5,   "depth should be >= 5 for delta=0.01")
  end)

  T.it("rejects epsilon out of range", function()
    local s1, e1 = cms.new(0, 0.01)
    T.ok(s1 == nil, "epsilon=0 should fail")
    T.ok(type(e1) == "string", "should return error string")

    local s2, e2 = cms.new(1, 0.01)
    T.ok(s2 == nil, "epsilon=1 should fail")
    T.ok(type(e2) == "string", "should return error string")
  end)

  T.it("rejects delta out of range", function()
    local s1, e1 = cms.new(0.01, 0)
    T.ok(s1 == nil, "delta=0 should fail")
    T.ok(type(e1) == "string", "should return error string")

    local s2, e2 = cms.new(0.01, 1)
    T.ok(s2 == nil, "delta=1 should fail")
    T.ok(type(e2) == "string", "should return error string")
  end)
end)

-- ---------------------------------------------------------------------------
-- Constructor: new_wh(width, depth)
-- ---------------------------------------------------------------------------

T.describe("count_min.new_wh", function()
  T.it("creates sketch with exact dimensions", function()
    local s = cms.new_wh(100, 5)
    T.eq(s:width(), 100, "width")
    T.eq(s:depth(), 5,   "depth")
  end)

  T.it("rejects invalid dimensions", function()
    local s1, e1 = cms.new_wh(0, 5)
    T.ok(s1 == nil, "width=0 should fail")
    T.ok(type(e1) == "string")

    local s2, e2 = cms.new_wh(100, 0)
    T.ok(s2 == nil, "depth=0 should fail")
    T.ok(type(e2) == "string")
  end)
end)

-- ---------------------------------------------------------------------------
-- update / query basic behaviour
-- ---------------------------------------------------------------------------

T.describe("update and query", function()
  T.it("single element: 5 updates → query >= 5", function()
    local s = cms.new_wh(1000, 7)
    for _ = 1, 5 do s:update("foo") end
    T.ok(s:query("foo") >= 5, "estimate must be >= actual count")
  end)

  T.it("unseen element returns 0", function()
    local s = cms.new_wh(200, 5)
    s:update("bar", 10)
    T.eq(s:query("never_inserted"), 0, "unseen element should be 0")
  end)

  T.it("multiple elements: no false negatives", function()
    local s = cms.new(0.01, 0.01)
    s:update("apple",  100)
    s:update("banana",  50)
    s:update("cherry",  25)
    T.ok(s:query("apple")  >= 100, "apple estimate >= 100")
    T.ok(s:query("banana") >=  50, "banana estimate >= 50")
    T.ok(s:query("cherry") >=  25, "cherry estimate >= 25")
  end)

  T.it("large batch: estimate <= true_count + epsilon*N", function()
    local epsilon = 0.01
    local delta   = 0.01
    local s       = cms.new(epsilon, delta)
    local N       = 10000
    -- Insert a diverse set of elements to stress the sketch.
    local true_count = {}
    for i = 1, N do
      local key = "key" .. (i % 100)   -- 100 distinct keys
      s:update(key, 1)
      true_count[key] = (true_count[key] or 0) + 1
    end
    -- Check a specific heavy hitter.
    local target = "key0"  -- inserted 100 times
    local est = s:query(target)
    local tc  = true_count[target]
    T.ok(est >= tc, "no false negative: estimate >= true count")
    T.ok(est <= tc + epsilon * N, "estimate within error bound")
  end)

  T.it("update with custom amount", function()
    local s = cms.new_wh(500, 5)
    s:update("x", 42)
    T.ok(s:query("x") >= 42, "estimate >= inserted amount")
  end)

  T.it("numeric keys are coerced to strings", function()
    local s = cms.new_wh(200, 5)
    s:update(123, 7)
    T.ok(s:query(123) >= 7, "numeric key works")
    T.ok(s:query("123") >= 7, "string coercion consistent")
  end)
end)

-- ---------------------------------------------------------------------------
-- total()
-- ---------------------------------------------------------------------------

T.describe("total", function()
  T.it("tracks cumulative update count", function()
    local s = cms.new_wh(100, 3)
    T.eq(s:total(), 0, "initial total is 0")
    s:update("a", 10)
    T.eq(s:total(), 10, "after update 10")
    s:update("b", 5)
    T.eq(s:total(), 15, "after update 5 more")
    s:update("c")   -- default amount 1
    T.eq(s:total(), 16, "after update 1 more")
  end)
end)

-- ---------------------------------------------------------------------------
-- update_conservative
-- ---------------------------------------------------------------------------

T.describe("update_conservative", function()
  T.it("produces estimates >= actual count (no false negatives)", function()
    local s = cms.new_wh(500, 5)
    for _ = 1, 20 do s:update_conservative("foo") end
    T.ok(s:query("foo") >= 20, "conservative: estimate >= count")
  end)

  T.it("total tracks conservative updates correctly", function()
    local s = cms.new_wh(200, 4)
    s:update_conservative("a", 5)
    s:update_conservative("b", 3)
    T.eq(s:total(), 8, "total after conservative updates")
  end)

  T.it("conservative ≤ regular for heavy collision scenario", function()
    -- With a tiny width there will be collisions; conservative should be ≤ regular.
    local sc = cms.new_wh(3, 3)   -- very narrow → many collisions
    local sr = cms.new_wh(3, 3)
    -- Re-seed both identically by using same w/d.
    local items = { "a", "b", "c", "d", "e" }
    for _, v in ipairs(items) do
      sc:update_conservative(v, 10)
      sr:update(v, 10)
    end
    for _, v in ipairs(items) do
      T.ok(sc:query(v) <= sr:query(v),
        "conservative estimate <= regular estimate for " .. v)
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- reset()
-- ---------------------------------------------------------------------------

T.describe("reset", function()
  T.it("all queries return 0 after reset", function()
    local s = cms.new_wh(200, 5)
    s:update("a", 100)
    s:update("b", 50)
    s:reset()
    T.eq(s:query("a"), 0, "a should be 0 after reset")
    T.eq(s:query("b"), 0, "b should be 0 after reset")
    T.eq(s:total(), 0,    "total should be 0 after reset")
  end)

  T.it("sketch usable after reset", function()
    local s = cms.new_wh(200, 5)
    s:update("x", 99)
    s:reset()
    s:update("x", 7)
    T.ok(s:query("x") >= 7, "can insert after reset")
    T.eq(s:total(), 7, "total reflects post-reset updates")
  end)
end)

-- ---------------------------------------------------------------------------
-- merge()
-- ---------------------------------------------------------------------------

T.describe("merge", function()
  T.it("merges counts additively", function()
    local s1 = cms.new_wh(300, 5)
    local s2 = cms.new_wh(300, 5)
    s1:update("foo", 30)
    s2:update("foo", 20)
    s1:merge(s2)
    T.ok(s1:query("foo") >= 50, "merged estimate >= 50")
  end)

  T.it("total is sum of both totals", function()
    local s1 = cms.new_wh(200, 4)
    local s2 = cms.new_wh(200, 4)
    s1:update("a", 10)
    s2:update("b", 15)
    s1:merge(s2)
    T.eq(s1:total(), 25, "merged total = 10 + 15")
  end)

  T.it("returns error for incompatible dimensions", function()
    local s1 = cms.new_wh(100, 3)
    local s2 = cms.new_wh(200, 3)
    local res, err = s1:merge(s2)
    T.ok(res == nil, "should return nil for width mismatch")
    T.ok(type(err) == "string", "should return error string")
  end)

  T.it("returns error for depth mismatch", function()
    local s1 = cms.new_wh(100, 3)
    local s2 = cms.new_wh(100, 4)
    local res, err = s1:merge(s2)
    T.ok(res == nil, "should return nil for depth mismatch")
    T.ok(type(err) == "string", "should return error string")
  end)

  T.it("returns self on success", function()
    local s1 = cms.new_wh(100, 3)
    local s2 = cms.new_wh(100, 3)
    local res, err = s1:merge(s2)
    T.ok(res == s1, "merge should return self")
    T.ok(err == nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- width() / depth()
-- ---------------------------------------------------------------------------

T.describe("width and depth", function()
  T.it("new_wh returns correct values", function()
    local s = cms.new_wh(77, 9)
    T.eq(s:width(), 77)
    T.eq(s:depth(),  9)
  end)

  T.it("new returns values matching formula", function()
    -- epsilon=0.1 → w=ceil(e/0.1)=ceil(27.18...)=28
    -- delta=0.1  → d=ceil(ln(10))=ceil(2.30...)=3
    local s = cms.new(0.1, 0.1)
    T.ok(s:width() >= 28, "w >= 28 for epsilon=0.1")
    T.ok(s:depth() >= 3,  "d >= 3 for delta=0.1")
  end)
end)

-- ---------------------------------------------------------------------------
-- serialize / deserialize
-- ---------------------------------------------------------------------------

T.describe("serialize / deserialize", function()
  T.it("round-trips dimensions", function()
    local s = cms.new_wh(150, 4)
    local blob = s:serialize()
    local s2, err = cms.deserialize(blob)
    T.ok(s2 ~= nil, "deserialize should succeed")
    T.ok(err == nil, "no error")
    T.eq(s2:width(), 150, "width preserved")
    T.eq(s2:depth(),   4, "depth preserved")
  end)

  T.it("round-trips counter values", function()
    local s = cms.new_wh(200, 5)
    s:update("hello", 17)
    s:update("world", 42)
    local blob = s:serialize()
    local s2   = cms.deserialize(blob)
    T.ok(s2:query("hello") >= 17, "hello estimate preserved")
    T.ok(s2:query("world") >= 42, "world estimate preserved")
  end)

  T.it("round-trips total", function()
    local s = cms.new_wh(100, 3)
    s:update("a", 99)
    s:update("b", 1)
    local blob = s:serialize()
    local s2   = cms.deserialize(blob)
    T.eq(s2:total(), 100, "total preserved after round-trip")
  end)

  T.it("estimates match before and after round-trip", function()
    local s = cms.new(0.05, 0.05)
    local words = { "the", "quick", "brown", "fox", "the", "the", "quick" }
    for _, w in ipairs(words) do s:update(w) end
    local blob = s:serialize()
    local s2   = cms.deserialize(blob)
    T.eq(s2:query("the"),   s:query("the"),   "the count matches")
    T.eq(s2:query("quick"), s:query("quick"), "quick count matches")
    T.eq(s2:query("fox"),   s:query("fox"),   "fox count matches")
  end)

  T.it("rejects invalid data", function()
    local s1, e1 = cms.deserialize("")
    T.ok(s1 == nil, "empty string rejected")
    T.ok(type(e1) == "string")

    local s2, e2 = cms.deserialize("tooshort")
    T.ok(s2 == nil, "too-short string rejected")
    T.ok(type(e2) == "string")

    -- Valid header but truncated body.
    local s = cms.new_wh(10, 2)
    local blob = s:serialize()
    local truncated = blob:sub(1, 18)  -- cut off mid-body
    local s3, e3 = cms.deserialize(truncated)
    T.ok(s3 == nil, "truncated data rejected")
    T.ok(type(e3) == "string")
  end)
end)

-- ---------------------------------------------------------------------------
-- heavy_hitters
-- ---------------------------------------------------------------------------

T.describe("heavy_hitters", function()
  T.it("returns error without track_heavy", function()
    local s = cms.new_wh(100, 3)
    local res, err = s:heavy_hitters(5)
    T.ok(res == nil, "should fail without track_heavy")
    T.ok(type(err) == "string")
  end)

  T.it("returns top-k elements in descending order", function()
    local s = cms.new(0.01, 0.01, { track_heavy = true })
    s:update("rare",   1)
    s:update("medium", 50)
    s:update("common", 200)
    local top = s:heavy_hitters(2)
    T.ok(top ~= nil, "should return results")
    T.eq(#top, 2, "should return exactly 2 results")
    T.eq(top[1][1], "common", "top element should be 'common'")
    T.ok(top[1][2] > top[2][2], "results in descending order")
  end)

  T.it("returns all elements when k is nil", function()
    local s = cms.new_wh(100, 3, { track_heavy = true })
    s:update("a", 5)
    s:update("b", 3)
    s:update("c", 8)
    local all = s:heavy_hitters()
    T.eq(#all, 3, "should return all 3 elements")
    T.eq(all[1][1], "c", "highest count first")
  end)

  T.it("heavy hitters survive merge", function()
    local s1 = cms.new_wh(200, 4, { track_heavy = true })
    local s2 = cms.new_wh(200, 4, { track_heavy = true })
    s1:update("x", 10)
    s2:update("x", 15)
    s1:merge(s2)
    local top = s1:heavy_hitters(1)
    T.ok(top ~= nil)
    T.eq(top[1][1], "x")
    T.eq(top[1][2], 25, "merged heavy count should be 25")
  end)

  T.it("heavy hitters reset on reset()", function()
    local s = cms.new_wh(100, 3, { track_heavy = true })
    s:update("z", 99)
    s:reset()
    local all = s:heavy_hitters()
    T.eq(#all, 0, "no heavy hitters after reset")
  end)
end)
