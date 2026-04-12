if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local st = require("lib.segment_tree")

T.describe("segment_tree basic (sum)", function()
  local arr = {3, 1, 4, 1, 5, 9, 2, 6}
  local tree = st.new(arr, st.sum)

  T.it("query(1, n) = total sum", function()
    T.eq(tree:query(1, 8), 31)
  end)

  T.it("partial range query", function()
    T.eq(tree:query(2, 5), 11)  -- 1+4+1+5
  end)

  T.it("single element query", function()
    T.eq(tree:query(4, 4), 1)
    T.eq(tree:query(6, 6), 9)
  end)

  T.it("len() is correct", function()
    T.eq(tree:len(), 8)
  end)

  T.it("get(i) returns element", function()
    T.eq(tree:get(1), 3)
    T.eq(tree:get(6), 9)
  end)

  T.it("point update reflects in query", function()
    tree:update(3, 10)
    T.eq(tree:query(1, 8), 37)  -- 31 - 4 + 10
    T.eq(tree:query(3, 3), 10)
    T.eq(tree:query(2, 4), 12)  -- 1+10+1
  end)

  T.it("multiple updates still correct", function()
    -- State from previous test: index 3 was set to 10, so {3,1,10,1,5,9,2,6}
    tree:update(1, 0)
    tree:update(8, 0)
    -- Now {0,1,10,1,5,9,2,0}, sum = 28
    T.eq(tree:query(1, 8), 28)
  end)
end)

T.describe("segment_tree basic (max)", function()
  local arr = {3, 1, 4, 1, 5, 9, 2, 6}
  local tree = st.new(arr, st.max)

  T.it("query returns correct max", function()
    T.eq(tree:query(1, 8), 9)
    T.eq(tree:query(2, 5), 5)  -- max of {1,4,1,5}
    T.eq(tree:query(1, 3), 4)
  end)

  T.it("single element max", function()
    T.eq(tree:query(6, 6), 9)
    T.eq(tree:query(2, 2), 1)
  end)

  T.it("point update changes max", function()
    tree:update(3, 10)
    T.eq(tree:query(1, 8), 10)
    T.eq(tree:query(1, 2), 3)
  end)
end)

T.describe("segment_tree basic (min)", function()
  local arr = {3, 1, 4, 1, 5, 9, 2, 6}
  local tree = st.new(arr, st.min)

  T.it("M.min helper works", function()
    T.eq(tree:query(1, 8), 1)
    T.eq(tree:query(3, 7), 1)
    T.eq(tree:query(5, 8), 2)
  end)

  T.it("M.max helper works via max tree", function()
    local t2 = st.new(arr, st.max)
    T.eq(t2:query(1, 8), 9)
  end)
end)

T.describe("segment_tree lazy propagation", function()
  -- update_fn receives (aggregate_val, tag, count) where count = number of elements
  -- covered by the node. For sum+add, the aggregate increases by tag*count.
  local function sum_update(val, add, count) return val + add * count end

  T.it("range_update: all elements in range affected", function()
    local tree = st.new_lazy(
      {1, 2, 3, 4, 5},
      {
        combine = st.sum,
        update = sum_update,
        compose = st.sum,
        identity = 0,
      }
    )
    tree:range_update(2, 4, 10)
    -- elements become {1, 12, 13, 14, 5}
    T.eq(tree:query(1, 5), 45)
    T.eq(tree:query(2, 4), 39)
    T.eq(tree:query(1, 1), 1)
    T.eq(tree:query(5, 5), 5)
  end)

  T.it("multiple range updates compose correctly", function()
    local tree = st.new_lazy(
      {1, 2, 3, 4, 5},
      {
        combine = st.sum,
        update = sum_update,
        compose = st.sum,
        identity = 0,
      }
    )
    tree:range_update(1, 3, 5)   -- {6, 7, 8, 4, 5}
    tree:range_update(2, 5, 3)   -- {6, 10, 11, 7, 8}
    T.eq(tree:query(1, 5), 42)
    T.eq(tree:query(1, 1), 6)
    T.eq(tree:query(2, 2), 10)
    T.eq(tree:query(5, 5), 8)
  end)

  T.it("range update on single element", function()
    local tree = st.new_lazy(
      {10, 20, 30},
      {
        combine = st.max,
        -- for max tree, adding a constant to all elements: max shifts uniformly
        update = function(val, add, _count) return val + add end,
        compose = st.sum,
        identity = 0,
      }
    )
    tree:range_update(2, 2, 15)
    T.eq(tree:query(1, 3), 35)  -- max of {10, 35, 30}
    T.eq(tree:query(1, 1), 10)
  end)
end)

T.describe("segment_tree persistent", function()
  local arr = {1, 2, 3, 4, 5}

  T.it("original version unchanged after update", function()
    local v0 = st.persistent(arr, st.sum)
    local v1 = v0:update(3, 10)
    T.eq(v0:query(1, 5), 15)  -- original
    T.eq(v1:query(1, 5), 22)  -- 15 - 3 + 10
  end)

  T.it("two branches are independent", function()
    local v0 = st.persistent(arr, st.sum)
    local v1 = v0:update(3, 10)
    local v2 = v0:update(1, 20)
    T.eq(v0:query(1, 5), 15)
    T.eq(v1:query(1, 5), 22)  -- 3->10
    T.eq(v2:query(1, 5), 34)  -- 1->20
  end)

  T.it("query on subrange is correct", function()
    local v0 = st.persistent(arr, st.max)
    local v1 = v0:update(2, 100)
    T.eq(v0:query(1, 3), 3)
    T.eq(v1:query(1, 3), 100)
    T.eq(v1:query(4, 5), 5)
  end)

  T.it("len() works on persistent tree", function()
    local v0 = st.persistent(arr, st.sum)
    local v1 = v0:update(1, 99)
    T.eq(v0:len(), 5)
    T.eq(v1:len(), 5)
  end)
end)

T.describe("segment_tree sparse", function()
  T.it("point update and range query on huge range", function()
    local sparse = st.sparse(1, 10^9, st.sum)
    sparse:update(500000000, 42)
    T.eq(sparse:query(1, 10^9), 42)
  end)

  T.it("multiple sparse updates", function()
    local sparse = st.sparse(1, 10^9, st.sum)
    sparse:update(1, 10)
    sparse:update(500000000, 42)
    sparse:update(10^9, 7)
    T.eq(sparse:query(1, 10^9), 59)
    T.eq(sparse:query(1, 1), 10)
    T.eq(sparse:query(10^9, 10^9), 7)
    T.eq(sparse:query(2, 10^9 - 1), 42)
  end)

  T.it("query on empty sparse tree returns nil", function()
    local sparse = st.sparse(1, 1000, st.sum)
    T.eq(sparse:query(1, 1000), nil)
  end)
end)
