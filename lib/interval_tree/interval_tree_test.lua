if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local it = require("lib.interval_tree")

-- Helper: sort result array by lo, then hi for deterministic comparison
local function sort_results(arr)
  table.sort(arr, function(a, b)
    if a.lo ~= b.lo then return a.lo < b.lo end
    return a.hi < b.hi
  end)
  return arr
end

-- ── Insert and stab ──────────────────────────────────────────────────────────

T.describe("interval_tree: insert and stab", function()
  T.it("point inside returns correct intervals", function()
    local tree = it.tree()
    tree:insert(10, 20, "a")
    tree:insert(15, 25, "b")
    tree:insert(5, 12, "c")
    tree:insert(30, 40, "d")
    local hits = sort_results(tree:stab(17))
    T.eq(#hits, 2)
    T.eq(hits[1].lo, 10) T.eq(hits[1].hi, 20) T.eq(hits[1].data, "a")
    T.eq(hits[2].lo, 15) T.eq(hits[2].hi, 25) T.eq(hits[2].data, "b")
  end)

  T.it("point outside all intervals returns empty", function()
    local tree = it.tree()
    tree:insert(10, 20, "a")
    tree:insert(30, 40, "b")
    local hits = tree:stab(25)
    T.eq(#hits, 0)
  end)

  T.it("boundary: point at lo is included", function()
    local tree = it.tree()
    tree:insert(10, 20, "a")
    local hits = tree:stab(10)
    T.eq(#hits, 1)
    T.eq(hits[1].lo, 10)
  end)

  T.it("boundary: point at hi is included", function()
    local tree = it.tree()
    tree:insert(10, 20, "a")
    local hits = tree:stab(20)
    T.eq(#hits, 1)
    T.eq(hits[1].hi, 20)
  end)

  T.it("point just below lo returns empty", function()
    local tree = it.tree()
    tree:insert(10, 20, "a")
    local hits = tree:stab(9)
    T.eq(#hits, 0)
  end)

  T.it("point just above hi returns empty", function()
    local tree = it.tree()
    tree:insert(10, 20, "a")
    local hits = tree:stab(21)
    T.eq(#hits, 0)
  end)
end)

-- ── Overlap ──────────────────────────────────────────────────────────────────

T.describe("interval_tree: overlap", function()
  T.it("overlap query returns correct set", function()
    local tree = it.tree()
    tree:insert(10, 20, "a")
    tree:insert(15, 25, "b")
    tree:insert(5, 12, "c")
    tree:insert(30, 40, "d")
    local hits = sort_results(tree:overlap(11, 22))
    T.eq(#hits, 3)
    T.eq(hits[1].lo, 5)  T.eq(hits[1].hi, 12) T.eq(hits[1].data, "c")
    T.eq(hits[2].lo, 10) T.eq(hits[2].hi, 20) T.eq(hits[2].data, "a")
    T.eq(hits[3].lo, 15) T.eq(hits[3].hi, 25) T.eq(hits[3].data, "b")
  end)

  T.it("touching intervals (adjacent but not overlapping) are excluded", function()
    local tree = it.tree()
    tree:insert(1, 5, "a")   -- ends at 5
    tree:insert(6, 10, "b")  -- starts at 6 — does NOT overlap [1,5]
    -- query [5,5]: overlaps "a" (5 is in [1,5]), not "b" (6 > 5)
    local hits = sort_results(tree:overlap(5, 5))
    T.eq(#hits, 1)
    T.eq(hits[1].data, "a")
  end)

  T.it("overlap with interval touching at single point is included", function()
    local tree = it.tree()
    tree:insert(1, 10, "a")
    tree:insert(10, 20, "b")
    -- Both share point 10
    local hits = sort_results(tree:overlap(10, 10))
    T.eq(#hits, 2)
    T.eq(hits[1].data, "a")
    T.eq(hits[2].data, "b")
  end)

  T.it("no overlap returns empty", function()
    local tree = it.tree()
    tree:insert(1, 5, "a")
    tree:insert(20, 30, "b")
    local hits = tree:overlap(10, 15)
    T.eq(#hits, 0)
  end)
end)

-- ── Contained ────────────────────────────────────────────────────────────────

T.describe("interval_tree: contained", function()
  T.it("only fully-inside intervals returned", function()
    local tree = it.tree()
    tree:insert(5, 10, "inside")
    tree:insert(1, 10, "straddles_lo")
    tree:insert(5, 15, "straddles_hi")
    tree:insert(1, 20, "wraps")
    tree:insert(20, 30, "outside")
    local hits = sort_results(tree:contained(4, 12))
    T.eq(#hits, 1)
    T.eq(hits[1].data, "inside")
  end)

  T.it("exact boundary matches are contained", function()
    local tree = it.tree()
    tree:insert(5, 15, "exact")
    local hits = tree:contained(5, 15)
    T.eq(#hits, 1)
    T.eq(hits[1].data, "exact")
  end)

  T.it("returns empty when nothing is contained", function()
    local tree = it.tree()
    tree:insert(1, 100, "big")
    local hits = tree:contained(10, 20)
    T.eq(#hits, 0)
  end)
end)

-- ── Delete ────────────────────────────────────────────────────────────────────

T.describe("interval_tree: delete", function()
  T.it("removed interval no longer appears in stab", function()
    local tree = it.tree()
    tree:insert(10, 20, "a")
    tree:insert(15, 25, "b")
    local ok = tree:delete(10, 20)
    T.ok(ok)
    local hits = tree:stab(17)
    T.eq(#hits, 1)
    T.eq(hits[1].data, "b")
  end)

  T.it("delete non-existent returns false", function()
    local tree = it.tree()
    tree:insert(10, 20, "a")
    local ok = tree:delete(1, 2)
    T.ok(not ok)
  end)

  T.it("delete with data match removes correct entry", function()
    local tree = it.tree()
    tree:insert(10, 20, "a")
    tree:insert(10, 20, "b")
    local ok = tree:delete(10, 20, "a")
    T.ok(ok)
    local hits = sort_results(tree:stab(15))
    T.eq(#hits, 1)
    T.eq(hits[1].data, "b")
  end)

  T.it("delete with wrong data match returns false", function()
    local tree = it.tree()
    tree:insert(10, 20, "a")
    local ok = tree:delete(10, 20, "zzz")
    T.ok(not ok)
    T.eq(tree:len(), 1)
  end)
end)

-- ── len ──────────────────────────────────────────────────────────────────────

T.describe("interval_tree: len", function()
  T.it("correct after inserts", function()
    local tree = it.tree()
    T.eq(tree:len(), 0)
    tree:insert(1, 5)
    T.eq(tree:len(), 1)
    tree:insert(2, 6)
    T.eq(tree:len(), 2)
    tree:insert(3, 7)
    T.eq(tree:len(), 3)
  end)

  T.it("correct after delete", function()
    local tree = it.tree()
    tree:insert(1, 5, "a")
    tree:insert(2, 6, "b")
    tree:delete(1, 5)
    T.eq(tree:len(), 1)
  end)
end)

-- ── each ─────────────────────────────────────────────────────────────────────

T.describe("interval_tree: each", function()
  T.it("visits all intervals in sorted order", function()
    local tree = it.tree()
    tree:insert(30, 40, "d")
    tree:insert(10, 20, "a")
    tree:insert(5, 12, "c")
    tree:insert(15, 25, "b")
    local visited = {}
    tree:each(function(lo, hi, data)
      visited[#visited + 1] = { lo = lo, hi = hi, data = data }
    end)
    T.eq(#visited, 4)
    -- In-order by lo (then hi as tiebreak)
    T.eq(visited[1].lo, 5)
    T.eq(visited[2].lo, 10)
    T.eq(visited[3].lo, 15)
    T.eq(visited[4].lo, 30)
  end)

  T.it("each on empty tree calls fn zero times", function()
    local tree = it.tree()
    local count = 0
    tree:each(function() count = count + 1 end)
    T.eq(count, 0)
  end)
end)

-- ── Multiple intervals with same lo ──────────────────────────────────────────

T.describe("interval_tree: duplicate lo", function()
  T.it("all intervals with same lo are returned by stab", function()
    local tree = it.tree()
    tree:insert(10, 20, "a")
    tree:insert(10, 30, "b")
    tree:insert(10, 15, "c")
    local hits = sort_results(tree:stab(12))
    T.eq(#hits, 3)
  end)
end)

-- ── from_array ────────────────────────────────────────────────────────────────

T.describe("interval_tree: from_array", function()
  T.it("produces same results as individual inserts", function()
    local tree1 = it.tree()
    tree1:insert(10, 20, "a")
    tree1:insert(15, 25, "b")
    tree1:insert(5, 12, "c")
    tree1:insert(30, 40, "d")

    local tree2 = it.from_array({
      {10, 20, "a"}, {15, 25, "b"}, {5, 12, "c"}, {30, 40, "d"}
    })

    T.eq(tree1:len(), tree2:len())

    local hits1 = sort_results(tree1:stab(17))
    local hits2 = sort_results(tree2:stab(17))
    T.eq(#hits1, #hits2)
    for i = 1, #hits1 do
      T.eq(hits1[i].lo, hits2[i].lo)
      T.eq(hits1[i].hi, hits2[i].hi)
      T.eq(hits1[i].data, hits2[i].data)
    end
  end)

  T.it("from_array with empty array produces empty tree", function()
    local tree = it.from_array({})
    T.eq(tree:len(), 0)
    T.eq(#tree:stab(5), 0)
  end)
end)

-- ── nearest ──────────────────────────────────────────────────────────────────

T.describe("interval_tree: nearest", function()
  T.it("returns closest interval when point is outside all intervals", function()
    local tree = it.tree()
    tree:insert(10, 20, "a")
    tree:insert(30, 40, "b")
    -- point 25: distance to "a" is 5 (25-20), distance to "b" is 5 (30-25)
    -- either is valid; just check we get one
    local n = tree:nearest(25)
    T.ok(n ~= nil)
    T.ok(n.lo == 10 or n.lo == 30)
  end)

  T.it("returns interval containing the point (distance 0)", function()
    local tree = it.tree()
    tree:insert(10, 20, "a")
    tree:insert(30, 40, "b")
    local n = tree:nearest(15)
    T.ok(n ~= nil)
    T.eq(n.lo, 10) T.eq(n.hi, 20)
  end)

  T.it("returns nil for empty tree", function()
    local tree = it.tree()
    local n = tree:nearest(5)
    T.ok(n == nil)
  end)

  T.it("returns closest when point is to the left of all intervals", function()
    local tree = it.tree()
    tree:insert(10, 20, "a")
    tree:insert(30, 40, "b")
    local n = tree:nearest(1)
    T.ok(n ~= nil)
    T.eq(n.lo, 10)
  end)

  T.it("returns closest when point is to the right of all intervals", function()
    local tree = it.tree()
    tree:insert(10, 20, "a")
    tree:insert(30, 40, "b")
    local n = tree:nearest(100)
    T.ok(n ~= nil)
    T.eq(n.lo, 30)
  end)
end)

-- ── Large set ─────────────────────────────────────────────────────────────────

T.describe("interval_tree: large set", function()
  T.it("50 intervals: stab returns correct subset", function()
    local tree = it.tree()
    -- Insert 50 non-overlapping intervals [2k, 2k+1] for k=0..49
    -- Plus 50 that overlap zone [40,60]: [i, i+20] for i=30..79 step 1 → skip, just do targeted ones
    -- Use: 50 intervals of width 10 spaced 20 apart: [20*k, 20*k+10] for k=0..49
    -- Point 15 falls in [0,10] only
    for k = 0, 49 do
      tree:insert(20 * k, 20 * k + 10, k)
    end
    T.eq(tree:len(), 50)
    -- stab(5): only [0,10]
    local hits = tree:stab(5)
    T.eq(#hits, 1)
    T.eq(hits[1].lo, 0)
    -- stab(10): [0,10] boundary
    hits = tree:stab(10)
    T.eq(#hits, 1)
    T.eq(hits[1].lo, 0)
    -- stab(15): gap, no hits
    hits = tree:stab(15)
    T.eq(#hits, 0)
    -- stab(200): [200, 210]
    hits = tree:stab(205)
    T.eq(#hits, 1)
    T.eq(hits[1].lo, 200)
  end)
end)
