-- lib/scrypt/scrypt_test.lua
-- Tests for lib.scrypt — RFC 7914 test vectors + API contract.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local scrypt = require("lib.scrypt")

T.describe("lib.scrypt", function()

  T.describe("tier", function()
    T.it("reports pure", function()
      T.eq(scrypt._tier, "pure")
    end)
  end)

  T.describe("derive", function()

    T.it("RFC 7914 §12 vector 1 (N=16, fast)", function()
      -- password="", salt="", N=16, r=1, p=1, dklen=64
      local expected =
        "77d6576238657b203b19ca42c18a0497" ..
        "f16b4844e3074ae8dfdffa3fede21442" ..
        "fcd0069ded0948f8326a753a0fc81f17" ..
        "e8d3e0fb2e0d3628cf35e20c38d18906"
      local dk, err = scrypt.derive("", "", 16, 1, 1, 64)
      T.ok(dk ~= nil, err)
      local got = ""
      for i = 1, #dk do
        got = got .. string.format("%02x", string.byte(dk, i))
      end
      T.eq(got, expected)
    end)

    T.it("RFC 7914 §12 vector 2 (N=1024, r=8, p=16)", function()
      -- password="password", salt="NaCl", N=1024, r=8, p=16, dklen=64
      local expected =
        "fdbabe1c9d3472007856e7190d01e9fe" ..
        "7c6ad7cbc8237830e77376634b3731622" ..
        "eaf30d92e22a3886ff109279d9830dac" ..
        "727afb94a83ee6d8360cbdfa2cc0640"
      -- NOTE: The expected value in the RFC is 64 bytes = 128 hex chars.
      -- The prompt's hex has a digit count issue; we use the RFC value directly.
      local dk, err = scrypt.derive("password", "NaCl", 1024, 8, 16, 64)
      T.ok(dk ~= nil, err)
      T.eq(#dk, 64)
      -- We verify the first 4 bytes match the RFC to catch gross errors,
      -- and full hex is checked against the canonical RFC value.
      local got = ""
      for i = 1, #dk do
        got = got .. string.format("%02x", string.byte(dk, i))
      end
      -- RFC 7914 §12 canonical value (64 bytes / 128 hex chars):
      local rfc_expected =
        "fdbabe1c9d3472007856e7190d01e9fe" ..
        "7c6ad7cbc8237830e77376634b373162" ..
        "2eaf30d92e22a3886ff109279d9830da" ..
        "c727afb94a83ee6d8360cbdfa2cc0640"
      T.eq(got, rfc_expected)
    end)

    T.it("dklen parameter controls output length", function()
      local dk16, err = scrypt.derive("pw", "sa", 16, 1, 1, 16)
      T.ok(dk16 ~= nil, err)
      T.eq(#dk16, 16)

      local dk32, _ = scrypt.derive("pw", "sa", 16, 1, 1, 32)
      T.eq(#dk32, 32)

      -- First 16 bytes of dk32 should match dk16 (both are PBKDF2 prefix).
      T.eq(dk32:sub(1, 16), dk16)
    end)

    T.it("default dklen is 32", function()
      local dk, err = scrypt.derive("pw", "sa", 16, 1, 1)
      T.ok(dk ~= nil, err)
      T.eq(#dk, 32)
    end)

    T.it("N must be a power of 2", function()
      local dk, err = scrypt.derive("pw", "sa", 3, 1, 1, 32)
      T.eq(dk, nil)
      T.ok(err:find("power of 2"))
    end)

    T.it("N < 2 returns error", function()
      local dk, err = scrypt.derive("pw", "sa", 1, 1, 1, 32)
      T.eq(dk, nil)
      T.ok(err ~= nil)
    end)

    T.it("r < 1 returns error", function()
      local dk, err = scrypt.derive("pw", "sa", 16, 0, 1, 32)
      T.eq(dk, nil)
      T.ok(err ~= nil)
    end)

    T.it("p < 1 returns error", function()
      local dk, err = scrypt.derive("pw", "sa", 16, 1, 0, 32)
      T.eq(dk, nil)
      T.ok(err ~= nil)
    end)

    T.it("non-string password returns error", function()
      local dk, err = scrypt.derive(123, "sa", 16, 1, 1, 32)
      T.eq(dk, nil)
      T.ok(err ~= nil)
    end)

    T.it("non-string salt returns error", function()
      local dk, err = scrypt.derive("pw", 456, 16, 1, 1, 32)
      T.eq(dk, nil)
      T.ok(err ~= nil)
    end)

  end)

  T.describe("derive_hex", function()

    T.it("returns lowercase hex of same length", function()
      local hex, err = scrypt.derive_hex("pw", "sa", 16, 1, 1, 16)
      T.ok(hex ~= nil, err)
      T.eq(#hex, 32)  -- 16 bytes = 32 hex chars
      T.ok(hex:match("^[0-9a-f]+$") ~= nil)
    end)

    T.it("matches derive output", function()
      local dk,  _   = scrypt.derive("pw", "sa", 16, 1, 1, 20)
      local hex, err = scrypt.derive_hex("pw", "sa", 16, 1, 1, 20)
      T.ok(hex ~= nil, err)
      local expected = ""
      for i = 1, #dk do
        expected = expected .. string.format("%02x", string.byte(dk, i))
      end
      T.eq(hex, expected)
    end)

    T.it("propagates errors", function()
      local hex, err = scrypt.derive_hex("pw", "sa", 3, 1, 1, 16)
      T.eq(hex, nil)
      T.ok(err ~= nil)
    end)

  end)

  T.describe("verify", function()

    T.it("correct password returns true", function()
      local dk, _ = scrypt.derive("secret", "salt!", 16, 1, 1, 32)
      local ok, err = scrypt.verify("secret", "salt!", 16, 1, 1, dk)
      T.ok(err == nil, err)
      T.ok(ok == true)
    end)

    T.it("wrong password returns false", function()
      local dk, _ = scrypt.derive("secret", "salt!", 16, 1, 1, 32)
      local ok, err = scrypt.verify("WRONG", "salt!", 16, 1, 1, dk)
      T.ok(err == nil)
      T.ok(ok == false)
    end)

    T.it("wrong salt returns false", function()
      local dk, _ = scrypt.derive("secret", "salt!", 16, 1, 1, 32)
      local ok, err = scrypt.verify("secret", "WRONG", 16, 1, 1, dk)
      T.ok(err == nil)
      T.ok(ok == false)
    end)

    T.it("accepts hex-encoded derived key via opts.hex", function()
      local hex, _ = scrypt.derive_hex("secret", "salt!", 16, 1, 1, 32)
      local ok, err = scrypt.verify("secret", "salt!", 16, 1, 1, hex, { hex = true })
      T.ok(err == nil, err)
      T.ok(ok == true)
    end)

    T.it("wrong password with hex key returns false", function()
      local hex, _ = scrypt.derive_hex("secret", "salt!", 16, 1, 1, 32)
      local ok, err = scrypt.verify("WRONG", "salt!", 16, 1, 1, hex, { hex = true })
      T.ok(err == nil)
      T.ok(ok == false)
    end)

  end)

end)
