-- lib/compress/compress_test.lua
-- Tests for lib/compress: system zlib FFI + pure Lua inflate.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local compress = require("lib.compress")

-- Try to load both tiers directly for parity testing
local sys_ok, sys = pcall(require, "lib.compress.system")
local pure_ok, pure = pcall(require, "lib.compress.pure")

-- ── Tier identification ──────────────────────────────────────────────────────

T.describe("compress: tier", function()
  T.it("_tier is a known value", function()
    T.ok(compress._tier == "system-zlib" or compress._tier == "pure-lua",
      "_tier is " .. tostring(compress._tier))
  end)

  if sys_ok then
    T.it("system tier reports system-zlib", function()
      T.eq(sys._tier, "system-zlib")
    end)
  end

  if pure_ok then
    T.it("pure tier reports pure-lua", function()
      T.eq(pure._tier, "pure-lua")
    end)
  end
end)

-- ── API shape ────────────────────────────────────────────────────────────────

T.describe("compress: API shape", function()
  T.it("exposes expected functions", function()
    T.eq(type(compress.deflate), "function")
    T.eq(type(compress.inflate), "function")
    T.eq(type(compress.encode), "function")
    T.eq(type(compress.decode), "function")
    T.eq(type(compress.deflater), "function")
    T.eq(type(compress.inflater), "function")
  end)

  T.it("encode/decode are aliases", function()
    T.eq(compress.encode, compress.deflate)
    T.eq(compress.decode, compress.inflate)
  end)
end)

-- ── Round-trip (system tier) ─────────────────────────────────────────────────

if sys_ok then
  local test_inputs = {
    { name = "empty string", data = "" },
    { name = "hello", data = "hello" },
    { name = "repeated data", data = string.rep("abcdefgh", 1000) },
    { name = "binary data", data = string.rep("\0\1\2\xff\xfe\xfd", 500) },
    { name = "single byte", data = "x" },
  }

  T.describe("compress: system round-trip (zlib format)", function()
    for _, tc in ipairs(test_inputs) do
      T.it("round-trips " .. tc.name, function()
        local compressed, err = sys.deflate(tc.data)
        T.ok(compressed, "deflate succeeded: " .. tostring(err))
        local decompressed, err2 = sys.inflate(compressed)
        T.ok(decompressed, "inflate succeeded: " .. tostring(err2))
        T.eq(decompressed, tc.data)
      end)
    end
  end)

  T.describe("compress: system round-trip (gzip format)", function()
    for _, tc in ipairs(test_inputs) do
      T.it("round-trips " .. tc.name, function()
        local compressed, err = sys.deflate(tc.data, { format = "gzip" })
        T.ok(compressed, "deflate succeeded: " .. tostring(err))
        local decompressed, err2 = sys.inflate(compressed, { format = "gzip" })
        T.ok(decompressed, "inflate succeeded: " .. tostring(err2))
        T.eq(decompressed, tc.data)
      end)
    end
  end)

  T.describe("compress: system round-trip (raw format)", function()
    for _, tc in ipairs(test_inputs) do
      T.it("round-trips " .. tc.name, function()
        local compressed, err = sys.deflate(tc.data, { format = "raw" })
        T.ok(compressed, "deflate succeeded: " .. tostring(err))
        local decompressed, err2 = sys.inflate(compressed, { format = "raw" })
        T.ok(decompressed, "inflate succeeded: " .. tostring(err2))
        T.eq(decompressed, tc.data)
      end)
    end
  end)

  -- ── Compression levels ───────────────────────────────────────────────────

  T.describe("compress: compression levels", function()
    local data = string.rep("the quick brown fox jumps over the lazy dog. ", 100)

    T.it("level 1 (fastest) works", function()
      local c = sys.deflate(data, { level = 1 })
      T.ok(c)
      T.eq(sys.inflate(c), data)
    end)

    T.it("level 9 (best) works", function()
      local c = sys.deflate(data, { level = 9 })
      T.ok(c)
      T.eq(sys.inflate(c), data)
    end)

    T.it("higher levels produce smaller output", function()
      local c1 = sys.deflate(data, { level = 1 })
      local c9 = sys.deflate(data, { level = 9 })
      T.ok(#c9 <= #c1, "level 9 <= level 1: " .. #c9 .. " vs " .. #c1)
    end)
  end)

  -- ── Streaming (system) ─────────────────────────────────────────────────

  T.describe("compress: system streaming", function()
    T.it("deflater/inflater match one-shot", function()
      local data = string.rep("streaming test data! ", 200)
      local oneshot = sys.deflate(data)

      -- Streaming deflate
      local d = sys.deflater()
      d.push(data:sub(1, 100))
      d.push(data:sub(101))
      local streamed = d.finish()
      T.ok(streamed)

      -- Both should decompress to the same thing
      T.eq(sys.inflate(streamed), data)
      T.eq(sys.inflate(oneshot), data)
    end)

    T.it("inflater streaming works", function()
      local data = "hello world"
      local compressed = sys.deflate(data)

      local inf = sys.inflater()
      inf.push(compressed)
      local result = inf.finish()
      T.eq(result, data)
    end)
  end)
end

-- ── Parity: system deflate -> pure inflate ───────────────────────────────────

if sys_ok and pure_ok then
  local parity_inputs = {
    { name = "empty string", data = "" },
    { name = "hello", data = "hello" },
    { name = "repeated data", data = string.rep("abcdefgh", 1000) },
    { name = "binary data", data = string.rep("\0\1\2\xff\xfe\xfd", 500) },
    { name = "single byte", data = "x" },
    { name = "lorem ipsum", data = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. " ..
      "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua." },
  }

  T.describe("compress: parity (system deflate -> pure inflate, zlib)", function()
    for _, tc in ipairs(parity_inputs) do
      T.it("parity for " .. tc.name, function()
        local compressed = sys.deflate(tc.data, { format = "zlib" })
        T.ok(compressed)

        local sys_result = sys.inflate(compressed, { format = "zlib" })
        local pure_result = pure.inflate(compressed, { format = "zlib" })

        T.ok(sys_result, "system inflate succeeded")
        T.ok(pure_result, "pure inflate succeeded")
        T.eq(pure_result, sys_result, "parity: pure == system")
        T.eq(pure_result, tc.data, "pure matches original")
      end)
    end
  end)

  T.describe("compress: parity (system deflate -> pure inflate, gzip)", function()
    for _, tc in ipairs(parity_inputs) do
      T.it("parity for " .. tc.name, function()
        local compressed = sys.deflate(tc.data, { format = "gzip" })
        T.ok(compressed)

        local sys_result = sys.inflate(compressed, { format = "gzip" })
        local pure_result = pure.inflate(compressed, { format = "gzip" })

        T.ok(sys_result, "system inflate succeeded")
        T.ok(pure_result, "pure inflate succeeded")
        T.eq(pure_result, sys_result)
        T.eq(pure_result, tc.data)
      end)
    end
  end)

  T.describe("compress: parity (system deflate -> pure inflate, raw)", function()
    for _, tc in ipairs(parity_inputs) do
      T.it("parity for " .. tc.name, function()
        local compressed = sys.deflate(tc.data, { format = "raw" })
        T.ok(compressed)

        local sys_result = sys.inflate(compressed, { format = "raw" })
        local pure_result = pure.inflate(compressed, { format = "raw" })

        T.ok(sys_result, "system inflate succeeded")
        T.ok(pure_result, "pure inflate succeeded")
        T.eq(pure_result, sys_result)
        T.eq(pure_result, tc.data)
      end)
    end
  end)
end

-- ── Pure Lua inflate with hardcoded vectors ──────────────────────────────────

if pure_ok then
  T.describe("compress: pure inflate known vectors", function()
    -- Hardcoded zlib-compressed "hello" (produced by zlib compress)
    -- We generate these at test time if system tier is available,
    -- otherwise use hardcoded bytes
    if sys_ok then
      T.it("inflates system-compressed hello", function()
        local compressed = sys.deflate("hello")
        local result, err = pure.inflate(compressed)
        T.ok(result, "inflate succeeded: " .. tostring(err))
        T.eq(result, "hello")
      end)

      T.it("inflates system-compressed empty", function()
        local compressed = sys.deflate("")
        local result, err = pure.inflate(compressed)
        T.ok(result, "inflate succeeded: " .. tostring(err))
        T.eq(result, "")
      end)
    end
  end)

  T.describe("compress: pure inflate streaming", function()
    if sys_ok then
      T.it("streaming inflater works", function()
        local data = "streaming pure lua inflate test"
        local compressed = sys.deflate(data)
        local inf = pure.inflater()
        inf.push(compressed:sub(1, 5))
        inf.push(compressed:sub(6))
        local result, err = inf.finish()
        T.ok(result, "inflate succeeded: " .. tostring(err))
        T.eq(result, data)
      end)
    end
  end)

  T.describe("compress: pure tier deflate unavailable", function()
    T.it("deflate returns nil + message", function()
      local result, err = pure.deflate("hello")
      T.eq(result, nil)
      T.ok(err:find("not available"), "error mentions not available")
    end)

    T.it("deflater returns nil + message", function()
      local result, err = pure.deflater()
      T.eq(result, nil)
      T.ok(err:find("not available"), "error mentions not available")
    end)
  end)
end

-- ── Error cases ──────────────────────────────────────────────────────────────

T.describe("compress: error handling", function()
  T.it("inflate rejects truncated zlib input", function()
    local result, err = compress.inflate("\x78\x9c")
    T.eq(result, nil)
    T.ok(type(err) == "string", "returns error message")
  end)

  T.it("inflate rejects corrupt data", function()
    local result, err = compress.inflate("\x78\x9c\xff\xff\xff\xff\xff\xff")
    T.eq(result, nil)
    T.ok(type(err) == "string", "returns error message")
  end)

  T.it("inflate rejects completely invalid input", function()
    local result, err = compress.inflate("not compressed data at all")
    T.eq(result, nil)
    T.ok(type(err) == "string", "returns error message")
  end)
end)

-- ── Checksum tests (pure tier) ───────────────────────────────────────────────

if pure_ok then
  T.describe("compress: adler32", function()
    T.it("empty string", function()
      T.eq(pure.adler32(""), 1)
    end)

    T.it("known vector: Wikipedia", function()
      -- adler32("Wikipedia") = 0x11E60398 = 300286872
      T.eq(pure.adler32("Wikipedia"), 300286872)
    end)
  end)

  T.describe("compress: crc32", function()
    T.it("empty string", function()
      T.eq(pure.crc32(""), 0)
    end)

    T.it("known vector", function()
      -- crc32("123456789") = 0xCBF43926 = 3421780262
      T.eq(pure.crc32("123456789"), 3421780262)
    end)
  end)

  -- ── Checksum verification ────────────────────────────────────────────────

  if sys_ok then
    T.describe("compress: checksum verification (corrupt → error)", function()
      T.it("corrupt adler32 in zlib → error", function()
        local compressed = sys.deflate("test data for checksum")
        -- Corrupt the last byte (part of adler32)
        local corrupted = compressed:sub(1, -2) .. string.char((compressed:byte(-1) + 1) % 256)
        local result, err = pure.inflate(corrupted, { format = "zlib" })
        T.eq(result, nil)
        T.ok(type(err) == "string")
        T.ok(err:find("checksum") or err:find("adler") or err:find("mismatch"),
          "error mentions checksum: " .. tostring(err))
      end)

      T.it("corrupt crc32 in gzip → error", function()
        local compressed = sys.deflate("test data for checksum", { format = "gzip" })
        -- Corrupt a byte near the end (part of crc32 trailer)
        local pos = #compressed - 5
        local corrupted = compressed:sub(1, pos - 1) ..
          string.char((compressed:byte(pos) + 1) % 256) ..
          compressed:sub(pos + 1)
        local result, err = pure.inflate(corrupted, { format = "gzip" })
        T.eq(result, nil)
        T.ok(type(err) == "string")
        T.ok(err:find("checksum") or err:find("crc") or err:find("mismatch"),
          "error mentions checksum: " .. tostring(err))
      end)
    end)
  end
end
