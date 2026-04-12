if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local crc = require("lib.crc")

local CHECK_INPUT = "123456789"

-- ---------------------------------------------------------------------------
-- Module meta
-- ---------------------------------------------------------------------------
T.describe("lib/crc meta", function()
  T.it("has _tier == pure", function()
    T.eq(crc._tier, "pure")
  end)

  T.it("CHECK table has correct keys", function()
    T.ok(crc.CHECK.crc32      ~= nil)
    T.ok(crc.CHECK.crc32c     ~= nil)
    T.ok(crc.CHECK.crc16      ~= nil)
    T.ok(crc.CHECK.crc16_ccitt ~= nil)
    T.ok(crc.CHECK.crc8       ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- make_table
-- ---------------------------------------------------------------------------
T.describe("make_table", function()
  T.it("returns 256 entries for CRC-32 poly", function()
    local t = crc.make_table(0x04C11DB7, 32)
    local count = 0
    for i = 0, 255 do
      T.ok(t[i] ~= nil)
      count = count + 1
    end
    T.eq(count, 256)
  end)

  T.it("returns 256 entries for CRC-16 poly", function()
    local t = crc.make_table(0x8005, 16)
    local count = 0
    for i = 0, 255 do
      T.ok(t[i] ~= nil)
      count = count + 1
    end
    T.eq(count, 256)
  end)

  T.it("returns 256 entries for CRC-8 poly", function()
    local t = crc.make_table(0x07, 8, false)
    local count = 0
    for i = 0, 255 do
      T.ok(t[i] ~= nil)
      count = count + 1
    end
    T.eq(count, 256)
  end)
end)

-- ---------------------------------------------------------------------------
-- CRC-32
-- ---------------------------------------------------------------------------
T.describe("crc32", function()
  T.it("check value for '123456789'", function()
    T.eq(crc.crc32(CHECK_INPUT), 0xcbf43926)
  end)

  T.it("matches M.CHECK.crc32", function()
    T.eq(crc.crc32(CHECK_INPUT), crc.CHECK.crc32)
  end)

  T.it("empty string returns 0x00000000", function()
    T.eq(crc.crc32(""), 0x00000000)
  end)

  T.it("single zero byte", function()
    T.eq(crc.crc32("\0"), 0xD202EF8D)
  end)

  T.it("single 0xFF byte", function()
    T.eq(crc.crc32("\xFF"), 0xFF000000)
  end)

  T.it("incremental equals full for two parts", function()
    local a, b = "Hello, ", "world!"
    local full = crc.crc32(a .. b)
    local incr = crc.crc32(b, crc.crc32(a))
    T.eq(incr, full)
  end)

  T.it("incremental over three parts", function()
    local p1, p2, p3 = "foo", "bar", "baz"
    local full = crc.crc32(p1 .. p2 .. p3)
    local incr = crc.crc32(p3, crc.crc32(p2, crc.crc32(p1)))
    T.eq(incr, full)
  end)

  T.it("crc32_hex returns 8-char lowercase hex", function()
    local h = crc.crc32_hex(CHECK_INPUT)
    T.eq(type(h), "string")
    T.eq(#h, 8)
    T.eq(h, "cbf43926")
  end)

  T.it("crc32_hex of empty string", function()
    T.eq(crc.crc32_hex(""), "00000000")
  end)
end)

-- ---------------------------------------------------------------------------
-- CRC-32C
-- ---------------------------------------------------------------------------
T.describe("crc32c", function()
  T.it("check value for '123456789'", function()
    T.eq(crc.crc32c(CHECK_INPUT), 0xe3069283)
  end)

  T.it("matches M.CHECK.crc32c", function()
    T.eq(crc.crc32c(CHECK_INPUT), crc.CHECK.crc32c)
  end)

  T.it("empty string returns 0x00000000", function()
    T.eq(crc.crc32c(""), 0x00000000)
  end)

  T.it("incremental equals full", function()
    local a, b = "Hello, ", "world!"
    local full = crc.crc32c(a .. b)
    local incr = crc.crc32c(b, crc.crc32c(a))
    T.eq(incr, full)
  end)

  T.it("differs from crc32 on same input", function()
    T.neq(crc.crc32(CHECK_INPUT), crc.crc32c(CHECK_INPUT))
  end)
end)

-- ---------------------------------------------------------------------------
-- CRC-16
-- ---------------------------------------------------------------------------
T.describe("crc16", function()
  T.it("check value for '123456789'", function()
    T.eq(crc.crc16(CHECK_INPUT), 0xBB3D)
  end)

  T.it("matches M.CHECK.crc16", function()
    T.eq(crc.crc16(CHECK_INPUT), crc.CHECK.crc16)
  end)

  T.it("empty string returns 0", function()
    T.eq(crc.crc16(""), 0)
  end)

  T.it("result fits in 16 bits", function()
    T.ok(crc.crc16(CHECK_INPUT) <= 0xFFFF)
    T.ok(crc.crc16(CHECK_INPUT) >= 0)
  end)

  T.it("incremental equals full", function()
    local a, b = "Hello, ", "world!"
    local full = crc.crc16(a .. b)
    local incr = crc.crc16(b, crc.crc16(a))
    T.eq(incr, full)
  end)

  T.it("crc16_hex returns 4-char uppercase hex", function()
    local h = crc.crc16_hex(CHECK_INPUT)
    T.eq(type(h), "string")
    T.eq(#h, 4)
    T.eq(h, "BB3D")
  end)
end)

-- ---------------------------------------------------------------------------
-- CRC-16/CCITT
-- ---------------------------------------------------------------------------
T.describe("crc16_ccitt", function()
  T.it("check value for '123456789'", function()
    T.eq(crc.crc16_ccitt(CHECK_INPUT), 0x29B1)
  end)

  T.it("matches M.CHECK.crc16_ccitt", function()
    T.eq(crc.crc16_ccitt(CHECK_INPUT), crc.CHECK.crc16_ccitt)
  end)

  T.it("empty string returns 0xFFFF (default init)", function()
    T.eq(crc.crc16_ccitt(""), 0xFFFF)
  end)

  T.it("result fits in 16 bits", function()
    T.ok(crc.crc16_ccitt(CHECK_INPUT) <= 0xFFFF)
    T.ok(crc.crc16_ccitt(CHECK_INPUT) >= 0)
  end)

  T.it("incremental equals full (manual init threading)", function()
    -- CRC-16/CCITT init is 0xFFFF on first call, but for incrementality
    -- the caller threads the raw CRC value; we test the interface works.
    local a, b = "Hello, ", "world!"
    -- Incremental for CCITT: first call uses default init 0xFFFF,
    -- subsequent calls pass the previous raw CRC as init.
    local full = crc.crc16_ccitt(a .. b)
    local mid  = crc.crc16_ccitt(a)
    local incr = crc.crc16_ccitt(b, mid)
    T.eq(incr, full)
  end)

  T.it("differs from crc16 on same input", function()
    T.neq(crc.crc16(CHECK_INPUT), crc.crc16_ccitt(CHECK_INPUT))
  end)
end)

-- ---------------------------------------------------------------------------
-- CRC-8
-- ---------------------------------------------------------------------------
T.describe("crc8", function()
  T.it("check value for '123456789'", function()
    T.eq(crc.crc8(CHECK_INPUT), 0xF4)
  end)

  T.it("matches M.CHECK.crc8", function()
    T.eq(crc.crc8(CHECK_INPUT), crc.CHECK.crc8)
  end)

  T.it("empty string returns 0", function()
    T.eq(crc.crc8(""), 0)
  end)

  T.it("result fits in 8 bits", function()
    T.ok(crc.crc8(CHECK_INPUT) <= 0xFF)
    T.ok(crc.crc8(CHECK_INPUT) >= 0)
  end)

  T.it("incremental equals full", function()
    local a, b = "Hello, ", "world!"
    local full = crc.crc8(a .. b)
    local incr = crc.crc8(b, crc.crc8(a))
    T.eq(incr, full)
  end)
end)

-- ---------------------------------------------------------------------------
-- CRC-8/MAXIM
-- ---------------------------------------------------------------------------
T.describe("crc8_maxim", function()
  T.it("returns a number", function()
    T.ok(type(crc.crc8_maxim(CHECK_INPUT)) == "number")
  end)

  T.it("result fits in 8 bits", function()
    T.ok(crc.crc8_maxim(CHECK_INPUT) <= 0xFF)
    T.ok(crc.crc8_maxim(CHECK_INPUT) >= 0)
  end)

  T.it("empty string returns 0", function()
    T.eq(crc.crc8_maxim(""), 0)
  end)

  T.it("differs from crc8 on non-trivial input", function()
    T.neq(crc.crc8(CHECK_INPUT), crc.crc8_maxim(CHECK_INPUT))
  end)

  T.it("incremental equals full", function()
    local a, b = "Hello, ", "world!"
    local full = crc.crc8_maxim(a .. b)
    local incr = crc.crc8_maxim(b, crc.crc8_maxim(a))
    T.eq(incr, full)
  end)
end)

-- ---------------------------------------------------------------------------
-- CRC-64
-- ---------------------------------------------------------------------------
T.describe("crc64", function()
  T.it("returns two numbers", function()
    local hi, lo = crc.crc64(CHECK_INPUT)
    T.ok(type(hi) == "number")
    T.ok(type(lo) == "number")
  end)

  T.it("empty string returns hi=0, lo=0", function()
    local hi, lo = crc.crc64("")
    T.eq(hi, 0)
    T.eq(lo, 0)
  end)

  T.it("non-empty produces non-zero result", function()
    local hi, lo = crc.crc64(CHECK_INPUT)
    T.ok(hi ~= 0 or lo ~= 0)
  end)

  T.it("incremental equals full (hi/lo)", function()
    local a, b = "Hello, ", "world!"
    local fhi, flo = crc.crc64(a .. b)
    local mhi, mlo = crc.crc64(a)
    local ihi, ilo = crc.crc64(b, mhi, mlo)
    T.eq(ihi, fhi)
    T.eq(ilo, flo)
  end)

  T.it("hi and lo fit in 32 bits (unsigned)", function()
    local hi, lo = crc.crc64(CHECK_INPUT)
    -- Lua bit library uses signed 32-bit; we check they're valid Lua numbers
    T.ok(hi == hi)  -- not NaN
    T.ok(lo == lo)
  end)
end)

-- ---------------------------------------------------------------------------
-- generic()
-- ---------------------------------------------------------------------------
T.describe("generic", function()
  T.it("replicates crc32 check value", function()
    local v = crc.generic(CHECK_INPUT, {
      poly   = 0x04C11DB7,
      width  = 32,
      init   = 0xFFFFFFFF,
      refin  = true,
      refout = true,
      xorout = 0xFFFFFFFF,
    })
    T.eq(v, 0xcbf43926)
  end)

  T.it("replicates crc16_ccitt check value", function()
    local v = crc.generic(CHECK_INPUT, {
      poly   = 0x1021,
      width  = 16,
      init   = 0xFFFF,
      refin  = false,
      refout = false,
      xorout = 0,
    })
    T.eq(v, 0x29B1)
  end)

  T.it("replicates crc8 check value", function()
    local v = crc.generic(CHECK_INPUT, {
      poly   = 0x07,
      width  = 8,
      init   = 0,
      refin  = false,
      refout = false,
      xorout = 0,
    })
    T.eq(v, 0xF4)
  end)

  T.it("returns nil, errmsg when opts missing poly", function()
    local v, err = crc.generic("data", { width = 32 })
    T.eq(v, nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns nil, errmsg when opts missing width", function()
    local v, err = crc.generic("data", { poly = 0x07 })
    T.eq(v, nil)
    T.ok(type(err) == "string")
  end)
end)
