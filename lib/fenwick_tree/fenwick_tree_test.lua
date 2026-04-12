-- lib/fenwick_tree/fenwick_tree_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local ft = require("lib.fenwick_tree")

T.describe("fenwick_tree", function()

  -- -------------------------------------------------------------------------
  T.it("new: len correct, all zeros", function()
    local t = ft.new(8)
    T.eq(t:len(), 8)
    T.eq(t:prefix(8), 0)
    for i = 1, 8 do
      T.eq(t:get(i), 0, "index " .. i .. " should be 0")
    end
  end)

  -- -------------------------------------------------------------------------
  T.it("update: prefix reflects change", function()
    local t = ft.new(8)
    t:update(3, 5)
    T.eq(t:prefix(3), 5)
    T.eq(t:prefix(2), 0)
    T.eq(t:prefix(8), 5)
    t:update(3, 2)
    T.eq(t:prefix(3), 7)
    T.eq(t:get(3), 7)
  end)

  -- -------------------------------------------------------------------------
  T.it("set: set index to value", function()
    local t = ft.new(8)
    t:update(3, 5)
    t:set(3, 10)
    T.eq(t:get(3), 10)
    T.eq(t:prefix(3), 10)
    -- Other indices unaffected
    T.eq(t:prefix(2), 0)
  end)

  -- -------------------------------------------------------------------------
  T.it("get: point value correct after updates", function()
    local t = ft.new(8)
    t:update(1, 3)
    t:update(2, 1)
    t:update(3, 4)
    t:update(4, 1)
    T.eq(t:get(1), 3)
    T.eq(t:get(2), 1)
    T.eq(t:get(3), 4)
    T.eq(t:get(4), 1)
  end)

  -- -------------------------------------------------------------------------
  T.it("query: range sum [l..r]", function()
    local t = ft.new(8)
    t:update(1, 3)
    t:update(2, 1)
    t:update(3, 4)
    t:update(4, 1)
    t:update(5, 5)
    t:update(6, 9)
    t:update(7, 2)
    t:update(8, 6)
    T.eq(t:query(1, 8), 31)
    T.eq(t:query(3, 6), 4 + 1 + 5 + 9)
    T.eq(t:query(2, 4), 1 + 4 + 1)
    T.eq(t:query(5, 5), 5)
  end)

  -- -------------------------------------------------------------------------
  T.it("from_array: prefix(n) = total sum", function()
    local arr = {3, 1, 4, 1, 5, 9, 2, 6}
    local t = ft.from_array(arr)
    local total = 0
    for _, v in ipairs(arr) do total = total + v end
    T.eq(t:prefix(#arr), total)
    T.eq(t:prefix(3), 3 + 1 + 4)
  end)

  -- -------------------------------------------------------------------------
  T.it("from_array: same result as incremental build", function()
    local arr = {3, 1, 4, 1, 5, 9, 2, 6}
    local incremental = ft.new(#arr)
    for i, v in ipairs(arr) do incremental:update(i, v) end
    local bulk = ft.from_array(arr)
    for i = 1, #arr do
      T.eq(bulk:prefix(i), incremental:prefix(i), "prefix(" .. i .. ") mismatch")
    end
  end)

  -- -------------------------------------------------------------------------
  T.it("to_array: recovers original values", function()
    local arr = {3, 1, 4, 1, 5, 9, 2, 6}
    local t = ft.from_array(arr)
    local out = t:to_array()
    for i, v in ipairs(arr) do
      T.eq(out[i], v, "to_array index " .. i)
    end
  end)

  -- -------------------------------------------------------------------------
  T.it("to_array: recovers after updates", function()
    local t = ft.new(5)
    t:update(1, 10)
    t:update(3, 20)
    t:update(5, 30)
    local out = t:to_array()
    T.eq(out[1], 10)
    T.eq(out[2], 0)
    T.eq(out[3], 20)
    T.eq(out[4], 0)
    T.eq(out[5], 30)
  end)

  -- -------------------------------------------------------------------------
  T.it("find_kth: binary lifting finds correct index", function()
    local arr = {1, 2, 3, 4, 5}
    local t = ft.from_array(arr)
    -- prefix sums: 1, 3, 6, 10, 15
    T.eq(t:find_kth(1), 1)   -- prefix(1) = 1 >= 1
    T.eq(t:find_kth(2), 2)   -- prefix(2) = 3 >= 2, prefix(1) = 1 < 2
    T.eq(t:find_kth(3), 2)   -- prefix(2) = 3 >= 3
    T.eq(t:find_kth(4), 3)   -- prefix(3) = 6 >= 4
    T.eq(t:find_kth(6), 3)   -- prefix(3) = 6 >= 6
    T.eq(t:find_kth(7), 4)   -- prefix(4) = 10 >= 7
    T.eq(t:find_kth(15), 5)  -- prefix(5) = 15 >= 15
    T.eq(t:find_kth(16), nil) -- beyond total
  end)

  -- -------------------------------------------------------------------------
  T.it("sequence of updates and queries", function()
    local t = ft.new(10)
    t:update(1, 5)
    t:update(5, 3)
    t:update(10, 7)
    T.eq(t:query(1, 10), 15)
    T.eq(t:query(2, 9), 3)
    t:update(5, -3)
    T.eq(t:query(1, 10), 12)
    T.eq(t:get(5), 0)
    t:set(3, 8)
    T.eq(t:get(3), 8)
    T.eq(t:query(1, 10), 20)
  end)

  -- -------------------------------------------------------------------------
  T.it("2D: update and prefix", function()
    local t = ft.new_2d(4, 4)
    t:update(1, 1, 3)
    t:update(2, 2, 5)
    t:update(3, 3, 7)
    T.eq(t:prefix(1, 1), 3)
    T.eq(t:prefix(2, 2), 3 + 5)
    T.eq(t:prefix(3, 3), 3 + 5 + 7)
    T.eq(t:prefix(4, 4), 3 + 5 + 7)
  end)

  -- -------------------------------------------------------------------------
  T.it("2D: query rectangle sum", function()
    local t = ft.new_2d(4, 4)
    -- Fill a 2x2 block
    t:update(1, 1, 1)
    t:update(1, 2, 2)
    t:update(2, 1, 3)
    t:update(2, 2, 4)
    t:update(3, 3, 9)
    -- Rectangle (1,1)..(2,2) = 1+2+3+4 = 10
    T.eq(t:query(1, 1, 2, 2), 10)
    -- Rectangle (2,2)..(3,3) = 4+9 = 13
    T.eq(t:query(2, 2, 3, 3), 13)
    -- Full rectangle (1,1)..(4,4) = 10+9 = 19
    T.eq(t:query(1, 1, 4, 4), 19)
  end)

  -- -------------------------------------------------------------------------
  T.it("new_op: max prefix query", function()
    local t = ft.new_op(8, {
      combine      = math.max,
      identity     = -math.huge,
      point_update = math.max,
    })
    t:update(3, 10)
    t:update(1, 5)
    t:update(6, 8)
    T.eq(t:prefix(1), 5)
    T.eq(t:prefix(3), 10)
    T.eq(t:prefix(6), 10)
    T.eq(t:prefix(8), 10)
    -- Update index 3 with a larger value
    t:update(3, 15)
    T.eq(t:prefix(3), 15)
    T.eq(t:prefix(8), 15)
    -- Update index 7 with the largest
    t:update(7, 20)
    T.eq(t:prefix(6), 15)
    T.eq(t:prefix(7), 20)
  end)

  -- -------------------------------------------------------------------------
  T.it("new_range: range update + point query", function()
    local t = ft.new_range(8)
    t:range_update(2, 5, 3)
    T.eq(t:point_query(1), 0)
    T.eq(t:point_query(2), 3)
    T.eq(t:point_query(4), 3)
    T.eq(t:point_query(5), 3)
    T.eq(t:point_query(6), 0)
    -- Second update overlapping
    t:range_update(4, 7, 2)
    T.eq(t:point_query(3), 3)
    T.eq(t:point_query(4), 5)  -- 3+2
    T.eq(t:point_query(6), 2)
    T.eq(t:point_query(8), 0)
    T.eq(t:len(), 8)
  end)

  -- -------------------------------------------------------------------------
  T.it("new_range_range: range update + range query", function()
    local t = ft.new_range_range(8)
    t:range_update(2, 5, 3)
    -- sum of [2..5] = 3*4 = 12
    T.eq(t:range_query(2, 5), 12)
    -- sum of [1..8] = 3*4 = 12
    T.eq(t:range_query(1, 8), 12)
    -- sum of [1..3] = 3*2 = 6
    T.eq(t:range_query(1, 3), 6)
    -- sum of [4..8] = 3*2 = 6
    T.eq(t:range_query(4, 8), 6)
    -- Second update
    t:range_update(4, 7, 2)
    -- [2..5]: indices 2,3 have +3; indices 4,5 have +3+2=5
    -- sum = 3+3+5+5 = 16
    T.eq(t:range_query(2, 5), 16)
    -- [1..8]: 0+3+3+5+5+2+2+0 = 20
    T.eq(t:range_query(1, 8), 20)
    T.eq(t:len(), 8)
  end)

end)
