-- lib/curve25519/init.lua
-- X25519 Diffie-Hellman key exchange (RFC 7748) using Curve25519.
-- Pure Lua implementation using TweetNaCl-style 16-limb GF(2^255-19) arithmetic.
--
-- Public API:
--   M.clamp(key)                  -> clamped 32-byte string
--   M.public_key(private_key)     -> 32-byte string | nil, errmsg
--   M.diffie_hellman(priv, pub)   -> 32-byte string | nil, errmsg
--   M.keypair(seed)               -> priv(32), pub(32)  seed: 32-byte string, required
--   M._tier = "pure"

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local sbyte  = string.byte
local schar  = string.char
local floor  = math.floor

-- ---------------------------------------------------------------------------
-- GF(2^255-19) arithmetic
-- TweetNaCl representation: gf is a table of 16 Lua numbers (doubles),
-- each holding a ~16-bit value (limbs in radix 2^16, little-endian).
-- After carry reduction, each limb fits in [-2^15, 2^15].
-- Intermediate products may temporarily exceed this range.
-- ---------------------------------------------------------------------------

-- p = 2^255 - 19
-- In 16-limb radix-2^16 representation, p = [0xffed, 0xffff, ..., 0xffff, 0x7fff]
-- But we work modulo p implicitly via the reduction constant 38 = 2*19.

local function gf_new()
  return {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}
end

local function gf_copy(a)
  return {a[1],a[2],a[3],a[4],a[5],a[6],a[7],a[8],
          a[9],a[10],a[11],a[12],a[13],a[14],a[15],a[16]}
end

-- Carry reduction: bring all limbs into a consistent range.
-- After carry, limb i is in roughly [0, 2^16).
local function car(o)
  local c
  for i = 1, 16 do
    o[i] = o[i] + 65536  -- 2^16 bias to avoid negative modulo issues
    c = floor(o[i] / 65536)
    if i < 16 then
      o[i+1] = o[i+1] + c - 1
    else
      -- wrap: the top carry folds back as 38 * c  (since 2^256 = 38 mod p)
      o[1] = o[1] + 38 * (c - 1)
    end
    o[i] = o[i] - c * 65536
  end
end

-- Fully reduce: two rounds of carry to ensure canonical form in [0, p).
-- After two rounds the value is in [0, 2^256) and below p.
local function reduce(o)
  car(o)
  car(o)
end

-- Field addition: a + b mod p
local function gf_add(a, b)
  local o = gf_new()
  for i = 1, 16 do o[i] = a[i] + b[i] end
  return o
end

-- Field subtraction: a - b mod p
local function gf_sub(a, b)
  local o = gf_new()
  for i = 1, 16 do o[i] = a[i] - b[i] end
  return o
end

-- Field multiplication: a * b mod p
-- Uses schoolbook O(n^2) with fold via 38 for limbs >= 16.
local function gf_mul(a, b)
  local t = {}
  for i = 1, 31 do t[i] = 0 end
  for i = 1, 16 do
    for j = 1, 16 do
      t[i+j-1] = t[i+j-1] + a[i] * b[j]
    end
  end
  -- Fold high limbs back using 2^256 = 38 mod p.
  -- t[17..31] fold into t[1..15]: t[i] += 38 * t[i+16].
  -- t[32] is never produced (max index = 16+16-1 = 31) but we guard anyway.
  for i = 1, 15 do
    t[i] = t[i] + 38 * t[i + 16]
  end
  local o = {}
  for i = 1, 16 do o[i] = t[i] end
  -- t now has 16 entries but may overflow; run two carries
  car(o)
  car(o)
  return o
end

-- Field squaring: a^2 mod p (same as multiply but can be slightly optimised)
local function gf_sq(a)
  return gf_mul(a, a)
end

-- Conditional swap: if swap==1, exchange (a,b); if swap==0, leave unchanged.
-- swap must be 0 or 1 only (a single scalar bit).
local function cswap(swap, a, b)
  -- Arithmetic trick: d = swap * (b[i] - a[i])
  -- if swap=1: a[i] += d = b[i], b[i] -= d = a[i]  (swapped)
  -- if swap=0: d=0, no change
  for i = 1, 16 do
    local d = swap * (b[i] - a[i])
    a[i] = a[i] + d
    b[i] = b[i] - d
  end
end

-- Field inversion: z^(p-2) mod p via Fermat's little theorem.
-- p-2 = 2^255-21: all bits set except bits 2 and 4 from the LSB.
-- Uses TweetNaCl's inv25519 square-and-multiply approach:
--   start with c=z, iterate bits 253 down to 0:
--   always square, multiply by z unless bit position is 2 or 4.
local function gf_inv(z)
  local c = gf_copy(z)
  for a = 253, 0, -1 do
    c = gf_sq(c)
    if a ~= 2 and a ~= 4 then
      c = gf_mul(c, z)
    end
  end
  return c
end

-- ---------------------------------------------------------------------------
-- Encoding / decoding field elements to/from 32-byte little-endian strings
-- ---------------------------------------------------------------------------

-- Decode 32-byte little-endian string into a gf element.
local function gf_decode(s)
  local o = gf_new()
  -- Each pair of bytes forms one 16-bit limb.
  for i = 1, 16 do
    local lo = sbyte(s, 2*i - 1)
    local hi = sbyte(s, 2*i)
    o[i] = lo + hi * 256
  end
  -- Clear the high bit of byte 31 (index 31 in 1-based = o[16] bit 15).
  -- RFC 7748: the high bit of the last byte is ignored.
  o[16] = o[16] % 32768  -- clear bit 15 (the sign bit that would make it > p)
  return o
end

-- Encode a gf element into a 32-byte little-endian string.
-- Mirrors TweetNaCl's pack25519: reduce, conditionally subtract p, then serialize.
local function gf_encode(h)
  -- Work on a copy so we don't mutate the caller's value.
  local t = gf_copy(h)
  -- Three carry rounds to get into canonical [0, p) range.
  reduce(t)
  reduce(t)
  reduce(t)

  -- p in 16-limb radix-2^16: 2^255-19
  -- Limbs: [0xffed, 0xffff x14, 0x7fff]
  -- Conditionally subtract p (do it twice to handle the edge case at 2p-1).
  for _ = 1, 2 do
    local m = {0xffed,0xffff,0xffff,0xffff,0xffff,0xffff,0xffff,0xffff,
               0xffff,0xffff,0xffff,0xffff,0xffff,0xffff,0xffff,0x7fff}
    -- m = t - p, propagating borrow
    for i = 1, 16 do m[i] = t[i] - m[i] end
    for i = 1, 15 do
      -- If m[i] is negative, borrow from next limb.
      -- borrow = floor(m[i] / 65536): 0 if non-negative, -1 if negative.
      local b = floor(m[i] / 65536)
      m[i+1] = m[i+1] + b
      m[i]   = m[i] - b * 65536
    end
    -- If after propagation m[16] >= 0, then t >= p and we should use m (= t - p).
    -- If m[16] < 0, then t < p and we keep t.
    -- b16 = 0 means t >= p; b16 < 0 means t < p.
    local b16 = floor(m[16] / 65536)  -- 0 or -1
    -- mask: if b16 == 0 (t >= p): replace t with m; if b16 == -1: keep t.
    -- (b16 + 1) = 1 when t >= p, 0 when t < p
    local use_m = b16 + 1  -- 1 if we should subtract, 0 if not
    m[16] = m[16] % 65536
    for i = 1, 16 do
      t[i] = t[i] + use_m * (m[i] - t[i])
    end
  end

  -- Serialize: each limb is 16 bits, two bytes little-endian.
  local bytes = {}
  for i = 1, 16 do
    local v = t[i] % 65536
    bytes[2*i - 1] = v % 256
    bytes[2*i]     = floor(v / 256)
  end
  return schar(unpack(bytes))
end

-- ---------------------------------------------------------------------------
-- X25519 Montgomery ladder (RFC 7748 §5)
-- ---------------------------------------------------------------------------

-- a24 = (486662 - 2) / 4 = 121665
local A24 = {121665,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}

-- scalarmult: compute X25519(k_bytes, u_bytes) where both are 32-byte strings.
-- k_bytes: scalar (will be clamped by caller)
-- u_bytes: u-coordinate of the input point
local function scalarmult(k_bytes, u_bytes)
  -- Decode scalar into 256 bits (byte array, for bit extraction)
  local k = {}
  for i = 1, 32 do k[i] = sbyte(k_bytes, i) end

  -- Decode u-coordinate
  local x1 = gf_decode(u_bytes)

  -- Initialize ladder state
  local x2 = {1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}  -- x_2 = 1
  local z2 = gf_new()                              -- z_2 = 0
  local x3 = gf_copy(x1)                          -- x_3 = u
  local z3 = {1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}   -- z_3 = 1

  local swap = 0

  -- Montgomery ladder: iterate bits 254 down to 0
  for t = 254, 0, -1 do
    -- Extract bit t of scalar k (bytes are little-endian)
    local byte_idx = floor(t / 8) + 1
    local bit_idx  = t % 8
    local k_t = floor(k[byte_idx] / (2^bit_idx)) % 2

    swap = (swap + k_t) % 2  -- XOR for single bits: swap ^= k_t
    cswap(swap, x2, x3)
    cswap(swap, z2, z3)
    swap = k_t

    local A  = gf_add(x2, z2)
    local AA = gf_sq(A)
    local B  = gf_sub(x2, z2)
    local BB = gf_sq(B)
    local E  = gf_sub(AA, BB)
    local C  = gf_add(x3, z3)
    local D  = gf_sub(x3, z3)
    local DA = gf_mul(D, A)
    local CB = gf_mul(C, B)

    local DA_plus_CB  = gf_add(DA, CB)
    local DA_minus_CB = gf_sub(DA, CB)

    x3 = gf_sq(DA_plus_CB)
    z3 = gf_mul(x1, gf_sq(DA_minus_CB))
    x2 = gf_mul(AA, BB)
    z2 = gf_mul(E, gf_add(AA, gf_mul(A24, E)))
  end

  -- Final conditional swap
  cswap(swap, x2, x3)
  cswap(swap, z2, z3)

  -- Return x2 * z2^(p-2) mod p
  local result = gf_mul(x2, gf_inv(z2))
  return gf_encode(result)
end

-- ---------------------------------------------------------------------------
-- Low-order point check
-- The all-zero output indicates a low-order input point (small subgroup).
-- ---------------------------------------------------------------------------

local function is_all_zero(s)
  for i = 1, 32 do
    if sbyte(s, i) ~= 0 then return false end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Base point: u = 9 as 32-byte little-endian
local BASE_POINT = schar(9) .. string.rep("\0", 31)

-- Clamp a 32-byte private key per RFC 7748 §5.
--: string -> string
M.clamp = function(key)
  local b = {sbyte(key, 1, 32)} --[[: any]]
  b[1]  = b[1]  % 256 - b[1]  % 8       -- clear low 3 bits: b[1] &= 248
  b[32] = b[32] % 128                    -- clear high bit: b[32] &= 127
  b[32] = b[32] + (b[32] % 64 == b[32] and 64 or 0)  -- set bit 6: b[32] |= 64
  return schar(unpack(b))
end

-- Generate a 32-byte public key from a 32-byte private key.
-- The private key will be clamped internally.
--: string -> (string | nil, string)
M.public_key = function(private_key)
  if type(private_key) ~= "string" or #private_key ~= 32 then
    return nil, "private_key must be a 32-byte string"
  end
  local clamped = M.clamp(private_key)
  return scalarmult(clamped, BASE_POINT)
end

-- X25519 Diffie-Hellman shared secret computation.
-- private_key: 32-byte scalar (will be clamped)
-- public_key:  32-byte u-coordinate of the remote party's public key
-- Returns: 32-byte shared secret, or nil + errmsg on failure.
--: (string, string) -> (string | nil, string)
M.diffie_hellman = function(private_key, public_key)
  if type(private_key) ~= "string" or #private_key ~= 32 then
    return nil, "private_key must be a 32-byte string"
  end
  if type(public_key) ~= "string" or #public_key ~= 32 then
    return nil, "public_key must be a 32-byte string"
  end
  local clamped = M.clamp(private_key)
  local shared  = scalarmult(clamped, public_key)
  if is_all_zero(shared) then
    return nil, "low-order point: shared secret is all zeros"
  end
  return shared
end

-- Generate a keypair.
-- seed: required 32-byte string
-- Returns: private_key(32 bytes), public_key(32 bytes)
--: string -> (string, string)
M.keypair = function(seed)
  if not seed then error("curve25519.keypair: seed is required (32-byte string)") end
  if type(seed) ~= "string" or #seed ~= 32 then
    error("seed must be a 32-byte string")
  end
  local priv = M.clamp(seed)
  local pub  = scalarmult(priv, BASE_POINT)
  return priv, pub
end

return M
