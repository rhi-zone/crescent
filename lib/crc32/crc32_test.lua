if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local crc32 = require("lib.crc32")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function hex(n)
  return string.format("%08x", n)
end

-- ---------------------------------------------------------------------------
-- Module metadata
-- ---------------------------------------------------------------------------

T.describe("crc32 module", function()
  T.it("has _tier = pure", function()
    T.eq(crc32._tier, "pure")
  end)
end)

-- ---------------------------------------------------------------------------
-- M.compute — IEEE CRC-32
-- ---------------------------------------------------------------------------

T.describe("crc32.compute (IEEE CRC-32)", function()
  T.it("empty string → 0x00000000", function()
    T.eq(crc32.compute(""), 0x00000000)
  end)

  T.it("standard check value: '123456789' → 0xCBF43926", function()
    T.eq(crc32.compute("123456789"), 0xCBF43926)
  end)

  T.it("single zero byte", function()
    T.eq(crc32.compute("\0"), 0xD202EF8D)
  end)

  T.it("single 0xFF byte", function()
    T.eq(crc32.compute("\xFF"), 0xFF000000)
  end)

  T.it("'Hello, World!'", function()
    -- Verified against Python: zlib.crc32(b'Hello, World!') & 0xFFFFFFFF
    T.eq(crc32.compute("Hello, World!"), 0xEC4AC3D0)
  end)

  T.it("returns unsigned value (not negative)", function()
    local c = crc32.compute("Hello, World!")
    T.ok(c >= 0, "CRC should be non-negative")
    T.ok(c <= 0xFFFFFFFF, "CRC should fit in 32 bits")
  end)

  T.it("'a' gives known value", function()
    T.eq(crc32.compute("a"), 0xE8B7BE43)
  end)

  T.it("'abc' gives known value", function()
    T.eq(crc32.compute("abc"), 0x352441C2)
  end)

  T.it("32 zero bytes", function()
    T.eq(crc32.compute(string.rep("\0", 32)), 0x190A55AD)
  end)
end)

-- ---------------------------------------------------------------------------
-- Incremental (chained) CRC-32
-- ---------------------------------------------------------------------------

T.describe("crc32.compute incremental", function()
  T.it("chaining 'hello ' + 'world' == 'hello world'", function()
    local c1 = crc32.compute("hello ")
    local c2 = crc32.compute("world", c1)
    T.eq(c2, crc32.compute("hello world"))
  end)

  T.it("chaining three parts", function()
    local full = "The quick brown fox"
    local c = crc32.compute("The ")
    c = crc32.compute("quick ", c)
    c = crc32.compute("brown fox", c)
    T.eq(c, crc32.compute(full))
  end)

  T.it("byte-by-byte == whole string", function()
    local data = "123456789"
    local c = 0
    for i = 1, #data do
      c = crc32.compute(data:sub(i, i), c)
    end
    T.eq(c, 0xCBF43926)
  end)

  T.it("chaining empty string is a no-op", function()
    local c = crc32.compute("abc")
    T.eq(crc32.compute("", c), c)
  end)
end)

-- ---------------------------------------------------------------------------
-- M.hex
-- ---------------------------------------------------------------------------

T.describe("crc32.hex", function()
  T.it("empty string → '00000000'", function()
    T.eq(crc32.hex(""), "00000000")
  end)

  T.it("'123456789' → 'cbf43926'", function()
    T.eq(crc32.hex("123456789"), "cbf43926")
  end)

  T.it("always 8 characters", function()
    T.eq(#crc32.hex("a"), 8)
    T.eq(#crc32.hex(""), 8)
    T.eq(#crc32.hex("Hello, World!"), 8)
  end)

  T.it("lowercase hex", function()
    local h = crc32.hex("123456789")
    T.eq(h, h:lower())
  end)

  T.it("matches compute() formatted", function()
    local data = "Hello, World!"
    T.eq(crc32.hex(data), string.format("%08x", crc32.compute(data)))
  end)
end)

-- ---------------------------------------------------------------------------
-- M.castagnoli (CRC-32C)
-- ---------------------------------------------------------------------------

T.describe("crc32.castagnoli (CRC-32C)", function()
  T.it("standard check value: '123456789' → 0xE3069283", function()
    T.eq(crc32.castagnoli("123456789"), 0xE3069283)
  end)

  T.it("empty string → 0x00000000", function()
    T.eq(crc32.castagnoli(""), 0x00000000)
  end)

  T.it("returns unsigned value", function()
    local c = crc32.castagnoli("123456789")
    T.ok(c >= 0 and c <= 0xFFFFFFFF)
  end)

  T.it("incremental: 'foo' + 'bar' == 'foobar'", function()
    local c1 = crc32.castagnoli("foo")
    local c2 = crc32.castagnoli("bar", c1)
    T.eq(c2, crc32.castagnoli("foobar"))
  end)

  T.it("differs from IEEE CRC-32 on same input", function()
    local data = "123456789"
    T.neq(crc32.castagnoli(data), crc32.compute(data))
  end)
end)

-- ---------------------------------------------------------------------------
-- M.castagnoli_hex
-- ---------------------------------------------------------------------------

T.describe("crc32.castagnoli_hex", function()
  T.it("'123456789' → 'e3069283'", function()
    T.eq(crc32.castagnoli_hex("123456789"), "e3069283")
  end)

  T.it("always 8 lowercase hex chars", function()
    local h = crc32.castagnoli_hex("abc")
    T.eq(#h, 8)
    T.eq(h, h:lower())
  end)
end)

-- ---------------------------------------------------------------------------
-- M.koopman
-- ---------------------------------------------------------------------------

T.describe("crc32.koopman", function()
  T.it("returns a number for empty string", function()
    local c = crc32.koopman("")
    T.ok(type(c) == "number")
    T.ok(c >= 0 and c <= 0xFFFFFFFF)
  end)

  T.it("'123456789' → 0x2D3DD0AE (Koopman check value)", function()
    -- CRC-32/KOOPMAN check value for "123456789"
    T.eq(crc32.koopman("123456789"), 0x2D3DD0AE)
  end)

  T.it("differs from IEEE and Castagnoli on same input", function()
    local data = "123456789"
    T.neq(crc32.koopman(data), crc32.compute(data))
    T.neq(crc32.koopman(data), crc32.castagnoli(data))
  end)

  T.it("incremental works for Koopman", function()
    local c1 = crc32.koopman("abc")
    local c2 = crc32.koopman("def", c1)
    T.eq(c2, crc32.koopman("abcdef"))
  end)
end)

-- ---------------------------------------------------------------------------
-- Streaming accumulator
-- ---------------------------------------------------------------------------

T.describe("crc32.stream", function()
  T.it("empty stream → 0", function()
    local s = crc32.stream()
    T.eq(s:finish(), 0)
  end)

  T.it("single update matches compute()", function()
    local s = crc32.stream()
    s:update("123456789")
    T.eq(s:finish(), crc32.compute("123456789"))
  end)

  T.it("multiple updates match compute() on concatenation", function()
    local s = crc32.stream()
    s:update("hello ")
    s:update("world")
    T.eq(s:finish(), crc32.compute("hello world"))
  end)

  T.it("hex() matches compute hex", function()
    local s = crc32.stream()
    s:update("123456789")
    T.eq(s:hex(), crc32.hex("123456789"))
  end)

  T.it("hex() always 8 chars", function()
    local s = crc32.stream()
    s:update("abc")
    T.eq(#s:hex(), 8)
  end)

  T.it("reset() starts over", function()
    local s = crc32.stream()
    s:update("garbage data to be discarded")
    s:reset()
    s:update("123456789")
    T.eq(s:finish(), crc32.compute("123456789"))
  end)

  T.it("multiple streams are independent", function()
    local s1 = crc32.stream()
    local s2 = crc32.stream()
    s1:update("aaa")
    s2:update("bbb")
    T.neq(s1:finish(), s2:finish())
    T.eq(s1:finish(), crc32.compute("aaa"))
    T.eq(s2:finish(), crc32.compute("bbb"))
  end)

  T.it("byte-by-byte streaming matches whole-string compute", function()
    local data = "The quick brown fox jumps over the lazy dog"
    local s = crc32.stream()
    for i = 1, #data do
      s:update(data:sub(i, i))
    end
    T.eq(s:finish(), crc32.compute(data))
  end)
end)

-- ---------------------------------------------------------------------------
-- M.combine
-- ---------------------------------------------------------------------------

T.describe("crc32.combine", function()
  T.it("combine(CRC(A), CRC(B), #B) == CRC(A..B) for 'hello'/'world'", function()
    local a, b = "hello ", "world"
    local crc_a = crc32.compute(a)
    local crc_b = crc32.compute(b)
    local crc_ab = crc32.compute(a .. b)
    T.eq(crc32.combine(crc_a, crc_b, #b), crc_ab)
  end)

  T.it("combine with empty second block returns crc1", function()
    local crc_a = crc32.compute("hello")
    T.eq(crc32.combine(crc_a, 0, 0), crc_a)
  end)

  T.it("combine('', CRC(B), #B) == CRC(B)", function()
    local b = "world"
    local crc_a = crc32.compute("")
    local crc_b = crc32.compute(b)
    T.eq(crc32.combine(crc_a, crc_b, #b), crc_b)
  end)

  T.it("combine works for '123456789' split at 5", function()
    local data = "123456789"
    local a, b = data:sub(1, 5), data:sub(6)
    local combined = crc32.combine(crc32.compute(a), crc32.compute(b), #b)
    T.eq(combined, crc32.compute(data))
  end)

  T.it("combine works for long strings", function()
    local a = string.rep("abcdefgh", 100)  -- 800 bytes
    local b = string.rep("ijklmnop", 200)  -- 1600 bytes
    local combined = crc32.combine(crc32.compute(a), crc32.compute(b), #b)
    T.eq(combined, crc32.compute(a .. b))
  end)

  T.it("combine is consistent with multi-chunk streaming", function()
    local chunks = { "The ", "quick ", "brown ", "fox" }
    local full = table.concat(chunks)
    -- Build expected CRC via streaming
    local expected = crc32.compute(full)
    -- Build via combine
    local acc_crc = crc32.compute(chunks[1])
    for i = 2, #chunks do
      acc_crc = crc32.combine(acc_crc, crc32.compute(chunks[i]), #chunks[i])
    end
    T.eq(acc_crc, expected)
  end)
end)

-- ---------------------------------------------------------------------------
-- Cross-check: compute == stream on varied inputs
-- ---------------------------------------------------------------------------

T.describe("crc32 parity: compute vs stream", function()
  local cases = {
    "",
    "a",
    "abc",
    "123456789",
    "Hello, World!",
    string.rep("\0", 16),
    string.rep("\xFF", 16),
    "The quick brown fox jumps over the lazy dog",
  }
  for _, data in ipairs(cases) do
    T.it("parity for " .. string.format("%q", data:sub(1, 20)), function()
      local s = crc32.stream()
      s:update(data)
      T.eq(s:finish(), crc32.compute(data))
    end)
  end
end)
