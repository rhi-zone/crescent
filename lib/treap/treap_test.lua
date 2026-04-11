-- lib/treap/treap_test.lua
-- Tests for lib/treap/init.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local treap = require("lib.treap")

-- ---------------------------------------------------------------------------
-- Basic insert / get
-- ---------------------------------------------------------------------------

T.describe("insert and get", function()
  T.it("single key", function()
    local t = treap.new()
    t:insert("a", 1)
    T.eq(t:get("a"), 1)
  end)

  T.it("multiple keys", function()
    local t = treap.new()
    t:insert("b", 2)
    t:insert("a", 1)
    t:insert("c", 3)
    T.eq(t:get("a"), 1)
    T.eq(t:get("b"), 2)
    T.eq(t:get("c"), 3)
  end)

  T.it("missing key returns nil", function()
    local t = treap.new()
    t:insert("x", 10)
    T.eq(t:get("y"), nil)
  end)

  T.it("duplicate key updates value", function()
    local t = treap.new()
    t:insert("k", 1)
    t:insert("k", 99)
    T.eq(t:get("k"), 99)
    T.eq(t:size(), 1)  -- no duplicate
  end)
end)

-- ---------------------------------------------------------------------------
-- Contains
-- ---------------------------------------------------------------------------

T.describe("contains", function()
  T.it("present key", function()
    local t = treap.new()
    t:insert(5, "five")
    T.eq(t:contains(5), true)
  end)

  T.it("absent key", function()
    local t = treap.new()
    t:insert(5, "five")
    T.eq(t:contains(6), false)
  end)

  T.it("empty treap", function()
    local t = treap.new()
    T.eq(t:contains(1), false)
  end)
end)

-- ---------------------------------------------------------------------------
-- Remove
-- ---------------------------------------------------------------------------

T.describe("remove", function()
  T.it("remove present key", function()
    local t = treap.new()
    t:insert(1, "a")
    t:insert(2, "b")
    t:insert(3, "c")
    T.eq(t:remove(2), true)
    T.eq(t:get(2), nil)
    T.eq(t:size(), 2)
  end)

  T.it("remove absent key returns false", function()
    local t = treap.new()
    t:insert(1, "a")
    T.eq(t:remove(9), false)
    T.eq(t:size(), 1)
  end)

  T.it("remove then reinsert", function()
    local t = treap.new()
    t:insert(7, "seven")
    T.eq(t:remove(7), true)
    T.eq(t:size(), 0)
    t:insert(7, "back")
    T.eq(t:get(7), "back")
    T.eq(t:size(), 1)
  end)

  T.it("remove all elements", function()
    local t = treap.new()
    for i = 1, 5 do t:insert(i, i) end
    for i = 1, 5 do
      T.eq(t:remove(i), true)
    end
    T.eq(t:size(), 0)
    T.eq(t:get(1), nil)
  end)

  T.it("remove root (only element)", function()
    local t = treap.new()
    t:insert(42, "x")
    T.eq(t:remove(42), true)
    T.eq(t:size(), 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- Size
-- ---------------------------------------------------------------------------

T.describe("size", function()
  T.it("empty is 0", function()
    T.eq(treap.new():size(), 0)
  end)

  T.it("tracks inserts", function()
    local t = treap.new()
    for i = 1, 10 do
      t:insert(i, i)
      T.eq(t:size(), i)
    end
  end)

  T.it("duplicate insert does not increase size", function()
    local t = treap.new()
    t:insert(1, "a")
    t:insert(1, "b")
    T.eq(t:size(), 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- Min / Max
-- ---------------------------------------------------------------------------

T.describe("min and max", function()
  T.it("empty returns nil", function()
    local t = treap.new()
    local k, v = t:min()
    T.eq(k, nil)
    T.eq(v, nil)
    k, v = t:max()
    T.eq(k, nil)
    T.eq(v, nil)
  end)

  T.it("single element", function()
    local t = treap.new()
    t:insert(5, "five")
    local k, v = t:min()
    T.eq(k, 5); T.eq(v, "five")
    k, v = t:max()
    T.eq(k, 5); T.eq(v, "five")
  end)

  T.it("multiple elements", function()
    local t = treap.new()
    for _, x in ipairs({3, 1, 4, 1, 5, 9, 2, 6}) do
      t:insert(x, x * 10)
    end
    local kmin, vmin = t:min()
    T.eq(kmin, 1); T.eq(vmin, 10)
    local kmax, vmax = t:max()
    T.eq(kmax, 9); T.eq(vmax, 90)
  end)
end)

-- ---------------------------------------------------------------------------
-- Floor / Ceil
-- ---------------------------------------------------------------------------

T.describe("floor and ceil", function()
  local function make()
    local t = treap.new()
    for _, x in ipairs({2, 4, 6, 8, 10}) do t:insert(x, x) end
    return t
  end

  T.it("floor exact match", function()
    local t = make()
    local k, v = t:floor(6)
    T.eq(k, 6); T.eq(v, 6)
  end)

  T.it("floor between values", function()
    local t = make()
    local k, v = t:floor(5)
    T.eq(k, 4); T.eq(v, 4)
  end)

  T.it("floor below all keys", function()
    local t = make()
    local k, v = t:floor(1)
    T.eq(k, nil); T.eq(v, nil)
  end)

  T.it("floor above all keys", function()
    local t = make()
    local k, v = t:floor(11)
    T.eq(k, 10); T.eq(v, 10)
  end)

  T.it("ceil exact match", function()
    local t = make()
    local k, v = t:ceil(6)
    T.eq(k, 6); T.eq(v, 6)
  end)

  T.it("ceil between values", function()
    local t = make()
    local k, v = t:ceil(5)
    T.eq(k, 6); T.eq(v, 6)
  end)

  T.it("ceil above all keys", function()
    local t = make()
    local k, v = t:ceil(11)
    T.eq(k, nil); T.eq(v, nil)
  end)

  T.it("ceil below all keys", function()
    local t = make()
    local k, v = t:ceil(1)
    T.eq(k, 2); T.eq(v, 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- Pred / Succ
-- ---------------------------------------------------------------------------

T.describe("pred and succ", function()
  local function make()
    local t = treap.new()
    for _, x in ipairs({10, 20, 30, 40, 50}) do t:insert(x, x) end
    return t
  end

  T.it("pred of existing key", function()
    local t = make()
    local k, v = t:pred(30)
    T.eq(k, 20); T.eq(v, 20)
  end)

  T.it("pred of min key is nil", function()
    local t = make()
    local k, v = t:pred(10)
    T.eq(k, nil); T.eq(v, nil)
  end)

  T.it("pred of non-existing key", function()
    local t = make()
    local k, v = t:pred(25)
    T.eq(k, 20); T.eq(v, 20)
  end)

  T.it("succ of existing key", function()
    local t = make()
    local k, v = t:succ(30)
    T.eq(k, 40); T.eq(v, 40)
  end)

  T.it("succ of max key is nil", function()
    local t = make()
    local k, v = t:succ(50)
    T.eq(k, nil); T.eq(v, nil)
  end)

  T.it("succ of non-existing key", function()
    local t = make()
    local k, v = t:succ(25)
    T.eq(k, 30); T.eq(v, 30)
  end)
end)

-- ---------------------------------------------------------------------------
-- each (in-order traversal)
-- ---------------------------------------------------------------------------

T.describe("each", function()
  T.it("empty treap", function()
    local count = 0
    treap.new():each(function() count = count + 1 end)
    T.eq(count, 0)
  end)

  T.it("traversal is sorted", function()
    local t = treap.new()
    local keys = {5, 3, 8, 1, 4, 7, 9, 2, 6}
    for _, k in ipairs(keys) do t:insert(k, k) end
    local got = {}
    t:each(function(k, v)
      got[#got + 1] = k
      T.eq(v, k)  -- value == key in our test
    end)
    T.eq(#got, #keys)
    for i = 2, #got do
      T.ok(got[i - 1] < got[i], "out of order at index " .. i)
    end
    T.eq(got[1], 1)
    T.eq(got[#got], 9)
  end)
end)

-- ---------------------------------------------------------------------------
-- range
-- ---------------------------------------------------------------------------

T.describe("range", function()
  T.it("range covering all", function()
    local t = treap.new()
    for i = 1, 5 do t:insert(i, i) end
    local got = {}
    t:range(1, 5, function(k, v) got[#got + 1] = k end)
    T.eq(#got, 5)
  end)

  T.it("range subset", function()
    local t = treap.new()
    for i = 1, 10 do t:insert(i, i) end
    local got = {}
    t:range(3, 7, function(k, v) got[#got + 1] = k end)
    T.eq(#got, 5)
    T.eq(got[1], 3); T.eq(got[#got], 7)
  end)

  T.it("range single element", function()
    local t = treap.new()
    for i = 1, 5 do t:insert(i, i) end
    local got = {}
    t:range(3, 3, function(k, v) got[#got + 1] = k end)
    T.eq(#got, 1); T.eq(got[1], 3)
  end)

  T.it("range empty result", function()
    local t = treap.new()
    for i = 1, 5 do t:insert(i, i) end
    local count = 0
    t:range(10, 20, function() count = count + 1 end)
    T.eq(count, 0)
  end)

  T.it("range result is sorted", function()
    local t = treap.new()
    for _, k in ipairs({7, 2, 5, 1, 9, 3, 8, 4, 6}) do t:insert(k, k) end
    local got = {}
    t:range(2, 7, function(k) got[#got + 1] = k end)
    for i = 2, #got do
      T.ok(got[i - 1] < got[i], "range not sorted")
    end
    T.eq(got[1], 2); T.eq(got[#got], 7)
  end)
end)

-- ---------------------------------------------------------------------------
-- to_array
-- ---------------------------------------------------------------------------

T.describe("to_array", function()
  T.it("empty returns empty", function()
    local arr = treap.new():to_array()
    T.eq(#arr, 0)
  end)

  T.it("sorted pairs", function()
    local t = treap.new()
    for _, k in ipairs({4, 2, 5, 1, 3}) do t:insert(k, k * 2) end
    local arr = t:to_array()
    T.eq(#arr, 5)
    for i = 1, 5 do
      T.eq(arr[i][1], i)        -- key == i
      T.eq(arr[i][2], i * 2)    -- value == key * 2
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- split / merge
-- ---------------------------------------------------------------------------

T.describe("split and merge", function()
  T.it("split divides keys correctly", function()
    local t = treap.new()
    for i = 1, 10 do t:insert(i, i) end
    local lt, rt = t:split(5)
    -- lt has keys < 5
    local la = lt:to_array()
    T.eq(#la, 4)
    for _, pair in ipairs(la) do
      T.ok(pair[1] < 5, "left side has key >= 5: " .. tostring(pair[1]))
    end
    -- rt has keys >= 5
    local ra = rt:to_array()
    T.eq(#ra, 6)
    for _, pair in ipairs(ra) do
      T.ok(pair[1] >= 5, "right side has key < 5: " .. tostring(pair[1]))
    end
  end)

  T.it("split sizes sum to original", function()
    local t = treap.new()
    for i = 1, 8 do t:insert(i, i) end
    local lt, rt = t:split(4)
    T.eq(lt:size() + rt:size(), 8)
  end)

  T.it("split at min: left is empty", function()
    local t = treap.new()
    for i = 1, 5 do t:insert(i, i) end
    local lt, rt = t:split(1)
    T.eq(lt:size(), 0)
    T.eq(rt:size(), 5)
  end)

  T.it("split above max: right is empty", function()
    local t = treap.new()
    for i = 1, 5 do t:insert(i, i) end
    local lt, rt = t:split(100)
    T.eq(lt:size(), 5)
    T.eq(rt:size(), 0)
  end)

  T.it("merge restores order", function()
    local lt = treap.new()
    for i = 1, 5 do lt:insert(i, i) end
    local rt = treap.new()
    for i = 6, 10 do rt:insert(i, i) end
    local m = treap.merge(lt, rt)
    T.eq(m:size(), 10)
    local arr = m:to_array()
    T.eq(#arr, 10)
    for i = 1, 10 do
      T.eq(arr[i][1], i)
    end
  end)

  T.it("split then merge roundtrip", function()
    local t = treap.new()
    for i = 1, 10 do t:insert(i, i * 3) end
    local lt, rt = t:split(6)
    local m = treap.merge(lt, rt)
    T.eq(m:size(), 10)
    local arr = m:to_array()
    for i = 1, 10 do
      T.eq(arr[i][1], i)
      T.eq(arr[i][2], i * 3)
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- Custom comparator (reverse order)
-- ---------------------------------------------------------------------------

T.describe("custom comparator", function()
  T.it("reverse order treap", function()
    local function rev_cmp(a, b)
      if a > b then return -1
      elseif a < b then return 1
      else return 0
      end
    end
    local t = treap.new(rev_cmp)
    for _, k in ipairs({3, 1, 4, 1, 5, 9, 2, 6}) do
      t:insert(k, k)
    end
    -- min in reverse order is actually the largest number
    local kmin, _ = t:min()
    local kmax, _ = t:max()
    T.eq(kmin, 9)
    T.eq(kmax, 1)
  end)

  T.it("reverse order each is descending", function()
    local function rev_cmp(a, b)
      if a > b then return -1
      elseif a < b then return 1
      else return 0
      end
    end
    local t = treap.new(rev_cmp)
    for i = 1, 7 do t:insert(i, i) end
    local got = {}
    t:each(function(k) got[#got + 1] = k end)
    -- should be 7,6,5,4,3,2,1
    for i = 2, #got do
      T.ok(got[i - 1] > got[i], "reverse order violated at " .. i)
    end
    T.eq(got[1], 7)
    T.eq(got[#got], 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- Stress test: 1000 random inserts/removes
-- ---------------------------------------------------------------------------

T.describe("stress test", function()
  T.it("BST property maintained after 1000 random inserts/removes", function()
    math.randomseed(42)
    local t = treap.new()
    local mirror = {}  -- ground truth

    -- Insert 1000 random keys
    for _ = 1, 1000 do
      local k = math.random(1, 200)
      local v = math.random(1, 10000)
      t:insert(k, v)
      mirror[k] = v
    end

    -- Verify all mirror keys are in the treap
    local mirror_count = 0
    for k, v in pairs(mirror) do
      mirror_count = mirror_count + 1
      T.eq(t:get(k), v)
    end
    T.eq(t:size(), mirror_count)

    -- Remove half the keys
    local removed = 0
    for k, _ in pairs(mirror) do
      if math.random() < 0.5 then
        T.eq(t:remove(k), true)
        mirror[k] = nil
        removed = removed + 1
      end
    end

    -- Verify remaining
    local remaining = 0
    for k, v in pairs(mirror) do
      remaining = remaining + 1
      T.eq(t:get(k), v)
    end
    T.eq(t:size(), remaining)

    -- Verify sorted order via to_array
    local arr = t:to_array()
    T.eq(#arr, remaining)
    for i = 2, #arr do
      T.ok(arr[i - 1][1] < arr[i][1], "out of order at index " .. i)
    end
  end)
end)
