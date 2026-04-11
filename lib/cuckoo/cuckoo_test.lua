-- lib/cuckoo/cuckoo_test.lua
-- Tests for the cuckoo filter.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local C = require("lib.cuckoo")

-- ---------------------------------------------------------------------------
T.describe("cuckoo.new", function()
  T.it("creates a filter with correct capacity", function()
    local f, err = C.new(1000)
    T.ok(f, "filter created")
    T.ok(not err, "no error")
    T.ok(f:capacity() >= 1000, "capacity >= requested")
  end)

  T.it("rejects invalid capacity", function()
    local f, err = C.new(0)
    T.ok(not f)
    T.ok(err)
    local f2, err2 = C.new(-1)
    T.ok(not f2)
    T.ok(err2)
  end)

  T.it("rejects invalid fingerprint_bits", function()
    local f, err = C.new(100, { fingerprint_bits = 7 })
    T.ok(not f)
    T.ok(err)
  end)

  T.it("rejects invalid bucket_size", function()
    local f, err = C.new(100, { bucket_size = 3 })
    T.ok(not f)
    T.ok(err)
  end)

  T.it("has _tier = 'pure'", function()
    T.eq(C._tier, "pure")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("basic insert and contains", function()
  T.it("inserted items are contained", function()
    local f = C.new(500)
    T.ok(f:insert("hello"))
    T.ok(f:insert("world"))
    T.ok(f:contains("hello"))
    T.ok(f:contains("world"))
  end)

  T.it("uninserted items return false", function()
    local f = C.new(500)
    f:insert("apple")
    T.ok(not f:contains("orange"), "orange not in filter")
    T.ok(not f:contains("banana"), "banana not in filter")
    T.ok(not f:contains(""),       "empty string not in filter")
  end)

  T.it("accepts numeric keys (coerced to string)", function()
    local f = C.new(100)
    f:insert(42)
    T.ok(f:contains(42))
    T.ok(not f:contains(43))
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("delete", function()
  T.it("deleted item no longer contained", function()
    local f = C.new(500)
    f:insert("foo")
    T.ok(f:contains("foo"), "present before delete")
    local removed = f:delete("foo")
    T.ok(removed, "delete returned true")
    T.ok(not f:contains("foo"), "absent after delete")
  end)

  T.it("delete returns false for absent item", function()
    local f = C.new(500)
    f:insert("bar")
    T.ok(not f:delete("baz"), "baz never inserted")
  end)

  T.it("count decrements after delete", function()
    local f = C.new(500)
    f:insert("x")
    f:insert("y")
    T.eq(f:count(), 2)
    f:delete("x")
    T.eq(f:count(), 1)
  end)

  T.it("re-inserting after delete works", function()
    local f = C.new(500)
    f:insert("temp")
    f:delete("temp")
    T.ok(not f:contains("temp"))
    f:insert("temp")
    T.ok(f:contains("temp"))
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("count and stats", function()
  T.it("count starts at 0", function()
    local f = C.new(100)
    T.eq(f:count(), 0)
  end)

  T.it("count increments with inserts", function()
    local f = C.new(500)
    for i = 1, 20 do f:insert("item" .. i) end
    T.eq(f:count(), 20)
  end)

  T.it("load_factor is 0 initially", function()
    local f = C.new(100)
    T.eq(f:load_factor(), 0)
  end)

  T.it("load_factor increases with inserts", function()
    local f = C.new(100)
    local lf0 = f:load_factor()
    for i = 1, 50 do f:insert("item" .. i) end
    local lf1 = f:load_factor()
    T.ok(lf1 > lf0, "load factor increased")
    T.ok(lf1 <= 1.0, "load factor <= 1")
  end)

  T.it("false_positive_rate is positive and < 1", function()
    local f = C.new(1000)
    local fpr = f:false_positive_rate()
    T.ok(fpr > 0, "fpr > 0")
    T.ok(fpr < 1, "fpr < 1")
  end)

  T.it("false_positive_rate decreases with more fingerprint bits", function()
    local f8  = C.new(1000, { fingerprint_bits = 8  })
    local f16 = C.new(1000, { fingerprint_bits = 16 })
    T.ok(f16:false_positive_rate() < f8:false_positive_rate(),
         "16-bit fp has lower FPR than 8-bit fp")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("bulk insert (1000 items)", function()
  T.it("all inserted items are contained (no false negatives)", function()
    local f = C.new(2000)
    local keys = {}
    for i = 1, 1000 do
      local k = "key:" .. i
      keys[i] = k
      local ok, err = f:insert(k)
      T.ok(ok, "insert " .. i .. " succeeded: " .. tostring(err))
    end
    local missing = 0
    for i = 1, 1000 do
      if not f:contains(keys[i]) then missing = missing + 1 end
    end
    T.eq(missing, 0, "no false negatives")
  end)

  T.it("count matches number of inserts", function()
    local f = C.new(2000)
    for i = 1, 1000 do f:insert("k" .. i) end
    T.eq(f:count(), 1000)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("false positive rate", function()
  T.it("FPR < 2% for 1000 items with 8-bit fingerprints", function()
    local f = C.new(2000, { fingerprint_bits = 8 })
    for i = 1, 1000 do f:insert("present:" .. i) end

    local fp_count = 0
    local trials   = 1000
    for i = 1, trials do
      -- Use a different namespace to avoid overlap.
      if f:contains("absent:" .. i) then fp_count = fp_count + 1 end
    end
    local fpr = fp_count / trials
    T.ok(fpr < 0.02, "FPR " .. fpr .. " < 2%")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("serialize / deserialize", function()
  T.it("round-trips an empty filter", function()
    local f  = C.new(100)
    local s  = f:serialize()
    T.ok(type(s) == "string", "serialize returns string")
    T.ok(#s > 0, "non-empty string")
    local f2, err = C.deserialize(s)
    T.ok(f2, "deserialized: " .. tostring(err))
    T.eq(f2:count(), 0)
    T.eq(f2:capacity(), f:capacity())
  end)

  T.it("round-trips a populated filter", function()
    local f = C.new(500)
    local items = {}
    for i = 1, 200 do
      items[i] = "item:" .. i
      f:insert(items[i])
    end
    local s   = f:serialize()
    local f2, err = C.deserialize(s)
    T.ok(f2, "deserialized: " .. tostring(err))
    T.eq(f2:count(), 200, "count preserved")
    for i = 1, 200 do
      T.ok(f2:contains(items[i]), "item " .. i .. " still contained after deserialization")
    end
  end)

  T.it("round-trips with 16-bit fingerprints", function()
    local f = C.new(200, { fingerprint_bits = 16 })
    for i = 1, 50 do f:insert("v" .. i) end
    local s = f:serialize()
    local f2, err = C.deserialize(s)
    T.ok(f2, tostring(err))
    T.eq(f2:count(), 50)
    for i = 1, 50 do T.ok(f2:contains("v" .. i)) end
  end)

  T.it("rejects truncated data", function()
    local f  = C.new(100)
    local s  = f:serialize()
    local f2, err = C.deserialize(s:sub(1, 5))
    T.ok(not f2)
    T.ok(err)
  end)

  T.it("rejects empty string", function()
    local f2, err = C.deserialize("")
    T.ok(not f2)
    T.ok(err)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("overflow / full filter", function()
  T.it("returns 'full' error when filter is exhausted", function()
    -- Very small filter: 4 buckets * 4 slots = 16 slots, ~15 items before full.
    local f = C.new(8, { max_kicks = 200 })
    local inserted = 0
    local got_full = false
    for i = 1, 200 do
      local ok, err = f:insert("item" .. i)
      if ok then
        inserted = inserted + 1
      elseif err == "full" then
        got_full = true
        break
      end
    end
    T.ok(got_full, "got full error (inserted " .. inserted .. " before full)")
    T.ok(inserted > 0, "at least one item inserted before full")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("bucket_size=2 variant", function()
  T.it("works with bucket_size=2", function()
    local f = C.new(500, { bucket_size = 2 })
    for i = 1, 100 do f:insert("x" .. i) end
    local missing = 0
    for i = 1, 100 do
      if not f:contains("x" .. i) then missing = missing + 1 end
    end
    T.eq(missing, 0, "no false negatives with bucket_size=2")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("edge cases", function()
  T.it("insert and contains work on empty string key", function()
    local f = C.new(100)
    f:insert("")
    T.ok(f:contains(""))
  end)

  T.it("very long key", function()
    local f = C.new(100)
    local long = string.rep("a", 10000)
    f:insert(long)
    T.ok(f:contains(long))
    T.ok(not f:contains(string.rep("a", 9999)))
  end)

  T.it("many distinct small keys", function()
    local f = C.new(300)
    for i = 0, 255 do f:insert(string.char(i)) end
    for i = 0, 255 do
      T.ok(f:contains(string.char(i)), "char " .. i .. " present")
    end
  end)
end)
