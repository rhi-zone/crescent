if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local MM = require("lib.multimap")

-- Helper: sort an array for stable comparison
local function sorted(arr)
  local copy = {}
  for i = 1, #arr do copy[i] = arr[i] end
  table.sort(copy)
  return copy
end

-- Helper: check two arrays have same elements (order-insensitive)
local function same_elements(a, b)
  if #a ~= #b then return false end
  local sa, sb = sorted(a), sorted(b)
  for i = 1, #sa do
    if sa[i] ~= sb[i] then return false end
  end
  return true
end

T.describe("multimap", function()

  T.describe("list mode", function()
    T.it("preserves duplicates and insertion order", function()
      local mm = MM.new()
      mm:put("fruits", "apple")
      mm:put("fruits", "banana")
      mm:put("fruits", "apple")
      local vals = mm:get("fruits")
      T.eq(#vals, 3)
      T.eq(vals[1], "apple")
      T.eq(vals[2], "banana")
      T.eq(vals[3], "apple")
    end)

    T.it("get on missing key returns empty array", function()
      local mm = MM.new()
      local vals = mm:get("missing")
      T.eq(type(vals), "table")
      T.eq(#vals, 0)
    end)

    T.it("has returns true for present value", function()
      local mm = MM.new()
      mm:put("k", "v")
      T.ok(mm:has("k", "v"))
      T.ok(not mm:has("k", "x"))
      T.ok(not mm:has("z", "v"))
    end)

    T.it("has_key works correctly", function()
      local mm = MM.new()
      T.ok(not mm:has_key("k"))
      mm:put("k", "v")
      T.ok(mm:has_key("k"))
    end)

    T.it("remove removes one occurrence only", function()
      local mm = MM.new()
      mm:put("k", "a")
      mm:put("k", "a")
      mm:put("k", "b")
      local ok = mm:remove("k", "a")
      T.ok(ok)
      local vals = mm:get("k")
      T.eq(#vals, 2)
      T.eq(vals[1], "a")
      T.eq(vals[2], "b")
    end)

    T.it("remove returns false when value not found", function()
      local mm = MM.new()
      mm:put("k", "a")
      T.ok(not mm:remove("k", "z"))
      T.ok(not mm:remove("missing", "a"))
    end)

    T.it("remove cleans up key when bucket empties", function()
      local mm = MM.new()
      mm:put("k", "a")
      mm:remove("k", "a")
      T.ok(not mm:has_key("k"))
    end)

    T.it("remove_all removes key entirely", function()
      local mm = MM.new()
      mm:put("k", "a")
      mm:put("k", "b")
      mm:remove_all("k")
      T.ok(not mm:has_key("k"))
      T.eq(mm:value_count(), 0)
    end)

    T.it("delete_key is alias for remove_all", function()
      local mm = MM.new()
      mm:put("k", "x")
      mm:delete_key("k")
      T.ok(not mm:has_key("k"))
    end)

    T.it("key_count and value_count are correct", function()
      local mm = MM.new()
      mm:put("a", 1)
      mm:put("a", 2)
      mm:put("b", 3)
      T.eq(mm:key_count(), 2)
      T.eq(mm:value_count(), 3)
    end)

    T.it("size returns count for a specific key", function()
      local mm = MM.new()
      mm:put("a", 1)
      mm:put("a", 2)
      mm:put("b", 3)
      T.eq(mm:size("a"), 2)
      T.eq(mm:size("b"), 1)
      T.eq(mm:size("missing"), 0)
    end)

    T.it("put_all adds multiple values", function()
      local mm = MM.new()
      mm:put_all("fruits", {"cherry", "date", "elderberry"})
      T.eq(mm:size("fruits"), 3)
      T.eq(mm:value_count(), 3)
    end)

    T.it("each yields (k, v) pairs", function()
      local mm = MM.new()
      mm:put("a", 1)
      mm:put("a", 2)
      mm:put("b", 3)
      local got = {}
      for k, v in mm:each() do
        got[#got + 1] = {k, v}
      end
      T.eq(#got, 3)
      -- Collect all values seen per key
      local by_key = {}
      for _, pair in ipairs(got) do
        local k, v = pair[1], pair[2]
        if not by_key[k] then by_key[k] = {} end
        by_key[k][#by_key[k] + 1] = v
      end
      T.ok(same_elements(by_key["a"], {1, 2}))
      T.ok(same_elements(by_key["b"], {3}))
    end)

    T.it("each_key yields (k, vals) pairs", function()
      local mm = MM.new()
      mm:put("x", "foo")
      mm:put("x", "bar")
      mm:put("y", "baz")
      local by_key = {}
      for k, vals in mm:each_key() do
        by_key[k] = vals
      end
      T.ok(same_elements(by_key["x"], {"foo", "bar"}))
      T.ok(same_elements(by_key["y"], {"baz"}))
    end)

    T.it("to_table returns key -> values map", function()
      local mm = MM.new()
      mm:put("a", 1)
      mm:put("a", 2)
      mm:put("b", 3)
      local t = mm:to_table()
      T.ok(same_elements(t["a"], {1, 2}))
      T.ok(same_elements(t["b"], {3}))
    end)

    T.it("flatten returns array of {key, value} pairs", function()
      local mm = MM.new()
      mm:put("a", 1)
      mm:put("b", 2)
      local flat = mm:flatten()
      T.eq(#flat, 2)
      -- Check both pairs present
      local found_a, found_b = false, false
      for _, pair in ipairs(flat) do
        if pair[1] == "a" and pair[2] == 1 then found_a = true end
        if pair[1] == "b" and pair[2] == 2 then found_b = true end
      end
      T.ok(found_a)
      T.ok(found_b)
    end)

    T.it("invert maps values to keys", function()
      local mm = MM.new()
      mm:put("fruits", "apple")
      mm:put("vegs",   "apple")
      mm:put("fruits", "banana")
      local inv = mm:invert()
      T.ok(same_elements(inv:get("apple"), {"fruits", "vegs"}))
      T.ok(same_elements(inv:get("banana"), {"fruits"}))
    end)

    T.it("copy produces independent clone", function()
      local mm = MM.new()
      mm:put("k", "v")
      local c = mm:copy()
      c:put("k", "w")
      T.eq(mm:size("k"), 1)
      T.eq(c:size("k"), 2)
    end)

    T.it("map_values transforms values", function()
      local mm = MM.new()
      mm:put("a", "hello")
      mm:put("a", "world")
      local mapped = mm:map_values(function(k, v) return v:upper() end)
      T.ok(same_elements(mapped:get("a"), {"HELLO", "WORLD"}))
    end)

    T.it("filter_values keeps matching values", function()
      local mm = MM.new()
      mm:put("a", "hi")
      mm:put("a", "hello")
      mm:put("a", "hey")
      local filtered = mm:filter_values(function(k, v) return #v > 2 end)
      T.ok(same_elements(filtered:get("a"), {"hello", "hey"}))
    end)

    T.it("filter_values removes key when no values remain", function()
      local mm = MM.new()
      mm:put("a", "x")
      local filtered = mm:filter_values(function(k, v) return #v > 5 end)
      T.ok(not filtered:has_key("a"))
    end)

    T.it("merge combines two multimaps", function()
      local mm1 = MM.new()
      mm1:put("a", 1)
      mm1:put("a", 2)
      local mm2 = MM.new()
      mm2:put("a", 3)
      mm2:put("b", 4)
      local merged = MM.merge(mm1, mm2)
      T.ok(same_elements(merged:get("a"), {1, 2, 3}))
      T.ok(same_elements(merged:get("b"), {4}))
      -- originals unchanged
      T.eq(mm1:size("a"), 2)
      T.ok(not mm1:has_key("b"))
    end)

    T.it("from_table accepts key->array input", function()
      local mm = MM.from_table({ fruits = {"apple", "banana"}, vegs = {"carrot"} })
      T.ok(same_elements(mm:get("fruits"), {"apple", "banana"}))
      T.ok(same_elements(mm:get("vegs"), {"carrot"}))
      T.eq(mm:value_count(), 3)
    end)

    T.it("from_table accepts key->scalar input", function()
      local mm = MM.from_table({ a = "x", b = "y" })
      T.ok(same_elements(mm:get("a"), {"x"}))
      T.ok(same_elements(mm:get("b"), {"y"}))
    end)

    T.it("keys returns all keys", function()
      local mm = MM.new()
      mm:put("x", 1)
      mm:put("y", 2)
      T.ok(same_elements(mm:keys(), {"x", "y"}))
    end)
  end)

  T.describe("set mode", function()
    T.it("ignores duplicate values per key", function()
      local mm = MM.new("set")
      mm:put("fruits", "apple")
      mm:put("fruits", "banana")
      mm:put("fruits", "apple")
      local vals = mm:get("fruits")
      T.eq(#vals, 2)
      T.ok(same_elements(vals, {"apple", "banana"}))
    end)

    T.it("value_count counts unique values only", function()
      local mm = MM.new("set")
      mm:put("k", "a")
      mm:put("k", "a")
      mm:put("k", "b")
      T.eq(mm:value_count(), 2)
    end)

    T.it("has works correctly in set mode", function()
      local mm = MM.new("set")
      mm:put("k", "v")
      T.ok(mm:has("k", "v"))
      T.ok(not mm:has("k", "x"))
    end)

    T.it("remove works in set mode", function()
      local mm = MM.new("set")
      mm:put("k", "a")
      mm:put("k", "b")
      mm:remove("k", "a")
      T.ok(not mm:has("k", "a"))
      T.ok(mm:has("k", "b"))
    end)

    T.it("merge in set mode deduplicates", function()
      local mm1 = MM.new("set")
      mm1:put("k", "a")
      local mm2 = MM.new("set")
      mm2:put("k", "a")
      mm2:put("k", "b")
      local merged = MM.merge(mm1, mm2)
      T.ok(same_elements(merged:get("k"), {"a", "b"}))
    end)
  end)

  T.describe("sorted mode", function()
    T.it("keeps values sorted ascending", function()
      local mm = MM.new("sorted")
      mm:put("nums", 5)
      mm:put("nums", 1)
      mm:put("nums", 3)
      mm:put("nums", 2)
      local vals = mm:get("nums")
      T.eq(#vals, 4)
      T.eq(vals[1], 1)
      T.eq(vals[2], 2)
      T.eq(vals[3], 3)
      T.eq(vals[4], 5)
    end)

    T.it("preserves duplicates in sorted order", function()
      local mm = MM.new("sorted")
      mm:put("k", "b")
      mm:put("k", "a")
      mm:put("k", "b")
      local vals = mm:get("k")
      T.eq(#vals, 3)
      T.eq(vals[1], "a")
      T.eq(vals[2], "b")
      T.eq(vals[3], "b")
    end)

    T.it("value_count correct in sorted mode", function()
      local mm = MM.new("sorted")
      mm:put("k", "x")
      mm:put("k", "x")
      T.eq(mm:value_count(), 2)
    end)
  end)

  T.describe("_tier", function()
    T.it("is 'pure'", function()
      T.eq(MM._tier, "pure")
    end)
  end)

end)
