if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local skiplist = require("lib.skiplist")

T.describe("skiplist", function()

  T.describe("basic insert/get/has", function()
    T.it("get returns value for inserted key", function()
      local sl = skiplist.new(42)
      sl:insert(5, "five")
      T.eq(sl:get(5), "five")
    end)

    T.it("get returns nil for missing key", function()
      local sl = skiplist.new(42)
      sl:insert(5, "five")
      T.eq(sl:get(4), nil)
      T.eq(sl:get(6), nil)
    end)

    T.it("has returns true for present key", function()
      local sl = skiplist.new(42)
      sl:insert(3, "three")
      T.ok(sl:has(3))
    end)

    T.it("has returns false for absent key", function()
      local sl = skiplist.new(42)
      sl:insert(3, "three")
      T.fail(sl:has(4))
    end)

    T.it("insert updates value for duplicate key", function()
      local sl = skiplist.new(42)
      sl:insert(5, "five")
      sl:insert(5, "FIVE")
      T.eq(sl:get(5), "FIVE")
      T.eq(sl:size(), 1)
    end)

    T.it("insert without value stores nil", function()
      local sl = skiplist.new(42)
      sl:insert(7)
      T.ok(sl:has(7))
      T.eq(sl:get(7), nil)
    end)

    T.it("size reflects number of distinct keys", function()
      local sl = skiplist.new(42)
      T.eq(sl:size(), 0)
      sl:insert(1)
      T.eq(sl:size(), 1)
      sl:insert(2)
      T.eq(sl:size(), 2)
      sl:insert(2)  -- duplicate
      T.eq(sl:size(), 2)
    end)
  end)

  T.describe("delete", function()
    T.it("delete returns true when key exists", function()
      local sl = skiplist.new(42)
      sl:insert(3, "three")
      T.ok(sl:delete(3))
    end)

    T.it("delete returns false when key absent", function()
      local sl = skiplist.new(42)
      sl:insert(3, "three")
      T.fail(sl:delete(9))
    end)

    T.it("deleted key is no longer found", function()
      local sl = skiplist.new(42)
      sl:insert(3, "three")
      sl:delete(3)
      T.fail(sl:has(3))
      T.eq(sl:get(3), nil)
    end)

    T.it("delete decrements size", function()
      local sl = skiplist.new(42)
      sl:insert(1) sl:insert(2) sl:insert(3)
      sl:delete(2)
      T.eq(sl:size(), 2)
    end)

    T.it("delete on empty list returns false", function()
      local sl = skiplist.new(42)
      T.fail(sl:delete(99))
    end)

    T.it("delete all elements leaves empty list", function()
      local sl = skiplist.new(42)
      sl:insert(1) sl:insert(2) sl:insert(3)
      sl:delete(1) sl:delete(2) sl:delete(3)
      T.eq(sl:size(), 0)
      T.eq(sl:min(), nil)
      T.eq(sl:max(), nil)
    end)
  end)

  T.describe("min/max", function()
    T.it("min returns nil on empty list", function()
      local sl = skiplist.new(42)
      T.eq(sl:min(), nil)
    end)

    T.it("max returns nil on empty list", function()
      local sl = skiplist.new(42)
      T.eq(sl:max(), nil)
    end)

    T.it("min returns smallest key", function()
      local sl = skiplist.new(42)
      sl:insert(5) sl:insert(3) sl:insert(7) sl:insert(1)
      T.eq(sl:min(), 1)
    end)

    T.it("max returns largest key", function()
      local sl = skiplist.new(42)
      sl:insert(5) sl:insert(3) sl:insert(7) sl:insert(1)
      T.eq(sl:max(), 7)
    end)

    T.it("min/max work with single element", function()
      local sl = skiplist.new(42)
      sl:insert(42)
      T.eq(sl:min(), 42)
      T.eq(sl:max(), 42)
    end)
  end)

  T.describe("iter / keys / values / pairs", function()
    T.it("iter yields keys in sorted order", function()
      local sl = skiplist.new(42)
      sl:insert(5, "e") sl:insert(3, "c") sl:insert(7, "g") sl:insert(1, "a")
      local got = {}
      for k, v in sl:iter() do
        got[#got + 1] = k
      end
      T.eq(got[1], 1)
      T.eq(got[2], 3)
      T.eq(got[3], 5)
      T.eq(got[4], 7)
    end)

    T.it("iter yields values matched to keys", function()
      local sl = skiplist.new(42)
      sl:insert(5, "e") sl:insert(3, "c") sl:insert(1, "a")
      local vals = {}
      for k, v in sl:iter() do
        vals[#vals + 1] = v
      end
      T.eq(vals[1], "a")
      T.eq(vals[2], "c")
      T.eq(vals[3], "e")
    end)

    T.it("keys returns sorted key array", function()
      local sl = skiplist.new(42)
      sl:insert(4) sl:insert(2) sl:insert(6)
      local ks = sl:keys()
      T.eq(ks[1], 2)
      T.eq(ks[2], 4)
      T.eq(ks[3], 6)
      T.eq(#ks, 3)
    end)

    T.it("values returns values in key-sorted order", function()
      local sl = skiplist.new(42)
      sl:insert(4, "d") sl:insert(2, "b") sl:insert(6, "f")
      local vs = sl:values()
      T.eq(vs[1], "b")
      T.eq(vs[2], "d")
      T.eq(vs[3], "f")
    end)

    T.it("pairs returns sorted {key,value} array", function()
      local sl = skiplist.new(42)
      sl:insert(4, "d") sl:insert(2, "b") sl:insert(6, "f")
      local ps = sl:pairs()
      T.eq(ps[1].key, 2) T.eq(ps[1].value, "b")
      T.eq(ps[2].key, 4) T.eq(ps[2].value, "d")
      T.eq(ps[3].key, 6) T.eq(ps[3].value, "f")
    end)

    T.it("iter on empty list returns nothing", function()
      local sl = skiplist.new(42)
      local count = 0
      for k, v in sl:iter() do count = count + 1 end
      T.eq(count, 0)
    end)
  end)

  T.describe("range / range_keys", function()
    local function make_sl()
      local sl = skiplist.new(42)
      for _, v in ipairs({1,3,5,7,9,11}) do sl:insert(v, v*10) end
      return sl
    end

    T.it("range returns pairs within bounds (inclusive)", function()
      local sl = make_sl()
      local r = sl:range(3, 7)
      T.eq(#r, 3)
      T.eq(r[1].key, 3) T.eq(r[1].value, 30)
      T.eq(r[2].key, 5) T.eq(r[2].value, 50)
      T.eq(r[3].key, 7) T.eq(r[3].value, 70)
    end)

    T.it("range with exact lo=hi returns single element", function()
      local sl = make_sl()
      local r = sl:range(5, 5)
      T.eq(#r, 1)
      T.eq(r[1].key, 5)
    end)

    T.it("range with lo=hi not present returns empty", function()
      local sl = make_sl()
      local r = sl:range(4, 4)
      T.eq(#r, 0)
    end)

    T.it("range spanning full list", function()
      local sl = make_sl()
      local r = sl:range(0, 100)
      T.eq(#r, 6)
    end)

    T.it("range out of bounds returns empty", function()
      local sl = make_sl()
      local r = sl:range(20, 30)
      T.eq(#r, 0)
    end)

    T.it("range with lo between elements", function()
      local sl = make_sl()
      local r = sl:range(2, 6)
      T.eq(#r, 2)
      T.eq(r[1].key, 3)
      T.eq(r[2].key, 5)
    end)

    T.it("range_keys returns only keys", function()
      local sl = make_sl()
      local ks = sl:range_keys(3, 9)
      T.eq(#ks, 4)
      T.eq(ks[1], 3)
      T.eq(ks[2], 5)
      T.eq(ks[3], 7)
      T.eq(ks[4], 9)
    end)

    T.it("range_keys empty result", function()
      local sl = make_sl()
      local ks = sl:range_keys(100, 200)
      T.eq(#ks, 0)
    end)
  end)

  T.describe("rank / at_rank", function()
    T.it("rank returns 1-based position", function()
      local sl = skiplist.new(42)
      sl:insert(1) sl:insert(3) sl:insert(5) sl:insert(7)
      T.eq(sl:rank(1), 1)
      T.eq(sl:rank(3), 2)
      T.eq(sl:rank(5), 3)
      T.eq(sl:rank(7), 4)
    end)

    T.it("rank returns nil for absent key", function()
      local sl = skiplist.new(42)
      sl:insert(1) sl:insert(3) sl:insert(5)
      T.eq(sl:rank(4), nil)
    end)

    T.it("at_rank returns correct key/value", function()
      local sl = skiplist.new(42)
      sl:insert(1, "a") sl:insert(3, "c") sl:insert(5, "e") sl:insert(7, "g")
      local r = sl:at_rank(2)
      T.eq(r.key, 3)
      T.eq(r.value, "c")
    end)

    T.it("at_rank(1) returns minimum", function()
      local sl = skiplist.new(42)
      sl:insert(10) sl:insert(20) sl:insert(30)
      local r = sl:at_rank(1)
      T.eq(r.key, 10)
    end)

    T.it("at_rank(size) returns maximum", function()
      local sl = skiplist.new(42)
      sl:insert(10) sl:insert(20) sl:insert(30)
      local r = sl:at_rank(3)
      T.eq(r.key, 30)
    end)

    T.it("at_rank out of range returns nil", function()
      local sl = skiplist.new(42)
      sl:insert(10)
      T.eq(sl:at_rank(0), nil)
      T.eq(sl:at_rank(2), nil)
    end)

    T.it("rank and at_rank are consistent", function()
      local sl = skiplist.new(42)
      local keys = {4, 8, 15, 16, 23, 42}
      for _, k in ipairs(keys) do sl:insert(k, k) end
      for _, k in ipairs(keys) do
        local r = sl:rank(k)
        T.ok(r ~= nil, "rank of " .. k .. " should not be nil")
        local entry = sl:at_rank(r)
        T.eq(entry.key, k)
      end
    end)
  end)

  T.describe("pred / succ / floor / ceil", function()
    local function make_sl()
      local sl = skiplist.new(42)
      for _, v in ipairs({2, 4, 6, 8, 10}) do sl:insert(v, v) end
      return sl
    end

    T.it("pred returns largest key strictly less than given", function()
      local sl = make_sl()
      T.eq(sl:pred(6).key, 4)
      T.eq(sl:pred(5).key, 4)
      T.eq(sl:pred(7).key, 6)
    end)

    T.it("pred returns nil when given <= min", function()
      local sl = make_sl()
      T.eq(sl:pred(2), nil)
      T.eq(sl:pred(1), nil)
    end)

    T.it("pred of value just above max returns max", function()
      local sl = make_sl()
      T.eq(sl:pred(11).key, 10)
    end)

    T.it("succ returns smallest key strictly greater than given", function()
      local sl = make_sl()
      T.eq(sl:succ(6).key, 8)
      T.eq(sl:succ(5).key, 6)
      T.eq(sl:succ(7).key, 8)
    end)

    T.it("succ returns nil when given >= max", function()
      local sl = make_sl()
      T.eq(sl:succ(10), nil)
      T.eq(sl:succ(11), nil)
    end)

    T.it("succ of value just below min returns min", function()
      local sl = make_sl()
      T.eq(sl:succ(1).key, 2)
    end)

    T.it("floor returns largest key <= given (exact match)", function()
      local sl = make_sl()
      T.eq(sl:floor(6).key, 6)
    end)

    T.it("floor returns largest key <= given (between)", function()
      local sl = make_sl()
      T.eq(sl:floor(5).key, 4)
      T.eq(sl:floor(7).key, 6)
    end)

    T.it("floor returns nil when given < min", function()
      local sl = make_sl()
      T.eq(sl:floor(1), nil)
    end)

    T.it("floor of value >= max returns max", function()
      local sl = make_sl()
      T.eq(sl:floor(10).key, 10)
      T.eq(sl:floor(99).key, 10)
    end)

    T.it("ceil returns smallest key >= given (exact match)", function()
      local sl = make_sl()
      T.eq(sl:ceil(6).key, 6)
    end)

    T.it("ceil returns smallest key >= given (between)", function()
      local sl = make_sl()
      T.eq(sl:ceil(5).key, 6)
      T.eq(sl:ceil(3).key, 4)
    end)

    T.it("ceil returns nil when given > max", function()
      local sl = make_sl()
      T.eq(sl:ceil(11), nil)
    end)

    T.it("ceil of value <= min returns min", function()
      local sl = make_sl()
      T.eq(sl:ceil(2).key, 2)
      T.eq(sl:ceil(1).key, 2)
    end)
  end)

  T.describe("custom comparator (reverse order)", function()
    T.it("new with reverse comparator sorts descending", function()
      local sl = skiplist.new(42, function(a, b) return a > b end)
      sl:insert(5) sl:insert(3) sl:insert(7) sl:insert(1)
      local ks = sl:keys()
      T.eq(ks[1], 7)
      T.eq(ks[2], 5)
      T.eq(ks[3], 3)
      T.eq(ks[4], 1)
    end)

    T.it("reverse: min returns largest numeric key", function()
      local sl = skiplist.new(42, function(a, b) return a > b end)
      sl:insert(5) sl:insert(3) sl:insert(7)
      T.eq(sl:min(), 7)
    end)

    T.it("reverse: max returns smallest numeric key", function()
      local sl = skiplist.new(42, function(a, b) return a > b end)
      sl:insert(5) sl:insert(3) sl:insert(7)
      T.eq(sl:max(), 3)
    end)

    T.it("reverse: range works by comparator order", function()
      local sl = skiplist.new(42, function(a, b) return a > b end)
      -- Stored in desc order: 9,7,5,3,1
      for _, v in ipairs({9,7,5,3,1}) do sl:insert(v) end
      -- range(lo=7, hi=3) means: 7 >= key >= 3 in comparator sense
      local r = sl:range(7, 3)
      T.eq(#r, 3)
      T.eq(r[1].key, 7)
      T.eq(r[2].key, 5)
      T.eq(r[3].key, 3)
    end)

    T.it("reverse: get still works", function()
      local sl = skiplist.new(42, function(a, b) return a > b end)
      sl:insert(5, "five") sl:insert(3, "three")
      T.eq(sl:get(5), "five")
      T.eq(sl:get(3), "three")
      T.eq(sl:get(4), nil)
    end)

    T.it("reverse: rank is positional", function()
      local sl = skiplist.new(42, function(a, b) return a > b end)
      sl:insert(5) sl:insert(3) sl:insert(7) sl:insert(1)
      -- Sorted desc: 7,5,3,1
      T.eq(sl:rank(7), 1)
      T.eq(sl:rank(5), 2)
      T.eq(sl:rank(3), 3)
      T.eq(sl:rank(1), 4)
    end)
  end)

  T.describe("large random test", function()
    T.it("100 inserts: sorted iteration matches sorted table", function()
      math.randomseed(42)
      local sl = skiplist.new(42)
      local inserted = {}
      local seen = {}
      for i = 1, 100 do
        local k = math.floor(math.random() * 200) + 1
        if not seen[k] then
          seen[k] = true
          inserted[#inserted + 1] = k
          sl:insert(k, k * 2)
        end
      end
      table.sort(inserted)
      local ks = sl:keys()
      T.eq(#ks, #inserted)
      for i = 1, #inserted do
        T.eq(ks[i], inserted[i])
      end
    end)

    T.it("100 inserts: range query matches brute force", function()
      math.randomseed(123)
      local sl = skiplist.new(42)
      local all_keys = {}
      local seen = {}
      for i = 1, 100 do
        local k = math.floor(math.random() * 500) + 1
        if not seen[k] then
          seen[k] = true
          all_keys[#all_keys + 1] = k
          sl:insert(k, k)
        end
      end
      table.sort(all_keys)

      local lo, hi = 100, 300
      -- Brute force
      local expected = {}
      for _, k in ipairs(all_keys) do
        if k >= lo and k <= hi then expected[#expected + 1] = k end
      end
      -- Skip list range
      local r = sl:range_keys(lo, hi)
      T.eq(#r, #expected)
      for i = 1, #expected do
        T.eq(r[i], expected[i])
      end
    end)

    T.it("rank/at_rank consistent after 50 random inserts", function()
      math.randomseed(77)
      local sl = skiplist.new(42)
      local inserted = {}
      local seen = {}
      for i = 1, 50 do
        local k = math.floor(math.random() * 200) + 1
        if not seen[k] then
          seen[k] = true
          inserted[#inserted + 1] = k
          sl:insert(k, k)
        end
      end
      table.sort(inserted)
      -- Verify each key's rank matches its 1-based sorted position
      for i, k in ipairs(inserted) do
        local r = sl:rank(k)
        T.eq(r, i, "rank of key " .. k)
        local entry = sl:at_rank(i)
        T.eq(entry.key, k, "at_rank " .. i)
      end
    end)

    T.it("delete reduces size and removes from iteration", function()
      math.randomseed(99)
      local sl = skiplist.new(42)
      local keys = {}
      local seen = {}
      for i = 1, 30 do
        local k = math.floor(math.random() * 100) + 1
        if not seen[k] then
          seen[k] = true
          keys[#keys + 1] = k
          sl:insert(k, k)
        end
      end
      local n = #keys
      -- Delete first half
      for i = 1, math.floor(n / 2) do
        sl:delete(keys[i])
      end
      T.eq(sl:size(), n - math.floor(n / 2))
      -- Verify deleted keys gone
      for i = 1, math.floor(n / 2) do
        T.fail(sl:has(keys[i]))
      end
      -- Verify remaining keys present
      for i = math.floor(n / 2) + 1, n do
        T.ok(sl:has(keys[i]))
      end
    end)
  end)

end)
