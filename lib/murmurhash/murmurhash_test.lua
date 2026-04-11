-- lib/murmurhash/murmurhash_test.lua
-- Tests for MurmurHash3 x86_32, x86_128, and x64_128 variants.
-- All test vectors are verified against the reference C implementation and
-- against the Python mmh3 library.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local mmh = require("lib.murmurhash")
local T   = require("lib.test.assert")
local bit = require("bit")

T.describe("lib.murmurhash", function()

  T.describe("tier", function()
    T.it("_tier is 'pure'", function()
      T.eq(mmh._tier, "pure")
    end)
  end)

  -- -------------------------------------------------------------------------
  -- x86_32
  -- -------------------------------------------------------------------------

  T.describe("x86_32", function()
    T.it("empty string, seed=0 returns 0", function()
      T.eq(mmh.x86_32("", 0), 0)
    end)

    T.it("null byte, seed=0", function()
      T.eq(mmh.x86_32_hex("\x00", 0), "514e28b7")
    end)

    T.it("hello, seed=0", function()
      -- Reference (C + python mmh3): 0x248bfa47
      T.eq(mmh.x86_32_hex("hello", 0), "248bfa47")
    end)

    T.it("seed affects output", function()
      local h0 = mmh.x86_32("hello", 0)
      local h42 = mmh.x86_32("hello", 42)
      T.neq(h0, h42)
      T.eq(mmh.x86_32_hex("hello", 42), "e2dbd2e1")
    end)

    T.it("deterministic — same input, same output", function()
      local h1 = mmh.x86_32("hello", 0)
      local h2 = mmh.x86_32("hello", 0)
      T.eq(h1, h2)
    end)

    T.it("different strings produce different hashes", function()
      T.neq(mmh.x86_32("hello", 0), mmh.x86_32("world", 0))
      T.neq(mmh.x86_32("abc",   0), mmh.x86_32("abd",   0))
    end)

    T.it("x86_32_hex returns 8-character lowercase hex string", function()
      local hex = mmh.x86_32_hex("hello", 0)
      T.eq(type(hex), "string")
      T.eq(#hex, 8)
      T.ok(hex:match("^[0-9a-f]+$"))
    end)

    T.it("various lengths — 1 byte tail (rem=1)", function()
      T.eq(mmh.x86_32_hex("a", 0), "3c2569b2")
    end)

    T.it("various lengths — 2 byte tail (rem=2)", function()
      T.eq(mmh.x86_32_hex("ab", 0), "9bbfd75f")
    end)

    T.it("various lengths — 3 byte tail (rem=3)", function()
      T.eq(mmh.x86_32_hex("abc", 0), "b3dd93fa")
    end)

    T.it("various lengths — 4 bytes (one full block, no tail)", function()
      T.eq(mmh.x86_32_hex("abcd", 0), "43ed676a")
    end)

    T.it("various lengths — 5 bytes (one block + 1 byte tail)", function()
      T.eq(mmh.x86_32_hex("abcde", 0), "e89b9af6")
    end)

    T.it("various lengths — 8 bytes (two full blocks)", function()
      T.eq(mmh.x86_32_hex("abcdefgh", 0), "49ddccc4")
    end)

    T.it("various lengths — 16 bytes (four full blocks)", function()
      T.eq(mmh.x86_32_hex("abcdefghijklmnop", 0), "e76291ed")
    end)

    T.it("various lengths — 17 bytes (four blocks + 1 byte tail)", function()
      T.eq(mmh.x86_32_hex("abcdefghijklmnopq", 0), "b6655e4a")
    end)

    T.it("returns nil, errmsg on non-string key", function()
      local r, err = mmh.x86_32(42, 0)
      T.eq(r, nil)
      T.ok(err ~= nil)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- x86_128
  -- -------------------------------------------------------------------------

  T.describe("x86_128", function()
    T.it("empty string, seed=0 returns four zeros", function()
      local h1, h2, h3, h4 = mmh.x86_128("", 0)
      T.eq(h1, 0)
      T.eq(h2, 0)
      T.eq(h3, 0)
      T.eq(h4, 0)
    end)

    T.it("empty string hex is 32 zeros", function()
      T.eq(mmh.x86_128_hex("", 0), ("0"):rep(32))
    end)

    T.it("hello, seed=0 (verified against C reference)", function()
      -- C reference: 2b2444a0 db91def7 9adb31b6 9adb31b6
      T.eq(mmh.x86_128_hex("hello", 0), "2b2444a0db91def79adb31b69adb31b6")
    end)

    T.it("seed affects output", function()
      T.neq(mmh.x86_128_hex("hello", 0), mmh.x86_128_hex("hello", 42))
      T.eq(mmh.x86_128_hex("hello", 42), "9c4f9a01053404f6886f9b95886f9b95")
    end)

    T.it("full block (16 bytes), seed=0 (verified against C reference)", function()
      -- C reference: 9fd27627 90b91256 e4ce8b21 d193ba45
      T.eq(mmh.x86_128_hex("abcdefghijklmnop", 0), "9fd2762790b91256e4ce8b21d193ba45")
    end)

    T.it("full block + tail (17 bytes)", function()
      T.eq(mmh.x86_128_hex("abcdefghijklmnopq", 0), "0445a4d364515c6fd96ddc2a1d11079d")
    end)

    T.it("x86_128_hex returns 32-character lowercase hex string", function()
      local hex = mmh.x86_128_hex("hello", 0)
      T.eq(type(hex), "string")
      T.eq(#hex, 32)
      T.ok(hex:match("^[0-9a-f]+$"))
    end)

    T.it("deterministic", function()
      T.eq(mmh.x86_128_hex("hello", 0), mmh.x86_128_hex("hello", 0))
    end)

    T.it("different strings produce different hashes", function()
      T.neq(mmh.x86_128_hex("hello", 0), mmh.x86_128_hex("world", 0))
    end)

    T.it("returns nil, errmsg on non-string key", function()
      local r, err = mmh.x86_128(nil, 0)
      T.eq(r, nil)
      T.ok(err ~= nil)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- x64_128
  -- -------------------------------------------------------------------------

  T.describe("x64_128", function()
    T.it("empty string, seed=0 returns zero, zero", function()
      local ffi = require("ffi")
      local h1, h2 = mmh.x64_128("", 0)
      T.eq(tonumber(h1), 0)
      T.eq(tonumber(h2), 0)
    end)

    T.it("empty string hex is 32 zeros", function()
      T.eq(mmh.x64_128_hex("", 0), ("0"):rep(32))
    end)

    T.it("hello, seed=0 (verified against python mmh3 + C reference)", function()
      -- python mmh3: h1=0xcbd8a7b341bd9b02, h2=0x5b1e906a48ae1d19
      T.eq(mmh.x64_128_hex("hello", 0), "cbd8a7b341bd9b025b1e906a48ae1d19")
    end)

    T.it("seed affects output", function()
      T.neq(mmh.x64_128_hex("hello", 0), mmh.x64_128_hex("hello", 42))
      T.eq(mmh.x64_128_hex("hello", 42), "c4b8b3c960af6f082334b875b0efbc7a")
    end)

    T.it("full block (16 bytes)", function()
      T.eq(mmh.x64_128_hex("abcdefghijklmnop", 0), "c4ca3ca3224cb7234333d695b331eb1a")
    end)

    T.it("full block + tail (17 bytes)", function()
      T.eq(mmh.x64_128_hex("abcdefghijklmnopq", 0), "7564747f88bda657ecda499da1110de4")
    end)

    T.it("x64_128_hex returns 32-character lowercase hex string", function()
      local hex = mmh.x64_128_hex("hello", 0)
      T.eq(type(hex), "string")
      T.eq(#hex, 32)
      T.ok(hex:match("^[0-9a-f]+$"))
    end)

    T.it("deterministic", function()
      T.eq(mmh.x64_128_hex("hello", 0), mmh.x64_128_hex("hello", 0))
    end)

    T.it("different strings produce different hashes", function()
      T.neq(mmh.x64_128_hex("hello", 0), mmh.x64_128_hex("world", 0))
    end)

    T.it("returns nil, errmsg on non-string key", function()
      local r, err = mmh.x64_128(42, 0)
      T.eq(r, nil)
      T.ok(err ~= nil)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- Aliases
  -- -------------------------------------------------------------------------

  T.describe("aliases", function()
    T.it("hash32 is x86_32", function()
      T.eq(mmh.hash32, mmh.x86_32)
    end)

    T.it("hash128 is x64_128", function()
      T.eq(mmh.hash128, mmh.x64_128)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- Avalanche / diffusion
  -- -------------------------------------------------------------------------

  T.describe("avalanche", function()
    T.it("flipping one bit in x86_32 input changes >= 25% of output bits", function()
      -- 'hello' vs 'hfllo': bit 0 of byte 1 differs (e=0x65 vs f=0x66)
      local h_a = mmh.x86_32("hello", 0)
      local h_b = mmh.x86_32("hfllo", 0)
      local diff = bit.bxor(h_a, h_b)
      local changed = 0
      for i = 0, 31 do
        if bit.band(bit.rshift(diff, i), 1) ~= 0 then
          changed = changed + 1
        end
      end
      -- At least 8 of 32 bits changed (25%)
      T.ok(changed >= 8)
    end)

    T.it("similar strings hash very differently with x86_32", function()
      -- First byte differs by 1
      T.neq(mmh.x86_32("aaa", 0), mmh.x86_32("baa", 0))
      T.neq(mmh.x86_32("aaa", 0), mmh.x86_32("aba", 0))
      T.neq(mmh.x86_32("aaa", 0), mmh.x86_32("aab", 0))
      -- Prefix/suffix relations
      T.neq(mmh.x86_32("abc",  0), mmh.x86_32("abcd", 0))
      T.neq(mmh.x86_32("abcd", 0), mmh.x86_32("abcde", 0))
    end)

    T.it("x86_32 and x64_128 produce different digests for same input", function()
      -- Sanity: different algorithms should give different results
      -- (x86_32 result != first 8 hex chars of x64_128)
      local h32  = mmh.x86_32_hex("hello", 0)
      local h128 = mmh.x64_128_hex("hello", 0):sub(1, 8)
      T.neq(h32, h128)
    end)
  end)

end)
