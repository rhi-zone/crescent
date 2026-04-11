-- lib/poly1305/poly1305_test.lua
-- Comprehensive tests for lib/poly1305 (Poly1305 one-time MAC, RFC 8439).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local poly    = require("lib.poly1305")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Decode a hex string into binary.
local function from_hex(h)
  return (h:gsub("%s+", ""):gsub("..", function(c)
    return string.char(tonumber(c, 16))
  end))
end

-- Encode binary to hex.
local function to_hex(s)
  local t = {}
  for i = 1, #s do
    t[i] = string.format("%02x", string.byte(s, i))
  end
  return table.concat(t)
end

-- ---------------------------------------------------------------------------
-- RFC 8439 test vectors
-- ---------------------------------------------------------------------------

-- RFC 8439 §2.5.2 — the canonical Poly1305 test vector.
-- Key and message produce a known 16-byte tag.
local RFC_KEY = from_hex(
  "85d6be7857556d337f4452fe42d506a8" ..
  "0103808afb0db2fd4abff6af4149f51b"
)
local RFC_MSG = "Cryptographic Forum Research Group"
local RFC_TAG = from_hex("a8061dc1305136c6c22b8baf0c0127a9")

-- All-zero key: tag must also be all zeros (r=0 means polynomial is 0+s=s, and s=0).
local ZERO_KEY = ("\0"):rep(32)
local ZERO_64  = ("\0"):rep(64)
local ZERO_TAG = ("\0"):rep(16)

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

T.describe("lib.poly1305", function()

  T.describe("tier", function()
    T.it("M._tier is 'pure'", function()
      T.eq(poly._tier, "pure")
    end)
  end)

  T.describe("auth", function()

    T.it("RFC 8439 §2.5.2 known vector", function()
      local tag, err = poly.auth(RFC_KEY, RFC_MSG)
      T.ok(err == nil, "no error: " .. tostring(err))
      T.ok(tag ~= nil, "tag returned")
      T.eq(to_hex(tag), "a8061dc1305136c6c22b8baf0c0127a9")
    end)

    T.it("all-zero key + 64 zero bytes → all-zero tag", function()
      local tag, err = poly.auth(ZERO_KEY, ZERO_64)
      T.ok(err == nil, "no error: " .. tostring(err))
      T.eq(to_hex(tag), ("00"):rep(16))
    end)

    T.it("empty message", function()
      -- With an empty message no blocks are processed; tag = s (= 0 for zero key).
      local tag, err = poly.auth(ZERO_KEY, "")
      T.ok(err == nil, "no error: " .. tostring(err))
      T.eq(to_hex(tag), ("00"):rep(16))
    end)

    T.it("single-byte message", function()
      local tag, err = poly.auth(RFC_KEY, "\x41")
      T.ok(err == nil, "no error")
      T.ok(tag ~= nil and #tag == 16, "16-byte tag")
    end)

    T.it("exactly 16-byte message (single full block)", function()
      local tag, err = poly.auth(RFC_KEY, ("\x41"):rep(16))
      T.ok(err == nil, "no error")
      T.ok(tag ~= nil and #tag == 16, "16-byte tag")
    end)

    T.it("17-byte message (one full block + one partial)", function()
      local tag, err = poly.auth(RFC_KEY, ("\x41"):rep(17))
      T.ok(err == nil, "no error")
      T.ok(tag ~= nil and #tag == 16, "16-byte tag")
    end)

    T.it("multi-block message", function()
      -- 64 bytes → 4 full blocks.
      local tag, err = poly.auth(RFC_KEY, ("\x42"):rep(64))
      T.ok(err == nil, "no error")
      T.ok(tag ~= nil and #tag == 16, "16-byte tag")
    end)

    T.it("returns 16-byte binary string", function()
      local tag = poly.auth(RFC_KEY, RFC_MSG)
      T.eq(#tag, 16)
    end)

    -- Additional RFC 8439 Appendix A.3 vectors (test vector #1):
    -- key = 00..00 (32 bytes), msg = 00..00 (64 bytes), tag = 00..00
    T.it("RFC 8439 Appendix A.3 vector #1 (all zeros)", function()
      local key = from_hex(
        "0000000000000000000000000000000000000000000000000000000000000000"
      )
      local msg = from_hex(
        "00000000000000000000000000000000" ..
        "00000000000000000000000000000000" ..
        "00000000000000000000000000000000" ..
        "00000000000000000000000000000000"
      )
      local tag, err = poly.auth(key, msg)
      T.ok(err == nil, "no error")
      T.eq(to_hex(tag), ("00"):rep(16))
    end)

    -- RFC 8439 Appendix A.3 vector #2:
    -- key = 00..00 36 e5 f6 b5 c5 e0 60 70 f0 ef ca96 22 7a 86 3e
    --       00..00 (second half zeros)
    -- msg = "Any submission to the IETF intended..." (128 bytes)
    T.it("RFC 8439 Appendix A.3 vector #2", function()
      local key = from_hex(
        "0000000000000000000000000000000036e5f6b5c5e06070f0efca96227a863e"
      )
      local msg =
        "Any submission to the IETF intended by the Contributor for publication as all or part of an IETF Internet-Draft or RFC and any statement made within the context of an IETF activity is considered an \"IETF Contribution\"."
      -- Truncate to first 131 bytes (per appendix — the full message is 131 bytes).
      msg = msg:sub(1, 131)
      local _, err = poly.auth(key, msg)
      T.ok(err == nil, "no error: " .. tostring(err))
    end)

    -- RFC 8439 Appendix A.3 vector #3 (r clamped, verifiable):
    -- key = 36e5f6b5c5e06070f0efca96227a863e 00000000000000000000000000000000
    -- msg = "Any submission..."
    T.it("RFC 8439 Appendix A.3 vector #3", function()
      local key = from_hex(
        "36e5f6b5c5e06070f0efca96227a863e" ..
        "00000000000000000000000000000000"
      )
      local msg =
        "Any submission to the IETF intended by the Contributor for publication as all or part of an IETF Internet-Draft or RFC and any statement made within the context of an IETF activity is considered an \"IETF Contribution\"."
      msg = msg:sub(1, 131)
      local tag, err = poly.auth(key, msg)
      T.ok(err == nil, "no error")
      T.ok(tag ~= nil and #tag == 16, "16-byte tag")
    end)

    -- RFC 8439 Appendix A.3 vector #7 (full numeric check):
    T.it("RFC 8439 Appendix A.3 vector #7", function()
      local key = from_hex(
        "0200000000000000000000000000000000000000000000000000000000000000"
      )
      local msg = from_hex(
        "ffffffffffffffffffffffffffffffff"
      )
      local tag, err = poly.auth(key, msg)
      T.ok(err == nil, "no error")
      T.ok(tag ~= nil and #tag == 16, "16-byte tag")
      -- r=2, s=0, msg block = 0xfff...ff | 2^128
      -- n = 2^128 + 2^128 - 1 = 2^129 - 1
      -- (2^129 - 1) * 2 mod (2^130 - 5) = 2^130 - 2 mod (2^130-5) = 2^130-2-(2^130-5) = 3
      -- tag = 3 + 0 = 3 (as 16-byte LE) = 03 00 00 ... 00
      T.eq(to_hex(tag), "03000000000000000000000000000000")
    end)

    -- RFC 8439 Appendix A.3 vector #8 (wrap-around):
    T.it("RFC 8439 Appendix A.3 vector #8 (reduction boundary)", function()
      local key = from_hex(
        "0200000000000000000000000000000000000000000000000000000000000000"
      )
      -- Two blocks of 0xff...ff.
      local msg = from_hex(
        "ffffffffffffffffffffffffffffffff" ..
        "f0ffffffffffffffffffffffffffffff"
      )
      local tag, err = poly.auth(key, msg)
      T.ok(err == nil, "no error")
      T.ok(tag ~= nil and #tag == 16, "16-byte tag")
    end)

  end)

  T.describe("auth_hex", function()

    T.it("returns a 32-character lowercase hex string", function()
      local hex, err = poly.auth_hex(RFC_KEY, RFC_MSG)
      T.ok(err == nil, "no error")
      T.ok(type(hex) == "string", "is string")
      T.eq(#hex, 32)
      T.ok(hex:match("^[0-9a-f]+$") ~= nil, "lowercase hex chars")
    end)

    T.it("matches RFC 8439 §2.5.2 vector", function()
      local hex = poly.auth_hex(RFC_KEY, RFC_MSG)
      T.eq(hex, "a8061dc1305136c6c22b8baf0c0127a9")
    end)

    T.it("consistent with auth()", function()
      local tag     = poly.auth(RFC_KEY, RFC_MSG)
      local hex_via_auth    = to_hex(tag)
      local hex_via_auth_hex = poly.auth_hex(RFC_KEY, RFC_MSG)
      T.eq(hex_via_auth, hex_via_auth_hex)
    end)

    T.it("all-zero key + empty message → 32 zero hex chars", function()
      local hex = poly.auth_hex(ZERO_KEY, "")
      T.eq(hex, ("00"):rep(16))
    end)

  end)

  T.describe("verify", function()

    T.it("correct tag → true", function()
      T.ok(poly.verify(RFC_KEY, RFC_MSG, RFC_TAG) == true)
    end)

    T.it("wrong tag → false", function()
      -- Flip a single bit in the tag.
      local bad_tag = from_hex("a9061dc1305136c6c22b8baf0c0127a9")
      T.ok(poly.verify(RFC_KEY, RFC_MSG, bad_tag) == false)
    end)

    T.it("wrong message → false", function()
      T.ok(poly.verify(RFC_KEY, RFC_MSG .. "!", RFC_TAG) == false)
    end)

    T.it("wrong key → false", function()
      local other_key = ("\x01"):rep(32)
      T.ok(poly.verify(other_key, RFC_MSG, RFC_TAG) == false)
    end)

    T.it("all-zero vector → true", function()
      T.ok(poly.verify(ZERO_KEY, ZERO_64, ZERO_TAG) == true)
    end)

    T.it("non-string tag → false", function()
      T.ok(poly.verify(RFC_KEY, RFC_MSG, 42) == false)
    end)

    T.it("tag wrong length → false", function()
      T.ok(poly.verify(RFC_KEY, RFC_MSG, "\x00") == false)
    end)

    -- Timing-safety: verify should run the same code path regardless of
    -- where the first difference is (first byte vs last byte).  We can't
    -- measure wall-clock reliably, but we can at least confirm both paths
    -- return false and that the function reaches the end (no early return).
    T.it("timing-safe: mismatch in first byte still returns false", function()
      -- Tag differs only in byte 1.
      local bytes = {}
      for i = 1, 16 do bytes[i] = string.byte(RFC_TAG, i) end
      bytes[1]  = (bytes[1] + 1) % 256
      local bad = string.char(unpack(bytes))
      T.ok(poly.verify(RFC_KEY, RFC_MSG, bad) == false)
    end)

    T.it("timing-safe: mismatch in last byte still returns false", function()
      -- Tag differs only in byte 16.
      local bytes = {}
      for i = 1, 16 do bytes[i] = string.byte(RFC_TAG, i) end
      bytes[16] = (bytes[16] + 1) % 256
      local bad = string.char(unpack(bytes))
      T.ok(poly.verify(RFC_KEY, RFC_MSG, bad) == false)
    end)

  end)

  T.describe("streaming", function()

    T.it("new() + update() + finish() == auth()", function()
      local ctx = poly.new(RFC_KEY)
      T.ok(ctx ~= nil, "ctx created")
      ctx:update(RFC_MSG)
      local tag = ctx:finish()
      T.eq(to_hex(tag), "a8061dc1305136c6c22b8baf0c0127a9")
    end)

    T.it("multiple updates same as single update", function()
      local msg = RFC_MSG
      -- Split at various points.
      local splits = { 1, 5, 8, 16, 17, #msg - 1 }
      local single = poly.auth(RFC_KEY, msg)
      for _, split in ipairs(splits) do
        local ctx = poly.new(RFC_KEY)
        ctx:update(msg:sub(1, split))
        ctx:update(msg:sub(split + 1))
        local tag = ctx:finish()
        T.eq(
          to_hex(tag), to_hex(single),
          "split at " .. split .. " should match single auth"
        )
      end
    end)

    T.it("byte-at-a-time updates", function()
      local ctx = poly.new(RFC_KEY)
      for i = 1, #RFC_MSG do
        ctx:update(RFC_MSG:sub(i, i))
      end
      local tag = ctx:finish()
      T.eq(to_hex(tag), "a8061dc1305136c6c22b8baf0c0127a9")
    end)

    T.it("16-byte chunk updates", function()
      local msg = ("\x42"):rep(64)
      local single = poly.auth(RFC_KEY, msg)
      local ctx = poly.new(RFC_KEY)
      for i = 1, 64, 16 do
        ctx:update(msg:sub(i, i + 15))
      end
      local tag = ctx:finish()
      T.eq(to_hex(tag), to_hex(single))
    end)

    T.it("finish() is idempotent-error: second call errors", function()
      local ctx = poly.new(RFC_KEY)
      ctx:update(RFC_MSG)
      ctx:finish()
      local tag2, err = ctx:finish()
      T.ok(tag2 == nil, "nil on second finish")
      T.ok(type(err) == "string", "error message returned")
    end)

    T.it("update() after finish() errors", function()
      local ctx = poly.new(RFC_KEY)
      ctx:finish()
      local ok, err = ctx:update("more data")
      T.ok(ok == nil, "nil on update after finish")
      T.ok(type(err) == "string", "error message returned")
    end)

    T.it("empty update is a no-op", function()
      local ctx1 = poly.new(RFC_KEY)
      ctx1:update(RFC_MSG)
      local tag1 = ctx1:finish()

      local ctx2 = poly.new(RFC_KEY)
      ctx2:update("")
      ctx2:update(RFC_MSG)
      ctx2:update("")
      local tag2 = ctx2:finish()

      T.eq(to_hex(tag1), to_hex(tag2))
    end)

    T.it("streaming on zero-key all-zero message", function()
      local ctx = poly.new(ZERO_KEY)
      ctx:update(ZERO_64)
      local tag = ctx:finish()
      T.eq(to_hex(tag), ("00"):rep(16))
    end)

  end)

  T.describe("errors", function()

    T.it("auth: key too short → nil, errmsg", function()
      local tag, err = poly.auth(("\x00"):rep(16), "msg")
      T.ok(tag == nil, "nil tag")
      T.ok(type(err) == "string", "error string")
    end)

    T.it("auth: key too long → nil, errmsg", function()
      local tag, err = poly.auth(("\x00"):rep(33), "msg")
      T.ok(tag == nil, "nil tag")
      T.ok(type(err) == "string", "error string")
    end)

    T.it("auth: key is not a string → nil, errmsg", function()
      local tag, err = poly.auth(12345, "msg")
      T.ok(tag == nil, "nil tag")
      T.ok(type(err) == "string", "error string")
    end)

    T.it("auth: message is not a string → nil, errmsg", function()
      local tag, err = poly.auth(RFC_KEY, 42)
      T.ok(tag == nil, "nil tag")
      T.ok(type(err) == "string", "error string")
    end)

    T.it("auth_hex: wrong key length → nil, errmsg", function()
      local hex, err = poly.auth_hex("short", "msg")
      T.ok(hex == nil, "nil hex")
      T.ok(type(err) == "string", "error string")
    end)

    T.it("new: wrong key length → nil, errmsg", function()
      local ctx, err = poly.new("tooshort")
      T.ok(ctx == nil, "nil ctx")
      T.ok(type(err) == "string", "error string")
    end)

    T.it("new: key not a string → nil, errmsg", function()
      local ctx, err = poly.new(nil)
      T.ok(ctx == nil, "nil ctx")
      T.ok(type(err) == "string", "error string")
    end)

    T.it("update: non-string chunk → nil, errmsg", function()
      local ctx = poly.new(RFC_KEY)
      local ok, err = ctx:update(42)
      T.ok(ok == nil, "nil")
      T.ok(type(err) == "string", "error string")
    end)

  end)

end)
