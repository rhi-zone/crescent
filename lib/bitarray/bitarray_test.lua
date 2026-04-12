-- lib/bitarray/bitarray_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local ba = require("lib.bitarray")

T.describe("bitarray", function()

  -- -------------------------------------------------------------------------
  T.it("new: all bits zero, len correct", function()
    local b = ba.new(10)
    T.eq(b:len(), 10)
    for i = 0, 9 do
      T.eq(b:get(i), 0, "bit " .. i .. " should be 0")
    end
  end)

  -- -------------------------------------------------------------------------
  T.it("set/get: round-trip", function()
    local b = ba.new(16)
    b:set(0, 1)
    b:set(7, 1)
    b:set(15, 1)
    T.eq(b:get(0), 1)
    T.eq(b:get(7), 1)
    T.eq(b:get(15), 1)
    T.eq(b:get(1), 0)
    T.eq(b:get(8), 0)
  end)

  T.it("set/get: clear with 0", function()
    local b = ba.new(8)
    b:set(3, 1)
    T.eq(b:get(3), 1)
    b:set(3, 0)
    T.eq(b:get(3), 0)
  end)

  -- -------------------------------------------------------------------------
  T.it("flip: toggle bits", function()
    local b = ba.new(8)
    T.eq(b:get(4), 0)
    b:flip(4)
    T.eq(b:get(4), 1)
    b:flip(4)
    T.eq(b:get(4), 0)
  end)

  -- -------------------------------------------------------------------------
  T.it("fill(1): all bits set", function()
    local b = ba.new(33)
    b:fill(1)
    for i = 0, 32 do
      T.eq(b:get(i), 1, "bit " .. i)
    end
  end)

  T.it("fill(0): all bits clear", function()
    local b = ba.new(33)
    b:fill(1)
    b:fill(0)
    for i = 0, 32 do
      T.eq(b:get(i), 0, "bit " .. i)
    end
  end)

  T.it("fill(1) does not set bits beyond len", function()
    local b = ba.new(33)
    b:fill(1)
    -- The word for bit 32 is word 2 (0-indexed: 32/32+1=2). Bits 33..63 must stay 0.
    -- We verify by checking popcount = 33 exactly.
    T.eq(b:popcount(), 33)
  end)

  -- -------------------------------------------------------------------------
  T.it("popcount: correct count", function()
    local b = ba.new(64)
    T.eq(b:popcount(), 0)
    b:set(0, 1)
    b:set(31, 1)
    b:set(32, 1)
    b:set(63, 1)
    T.eq(b:popcount(), 4)
  end)

  -- -------------------------------------------------------------------------
  T.it("first_set: nil on empty array", function()
    local b = ba.new(16)
    T.eq(b:first_set(), nil)
  end)

  T.it("first_set: returns lowest set bit", function()
    local b = ba.new(64)
    b:set(5, 1)
    b:set(10, 1)
    T.eq(b:first_set(), 5)
  end)

  T.it("first_set: bit 0", function()
    local b = ba.new(32)
    b:set(0, 1)
    T.eq(b:first_set(), 0)
  end)

  T.it("first_set: word boundary (bit 32)", function()
    local b = ba.new(64)
    b:set(32, 1)
    T.eq(b:first_set(), 32)
  end)

  T.it("first_clear: nil when all bits set", function()
    local b = ba.new(8)
    b:fill(1)
    T.eq(b:first_clear(), nil)
  end)

  T.it("first_clear: returns lowest clear bit", function()
    local b = ba.new(8)
    b:fill(1)
    b:set(3, 0)
    T.eq(b:first_clear(), 3)
  end)

  T.it("first_clear: bit 0 when nothing set", function()
    local b = ba.new(8)
    T.eq(b:first_clear(), 0)
  end)

  -- -------------------------------------------------------------------------
  T.it("and_: bitwise AND", function()
    local a = ba.from_string("11001100")
    local b = ba.from_string("10101010")
    local c = ba.and_(a, b)
    T.eq(c:to_string(), "10001000")
  end)

  T.it("or_: bitwise OR", function()
    local a = ba.from_string("11001100")
    local b = ba.from_string("10101010")
    local c = ba.or_(a, b)
    T.eq(c:to_string(), "11101110")
  end)

  T.it("xor_: bitwise XOR", function()
    local a = ba.from_string("11001100")
    local b = ba.from_string("10101010")
    local c = ba.xor_(a, b)
    T.eq(c:to_string(), "01100110")
  end)

  T.it("not_: bitwise NOT", function()
    local a = ba.from_string("11001100")
    local c = ba.not_(a)
    T.eq(c:to_string(), "00110011")
  end)

  T.it("not_: does not leak bits beyond len", function()
    -- 5-bit array: only 5 bits should be inverted
    local a = ba.new(5)
    a:set(0, 1); a:set(2, 1); a:set(4, 1)
    local c = ba.not_(a)
    T.eq(c:len(), 5)
    T.eq(c:to_string(), "01010")
    T.eq(c:popcount(), 2)
  end)

  -- -------------------------------------------------------------------------
  T.it("to_string/from_string: round-trip", function()
    local s = "10110010110"
    local b = ba.from_string(s)
    T.eq(b:len(), #s)
    T.eq(b:to_string(), s)
  end)

  T.it("to_string/from_string: all zeros", function()
    local b = ba.new(8)
    T.eq(b:to_string(), "00000000")
  end)

  T.it("to_string/from_string: all ones", function()
    local b = ba.new(8)
    b:fill(1)
    T.eq(b:to_string(), "11111111")
    local b2 = ba.from_string("11111111")
    T.eq(b2:to_string(), "11111111")
  end)

  -- -------------------------------------------------------------------------
  T.it("to_hex/from_hex: round-trip (32 bits)", function()
    local b = ba.new(32)
    b:set(0, 1); b:set(8, 1); b:set(16, 1); b:set(24, 1)
    local h = b:to_hex()
    T.eq(#h, 8)
    local b2 = ba.from_hex(h, 32)
    T.eq(b2:to_string(), b:to_string())
  end)

  T.it("to_hex/from_hex: round-trip (64 bits)", function()
    local b = ba.new(64)
    b:fill(1)
    local h = b:to_hex()
    T.eq(#h, 16)
    local b2 = ba.from_hex(h, 64)
    T.eq(b2:popcount(), 64)
  end)

  -- -------------------------------------------------------------------------
  T.it("slice: extracts correct subsequence", function()
    local b = ba.from_string("0011110000")
    local s = b:slice(2, 6)   -- bits 2,3,4,5 → "1111"
    T.eq(s:len(), 4)
    T.eq(s:to_string(), "1111")
  end)

  T.it("slice: word-crossing slice", function()
    local b = ba.new(64)
    for i = 28, 35 do b:set(i, 1) end   -- set bits 28-35 (spans word boundary)
    local s = b:slice(28, 36)
    T.eq(s:len(), 8)
    T.eq(s:to_string(), "11111111")
  end)

  T.it("slice: bit 0 and bit n-1", function()
    local b = ba.from_string("10000001")
    local s = b:slice(0, 8)
    T.eq(s:to_string(), "10000001")
    T.eq(b:slice(0, 1):to_string(), "1")
    T.eq(b:slice(7, 8):to_string(), "1")
  end)

  -- -------------------------------------------------------------------------
  T.it("concat: length and values", function()
    local a = ba.from_string("1010")
    local b = ba.from_string("0101")
    local c = ba.concat(a, b)
    T.eq(c:len(), 8)
    T.eq(c:to_string(), "10100101")
  end)

  T.it("concat: empty + non-empty", function()
    local a = ba.new(0)
    local b = ba.from_string("111")
    local c = ba.concat(a, b)
    T.eq(c:len(), 3)
    T.eq(c:to_string(), "111")
  end)

  -- -------------------------------------------------------------------------
  T.it("fields: write/read round-trip, 8-bit at offset 0", function()
    local f = ba.fields(16)
    f:write(0, 8, 255)
    T.eq(f:read(0, 8), 255)
  end)

  T.it("fields: write/read, 4-bit at offset 8", function()
    local f = ba.fields(16)
    f:write(8, 4, 10)
    T.eq(f:read(8, 4), 10)
  end)

  T.it("fields: two adjacent fields do not interfere", function()
    local f = ba.fields(16)
    f:write(0, 8, 170)   -- 10101010
    f:write(8, 4, 5)     -- 0101
    T.eq(f:read(0, 8), 170)
    T.eq(f:read(8, 4), 5)
  end)

  T.it("fields: 3-bit fields at various offsets", function()
    local f = ba.fields(64)
    f:write(0,  3, 7)   -- 111
    f:write(3,  3, 3)   -- 011
    f:write(6,  3, 5)   -- 101
    T.eq(f:read(0, 3), 7)
    T.eq(f:read(3, 3), 3)
    T.eq(f:read(6, 3), 5)
  end)

  T.it("fields: word-crossing field", function()
    local f = ba.fields(64)
    -- write a 16-bit value crossing word boundary (bits 24..39)
    f:write(24, 16, 0xABCD)
    T.eq(f:read(24, 16), 0xABCD)
  end)

  -- -------------------------------------------------------------------------
  T.it("pack_array/unpack_array: round-trip with 4-bit width", function()
    local arr = {1, 2, 3, 4, 5, 6, 7, 8}
    local packed = ba.pack_array(arr, 4)
    T.eq(packed:len(), 32)
    local arr2 = ba.unpack_array(packed, 4, 8)
    for i = 1, 8 do
      T.eq(arr2[i], arr[i], "element " .. i)
    end
  end)

  T.it("pack_array/unpack_array: round-trip with 3-bit width", function()
    local arr = {0, 1, 2, 3, 4, 5, 6, 7}
    local packed = ba.pack_array(arr, 3)
    T.eq(packed:len(), 24)
    local arr2 = ba.unpack_array(packed, 3, 8)
    for i = 1, 8 do
      T.eq(arr2[i], arr[i], "element " .. i)
    end
  end)

  T.it("pack_array/unpack_array: round-trip with 7-bit width", function()
    local arr = {127, 64, 32, 1, 0, 100, 99, 63}
    local packed = ba.pack_array(arr, 7)
    T.eq(packed:len(), 56)
    local arr2 = ba.unpack_array(packed, 7, 8)
    for i = 1, 8 do
      T.eq(arr2[i], arr[i], "element " .. i)
    end
  end)

  -- -------------------------------------------------------------------------
  T.it("each(): iterates set bits in order", function()
    local b = ba.new(20)
    b:set(0, 1); b:set(5, 1); b:set(10, 1); b:set(19, 1)
    local seen = {}
    for i, v in b:each() do
      seen[#seen + 1] = i
      T.eq(v, 1)
    end
    T.eq(#seen, 4)
    T.eq(seen[1], 0)
    T.eq(seen[2], 5)
    T.eq(seen[3], 10)
    T.eq(seen[4], 19)
  end)

  T.it("each(): empty array yields nothing", function()
    local b = ba.new(16)
    local count = 0
    for _ in b:each() do count = count + 1 end
    T.eq(count, 0)
  end)

  T.it("each(): does not yield bits beyond len", function()
    -- Fill all words but use n=33, so bits 33..63 of word 2 are implicitly 0.
    local b = ba.new(33)
    b:fill(1)
    local seen = {}
    for i in b:each() do seen[#seen + 1] = i end
    T.eq(#seen, 33)
    T.eq(seen[33], 32)   -- last valid bit is index 32
  end)

  -- -------------------------------------------------------------------------
  T.it("boundary: bit 0", function()
    local b = ba.new(1)
    T.eq(b:get(0), 0)
    b:set(0, 1)
    T.eq(b:get(0), 1)
    b:flip(0)
    T.eq(b:get(0), 0)
  end)

  T.it("boundary: bit n-1 (last bit)", function()
    local b = ba.new(100)
    T.eq(b:get(99), 0)
    b:set(99, 1)
    T.eq(b:get(99), 1)
  end)

  T.it("boundary: word-crossing set/get", function()
    -- Bits 31 and 32 are in different words.
    local b = ba.new(64)
    b:set(31, 1)
    b:set(32, 1)
    T.eq(b:get(31), 1)
    T.eq(b:get(32), 1)
    T.eq(b:get(30), 0)
    T.eq(b:get(33), 0)
  end)

end)
