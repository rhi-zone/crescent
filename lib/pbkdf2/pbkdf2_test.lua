-- lib/pbkdf2/pbkdf2_test.lua
-- Tests for PBKDF2 key derivation (RFC 8018 / PKCS#5 v2.1).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local pbkdf2 = require("lib.pbkdf2")

T.describe("lib.pbkdf2", function()

  T.describe("tier", function()
    T.it("M._tier is 'pure'", function()
      T.eq(pbkdf2._tier, "pure")
    end)
  end)

  T.describe("derive (SHA-1)", function()
    -- RFC 6070 §2 test vectors (official, definitively correct).

    T.it("vector 1: password/salt/1/20", function()
      local dk, err = pbkdf2.derive_hex("password", "salt", 1, 20, { alg = "sha1" })
      T.eq(err, nil)
      T.eq(dk, "0c60c80f961f0e71f3a9b524af6012062fe037a6")
    end)

    T.it("vector 2: password/salt/2/20", function()
      local dk, err = pbkdf2.derive_hex("password", "salt", 2, 20, { alg = "sha1" })
      T.eq(err, nil)
      T.eq(dk, "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957")
    end)

    T.it("vector 3: password/salt/4096/20", function()
      local dk, err = pbkdf2.derive_hex("password", "salt", 4096, 20, { alg = "sha1" })
      T.eq(err, nil)
      T.eq(dk, "4b007901b765489abead49d926f721d065a429c1")
    end)

    T.it("vector 5: multi-block DK (dklen=25)", function()
      -- password: "passwordPASSWORDpassword"
      -- salt:     "saltSALTsaltSALTsaltSALTsaltSALTsalt"
      -- iterations: 4096, dklen: 25
      local dk, err = pbkdf2.derive_hex(
        "passwordPASSWORDpassword",
        "saltSALTsaltSALTsaltSALTsaltSALTsalt",
        4096,
        25,
        { alg = "sha1" }
      )
      T.eq(err, nil)
      T.eq(dk, "3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038")
    end)
  end)

  T.describe("derive (SHA-256)", function()
    -- Vector verified against Python: hashlib.pbkdf2_hmac('sha256', b'password', b'salt', 1, 32).hex()
    -- Result: 120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b

    T.it("vector 1: password/salt/1/32", function()
      local dk, err = pbkdf2.derive_hex("password", "salt", 1, 32, { alg = "sha256" })
      T.eq(err, nil)
      T.eq(dk, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    end)

    T.it("default alg is sha256", function()
      local dk_explicit = pbkdf2.derive_hex("password", "salt", 1, 32, { alg = "sha256" })
      local dk_default  = pbkdf2.derive_hex("password", "salt", 1, 32)
      T.eq(dk_default, dk_explicit)
    end)

    T.it("dklen truncation: request 16 bytes from sha256", function()
      local dk, err = pbkdf2.derive_hex("password", "salt", 1, 16, { alg = "sha256" })
      T.eq(err, nil)
      -- Should be the first 16 bytes (32 hex chars) of the full 32-byte output.
      T.eq(dk, "120fb6cffcf8b32c43e7225256c4f837")
    end)
  end)

  T.describe("derive_hex", function()
    T.it("returns the same value as derive but hex-encoded", function()
      local bin, _ = pbkdf2.derive("password", "salt", 1, 20, { alg = "sha1" })
      local hex, _ = pbkdf2.derive_hex("password", "salt", 1, 20, { alg = "sha1" })
      T.eq(type(bin), "string")
      T.eq(#bin, 20)
      T.eq(type(hex), "string")
      T.eq(#hex, 40)
      -- Re-encode bin and compare.
      local parts = {}
      for i = 1, #bin do
        parts[i] = string.format("%02x", string.byte(bin, i))
      end
      T.eq(table.concat(parts), hex)
    end)
  end)

  T.describe("verify", function()
    T.it("correct password returns true", function()
      local dk = pbkdf2.derive("password", "salt", 1, 20, { alg = "sha1" })
      local ok, err = pbkdf2.verify("password", "salt", 1, dk, { alg = "sha1" })
      T.eq(err, nil)
      T.ok(ok)
    end)

    T.it("wrong password returns false", function()
      local dk = pbkdf2.derive("password", "salt", 1, 20, { alg = "sha1" })
      local ok, err = pbkdf2.verify("wrongpassword", "salt", 1, dk, { alg = "sha1" })
      T.eq(err, nil)
      T.ok(not ok)
    end)

    T.it("wrong salt returns false", function()
      local dk = pbkdf2.derive("password", "salt", 1, 20, { alg = "sha1" })
      local ok = pbkdf2.verify("password", "wrongsalt", 1, dk, { alg = "sha1" })
      T.ok(not ok)
    end)

    T.it("hex mode: verify against hex-encoded stored key", function()
      local hex = pbkdf2.derive_hex("password", "salt", 1, 20, { alg = "sha1" })
      local ok, err = pbkdf2.verify("password", "salt", 1, hex, { alg = "sha1", hex = true })
      T.eq(err, nil)
      T.ok(ok)
    end)

    T.it("hex mode: wrong password returns false", function()
      local hex = pbkdf2.derive_hex("password", "salt", 1, 20, { alg = "sha1" })
      local ok = pbkdf2.verify("bad", "salt", 1, hex, { alg = "sha1", hex = true })
      T.ok(not ok)
    end)
  end)

  T.describe("error handling", function()
    T.it("dklen = 0 returns error", function()
      local dk, err = pbkdf2.derive("password", "salt", 1, 0)
      T.eq(dk, nil)
      T.ok(type(err) == "string")
    end)

    T.it("iterations = 0 returns error", function()
      local dk, err = pbkdf2.derive("password", "salt", 0, 20)
      T.eq(dk, nil)
      T.ok(type(err) == "string")
    end)

    T.it("unknown alg returns error", function()
      local dk, err = pbkdf2.derive("password", "salt", 1, 20, { alg = "md5" })
      T.eq(dk, nil)
      T.ok(type(err) == "string")
    end)

    T.it("non-integer iterations returns error", function()
      local dk, err = pbkdf2.derive("password", "salt", 1.5, 20)
      T.eq(dk, nil)
      T.ok(type(err) == "string")
    end)

    T.it("derive_hex propagates errors", function()
      local hex, err = pbkdf2.derive_hex("password", "salt", 0, 20)
      T.eq(hex, nil)
      T.ok(type(err) == "string")
    end)
  end)

end)
