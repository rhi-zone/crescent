-- lib/persistent/persistent_test.lua
-- Tests for lib/persistent: persistent list, vector, and map.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local P = require("lib.persistent")

-- ---------------------------------------------------------------------------
-- List tests
-- ---------------------------------------------------------------------------
T.describe("persistent list", function()
  T.it("empty list has length 0", function()
    local lst = P.list()
    T.eq(lst:length(), 0)
  end)

  T.it("empty list head returns nil", function()
    local lst = P.list()
    T.eq(lst:head(), nil)
  end)

  T.it("empty list tail returns empty list", function()
    local lst = P.list()
    T.eq(lst:tail():length(), 0)
  end)

  T.it("list() constructor with values", function()
    local lst = P.list(1, 2, 3)
    T.eq(lst:length(), 3)
    T.eq(lst:head(), 1)
  end)

  T.it("tail returns rest of list", function()
    local lst = P.list(1, 2, 3)
    local t = lst:tail()
    T.eq(t:length(), 2)
    T.eq(t:head(), 2)
  end)

  T.it("cons prepends a value", function()
    local lst = P.list(1, 2, 3)
    local lst2 = lst:cons(0)
    T.eq(lst2:length(), 4)
    T.eq(lst2:head(), 0)
    T.eq(lst2:tail():head(), 1)
  end)

  T.it("cons does not mutate original", function()
    local lst = P.list(1, 2, 3)
    local _ = lst:cons(0)
    T.eq(lst:length(), 3)
    T.eq(lst:head(), 1)
  end)

  T.it("get returns 1-indexed values", function()
    local lst = P.list(10, 20, 30)
    T.eq(lst:get(1), 10)
    T.eq(lst:get(2), 20)
    T.eq(lst:get(3), 30)
  end)

  T.it("get out of range returns nil", function()
    local lst = P.list(1, 2)
    T.eq(lst:get(0), nil)
    T.eq(lst:get(3), nil)
  end)

  T.it("to_array returns values in order", function()
    local lst = P.list(1, 2, 3)
    local arr = lst:to_array()
    T.eq(arr[1], 1)
    T.eq(arr[2], 2)
    T.eq(arr[3], 3)
    T.eq(#arr, 3)
  end)

  T.it("to_array on empty list returns empty table", function()
    local lst = P.list()
    local arr = lst:to_array()
    T.eq(#arr, 0)
  end)

  T.it("map transforms values", function()
    local lst = P.list(1, 2, 3)
    local doubled = lst:map(function(x) return x * 2 end)
    T.eq(doubled:get(1), 2)
    T.eq(doubled:get(2), 4)
    T.eq(doubled:get(3), 6)
    T.eq(doubled:length(), 3)
  end)

  T.it("map does not mutate original", function()
    local lst = P.list(1, 2, 3)
    local _ = lst:map(function(x) return x * 2 end)
    T.eq(lst:get(1), 1)
  end)

  T.it("filter selects elements", function()
    local lst = P.list(1, 2, 3, 4, 5)
    local evens = lst:filter(function(x) return x % 2 == 0 end)
    T.eq(evens:length(), 2)
    T.eq(evens:get(1), 2)
    T.eq(evens:get(2), 4)
  end)

  T.it("filter all false returns empty", function()
    local lst = P.list(1, 2, 3)
    local none = lst:filter(function(_) return false end)
    T.eq(none:length(), 0)
  end)

  T.it("foldl accumulates left to right", function()
    local lst = P.list(1, 2, 3, 4)
    local sum = lst:foldl(function(acc, x) return acc + x end, 0)
    T.eq(sum, 10)
  end)

  T.it("foldl preserves order (subtraction test)", function()
    local lst = P.list(10, 3, 2)
    -- ((10 - 3) - 2) = 5
    local result = lst:foldl(function(acc, x) return acc - x end, 10)
    T.eq(result, -5)  -- 10 then 10-10=0, 0-3=-3, -3-2=-5
  end)

  T.it("concat appends two lists", function()
    local a = P.list(1, 2, 3)
    local b = P.list(4, 5, 6)
    local c = a:concat(b)
    T.eq(c:length(), 6)
    T.eq(c:get(1), 1)
    T.eq(c:get(4), 4)
    T.eq(c:get(6), 6)
  end)

  T.it("concat with empty list", function()
    local a = P.list(1, 2, 3)
    local b = P.list()
    T.eq(a:concat(b):length(), 3)
    T.eq(b:concat(a):length(), 3)
  end)

  T.it("reverse reverses the list", function()
    local lst = P.list(1, 2, 3)
    local rev = lst:reverse()
    T.eq(rev:get(1), 3)
    T.eq(rev:get(2), 2)
    T.eq(rev:get(3), 1)
  end)

  T.it("reverse does not mutate original", function()
    local lst = P.list(1, 2, 3)
    local _ = lst:reverse()
    T.eq(lst:get(1), 1)
    T.eq(lst:get(3), 3)
  end)

  T.it("reverse of empty list is empty", function()
    local lst = P.list()
    T.eq(lst:reverse():length(), 0)
  end)

  T.it("list_from constructs from array", function()
    local arr = { 10, 20, 30, 40 }
    local lst = P.list_from(arr)
    T.eq(lst:length(), 4)
    T.eq(lst:get(1), 10)
    T.eq(lst:get(4), 40)
  end)

  T.it("list_from round-trip", function()
    local arr = { 5, 4, 3, 2, 1 }
    local lst = P.list_from(arr)
    local arr2 = lst:to_array()
    for i = 1, #arr do
      T.eq(arr2[i], arr[i])
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- Vector tests
-- ---------------------------------------------------------------------------
T.describe("persistent vector", function()
  T.it("empty vector has length 0", function()
    local vec = P.vector()
    T.eq(vec:length(), 0)
  end)

  T.it("vector() constructor with values", function()
    local vec = P.vector(1, 2, 3, 4, 5)
    T.eq(vec:length(), 5)
  end)

  T.it("get returns 1-indexed values", function()
    local vec = P.vector(10, 20, 30)
    T.eq(vec:get(1), 10)
    T.eq(vec:get(2), 20)
    T.eq(vec:get(3), 30)
  end)

  T.it("get out of range returns nil", function()
    local vec = P.vector(1, 2, 3)
    T.eq(vec:get(0), nil)
    T.eq(vec:get(4), nil)
  end)

  T.it("set returns new vector with changed value", function()
    local vec = P.vector(1, 2, 3)
    local vec2 = vec:set(2, 99)
    T.eq(vec2:get(1), 1)
    T.eq(vec2:get(2), 99)
    T.eq(vec2:get(3), 3)
    T.eq(vec2:length(), 3)
  end)

  T.it("set does not mutate original", function()
    local vec = P.vector(1, 2, 3)
    local _ = vec:set(2, 99)
    T.eq(vec:get(2), 2)
  end)

  T.it("set on out-of-range returns nil + errmsg", function()
    local vec = P.vector(1, 2, 3)
    local result, err = vec:set(5, 99)
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

  T.it("append adds element to end", function()
    local vec = P.vector(1, 2, 3)
    local vec2 = vec:append(4)
    T.eq(vec2:length(), 4)
    T.eq(vec2:get(4), 4)
  end)

  T.it("append does not mutate original", function()
    local vec = P.vector(1, 2, 3)
    local _ = vec:append(4)
    T.eq(vec:length(), 3)
  end)

  T.it("append to empty vector", function()
    local vec = P.vector()
    local vec2 = vec:append(42)
    T.eq(vec2:length(), 1)
    T.eq(vec2:get(1), 42)
  end)

  T.it("to_array returns values in order", function()
    local vec = P.vector(5, 4, 3, 2, 1)
    local arr = vec:to_array()
    T.eq(arr[1], 5)
    T.eq(arr[5], 1)
    T.eq(#arr, 5)
  end)

  T.it("map transforms values", function()
    local vec = P.vector(1, 2, 3)
    local doubled = vec:map(function(x) return x * 2 end)
    T.eq(doubled:get(1), 2)
    T.eq(doubled:get(2), 4)
    T.eq(doubled:get(3), 6)
  end)

  T.it("map does not mutate original", function()
    local vec = P.vector(1, 2, 3)
    local _ = vec:map(function(x) return x * 10 end)
    T.eq(vec:get(1), 1)
  end)

  T.it("slice returns sub-vector", function()
    local vec = P.vector(1, 2, 3, 4, 5)
    local sliced = vec:slice(2, 4)
    T.eq(sliced:length(), 3)
    T.eq(sliced:get(1), 2)
    T.eq(sliced:get(2), 3)
    T.eq(sliced:get(3), 4)
  end)

  T.it("slice does not mutate original", function()
    local vec = P.vector(1, 2, 3, 4, 5)
    local _ = vec:slice(2, 4)
    T.eq(vec:length(), 5)
    T.eq(vec:get(1), 1)
  end)

  T.it("slice out of bounds clamps", function()
    local vec = P.vector(1, 2, 3)
    local sliced = vec:slice(1, 100)
    T.eq(sliced:length(), 3)
  end)

  T.it("slice where from > to returns empty", function()
    local vec = P.vector(1, 2, 3)
    local sliced = vec:slice(4, 2)
    T.eq(sliced:length(), 0)
  end)

  T.it("vector_from constructs from array", function()
    local arr = { 10, 20, 30, 40 }
    local vec = P.vector_from(arr)
    T.eq(vec:length(), 4)
    T.eq(vec:get(1), 10)
    T.eq(vec:get(4), 40)
  end)

  T.it("vector_from round-trip", function()
    local arr = { 7, 6, 5, 4, 3 }
    local vec = P.vector_from(arr)
    local arr2 = vec:to_array()
    for i = 1, #arr do
      T.eq(arr2[i], arr[i])
    end
  end)

  T.it("vector_from empty array", function()
    local vec = P.vector_from({})
    T.eq(vec:length(), 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- Map tests
-- ---------------------------------------------------------------------------
T.describe("persistent map", function()
  T.it("empty map has size 0", function()
    local m = P.map()
    T.eq(m:size(), 0)
  end)

  T.it("set and get", function()
    local m = P.map():set("a", 1):set("b", 2):set("c", 3)
    T.eq(m:get("a"), 1)
    T.eq(m:get("b"), 2)
    T.eq(m:get("c"), 3)
  end)

  T.it("get missing key returns nil", function()
    local m = P.map():set("a", 1)
    T.eq(m:get("z"), nil)
  end)

  T.it("has returns true for existing key", function()
    local m = P.map():set("x", 42)
    T.ok(m:has("x"))
  end)

  T.it("has returns false for missing key", function()
    local m = P.map():set("x", 42)
    T.ok(not m:has("y"))
  end)

  T.it("size tracks insertions", function()
    local m = P.map():set("a", 1):set("b", 2):set("c", 3)
    T.eq(m:size(), 3)
  end)

  T.it("set does not mutate original", function()
    local m1 = P.map():set("a", 1)
    local _ = m1:set("b", 2)
    T.eq(m1:size(), 1)
    T.ok(not m1:has("b"))
  end)

  T.it("set with same key updates value, size unchanged", function()
    local m1 = P.map():set("a", 1)
    local m2 = m1:set("a", 99)
    T.eq(m2:get("a"), 99)
    T.eq(m2:size(), 1)
    -- original unchanged
    T.eq(m1:get("a"), 1)
  end)

  T.it("delete removes key", function()
    local m = P.map():set("a", 1):set("b", 2):set("c", 3)
    local m2 = m:delete("b")
    T.ok(not m2:has("b"))
    T.eq(m2:size(), 2)
    T.eq(m2:get("a"), 1)
    T.eq(m2:get("c"), 3)
  end)

  T.it("delete does not mutate original", function()
    local m = P.map():set("a", 1):set("b", 2)
    local _ = m:delete("a")
    T.ok(m:has("a"))
    T.eq(m:size(), 2)
  end)

  T.it("delete missing key returns same map", function()
    local m = P.map():set("a", 1)
    local m2 = m:delete("z")
    T.eq(m2:size(), 1)
    T.ok(m2:has("a"))
  end)

  T.it("keys returns sorted array", function()
    local m = P.map():set("c", 3):set("a", 1):set("b", 2)
    local keys = m:keys()
    T.eq(#keys, 3)
    T.eq(keys[1], "a")
    T.eq(keys[2], "b")
    T.eq(keys[3], "c")
  end)

  T.it("values returns values in key order", function()
    local m = P.map():set("c", 30):set("a", 10):set("b", 20)
    local vals = m:values()
    T.eq(vals[1], 10)  -- a
    T.eq(vals[2], 20)  -- b
    T.eq(vals[3], 30)  -- c
  end)

  T.it("to_table returns plain Lua table", function()
    local m = P.map():set("x", 1):set("y", 2)
    local t = m:to_table()
    T.eq(t["x"], 1)
    T.eq(t["y"], 2)
  end)

  T.it("merge right-wins on conflicts", function()
    local m1 = P.map():set("a", 1):set("b", 2)
    local m2 = P.map():set("b", 99):set("c", 3)
    local merged = m1:merge(m2)
    T.eq(merged:get("a"), 1)
    T.eq(merged:get("b"), 99)  -- m2 wins
    T.eq(merged:get("c"), 3)
    T.eq(merged:size(), 3)
  end)

  T.it("merge does not mutate either map", function()
    local m1 = P.map():set("a", 1)
    local m2 = P.map():set("b", 2)
    local _ = m1:merge(m2)
    T.eq(m1:size(), 1)
    T.eq(m2:size(), 1)
  end)

  T.it("merge with empty map", function()
    local m = P.map():set("a", 1)
    T.eq(m:merge(P.map()):size(), 1)
    T.eq(P.map():merge(m):size(), 1)
  end)

  T.it("map_from constructs from table", function()
    local m = P.map_from({ x = 10, y = 20, z = 30 })
    T.eq(m:size(), 3)
    T.eq(m:get("x"), 10)
    T.eq(m:get("y"), 20)
    T.eq(m:get("z"), 30)
  end)

  T.it("map_from round-trip via to_table", function()
    local original = { alpha = 1, beta = 2, gamma = 3 }
    local m = P.map_from(original)
    local result = m:to_table()
    T.eq(result["alpha"], original["alpha"])
    T.eq(result["beta"], original["beta"])
    T.eq(result["gamma"], original["gamma"])
  end)

  T.it("map_from_pairs constructs from array", function()
    local pairs_arr = { { "a", 1 }, { "b", 2 }, { "c", 3 } }
    local m = P.map_from_pairs(pairs_arr)
    T.eq(m:size(), 3)
    T.eq(m:get("a"), 1)
    T.eq(m:get("b"), 2)
    T.eq(m:get("c"), 3)
  end)

  T.it("map works with numeric keys", function()
    local m = P.map():set(1, "one"):set(2, "two"):set(3, "three")
    T.eq(m:get(1), "one")
    T.eq(m:get(2), "two")
    T.eq(m:size(), 3)
  end)
end)

-- ---------------------------------------------------------------------------
-- Module meta
-- ---------------------------------------------------------------------------
T.describe("module", function()
  T.it("_tier is 'pure'", function()
    T.eq(P._tier, "pure")
  end)
end)
