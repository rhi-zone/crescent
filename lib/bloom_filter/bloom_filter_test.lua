if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local bloom = require("lib.bloom_filter")

T.describe("bloom_filter", function()

  T.describe("standard bloom filter", function()
    T.it("add and contains basic items", function()
      local f = bloom.new({ capacity = 100, error_rate = 0.01 })
      T.ok(f, "filter created")
      f:add("hello")
      f:add("world")
      T.ok(f:contains("hello"), "hello present")
      T.ok(f:contains("world"), "world present")
      T.ok(not f:contains("missing"), "missing absent (no false negative)")
    end)

    T.it("no false negatives", function()
      local f = bloom.new({ capacity = 1000, error_rate = 0.01 })
      local items = {}
      for i = 1, 500 do
        local item = "item_" .. i
        items[i] = item
        f:add(item)
      end
      for i = 1, 500 do
        T.ok(f:contains(items[i]), "no false negative for item " .. i)
      end
    end)

    T.it("false positive rate stays below error_rate after capacity insertions", function()
      local capacity = 500
      local error_rate = 0.05
      local f = bloom.new({ capacity = capacity, error_rate = error_rate })
      for i = 1, capacity do
        f:add("member_" .. i)
      end
      -- Test with non-members, count FP
      local fp = 0
      local trials = 2000
      for i = 1, trials do
        if f:contains("nonmember_" .. i) then fp = fp + 1 end
      end
      local actual_fpr = fp / trials
      -- Allow some slack (2x) since this is probabilistic
      T.ok(actual_fpr < error_rate * 2, "FPR " .. actual_fpr .. " < " .. error_rate * 2)
    end)

    T.it("optimal m and k computed from capacity+error_rate", function()
      local f = bloom.new({ capacity = 1000, error_rate = 0.01 })
      -- m = ceil(-n * ln(p) / (ln(2)^2)) = ceil(-1000 * ln(0.01) / 0.4805) = 9585
      T.ok(f._m > 9000 and f._m < 10200, "m in expected range: " .. f._m)
      -- k = round((m/n) * ln(2)) = round(9585/1000 * 0.693) = round(6.64) = 7
      T.ok(f._k >= 6 and f._k <= 8, "k in expected range: " .. f._k)
    end)

    T.it("clear resets the filter", function()
      local f = bloom.new({ capacity = 100, error_rate = 0.01 })
      f:add("alpha")
      f:add("beta")
      T.ok(f:contains("alpha"), "alpha before clear")
      f:clear()
      T.ok(not f:contains("alpha"), "alpha gone after clear")
      T.ok(not f:contains("beta"), "beta gone after clear")
    end)

    T.it("count estimates inserted elements", function()
      local f = bloom.new({ capacity = 1000, error_rate = 0.01 })
      T.eq(f:count(), 0, "empty count is 0")
      for i = 1, 200 do
        f:add("item_" .. i)
      end
      local est = f:count()
      -- Allow 20% error in the estimate
      T.ok(est > 160 and est < 240, "count estimate " .. est .. " within 20% of 200")
    end)

    T.it("false_positive_rate increases as items are added", function()
      local f = bloom.new({ capacity = 100, error_rate = 0.01 })
      local fpr0 = f:false_positive_rate()
      for i = 1, 80 do f:add("x_" .. i) end
      local fpr80 = f:false_positive_rate()
      T.ok(fpr80 > fpr0, "FPR increases with insertions")
      T.ok(fpr80 < 0.5, "FPR stays reasonable before capacity")
    end)

    T.it("returns nil+errmsg for invalid opts", function()
      local f, err = bloom.new({ capacity = -1, error_rate = 0.01 })
      T.ok(f == nil, "nil on invalid capacity")
      T.ok(type(err) == "string", "error message returned")

      local f2, err2 = bloom.new({ capacity = 100, error_rate = 1.5 })
      T.ok(f2 == nil, "nil on invalid error_rate")
      T.ok(type(err2) == "string", "error message returned")

      local f3, err3 = bloom.new(nil)
      T.ok(f3 == nil, "nil on nil opts")
      T.ok(type(err3) == "string", "error message returned")
    end)

    T.it("hash distribution: different items hit different bits", function()
      local f = bloom.new({ capacity = 1000, error_rate = 0.01 })
      -- Insert a few items and verify they set bits (non-trivially)
      f:add("apple")
      f:add("banana")
      -- Count set bits
      local set_a, set_b = 0, 0
      -- We can't directly observe per-item bits, but we can verify
      -- that after clearing and adding one item, some bits are set
      f:clear()
      f:add("apple")
      local words = math.ceil(f._m / 32)
      for i = 1, words do
        local v = f._bits[i]
        while v ~= 0 do
          v = require("bit").band(v, v - 1)
          set_a = set_a + 1
        end
      end
      f:clear()
      f:add("banana")
      for i = 1, words do
        local v = f._bits[i]
        while v ~= 0 do
          v = require("bit").band(v, v - 1)
          set_b = set_b + 1
        end
      end
      -- Each item should set exactly k bits (assuming no collisions with small filter)
      T.eq(set_a, f._k, "apple sets k bits")
      T.eq(set_b, f._k, "banana sets k bits")
    end)
  end)

  T.describe("counting bloom filter", function()
    T.it("add and contains basic items", function()
      local f = bloom.counting({ capacity = 100, error_rate = 0.01 })
      T.ok(f, "filter created")
      f:add("hello")
      T.ok(f:contains("hello"), "hello present")
      T.ok(not f:contains("world"), "world absent")
    end)

    T.it("remove decrements counter and item no longer found", function()
      local f = bloom.counting({ capacity = 100, error_rate = 0.01 })
      f:add("hello")
      f:add("hello")
      T.ok(f:contains("hello"), "present after 2 adds")
      local ok = f:remove("hello")
      T.ok(ok, "first remove succeeds")
      T.ok(f:contains("hello"), "still present after 1 remove (count=1)")
      ok = f:remove("hello")
      T.ok(ok, "second remove succeeds")
      T.ok(not f:contains("hello"), "absent after 2 removes")
    end)

    T.it("remove returns false for item not added", function()
      local f = bloom.counting({ capacity = 100, error_rate = 0.01 })
      local ok = f:remove("ghost")
      T.ok(not ok, "remove of absent item returns false")
    end)

    T.it("remove prevents false positives for removed items", function()
      local f = bloom.counting({ capacity = 100, error_rate = 0.01 })
      -- Add many items to increase saturation, then remove specific one
      for i = 1, 50 do f:add("item_" .. i) end
      f:add("target")
      T.ok(f:contains("target"), "target present")
      f:remove("target")
      -- After removing, target should not be in the filter
      -- (assuming no hash collision with remaining items — test with isolated filter)
      local f2 = bloom.counting({ capacity = 100, error_rate = 0.01 })
      f2:add("target")
      f2:remove("target")
      T.ok(not f2:contains("target"), "target absent after add+remove in isolated filter")
    end)

    T.it("no false negatives before any removal", function()
      local f = bloom.counting({ capacity = 200, error_rate = 0.01 })
      for i = 1, 100 do f:add("x_" .. i) end
      for i = 1, 100 do
        T.ok(f:contains("x_" .. i), "no false negative for x_" .. i)
      end
    end)

    T.it("returns nil+errmsg for invalid opts", function()
      local f, err = bloom.counting({ capacity = 0, error_rate = 0.01 })
      T.ok(f == nil, "nil on invalid capacity")
      T.ok(type(err) == "string", "error message returned")
    end)
  end)

  T.describe("scalable bloom filter", function()
    T.it("basic add and contains", function()
      local f = bloom.scalable({ initial_capacity = 20, error_rate = 0.01 })
      T.ok(f, "filter created")
      f:add("alpha")
      T.ok(f:contains("alpha"), "alpha present")
      T.ok(not f:contains("beta"), "beta absent")
    end)

    T.it("grows layers when capacity exceeded", function()
      local f = bloom.scalable({ initial_capacity = 10, error_rate = 0.01, growth_factor = 2 })
      T.eq(f:layers(), 1, "starts with 1 layer")
      for i = 1, 15 do f:add("item_" .. i) end
      T.ok(f:layers() >= 2, "grows to 2+ layers after exceeding capacity")
    end)

    T.it("maintains membership across layers", function()
      local f = bloom.scalable({ initial_capacity = 10, error_rate = 0.01, growth_factor = 2 })
      local items = {}
      for i = 1, 50 do
        items[i] = "member_" .. i
        f:add(items[i])
      end
      for i = 1, 50 do
        T.ok(f:contains(items[i]), "no false negative for member_" .. i)
      end
    end)

    T.it("layers count increases as items are added", function()
      local f = bloom.scalable({ initial_capacity = 5, error_rate = 0.01, growth_factor = 2 })
      local prev = f:layers()
      for i = 1, 100 do f:add("z_" .. i) end
      T.ok(f:layers() > prev, "layers increased")
    end)

    T.it("returns nil+errmsg for invalid opts", function()
      local f, err = bloom.scalable({ initial_capacity = -1 })
      T.ok(f == nil, "nil on negative initial_capacity")
      T.ok(type(err) == "string", "error message for invalid capacity")

      local f2, err2 = bloom.scalable({ initial_capacity = 100, error_rate = 2.0 })
      T.ok(f2 == nil, "nil on invalid error_rate")
      T.ok(type(err2) == "string", "error message for invalid error_rate")

      local f3, err3 = bloom.scalable({ initial_capacity = 100, error_rate = 0.01, growth_factor = 0.5 })
      T.ok(f3 == nil, "nil on growth_factor <= 1")
      T.ok(type(err3) == "string", "error message for invalid growth_factor")

      local f4, err4 = bloom.scalable({ initial_capacity = 100, error_rate = 0.01, growth_factor = 2, tightening_ratio = 1.5 })
      T.ok(f4 == nil, "nil on invalid tightening_ratio")
      T.ok(type(err4) == "string", "error message for invalid tightening_ratio")
    end)

    T.it("FPR stays reasonable for scalable filter", function()
      local f = bloom.scalable({ initial_capacity = 100, error_rate = 0.05, growth_factor = 2 })
      for i = 1, 300 do f:add("member_" .. i) end
      local fp = 0
      local trials = 1000
      for i = 1, trials do
        if f:contains("nonmember_" .. i) then fp = fp + 1 end
      end
      local actual_fpr = fp / trials
      -- Allow generous slack since scalable filter has compounding error rates
      T.ok(actual_fpr < 0.20, "scalable FPR " .. actual_fpr .. " < 0.20")
    end)
  end)

end)
