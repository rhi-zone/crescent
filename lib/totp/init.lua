-- lib/totp/init.lua
-- HOTP (RFC 4226) and TOTP (RFC 6238) one-time password generation.
--
-- Public API:
--   M.hotp(key, counter, opts)          -> otp_string, nil | nil, errmsg
--   M.totp(key, opts)                   -> otp_string, nil | nil, errmsg
--   M.totp_base32(secret, opts)         -> otp_string, nil | nil, errmsg
--   M.new_secret(opts)                  -> base32_string
--   M.verify(secret, code, opts)        -> boolean
--   M.otpauth_uri(type, label, secret, opts) -> uri_string
--   M._tier = "pure"

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local hmac = require("lib.hash.hmac")
local base32 = require("lib.base32")

local M = {}
M._tier = "pure"

local band   = bit.band
local bor    = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift

-- ── Counter encoding ──────────────────────────────────────────────────────────

-- Encode a non-negative integer as an 8-byte big-endian string.
-- LuaJIT integers are 64-bit when using the number type carefully.
-- For values that fit in 32 bits (step counts up to ~136 years at 30s periods
-- only reach ~10^9), high 4 bytes are zero.
local function counter_to_bytes(n)
  -- Split into high and low 32-bit halves.
  -- Use modular arithmetic to avoid float precision issues for large values.
  -- n is expected to be a non-negative Lua number.
  local lo = n % 0x100000000        -- lower 32 bits
  local hi = (n - lo) / 0x100000000 -- upper 32 bits (integer division)
  hi = hi % 0x100000000
  return string.char(
    band(rshift(hi, 24), 0xff),
    band(rshift(hi, 16), 0xff),
    band(rshift(hi,  8), 0xff),
    band(hi, 0xff),
    band(rshift(lo, 24), 0xff),
    band(rshift(lo, 16), 0xff),
    band(rshift(lo,  8), 0xff),
    band(lo, 0xff)
  )
end

-- ── HMAC dispatch ─────────────────────────────────────────────────────────────

local function hmac_binary(alg, key, msg)
  if alg == "sha1" or alg == nil then
    return hmac.sha1_binary(key, msg)
  elseif alg == "sha256" then
    return hmac.sha256_binary(key, msg)
  else
    return nil, "unsupported algorithm: " .. tostring(alg)
  end
end

-- ── HOTP (RFC 4226 §5.3) ──────────────────────────────────────────────────────

--- HOTP: HMAC-based One-Time Password.
-- key: raw binary secret (NOT base32-encoded)
-- counter: integer counter value (>= 0)
-- opts: { digits = 6, alg = "sha1" }
-- Returns: otp_string, nil  OR  nil, errmsg
function M.hotp(key, counter, opts)
  if type(key) ~= "string" or #key == 0 then
    return nil, "key must be a non-empty string"
  end
  if type(counter) ~= "number" or counter < 0 or counter ~= math.floor(counter) then
    return nil, "counter must be a non-negative integer"
  end
  opts = opts or {}
  local digits = opts.digits or 6
  if digits ~= 6 and digits ~= 8 then
    return nil, "digits must be 6 or 8"
  end
  local alg = opts.alg or "sha1"

  -- Step 1: encode counter as 8-byte big-endian
  local counter_bytes = counter_to_bytes(counter)

  -- Step 2: HMAC
  local mac, err = hmac_binary(alg, key, counter_bytes)
  if not mac then return nil, err end

  -- Step 3: dynamic truncation (RFC 4226 §5.3)
  -- offset = last byte & 0x0f
  local last = string.byte(mac, #mac)
  local offset = band(last, 0x0f)

  -- Step 4: extract 4 bytes at offset (1-indexed in Lua)
  local b1 = string.byte(mac, offset + 1)
  local b2 = string.byte(mac, offset + 2)
  local b3 = string.byte(mac, offset + 3)
  local b4 = string.byte(mac, offset + 4)

  -- mask the most-significant bit of b1
  local code = bor(
    lshift(band(b1, 0x7f), 24),
    lshift(b2, 16),
    lshift(b3, 8),
    b4
  )
  -- code is a signed 32-bit value from bit.*; convert to unsigned Lua number
  if code < 0 then code = code + 0x100000000 end

  -- Step 5: truncate to digits
  local modulus = 10 ^ digits
  local otp = code % modulus

  return string.format("%0" .. digits .. "d", otp), nil
end

-- ── TOTP (RFC 6238 §4) ────────────────────────────────────────────────────────

--- TOTP: Time-based One-Time Password.
-- key: raw binary secret
-- opts: { digits = 6, period = 30, alg = "sha1", time = os.time() }
-- Returns: otp_string, nil  OR  nil, errmsg
function M.totp(key, opts)
  opts = opts or {}
  local period = opts.period or 30
  if type(period) ~= "number" or period <= 0 then
    return nil, "period must be a positive number"
  end
  local t = opts.time or os.time()
  local step = math.floor(t / period)
  return M.hotp(key, step, opts)
end

--- TOTP with base32-encoded secret (common for authenticator apps).
-- secret: base32 string like "JBSWY3DPEHPK3PXP"
-- opts: same as totp()
-- Returns: otp_string, nil  OR  nil, errmsg
function M.totp_base32(secret, opts)
  if type(secret) ~= "string" or #secret == 0 then
    return nil, "secret must be a non-empty base32 string"
  end
  local key, err = base32.decode(secret)
  if not key then return nil, "base32 decode failed: " .. tostring(err) end
  return M.totp(key, opts)
end

-- ── Secret generation ─────────────────────────────────────────────────────────

--- Generate a new random secret.
-- opts: { bytes = 20 }
-- Returns: base32_string
function M.new_secret(opts)
  opts = opts or {}
  local nbytes = opts.bytes or 20
  math.randomseed(os.time() + math.random(0, 65535))
  local bytes = {}
  for i = 1, nbytes do
    bytes[i] = string.char(math.random(0, 255))
  end
  return base32.encode(table.concat(bytes))
end

-- ── Verification ──────────────────────────────────────────────────────────────

--- Verify a TOTP code with a time window.
-- secret: base32 string
-- code: string like "123456"
-- opts: { window = 1, period = 30, time = os.time() }
-- Returns: true or false
function M.verify(secret, code, opts)
  if type(secret) ~= "string" or type(code) ~= "string" then
    return false
  end
  local key, err = base32.decode(secret)
  if not key then return false end

  opts = opts or {}
  local window = opts.window or 1
  local period = opts.period or 30
  local t = opts.time or os.time()
  local step = math.floor(t / period)

  for delta = -window, window do
    local otp, e = M.hotp(key, step + delta, {
      digits = opts.digits or 6,
      alg    = opts.alg or "sha1",
    })
    if otp and otp == code then
      return true
    end
  end
  return false
end

-- ── URI generation ────────────────────────────────────────────────────────────

-- Percent-encode a string for use in a URI.
local function uri_encode(s)
  return (s:gsub("[^%w%-%.%_%~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

--- Generate an otpauth:// URI for QR code provisioning.
-- otype: "totp" or "hotp"
-- label: account label (e.g. "user@example.com")
-- secret: base32 string
-- opts: { issuer, digits, period, counter, algorithm }
-- Returns: uri_string
function M.otpauth_uri(otype, label, secret, opts)
  opts = opts or {}
  local uri = "otpauth://" .. tostring(otype) .. "/" .. uri_encode(tostring(label))
    .. "?secret=" .. tostring(secret)
  if opts.issuer then
    uri = uri .. "&issuer=" .. uri_encode(tostring(opts.issuer))
  end
  if opts.digits then
    uri = uri .. "&digits=" .. tostring(opts.digits)
  end
  if otype == "totp" then
    local period = opts.period or 30
    uri = uri .. "&period=" .. tostring(period)
  end
  if otype == "hotp" and opts.counter then
    uri = uri .. "&counter=" .. tostring(opts.counter)
  end
  if opts.algorithm then
    uri = uri .. "&algorithm=" .. tostring(opts.algorithm):upper()
  end
  return uri
end

return M
