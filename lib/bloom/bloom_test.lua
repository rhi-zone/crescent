-- lib/bloom/bloom_test.lua
-- Tests for the Bloom filter library.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local bloom = require("lib.bloom")

-- ---------------------------------------------------------------------------
-- Helper
-- ---------------------------------------------------------------------------

local function range(a, b)
  local t = {}
  for i = a, b do t[#t + 1] = i end
  return t
end

-- ---------------------------------------------------------------------------
-- Creation from capacity + FP rate
-- ---------------------------------------------------------------------------

T.describe("bloom.new", function()
  T.it("returns a filter with reasonable m and k", function()
    local b = bloom.new(1000, 0.01)
    T.ok(b, "filter created")
    -- m = -1000 * ln(0.01) / (ln 2)^2 ≈ 9585  (round up)
    T.ok(b:capacity() >= 9000, "m is at least 9000")
    T.ok(b:capacity() <= 11000, "m is at most 11000")
    -- k = (m/1000) * ln(2) ≈ 7
    T.ok(b:num_hashes() >= 5, "k >= 5")
    T.ok(b:num_hashes() <= 10, "k <= 10")
  end)

  T.it("returns a filter for 500 items at 5% FP", function()
    local b = bloom.new(500, 0.05)
    T.ok(b, "filter created")
    T.ok(b:capacity() > 0, "m > 0")
    T.ok(b:num_hashes() >= 1, "k >= 1")
  end)

  T.it("returns nil, errmsg for invalid p=0", function()
    local b, err = bloom.new(1000, 0)
    T.fail(b, "should fail")
    T.ok(err, "has error message")
  end)

  T.it("returns nil, errmsg for invalid p=1", function()
    local b, err = bloom.new(1000, 1)
    T.fail(b, "should fail")
    T.ok(err, "has error message")
  end)

  T.it("returns nil, errmsg for n=0", function()
    local b, err = bloom.new(0, 0.01)
    T.fail(b, "should fail")
    T.ok(err, "has error message")
  end)
end)

-- ---------------------------------------------------------------------------
-- new_raw
-- ---------------------------------------------------------------------------

T.describe("bloom.new_raw", function()
  T.it("creates a filter with exact m and k", function()
    local b = bloom.new_raw(8192, 3)
    T.eq(b:capacity(), 8192)
    T.eq(b:num_hashes(), 3)
  end)
end)

-- ---------------------------------------------------------------------------
-- add / has — no false negatives
-- ---------------------------------------------------------------------------

T.describe("add/has", function()
  T.it("all added strings are present (no false negatives)", function()
    local b = bloom.new(200, 0.01)
    local items = {}
    for i = 1, 200 do
      items[i] = "item-" .. i
      b:add(items[i])
    end
    for i = 1, 200 do
      T.ok(b:has(items[i]), "item-" .. i .. " must be present")
    end
  end)

  T.it("coerces numbers to strings", function()
    local b = bloom.new(100, 0.01)
    b:add(42)
    T.ok(b:has(42), "has(42) true")
    T.ok(b:has("42"), "has('42') true (same key)")
  end)

  T.it("empty filter has() returns false for arbitrary keys", function()
    local b = bloom.new(100, 0.01)
    T.fail(b:has("anything"), "empty filter: has returns false")
    T.fail(b:has("foo"), "empty filter: has returns false")
  end)
end)

-- ---------------------------------------------------------------------------
-- False positive rate check
-- ---------------------------------------------------------------------------

T.describe("false positive rate", function()
  T.it("FP rate under 5% when adding 1000 items (target 1%)", function()
    local b = bloom.new(1000, 0.01)
    for i = 1, 1000 do b:add("member-" .. i) end
    local fp = 0
    local trials = 1000
    for i = 1, trials do
      -- Keys "nonmember-i" are disjoint from "member-i"
      if b:has("nonmember-" .. i) then fp = fp + 1 end
    end
    local rate = fp / trials
    -- Allow up to 5% (target is 1% — we give generous headroom for small-sample variance)
    T.ok(rate <= 0.05, "FP rate " .. rate .. " <= 0.05")
  end)
end)

-- ---------------------------------------------------------------------------
-- count
-- ---------------------------------------------------------------------------

T.describe("count", function()
  T.it("empty filter estimates 0", function()
    local b = bloom.new(1000, 0.01)
    T.eq(b:count(), 0)
  end)

  T.it("estimated count is in the right ballpark after 500 inserts", function()
    local b = bloom.new(1000, 0.01)
    for i = 1, 500 do b:add("x-" .. i) end
    local est = b:count()
    -- Should be within 20% of 500
    T.ok(est >= 400, "count estimate >= 400, got " .. est)
    T.ok(est <= 600, "count estimate <= 600, got " .. est)
  end)
end)

-- ---------------------------------------------------------------------------
-- false_positive_rate
-- ---------------------------------------------------------------------------

T.describe("false_positive_rate", function()
  T.it("returns 0 for empty filter", function()
    local b = bloom.new(1000, 0.01)
    T.eq(b:false_positive_rate(), 0)
  end)

  T.it("returns a small value after moderate fill", function()
    local b = bloom.new(1000, 0.01)
    for i = 1, 300 do b:add("y-" .. i) end
    local r = b:false_positive_rate()
    T.ok(r > 0 and r < 0.05, "FP rate in (0, 0.05), got " .. r)
  end)
end)

-- ---------------------------------------------------------------------------
-- clear
-- ---------------------------------------------------------------------------

T.describe("clear", function()
  T.it("after clear, previously added items are gone", function()
    local b = bloom.new(100, 0.01)
    b:add("a")
    b:add("b")
    b:clear()
    -- After clear, has() should return false for previously added items
    -- (may still get lucky collisions but extremely unlikely for a 9k+ bit array)
    T.fail(b:has("a"), "a gone after clear")
    T.fail(b:has("b"), "b gone after clear")
  end)

  T.it("can add again after clear", function()
    local b = bloom.new(100, 0.01)
    b:add("x")
    b:clear()
    b:add("y")
    T.ok(b:has("y"), "y present after clear+add")
    T.fail(b:has("x"), "x gone after clear")
  end)
end)

-- ---------------------------------------------------------------------------
-- union / intersection
-- ---------------------------------------------------------------------------

T.describe("union", function()
  T.it("union contains items from both filters", function()
    local b1 = bloom.new_raw(1024, 4)
    local b2 = bloom.new_raw(1024, 4)
    b1:add("alpha")
    b2:add("beta")
    local u = b1:union(b2)
    T.ok(u:has("alpha"), "union has alpha")
    T.ok(u:has("beta"), "union has beta")
  end)

  T.it("returns nil,err for incompatible filters", function()
    local b1 = bloom.new_raw(1024, 4)
    local b2 = bloom.new_raw(2048, 4)
    local u, err = b1:union(b2)
    T.fail(u, "should fail")
    T.ok(err, "has error")
  end)

  T.it("union does not modify originals", function()
    local b1 = bloom.new_raw(1024, 4)
    local b2 = bloom.new_raw(1024, 4)
    b1:add("only-in-b1")
    b1:union(b2)
    T.fail(b2:has("only-in-b1"), "b2 unchanged")
  end)
end)

T.describe("intersection", function()
  T.it("intersection contains only items in both filters", function()
    local b1 = bloom.new_raw(1024, 4)
    local b2 = bloom.new_raw(1024, 4)
    -- Add "shared" to both
    b1:add("shared")
    b2:add("shared")
    -- Add exclusives
    b1:add("only1")
    b2:add("only2")
    local ix = b1:intersection(b2)
    T.ok(ix:has("shared"), "intersection has shared item")
    -- "only1" is not in b2, so its bits may be cleared → likely absent
    T.fail(ix:has("only1"), "only1 absent from intersection")
    T.fail(ix:has("only2"), "only2 absent from intersection")
  end)

  T.it("returns nil,err for incompatible filters", function()
    local b1 = bloom.new_raw(1024, 4)
    local b2 = bloom.new_raw(512, 4)
    local ix, err = b1:intersection(b2)
    T.fail(ix, "should fail")
    T.ok(err, "has error")
  end)
end)

-- ---------------------------------------------------------------------------
-- Serialization
-- ---------------------------------------------------------------------------

T.describe("to_string / from_string", function()
  T.it("round-trip preserves bit array exactly", function()
    local b = bloom.new(200, 0.01)
    for i = 1, 100 do b:add("serial-" .. i) end
    local s = b:to_string()
    T.ok(type(s) == "string", "to_string returns string")
    -- Format: 4-byte m header + nwords * 4 bytes
    local nwords = math.ceil(b:capacity() / 32)
    T.eq(#s, 4 + nwords * 4, "serialized length correct")

    local b2 = bloom.from_string(s, b:num_hashes())
    T.ok(b2, "from_string succeeded")
    T.eq(b2:capacity(), b:capacity(), "m preserved")
    T.eq(b2:num_hashes(), b:num_hashes(), "k preserved")
    -- All added items still present after round-trip
    for i = 1, 100 do
      T.ok(b2:has("serial-" .. i), "serial-" .. i .. " present after round-trip")
    end
  end)

  T.it("from_string returns nil,err for bad length", function()
    -- 3 bytes: too short even for the 4-byte header
    local b2, err = bloom.from_string("abc", 3)
    T.fail(b2, "should fail")
    T.ok(err, "has error")
  end)

  T.it("from_string returns nil,err for non-multiple-of-4 data portion", function()
    -- 4-byte header + 3 data bytes = invalid (data not multiple of 4)
    local b2, err = bloom.from_string("\0\0\0\x80abc", 3)
    T.fail(b2, "should fail")
    T.ok(err, "has error")
  end)

  T.it("empty filter serializes and deserializes", function()
    local b = bloom.new_raw(128, 3)
    local s = b:to_string()
    local b2 = bloom.from_string(s, 3)
    T.eq(b2:count(), 0, "empty after round-trip")
  end)
end)

-- ---------------------------------------------------------------------------
-- Counting Bloom filter
-- ---------------------------------------------------------------------------

T.describe("counting_new", function()
  T.it("creates filter with reasonable m and k", function()
    local cb = bloom.counting_new(500, 0.01)
    T.ok(cb, "counting filter created")
    T.ok(cb:capacity() > 0, "m > 0")
    T.ok(cb:num_hashes() >= 1, "k >= 1")
  end)

  T.it("returns nil,err for invalid params", function()
    local cb, err = bloom.counting_new(0, 0.01)
    T.fail(cb, "should fail")
    T.ok(err, "has error")
  end)
end)

T.describe("counting add/has/remove", function()
  T.it("add then has returns true", function()
    local cb = bloom.counting_new(100, 0.01)
    cb:add("foo")
    T.ok(cb:has("foo"), "has after add")
  end)

  T.it("add then remove then has returns false", function()
    local cb = bloom.counting_new(100, 0.01)
    cb:add("foo")
    cb:remove("foo")
    T.fail(cb:has("foo"), "not has after add+remove")
  end)

  T.it("double add then single remove still present", function()
    local cb = bloom.counting_new(100, 0.01)
    cb:add("bar")
    cb:add("bar")
    cb:remove("bar")
    T.ok(cb:has("bar"), "still present after double-add single-remove")
  end)

  T.it("double add then double remove gone", function()
    local cb = bloom.counting_new(100, 0.01)
    cb:add("baz")
    cb:add("baz")
    cb:remove("baz")
    cb:remove("baz")
    T.fail(cb:has("baz"), "gone after double-add double-remove")
  end)

  T.it("remove on absent item is safe (no underflow)", function()
    local cb = bloom.counting_new(100, 0.01)
    cb:remove("ghost")  -- never added
    T.fail(cb:has("ghost"), "still absent after spurious remove")
  end)

  T.it("count_of returns 0 for absent item", function()
    local cb = bloom.counting_new(100, 0.01)
    T.eq(cb:count_of("missing"), 0)
  end)

  T.it("count_of returns 1 after single add", function()
    local cb = bloom.counting_new(100, 0.01)
    cb:add("once")
    T.ok(cb:count_of("once") >= 1, "count_of >= 1 after add")
  end)

  T.it("count_of reflects double add", function()
    local cb = bloom.counting_new(100, 0.01)
    cb:add("twice")
    cb:add("twice")
    T.ok(cb:count_of("twice") >= 2, "count_of >= 2 after double add")
  end)

  T.it("count_of decrements on remove", function()
    local cb = bloom.counting_new(100, 0.01)
    cb:add("dec")
    cb:add("dec")
    cb:remove("dec")
    T.ok(cb:count_of("dec") >= 1, "count_of >= 1 after double-add single-remove")
  end)

  T.it("no false negatives for 100 items", function()
    local cb = bloom.counting_new(200, 0.01)
    for i = 1, 100 do cb:add("citem-" .. i) end
    for i = 1, 100 do
      T.ok(cb:has("citem-" .. i), "citem-" .. i .. " present")
    end
  end)

  T.it("clear resets counting filter", function()
    local cb = bloom.counting_new(100, 0.01)
    cb:add("p")
    cb:clear()
    T.fail(cb:has("p"), "gone after clear")
    T.eq(cb:count_of("p"), 0, "count_of 0 after clear")
  end)
end)

T.describe("counting false_positive_rate", function()
  T.it("returns 0 for empty filter", function()
    local cb = bloom.counting_new(500, 0.01)
    T.eq(cb:false_positive_rate(), 0)
  end)

  T.it("returns positive value after inserts", function()
    local cb = bloom.counting_new(500, 0.01)
    for i = 1, 200 do cb:add("z-" .. i) end
    T.ok(cb:false_positive_rate() > 0, "FP rate > 0 after inserts")
  end)
end)
