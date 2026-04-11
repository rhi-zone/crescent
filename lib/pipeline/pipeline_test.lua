if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local M = require("lib.pipeline")

-- helper: deep equality for arrays
local function arr_eq(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

-- helper: deep equality for arrays of arrays (one level)
local function arr2_eq(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if not arr_eq(a[i], b[i]) then return false end
  end
  return true
end

T.describe("pipeline", function()

  T.describe("tier", function()
    T.it("_tier is pure", function()
      T.eq(M._tier, "pure")
    end)
  end)

  T.describe("from + collect", function()
    T.it("identity collect", function()
      local result = M.from({1, 2, 3}):collect()
      T.ok(arr_eq(result, {1, 2, 3}), "identity")
    end)

    T.it("empty array", function()
      local result = M.from({}):collect()
      T.eq(#result, 0)
    end)

    T.it("single element", function()
      local result = M.from({42}):collect()
      T.eq(result[1], 42)
      T.eq(#result, 1)
    end)
  end)

  T.describe("empty", function()
    T.it("empty() collect is empty", function()
      T.eq(#M.empty():collect(), 0)
    end)
    T.it("empty() count is 0", function()
      T.eq(M.empty():count(), 0)
    end)
  end)

  T.describe("filter", function()
    T.it("keeps matching elements", function()
      local result = M.from({1,2,3,4,5,6}):filter(function(x) return x % 2 == 0 end):collect()
      T.ok(arr_eq(result, {2,4,6}))
    end)

    T.it("removes all", function()
      local result = M.from({1,3,5}):filter(function(x) return x % 2 == 0 end):collect()
      T.eq(#result, 0)
    end)

    T.it("keeps all", function()
      local result = M.from({2,4,6}):filter(function(x) return x % 2 == 0 end):collect()
      T.ok(arr_eq(result, {2,4,6}))
    end)
  end)

  T.describe("map", function()
    T.it("transforms elements", function()
      local result = M.from({1,2,3}):map(function(x) return x * 2 end):collect()
      T.ok(arr_eq(result, {2,4,6}))
    end)

    T.it("type transform", function()
      local result = M.from({1,2,3}):map(tostring):collect()
      T.eq(result[1], "1")
      T.eq(result[2], "2")
      T.eq(result[3], "3")
    end)
  end)

  T.describe("take", function()
    T.it("takes first n", function()
      local result = M.from({1,2,3,4,5}):take(3):collect()
      T.ok(arr_eq(result, {1,2,3}))
    end)

    T.it("take more than available", function()
      local result = M.from({1,2}):take(10):collect()
      T.ok(arr_eq(result, {1,2}))
    end)

    T.it("take 0", function()
      T.eq(#M.from({1,2,3}):take(0):collect(), 0)
    end)
  end)

  T.describe("drop", function()
    T.it("drops first n", function()
      local result = M.from({1,2,3,4,5}):drop(2):collect()
      T.ok(arr_eq(result, {3,4,5}))
    end)

    T.it("drop more than available", function()
      local result = M.from({1,2}):drop(10):collect()
      T.eq(#result, 0)
    end)

    T.it("drop 0", function()
      T.ok(arr_eq(M.from({1,2,3}):drop(0):collect(), {1,2,3}))
    end)
  end)

  T.describe("take_while / drop_while", function()
    T.it("take_while stops at first false", function()
      local result = M.from({1,2,3,4,5}):take_while(function(x) return x < 4 end):collect()
      T.ok(arr_eq(result, {1,2,3}))
    end)

    T.it("drop_while skips leading matches", function()
      local result = M.from({1,2,3,4,5}):drop_while(function(x) return x < 3 end):collect()
      T.ok(arr_eq(result, {3,4,5}))
    end)
  end)

  T.describe("flat_map", function()
    T.it("flattens arrays", function()
      local result = M.from({1,2,3}):flat_map(function(x) return {x, x*10} end):collect()
      T.ok(arr_eq(result, {1,10,2,20,3,30}))
    end)

    T.it("empty inner arrays", function()
      local result = M.from({1,2,3}):flat_map(function(_) return {} end):collect()
      T.eq(#result, 0)
    end)
  end)

  T.describe("enumerate", function()
    T.it("adds 1-based indices", function()
      local result = M.from({"a","b","c"}):enumerate():collect()
      T.eq(#result, 3)
      T.eq(result[1][1], 1) T.eq(result[1][2], "a")
      T.eq(result[2][1], 2) T.eq(result[2][2], "b")
      T.eq(result[3][1], 3) T.eq(result[3][2], "c")
    end)
  end)

  T.describe("zip", function()
    T.it("pairs elements", function()
      local result = M.from({1,2,3}):zip(M.from({"a","b","c"})):collect()
      T.eq(#result, 3)
      T.eq(result[1][1], 1) T.eq(result[1][2], "a")
      T.eq(result[2][1], 2) T.eq(result[2][2], "b")
    end)

    T.it("stops at shorter pipeline", function()
      local result = M.from({1,2,3}):zip(M.from({"a","b"})):collect()
      T.eq(#result, 2)
    end)
  end)

  T.describe("batch", function()
    T.it("groups into batches", function()
      local result = M.from({1,2,3,4,5,6}):batch(2):collect()
      T.eq(#result, 3)
      T.ok(arr_eq(result[1], {1,2}))
      T.ok(arr_eq(result[2], {3,4}))
      T.ok(arr_eq(result[3], {5,6}))
    end)

    T.it("last batch smaller", function()
      local result = M.from({1,2,3,4,5}):batch(2):collect()
      T.eq(#result, 3)
      T.ok(arr_eq(result[3], {5}))
    end)
  end)

  T.describe("flatten", function()
    T.it("flattens one level", function()
      local result = M.from({{1,2},{3,4},{5}}):flatten():collect()
      T.ok(arr_eq(result, {1,2,3,4,5}))
    end)
  end)

  T.describe("unique", function()
    T.it("removes consecutive duplicates", function()
      local result = M.from({1,1,2,3,3,3,4}):unique():collect()
      T.ok(arr_eq(result, {1,2,3,4}))
    end)

    T.it("non-consecutive duplicates kept", function()
      local result = M.from({1,2,1,2}):unique():collect()
      T.ok(arr_eq(result, {1,2,1,2}))
    end)
  end)

  T.describe("tap", function()
    T.it("side effects without altering stream", function()
      local seen = {}
      local result = M.from({1,2,3}):tap(function(x) seen[#seen+1] = x end):collect()
      T.ok(arr_eq(result, {1,2,3}))
      T.ok(arr_eq(seen, {1,2,3}))
    end)
  end)

  T.describe("scan", function()
    T.it("running sum", function()
      local result = M.from({1,2,3,4}):scan(function(acc, x) return acc + x end, 0):collect()
      T.ok(arr_eq(result, {1,3,6,10}))
    end)
  end)

  T.describe("window", function()
    T.it("sliding window of 3", function()
      local result = M.from({1,2,3,4,5}):window(3):collect()
      T.eq(#result, 3)
      T.ok(arr_eq(result[1], {1,2,3}))
      T.ok(arr_eq(result[2], {2,3,4}))
      T.ok(arr_eq(result[3], {3,4,5}))
    end)

    T.it("window larger than input returns nothing", function()
      local result = M.from({1,2}):window(5):collect()
      T.eq(#result, 0)
    end)
  end)

  T.describe("range", function()
    T.it("range(1,5)", function()
      T.ok(arr_eq(M.range(1,5):collect(), {1,2,3,4,5}))
    end)

    T.it("range with step", function()
      T.ok(arr_eq(M.range(0,10,2):collect(), {0,2,4,6,8,10}))
    end)

    T.it("range descending", function()
      T.ok(arr_eq(M.range(5,1,-1):collect(), {5,4,3,2,1}))
    end)
  end)

  T.describe("generate", function()
    T.it("calls fn n times", function()
      local i = 0
      local result = M.generate(function() i = i+1; return i end, 4):collect()
      T.ok(arr_eq(result, {1,2,3,4}))
    end)

    T.it("stops early on nil", function()
      local data = {10,20,nil,40}
      local i = 0
      local result = M.generate(function() i=i+1; return data[i] end, 10):collect()
      T.ok(arr_eq(result, {10,20}))
    end)
  end)

  T.describe("repeat_val", function()
    T.it("repeats n times", function()
      T.ok(arr_eq(M.repeat_val(7, 3):collect(), {7,7,7}))
    end)

    T.it("repeat 0 times is empty", function()
      T.eq(#M.repeat_val(7, 0):collect(), 0)
    end)
  end)

  T.describe("from_iter", function()
    T.it("wraps an iterator function", function()
      local data = {5,6,7}
      local i = 0
      local result = M.from_iter(function()
        i = i + 1
        return data[i]
      end):collect()
      T.ok(arr_eq(result, {5,6,7}))
    end)
  end)

  T.describe("concat_sources", function()
    T.it("concatenates two pipelines", function()
      local result = M.concat_sources(M.from({1,2}), M.from({3,4,5})):collect()
      T.ok(arr_eq(result, {1,2,3,4,5}))
    end)

    T.it("concat with empty", function()
      T.ok(arr_eq(M.concat_sources(M.empty(), M.from({1,2})):collect(), {1,2}))
    end)
  end)

  T.describe("reduce", function()
    T.it("fold sum", function()
      local result = M.from({1,2,3,4,5}):reduce(function(acc,x) return acc+x end, 0)
      T.eq(result, 15)
    end)

    T.it("fold concat", function()
      local result = M.from({"a","b","c"}):reduce(function(acc,x) return acc..x end, "")
      T.eq(result, "abc")
    end)
  end)

  T.describe("each", function()
    T.it("calls fn and returns count", function()
      local sum = 0
      local n = M.from({1,2,3,4}):each(function(x) sum = sum + x end)
      T.eq(sum, 10)
      T.eq(n, 4)
    end)
  end)

  T.describe("count", function()
    T.it("counts elements", function()
      T.eq(M.from({1,2,3,4,5}):count(), 5)
    end)
    T.it("empty count is 0", function()
      T.eq(M.empty():count(), 0)
    end)
  end)

  T.describe("first / last", function()
    T.it("first returns first element", function()
      T.eq(M.from({10,20,30}):first(), 10)
    end)
    T.it("first on empty is nil", function()
      T.eq(M.empty():first(), nil)
    end)
    T.it("last returns last element", function()
      T.eq(M.from({10,20,30}):last(), 30)
    end)
    T.it("last on empty is nil", function()
      T.eq(M.empty():last(), nil)
    end)
  end)

  T.describe("sum", function()
    T.it("sums numbers", function()
      T.eq(M.from({1,2,3,4,5}):sum(), 15)
    end)
    T.it("empty sum is 0", function()
      T.eq(M.empty():sum(), 0)
    end)
  end)

  T.describe("min / max", function()
    T.it("min of numbers", function()
      T.eq(M.from({3,1,4,1,5,9,2,6}):min(), 1)
    end)
    T.it("max of numbers", function()
      T.eq(M.from({3,1,4,1,5,9,2,6}):max(), 9)
    end)
    T.it("min of empty is nil", function()
      T.eq(M.empty():min(), nil)
    end)
    T.it("max of empty is nil", function()
      T.eq(M.empty():max(), nil)
    end)
  end)

  T.describe("any / all", function()
    T.it("any returns true if any match", function()
      T.ok(M.from({1,2,3}):any(function(x) return x == 2 end))
    end)
    T.it("any returns false if none match", function()
      T.ok(not M.from({1,3,5}):any(function(x) return x == 2 end))
    end)
    T.it("all returns true if all match", function()
      T.ok(M.from({2,4,6}):all(function(x) return x % 2 == 0 end))
    end)
    T.it("all returns false if one fails", function()
      T.ok(not M.from({2,3,6}):all(function(x) return x % 2 == 0 end))
    end)
    T.it("all on empty is true", function()
      T.ok(M.empty():all(function() return false end))
    end)
    T.it("any on empty is false", function()
      T.ok(not M.empty():any(function() return true end))
    end)
  end)

  T.describe("find", function()
    T.it("finds first matching element", function()
      T.eq(M.from({1,2,3,4,5}):find(function(x) return x > 3 end), 4)
    end)
    T.it("returns nil if not found", function()
      T.eq(M.from({1,2,3}):find(function(x) return x > 10 end), nil)
    end)
  end)

  T.describe("to_map", function()
    T.it("builds map with key_fn", function()
      local result = M.from({"foo","bar","baz"}):to_map(function(s) return s:sub(1,1) end)
      T.eq(result["f"], "foo")
      T.eq(result["b"], "baz")  -- last wins on collision
    end)
    T.it("builds map with key_fn and val_fn", function()
      local result = M.from({1,2,3}):to_map(function(x) return x end, function(x) return x*x end)
      T.eq(result[1], 1)
      T.eq(result[2], 4)
      T.eq(result[3], 9)
    end)
  end)

  T.describe("group_by", function()
    T.it("groups elements by key", function()
      local result = M.from({1,2,3,4,5,6}):group_by(function(x)
        return x % 2 == 0 and "even" or "odd"
      end)
      T.ok(arr_eq(result["even"], {2,4,6}))
      T.ok(arr_eq(result["odd"], {1,3,5}))
    end)
  end)

  T.describe("join", function()
    T.it("joins with separator", function()
      T.eq(M.from({"a","b","c"}):join(","), "a,b,c")
    end)
    T.it("joins numbers", function()
      T.eq(M.from({1,2,3}):join("-"), "1-2-3")
    end)
    T.it("empty join is empty string", function()
      T.eq(M.empty():join(","), "")
    end)
  end)

  T.describe("drain", function()
    T.it("consumes pipeline for side effects", function()
      local sum = 0
      M.from({1,2,3}):tap(function(x) sum = sum + x end):drain()
      T.eq(sum, 6)
    end)
  end)

  T.describe("chaining", function()
    T.it("filter + map + take", function()
      local result = M.from({1,2,3,4,5,6,7,8,9,10})
        :filter(function(x) return x % 2 == 0 end)
        :map(function(x) return x * x end)
        :take(3)
        :collect()
      T.ok(arr_eq(result, {4,16,36}))
    end)

    T.it("range + map + filter + collect", function()
      local result = M.range(1,20)
        :map(function(x) return x * 3 end)
        :filter(function(x) return x % 2 == 1 end)
        :collect()
      -- odd multiples of 3 in range 3..60: 3,9,15,21,27,33,39,45,51,57
      T.eq(result[1], 3)
      T.eq(result[2], 9)
      T.eq(#result, 10)
    end)

    T.it("deep chain", function()
      local result = M.from({1,2,3,4,5,6,7,8,9,10})
        :drop(2)
        :take_while(function(x) return x <= 8 end)
        :map(function(x) return x + 100 end)
        :collect()
      T.ok(arr_eq(result, {103,104,105,106,107,108}))
    end)
  end)

  T.describe("large pipeline", function()
    T.it("1000 elements filter+map", function()
      local arr = {}
      for i = 1, 1000 do arr[i] = i end
      local result = M.from(arr)
        :filter(function(x) return x % 3 == 0 end)
        :map(function(x) return x * 2 end)
        :collect()
      T.eq(#result, 333)
      T.eq(result[1], 6)
      T.eq(result[333], 1998)  -- 3*333=999, 999*2=1998
    end)

    T.it("1000 elements sum", function()
      local arr = {}
      for i = 1, 1000 do arr[i] = i end
      T.eq(M.from(arr):sum(), 500500)
    end)
  end)

end)
