-- lib/jwt/init.lua
-- JSON Web Token encode/decode (RFC 7519).
-- Supports HS256 (HMAC-SHA256). HS384/HS512 are rejected (no SHA-384/512 HMAC available).
-- "none" algorithm: decode_unverified only; encode rejects it.
-- Pure Lua — depends on lib.hash.hmac, lib.base64, lib.json.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local hmac   = require("lib.hash.hmac")
local base64 = require("lib.base64")
local json   = require("lib.json")

-- ── base64url helpers ─────────────────────────────────────────────────────────

-- Encode binary string to base64url (no padding, URL-safe alphabet).
--: (string) -> string
local function b64url_encode(s)
  return base64.encode(s, { url = true, pad = false })
end

-- Decode base64url string (with or without padding) to binary.
-- Returns (string) or (nil, errmsg).
--: (string) -> string | (nil, string)
local function b64url_decode(s)
  -- Add padding if needed so base64.decode is happy
  local rem = #s % 4
  if rem == 2 then s = s .. "=="
  elseif rem == 3 then s = s .. "="
  end
  return base64.decode(s, { url = true })
end

-- ── Timing-safe comparison ────────────────────────────────────────────────────

-- Compare two strings without early exit to resist timing attacks.
-- Returns true iff a == b (same length and same bytes).
--: (string, string) -> boolean
local function safe_eq(a, b)
  if #a ~= #b then return false end
  local diff = 0
  for i = 1, #a do
    diff = diff + (string.byte(a, i) ~= string.byte(b, i) and 1 or 0)
  end
  return diff == 0
end

-- ── Supported algorithms ──────────────────────────────────────────────────────

-- Map alg name → sign function(key, signing_input) → binary signature
local ALGORITHMS = {
  HS256 = function(key, input) return hmac.sha256_binary(key, input) end,
}

-- ── Internal helpers ──────────────────────────────────────────────────────────

-- Encode a Lua table to compact JSON with sorted keys.
-- Returns (string, nil) or (nil, errmsg).
--: (unknown) -> string | (nil, string)
local function json_encode_sorted(t)
  return json.encode(t, { sort_keys = true })
end

-- Split a JWT token string into its three parts.
-- Returns header_b64, payload_b64, sig_b64  OR  nil, nil, nil, errmsg.
--: (string) -> (string, string, string | (nil, nil, nil, string))
local function split_token(token)
  local parts = {}
  local n = 0
  for part in (token .. "."):gmatch("([^.]*)[.]") do
    n = n + 1
    parts[n] = part
  end
  if n ~= 3 then
    return nil, nil, nil, "malformed token: expected 3 parts, got " .. n
  end
  return parts[1], parts[2], parts[3], nil
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Return the current Unix time via the given time function.
--: (() -> number) -> number
function M.now(time_fn)
  assert(time_fn, "now requires time_fn")
  return time_fn()
end

--- Return time_fn() + seconds (for use as exp claim).
--: (() -> number, number) -> number
function M.exp_in(time_fn, seconds)
  assert(time_fn, "exp_in requires time_fn")
  return time_fn() + seconds
end

--- Encode a JWT.
-- Returns: token_string, nil  OR  nil, errmsg.
-- opts.alg defaults to "HS256". HS384/HS512 → error. "none" → error.
--: (unknown, string, { alg: string | nil } | nil) -> string | (nil, string)
function M.encode(payload, secret, opts)
  local alg = (opts and opts.alg) or "HS256"

  if alg == "none" then
    return nil, "alg 'none' not allowed for encoding"
  end

  local sign = ALGORITHMS[alg]
  if not sign then
    return nil, "algorithm not supported: " .. tostring(alg)
  end

  -- Build header
  local header = { alg = alg, typ = "JWT" }
  local header_json, err = json_encode_sorted(header)
  if not header_json then
    return nil, "failed to encode header: " .. (err or "unknown")
  end

  -- Build payload
  local payload_json, err2 = json.encode(payload)
  if not payload_json then
    return nil, "failed to encode payload: " .. (err2 or "unknown")
  end

  local header_b64  = b64url_encode(header_json)
  local payload_b64 = b64url_encode(payload_json)
  local signing_input = header_b64 .. "." .. payload_b64

  local sig_bin = sign(secret, signing_input)
  local sig_b64 = b64url_encode(sig_bin)

  return signing_input .. "." .. sig_b64, nil
end

--- Decode and verify a JWT.
-- Returns: payload_table, header_table  OR  nil, errmsg.
-- opts.verify (default true): verify signature and time claims.
-- opts.algorithms: list of accepted algorithm names (default {"HS256"}).
-- opts.time_fn: required when verify ~= false — function returning unix timestamp.
--: (string, string, { verify: boolean | nil, algorithms: unknown, time_fn: (() -> number) | nil } | nil) -> (unknown, unknown | (nil, string))
function M.decode(token, secret, opts)
  local verify = not (opts and opts.verify == false)
  local allowed_algs
  if opts and opts.algorithms then
    allowed_algs = {}
    for _, a in ipairs(opts.algorithms) do allowed_algs[a] = true end
  else
    allowed_algs = { HS256 = true }
  end

  local header_b64, payload_b64, sig_b64, split_err = split_token(token)
  if split_err then return nil, split_err end

  -- Decode header
  local header_json, h_err = b64url_decode(header_b64)
  if not header_json then return nil, "invalid header encoding: " .. (h_err or "") end
  local header, hj_err = json.decode(header_json)
  if not header then return nil, "invalid header JSON: " .. (hj_err or "") end

  -- Decode payload
  local payload_json, p_err = b64url_decode(payload_b64)
  if not payload_json then return nil, "invalid payload encoding: " .. (p_err or "") end
  local payload, pj_err = json.decode(payload_json)
  if not payload then return nil, "invalid payload JSON: " .. (pj_err or "") end

  if not verify then
    return payload, header
  end

  -- Algorithm check
  local alg = header.alg
  if alg == "none" then
    return nil, "algorithm 'none' rejected"
  end
  if not allowed_algs[alg] then
    return nil, "algorithm not allowed: " .. tostring(alg)
  end
  local sign = ALGORITHMS[alg]
  if not sign then
    return nil, "algorithm not supported: " .. tostring(alg)
  end

  -- Signature verification (timing-safe)
  local signing_input = header_b64 .. "." .. payload_b64
  local expected_bin = sign(secret, signing_input)
  local expected_b64 = b64url_encode(expected_bin)
  if not safe_eq(sig_b64, expected_b64) then
    return nil, "signature verification failed"
  end

  -- Time claims
  assert(opts and opts.time_fn, "decode with verify requires opts.time_fn")
  local now = opts.time_fn()
  if type(payload) == "table" then
    if payload.exp ~= nil then
      if type(payload.exp) ~= "number" then
        return nil, "invalid exp claim: not a number"
      end
      if now > payload.exp then
        return nil, "token expired"
      end
    end
    if payload.nbf ~= nil then
      if type(payload.nbf) ~= "number" then
        return nil, "invalid nbf claim: not a number"
      end
      if now < payload.nbf then
        return nil, "token not yet valid"
      end
    end
  end

  return payload, header
end

--- Decode a JWT without verifying the signature or time claims.
-- Useful for inspection. Returns: payload_table, header_table  OR  nil, errmsg.
--: (string) -> (unknown, unknown | (nil, string))
function M.decode_unverified(token)
  local header_b64, payload_b64, _, split_err = split_token(token)
  if split_err then return nil, split_err end

  local header_json, h_err = b64url_decode(header_b64)
  if not header_json then return nil, "invalid header encoding: " .. (h_err or "") end
  local header, hj_err = json.decode(header_json)
  if not header then return nil, "invalid header JSON: " .. (hj_err or "") end

  local payload_json, p_err = b64url_decode(payload_b64)
  if not payload_json then return nil, "invalid payload encoding: " .. (p_err or "") end
  local payload, pj_err = json.decode(payload_json)
  if not payload then return nil, "invalid payload JSON: " .. (pj_err or "") end

  return payload, header
end

return M
