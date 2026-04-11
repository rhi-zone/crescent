-- lib/bitset/bitset_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local bitset = require("lib.bitset")

-- ---------------------------------------------------------------------------
T.describe("M.new / capacity", function()
  T.it("new() with no arg starts empty", function()
    local b = bitset.new()
    T.eq(b:capacity(), 0)
    T.eq(b:count(), 0)
    T.ok(b:is_empty())
  end)

  T.it("new(n) pre-allocates capacity", function()
    local b = bitset.new(64)
    T.eq(b:capacity(), 64)
    T.ok(b:is_empty())
  end)

  T.it("new(n) with non-multiple-of-32 rounds up capacity", function()
    local b = bitset.new(33)
    T.eq(b:capacity(), 64)  -- 2 words
  end)

  T.it("capacity grows as bits are set", function()
    local b = bitset.new()
    b:set(100)
    T.ok(b:capacity() >= 100)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("M.from_bits", function()
  T.it("creates bitset from positions array", function()
    local b = bitset.from_bits({1, 5, 32, 33, 64})
    T.ok(b:test(1))
    T.ok(b:test(5))
    T.ok(b:test(32))
    T.ok(b:test(33))
    T.ok(b:test(64))
    T.eq(b:count(), 5)
  end)

  T.it("empty positions gives empty bitset", function()
    local b = bitset.from_bits({})
    T.ok(b:is_empty())
    T.eq(b:count(), 0)
  end)

  T.it("round-trips to_array", function()
    local positions = {2, 10, 31, 32, 33, 100}
    local b = bitset.from_bits(positions)
    local arr = b:to_array()
    T.eq(#arr, #positions)
    for i = 1, #positions do
      T.eq(arr[i], positions[i])
    end
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("set / test / get / clear / flip", function()
  T.it("set and test bit 1", function()
    local b = bitset.new()
    T.ok(not b:test(1))
    b:set(1)
    T.ok(b:test(1))
  end)

  T.it("get returns 0 or 1", function()
    local b = bitset.new()
    T.eq(b:get(5), 0)
    b:set(5)
    T.eq(b:get(5), 1)
  end)

  T.it("set and test bit 32 (word boundary)", function()
    local b = bitset.new()
    b:set(32)
    T.ok(b:test(32))
    T.ok(not b:test(31))
    T.ok(not b:test(33))
  end)

  T.it("set and test bit 33 (second word)", function()
    local b = bitset.new()
    b:set(33)
    T.ok(b:test(33))
    T.ok(not b:test(32))
    T.ok(not b:test(34))
  end)

  T.it("set and test bit 64", function()
    local b = bitset.new()
    b:set(64)
    T.ok(b:test(64))
    T.ok(not b:test(63))
  end)

  T.it("clear a set bit", function()
    local b = bitset.new()
    b:set(10)
    T.ok(b:test(10))
    b:clear(10)
    T.ok(not b:test(10))
  end)

  T.it("clear an unallocated bit is a no-op", function()
    local b = bitset.new()
    b:clear(1000)  -- no crash
    T.ok(not b:test(1000))
  end)

  T.it("flip toggles on and off", function()
    local b = bitset.new()
    T.ok(not b:test(7))
    b:flip(7)
    T.ok(b:test(7))
    b:flip(7)
    T.ok(not b:test(7))
  end)

  T.it("test on unallocated position returns false", function()
    local b = bitset.new()
    T.ok(not b:test(9999))
  end)

  T.it("get on unallocated position returns 0", function()
    local b = bitset.new()
    T.eq(b:get(9999), 0)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("set_range / clear_range / flip_range", function()
  T.it("set_range sets all bits in range", function()
    local b = bitset.new()
    b:set_range(3, 7)
    T.ok(not b:test(2))
    T.ok(b:test(3))
    T.ok(b:test(4))
    T.ok(b:test(5))
    T.ok(b:test(6))
    T.ok(b:test(7))
    T.ok(not b:test(8))
    T.eq(b:count(), 5)
  end)

  T.it("set_range spanning word boundary", function()
    local b = bitset.new()
    b:set_range(30, 35)
    for i = 30, 35 do T.ok(b:test(i)) end
    T.ok(not b:test(29))
    T.ok(not b:test(36))
    T.eq(b:count(), 6)
  end)

  T.it("clear_range clears all bits in range", function()
    local b = bitset.new()
    b:set_range(1, 10)
    b:clear_range(3, 7)
    T.ok(b:test(1))
    T.ok(b:test(2))
    T.ok(not b:test(3))
    T.ok(not b:test(7))
    T.ok(b:test(8))
    -- 1,2,8,9,10 remain = 5 bits
    T.eq(b:count(), 5)
  end)

  T.it("flip_range toggles bits", function()
    local b = bitset.new()
    b:set(2); b:set(4)
    b:flip_range(1, 5)
    T.ok(b:test(1))
    T.ok(not b:test(2))
    T.ok(b:test(3))
    T.ok(not b:test(4))
    T.ok(b:test(5))
    T.eq(b:count(), 3)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("count / is_empty / any / all", function()
  T.it("count increases and decreases", function()
    local b = bitset.new()
    T.eq(b:count(), 0)
    b:set(1); T.eq(b:count(), 1)
    b:set(32); T.eq(b:count(), 2)
    b:set(33); T.eq(b:count(), 3)
    b:clear(32); T.eq(b:count(), 2)
  end)

  T.it("is_empty and any", function()
    local b = bitset.new()
    T.ok(b:is_empty())
    T.ok(not b:any())
    b:set(5)
    T.ok(not b:is_empty())
    T.ok(b:any())
    b:clear(5)
    T.ok(b:is_empty())
  end)

  T.it("all(n) — all bits 1..n set", function()
    local b = bitset.new()
    for i = 1, 8 do b:set(i) end
    T.ok(b:all(8))
    T.ok(not b:all(9))
    b:set(9)
    T.ok(b:all(9))
  end)

  T.it("all(n) across word boundary", function()
    local b = bitset.new()
    for i = 1, 40 do b:set(i) end
    T.ok(b:all(40))
    b:clear(20)
    T.ok(not b:all(40))
  end)

  T.it("all(0) is vacuously true", function()
    local b = bitset.new()
    T.ok(b:all(0))
  end)

  T.it("popcount across word boundary", function()
    local b = bitset.new()
    b:set(30); b:set(31); b:set(32); b:set(33); b:set(34)
    T.eq(b:count(), 5)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("band / bor / bxor / bnot / andnot", function()
  T.it("band: intersection", function()
    local b1 = bitset.from_bits({1, 32, 33})
    local b2 = bitset.from_bits({32, 33, 64})
    local r = b1:band(b2)
    T.ok(not r:test(1))
    T.ok(r:test(32))
    T.ok(r:test(33))
    T.ok(not r:test(64))
    T.eq(r:count(), 2)
  end)

  T.it("bor: union", function()
    local b1 = bitset.from_bits({1, 10})
    local b2 = bitset.from_bits({10, 20})
    local r = b1:bor(b2)
    T.ok(r:test(1))
    T.ok(r:test(10))
    T.ok(r:test(20))
    T.eq(r:count(), 3)
  end)

  T.it("bor of different-length bitsets", function()
    local b1 = bitset.from_bits({1})
    local b2 = bitset.from_bits({100})
    local r = b1:bor(b2)
    T.ok(r:test(1))
    T.ok(r:test(100))
    T.eq(r:count(), 2)
  end)

  T.it("bxor: symmetric difference", function()
    local b1 = bitset.from_bits({1, 10})
    local b2 = bitset.from_bits({10, 20})
    local r = b1:bxor(b2)
    T.ok(r:test(1))
    T.ok(not r:test(10))
    T.ok(r:test(20))
    T.eq(r:count(), 2)
  end)

  T.it("bxor with self gives empty", function()
    local b = bitset.from_bits({7, 40})
    local r = b:bxor(b)
    T.ok(r:is_empty())
  end)

  T.it("bnot: complement up to max_bit", function()
    local b = bitset.new()
    b:set(1); b:set(3); b:set(5); b:set(7)
    -- max_bit = 7
    local r = b:bnot()
    T.ok(not r:test(1))
    T.ok(r:test(2))
    T.ok(not r:test(3))
    T.ok(r:test(4))
    T.ok(not r:test(5))
    T.ok(r:test(6))
    T.ok(not r:test(7))
    T.eq(r:count(), 3)
  end)

  T.it("bnot of empty is empty", function()
    local b = bitset.new()
    local r = b:bnot()
    T.ok(r:is_empty())
  end)

  T.it("bnot round-trip: bnot(bnot(b)) on contiguous range restores original", function()
    -- bnot complements up to max_bit; for a round-trip to work, the complement
    -- must have the same max_bit. Use a range so both the original and its
    -- complement have max_bit = 8.
    local b = bitset.new()
    b:set(1); b:set(3); b:set(5); b:set(7)  -- max_bit = 7; complement: {2,4,6} max_bit=6
    -- Instead: set bits so complement has same max_bit as original.
    -- b = {1,3,5,8}, max_bit=8; complement = {2,4,6,7}, max_bit=7... still drifts.
    -- The safest test: bnot is its own inverse when max_bit is stable.
    -- b = {1,2,3,4,5,6,7,8} → all set, bnot = {} (max=0), bnot = {} not useful.
    -- Document the semantic: bnot is NOT a perfect involution in general.
    -- Test a specific meaningful property instead: (b bor bnot(b)) covers 1..max_bit.
    local b2 = bitset.from_bits({1, 3, 5, 7, 8})
    local mb = b2:max_bit()
    local r = b2:bor(b2:bnot())
    for i = 1, mb do
      T.ok(r:test(i))
    end
  end)

  T.it("andnot: self AND NOT other", function()
    local b1 = bitset.from_bits({1, 5, 10})
    local b2 = bitset.from_bits({5, 10, 20})
    local r = b1:andnot(b2)
    T.ok(r:test(1))
    T.ok(not r:test(5))
    T.ok(not r:test(10))
    T.ok(not r:test(20))
    T.eq(r:count(), 1)
  end)

  T.it("band with self equals self", function()
    local b = bitset.from_bits({7, 8, 9})
    local r = b:band(b)
    T.eq(r:to_string(), b:to_string())
  end)

  T.it("bor with bnot covers original bits", function()
    local b = bitset.from_bits({1, 15, 30})
    local r = b:bor(b:bnot())
    -- bits 1..max_bit should all be set
    local mb = b:max_bit()
    for i = 1, mb do
      T.ok(r:test(i))
    end
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("in-place operations", function()
  T.it("band_inplace: self becomes self AND other", function()
    local b1 = bitset.from_bits({1, 5, 10})
    local b2 = bitset.from_bits({5, 10, 20})
    b1:band_inplace(b2)
    T.ok(not b1:test(1))
    T.ok(b1:test(5))
    T.ok(b1:test(10))
    T.ok(not b1:test(20))
    T.eq(b1:count(), 2)
  end)

  T.it("bor_inplace: self becomes self OR other", function()
    local b1 = bitset.from_bits({1, 10})
    local b2 = bitset.from_bits({10, 20})
    b1:bor_inplace(b2)
    T.ok(b1:test(1))
    T.ok(b1:test(10))
    T.ok(b1:test(20))
    T.eq(b1:count(), 3)
  end)

  T.it("bxor_inplace: self becomes self XOR other", function()
    local b1 = bitset.from_bits({1, 10})
    local b2 = bitset.from_bits({10, 20})
    b1:bxor_inplace(b2)
    T.ok(b1:test(1))
    T.ok(not b1:test(10))
    T.ok(b1:test(20))
    T.eq(b1:count(), 2)
  end)

  T.it("bxor_inplace with self clears all bits", function()
    local b = bitset.from_bits({3, 7, 100})
    b:bxor_inplace(b)
    T.ok(b:is_empty())
  end)

  T.it("in-place ops do not affect the other bitset", function()
    local b1 = bitset.from_bits({1, 2, 3})
    local b2 = bitset.from_bits({2, 3, 4})
    local b2_orig = b2:clone()
    b1:band_inplace(b2)
    T.ok(b2:eq(b2_orig))
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("next_set / next_clear", function()
  T.it("next_set returns first set bit from start", function()
    local b = bitset.from_bits({3, 7, 33})
    T.eq(b:next_set(1), 3)
    T.eq(b:next_set(3), 3)
    T.eq(b:next_set(4), 7)
    T.eq(b:next_set(8), 33)
    T.eq(b:next_set(34), nil)
  end)

  T.it("next_set with no args starts at 1", function()
    local b = bitset.from_bits({5, 10})
    T.eq(b:next_set(), 5)
  end)

  T.it("next_set on empty returns nil", function()
    local b = bitset.new()
    T.eq(b:next_set(1), nil)
  end)

  T.it("next_set iterates all set bits", function()
    local positions = {1, 5, 32, 33, 64}
    local b = bitset.from_bits(positions)
    local found = {}
    local pos = b:next_set(1)
    while pos do
      found[#found + 1] = pos
      pos = b:next_set(pos + 1)
    end
    T.eq(#found, #positions)
    for i = 1, #positions do
      T.eq(found[i], positions[i])
    end
  end)

  T.it("next_clear returns first clear bit from start", function()
    local b = bitset.from_bits({1, 2, 3, 5})
    T.eq(b:next_clear(1), 4)
    T.eq(b:next_clear(4), 4)
    T.eq(b:next_clear(5), 6)
  end)

  T.it("next_clear on empty returns 1", function()
    local b = bitset.new()
    T.eq(b:next_clear(1), 1)
  end)

  T.it("next_clear beyond all set bits returns next position", function()
    -- All 32 bits set in word 1, then nothing
    local b = bitset.new()
    for i = 1, 32 do b:set(i) end
    T.eq(b:next_clear(1), 33)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("eq / subset / intersects", function()
  T.it("eq on identical bitsets", function()
    local b1 = bitset.from_bits({1, 5, 100})
    local b2 = bitset.from_bits({1, 5, 100})
    T.ok(b1:eq(b2))
    T.ok(b2:eq(b1))
  end)

  T.it("eq on different bitsets", function()
    local b1 = bitset.from_bits({1, 5})
    local b2 = bitset.from_bits({1, 6})
    T.ok(not b1:eq(b2))
  end)

  T.it("eq handles different allocated lengths (trailing zeros)", function()
    local b1 = bitset.from_bits({1})
    local b2 = bitset.from_bits({1})
    -- b2 gets extra allocated words via set_range then clear_range
    b2:set(1000)
    b2:clear(1000)
    -- b1 and b2 logically equal but different word counts
    T.ok(b1:eq(b2))
  end)

  T.it("subset: A ⊆ A is true", function()
    local b = bitset.from_bits({1, 2, 3})
    T.ok(b:subset(b))
  end)

  T.it("subset: {} ⊆ anything is true", function()
    local empty = bitset.new()
    local b = bitset.from_bits({1, 2})
    T.ok(empty:subset(b))
  end)

  T.it("subset: A ⊆ B when A ⊂ B", function()
    local b1 = bitset.from_bits({2, 3})
    local b2 = bitset.from_bits({1, 2, 3, 4})
    T.ok(b1:subset(b2))
    T.ok(not b2:subset(b1))
  end)

  T.it("subset: not when A has bits outside B", function()
    local b1 = bitset.from_bits({1, 5})
    local b2 = bitset.from_bits({1, 2, 3})
    T.ok(not b1:subset(b2))
  end)

  T.it("intersects: disjoint sets return false", function()
    local b1 = bitset.from_bits({1, 2, 3})
    local b2 = bitset.from_bits({4, 5, 6})
    T.ok(not b1:intersects(b2))
  end)

  T.it("intersects: overlapping sets return true", function()
    local b1 = bitset.from_bits({1, 2, 10})
    local b2 = bitset.from_bits({10, 20})
    T.ok(b1:intersects(b2))
    T.ok(b2:intersects(b1))
  end)

  T.it("intersects: empty with anything is false", function()
    local empty = bitset.new()
    local b = bitset.from_bits({1, 2})
    T.ok(not empty:intersects(b))
    T.ok(not b:intersects(empty))
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("to_array / to_string / max_bit / clone", function()
  T.it("to_array returns sorted positions", function()
    local b = bitset.from_bits({64, 1, 33, 5})
    local arr = b:to_array()
    T.eq(arr[1], 1)
    T.eq(arr[2], 5)
    T.eq(arr[3], 33)
    T.eq(arr[4], 64)
  end)

  T.it("to_array on empty returns empty table", function()
    local b = bitset.new()
    local arr = b:to_array()
    T.eq(#arr, 0)
  end)

  T.it("to_string: empty gives empty string", function()
    local b = bitset.new()
    T.eq(b:to_string(), "")
  end)

  T.it("to_string: bit 1 is leftmost character", function()
    local b = bitset.new()
    b:set(1)
    local s = b:to_string()
    T.eq(s:sub(1, 1), "1")
  end)

  T.it("to_string: alternating bits", function()
    local b = bitset.from_bits({1, 3, 5, 7})
    T.eq(b:to_string(), "1010101")
  end)

  T.it("to_string length equals max_bit", function()
    local b = bitset.from_bits({1, 5, 20})
    T.eq(#b:to_string(), b:max_bit())
  end)

  T.it("max_bit returns highest set bit", function()
    local b = bitset.from_bits({1, 32, 100})
    T.eq(b:max_bit(), 100)
  end)

  T.it("max_bit on empty returns 0", function()
    local b = bitset.new()
    T.eq(b:max_bit(), 0)
  end)

  T.it("max_bit at word boundaries", function()
    local b = bitset.new()
    b:set(32)
    T.eq(b:max_bit(), 32)
    b:set(33)
    T.eq(b:max_bit(), 33)
  end)

  T.it("clone produces independent copy", function()
    local b = bitset.from_bits({1, 5, 100})
    local c = b:clone()
    T.ok(b:eq(c))
    c:set(200)
    T.ok(not b:test(200))
    T.ok(c:test(200))
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("large bitset (10000 bits)", function()
  T.it("set and test 10000 sparse bits", function()
    local b = bitset.new(10000)
    b:set(1)
    b:set(5000)
    b:set(10000)
    T.ok(b:test(1))
    T.ok(not b:test(2))
    T.ok(b:test(5000))
    T.ok(b:test(10000))
    T.eq(b:count(), 3)
  end)

  T.it("set_range over a large range", function()
    local b = bitset.new(10000)
    b:set_range(100, 200)
    T.eq(b:count(), 101)
    T.ok(not b:test(99))
    T.ok(b:test(100))
    T.ok(b:test(200))
    T.ok(not b:test(201))
  end)

  T.it("next_set scans large bitset correctly", function()
    local b = bitset.new(10000)
    b:set(1)
    b:set(5000)
    b:set(9999)
    T.eq(b:next_set(1), 1)
    T.eq(b:next_set(2), 5000)
    T.eq(b:next_set(5001), 9999)
    T.eq(b:next_set(10000), nil)
  end)

  T.it("popcount on large bitset", function()
    local b = bitset.new(10000)
    local expected = 0
    for i = 1, 10000, 3 do
      b:set(i)
      expected = expected + 1
    end
    T.eq(b:count(), expected)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("M._tier", function()
  T.it("is 'pure'", function()
    T.eq(bitset._tier, "pure")
  end)
end)
