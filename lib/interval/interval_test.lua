if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local interval = require("lib.interval")

-- ── Construction & basic accessors ──────────────────────────────────────────

T.describe("interval: construction", function()
  T.it("creates a closed interval with low/high", function()
    local a = interval.new(1, 5)
    T.eq(a:low(), 1)
    T.eq(a:high(), 5)
    T.ok(a:is_closed())
    T.ok(not a:is_open())
  end)

  T.it("legacy get_lo / get_hi aliases", function()
    local a = interval.new(2, 7)
    T.eq(a:get_lo(), 2)
    T.eq(a:get_hi(), 7)
  end)

  T.it("size and midpoint", function()
    local a = interval.new(1, 5)
    T.eq(a:size(), 4)
    T.eq(a:midpoint(), 3)
  end)

  T.it("length clamps to 0 for inverted", function()
    T.eq(interval.new(5, 3):length(), 0)
    T.eq(interval.new(1, 5):length(), 4)
  end)

  T.it("half-open interval (closed_left=true, closed_right=false)", function()
    local c = interval.new(1, 5, true, false)
    T.ok(not c:is_closed())
    T.ok(not c:is_open())
    T.ok(c:is_closed() == false)
  end)

  T.it("open interval", function()
    local o = interval.new(1, 5, false, false)
    T.ok(o:is_open())
    T.ok(not o:is_closed())
  end)

  T.it("tostring closed", function()
    T.eq(tostring(interval.new(1, 5)), "[1, 5]")
    T.eq(tostring(interval.new(-3, 10)), "[-3, 10]")
  end)

  T.it("tostring half-open", function()
    T.eq(tostring(interval.new(1, 5, true, false)), "[1, 5)")
    T.eq(tostring(interval.new(1, 5, false, true)), "(1, 5]")
    T.eq(tostring(interval.new(1, 5, false, false)), "(1, 5)")
  end)
end)

-- ── Empty interval ───────────────────────────────────────────────────────────

T.describe("interval: is_empty / empty", function()
  T.it("lo > hi is empty", function()
    T.ok(interval.new(5, 3):is_empty())
    T.ok(interval.new(5, 3):empty())
  end)

  T.it("lo == hi closed is not empty", function()
    T.ok(not interval.new(3, 3):is_empty())
  end)

  T.it("lo == hi open is empty", function()
    T.ok(interval.new(3, 3, false, true):is_empty())
    T.ok(interval.new(3, 3, true, false):is_empty())
    T.ok(interval.new(3, 3, false, false):is_empty())
  end)

  T.it("normal interval is not empty", function()
    T.ok(not interval.new(1, 5):is_empty())
  end)
end)

-- ── Equality ────────────────────────────────────────────────────────────────

T.describe("interval: equality", function()
  T.it("equal closed intervals via eq()", function()
    T.ok(interval.new(1, 5):eq(interval.new(1, 5)))
  end)

  T.it("unequal intervals via eq()", function()
    T.ok(not interval.new(1, 5):eq(interval.new(1, 6)))
    T.ok(not interval.new(1, 5):eq(interval.new(2, 5)))
  end)

  T.it("__eq metamethod", function()
    T.eq(interval.new(1, 5), interval.new(1, 5))
    T.neq(interval.new(1, 5), interval.new(1, 6))
  end)

  T.it("two empty intervals are equal regardless of endpoints", function()
    T.ok(interval.new(5, 3):eq(interval.new(9, 2)))
  end)

  T.it("closedness is part of equality", function()
    T.ok(not interval.new(1, 5):eq(interval.new(1, 5, true, false)))
  end)
end)

-- ── Contains point ───────────────────────────────────────────────────────────

T.describe("interval: contains point", function()
  T.it("interior point", function()
    T.ok(interval.new(1, 5):contains(3))
  end)

  T.it("closed endpoints are contained", function()
    T.ok(interval.new(1, 5):contains(1))
    T.ok(interval.new(1, 5):contains(5))
  end)

  T.it("open endpoints are not contained", function()
    T.ok(not interval.new(1, 5, false, true):contains(1))
    T.ok(interval.new(1, 5, false, true):contains(5))
    T.ok(interval.new(1, 5, true, false):contains(1))
    T.ok(not interval.new(1, 5, true, false):contains(5))
  end)

  T.it("outside points are not contained", function()
    T.ok(not interval.new(1, 5):contains(0))
    T.ok(not interval.new(1, 5):contains(6))
  end)

  T.it("degenerate closed [3,3] contains only 3", function()
    T.ok(interval.new(3, 3):contains(3))
    T.ok(not interval.new(3, 3):contains(4))
  end)

  T.it("empty interval contains nothing", function()
    T.ok(not interval.new(5, 3):contains(4))
    T.ok(not interval.new(3, 3, false, false):contains(3))
  end)
end)

-- ── Contains interval ────────────────────────────────────────────────────────

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

  T.it("closed contains half-open with same bounds", function()
    -- [1,5] contains [1,5)
    T.ok(interval.new(1, 5):contains_interval(interval.new(1, 5, true, false)))
  end)

  T.it("half-open does NOT contain closed at open end", function()
    -- [1,5) does NOT contain [1,5] because [1,5) is open at 5
    T.ok(not interval.new(1, 5, true, false):contains_interval(interval.new(1, 5)))
  end)

  T.it("empty interval is subset of anything", function()
    T.ok(interval.new(1, 5):contains_interval(interval.new(5, 3)))
  end)
end)

-- ── Overlaps ─────────────────────────────────────────────────────────────────

T.describe("interval: overlaps", function()
  T.it("overlapping intervals", function()
    T.ok(interval.new(1, 5):overlaps(interval.new(3, 8)))
    T.ok(interval.new(3, 8):overlaps(interval.new(1, 5)))
  end)

  T.it("touching closed endpoints overlap", function()
    T.ok(interval.new(1, 5):overlaps(interval.new(5, 8)))
    T.ok(interval.new(5, 8):overlaps(interval.new(1, 5)))
  end)

  T.it("touching open endpoints do NOT overlap", function()
    -- [1,5) and [5,8] share no point
    T.ok(not interval.new(1, 5, true, false):overlaps(interval.new(5, 8)))
    -- (1,5] and [5,8) share point 5
    T.ok(interval.new(1, 5, false, true):overlaps(interval.new(5, 8, true, false)))
  end)

  T.it("non-overlapping", function()
    T.ok(not interval.new(1, 3):overlaps(interval.new(4, 6)))
    T.ok(not interval.new(4, 6):overlaps(interval.new(1, 3)))
  end)

  T.it("contained interval overlaps", function()
    T.ok(interval.new(1, 10):overlaps(interval.new(3, 5)))
  end)

  T.it("empty intervals do not overlap", function()
    T.ok(not interval.new(5, 3):overlaps(interval.new(1, 10)))
  end)
end)

-- ── Intersection ─────────────────────────────────────────────────────────────

T.describe("interval: intersection", function()
  T.it("overlapping closed intervals", function()
    local i = interval.new(1, 5):intersection(interval.new(3, 8))
    T.eq(i, interval.new(3, 5))
  end)

  T.it("touching closed intervals gives degenerate [5,5]", function()
    local i = interval.new(1, 5):intersection(interval.new(5, 8))
    T.eq(i, interval.new(5, 5))
    T.ok(not i:is_empty())
    T.eq(i:length(), 0)
  end)

  T.it("non-overlapping gives empty interval", function()
    local i = interval.new(1, 3):intersection(interval.new(5, 8))
    T.ok(i:is_empty())
  end)

  T.it("contained interval", function()
    local i = interval.new(1, 10):intersection(interval.new(3, 5))
    T.eq(i, interval.new(3, 5))
  end)

  T.it("half-open intersection respects openness", function()
    -- [1,5) ∩ [3,8] = [3,5)
    local i = interval.new(1, 5, true, false):intersection(interval.new(3, 8))
    T.eq(i, interval.new(3, 5, true, false))
    T.ok(not i:contains(5))
    T.ok(i:contains(4))
  end)
end)

-- ── Union ────────────────────────────────────────────────────────────────────

T.describe("interval: union", function()
  T.it("overlapping closed intervals", function()
    local u = interval.new(1, 5):union(interval.new(3, 8))
    T.eq(u, interval.new(1, 8))
  end)

  T.it("touching closed intervals", function()
    local u = interval.new(1, 5):union(interval.new(5, 8))
    T.eq(u, interval.new(1, 8))
  end)

  T.it("adjacent (hi == other.lo) with at least one closed", function()
    local u = interval.new(1, 3):union(interval.new(3, 6))
    T.eq(u, interval.new(1, 6))
  end)

  T.it("non-overlapping returns an IntervalSet", function()
    local u = interval.new(1, 3):union(interval.new(5, 8))
    T.ok(getmetatable(u) == interval.Set)
    T.ok(u:contains(2))
    T.ok(u:contains(6))
    T.ok(not u:contains(4))
  end)

  T.it("union with empty returns self", function()
    local a = interval.new(1, 5)
    local empty = interval.new(5, 3)
    T.eq(a:union(empty), a)
  end)
end)

-- ── Difference ───────────────────────────────────────────────────────────────

T.describe("interval: difference", function()
  T.it("[1,5] - [3,8] = [1,3)", function()
    local d = interval.new(1, 5):difference(interval.new(3, 8))
    T.ok(d:contains(1))
    T.ok(d:contains(2))
    T.ok(not d:contains(3))
    T.ok(not d:contains(5))
  end)

  T.it("[1,8] - [3,5] = [1,3) ∪ (5,8]", function()
    local d = interval.new(1, 8):difference(interval.new(3, 5))
    -- Should be a set with two intervals
    T.ok(getmetatable(d) == interval.Set)
    T.ok(d:contains(1))
    T.ok(d:contains(8))
    T.ok(not d:contains(4))
  end)

  T.it("disjoint difference returns self", function()
    local a = interval.new(1, 3)
    local d = a:difference(interval.new(5, 8))
    T.eq(d, a)
  end)

  T.it("[1,5] - [1,5] is empty", function()
    local d = interval.new(1, 5):difference(interval.new(1, 5))
    T.ok(d:is_empty())
  end)
end)

-- ── Shift & scale ────────────────────────────────────────────────────────────

T.describe("interval: shift and scale", function()
  T.it("shift positive", function()
    T.eq(interval.new(1, 5):shift(2), interval.new(3, 7))
  end)

  T.it("shift negative", function()
    T.eq(interval.new(3, 7):shift(-1), interval.new(2, 6))
  end)

  T.it("shift preserves openness", function()
    local s = interval.new(1, 5, true, false):shift(3)
    T.ok(s.lo_closed)
    T.ok(not s.hi_closed)
    T.eq(s:low(), 4)
    T.eq(s:high(), 8)
  end)

  T.it("scale positive", function()
    T.eq(interval.new(1, 5):scale(2), interval.new(2, 10))
  end)

  T.it("scale by zero collapses to point", function()
    T.eq(interval.new(1, 5):scale(0), interval.new(0, 0))
  end)

  T.it("scale negative reverses interval", function()
    local s = interval.new(1, 5):scale(-1)
    T.eq(s:low(), -5)
    T.eq(s:high(), -1)
  end)
end)

-- ── Clamp ────────────────────────────────────────────────────────────────────

T.describe("interval: clamp", function()
  T.it("value below clamps to lo", function()
    T.eq(interval.new(2, 8):clamp(0), 2)
  end)

  T.it("value above clamps to hi", function()
    T.eq(interval.new(2, 8):clamp(10), 8)
  end)

  T.it("value inside unchanged", function()
    T.eq(interval.new(2, 8):clamp(5), 5)
  end)

  T.it("value at lo unchanged", function()
    T.eq(interval.new(2, 8):clamp(2), 2)
  end)

  T.it("value at hi unchanged", function()
    T.eq(interval.new(2, 8):clamp(8), 8)
  end)
end)

-- ── Before / after ───────────────────────────────────────────────────────────

T.describe("interval: before / after", function()
  T.it("before: a is strictly before b", function()
    T.ok(interval.new(1, 3):before(interval.new(5, 8)))
  end)

  T.it("before: not before if overlapping", function()
    T.ok(not interval.new(1, 5):before(interval.new(3, 8)))
  end)

  T.it("before: not before if touching closed-closed", function()
    T.ok(not interval.new(1, 5):before(interval.new(5, 8)))
  end)

  T.it("before: before if touching open end", function()
    -- [1,5) is before [5,8] because they share no point
    T.ok(interval.new(1, 5, true, false):before(interval.new(5, 8)))
  end)

  T.it("after: a is strictly after b", function()
    T.ok(interval.new(5, 8):after(interval.new(1, 3)))
  end)

  T.it("after: not after if overlapping", function()
    T.ok(not interval.new(3, 8):after(interval.new(1, 5)))
  end)
end)

-- ── Integer range ────────────────────────────────────────────────────────────

T.describe("interval: range iteration", function()
  T.it("default step 1", function()
    local r = interval.range(1, 5)
    local t = r:to_table()
    T.eq(#t, 5)
    T.eq(t[1], 1)
    T.eq(t[5], 5)
  end)

  T.it("step 2", function()
    local r = interval.range(1, 10, 2)
    local t = r:to_table()
    -- 1,3,5,7,9
    T.eq(#t, 5)
    T.eq(t[1], 1)
    T.eq(t[2], 3)
    T.eq(t[5], 9)
  end)

  T.it("single element", function()
    local t = interval.range(4, 4):to_table()
    T.eq(#t, 1)
    T.eq(t[1], 4)
  end)

  T.it("empty range (lo > hi)", function()
    local t = interval.range(5, 3):to_table()
    T.eq(#t, 0)
  end)

  T.it("iter works as a stateless generator", function()
    local sum = 0
    for v in interval.range(1, 4):iter() do sum = sum + v end
    T.eq(sum, 10)  -- 1+2+3+4
  end)
end)

-- ── Interval set ─────────────────────────────────────────────────────────────

T.describe("interval set", function()
  T.it("set:contains checks all intervals", function()
    local s = interval.set({ interval.new(1, 3), interval.new(5, 8) })
    T.ok(s:contains(2))
    T.ok(s:contains(6))
    T.ok(not s:contains(4))
    T.ok(not s:contains(9))
  end)

  T.it("normalize merges overlapping", function()
    local s = interval.set({
      interval.new(1, 5),
      interval.new(3, 8),
      interval.new(10, 15),
    }):normalize()
    T.eq(s.n, 2)
    T.eq(s.intervals[1], interval.new(1, 8))
    T.eq(s.intervals[2], interval.new(10, 15))
  end)

  T.it("normalize merges touching (closed)", function()
    local s = interval.set({
      interval.new(1, 3),
      interval.new(3, 6),
    }):normalize()
    T.eq(s.n, 1)
    T.eq(s.intervals[1], interval.new(1, 6))
  end)

  T.it("normalize leaves disjoint intervals alone", function()
    local s = interval.set({
      interval.new(1, 2),
      interval.new(4, 5),
    }):normalize()
    T.eq(s.n, 2)
  end)

  T.it("normalize sorts by lo", function()
    local s = interval.set({
      interval.new(5, 8),
      interval.new(1, 3),
    }):normalize()
    T.eq(s.intervals[1]:low(), 1)
    T.eq(s.intervals[2]:low(), 5)
  end)

  T.it("set:union merges two sets", function()
    local a = interval.set({ interval.new(1, 3) })
    local b = interval.set({ interval.new(2, 5), interval.new(7, 9) })
    local u = a:union(b)
    T.eq(u.n, 2)
    T.ok(u:contains(2))
    T.ok(u:contains(8))
    T.ok(not u:contains(6))
  end)

  T.it("set:intersection finds shared regions", function()
    local a = interval.set({ interval.new(1, 6) })
    local b = interval.set({ interval.new(3, 10) })
    local i = a:intersection(b)
    T.eq(i.n, 1)
    T.eq(i.intervals[1], interval.new(3, 6))
  end)

  T.it("set:intersection with no overlap is empty", function()
    local a = interval.set({ interval.new(1, 3) })
    local b = interval.set({ interval.new(5, 8) })
    local i = a:intersection(b)
    T.eq(i.n, 0)
  end)
end)

-- ── Collection utilities ──────────────────────────────────────────────────────

T.describe("interval: merge utility", function()
  T.it("merges overlapping", function()
    local result = interval.merge({
      interval.new(1, 5),
      interval.new(3, 8),
      interval.new(10, 15),
    })
    T.eq(#result, 2)
    T.eq(result[1], interval.new(1, 8))
    T.eq(result[2], interval.new(10, 15))
  end)

  T.it("merges touching", function()
    local result = interval.merge({
      interval.new(1, 3),
      interval.new(3, 5),
      interval.new(5, 7),
    })
    T.eq(#result, 1)
    T.eq(result[1], interval.new(1, 7))
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

  T.it("empty input", function()
    T.eq(#interval.merge({}), 0)
  end)

  T.it("single interval", function()
    local result = interval.merge({ interval.new(1, 5) })
    T.eq(#result, 1)
    T.eq(result[1], interval.new(1, 5))
  end)
end)

T.describe("interval: gaps utility", function()
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

  T.it("entire range is gap when no intervals", function()
    local g = interval.gaps({}, 0, 10)
    T.eq(#g, 1)
    T.eq(g[1], interval.new(0, 10))
  end)
end)

T.describe("interval: span utility", function()
  T.it("bounding interval of multiple", function()
    local s = interval.span({
      interval.new(3, 5),
      interval.new(1, 4),
      interval.new(7, 10),
    })
    T.eq(s, interval.new(1, 10))
  end)

  T.it("span of single", function()
    T.eq(interval.span({ interval.new(2, 8) }), interval.new(2, 8))
  end)

  T.it("span of empty returns nil with error", function()
    local s, err = interval.span({})
    T.eq(s, nil)
    T.ok(type(err) == "string")
  end)
end)

-- ── Interval tree ─────────────────────────────────────────────────────────────

T.describe("interval tree: basics", function()
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

  T.it("all returns entries sorted by lo", function()
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

  T.it("remove existing", function()
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
    local found = {}
    for _, entry in ipairs(r) do found[entry[2]] = true end
    T.ok(found["a"])
    T.ok(found["b"])
  end)

  T.it("point at shared endpoint", function()
    local r = tree:query_point(5)
    T.eq(#r, 2)
  end)

  T.it("point outside all intervals", function()
    local r = tree:query_point(9)
    T.eq(#r, 0)
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

  T.it("wide query hits all", function()
    local r = tree:query_overlap(interval.new(0, 100))
    T.eq(#r, 4)
  end)
end)

-- ── Report ────────────────────────────────────────────────────────────────────

local summary = T._summary()
local total = summary.pass + summary.fail
io.write(string.format(
  "\n%d/%d assertions passed",
  summary.pass, total
))
if summary.fail > 0 then
  io.write(string.format(", %d FAILED", summary.fail))
  for _, t in ipairs(summary.tests) do
    if not t.ok then
      io.write(string.format("\n  FAIL: %s\n    %s", t.name, t.err or ""))
    end
  end
  io.write("\n")
  os.exit(1)
else
  io.write(" — all pass\n")
end
