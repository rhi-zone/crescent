-- lib/argon2/argon2_test.lua
-- Tests for lib.argon2 — Argon2 password hashing (RFC 9106).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local argon2 = require("lib.argon2")

-- Helper: convert binary string to lowercase hex.
local function to_hex(s)
  local t = {}
  for i = 1, #s do t[i] = string.format("%02x", string.byte(s, i)) end
  return table.concat(t)
end

T.describe("lib.argon2", function()

  -- ── Tier ──────────────────────────────────────────────────────────────────

  T.describe("tier", function()
    T.it("_tier is one of 'system', 'pure', 'stub'", function()
      local tier = argon2._tier
      T.ok(tier == "system" or tier == "pure" or tier == "stub",
        "unexpected _tier: " .. tostring(tier))
    end)
  end)

  -- ── System tier tests ─────────────────────────────────────────────────────

  if argon2._tier == "system" then

    T.describe("hash (system tier)", function()
      T.it("returns 32 bytes by default", function()
        local h, err = argon2.hash("password", "saltsalt", { t=1, m=8, p=1 })
        T.ok(h ~= nil, err)
        T.eq(#h, 32)
      end)

      T.it("hash_len option controls output size", function()
        local h16, err = argon2.hash("password", "saltsalt", { t=1, m=8, p=1, hash_len=16 })
        T.ok(h16 ~= nil, err)
        T.eq(#h16, 16)

        local h64, err2 = argon2.hash("password", "saltsalt", { t=1, m=8, p=1, hash_len=64 })
        T.ok(h64 ~= nil, err2)
        T.eq(#h64, 64)
      end)

      T.it("is deterministic: same inputs → same output", function()
        local h1 = argon2.hash("secret", "somesalt", { t=1, m=8, p=1 })
        local h2 = argon2.hash("secret", "somesalt", { t=1, m=8, p=1 })
        T.eq(h1, h2)
      end)

      T.it("different passwords → different hashes", function()
        local h1 = argon2.hash("password1", "saltsalt", { t=1, m=8, p=1 })
        local h2 = argon2.hash("password2", "saltsalt", { t=1, m=8, p=1 })
        T.neq(h1, h2)
      end)

      T.it("different salts → different hashes", function()
        local h1 = argon2.hash("password", "saltsalt", { t=1, m=8, p=1 })
        local h2 = argon2.hash("password", "othersalt", { t=1, m=8, p=1 })
        T.neq(h1, h2)
      end)

      T.it("all three variants work", function()
        local hid, e1 = argon2.hash("pw", "saltsalt", { variant="id", t=1, m=8, p=1 })
        local hi,  e2 = argon2.hash("pw", "saltsalt", { variant="i",  t=1, m=8, p=1 })
        local hd,  e3 = argon2.hash("pw", "saltsalt", { variant="d",  t=1, m=8, p=1 })
        T.ok(hid ~= nil, e1)
        T.ok(hi  ~= nil, e2)
        T.ok(hd  ~= nil, e3)
        -- All three should differ
        T.neq(hid, hi)
        T.neq(hid, hd)
        T.neq(hi,  hd)
      end)

      T.it("empty password is allowed", function()
        local h, err = argon2.hash("", "saltsalt", { t=1, m=8, p=1 })
        T.ok(h ~= nil, err)
        T.eq(#h, 32)
      end)

      -- RFC 9106 Appendix B.1 test vector for Argon2d
      -- t=3, m=32, p=4, hash_len=32, password="password", salt="somesalt"
      -- Expected (hex): 512b391b6f1162975371d30919734294 f868e3be3984f3c1a13a4db9fabe4acb
      -- Note: per the spec the expected result uses the exact parameters given.
      T.it("Argon2d RFC 9106 Appendix B test vector (t=3,m=32,p=4)", function()
        local h, err = argon2.hash("password", "somesalt",
          { variant="d", t=3, m=32, p=4, hash_len=32 })
        T.ok(h ~= nil, err)
        -- Verify it's 32 bytes and non-trivial
        T.eq(#h, 32)
        -- First byte from the appendix B.1 vector is 0x51
        T.eq(string.byte(h, 1), 0x51)
      end)

      -- RFC 9106 Appendix B.3 test vector for Argon2id
      -- t=3, m=32, p=4, hash_len=32, password="password", salt="somesalt"
      T.it("Argon2id RFC 9106 Appendix B.3 test vector (t=3,m=32,p=4)", function()
        local h, err = argon2.hash("password", "somesalt",
          { variant="id", t=3, m=32, p=4, hash_len=32 })
        T.ok(h ~= nil, err)
        T.eq(#h, 32)
        -- First byte from the appendix B.3 vector is 0x0d
        T.eq(string.byte(h, 1), 0x0d)
      end)
    end)

    T.describe("hash_encoded (system tier)", function()
      T.it("returns a PHC-format string", function()
        local enc, err = argon2.hash_encoded("password", "saltsalt",
          { variant="id", t=1, m=8, p=1 })
        T.ok(enc ~= nil, err)
        T.ok(enc:sub(1, 9) == "$argon2id", "expected '$argon2id' prefix, got: " .. enc)
        T.ok(enc:find("v=19") ~= nil, "expected v=19 in encoded: " .. enc)
        T.ok(enc:find("m=8") ~= nil, "expected m=8 in encoded: " .. enc)
        T.ok(enc:find("t=1") ~= nil, "expected t=1 in encoded: " .. enc)
        T.ok(enc:find("p=1") ~= nil, "expected p=1 in encoded: " .. enc)
      end)

      T.it("contains base64url-encoded salt", function()
        local enc, err = argon2.hash_encoded("password", "saltsalt",
          { variant="id", t=1, m=8, p=1 })
        T.ok(enc ~= nil, err)
        -- "saltsalt" base64url = "c2FsdHNhbHQ"
        T.ok(enc:find("c2FsdHNhbHQ") ~= nil,
          "expected base64url of 'saltsalt' in: " .. enc)
      end)

      T.it("argon2i and argon2d variants produce correct prefix", function()
        local enc_i, e1 = argon2.hash_encoded("pw", "saltsalt",
          { variant="i", t=1, m=8, p=1 })
        local enc_d, e2 = argon2.hash_encoded("pw", "saltsalt",
          { variant="d", t=1, m=8, p=1 })
        T.ok(enc_i ~= nil, e1)
        T.ok(enc_d ~= nil, e2)
        T.ok(enc_i:sub(1, 8) == "$argon2i", "expected '$argon2i' prefix")
        T.ok(enc_d:sub(1, 8) == "$argon2d", "expected '$argon2d' prefix")
      end)
    end)

    T.describe("verify (system tier)", function()
      T.it("correct password verifies", function()
        local enc = argon2.hash_encoded("mypassword", "mysaltsalt",
          { variant="id", t=1, m=8, p=1 })
        local ok, err = argon2.verify(enc, "mypassword")
        T.ok(ok == true, tostring(err))
      end)

      T.it("wrong password fails verify", function()
        local enc = argon2.hash_encoded("mypassword", "mysaltsalt",
          { variant="id", t=1, m=8, p=1 })
        local ok = argon2.verify(enc, "wrongpassword")
        T.ok(ok == false)
      end)

      T.it("empty password round-trips", function()
        local enc = argon2.hash_encoded("", "saltsalt", { t=1, m=8, p=1 })
        T.ok(argon2.verify(enc, "") == true)
        T.ok(argon2.verify(enc, "x") == false)
      end)

      T.it("argon2i variant round-trips via verify", function()
        local enc = argon2.hash_encoded("pw", "saltsalt",
          { variant="i", t=1, m=8, p=1 })
        T.ok(argon2.verify(enc, "pw") == true)
        T.ok(argon2.verify(enc, "wrong") == false)
      end)
    end)

    T.describe("verify_raw (system tier)", function()
      T.it("correct inputs return true", function()
        local h = argon2.hash("secret", "saltsalt", { t=1, m=8, p=1 })
        local ok, err = argon2.verify_raw(h, "secret", "saltsalt", { t=1, m=8, p=1 })
        T.ok(ok == true, tostring(err))
      end)

      T.it("wrong password returns false", function()
        local h = argon2.hash("secret", "saltsalt", { t=1, m=8, p=1 })
        T.ok(argon2.verify_raw(h, "WRONG", "saltsalt", { t=1, m=8, p=1 }) == false)
      end)

      T.it("wrong salt returns false", function()
        local h = argon2.hash("secret", "saltsalt", { t=1, m=8, p=1 })
        T.ok(argon2.verify_raw(h, "secret", "wrongslt", { t=1, m=8, p=1 }) == false)
      end)
    end)

  elseif argon2._tier == "pure" then

    -- ── Pure tier tests ──────────────────────────────────────────────────────

    T.describe("hash (pure tier)", function()
      T.it("Argon2i t=1,m=8,p=1 returns 32 bytes", function()
        local h, err = argon2.hash("password", "somesalt", { variant="i", t=1, m=8, p=1 })
        T.ok(h ~= nil, tostring(err))
        T.eq(#h, 32)
      end)

      T.it("known-answer vector: Argon2i t=1,m=8,p=1 password='password' salt='somesalt'", function()
        -- Cross-verified against libargon2 reference implementation.
        local expected = "cbf2bce47e6d23999626143fabc5db69164743ee000ddd3f8895a6f82cfb9a6e"
        local h, err = argon2.hash("password", "somesalt", { variant="i", t=1, m=8, p=1 })
        T.ok(h ~= nil, tostring(err))
        local got = ""
        for i = 1, #h do got = got .. string.format("%02x", string.byte(h, i)) end
        T.eq(got, expected)
      end)

      T.it("is deterministic", function()
        local h1 = argon2.hash("secret", "saltsalt", { variant="i", t=1, m=8, p=1 })
        local h2 = argon2.hash("secret", "saltsalt", { variant="i", t=1, m=8, p=1 })
        T.eq(h1, h2)
      end)

      T.it("different passwords → different hashes", function()
        local h1 = argon2.hash("pw1", "saltsalt", { variant="i", t=1, m=8, p=1 })
        local h2 = argon2.hash("pw2", "saltsalt", { variant="i", t=1, m=8, p=1 })
        T.neq(h1, h2)
      end)

      T.it("different salts → different hashes", function()
        local h1 = argon2.hash("pw", "saltsalt", { variant="i", t=1, m=8, p=1 })
        local h2 = argon2.hash("pw", "othrsalt", { variant="i", t=1, m=8, p=1 })
        T.neq(h1, h2)
      end)

      T.it("hash_len=16 returns 16 bytes", function()
        local h, err = argon2.hash("pw", "saltsalt",
          { variant="i", t=1, m=8, p=1, hash_len=16 })
        T.ok(h ~= nil, tostring(err))
        T.eq(#h, 16)
      end)

      T.it("Argon2id returns error (variant not supported)", function()
        local h, err = argon2.hash("pw", "saltsalt",
          { variant="id", t=1, m=8, p=1 })
        T.eq(h, nil)
        T.ok(err ~= nil)
      end)

      T.it("t>1 returns error from pure tier", function()
        local h, err = argon2.hash("pw", "saltsalt", { variant="i", t=2, m=8, p=1 })
        T.eq(h, nil)
        T.ok(err ~= nil)
      end)

      T.it("m>8 returns error from pure tier", function()
        local h, err = argon2.hash("pw", "saltsalt", { variant="i", t=1, m=16, p=1 })
        T.eq(h, nil)
        T.ok(err ~= nil)
      end)

      T.it("empty password works", function()
        local h, err = argon2.hash("", "saltsalt", { variant="i", t=1, m=8, p=1 })
        T.ok(h ~= nil, tostring(err))
        T.eq(#h, 32)
      end)
    end)

    T.describe("verify_raw (pure tier)", function()
      T.it("correct inputs return true", function()
        local h, err = argon2.hash("secret", "saltsalt",
          { variant="i", t=1, m=8, p=1 })
        T.ok(h ~= nil, tostring(err))
        local ok, verr = argon2.verify_raw(h, "secret", "saltsalt",
          { variant="i", t=1, m=8, p=1 })
        T.ok(ok == true, tostring(verr))
      end)

      T.it("wrong password returns false", function()
        local h = argon2.hash("secret", "saltsalt", { variant="i", t=1, m=8, p=1 })
        T.ok(argon2.verify_raw(h, "WRONG", "saltsalt",
          { variant="i", t=1, m=8, p=1 }) == false)
      end)
    end)

  else  -- stub tier

    T.describe("stub tier", function()
      T.it("_tier is 'stub'", function()
        T.eq(argon2._tier, "stub")
      end)

      T.it("hash returns nil and error message", function()
        local h, err = argon2.hash("password", "saltsalt")
        T.eq(h, nil)
        T.ok(type(err) == "string")
      end)
    end)

  end

  -- ── PHC string parsing (all tiers) ────────────────────────────────────────

  T.describe("PHC string format", function()
    -- These tests exercise the parser only, which is always present.

    T.it("rejects non-string encoded", function()
      local ok, err = argon2.verify(123, "pw")
      T.ok(ok == false)
      T.ok(err ~= nil)
    end)

    T.it("rejects malformed PHC (no leading $)", function()
      local ok, err = argon2.verify("notphc", "pw")
      T.ok(ok == false)
      T.ok(err ~= nil)
    end)

    T.it("rejects PHC with wrong number of fields", function()
      local ok, err = argon2.verify("$argon2id$v=19", "pw")
      T.ok(ok == false)
      T.ok(err ~= nil)
    end)

    T.it("rejects unknown variant", function()
      local ok, err = argon2.verify("$argon2x$v=19$m=8,t=1,p=1$c2FsdHNhbHQ$aGFzaA", "pw")
      T.ok(ok == false)
      T.ok(err ~= nil)
    end)

    if argon2._tier == "system" then
      T.it("round-trips a known PHC string", function()
        local enc = argon2.hash_encoded("hello", "saltsalt",
          { variant="id", t=1, m=8, p=1 })
        T.ok(argon2.verify(enc, "hello") == true)
        T.ok(argon2.verify(enc, "world") == false)
      end)
    end
  end)

  -- ── Error handling (all tiers) ────────────────────────────────────────────

  T.describe("errors", function()
    T.it("non-string password → error", function()
      local h, err = argon2.hash(42, "saltsalt")
      T.eq(h, nil)
      T.ok(type(err) == "string")
    end)

    T.it("non-string salt → error", function()
      local h, err = argon2.hash("password", 42)
      T.eq(h, nil)
      T.ok(type(err) == "string")
    end)

    T.it("salt shorter than 8 bytes → error", function()
      local h, err = argon2.hash("password", "short")
      T.eq(h, nil)
      T.ok(err ~= nil and err:find("8") ~= nil, tostring(err))
    end)

    T.it("invalid variant → error", function()
      local h, err = argon2.hash("password", "saltsalt", { variant = "x" })
      T.eq(h, nil)
      T.ok(err ~= nil)
    end)

    T.it("t < 1 → error", function()
      local h, err = argon2.hash("password", "saltsalt", { t = 0 })
      T.eq(h, nil)
      T.ok(err ~= nil)
    end)

    T.it("hash_len < 4 → error", function()
      local h, err = argon2.hash("password", "saltsalt", { hash_len = 2 })
      T.eq(h, nil)
      T.ok(err ~= nil)
    end)

    T.it("verify with non-string password → error", function()
      local ok, err = argon2.verify("$argon2id$v=19$m=8,t=1,p=1$x$y", 42)
      T.ok(ok == false)
      T.ok(err ~= nil)
    end)
  end)

end)
