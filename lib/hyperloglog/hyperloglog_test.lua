-- lib/hyperloglog/hyperloglog_test.lua
-- Tests for HyperLogLog probabilistic cardinality estimator.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local HLL = require("lib.hyperloglog")

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

T.describe("hyperloglog.new", function()
  T.it("creates with default precision 12", function()
    local h, err = HLL.new()
    T.ok(h ~= nil, "h is non-nil")
    T.ok(err == nil, "no error")
    T.eq(h:precision(), 12)
    T.eq(h:registers(), 4096)
  end)

  T.it("creates with explicit precision 10", function()
    local h = HLL.new(10)
    T.eq(h:precision(), 10)
    T.eq(h:registers(), 1024)
  end)

  T.it("creates with precision 4 (minimum)", function()
    local h, err = HLL.new(4)
    T.ok(h ~= nil)
    T.ok(err == nil)
    T.eq(h:precision(), 4)
    T.eq(h:registers(), 16)
  end)

  T.it("creates with precision 16 (maximum)", function()
    local h, err = HLL.new(16)
    T.ok(h ~= nil)
    T.ok(err == nil)
    T.eq(h:precision(), 16)
    T.eq(h:registers(), 65536)
  end)

  T.it("rejects precision below 4", function()
    local h, err = HLL.new(3)
    T.ok(h == nil)
    T.ok(err ~= nil)
  end)

  T.it("rejects precision above 16", function()
    local h, err = HLL.new(17)
    T.ok(h == nil)
    T.ok(err ~= nil)
  end)

  T.it("rejects non-numeric precision", function()
    local h, err = HLL.new("bad")
    T.ok(h == nil)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Empty estimator
-- ---------------------------------------------------------------------------

T.describe("empty HLL", function()
  T.it("count() is close to 0 with no elements", function()
    local h = HLL.new(12)
    local c = h:count()
    -- Without any elements the linear counting formula returns 0
    T.ok(c >= 0 and c <= 10, "count near 0, got " .. c)
  end)

  T.it("memory() returns positive value", function()
    local h = HLL.new(12)
    T.ok(h:memory() > 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- Single element
-- ---------------------------------------------------------------------------

T.describe("single element", function()
  T.it("count() ≈ 1 after adding one element (small range correction)", function()
    local h = HLL.new(12)
    h:add("hello")
    local c = h:count()
    -- With small-range correction, should be exactly 1 or very close
    T.ok(c >= 1 and c <= 5, "count ≈ 1, got " .. c)
  end)

  T.it("same element added many times counts as 1", function()
    local h = HLL.new(12)
    for _ = 1, 1000 do h:add("duplicate") end
    local c = h:count()
    T.ok(c >= 1 and c <= 5, "dedup count ≈ 1, got " .. c)
  end)

  T.it("numbers are coerced to string for hashing", function()
    local h = HLL.new(12)
    h:add(42)
    h:add(42)
    h:add(42)
    local c = h:count()
    T.ok(c >= 1 and c <= 5, "number element count ≈ 1, got " .. c)
  end)
end)

-- ---------------------------------------------------------------------------
-- 100 distinct elements
-- ---------------------------------------------------------------------------

T.describe("100 distinct elements", function()
  T.it("count() within 10% of 100", function()
    local h = HLL.new(12)
    for i = 1, 100 do h:add("item_" .. i) end
    local c = h:count()
    -- Allow ±10%
    T.ok(math.abs(c - 100) / 100 < 0.10,
      "count within 10% of 100, got " .. c)
  end)

  T.it("precision 14 gives tighter estimate for 100 elements", function()
    local h = HLL.new(14)
    for i = 1, 100 do h:add("item_" .. i) end
    local c = h:count()
    T.ok(math.abs(c - 100) / 100 < 0.15,
      "count within 15% of 100 with b=14, got " .. c)
  end)
end)

-- ---------------------------------------------------------------------------
-- 1000 distinct elements
-- ---------------------------------------------------------------------------

T.describe("1000 distinct elements", function()
  T.it("count() within 5% of 1000 (precision 12)", function()
    local h = HLL.new(12)
    for i = 1, 1000 do h:add("elem_" .. i) end
    local c = h:count()
    T.ok(math.abs(c - 1000) / 1000 < 0.05,
      "count within 5% of 1000, got " .. c)
  end)

  T.it("count() within 5% of 1000 (precision 14)", function()
    local h = HLL.new(14)
    for i = 1, 1000 do h:add("elem_" .. i) end
    local c = h:count()
    T.ok(math.abs(c - 1000) / 1000 < 0.05,
      "count within 5% of 1000 b=14, got " .. c)
  end)

  T.it("same 1000 elements twice still ≈ 1000", function()
    local h = HLL.new(12)
    for _ = 1, 2 do
      for i = 1, 1000 do h:add("elem_" .. i) end
    end
    local c = h:count()
    T.ok(math.abs(c - 1000) / 1000 < 0.05,
      "idempotent re-add stays ≈ 1000, got " .. c)
  end)
end)

-- ---------------------------------------------------------------------------
-- Larger cardinality
-- ---------------------------------------------------------------------------

T.describe("10000 distinct elements", function()
  T.it("count() within 5% of 10000 (precision 14)", function()
    local h = HLL.new(14)
    for i = 1, 10000 do h:add("x_" .. i) end
    local c = h:count()
    T.ok(math.abs(c - 10000) / 10000 < 0.05,
      "count within 5% of 10000, got " .. c)
  end)
end)

-- ---------------------------------------------------------------------------
-- Merge
-- ---------------------------------------------------------------------------

T.describe("merge", function()
  T.it("merged HLL counts union of two disjoint sets", function()
    local h1 = HLL.new(12)
    local h2 = HLL.new(12)
    for i = 1, 500   do h1:add("a_" .. i) end
    for i = 501, 1000 do h2:add("a_" .. i) end
    local merged, err = h1:merge(h2)
    T.ok(err == nil, "no merge error")
    T.ok(merged ~= nil)
    local c = h1:count()  -- merge is in-place, h1 now holds union
    T.ok(math.abs(c - 1000) / 1000 < 0.10,
      "merged union within 10% of 1000, got " .. c)
  end)

  T.it("merge with overlapping sets", function()
    local h1 = HLL.new(12)
    local h2 = HLL.new(12)
    for i = 1, 750 do h1:add("b_" .. i) end
    for i = 250, 1000 do h2:add("b_" .. i) end
    h1:merge(h2)
    local c = h1:count()
    -- union is b_1..b_1000 = 1000
    T.ok(math.abs(c - 1000) / 1000 < 0.10,
      "overlapping merge within 10% of 1000, got " .. c)
  end)

  T.it("merge returns nil+err for different precision", function()
    local h1 = HLL.new(10)
    local h2 = HLL.new(12)
    local result, err = h1:merge(h2)
    T.ok(result == nil)
    T.ok(err ~= nil)
    T.ok(err:find("precision mismatch") ~= nil)
  end)

  T.it("merge is non-destructive to other", function()
    local h1 = HLL.new(12)
    local h2 = HLL.new(12)
    for i = 1, 200 do h1:add("c_" .. i) end
    for i = 201, 400 do h2:add("c_" .. i) end
    h1:merge(h2)
    -- h2 should still count its own elements
    local c2 = h2:count()
    T.ok(math.abs(c2 - 200) / 200 < 0.15,
      "h2 unchanged after merge, got " .. c2)
  end)
end)

-- ---------------------------------------------------------------------------
-- Serialize / deserialize
-- ---------------------------------------------------------------------------

T.describe("serialize/deserialize", function()
  T.it("round-trip preserves empty HLL", function()
    local h = HLL.new(12)
    local s = h:serialize()
    T.ok(type(s) == "string")
    -- 1 header byte + 4096 register bytes
    T.eq(#s, 4097)
    local h2, err = HLL.deserialize(s)
    T.ok(err == nil)
    T.ok(h2 ~= nil)
    T.eq(h2:precision(), 12)
    T.eq(h2:count(), h:count())
  end)

  T.it("round-trip preserves populated HLL", function()
    local h = HLL.new(12)
    for i = 1, 500 do h:add("s_" .. i) end
    local s = h:serialize()
    local h2, err = HLL.deserialize(s)
    T.ok(err == nil)
    T.eq(h2:count(), h:count())
  end)

  T.it("deserialize returns nil+err for short string", function()
    local h, err = HLL.deserialize("")
    T.ok(h == nil)
    T.ok(err ~= nil)
  end)

  T.it("deserialize returns nil+err for wrong length", function()
    -- precision 12 needs 4097 bytes; give 10
    local s = string.char(12) .. string.rep("\0", 9)
    local h, err = HLL.deserialize(s)
    T.ok(h == nil)
    T.ok(err ~= nil)
  end)

  T.it("serialize with precision 10", function()
    local h = HLL.new(10)
    for i = 1, 300 do h:add("t_" .. i) end
    local s = h:serialize()
    -- 1 + 1024 bytes
    T.eq(#s, 1025)
    local h2 = HLL.deserialize(s)
    T.eq(h2:precision(), 10)
    T.eq(h2:count(), h:count())
  end)
end)

-- ---------------------------------------------------------------------------
-- Metadata accessors
-- ---------------------------------------------------------------------------

T.describe("metadata accessors", function()
  T.it("precision() returns b", function()
    T.eq(HLL.new(10):precision(), 10)
    T.eq(HLL.new(14):precision(), 14)
  end)

  T.it("registers() returns 2^b", function()
    T.eq(HLL.new(10):registers(), 1024)
    T.eq(HLL.new(12):registers(), 4096)
    T.eq(HLL.new(14):registers(), 16384)
  end)

  T.it("memory() grows with precision", function()
    local m10 = HLL.new(10):memory()
    local m12 = HLL.new(12):memory()
    T.ok(m12 > m10, "higher precision uses more memory")
  end)
end)
