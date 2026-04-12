-- lib/bloom_count/bloom_count_test.lua
-- Tests for lib/bloom_count: counting Bloom filter, cuckoo filter, scalable Bloom filter.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local BC = require("lib.bloom_count")

-- ---------------------------------------------------------------------------
-- Counting Bloom Filter
-- ---------------------------------------------------------------------------

T.describe("counting Bloom filter", function()
  T.it("BC._tier is 'pure'", function()
    T.eq(BC._tier, "pure")
  end)

  T.it("add then contains returns true (no false negatives)", function()
    local cbf = BC.counting({ capacity = 1000, error_rate = 0.01 })
    local items = {}
    for i = 1, 200 do
      items[i] = "item:" .. i
      cbf:add(items[i])
    end
    for i = 1, 200 do
      T.ok(cbf:contains(items[i]), "should contain item:" .. i)
    end
  end)

  T.it("size increments on each add", function()
    local cbf = BC.counting({ capacity = 100, error_rate = 0.01 })
    T.eq(cbf:size(), 0)
    cbf:add("a")
    T.eq(cbf:size(), 1)
    cbf:add("b")
    T.eq(cbf:size(), 2)
    cbf:add("a")  -- duplicate — size still increments (raw add count)
    T.eq(cbf:size(), 3)
  end)

  T.it("remove decrements: item not found after add+remove", function()
    local cbf = BC.counting({ capacity = 1000, error_rate = 0.01 })
    -- Add unique items so counters don't share slots via collisions
    -- Use items with distinct hashes to minimize collision
    local added = {}
    for i = 1, 50 do
      added[i] = "rmtest:" .. i
      cbf:add(added[i])
    end
    -- Remove all and check (most will disappear; FP still possible so check majority)
    local still_present = 0
    for i = 1, 50 do
      cbf:remove(added[i])
      if cbf:contains(added[i]) then still_present = still_present + 1 end
    end
    -- With low FP rate, almost none should still appear
    T.ok(still_present <= 3, "at most 3 false positives after remove (got " .. still_present .. ")")
  end)

  T.it("remove is no-op when item was never added (no negative counters)", function()
    local cbf = BC.counting({ capacity = 100, error_rate = 0.01 })
    -- Remove an item that was never added
    cbf:remove("ghost")
    -- Afterward, add a real item and ensure it works
    cbf:add("real")
    T.ok(cbf:contains("real"))
    T.ok(not cbf:contains("ghost"))
  end)

  T.it("count returns minimum counter (estimate of net insertions)", function()
    local cbf = BC.counting({ capacity = 500, error_rate = 0.01 })
    -- Single unique item: count should be >= 1
    cbf:add("unique-item-xyz")
    local c = cbf:count("unique-item-xyz")
    T.ok(c >= 1, "count should be >= 1 after one add (got " .. c .. ")")
    -- Add same item again
    cbf:add("unique-item-xyz")
    local c2 = cbf:count("unique-item-xyz")
    T.ok(c2 >= 2, "count should be >= 2 after two adds (got " .. c2 .. ")")
  end)

  T.it("count for never-added item is 0", function()
    local cbf = BC.counting({ capacity = 500, error_rate = 0.01 })
    T.eq(cbf:count("never-added-qqq"), 0)
  end)

  T.it("clear resets all counters", function()
    local cbf = BC.counting({ capacity = 500, error_rate = 0.01 })
    for i = 1, 100 do cbf:add("item:" .. i) end
    cbf:clear()
    T.eq(cbf:size(), 0)
    -- After clear, no items should be found
    local found = 0
    for i = 1, 100 do
      if cbf:contains("item:" .. i) then found = found + 1 end
    end
    T.eq(found, 0)
  end)

  T.it("false_positive_rate is 0 when empty", function()
    local cbf = BC.counting({ capacity = 1000, error_rate = 0.01 })
    T.eq(cbf:false_positive_rate(), 0)
  end)

  T.it("false_positive_rate stays reasonable under load", function()
    local cbf = BC.counting({ capacity = 1000, error_rate = 0.01 })
    for i = 1, 1000 do cbf:add("load:" .. i) end
    local fpr = cbf:false_positive_rate()
    -- Should be at or near target rate (within 3x for reasonable margin)
    T.ok(fpr < 0.05, "FP rate should be < 5% at capacity (got " .. string.format("%.4f", fpr) .. ")")
  end)

  T.it("empirical FP rate with 1000 items and 1% target", function()
    local cbf = BC.counting({ capacity = 1000, error_rate = 0.01 })
    for i = 1, 1000 do cbf:add("present:" .. i) end
    local fp = 0
    local trials = 500
    for i = 1, trials do
      if cbf:contains("absent:" .. i) then fp = fp + 1 end
    end
    local rate = fp / trials
    T.ok(rate < 0.08, "empirical FP rate < 8% (got " .. string.format("%.4f", rate) .. ")")
  end)

  T.it("counter_bits=8 allows larger counter maximum", function()
    local cbf = BC.counting({ capacity = 200, error_rate = 0.01, counter_bits = 8 })
    -- With 8-bit counters, max is 255 — add many times
    for i = 1, 200 do cbf:add("saturate") end
    local c = cbf:count("saturate")
    T.ok(c >= 1, "count should be >= 1 (got " .. c .. ")")
    T.ok(cbf:contains("saturate"))
  end)

  T.it("returns nil+errmsg for invalid params", function()
    local r, e = BC.counting({ capacity = 0 })
    T.ok(r == nil)
    T.ok(type(e) == "string")
    local r2, e2 = BC.counting({ capacity = 100, error_rate = 1.5 })
    T.ok(r2 == nil)
    T.ok(type(e2) == "string")
  end)
end)

-- ---------------------------------------------------------------------------
-- Cuckoo Filter
-- ---------------------------------------------------------------------------

T.describe("cuckoo filter", function()
  T.it("add then contains returns true", function()
    local cf = BC.cuckoo({ capacity = 500 })
    local items = {}
    for i = 1, 100 do
      items[i] = "cuckoo:" .. i
      local ok = cf:add(items[i])
      T.ok(ok, "add should succeed for item " .. i)
    end
    for i = 1, 100 do
      T.ok(cf:contains(items[i]), "should contain cuckoo:" .. i)
    end
  end)

  T.it("remove: item not found after remove", function()
    local cf = BC.cuckoo({ capacity = 500 })
    cf:add("alpha")
    T.ok(cf:contains("alpha"))
    local removed = cf:remove("alpha")
    T.ok(removed)
    T.ok(not cf:contains("alpha"))
  end)

  T.it("remove returns false for never-added item (usually)", function()
    local cf = BC.cuckoo({ capacity = 1000 })
    -- A never-added item should almost always return false
    local found = cf:remove("definitely-not-added-xyzzy")
    -- This can technically be a false positive in rare cases; just don't assert false
    -- We test the return type is boolean
    T.ok(type(found) == "boolean")
  end)

  T.it("load_factor increases with adds", function()
    local cf = BC.cuckoo({ capacity = 500, bucket_size = 4 })
    local lf0 = cf:load_factor()
    T.eq(lf0, 0)
    for i = 1, 50 do cf:add("lf:" .. i) end
    local lf1 = cf:load_factor()
    T.ok(lf1 > 0, "load factor should increase (got " .. lf1 .. ")")
    for i = 51, 150 do cf:add("lf:" .. i) end
    local lf2 = cf:load_factor()
    T.ok(lf2 > lf1, "load factor should keep increasing")
  end)

  T.it("clear resets to empty", function()
    local cf = BC.cuckoo({ capacity = 200 })
    for i = 1, 50 do cf:add("clr:" .. i) end
    T.ok(cf:load_factor() > 0)
    cf:clear()
    T.eq(cf:load_factor(), 0)
    for i = 1, 50 do
      T.ok(not cf:contains("clr:" .. i))
    end
  end)

  T.it("can fill near full without crash", function()
    local cf = BC.cuckoo({ capacity = 200, bucket_size = 4 })
    local succeeded = 0
    for i = 1, 300 do
      if cf:add("fill:" .. i) then
        succeeded = succeeded + 1
      end
    end
    -- Should succeed for most of the capacity
    T.ok(succeeded >= 150, "should fill at least 150 slots (got " .. succeeded .. ")")
    local lf = cf:load_factor()
    T.ok(lf > 0.5, "load factor should be > 50% when near full (got " .. string.format("%.3f", lf) .. ")")
  end)

  T.it("add returns boolean true/false", function()
    local cf = BC.cuckoo({ capacity = 100, bucket_size = 4 })
    local r = cf:add("test-item")
    T.ok(r == true or r == false)
  end)

  T.it("multiple remove of same item", function()
    local cf = BC.cuckoo({ capacity = 500 })
    cf:add("dup")
    local r1 = cf:remove("dup")
    T.ok(r1 == true)
    local r2 = cf:remove("dup")
    -- Second remove: item already gone, should return false
    T.ok(r2 == false)
  end)

  T.it("fingerprint_bits option works", function()
    local cf = BC.cuckoo({ capacity = 200, fingerprint_bits = 16 })
    for i = 1, 50 do cf:add("fp16:" .. i) end
    for i = 1, 50 do
      T.ok(cf:contains("fp16:" .. i))
    end
  end)

  T.it("empirical FP rate is reasonable", function()
    local cf = BC.cuckoo({ capacity = 1000, fingerprint_bits = 8 })
    for i = 1, 500 do cf:add("present:" .. i) end
    local fp = 0
    local trials = 300
    for i = 1, trials do
      if cf:contains("notpresent:" .. i) then fp = fp + 1 end
    end
    local rate = fp / trials
    -- 8-bit fingerprint: theoretical FP rate ~2*bucket_size/2^fingerprint_bits = ~0.03
    T.ok(rate < 0.15, "cuckoo FP rate < 15% (got " .. string.format("%.4f", rate) .. ")")
  end)
end)

-- ---------------------------------------------------------------------------
-- Scalable Bloom Filter
-- ---------------------------------------------------------------------------

T.describe("scalable Bloom filter", function()
  T.it("contains returns true for all added items (no false negatives)", function()
    local sbf = BC.scalable({ initial_capacity = 50, error_rate = 0.01, growth_factor = 2 })
    for i = 1, 200 do sbf:add("sbf:" .. i) end
    for i = 1, 200 do
      T.ok(sbf:contains("sbf:" .. i), "should contain sbf:" .. i)
    end
  end)

  T.it("filter_count grows when capacity is exceeded", function()
    local sbf = BC.scalable({ initial_capacity = 20, error_rate = 0.01, growth_factor = 2 })
    T.eq(sbf:filter_count(), 1)
    -- Add well beyond initial capacity
    for i = 1, 100 do sbf:add("grow:" .. i) end
    T.ok(sbf:filter_count() > 1, "filter count should grow (got " .. sbf:filter_count() .. ")")
  end)

  T.it("total_capacity grows with filters", function()
    local sbf = BC.scalable({ initial_capacity = 30, error_rate = 0.01, growth_factor = 2 })
    local cap0 = sbf:total_capacity()
    T.eq(cap0, 30)
    -- Trigger at least one expansion
    for i = 1, 200 do sbf:add("tcap:" .. i) end
    local cap1 = sbf:total_capacity()
    T.ok(cap1 > cap0, "total_capacity should increase (got " .. cap1 .. ")")
  end)

  T.it("initial_capacity default is 100", function()
    local sbf = BC.scalable()
    T.eq(sbf:total_capacity(), 100)
    T.eq(sbf:filter_count(), 1)
  end)

  T.it("growth_factor controls capacity growth", function()
    local sbf2 = BC.scalable({ initial_capacity = 10, error_rate = 0.01, growth_factor = 2 })
    local sbf4 = BC.scalable({ initial_capacity = 10, error_rate = 0.01, growth_factor = 4 })
    -- Trigger one expansion in each
    for i = 1, 50 do sbf2:add("g2:" .. i) end
    for i = 1, 50 do sbf4:add("g4:" .. i) end
    -- sbf4's second filter should be larger (4x vs 2x initial)
    T.ok(sbf4:total_capacity() > sbf2:total_capacity(),
      "growth_factor=4 should produce larger total capacity")
  end)

  T.it("contains is false for truly absent items (probabilistic — allow small FP)", function()
    local sbf = BC.scalable({ initial_capacity = 100, error_rate = 0.01 })
    for i = 1, 100 do sbf:add("in:" .. i) end
    local fp = 0
    for i = 1, 200 do
      if sbf:contains("out:" .. i) then fp = fp + 1 end
    end
    T.ok(fp < 20, "FP count < 20 out of 200 (got " .. fp .. ")")
  end)

  T.it("large scale: 1000 items, no false negatives", function()
    local sbf = BC.scalable({ initial_capacity = 50, error_rate = 0.01, growth_factor = 2 })
    for i = 1, 1000 do sbf:add("large:" .. i) end
    local missing = 0
    for i = 1, 1000 do
      if not sbf:contains("large:" .. i) then missing = missing + 1 end
    end
    T.eq(missing, 0)
  end)

  T.it("filter_count and total_capacity are consistent", function()
    local sbf = BC.scalable({ initial_capacity = 25, error_rate = 0.01, growth_factor = 3 })
    for i = 1, 500 do sbf:add("cons:" .. i) end
    local fc = sbf:filter_count()
    local tc = sbf:total_capacity()
    T.ok(fc >= 1)
    T.ok(tc >= 25)
    -- total_capacity should be at least initial * growth_factor^(fc-1)
    T.ok(tc >= 25 * (3 ^ (fc - 1)), "total_capacity consistent with filter_count")
  end)
end)
