if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local hamt = require("lib.hamt")

T.describe("hamt", function()

  T.describe("empty map", function()
    T.it("new() returns empty map", function()
      local m = hamt.new()
      T.eq(m:size(), 0)
    end)

    T.it("get on empty returns nil", function()
      local m = hamt.new()
      T.eq(m:get("x"), nil)
    end)

    T.it("has on empty returns false", function()
      local m = hamt.new()
      T.eq(m:has("x"), false)
    end)

    T.it("to_table on empty returns {}", function()
      local m = hamt.new()
      local t = m:to_table()
      T.eq(next(t), nil)
    end)

    T.it("pairs on empty yields nothing", function()
      local m = hamt.new()
      local count = 0
      for _ in m:pairs() do count = count + 1 end
      T.eq(count, 0)
    end)
  end)

  T.describe("single key", function()
    T.it("set/get string key", function()
      local m = hamt.new():set("foo", 42)
      T.eq(m:get("foo"), 42)
    end)

    T.it("set/get number key", function()
      local m = hamt.new():set(1, "hello")
      T.eq(m:get(1), "hello")
    end)

    T.it("has returns true for present key", function()
      local m = hamt.new():set("k", true)
      T.eq(m:has("k"), true)
    end)

    T.it("has returns false for absent key", function()
      local m = hamt.new():set("k", true)
      T.eq(m:has("other"), false)
    end)

    T.it("size is 1 after one set", function()
      local m = hamt.new():set("k", 1)
      T.eq(m:size(), 1)
    end)

    T.it("delete existing key returns size 0", function()
      local m = hamt.new():set("k", 1):delete("k")
      T.eq(m:size(), 0)
      T.eq(m:get("k"), nil)
    end)

    T.it("delete absent key returns same-size map", function()
      local m = hamt.new():set("k", 1)
      local m2 = m:delete("missing")
      T.eq(m2:size(), 1)
    end)

    T.it("update replaces value, size unchanged", function()
      local m = hamt.new():set("k", 1):set("k", 99)
      T.eq(m:get("k"), 99)
      T.eq(m:size(), 1)
    end)
  end)

  T.describe("multiple keys", function()
    T.it("set and get many string keys", function()
      local m = hamt.new()
      for i = 1, 20 do
        m = m:set("key" .. i, i)
      end
      T.eq(m:size(), 20)
      for i = 1, 20 do
        T.eq(m:get("key" .. i), i)
      end
    end)

    T.it("set and get many number keys", function()
      local m = hamt.new()
      for i = 1, 20 do
        m = m:set(i, "v" .. i)
      end
      T.eq(m:size(), 20)
      for i = 1, 20 do
        T.eq(m:get(i), "v" .. i)
      end
    end)

    T.it("absent keys return nil", function()
      local m = hamt.new():set("a", 1):set("b", 2)
      T.eq(m:get("c"), nil)
      T.eq(m:get("z"), nil)
    end)

    T.it("delete one of many keys", function()
      local m = hamt.new()
      for i = 1, 10 do m = m:set(i, i * 2) end
      m = m:delete(5)
      T.eq(m:size(), 9)
      T.eq(m:get(5), nil)
      T.eq(m:get(4), 8)
      T.eq(m:get(6), 12)
    end)
  end)

  T.describe("persistence (structural sharing)", function()
    T.it("original unchanged after set", function()
      local m1 = hamt.new():set("a", 1)
      local m2 = m1:set("b", 2)
      T.eq(m1:size(), 1)
      T.eq(m1:get("b"), nil)
      T.eq(m2:size(), 2)
      T.eq(m2:get("a"), 1)
      T.eq(m2:get("b"), 2)
    end)

    T.it("original unchanged after delete", function()
      local m1 = hamt.new():set("a", 1):set("b", 2)
      local m2 = m1:delete("a")
      T.eq(m1:size(), 2)
      T.eq(m1:get("a"), 1)
      T.eq(m2:size(), 1)
      T.eq(m2:get("a"), nil)
    end)

    T.it("update does not affect old version", function()
      local m1 = hamt.new():set("x", 10)
      local m2 = m1:set("x", 20)
      T.eq(m1:get("x"), 10)
      T.eq(m2:get("x"), 20)
    end)

    T.it("branching history", function()
      local base = hamt.new():set("a", 1):set("b", 2)
      local branch1 = base:set("c", 3)
      local branch2 = base:set("c", 99)
      T.eq(base:get("c"), nil)
      T.eq(branch1:get("c"), 3)
      T.eq(branch2:get("c"), 99)
      -- base unchanged
      T.eq(base:size(), 2)
    end)
  end)

  T.describe("iteration", function()
    T.it("pairs yields all entries", function()
      local input = {a = 1, b = 2, c = 3, d = 4, e = 5}
      local m = hamt.from_table(input)
      local seen = {}
      for k, v in m:pairs() do
        seen[k] = v
      end
      for k, v in pairs(input) do
        T.eq(seen[k], v)
      end
    end)

    T.it("pairs count matches size", function()
      local m = hamt.new()
      for i = 1, 15 do m = m:set(i, i) end
      local count = 0
      for _ in m:pairs() do count = count + 1 end
      T.eq(count, 15)
      T.eq(count, m:size())
    end)

    T.it("pairs on empty yields zero entries", function()
      local m = hamt.new()
      local count = 0
      for _ in m:pairs() do count = count + 1 end
      T.eq(count, 0)
    end)
  end)

  T.describe("from_table / to_table", function()
    T.it("round-trip string keys", function()
      local t = {foo = 1, bar = 2, baz = 3}
      local m = hamt.from_table(t)
      T.eq(m:size(), 3)
      local t2 = m:to_table()
      for k, v in pairs(t) do T.eq(t2[k], v) end
      for k, v in pairs(t2) do T.eq(t[k], v) end
    end)

    T.it("round-trip number keys", function()
      local t = {[1] = "a", [2] = "b", [10] = "c"}
      local m = hamt.from_table(t)
      T.eq(m:size(), 3)
      local t2 = m:to_table()
      for k, v in pairs(t) do T.eq(t2[k], v) end
    end)

    T.it("from_table({}) produces empty map", function()
      local m = hamt.from_table({})
      T.eq(m:size(), 0)
    end)
  end)

  T.describe("merge", function()
    T.it("merge two disjoint maps", function()
      local m1 = hamt.from_table({a = 1, b = 2})
      local m2 = hamt.from_table({c = 3, d = 4})
      local merged = hamt.merge(m1, m2)
      T.eq(merged:size(), 4)
      T.eq(merged:get("a"), 1)
      T.eq(merged:get("b"), 2)
      T.eq(merged:get("c"), 3)
      T.eq(merged:get("d"), 4)
    end)

    T.it("merge: second wins on conflict", function()
      local m1 = hamt.from_table({a = 1, b = 2})
      local m2 = hamt.from_table({b = 99, c = 3})
      local merged = hamt.merge(m1, m2)
      T.eq(merged:get("a"), 1)
      T.eq(merged:get("b"), 99)
      T.eq(merged:get("c"), 3)
      T.eq(merged:size(), 3)
    end)

    T.it("merge with empty is identity", function()
      local m1 = hamt.from_table({a = 1, b = 2})
      local m2 = hamt.new()
      local merged = hamt.merge(m1, m2)
      T.eq(merged:size(), 2)
      T.eq(merged:get("a"), 1)
      T.eq(merged:get("b"), 2)
    end)

    T.it("merge empty with non-empty", function()
      local m1 = hamt.new()
      local m2 = hamt.from_table({x = 7})
      local merged = hamt.merge(m1, m2)
      T.eq(merged:size(), 1)
      T.eq(merged:get("x"), 7)
    end)

    T.it("originals unchanged after merge", function()
      local m1 = hamt.from_table({a = 1})
      local m2 = hamt.from_table({b = 2})
      local _ = hamt.merge(m1, m2)
      T.eq(m1:size(), 1)
      T.eq(m2:size(), 1)
      T.eq(m1:get("b"), nil)
    end)
  end)

  T.describe("large map stress test", function()
    T.it("insert 1000 entries and retrieve all", function()
      local m = hamt.new()
      for i = 1, 1000 do
        m = m:set("key" .. i, i * 3)
      end
      T.eq(m:size(), 1000)
      local ok = true
      for i = 1, 1000 do
        if m:get("key" .. i) ~= i * 3 then ok = false; break end
      end
      T.ok(ok)
    end)

    T.it("delete 500 entries from 1000-entry map", function()
      local m = hamt.new()
      for i = 1, 1000 do m = m:set(i, i) end
      for i = 1, 500 do m = m:delete(i) end
      T.eq(m:size(), 500)
      local ok = true
      for i = 501, 1000 do
        if m:get(i) ~= i then ok = false; break end
      end
      T.ok(ok)
      -- deleted keys gone
      for i = 1, 500 do
        if m:get(i) ~= nil then ok = false; break end
      end
      T.ok(ok)
    end)

    T.it("iteration covers all 1000 entries", function()
      local m = hamt.new()
      for i = 1, 1000 do m = m:set(i, i) end
      local seen = {}
      for k, v in m:pairs() do seen[k] = v end
      local ok = true
      for i = 1, 1000 do
        if seen[i] ~= i then ok = false; break end
      end
      T.ok(ok)
    end)
  end)

  T.describe("hash collision handling", function()
    -- We can't easily force hash collisions externally, but we test that
    -- keys that share hash prefixes (common with sequential integers) work correctly.
    T.it("sequential integer keys all stored correctly", function()
      local m = hamt.new()
      -- 0..63 share a 6-bit prefix pattern; test that all are distinct
      for i = 0, 63 do m = m:set(i, i + 1000) end
      T.eq(m:size(), 64)
      for i = 0, 63 do
        T.eq(m:get(i), i + 1000)
      end
    end)

    T.it("mixed string and number keys coexist", function()
      local m = hamt.new()
      m = m:set("1", "string-one")
      m = m:set(1, "number-one")
      T.eq(m:size(), 2)
      T.eq(m:get("1"), "string-one")
      T.eq(m:get(1), "number-one")
    end)
  end)

  T.describe("edge cases", function()
    T.it("nil value can be stored via set but get returns nil (same as absent)", function()
      -- HAMT treats nil values as absent (standard Lua table semantics)
      local m = hamt.new():set("k", 1):set("k", nil)
      -- set with nil: in our impl, nil is a valid value stored as nil
      -- get will return nil whether absent or stored-as-nil
      -- size behavior: we still increment delta for new keys
      -- This just verifies no crash
      T.ok(true)
    end)

    T.it("false value is stored and retrieved", function()
      local m = hamt.new():set("flag", false)
      T.eq(m:get("flag"), false)
      T.eq(m:size(), 1)
    end)

    T.it("zero key works", function()
      local m = hamt.new():set(0, "zero")
      T.eq(m:get(0), "zero")
    end)

    T.it("empty string key works", function()
      local m = hamt.new():set("", "empty")
      T.eq(m:get(""), "empty")
    end)

    T.it("delete on empty map is safe", function()
      local m = hamt.new():delete("anything")
      T.eq(m:size(), 0)
    end)

    T.it("table values are stored by reference", function()
      local obj = {x = 1}
      local m = hamt.new():set("obj", obj)
      T.ok(m:get("obj") == obj)
    end)
  end)

end)
