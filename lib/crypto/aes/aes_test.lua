-- lib/crypto/aes/aes_test.lua
-- Tests for AES block cipher: NIST FIPS 197 vectors, ECB, CBC, CTR, PKCS#7.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local T = require("lib.test.assert")
local aes = require("lib.crypto.aes")

-- Helpers: hex <-> string
local function hex_to_str(hex)
  return (hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

local function str_to_hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end

T.describe("lib.crypto.aes", function()

  T.describe("tier", function()
    T.it("has _tier = 'pure'", function()
      T.eq(aes._tier, "pure")
    end)
  end)

  -- -------------------------------------------------------------------------
  -- NIST FIPS 197 Appendix B: AES-128 step-by-step example
  -- Key:       2b7e151628aed2a6abf7158809cf4f3c
  -- Plaintext: 3243f6a8885a308d313198a2e0370734
  -- Cipher:    3925841d02dc09fbdc118597196a0b32
  -- -------------------------------------------------------------------------
  T.describe("NIST FIPS 197 Appendix B (AES-128)", function()
    local key = hex_to_str("2b7e151628aed2a6abf7158809cf4f3c")
    local pt  = hex_to_str("3243f6a8885a308d313198a2e0370734")
    local ct  = hex_to_str("3925841d02dc09fbdc118597196a0b32")

    T.it("encrypt_block matches FIPS 197 Appendix B", function()
      local result = aes.encrypt_block(key, pt)
      T.eq(str_to_hex(result), "3925841d02dc09fbdc118597196a0b32")
    end)

    T.it("decrypt_block inverts encrypt_block", function()
      local result = aes.decrypt_block(key, ct)
      T.eq(str_to_hex(result), "3243f6a8885a308d313198a2e0370734")
    end)
  end)

  -- -------------------------------------------------------------------------
  -- AES-128 ECB known vector (verified against OpenSSL)
  -- Key:       000102030405060708090a0b0c0d0e0f
  -- Plaintext: 00112233445566778899aabbccddeeff
  -- Cipher:    69c4e0d86a7b0430d8cdb78070b4c55a
  -- -------------------------------------------------------------------------
  T.describe("NIST FIPS 197 Appendix C.1 (AES-128 ECB)", function()
    local key = hex_to_str("000102030405060708090a0b0c0d0e0f")
    local pt  = hex_to_str("00112233445566778899aabbccddeeff")
    local ct  = hex_to_str("69c4e0d86a7b0430d8cdb78070b4c55a")

    T.it("encrypt_block matches", function()
      T.eq(str_to_hex(aes.encrypt_block(key, pt)), "69c4e0d86a7b0430d8cdb78070b4c55a")
    end)

    T.it("decrypt_block matches", function()
      T.eq(str_to_hex(aes.decrypt_block(key, ct)), "00112233445566778899aabbccddeeff")
    end)
  end)

  -- -------------------------------------------------------------------------
  -- NIST FIPS 197 Appendix C.2: AES-192 ECB
  -- Key:       000102030405060708090a0b0c0d0e0f1011121314151617
  -- Plaintext: 00112233445566778899aabbccddeeff
  -- Cipher:    dda97ca4864cdfe06eaf70a0ec0d7191
  -- -------------------------------------------------------------------------
  T.describe("NIST FIPS 197 Appendix C.2 (AES-192 ECB)", function()
    local key = hex_to_str("000102030405060708090a0b0c0d0e0f1011121314151617")
    local pt  = hex_to_str("00112233445566778899aabbccddeeff")
    local ct  = hex_to_str("dda97ca4864cdfe06eaf70a0ec0d7191")

    T.it("encrypt_block matches", function()
      T.eq(str_to_hex(aes.encrypt_block(key, pt)), "dda97ca4864cdfe06eaf70a0ec0d7191")
    end)

    T.it("decrypt_block matches", function()
      T.eq(str_to_hex(aes.decrypt_block(key, ct)), "00112233445566778899aabbccddeeff")
    end)
  end)

  -- -------------------------------------------------------------------------
  -- NIST FIPS 197 Appendix C.3: AES-256 ECB
  -- Key:       000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
  -- Plaintext: 00112233445566778899aabbccddeeff
  -- Cipher:    8ea2b7ca516745bfeafc49904b496089
  -- -------------------------------------------------------------------------
  T.describe("NIST FIPS 197 Appendix C.3 (AES-256 ECB)", function()
    local key = hex_to_str("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    local pt  = hex_to_str("00112233445566778899aabbccddeeff")
    local ct  = hex_to_str("8ea2b7ca516745bfeafc49904b496089")

    T.it("encrypt_block matches", function()
      T.eq(str_to_hex(aes.encrypt_block(key, pt)), "8ea2b7ca516745bfeafc49904b496089")
    end)

    T.it("decrypt_block matches", function()
      T.eq(str_to_hex(aes.decrypt_block(key, ct)), "00112233445566778899aabbccddeeff")
    end)
  end)

  -- -------------------------------------------------------------------------
  -- ECB multi-block round-trip
  -- -------------------------------------------------------------------------
  T.describe("ecb_encrypt / ecb_decrypt", function()
    local key = hex_to_str("2b7e151628aed2a6abf7158809cf4f3c")

    T.it("round-trips two blocks", function()
      local pt = hex_to_str("6bc1bee22e409f96e93d7e117393172a") ..
                 hex_to_str("ae2d8a571e03ac9c9eb76fac45af8e51")
      local ct = aes.ecb_encrypt(key, pt)
      local recovered = aes.ecb_decrypt(key, ct)
      T.eq(recovered, pt)
    end)

    T.it("rejects non-block-aligned input", function()
      local ok, err = aes.ecb_encrypt(key, "short")
      T.eq(ok, nil)
      T.ok(err ~= nil)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- CBC round-trip
  -- -------------------------------------------------------------------------
  T.describe("cbc_encrypt / cbc_decrypt", function()
    local key = hex_to_str("2b7e151628aed2a6abf7158809cf4f3c")
    local iv  = hex_to_str("000102030405060708090a0b0c0d0e0f")

    T.it("round-trips a single block", function()
      local pt = "Hello, AES-CBC!!"  -- 16 bytes exactly
      local ct, used_iv = aes.cbc_encrypt(key, pt, iv)
      T.ok(ct ~= nil)
      T.eq(used_iv, iv)
      local recovered = aes.cbc_decrypt(key, ct, iv)
      T.eq(recovered, pt)
    end)

    T.it("round-trips data with padding", function()
      local pt = "Hello, AES-CBC!"  -- 15 bytes — needs 1 byte of padding
      local ct, used_iv = aes.cbc_encrypt(key, pt, iv)
      T.ok(ct ~= nil)
      local recovered = aes.cbc_decrypt(key, ct, used_iv)
      T.eq(recovered, pt)
    end)

    T.it("round-trips multi-block input", function()
      local pt = ("abcdefghijklmnop"):rep(4)  -- 64 bytes
      local ct, used_iv = aes.cbc_encrypt(key, pt, iv)
      -- With PKCS#7 padding the ciphertext should be 80 bytes (64 + 16 full-pad block)
      local recovered = aes.cbc_decrypt(key, ct, used_iv)
      T.eq(recovered, pt)
    end)

    T.it("uses zero IV when not provided", function()
      local pt = "test data block!"
      local ct1, iv1 = aes.cbc_encrypt(key, pt)
      local ct2, iv2 = aes.cbc_encrypt(key, pt, ("\0"):rep(16))
      T.eq(ct1, ct2)
    end)

    -- NIST SP 800-38A F.2.1 CBC-AES128.Encrypt test vector
    T.it("matches NIST SP 800-38A F.2.1 vector (block 1)", function()
      local nist_key = hex_to_str("2b7e151628aed2a6abf7158809cf4f3c")
      local nist_iv  = hex_to_str("000102030405060708090a0b0c0d0e0f")
      local nist_pt  = hex_to_str("6bc1bee22e409f96e93d7e117393172a")
      -- Expected first ciphertext block
      local expected_ct1 = "7649abac8119b246cee98e9b12e9197d"
      -- CBC with no padding on one block — encrypt raw then check
      -- (CBC adds padding, so encrypt two zero bytes short to get the exact block)
      -- We compare the first 16 bytes of ct for one padded block input
      local ct, _ = aes.cbc_encrypt(nist_key, nist_pt, nist_iv)
      -- First 16 bytes should match NIST vector
      T.eq(str_to_hex(ct:sub(1, 16)), expected_ct1)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- CTR mode
  -- -------------------------------------------------------------------------
  T.describe("ctr_encrypt / ctr_decrypt", function()
    local key   = hex_to_str("2b7e151628aed2a6abf7158809cf4f3c")
    local nonce = hex_to_str("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")

    T.it("encrypt and decrypt are symmetric", function()
      local pt = "Hello, CTR mode!"
      local ct = aes.ctr_encrypt(key, pt, nonce)
      local recovered = aes.ctr_decrypt(key, ct, nonce)
      T.eq(recovered, pt)
    end)

    T.it("round-trips non-block-aligned input", function()
      local pt = "Short"
      local ct = aes.ctr_encrypt(key, pt, nonce)
      T.eq(#ct, 5)
      T.eq(aes.ctr_decrypt(key, ct, nonce), pt)
    end)

    T.it("round-trips multi-block input", function()
      local pt = ("The quick brown fox jumps over the lazy dog."):rep(3)
      local ct = aes.ctr_encrypt(key, pt, nonce)
      T.eq(#ct, #pt)
      T.eq(aes.ctr_decrypt(key, ct, nonce), pt)
    end)

    -- NIST SP 800-38A F.5.1 CTR-AES128 test vector
    T.it("matches NIST SP 800-38A F.5.1 CTR vector (block 1)", function()
      local nist_key   = hex_to_str("2b7e151628aed2a6abf7158809cf4f3c")
      local nist_nonce = hex_to_str("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
      local nist_pt    = hex_to_str("6bc1bee22e409f96e93d7e117393172a")
      local expected   = "874d6191b620e3261bef6864990db6ce"
      local ct = aes.ctr_encrypt(nist_key, nist_pt, nist_nonce)
      T.eq(str_to_hex(ct:sub(1, 16)), expected)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- PKCS#7 padding
  -- -------------------------------------------------------------------------
  T.describe("pad / unpad", function()
    T.it("pads 0-byte input to 16 bytes", function()
      local padded = aes.pad("", 16)
      T.eq(#padded, 16)
      T.eq(string.byte(padded, 1), 16)
    end)

    T.it("pads 15-byte input with 1 byte", function()
      local padded = aes.pad(("a"):rep(15), 16)
      T.eq(#padded, 16)
      T.eq(string.byte(padded, 16), 1)
    end)

    T.it("pads 16-byte input with full block", function()
      local padded = aes.pad(("a"):rep(16), 16)
      T.eq(#padded, 32)
      T.eq(string.byte(padded, 32), 16)
    end)

    T.it("unpad inverts pad", function()
      for len = 0, 31 do
        local data = ("x"):rep(len)
        local padded = aes.pad(data, 16)
        local unpadded = aes.unpad(padded)
        T.eq(unpadded, data)
      end
    end)

    T.it("unpad rejects invalid padding byte", function()
      -- Byte value 0 is invalid PKCS#7
      local bad = ("a"):rep(15) .. "\0"
      local result, err = aes.unpad(bad)
      T.eq(result, nil)
      T.ok(err ~= nil)
    end)

    T.it("unpad rejects inconsistent padding", function()
      -- Last byte says 3 but earlier bytes don't match
      local bad = ("a"):rep(13) .. "\x02\x03"
      local result, err = aes.unpad(bad)
      T.eq(result, nil)
      T.ok(err ~= nil)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- Error handling
  -- -------------------------------------------------------------------------
  T.describe("error handling", function()
    T.it("encrypt_block rejects wrong key length", function()
      local r, e = aes.encrypt_block("shortkey", ("\0"):rep(16))
      T.eq(r, nil)
      T.ok(e ~= nil)
    end)

    T.it("encrypt_block rejects wrong block length", function()
      local r, e = aes.encrypt_block(("\0"):rep(16), "short")
      T.eq(r, nil)
      T.ok(e ~= nil)
    end)

    T.it("ecb_encrypt rejects non-aligned input", function()
      local r, e = aes.ecb_encrypt(("\0"):rep(16), "17bytes-padneeded")
      T.eq(r, nil)
      T.ok(e ~= nil)
    end)

    T.it("cbc_decrypt rejects bad padding", function()
      local key = ("\0"):rep(16)
      local iv  = ("\0"):rep(16)
      -- Corrupt the last byte to break PKCS#7
      local ct, _ = aes.cbc_encrypt(key, "Hello, world!!", iv)
      -- Flip last byte to create bad padding
      local bad_ct = ct:sub(1, -2) .. string.char(bit.bxor(string.byte(ct, -1), 1))
      local r, e = aes.cbc_decrypt(key, bad_ct, iv)
      T.eq(r, nil)
      T.ok(e ~= nil)
    end)
  end)

end)
