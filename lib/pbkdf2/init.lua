-- lib/pbkdf2/init.lua
-- PBKDF2 key derivation function (RFC 8018 / PKCS#5 v2.1).
--
-- Public API:
--   M.derive(password, salt, iterations, dklen, opts)     -> binary_string | nil, errmsg
--   M.derive_hex(password, salt, iterations, dklen, opts) -> hex_string    | nil, errmsg
--   M.verify(password, salt, iterations, derived_key, opts) -> boolean     | nil, errmsg
--   M._tier = "pure"
--
-- opts: { alg = "sha256"|"sha1" (default "sha256") }
-- For verify, opts may also include: { hex = true } if derived_key is hex-encoded.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local hmac = require("lib.hash.hmac")

local M = {}
M._tier = "pure"

-- XOR two equal-length binary strings byte by byte.
local function xor_strings(a, b)
  local result = {}
  for i = 1, #a do
    local ba = (string.byte(a, i, i) or 0) --[[:! integer]]
    local bb = (string.byte(b, i, i) or 0) --[[:! integer]]
    result[i] = string.char(bit.bxor(ba, bb))
  end
  return table.concat(result)
end

-- Encode n as a 4-byte big-endian binary string.
local function int32_be(n)
  return string.char(
    math.floor(n / 0x1000000) % 256,
    math.floor(n / 0x10000) % 256,
    math.floor(n / 0x100) % 256,
    n % 256
  )
end

-- Convert binary string to lowercase hex string.
local function binary_to_hex(bin)
  local parts = {}
  for i = 1, #bin do
    parts[i] = string.format("%02x", string.byte(bin, i))
  end
  return table.concat(parts)
end

-- Convert hex string to binary string.
local function hex_to_binary(hex)
  return (hex:gsub("..", function(h) return string.char(tonumber(h, 16)) end))
end

-- Select the PRF function and its output length based on alg.
local function get_prf(alg)
  if alg == "sha1" then
    return hmac.sha1_binary, 20
  elseif alg == "sha256" or alg == nil then
    return hmac.sha256_binary, 32
  else
    return nil, nil, "pbkdf2: unknown algorithm: " .. tostring(alg)
  end
end

-- Compute one block Ti = F(password, salt, c, i) per RFC 8018 §5.2.
local function compute_block(prf, password, salt, iterations, i)
  local prf_fn = prf --[[:! (string, string) -> string]]
  -- U1 = PRF(password, salt || INT(i))
  local u = prf_fn(password, salt .. int32_be(i))
  local t = u
  for _ = 2, iterations do
    u = prf_fn(password, u)
    t = xor_strings(t, u)
  end
  return t
end

--- Derive a key using PBKDF2.
-- password:   string
-- salt:       string
-- iterations: integer >= 1
-- dklen:      desired output key length in bytes (default: hash output length)
-- opts:       { alg = "sha256"|"sha1" }
-- Returns: binary_string (dklen bytes) or nil, errmsg
function M.derive(password, salt, iterations, dklen, opts)
  local alg = opts and opts.alg
  local prf, hlen, err = get_prf(alg)
  if not prf then return nil, err end
  local prf_any = prf --[[: any]]
  local prf_ = prf_any --[[:! (string, string) -> string]]
  local hlen_ = (hlen or 32) --[[:! integer]]

  if type(iterations) ~= "number" or iterations < 1 or math.floor(iterations) ~= iterations then
    return nil, "pbkdf2: iterations must be a positive integer"
  end

  dklen = dklen or hlen_

  if type(dklen) ~= "number" or dklen < 1 or math.floor(dklen) ~= dklen then
    return nil, "pbkdf2: dklen must be a positive integer"
  end

  -- RFC 8018: dklen <= (2^32 - 1) * hlen
  -- We skip the exact large-number check for simplicity; LuaJIT doubles can
  -- represent the limit precisely only up to 2^53. In practice dklen fits.

  local dklen_ = dklen --[[:! integer]]
  local blocks = math.ceil(dklen_ / hlen_) --[[:! integer]]
  local parts = {}
  for i = 1, blocks do
    parts[i] = compute_block(prf_, password, salt, iterations, i)
  end
  local dk = table.concat(parts)
  -- Truncate to dklen bytes.
  return dk:sub(1, dklen_)
end

--- Derive a key and return it as a lowercase hex string.
function M.derive_hex(password, salt, iterations, dklen, opts)
  local dk, err = M.derive(password, salt, iterations, dklen, opts)
  if not dk then return nil, err end
  return binary_to_hex(dk)
end

--- Verify a password against a stored derived key (timing-safe comparison).
-- password:    string
-- salt:        string
-- iterations:  integer
-- derived_key: binary string (or hex string if opts.hex == true)
-- opts:        { alg, hex = true|false }
-- Returns: boolean or nil, errmsg
function M.verify(password, salt, iterations, derived_key, opts)
  local hex_mode = opts and opts.hex
  local stored
  if hex_mode then
    stored = hex_to_binary(derived_key)
  else
    stored = derived_key
  end

  local dklen = #stored
  local candidate, err = M.derive(password, salt, iterations, dklen, opts)
  if not candidate then return nil, err end

  -- Timing-safe byte-by-byte comparison.
  if #candidate ~= #stored then return false end
  local diff = 0
  for i = 1, #stored do
    local bc = (string.byte(candidate, i, i) or 0) --[[:! integer]]
    local bs = (string.byte(stored, i, i) or 0) --[[:! integer]]
    diff = bit.bor(diff, bit.bxor(bc, bs))
  end
  return diff == 0
end

return M
