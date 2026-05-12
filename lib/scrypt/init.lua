-- lib/scrypt/init.lua
-- scrypt password-based key derivation function (RFC 7914).
--
-- Public API:
--   M.derive(password, salt, N, r, p, dklen)     -> binary_string | nil, errmsg
--   M.derive_hex(password, salt, N, r, p, dklen) -> hex_string    | nil, errmsg
--   M.verify(password, salt, N, r, p, derived_key, opts) -> boolean | nil, errmsg
--   M._tier = "pure"
--
-- Parameters:
--   N:     CPU/memory cost (must be a power of 2, >= 2)
--   r:     block size factor (>= 1)
--   p:     parallelization factor (>= 1)
--   dklen: derived key length in bytes (default 32)

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local pbkdf2 = require("lib.pbkdf2")

local M = {}
M._tier = "pure"

-- ─── helpers ────────────────────────────────────────────────────────────────

local band  = bit.band
local bxor  = bit.bxor
local bor   = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift

local function rotl32(v, n)
  return bor(lshift(v, n), rshift(v, 32 - n))
end

-- Convert binary string to lowercase hex.
--: (string) -> string
local function to_hex(s)
  local t = {}
  for i = 1, #s do
    t[i] = string.format("%02x", (string.byte(s, i) or 0))
  end
  return table.concat(t)
end

-- Convert hex string to binary string.
local function from_hex(h)
  return (h:gsub("..", function(b) return string.char(tonumber(b, 16)) end))
end

-- ─── Salsa20/8 core ─────────────────────────────────────────────────────────
-- Operates on a flat Lua array of 16 uint32 words (indices 1..16).
-- The quarter-round definition follows RFC 7914 §3 (Salsa20 column/row order).

local function salsa20_8(x)
  -- Copy input.
  local x0,  x1,  x2,  x3  = x[1],  x[2],  x[3],  x[4]
  local x4,  x5,  x6,  x7  = x[5],  x[6],  x[7],  x[8]
  local x8,  x9,  x10, x11 = x[9],  x[10], x[11], x[12]
  local x12, x13, x14, x15 = x[13], x[14], x[15], x[16]

  -- 4 double-rounds (= 8 rounds total).
  for _ = 1, 4 do
    -- Column quarter-rounds (RFC 7914 §3 Salsa20 definition):
    -- QR(a,b,c,d): b^=rotl(a+d,7); c^=rotl(b+a,9); d^=rotl(c+b,13); a^=rotl(d+c,18)
    -- Column 0: (x0, x4, x8, x12)
    x4  = bxor(x4,  rotl32(band(x0  + x12, 0xFFFFFFFF), 7))
    x8  = bxor(x8,  rotl32(band(x4  + x0,  0xFFFFFFFF), 9))
    x12 = bxor(x12, rotl32(band(x8  + x4,  0xFFFFFFFF), 13))
    x0  = bxor(x0,  rotl32(band(x12 + x8,  0xFFFFFFFF), 18))
    -- Column 1: (x5, x9, x13, x1)
    x9  = bxor(x9,  rotl32(band(x5  + x1,  0xFFFFFFFF), 7))
    x13 = bxor(x13, rotl32(band(x9  + x5,  0xFFFFFFFF), 9))
    x1  = bxor(x1,  rotl32(band(x13 + x9,  0xFFFFFFFF), 13))
    x5  = bxor(x5,  rotl32(band(x1  + x13, 0xFFFFFFFF), 18))
    -- Column 2: (x10, x14, x2, x6)
    x14 = bxor(x14, rotl32(band(x10 + x6,  0xFFFFFFFF), 7))
    x2  = bxor(x2,  rotl32(band(x14 + x10, 0xFFFFFFFF), 9))
    x6  = bxor(x6,  rotl32(band(x2  + x14, 0xFFFFFFFF), 13))
    x10 = bxor(x10, rotl32(band(x6  + x2,  0xFFFFFFFF), 18))
    -- Column 3: (x15, x3, x7, x11)
    x3  = bxor(x3,  rotl32(band(x15 + x11, 0xFFFFFFFF), 7))
    x7  = bxor(x7,  rotl32(band(x3  + x15, 0xFFFFFFFF), 9))
    x11 = bxor(x11, rotl32(band(x7  + x3,  0xFFFFFFFF), 13))
    x15 = bxor(x15, rotl32(band(x11 + x7,  0xFFFFFFFF), 18))

    -- Row quarter-rounds:
    -- Row 0: (x0, x1, x2, x3)
    x1  = bxor(x1,  rotl32(band(x0  + x3,  0xFFFFFFFF), 7))
    x2  = bxor(x2,  rotl32(band(x1  + x0,  0xFFFFFFFF), 9))
    x3  = bxor(x3,  rotl32(band(x2  + x1,  0xFFFFFFFF), 13))
    x0  = bxor(x0,  rotl32(band(x3  + x2,  0xFFFFFFFF), 18))
    -- Row 1: (x5, x6, x7, x4)
    x6  = bxor(x6,  rotl32(band(x5  + x4,  0xFFFFFFFF), 7))
    x7  = bxor(x7,  rotl32(band(x6  + x5,  0xFFFFFFFF), 9))
    x4  = bxor(x4,  rotl32(band(x7  + x6,  0xFFFFFFFF), 13))
    x5  = bxor(x5,  rotl32(band(x4  + x7,  0xFFFFFFFF), 18))
    -- Row 2: (x10, x11, x8, x9)
    x11 = bxor(x11, rotl32(band(x10 + x9,  0xFFFFFFFF), 7))
    x8  = bxor(x8,  rotl32(band(x11 + x10, 0xFFFFFFFF), 9))
    x9  = bxor(x9,  rotl32(band(x8  + x11, 0xFFFFFFFF), 13))
    x10 = bxor(x10, rotl32(band(x9  + x8,  0xFFFFFFFF), 18))
    -- Row 3: (x15, x12, x13, x14)
    x12 = bxor(x12, rotl32(band(x15 + x14, 0xFFFFFFFF), 7))
    x13 = bxor(x13, rotl32(band(x12 + x15, 0xFFFFFFFF), 9))
    x14 = bxor(x14, rotl32(band(x13 + x12, 0xFFFFFFFF), 13))
    x15 = bxor(x15, rotl32(band(x14 + x13, 0xFFFFFFFF), 18))
  end

  -- Add original input back (mod 2^32).
  x[1]  = band(x[1]  + x0,  0xFFFFFFFF)
  x[2]  = band(x[2]  + x1,  0xFFFFFFFF)
  x[3]  = band(x[3]  + x2,  0xFFFFFFFF)
  x[4]  = band(x[4]  + x3,  0xFFFFFFFF)
  x[5]  = band(x[5]  + x4,  0xFFFFFFFF)
  x[6]  = band(x[6]  + x5,  0xFFFFFFFF)
  x[7]  = band(x[7]  + x6,  0xFFFFFFFF)
  x[8]  = band(x[8]  + x7,  0xFFFFFFFF)
  x[9]  = band(x[9]  + x8,  0xFFFFFFFF)
  x[10] = band(x[10] + x9,  0xFFFFFFFF)
  x[11] = band(x[11] + x10, 0xFFFFFFFF)
  x[12] = band(x[12] + x11, 0xFFFFFFFF)
  x[13] = band(x[13] + x12, 0xFFFFFFFF)
  x[14] = band(x[14] + x13, 0xFFFFFFFF)
  x[15] = band(x[15] + x14, 0xFFFFFFFF)
  x[16] = band(x[16] + x15, 0xFFFFFFFF)
end

-- ─── Block encoding helpers ──────────────────────────────────────────────────
-- We represent blocks as flat Lua arrays of uint32 words.
-- One 64-byte block = 16 words.  A 2r-block sequence = 2r*16 words.

-- Decode a binary string of length 4*n into an array of n uint32 (LE).
--: (s: string, offset: integer, count: integer) -> { [integer]: integer }
local function decode_words(s, offset, count)
  -- offset: 1-based byte offset into s
  -- count: number of 32-bit words to decode
  local w = {}
  local p = offset
  for i = 1, count do
    local b0, b1, b2, b3 = string.byte(s, p, p + 3)
    local i0 = b0 or 0 --[[:! integer]]
    local i1 = b1 or 0 --[[:! integer]]
    local i2 = b2 or 0 --[[:! integer]]
    local i3 = b3 or 0 --[[:! integer]]
    w[i] = bor(i0, lshift(i1, 8), lshift(i2, 16), lshift(i3, 24))
    p = p + 4
  end
  return w
end

-- Encode an array of uint32 words into a binary string (LE).
local function encode_words(w, n)
  local t = {}
  for i = 1, n do
    local v = w[i]
    t[#t+1] = string.char(
      band(v, 0xFF),
      band(rshift(v, 8),  0xFF),
      band(rshift(v, 16), 0xFF),
      band(rshift(v, 24), 0xFF)
    )
  end
  return table.concat(t)
end

-- ─── scryptBlockMix ──────────────────────────────────────────────────────────
-- B_words: flat array of 2r*16 uint32 words (modified in place conceptually,
--          but we return a new array to keep things clear).
-- r:       block-size factor.
-- Returns: new flat array of 2r*16 uint32 words.

local function block_mix(B, r)
  local two_r = 2 * r
  local block_words = 16  -- one 64-byte block = 16 words

  -- X = last 64-byte block of B.
  local X = {}
  local last_start = (two_r - 1) * block_words
  for i = 1, block_words do
    X[i] = B[last_start + i]
  end

  local Y = {}  -- will hold 2r blocks in sequential order

  for i = 0, two_r - 1 do
    local base = i * block_words
    -- T = X XOR B[i]
    for j = 1, block_words do
      X[j] = bxor(X[j], B[base + j])
    end
    -- X = Salsa20/8(T)
    salsa20_8(X)
    -- Store Y[i] = X  (copy the 16 words)
    local y_base = i * block_words
    for j = 1, block_words do
      Y[y_base + j] = X[j]
    end
  end

  -- Reorder: output = Y[0], Y[2], ..., Y[2r-2], Y[1], Y[3], ..., Y[2r-1]
  local out = {}
  local out_idx = 1
  -- Even-indexed blocks first.
  for i = 0, two_r - 1, 2 do
    local y_base = i * block_words
    for j = 1, block_words do
      out[out_idx] = Y[y_base + j]
      out_idx = out_idx + 1
    end
  end
  -- Odd-indexed blocks.
  for i = 1, two_r - 1, 2 do
    local y_base = i * block_words
    for j = 1, block_words do
      out[out_idx] = Y[y_base + j]
      out_idx = out_idx + 1
    end
  end
  return out
end

-- ─── scryptROMix ─────────────────────────────────────────────────────────────
-- B_str: binary string of 128*r bytes.
-- N:     CPU/memory cost parameter.
-- r:     block-size factor.
-- Returns: binary string of 128*r bytes.

local function romix(B_str, N, r)
  local block_count = 2 * r  -- number of 64-byte blocks in B
  local word_count  = block_count * 16  -- total uint32 words

  -- Decode B into a word array X.
  local X = decode_words(B_str, 1, word_count)

  -- V[0..N-1]: store word arrays.
  local V = {}
  V[1] = X  -- V[0] (1-indexed here) = initial X

  -- Fill V: V[i] = scryptBlockMix(V[i-1])
  for i = 1, N - 1 do
    local prev = V[i]
    V[i + 1] = block_mix(prev, r)
  end

  -- X = scryptBlockMix(V[N-1])
  X = block_mix(V[N], r)

  -- Mixing loop.
  for _ = 1, N do
    -- j = Integerify(X) mod N
    -- Integerify = LE uint64 from the first 8 bytes of the last 64-byte block.
    -- Last 64-byte block starts at word index (2r-1)*16+1 (1-based).
    local last_block_start = (block_count - 1) * 16
    local lo = X[last_block_start + 1]  -- first word of last block
    -- hi = X[last_block_start + 2]    -- second word (high 32 bits)
    -- For N < 2^32, only lo is needed (N is a power of 2 ≤ 2^32).
    local j = band(lo, N - 1) + 1  -- 1-based index into V

    -- X = scryptBlockMix(X XOR V[j])
    local Vj = V[j]
    local Xtmp = {}
    for k = 1, word_count do
      Xtmp[k] = bxor(X[k], Vj[k])
    end
    X = block_mix(Xtmp, r)
  end

  return encode_words(X, word_count)
end

-- ─── Public API ──────────────────────────────────────────────────────────────

--- Derive a key using scrypt (RFC 7914).
-- password: string
-- salt:     string
-- N:        CPU/memory cost (power of 2, >= 2)
-- r:        block size factor (>= 1)
-- p:        parallelization factor (>= 1)
-- dklen:    derived key length in bytes (default 32)
-- Returns: binary_string or nil, errmsg
function M.derive(password, salt, N, r, p, dklen)
  if type(password) ~= "string" then
    return nil, "scrypt: password must be a string"
  end
  if type(salt) ~= "string" then
    return nil, "scrypt: salt must be a string"
  end
  if type(N) ~= "number" or N < 2 or math.floor(N) ~= N then
    return nil, "scrypt: N must be an integer >= 2"
  end
  local N_ = math.floor(N)
  if band(N_, N_ - 1) ~= 0 then
    return nil, "scrypt: N must be a power of 2"
  end
  if type(r) ~= "number" or r < 1 or math.floor(r) ~= r then
    return nil, "scrypt: r must be a positive integer"
  end
  if type(p) ~= "number" or p < 1 or math.floor(p) ~= p then
    return nil, "scrypt: p must be a positive integer"
  end
  dklen = dklen or 32
  if type(dklen) ~= "number" or dklen < 1 or math.floor(dklen) ~= dklen then
    return nil, "scrypt: dklen must be a positive integer"
  end

  local block_size = 128 * r

  -- Step 1: B = PBKDF2-HMAC-SHA256(P, S, 1, p * 128 * r)
  local B, err = pbkdf2.derive(password, salt, 1, p * block_size, { alg = nil })
  if not B then return nil, "scrypt: pbkdf2 (step 1) failed: " .. (err or "") end

  -- Step 2: For each block, run scryptROMix.
  local blocks = {}
  for i = 0, p - 1 do
    local chunk = B:sub(i * block_size + 1, (i + 1) * block_size)
    blocks[i + 1] = romix(chunk, N, r)
  end
  B = table.concat(blocks)

  -- Step 3: DK = PBKDF2-HMAC-SHA256(P, B, 1, dkLen)
  local dk, err2 = pbkdf2.derive(password, B --[[:! string]], 1, dklen, { alg = nil })
  if not dk then return nil, "scrypt: pbkdf2 (step 3) failed: " .. (err2 or "") end

  return dk
end

--- Derive and return a lowercase hex string.
function M.derive_hex(password, salt, N, r, p, dklen)
  local dk, err = M.derive(password, salt, N, r, p, dklen)
  if not dk then return nil, err end
  return to_hex(dk)
end

--- Timing-safe verify.
-- opts: { hex = true } if derived_key is a hex string.
function M.verify(password, salt, N, r, p, derived_key, opts)
  local stored
  if opts and opts.hex then
    stored = from_hex(derived_key)
  else
    stored = derived_key
  end
  local dklen = #stored
  local candidate, err = M.derive(password, salt, N, r, p, dklen)
  if not candidate then return nil, err end
  if #candidate ~= dklen then return false end
  local candidate_ = candidate --[[:! string]]
  local stored_ = stored --[[:! string]]
  local diff = 0
  for i = 1, dklen do
    diff = bor(diff, bxor(
      (string.byte(candidate_, i) or 0),
      (string.byte(stored_, i) or 0)))
  end
  return diff == 0
end

return M
