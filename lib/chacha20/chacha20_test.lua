-- lib/chacha20/chacha20_test.lua
-- Tests for ChaCha20 stream cipher and ChaCha20-Poly1305 AEAD (RFC 7539).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local chacha  = require("lib.chacha20")

-- ---------------------------------------------------------------------------
-- Helper: hex string -> binary string
-- ---------------------------------------------------------------------------
local function from_hex(h)
  return (h:gsub("%x%x", function(c) return string.char(tonumber(c, 16) or 0) end))
end

-- Helper: binary string -> hex string
local function to_hex(s)
  local t = {}
  for i = 1, #s do
    t[i] = string.format("%02x", string.byte(s, i))
  end
  return table.concat(t)
end

-- ---------------------------------------------------------------------------
-- RFC 7539 test vectors
-- ---------------------------------------------------------------------------

-- §2.1.1 quarter-round test vector.
local QR_INPUT  = { 0x11111111, 0x01020304, 0x9b8d6f43, 0x01234567 }
local QR_OUTPUT = { 0xea2a92f4, 0xcb1cf8ce, 0x4581472e, 0x5881c4bb }

-- §2.3.2 block function test vector.
local BLOCK_KEY   = from_hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
local BLOCK_NONCE = from_hex("000000090000004a00000000")
local BLOCK_CTR   = 1
-- Expected 64-byte keystream block (from RFC 7539 §2.3.2).
local BLOCK_EXPECTED = from_hex(
  "10f1e7e4d13b5915500fdd1fa32071c4" ..
  "c7d1f4c733c068030422aa9ac3d46c4e" ..
  "d2826446079faa0914c2d705d98b02a2" ..
  "b5129cd1de164eb9cbd083e8a2503c4e"
)

-- §2.8.2 AEAD test vector.
local AEAD_KEY      = from_hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
local AEAD_NONCE    = from_hex("070000004041424344454647")
local AEAD_PT       = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
local AEAD_AAD      = from_hex("50515253c0c1c2c3c4c5c6c7")
local AEAD_TAG_HEX  = "1ae10b594f09e26a7e902ecbd0600691"

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

T.describe("lib.chacha20", function()

  T.describe("tier", function()
    T.it("M._tier is 'pure'", function()
      T.eq(chacha._tier, "pure")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("quarter round", function()
    T.it("RFC 7539 §2.1.1 vector", function()
      local bit = require("bit")
      local s = {
        bit.tobit(QR_INPUT[1]),
        bit.tobit(QR_INPUT[2]),
        bit.tobit(QR_INPUT[3]),
        bit.tobit(QR_INPUT[4]),
      }
      chacha._quarter_round(s, 1, 2, 3, 4)
      -- Compare unsigned 32-bit: mask both sides to 0xffffffff before formatting
      -- (string.format %x on negative Lua numbers gives 16 hex digits on LuaJIT).
      local function u32hex(v)
        return string.format("%08x", bit.band(v, 0xffffffff))
      end
      T.eq(u32hex(s[1]), u32hex(bit.tobit(QR_OUTPUT[1])))
      T.eq(u32hex(s[2]), u32hex(bit.tobit(QR_OUTPUT[2])))
      T.eq(u32hex(s[3]), u32hex(bit.tobit(QR_OUTPUT[3])))
      T.eq(u32hex(s[4]), u32hex(bit.tobit(QR_OUTPUT[4])))
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("block function", function()
    T.it("RFC 7539 §2.3.2: first 4 bytes", function()
      local block = chacha._chacha20_block(BLOCK_KEY, BLOCK_CTR, BLOCK_NONCE)
      T.eq(to_hex(block:sub(1, 4)), to_hex(BLOCK_EXPECTED:sub(1, 4)))
    end)

    T.it("RFC 7539 §2.3.2: full 64-byte block", function()
      local block = chacha._chacha20_block(BLOCK_KEY, BLOCK_CTR, BLOCK_NONCE)
      T.eq(#block, 64)
      T.eq(to_hex(block), to_hex(BLOCK_EXPECTED))
    end)

    T.it("block is 64 bytes", function()
      local k = ("\x00"):rep(32)
      local n = ("\x00"):rep(12)
      local b = chacha._chacha20_block(k, 0, n)
      T.eq(#b, 64)
    end)

    T.it("different counters produce different blocks", function()
      local k = ("\x00"):rep(32)
      local n = ("\x00"):rep(12)
      local b0 = chacha._chacha20_block(k, 0, n)
      local b1 = chacha._chacha20_block(k, 1, n)
      T.neq(b0, b1)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("encrypt/decrypt", function()
    T.it("RFC 7539 §2.3.2: keystream matches block output", function()
      -- Encrypting 64 zero bytes at counter=1 should equal the block output.
      local zeros = ("\x00"):rep(64)
      local ct, err = chacha.encrypt(BLOCK_KEY, BLOCK_NONCE, zeros, BLOCK_CTR)
      T.eq(err, nil)
      T.eq(to_hex(ct), to_hex(BLOCK_EXPECTED))
    end)

    T.it("round-trip: decrypt(encrypt(x)) == x", function()
      local k = ("\x42"):rep(32)
      local n = ("\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c")
      local pt = "Hello, ChaCha20 world! This is a test message for round-trip."
      local ct, err1 = chacha.encrypt(k, n, pt)
      T.eq(err1, nil)
      local pt2, err2 = chacha.decrypt(k, n, ct)
      T.eq(err2, nil)
      T.eq(pt2, pt)
    end)

    T.it("empty plaintext", function()
      local k = ("\x00"):rep(32)
      local n = ("\x00"):rep(12)
      local ct, err = chacha.encrypt(k, n, "")
      T.eq(err, nil)
      T.eq(ct, "")
    end)

    T.it("non-block-aligned length (1 byte)", function()
      local k = ("\x00"):rep(32)
      local n = ("\x00"):rep(12)
      local ct, err = chacha.encrypt(k, n, "\xab", 1)
      T.eq(err, nil)
      T.eq(#ct, 1)
      -- Decrypting should recover original.
      local pt, _ = chacha.decrypt(k, n, ct, 1)
      T.eq(pt, "\xab")
    end)

    T.it("non-block-aligned length (65 bytes)", function()
      local k = ("\xde"):rep(32)
      local n = ("\xad"):rep(12)
      local pt = ("A"):rep(65)
      local ct, err = chacha.encrypt(k, n, pt)
      T.eq(err, nil)
      T.eq(#ct, 65)
      local dec, _ = chacha.decrypt(k, n, ct)
      T.eq(dec, pt)
    end)

    T.it("encrypt and decrypt are identical functions", function()
      local k = ("\x11"):rep(32)
      local n = ("\x22"):rep(12)
      local msg = "symmetric XOR cipher"
      local ct, _ = chacha.encrypt(k, n, msg)
      local pt, _ = chacha.decrypt(k, n, ct)
      T.eq(pt, msg)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("keystream", function()
    T.it("length matches requested", function()
      local k = ("\x00"):rep(32)
      local n = ("\x00"):rep(12)
      local ks, err = chacha.keystream(k, n, 100)
      T.eq(err, nil)
      T.eq(#ks, 100)
    end)

    T.it("zero length returns empty string", function()
      local k = ("\x00"):rep(32)
      local n = ("\x00"):rep(12)
      local ks, err = chacha.keystream(k, n, 0)
      T.eq(err, nil)
      T.eq(ks, "")
    end)

    T.it("consistent with encrypt (XOR zeros)", function()
      local k = ("\x55"):rep(32)
      local n = ("\xaa"):rep(12)
      local ks, _ = chacha.keystream(k, n, 50, 1)
      local ct, _ = chacha.encrypt(k, n, ("\x00"):rep(50), 1)
      T.eq(ks, ct)
    end)

    T.it("64-byte keystream matches block function", function()
      local k = BLOCK_KEY
      local n = BLOCK_NONCE
      local ks, _ = chacha.keystream(k, n, 64, BLOCK_CTR)
      T.eq(to_hex(ks), to_hex(BLOCK_EXPECTED))
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("aead_encrypt/aead_decrypt", function()
    T.it("RFC 7539 §2.8.2: tag matches", function()
      local ct_tag, err = chacha.aead_encrypt(AEAD_KEY, AEAD_NONCE, AEAD_PT, AEAD_AAD)
      T.eq(err, nil)
      T.ok(ct_tag ~= nil)
      -- Tag is the last 16 bytes.
      local tag = ct_tag:sub(#ct_tag - 15)
      T.eq(to_hex(tag), AEAD_TAG_HEX)
    end)

    T.it("RFC 7539 §2.8.2: ciphertext length correct", function()
      local ct_tag, _ = chacha.aead_encrypt(AEAD_KEY, AEAD_NONCE, AEAD_PT, AEAD_AAD)
      -- ciphertext is same length as plaintext; total = plaintext + 16-byte tag.
      T.eq(#ct_tag, #AEAD_PT + 16)
    end)

    T.it("round-trip with AAD", function()
      local k = ("\x01"):rep(32)
      local n = ("\x02"):rep(12)
      local pt = "Secret message for AEAD round-trip test."
      local aad = "authenticated header"
      local ct_tag, err1 = chacha.aead_encrypt(k, n, pt, aad)
      T.eq(err1, nil)
      local pt2, err2 = chacha.aead_decrypt(k, n, ct_tag, aad)
      T.eq(err2, nil)
      T.eq(pt2, pt)
    end)

    T.it("round-trip without AAD", function()
      local k = ("\x03"):rep(32)
      local n = ("\x04"):rep(12)
      local pt = "Message without additional data."
      local ct_tag, err1 = chacha.aead_encrypt(k, n, pt)
      T.eq(err1, nil)
      local pt2, err2 = chacha.aead_decrypt(k, n, ct_tag)
      T.eq(err2, nil)
      T.eq(pt2, pt)
    end)

    T.it("round-trip with empty plaintext", function()
      local k = ("\x05"):rep(32)
      local n = ("\x06"):rep(12)
      local ct_tag, err1 = chacha.aead_encrypt(k, n, "", "aad")
      T.eq(err1, nil)
      T.eq(#ct_tag, 16)  -- just the tag
      local pt, err2 = chacha.aead_decrypt(k, n, ct_tag, "aad")
      T.eq(err2, nil)
      T.eq(pt, "")
    end)

    T.it("tampered ciphertext -> authentication failed", function()
      local k = ("\x07"):rep(32)
      local n = ("\x08"):rep(12)
      local pt = "Tamper test: flip a bit in the ciphertext."
      local ct_tag, _ = chacha.aead_encrypt(k, n, pt, "aad")
      -- Flip one byte in the ciphertext portion.
      local tampered = ct_tag:sub(1, 1):byte(1)
      local flipped = string.char(bit.bxor(tampered, 0xff))
      local bad = flipped .. ct_tag:sub(2)
      local result, err = chacha.aead_decrypt(k, n, bad, "aad")
      T.eq(result, nil)
      T.eq(err, "authentication failed")
    end)

    T.it("tampered tag -> authentication failed", function()
      local k = ("\x09"):rep(32)
      local n = ("\x0a"):rep(12)
      local pt = "Tamper test: flip a bit in the tag."
      local ct_tag, _ = chacha.aead_encrypt(k, n, pt, "aad")
      -- Flip one byte in the tag (last 16 bytes).
      local tag_start = #ct_tag - 15
      local tampered_byte = string.char(bit.bxor(ct_tag:sub(tag_start, tag_start):byte(1), 0x01))
      local bad = ct_tag:sub(1, tag_start - 1) .. tampered_byte .. ct_tag:sub(tag_start + 1)
      local result, err = chacha.aead_decrypt(k, n, bad, "aad")
      T.eq(result, nil)
      T.eq(err, "authentication failed")
    end)

    T.it("tampered AAD -> authentication failed", function()
      local k = ("\x0b"):rep(32)
      local n = ("\x0c"):rep(12)
      local pt = "Tamper test: wrong AAD."
      local ct_tag, _ = chacha.aead_encrypt(k, n, pt, "correct aad")
      local result, err = chacha.aead_decrypt(k, n, ct_tag, "wrong aad")
      T.eq(result, nil)
      T.eq(err, "authentication failed")
    end)

    T.it("wrong key -> authentication failed", function()
      local k1 = ("\x11"):rep(32)
      local k2 = ("\x22"):rep(32)
      local n  = ("\x00"):rep(12)
      local ct_tag, _ = chacha.aead_encrypt(k1, n, "hello", "")
      local result, err = chacha.aead_decrypt(k2, n, ct_tag, "")
      T.eq(result, nil)
      T.eq(err, "authentication failed")
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("errors", function()
    T.it("encrypt: wrong key length", function()
      local ct, err = chacha.encrypt(("\x00"):rep(16), ("\x00"):rep(12), "hi")
      T.eq(ct, nil)
      T.ok(type(err) == "string")
    end)

    T.it("encrypt: wrong nonce length", function()
      local ct, err = chacha.encrypt(("\x00"):rep(32), ("\x00"):rep(8), "hi")
      T.eq(ct, nil)
      T.ok(type(err) == "string")
    end)

    T.it("decrypt: wrong key length", function()
      local pt, err = chacha.decrypt("short", ("\x00"):rep(12), "hi")
      T.eq(pt, nil)
      T.ok(type(err) == "string")
    end)

    T.it("keystream: negative n", function()
      local ks, err = chacha.keystream(("\x00"):rep(32), ("\x00"):rep(12), -1)
      T.eq(ks, nil)
      T.ok(type(err) == "string")
    end)

    T.it("keystream: non-integer n", function()
      local ks, err = chacha.keystream(("\x00"):rep(32), ("\x00"):rep(12), 1.5)
      T.eq(ks, nil)
      T.ok(type(err) == "string")
    end)

    T.it("aead_encrypt: wrong key length", function()
      local ct, err = chacha.aead_encrypt(("\x00"):rep(16), ("\x00"):rep(12), "msg", "")
      T.eq(ct, nil)
      T.ok(type(err) == "string")
    end)

    T.it("aead_decrypt: too short (no room for tag)", function()
      local pt, err = chacha.aead_decrypt(("\x00"):rep(32), ("\x00"):rep(12), "short")
      T.eq(pt, nil)
      T.ok(type(err) == "string")
    end)
  end)

end)
