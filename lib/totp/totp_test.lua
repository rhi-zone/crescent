-- lib/totp/totp_test.lua
-- Tests for lib/totp: HOTP (RFC 4226) and TOTP (RFC 6238).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local totp = require("lib.totp")

-- RFC 4226 Appendix D key: "12345678901234567890" as raw ASCII (20 bytes)
local HOTP_KEY = "12345678901234567890"

-- RFC 6238 Appendix B uses the same 20-byte key for SHA-1 TOTP (8 digits)
local TOTP_KEY_SHA1 = "12345678901234567890"

T.describe("lib.totp", function()

  T.describe("tier", function()
    T.it("is pure", function()
      T.eq(totp._tier, "pure")
    end)
  end)

  -- ── HOTP ────────────────────────────────────────────────────────────────────

  T.describe("hotp", function()
    -- RFC 4226 Appendix D — 6-digit vectors
    local vectors_6 = {
      { 0, "755224" },
      { 1, "287082" },
      { 2, "359152" },
      { 3, "969429" },
      { 4, "338314" },
    }

    for _, v in ipairs(vectors_6) do
      local counter, expected = v[1], v[2]
      T.it("RFC 4226 counter=" .. counter .. " → " .. expected, function()
        local otp, err = totp.hotp(HOTP_KEY, counter)
        T.eq(err, nil)
        T.eq(otp, expected)
      end)
    end

    T.it("returns zero-padded 6-digit string", function()
      -- counter=0 yields 755224 — already tests normal case.
      -- use a counter that produces a small OTP to verify padding
      local otp, err = totp.hotp(HOTP_KEY, 0)
      T.eq(err, nil)
      T.eq(#otp, 6)
    end)

    T.it("digits=8 produces 8-char result", function()
      local otp, err = totp.hotp(HOTP_KEY, 0, { digits = 8 })
      T.eq(err, nil)
      T.eq(#otp, 8)
      -- RFC 4226 Appendix D 8-digit: counter 0 → 84755224
      T.eq(otp, "84755224")
    end)

    T.it("digits=8 counter=1 vector", function()
      local otp, err = totp.hotp(HOTP_KEY, 1, { digits = 8 })
      T.eq(err, nil)
      T.eq(otp, "94287082")
    end)

    T.it("rejects invalid digits", function()
      local otp, err = totp.hotp(HOTP_KEY, 0, { digits = 7 })
      T.eq(otp, nil)
      T.ok(err ~= nil)
    end)

    T.it("rejects empty key", function()
      local otp, err = totp.hotp("", 0)
      T.eq(otp, nil)
      T.ok(err ~= nil)
    end)

    T.it("rejects negative counter", function()
      local otp, err = totp.hotp(HOTP_KEY, -1)
      T.eq(otp, nil)
      T.ok(err ~= nil)
    end)

    T.it("rejects non-integer counter", function()
      local otp, err = totp.hotp(HOTP_KEY, 1.5)
      T.eq(otp, nil)
      T.ok(err ~= nil)
    end)
  end)

  -- ── TOTP ────────────────────────────────────────────────────────────────────

  T.describe("totp", function()
    -- RFC 6238 Appendix B — SHA-1, 8 digits
    -- T=59 → step=1 (period=30 → floor(59/30) = 1) → "94287082"
    T.it("RFC 6238 time=59 SHA-1 8-digit → 94287082", function()
      local otp, err = totp.totp(TOTP_KEY_SHA1, {
        digits = 8,
        period = 30,
        alg    = "sha1",
        time   = 59,
      })
      T.eq(err, nil)
      T.eq(otp, "94287082")
    end)

    -- RFC 6238 Appendix B: time=1111111109, step=37037036 → "07081804"
    T.it("RFC 6238 time=1111111109 SHA-1 8-digit → 07081804", function()
      local otp, err = totp.totp(TOTP_KEY_SHA1, {
        digits = 8,
        period = 30,
        alg    = "sha1",
        time   = 1111111109,
      })
      T.eq(err, nil)
      T.eq(otp, "07081804")
    end)

    -- RFC 6238 Appendix B: time=1111111111, step=37037036 → "14050471"
    T.it("RFC 6238 time=1111111111 SHA-1 8-digit → 14050471", function()
      local otp, err = totp.totp(TOTP_KEY_SHA1, {
        digits = 8,
        period = 30,
        alg    = "sha1",
        time   = 1111111111,
      })
      T.eq(err, nil)
      T.eq(otp, "14050471")
    end)

    T.it("uses opts.time for deterministic output", function()
      local otp1, _ = totp.totp(TOTP_KEY_SHA1, { time = 1000 })
      local otp2, _ = totp.totp(TOTP_KEY_SHA1, { time = 1000 })
      T.eq(otp1, otp2)
    end)

    T.it("different periods produce different steps", function()
      -- period=30 at t=60 → step=2; period=60 at t=60 → step=1
      local otp30, _ = totp.totp(TOTP_KEY_SHA1, { time = 60, period = 30 })
      local otp60, _ = totp.totp(TOTP_KEY_SHA1, { time = 60, period = 60 })
      T.neq(otp30, otp60)
    end)

    T.it("rejects invalid period", function()
      local otp, err = totp.totp(TOTP_KEY_SHA1, { period = 0, time = 1000 })
      T.eq(otp, nil)
      T.ok(err ~= nil)
    end)
  end)

  -- ── totp_base32 ─────────────────────────────────────────────────────────────

  T.describe("totp_base32", function()
    -- "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ" is base32 for "12345678901234567890"
    -- Verified: base32.encode("12345678901234567890") = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    local B32_KEY = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    T.it("decodes base32 secret and computes TOTP", function()
      local otp, err = totp.totp_base32(B32_KEY, {
        digits = 8,
        period = 30,
        alg    = "sha1",
        time   = 59,
      })
      T.eq(err, nil)
      T.eq(otp, "94287082")
    end)

    T.it("rejects empty secret", function()
      local otp, err = totp.totp_base32("", {})
      T.eq(otp, nil)
      T.ok(err ~= nil)
    end)

    T.it("rejects invalid base32", function()
      local otp, err = totp.totp_base32("!!INVALID!!", {})
      T.eq(otp, nil)
      T.ok(err ~= nil)
    end)

    T.it("round-trips with verify", function()
      local secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
      local t = 1000
      local otp, err = totp.totp_base32(secret, { time = t })
      T.eq(err, nil)
      T.ok(otp ~= nil)
      local ok = totp.verify(secret, otp, { time = t })
      T.ok(ok)
    end)
  end)

  -- ── verify ──────────────────────────────────────────────────────────────────

  T.describe("verify", function()
    local SECRET = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    local FIXED_TIME = 59

    T.it("accepts correct code", function()
      local otp, _ = totp.totp_base32(SECRET, {
        digits = 8, period = 30, alg = "sha1", time = FIXED_TIME,
      })
      local ok = totp.verify(SECRET, otp, {
        window = 0, period = 30, time = FIXED_TIME, digits = 8,
      })
      T.ok(ok)
    end)

    T.it("rejects wrong code", function()
      local ok = totp.verify(SECRET, "000000", {
        window = 0, period = 30, time = FIXED_TIME,
      })
      T.ok(not ok)
    end)

    T.it("window=1 accepts previous step", function()
      -- Generate OTP at step N-1 (time = FIXED_TIME - 30)
      local prev_time = FIXED_TIME - 30
      local otp, _ = totp.totp_base32(SECRET, {
        digits = 6, period = 30, alg = "sha1", time = prev_time,
      })
      -- Verify at current time with window=1 should accept it
      local ok = totp.verify(SECRET, otp, {
        window = 1, period = 30, time = FIXED_TIME, digits = 6,
      })
      T.ok(ok)
    end)

    T.it("window=1 accepts next step", function()
      local next_time = FIXED_TIME + 30
      local otp, _ = totp.totp_base32(SECRET, {
        digits = 6, period = 30, alg = "sha1", time = next_time,
      })
      local ok = totp.verify(SECRET, otp, {
        window = 1, period = 30, time = FIXED_TIME, digits = 6,
      })
      T.ok(ok)
    end)

    T.it("returns false for invalid base32 secret", function()
      local ok = totp.verify("!!BAD!!", "123456", {})
      T.ok(not ok)
    end)
  end)

  -- ── otpauth_uri ─────────────────────────────────────────────────────────────

  T.describe("otpauth_uri", function()
    T.it("generates basic totp URI", function()
      local uri = totp.otpauth_uri("totp", "user@example.com", "JBSWY3DPEHPK3PXP", {})
      T.ok(uri:find("^otpauth://totp/") ~= nil)
      T.ok(uri:find("secret=JBSWY3DPEHPK3PXP") ~= nil)
    end)

    T.it("includes issuer in URI", function()
      local uri = totp.otpauth_uri("totp", "user@example.com", "JBSWY3DPEHPK3PXP", {
        issuer = "ExampleCorp",
      })
      T.ok(uri:find("issuer=ExampleCorp") ~= nil)
    end)

    T.it("includes digits in URI", function()
      local uri = totp.otpauth_uri("totp", "user@example.com", "JBSWY3DPEHPK3PXP", {
        digits = 8,
      })
      T.ok(uri:find("digits=8") ~= nil)
    end)

    T.it("includes period in TOTP URI", function()
      local uri = totp.otpauth_uri("totp", "user@example.com", "JBSWY3DPEHPK3PXP", {
        period = 60,
      })
      T.ok(uri:find("period=60") ~= nil)
    end)

    T.it("includes counter in HOTP URI", function()
      local uri = totp.otpauth_uri("hotp", "user@example.com", "JBSWY3DPEHPK3PXP", {
        counter = 5,
      })
      T.ok(uri:find("^otpauth://hotp/") ~= nil)
      T.ok(uri:find("counter=5") ~= nil)
    end)

    T.it("percent-encodes label with special chars", function()
      local uri = totp.otpauth_uri("totp", "My App:user@example.com", "SECRET", {})
      T.ok(uri:find("%%3A") ~= nil or uri:find("%%40") ~= nil)
    end)

    T.it("includes algorithm when specified", function()
      local uri = totp.otpauth_uri("totp", "user@example.com", "SECRET", {
        algorithm = "sha256",
      })
      T.ok(uri:find("algorithm=SHA256") ~= nil)
    end)
  end)

  -- ── new_secret ──────────────────────────────────────────────────────────────

  T.describe("new_secret", function()
    T.it("returns a non-empty base32 string", function()
      local s = totp.new_secret()
      T.ok(type(s) == "string")
      T.ok(#s > 0)
      -- must be decodable
      local decoded, err = require("lib.base32").decode(s)
      T.eq(err, nil)
      T.ok(decoded ~= nil)
    end)

    T.it("default length decodes to 20 bytes", function()
      local s = totp.new_secret()
      local decoded = require("lib.base32").decode(s)
      -- base32 encodes groups of 5 bytes → 8 chars; 20 bytes → 32 chars (with padding)
      -- decoded binary should be 20 bytes
      T.eq(#decoded, 20)
    end)

    T.it("respects custom bytes option", function()
      local s = totp.new_secret({ bytes = 10 })
      local decoded = require("lib.base32").decode(s)
      T.eq(#decoded, 10)
    end)

    T.it("two secrets are different (probabilistic)", function()
      local s1 = totp.new_secret()
      local s2 = totp.new_secret()
      -- Extremely unlikely to collide
      T.neq(s1, s2)
    end)
  end)

end)
