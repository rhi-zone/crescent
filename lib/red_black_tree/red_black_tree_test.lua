if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local RBT = require("lib.red_black_tree")

T.describe("red_black_tree", function()

  T.describe("empty tree", function()
    T.it("size is 0", function()
      local t = RBT.new()
      T.eq(t:size(), 0)
    end)

    T.it("get returns nil", function()
      local t = RBT.new()
      T.eq(t:get(1), nil)
      T.eq(t:get("x"), nil)
    end)

    T.it("has returns false", function()
      local t = RBT.new()
      T.eq(t:has(1), false)
    end)

    T.it("min and max return nil", function()
      local t = RBT.new()
      local k, v = t:min()
      T.eq(k, nil)
      T.eq(v, nil)
      local k2, v2 = t:max()
      T.eq(k2, nil)
      T.eq(v2, nil)
    end)

    T.it("pairs returns empty iterator", function()
      local t = RBT.new()
      local count = 0
      for k, v in t:pairs() do
        count = count + 1
      end
      T.eq(count, 0)
    end)

    T.it("delete returns false", function()
      local t = RBT.new()
      T.eq(t:delete(1), false)
    end)

    T.it("verify passes", function()
      local t = RBT.new()
      local ok, err = t:verify()
      T.ok(ok, err)
    end)

    T.it("to_array returns empty table", function()
      local t = RBT.new()
      local arr = t:to_array()
      T.eq(#arr, 0)
    end)
  end)

  T.describe("single insert", function()
    T.it("get returns value", function()
      local t = RBT.new()
      t:insert(5, "five")
      T.eq(t:get(5), "five")
    end)

    T.it("has returns true", function()
      local t = RBT.new()
      t:insert(5, "five")
      T.ok(t:has(5))
    end)

    T.it("size is 1", function()
      local t = RBT.new()
      t:insert(5, "five")
      T.eq(t:size(), 1)
    end)

    T.it("verify passes", function()
      local t = RBT.new()
      t:insert(5, "five")
      local ok, err = t:verify()
      T.ok(ok, err)
    end)

    T.it("default value is true", function()
      local t = RBT.new()
      t:insert(42)
      T.eq(t:get(42), true)
    end)
  end)

  T.describe("sorted order inserts (worst case for unbalanced BST)", function()
    T.it("verify passes after inserting 1..20 in order", function()
      local t = RBT.new()
      for i = 1, 20 do
        t:insert(i, i)
      end
      T.eq(t:size(), 20)
      local ok, err = t:verify()
      T.ok(ok, err)
    end)
  end)

  T.describe("reverse order inserts", function()
    T.it("verify passes after inserting 20..1 in reverse", function()
      local t = RBT.new()
      for i = 20, 1, -1 do
        t:insert(i, i)
      end
      T.eq(t:size(), 20)
      local ok, err = t:verify()
      T.ok(ok, err)
    end)
  end)

  T.describe("arbitrary order inserts", function()
    T.it("verify passes for 1,5,3,7,2,6,4,8", function()
      local t = RBT.new()
      local keys = {1, 5, 3, 7, 2, 6, 4, 8}
      for _, k in ipairs(keys) do
        t:insert(k, k * 10)
      end
      T.eq(t:size(), 8)
      local ok, err = t:verify()
      T.ok(ok, err)
      -- Check all values are correct
      for _, k in ipairs(keys) do
        T.eq(t:get(k), k * 10)
      end
    end)
  end)

  T.describe("update (insert same key twice)", function()
    T.it("get returns new value", function()
      local t = RBT.new()
      t:insert(10, "first")
      t:insert(10, "second")
      T.eq(t:get(10), "second")
      T.eq(t:size(), 1)
    end)

    T.it("verify passes after update", function()
      local t = RBT.new()
      t:insert(10, "first")
      t:insert(10, "second")
      local ok, err = t:verify()
      T.ok(ok, err)
    end)
  end)

  T.describe("delete", function()
    T.it("delete leaf node", function()
      local t = RBT.new()
      t:insert(5, "five")
      t:insert(3, "three")
      t:insert(7, "seven")
      -- 3 and 7 are leaves
      T.ok(t:delete(3))
      T.eq(t:size(), 2)
      T.eq(t:get(3), nil)
      local ok, err = t:verify()
      T.ok(ok, err)
    end)

    T.it("delete node with one child", function()
      local t = RBT.new()
      -- Build a shape where a node has one child
      t:insert(10)
      t:insert(5)
      t:insert(15)
      t:insert(3)
      -- 5 has one child (3); deleting 5 should promote 3
      T.ok(t:delete(5))
      T.eq(t:size(), 3)
      T.eq(t:get(5), nil)
      T.ok(t:has(3))
      local ok, err = t:verify()
      T.ok(ok, err)
    end)

    T.it("delete node with two children", function()
      local t = RBT.new()
      t:insert(10)
      t:insert(5)
      t:insert(15)
      t:insert(3)
      t:insert(7)
      -- 5 has two children (3 and 7)
      T.ok(t:delete(5))
      T.eq(t:size(), 4)
      T.eq(t:get(5), nil)
      T.ok(t:has(3))
      T.ok(t:has(7))
      local ok, err = t:verify()
      T.ok(ok, err)
    end)

    T.it("delete returns false for missing key", function()
      local t = RBT.new()
      t:insert(1)
      T.eq(t:delete(99), false)
      T.eq(t:size(), 1)
    end)

    T.it("delete all nodes one by one, verify at each step", function()
      local t = RBT.new()
      local keys = {5, 3, 7, 1, 4, 6, 8, 2}
      for _, k in ipairs(keys) do
        t:insert(k)
      end
      -- Delete in a specific order and verify each time
      for _, k in ipairs(keys) do
        T.ok(t:delete(k))
        local ok, err = t:verify()
        T.ok(ok, err)
      end
      T.eq(t:size(), 0)
    end)
  end)

  T.describe("min and max", function()
    T.it("correct after inserts", function()
      local t = RBT.new()
      local keys = {5, 3, 7, 1, 9, 4}
      for _, k in ipairs(keys) do
        t:insert(k, k)
      end
      local mink, minv = t:min()
      T.eq(mink, 1)
      T.eq(minv, 1)
      local maxk, maxv = t:max()
      T.eq(maxk, 9)
      T.eq(maxv, 9)
    end)

    T.it("correct after deletes", function()
      local t = RBT.new()
      for i = 1, 5 do t:insert(i, i) end
      t:delete(1)
      t:delete(5)
      local mink = t:min()
      T.eq(mink, 2)
      local maxk = t:max()
      T.eq(maxk, 4)
    end)
  end)

  T.describe("pairs() ordered iteration", function()
    T.it("returns sorted order", function()
      local t = RBT.new()
      local inserted = {5, 3, 7, 1, 4, 6, 8, 2}
      for _, k in ipairs(inserted) do
        t:insert(k, k * 2)
      end
      local result = {}
      for k, v in t:pairs() do
        result[#result + 1] = {k, v}
      end
      T.eq(#result, 8)
      for i = 1, #result - 1 do
        T.ok(result[i][1] < result[i+1][1])
      end
      -- Check values
      for _, pair in ipairs(result) do
        T.eq(pair[2], pair[1] * 2)
      end
    end)
  end)

  T.describe("range()", function()
    T.it("returns correct subset", function()
      local t = RBT.new()
      for i = 1, 10 do t:insert(i, i) end
      local result = {}
      for k, v in t:range(3, 7) do
        result[#result + 1] = k
      end
      T.eq(#result, 5)
      T.eq(result[1], 3)
      T.eq(result[5], 7)
    end)

    T.it("range with no matches", function()
      local t = RBT.new()
      for i = 1, 5 do t:insert(i) end
      local count = 0
      for k, v in t:range(10, 20) do
        count = count + 1
      end
      T.eq(count, 0)
    end)

    T.it("range spanning full tree", function()
      local t = RBT.new()
      for i = 1, 5 do t:insert(i, i) end
      local result = {}
      for k, v in t:range(1, 5) do
        result[#result + 1] = k
      end
      T.eq(#result, 5)
    end)

    T.it("range single element", function()
      local t = RBT.new()
      for i = 1, 5 do t:insert(i, i) end
      local result = {}
      for k, v in t:range(3, 3) do
        result[#result + 1] = {k, v}
      end
      T.eq(#result, 1)
      T.eq(result[1][1], 3)
    end)
  end)

  T.describe("floor and ceiling", function()
    T.it("floor exact match", function()
      local t = RBT.new()
      for _, k in ipairs({1, 3, 5, 7, 9}) do t:insert(k, k) end
      local fk, fv = t:floor(5)
      T.eq(fk, 5)
      T.eq(fv, 5)
    end)

    T.it("floor no exact match", function()
      local t = RBT.new()
      for _, k in ipairs({1, 3, 5, 7, 9}) do t:insert(k, k) end
      local fk = t:floor(4)
      T.eq(fk, 3)
    end)

    T.it("floor below minimum returns nil", function()
      local t = RBT.new()
      for _, k in ipairs({3, 5, 7}) do t:insert(k, k) end
      local fk, fv = t:floor(1)
      T.eq(fk, nil)
      T.eq(fv, nil)
    end)

    T.it("ceiling exact match", function()
      local t = RBT.new()
      for _, k in ipairs({1, 3, 5, 7, 9}) do t:insert(k, k) end
      local ck, cv = t:ceiling(5)
      T.eq(ck, 5)
      T.eq(cv, 5)
    end)

    T.it("ceiling no exact match", function()
      local t = RBT.new()
      for _, k in ipairs({1, 3, 5, 7, 9}) do t:insert(k, k) end
      local ck = t:ceiling(4)
      T.eq(ck, 5)
    end)

    T.it("ceiling above maximum returns nil", function()
      local t = RBT.new()
      for _, k in ipairs({1, 3, 5}) do t:insert(k, k) end
      local ck, cv = t:ceiling(10)
      T.eq(ck, nil)
      T.eq(cv, nil)
    end)
  end)

  T.describe("to_array", function()
    T.it("returns sorted pairs", function()
      local t = RBT.new()
      local keys = {4, 2, 6, 1, 3, 5, 7}
      for _, k in ipairs(keys) do t:insert(k, k * 10) end
      local arr = t:to_array()
      T.eq(#arr, 7)
      for i = 1, 7 do
        T.eq(arr[i][1], i)
        T.eq(arr[i][2], i * 10)
      end
    end)
  end)

  T.describe("large test", function()
    T.it("insert 1..100 shuffled, verify, delete evens, verify", function()
      -- Fisher-Yates shuffle with fixed seed
      local keys = {}
      for i = 1, 100 do keys[i] = i end
      local seed = 12345
      local function lcg()
        seed = (seed * 1103515245 + 12345) % (2^31)
        return seed
      end
      for i = 100, 2, -1 do
        local j = (lcg() % i) + 1
        keys[i], keys[j] = keys[j], keys[i]
      end

      local t = RBT.new()
      for _, k in ipairs(keys) do
        t:insert(k, k)
      end
      T.eq(t:size(), 100)
      local ok, err = t:verify()
      T.ok(ok, err)

      -- Verify sorted order
      local arr = t:to_array()
      T.eq(#arr, 100)
      for i = 1, 100 do
        T.eq(arr[i][1], i)
      end

      -- Delete evens
      for i = 2, 100, 2 do
        T.ok(t:delete(i))
      end
      T.eq(t:size(), 50)
      local ok2, err2 = t:verify()
      T.ok(ok2, err2)

      -- Only odds remain
      for i = 1, 100 do
        if i % 2 == 1 then
          T.ok(t:has(i))
        else
          T.eq(t:has(i), false)
        end
      end
    end)
  end)

  T.describe("custom comparator", function()
    T.it("reverse order comparator", function()
      local t = RBT.new({ cmp = function(a, b) return a > b end })
      for _, k in ipairs({3, 1, 4, 1, 5, 9, 2, 6}) do
        t:insert(k, k)
      end
      -- With > comparator, "min" in tree order is actually the largest number
      local mink = t:min()
      T.eq(mink, 9)
      local maxk = t:max()
      T.eq(maxk, 1)
      local ok, err = t:verify()
      T.ok(ok, err)
    end)

    T.it("string length comparator", function()
      local t = RBT.new({ cmp = function(a, b) return #a < #b end })
      t:insert("a", 1)
      t:insert("bb", 2)
      t:insert("ccc", 3)
      t:insert("dddd", 4)
      T.eq(t:size(), 4)
      local ok, err = t:verify()
      T.ok(ok, err)
      -- min by length
      local mink = t:min()
      T.eq(mink, "a")
      local maxk = t:max()
      T.eq(maxk, "dddd")
    end)
  end)

  T.describe("verify() detects violations", function()
    T.it("manually corrupted root color is detected", function()
      local t = RBT.new()
      t:insert(5)
      -- Force root to red (violation of invariant 2)
      t._root.color = 0 -- RED
      local ok, err = t:verify()
      T.eq(ok, nil)
      T.ok(type(err) == "string")
    end)
  end)

end)
