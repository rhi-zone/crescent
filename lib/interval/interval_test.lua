if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local interval = require("lib.interval")

-- ── Construction & accessors ────────────────────────────────────────────────

T.describe("interval: construction", function()
  T.it("creates an interval with lo and hi", function()
    local a = interval.new(1, 5)
    T.eq(a:get_lo(), 1)
    T.eq(a:get_hi(), 5)
  end)

  T.it("computes length", function()
    T.eq(interval.new(1, 5):length(), 4)
    T.eq(interval.new(3, 3):length(), 0)
  end)

  T.it("empty interval has zero length", function()
    local e = interval.new(5, 3)
    T.ok(e:empty())
    T.eq(e:length(), 0)
  end)

  T.it("non-empty interval is not empty", function()
    T.ok(not interval.new(1, 5):empty())
    T.ok(not interval.new(3, 3):empty())
  end)

  T.it("tostring formats correctly", function()
    T.eq(tostring(interval.new(1, 5)), "[1, 5]")
    T.eq(tostring(interval.new(-3, 10)), "[-3, 10]")
  end)
end)

-- ── Equality ────────────────────────────────────────────────────────────────

T.describe("interval: equality", function()
  T.it("equal intervals", function()
    T.ok(interval.new(1, 5):eq(interval.new(1, 5)))
  end)

  T.it("unequal intervals", function()
    T.ok(not interval.new(1, 5):eq(interval.new(1, 6)))
    T.ok(not interval.new(1, 5):eq(interval.new(2, 5)))
  end)

  T.it("__eq metamethod works", function()
    T.eq(interval.new(1, 5), interval.new(1, 5))
    T.neq(interval.new(1, 5), interval.new(1, 6))
  end)
end)

-- ── Contains (point) ────────────────────────────────────────────────────────

T.describe("interval: contains point", function()
  local a = interval.new(1, 5)

  T.it("contains interior point", function()
    T.ok(a:contains(3))
  end)

  T.it("contains endpoints", function()
    T.ok(a:contains(1))
    T.ok(a:contains(5))
  end)

  T.it("does not contain outside points", function()
    T.ok(not a:contains(0))
    T.ok(not a:contains(6))
  end)

  T.it("degenerate interval contains its point", function()
    T.ok(interval.new(3, 3):contains(3))
    T.ok(not interval.new(3, 3):contains(4))
  end)
end)

-- ── Contains interval ───────────────────────────────────────────────────────

T.describe("interval: contains_interval", function()
  T.it("contains sub-interval", function()
    T.ok(interval.new(1, 10):contains_interval(interval.new(2, 5)))
  end)

  T.it("contains itself", function()
    T.ok(interval.new(1, 5):contains_interval(interval.new(1, 5)))
  end)

  T.it("does not contain wider interval", function()
    T.ok(not interval.new(2, 5):contains_interval(interval.new(1, 6)))
  end)

  T.it("does not contain partially overlapping", function()
    T.ok(not interval.new(1, 5):contains_interval(interval.new(3, 8)))
  end)
end)

-- ── Overlaps ────────────────────────────────────────────────────────────────

T.describe("interval: overlaps", function()
  T.it("overlapping intervals", function()
    T.ok(interval.new(1, 5):overlaps(interval.new(3, 8)))
    T.ok(interval.new(3, 8):overlaps(interval.new(1, 5)))
  end)

  T.it("touching intervals overlap (shared endpoint)", function()
    T.ok(interval.new(1, 5):overlaps(interval.new(5, 8)))
    T.ok(interval.new(5, 8):overlaps(interval.new(1, 5)))
  end)

  T.it("non-overlapping intervals", function()
    T.ok(not interval.new(1, 3):overlaps(interval.new(4, 6)))
    T.ok(not interval.new(4, 6):overlaps(interval.new(1, 3)))
  end)

  T.it("contained interval overlaps", function()
    T.ok(interval.new(1, 10):overlaps(interval.new(3, 5)))
  end)
end)

-- ── Union ───────────────────────────────────────────────────────────────────

T.describe("interval: union", function()
  T.it("union of overlapping intervals", function()
    local u = interval.new(1, 5):union(interval.new(3, 8))
    T.eq(u, interval.new(1, 8))
  end)

  T.it("union of touching intervals", function()
    local u = interval.new(1, 5):union(interval.new(5, 8))
    T.eq(u, interval.new(1, 8))
  end)

  T.it("union of adjacent intervals (hi == other.lo)", function()
    local u = interval.new(1, 3):union(interval.new(3, 6))
    T.eq(u, interval.new(1, 6))
  end)

  T.it("union of non-overlapping returns nil", function()
    local u, err = interval.new(1, 3):union(interval.new(5, 8))
    T.eq(u, nil)
    T.ok(type(err) == "string")
  end)
end)

-- ── Intersection ────────────────────────────────────────────────────────────

T.describe("interval: intersection", function()
  T.it("intersection of overlapping intervals", function()
    local i = interval.new(1, 5):intersection(interval.new(3, 8))
    T.eq(i, interval.new(3, 5))
  end)

  T.it("intersection of touching intervals is degenerate", function()
    local i = interval.new(1, 5):intersection(interval.new(5, 8))
    T.eq(i, interval.new(5, 5))
    T.ok(not i:empty())
    T.eq(i:length(), 0)
  end)

  T.it("intersection of non-overlapping is empty", function()
    local i = interval.new(1, 3):intersection(interval.new(5, 8))
    T.ok(i:empty())
  end)

  T.it("intersection of contained interval", function()
    local i = interval.new(1, 10):intersection(interval.new(3, 5))
    T.eq(i, interval.new(3, 5))
  end)
end)

-- ── Merge collection ────────────────────────────────────────────────────────

T.describe("interval: merge", function()
  T.it("merges overlapping intervals", function()
    local result = interval.merge({
      interval.new(1, 5),
      interval.new(3, 8),
      interval.new(10, 15),
    })
    T.eq(#result, 2)
    T.eq(result[1], interval.new(1, 8))
    T.eq(result[2], interval.new(10, 15))
  end)

  T.it("merges touching intervals", function()
    local result = interval.merge({
      interval.new(1, 3),
      interval.new(3, 5),
      interval.new(5, 7),
    })
    T.eq(#result, 1)
    T.eq(result[1], interval.new(1, 7))
  end)

  T.it("handles already non-overlapping", function()
    local result = interval.merge({
      interval.new(1, 2),
      interval.new(4, 5),
      interval.new(7, 8),
    })
    T.eq(#result, 3)
  end)

  T.it("handles unsorted input", function()
    local result = interval.merge({
      interval.new(10, 15),
      interval.new(1, 5),
      interval.new(3, 8),
    })
    T.eq(#result, 2)
    T.eq(result[1], interval.new(1, 8))
    T.eq(result[2], interval.new(10, 15))
  end)

  T.it("empty input returns empty", function()
    T.eq(#interval.merge({}), 0)
  end)

  T.it("single interval returns copy", function()
    local result = interval.merge({ interval.new(1, 5) })
    T.eq(#result, 1)
    T.eq(result[1], interval.new(1, 5))
  end)
end)

-- ── Gaps ────────────────────────────────────────────────────────────────────

T.describe("interval: gaps", function()
  T.it("finds gaps between intervals", function()
    local g = interval.gaps({
      interval.new(1, 3),
      interval.new(5, 8),
    }, 0, 10)
    T.eq(#g, 3)
    T.eq(g[1], interval.new(0, 1))
    T.eq(g[2], interval.new(3, 5))
    T.eq(g[3], interval.new(8, 10))
  end)

  T.it("no gaps when fully covered", function()
    local g = interval.gaps({
      interval.new(0, 5),
      interval.new(5, 10),
    }, 0, 10)
    T.eq(#g, 0)
  end)

  T.it("entire range is a gap when no intervals", function()
    local g = interval.gaps({}, 0, 10)
    T.eq(#g, 1)
    T.eq(g[1], interval.new(0, 10))
  end)

  T.it("gaps with overlapping intervals", function()
    local g = interval.gaps({
      interval.new(1, 5),
      interval.new(3, 7),
    }, 0, 10)
    T.eq(#g, 2)
    T.eq(g[1], interval.new(0, 1))
    T.eq(g[2], interval.new(7, 10))
  end)
end)

-- ── Span ────────────────────────────────────────────────────────────────────

T.describe("interval: span", function()
  T.it("bounding interval of multiple", function()
    local s = interval.span({
      interval.new(3, 5),
      interval.new(1, 4),
      interval.new(7, 10),
    })
    T.eq(s, interval.new(1, 10))
  end)

  T.it("span of single interval", function()
    T.eq(interval.span({ interval.new(2, 8) }), interval.new(2, 8))
  end)

  T.it("span of empty returns nil", function()
    local s, err = interval.span({})
    T.eq(s, nil)
    T.ok(type(err) == "string")
  end)
end)

-- ── Interval tree ───────────────────────────────────────────────────────────

T.describe("interval tree: basic operations", function()
  T.it("starts empty", function()
    local tree = interval.tree()
    T.eq(tree:size(), 0)
    T.eq(#tree:all(), 0)
  end)

  T.it("insert and size", function()
    local tree = interval.tree()
    tree:insert(interval.new(1, 5), "a")
    tree:insert(interval.new(3, 8), "b")
    T.eq(tree:size(), 2)
  end)

  T.it("all returns entries in order", function()
    local tree = interval.tree()
    tree:insert(interval.new(3, 8), "b")
    tree:insert(interval.new(1, 5), "a")
    local all = tree:all()
    T.eq(#all, 2)
    T.eq(all[1][1], interval.new(1, 5))
    T.eq(all[1][2], "a")
    T.eq(all[2][1], interval.new(3, 8))
    T.eq(all[2][2], "b")
  end)

  T.it("remove existing interval", function()
    local tree = interval.tree()
    tree:insert(interval.new(1, 5), "a")
    tree:insert(interval.new(3, 8), "b")
    T.ok(tree:remove(interval.new(1, 5)))
    T.eq(tree:size(), 1)
    T.eq(tree:all()[1][2], "b")
  end)

  T.it("remove non-existing returns false", function()
    local tree = interval.tree()
    tree:insert(interval.new(1, 5), "a")
    T.ok(not tree:remove(interval.new(2, 6)))
    T.eq(tree:size(), 1)
  end)
end)

T.describe("interval tree: point queries", function()
  local tree = interval.tree()
  tree:insert(interval.new(1, 5), "a")
  tree:insert(interval.new(3, 8), "b")
  tree:insert(interval.new(10, 15), "c")

  T.it("point in one interval", function()
    local r = tree:query_point(2)
    T.eq(#r, 1)
    T.eq(r[1][2], "a")
  end)

  T.it("point in multiple intervals", function()
    local r = tree:query_point(4)
    T.eq(#r, 2)
    -- both a and b contain 4
    local found = {}
    for _, entry in ipairs(r) do found[entry[2]] = true end
    T.ok(found["a"])
    T.ok(found["b"])
  end)

  T.it("point at endpoint", function()
    local r = tree:query_point(5)
    T.eq(#r, 2)
  end)

  T.it("point outside all intervals", function()
    local r = tree:query_point(9)
    T.eq(#r, 0)
  end)

  T.it("point at far endpoint", function()
    local r = tree:query_point(15)
    T.eq(#r, 1)
    T.eq(r[1][2], "c")
  end)
end)

T.describe("interval tree: overlap queries", function()
  local tree = interval.tree()
  tree:insert(interval.new(1, 5), "a")
  tree:insert(interval.new(3, 8), "b")
  tree:insert(interval.new(10, 15), "c")
  tree:insert(interval.new(20, 25), "d")

  T.it("query overlapping multiple", function()
    local r = tree:query_overlap(interval.new(4, 6))
    T.eq(#r, 2)
    local found = {}
    for _, entry in ipairs(r) do found[entry[2]] = true end
    T.ok(found["a"])
    T.ok(found["b"])
  end)

  T.it("query overlapping one", function()
    local r = tree:query_overlap(interval.new(12, 13))
    T.eq(#r, 1)
    T.eq(r[1][2], "c")
  end)

  T.it("query overlapping none", function()
    local r = tree:query_overlap(interval.new(16, 19))
    T.eq(#r, 0)
  end)

  T.it("query touching endpoint", function()
    local r = tree:query_overlap(interval.new(5, 5))
    -- [1,5] and [3,8] both overlap [5,5]
    T.eq(#r, 2)
  end)

  T.it("wide query hits all", function()
    local r = tree:query_overlap(interval.new(0, 100))
    T.eq(#r, 4)
  end)
end)

T.describe("interval tree: edge cases", function()
  T.it("insert with nil data", function()
    local tree = interval.tree()
    tree:insert(interval.new(1, 5))
    local all = tree:all()
    T.eq(#all, 1)
    T.eq(all[1][2], nil)
  end)

  T.it("multiple inserts at same lo", function()
    local tree = interval.tree()
    tree:insert(interval.new(1, 5), "a")
    tree:insert(interval.new(1, 8), "b")
    tree:insert(interval.new(1, 3), "c")
    T.eq(tree:size(), 3)
    local r = tree:query_point(1)
    T.eq(#r, 3)
  end)

  T.it("remove first of duplicates at same lo", function()
    local tree = interval.tree()
    tree:insert(interval.new(1, 5), "a")
    tree:insert(interval.new(1, 8), "b")
    T.ok(tree:remove(interval.new(1, 5)))
    T.eq(tree:size(), 1)
    T.eq(tree:all()[1][2], "b")
  end)

  T.it("degenerate point interval in tree", function()
    local tree = interval.tree()
    tree:insert(interval.new(5, 5), "point")
    T.eq(#tree:query_point(5), 1)
    T.eq(#tree:query_point(4), 0)
    T.eq(#tree:query_point(6), 0)
  end)
end)
