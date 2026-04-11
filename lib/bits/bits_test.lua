-- lib/bits/bits_test.lua
-- Tests for bitset and Bloom filter.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local bits = require("lib.bits")

-- ── Bitset: basic operations ────────────────────────────────────────────────

T.describe("bitset: set/clear/toggle/get", function()
  T.it("set and get individual bits", function()
    local bs = bits.bitset(64)
    T.ok(not bs:get(0), "bit 0 initially clear")
    T.ok(not bs:get(63), "bit 63 initially clear")
    bs:set(0)
    T.ok(bs:get(0), "bit 0 set")
    bs:set(63)
    T.ok(bs:get(63), "bit 63 set")
    T.ok(not bs:get(1), "bit 1 still clear")
  end)

  T.it("clear a set bit", function()
    local bs = bits.bitset(32)
    bs:set(5)
    T.ok(bs:get(5), "bit 5 set")
    bs:clear(5)
    T.ok(not bs:get(5), "bit 5 cleared")
  end)

  T.it("toggle flips bits", function()
    local bs = bits.bitset(16)
    bs:toggle(3)
    T.ok(bs:get(3), "toggle 0->1")
    bs:toggle(3)
    T.ok(not bs:get(3), "toggle 1->0")
  end)

  T.it("out-of-range get returns false", function()
    local bs = bits.bitset(8)
    T.ok(not bs:get(8), "index == size returns false")
    T.ok(not bs:get(100), "index > size returns false")
    T.ok(not bs:get(-1), "negative index returns false")
  end)

  T.it("out-of-range set/clear/toggle are no-ops", function()
    local bs = bits.bitset(8)
    bs:set(100)
    bs:clear(100)
    bs:toggle(100)
    T.eq(bs:count(), 0, "no bits set after out-of-range ops")
  end)
end)

-- ── Bitset: count/any/none/all ──────────────────────────────────────────────

T.describe("bitset: count/any/none/all", function()
  T.it("count returns number of set bits", function()
    local bs = bits.bitset(32)
    T.eq(bs:count(), 0, "empty bitset has count 0")
    bs:set(0)
    bs:set(15)
    bs:set(31)
    T.eq(bs:count(), 3, "3 bits set")
  end)

  T.it("any/none/all on empty bitset", function()
    local bs = bits.bitset(16)
    T.ok(bs:none(), "empty is none")
    T.ok(not bs:any(), "empty is not any")
    T.ok(not bs:all(), "empty is not all")
  end)

  T.it("any/none/all with some bits set", function()
    local bs = bits.bitset(8)
    bs:set(3)
    T.ok(bs:any(), "some bits: any is true")
    T.ok(not bs:none(), "some bits: none is false")
    T.ok(not bs:all(), "some bits: all is false")
  end)

  T.it("all returns true when all bits set", function()
    local bs = bits.bitset(8)
    for i = 0, 7 do bs:set(i) end
    T.ok(bs:all(), "all bits set")
    T.eq(bs:count(), 8, "count matches size")
  end)

  T.it("all works for non-multiple-of-32 sizes", function()
    local bs = bits.bitset(5)
    for i = 0, 4 do bs:set(i) end
    T.ok(bs:all(), "all 5 bits set")
  end)
end)

-- ── Bitset: size ────────────────────────────────────────────────────────────

T.describe("bitset: size", function()
  T.it("returns the capacity", function()
    T.eq(bits.bitset(0):size(), 0, "size 0")
    T.eq(bits.bitset(1):size(), 1, "size 1")
    T.eq(bits.bitset(100):size(), 100, "size 100")
  end)
end)

-- ── Bitset: set operations ──────────────────────────────────────────────────

T.describe("bitset: set operations", function()
  T.it("and_ produces intersection", function()
    local a = bits.bitset(8)
    local b = bits.bitset(8)
    a:set(1); a:set(2); a:set(3)
    b:set(2); b:set(3); b:set(4)
    local c = a:and_(b)
    T.eq(c:get(1), false, "1 not in intersection")
    T.ok(c:get(2), "2 in intersection")
    T.ok(c:get(3), "3 in intersection")
    T.eq(c:get(4), false, "4 not in intersection")
  end)

  T.it("or_ produces union", function()
    local a = bits.bitset(8)
    local b = bits.bitset(8)
    a:set(0); a:set(1)
    b:set(1); b:set(2)
    local c = a:or_(b)
    T.ok(c:get(0), "0 in union")
    T.ok(c:get(1), "1 in union")
    T.ok(c:get(2), "2 in union")
    T.eq(c:get(3), false, "3 not in union")
  end)

  T.it("xor_ produces symmetric difference", function()
    local a = bits.bitset(8)
    local b = bits.bitset(8)
    a:set(0); a:set(1)
    b:set(1); b:set(2)
    local c = a:xor_(b)
    T.ok(c:get(0), "0 in xor (only in a)")
    T.eq(c:get(1), false, "1 not in xor (in both)")
    T.ok(c:get(2), "2 in xor (only in b)")
  end)

  T.it("not_ flips all bits within size", function()
    local a = bits.bitset(8)
    a:set(0); a:set(7)
    local b = a:not_()
    T.eq(b:get(0), false, "0 was set, now clear")
    T.ok(b:get(1), "1 was clear, now set")
    T.ok(b:get(6), "6 was clear, now set")
    T.eq(b:get(7), false, "7 was set, now clear")
    T.eq(b:count(), 6, "6 bits set after not")
  end)

  T.it("set operations return nil on size mismatch", function()
    local a = bits.bitset(8)
    local b = bits.bitset(16)
    local r, err = a:and_(b)
    T.ok(not r, "and_ returns nil on mismatch")
    T.ok(err, "and_ returns error message")
    r, err = a:or_(b)
    T.ok(not r, "or_ returns nil on mismatch")
    r, err = a:xor_(b)
    T.ok(not r, "xor_ returns nil on mismatch")
  end)

  T.it("set operations do not mutate originals", function()
    local a = bits.bitset(8)
    local b = bits.bitset(8)
    a:set(0)
    b:set(1)
    local c = a:or_(b)
    T.eq(a:count(), 1, "a unchanged")
    T.eq(b:count(), 1, "b unchanged")
    T.eq(c:count(), 2, "c has union")
  end)
end)

-- ── Bitset: to_array / from_array ───────────────────────────────────────────

T.describe("bitset: to_array / from_array", function()
  T.it("to_array returns sorted indices of set bits", function()
    local bs = bits.bitset(16)
    bs:set(3); bs:set(7); bs:set(15)
    local arr = bs:to_array()
    T.eq(#arr, 3, "3 elements")
    T.eq(arr[1], 3, "first is 3")
    T.eq(arr[2], 7, "second is 7")
    T.eq(arr[3], 15, "third is 15")
  end)

  T.it("from_array sets bits from list", function()
    local bs = bits.bitset(32)
    bs:from_array({0, 10, 31})
    T.ok(bs:get(0), "bit 0 set")
    T.ok(bs:get(10), "bit 10 set")
    T.ok(bs:get(31), "bit 31 set")
    T.eq(bs:count(), 3, "3 bits set")
  end)

  T.it("empty bitset to_array returns empty table", function()
    local arr = bits.bitset(8):to_array()
    T.eq(#arr, 0, "no elements")
  end)
end)

-- ── Bitset: tostring ────────────────────────────────────────────────────────

T.describe("bitset: tostring", function()
  T.it("represents bits as string (bit 0 leftmost)", function()
    local bs = bits.bitset(8)
    bs:set(0); bs:set(2); bs:set(4)
    T.eq(tostring(bs), "10101000", "correct string representation")
  end)

  T.it("empty bitset all zeros", function()
    T.eq(tostring(bits.bitset(4)), "0000", "4 zeros")
  end)
end)

-- ── Bitset: large bitset ────────────────────────────────────────────────────

T.describe("bitset: large (1000+ bits)", function()
  T.it("handles 1024-bit bitset correctly", function()
    local bs = bits.bitset(1024)
    T.eq(bs:size(), 1024, "size is 1024")
    bs:set(0)
    bs:set(511)
    bs:set(1023)
    T.ok(bs:get(0), "bit 0")
    T.ok(bs:get(511), "bit 511")
    T.ok(bs:get(1023), "bit 1023")
    T.ok(not bs:get(512), "bit 512 clear")
    T.eq(bs:count(), 3, "3 bits set")
  end)

  T.it("all works on large bitset", function()
    local bs = bits.bitset(1000)
    for i = 0, 999 do bs:set(i) end
    T.ok(bs:all(), "all 1000 bits set")
    T.eq(bs:count(), 1000, "count is 1000")
  end)
end)

-- ── Bitset: edge cases ─────────────────────────────────────────────────────

T.describe("bitset: edge cases", function()
  T.it("single-bit bitset", function()
    local bs = bits.bitset(1)
    T.eq(bs:size(), 1, "size 1")
    T.ok(not bs:get(0), "initially clear")
    bs:set(0)
    T.ok(bs:get(0), "set bit 0")
    T.ok(bs:all(), "all (single bit)")
    T.eq(bs:count(), 1, "count 1")
  end)

  T.it("bit at word boundary (31, 32, 33)", function()
    local bs = bits.bitset(64)
    bs:set(31); bs:set(32); bs:set(33)
    T.ok(bs:get(31), "bit 31")
    T.ok(bs:get(32), "bit 32")
    T.ok(bs:get(33), "bit 33")
    T.ok(not bs:get(30), "bit 30 clear")
    T.ok(not bs:get(34), "bit 34 clear")
  end)

  T.it("error on invalid size", function()
    local r, err = bits.bitset(-1)
    T.ok(not r, "nil on negative size")
    T.ok(err, "error message returned")
    r, err = bits.bitset("foo")
    T.ok(not r, "nil on string size")
  end)
end)

-- ── Bitset: tier ────────────────────────────────────────────────────────────

T.describe("bitset: tier", function()
  T.it("exposes _tier string", function()
    T.ok(bits._tier == "ffi" or bits._tier == "pure",
      "_tier is ffi or pure")
  end)
end)

-- ── Bloom filter: basic operations ──────────────────────────────────────────

T.describe("bloom: add and test", function()
  T.it("added items always test positive (no false negatives)", function()
    local bf = bits.bloom(100, 0.01)
    local items = {}
    for i = 1, 50 do
      items[i] = "item_" .. i
      bf:add(items[i])
    end
    for i = 1, 50 do
      T.ok(bf:test(items[i]), "item " .. i .. " found")
    end
  end)

  T.it("works with numbers", function()
    local bf = bits.bloom(50, 0.01)
    bf:add(42)
    bf:add(0)
    bf:add(-1)
    T.ok(bf:test(42), "42 found")
    T.ok(bf:test(0), "0 found")
    T.ok(bf:test(-1), "-1 found")
  end)

  T.it("count tracks approximate insertions", function()
    local bf = bits.bloom(100, 0.01)
    T.eq(bf:count(), 0, "initially 0")
    bf:add("a")
    bf:add("b")
    bf:add("c")
    T.eq(bf:count(), 3, "3 after 3 distinct adds")
  end)
end)

-- ── Bloom filter: false positive rate ───────────────────────────────────────

T.describe("bloom: false positive rate", function()
  T.it("actual FP rate is within expected bounds", function()
    local n = 1000
    local target_fp = 0.05
    local bf = bits.bloom(n, target_fp)
    -- Add n items
    for i = 1, n do
      bf:add("present_" .. i)
    end
    -- Test 10000 items that were NOT added
    local false_positives = 0
    local tests = 10000
    for i = 1, tests do
      if bf:test("absent_" .. i) then
        false_positives = false_positives + 1
      end
    end
    local actual_fp = false_positives / tests
    -- Allow 3x the target rate as tolerance (probabilistic)
    T.ok(actual_fp < target_fp * 3,
      "FP rate " .. actual_fp .. " < " .. (target_fp * 3))
  end)

  T.it("false_positive_rate returns estimate", function()
    local bf = bits.bloom(100, 0.01)
    local initial_fp = bf:false_positive_rate()
    T.eq(initial_fp, 0, "empty filter has 0 FP rate")
    for i = 1, 50 do bf:add("x" .. i) end
    local fp = bf:false_positive_rate()
    T.ok(fp > 0, "FP rate > 0 after adds")
    T.ok(fp < 1, "FP rate < 1")
  end)
end)

-- ── Bloom filter: union ─────────────────────────────────────────────────────

T.describe("bloom: union", function()
  T.it("union merges two filters", function()
    local bf1 = bits.bloom(100, 0.01)
    local bf2 = bits.bloom(100, 0.01)
    bf1:add("alpha")
    bf1:add("beta")
    bf2:add("gamma")
    bf2:add("delta")
    local ok = bf1:union(bf2)
    T.ok(ok, "union succeeds")
    T.ok(bf1:test("alpha"), "alpha in merged")
    T.ok(bf1:test("beta"), "beta in merged")
    T.ok(bf1:test("gamma"), "gamma in merged")
    T.ok(bf1:test("delta"), "delta in merged")
  end)

  T.it("union rejects mismatched filters", function()
    local bf1 = bits.bloom(100, 0.01)
    local bf2 = bits.bloom(200, 0.01)
    local r, err = bf1:union(bf2)
    T.ok(not r, "union returns nil on mismatch")
    T.ok(err, "error message returned")
  end)
end)

-- ── Bloom filter: clear ─────────────────────────────────────────────────────

T.describe("bloom: clear", function()
  T.it("clear resets filter", function()
    local bf = bits.bloom(100, 0.01)
    bf:add("test")
    T.ok(bf:test("test"), "present before clear")
    bf:clear()
    T.eq(bf:count(), 0, "count 0 after clear")
    -- After clear, previously added items may still be false-positive,
    -- but a clear filter should be empty
    T.eq(bf:false_positive_rate(), 0, "FP rate 0 after clear")
  end)
end)

-- ── Bloom filter: error handling ────────────────────────────────────────────

T.describe("bloom: error handling", function()
  T.it("rejects invalid parameters", function()
    local r, err = bits.bloom(0, 0.01)
    T.ok(not r, "nil on 0 items")
    T.ok(err, "error message")
    r, err = bits.bloom(100, 0)
    T.ok(not r, "nil on 0 FP rate")
    r, err = bits.bloom(100, 1)
    T.ok(not r, "nil on 1 FP rate")
    r, err = bits.bloom(-5, 0.01)
    T.ok(not r, "nil on negative items")
  end)
end)
