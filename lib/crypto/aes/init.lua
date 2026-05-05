-- lib/crypto/aes/init.lua
-- AES block cipher: AES-128/192/256, ECB, CBC, CTR modes.
-- Pure Lua implementation verified against NIST FIPS 197 test vectors.
--
-- Public API:
--   M.encrypt_block(key, block)          -> string (16 bytes)
--   M.decrypt_block(key, block)          -> string (16 bytes)
--   M.ecb_encrypt(key, plaintext)        -> string
--   M.ecb_decrypt(key, ciphertext)       -> string
--   M.cbc_encrypt(key, plaintext, iv)    -> ciphertext, iv
--   M.cbc_decrypt(key, ciphertext, iv)   -> string | (nil, errmsg)
--   M.ctr_encrypt(key, plaintext, nonce) -> string
--   M.ctr_decrypt(key, ciphertext, nonce)-> string
--   M.pad(data, block_size)              -> string
--   M.unpad(data)                        -> string | (nil, errmsg)
--   M._tier                              -> "pure"

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local bxor  = bit.bxor
local band  = bit.band
local bor   = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift
local byte  = string.byte
local char  = string.char

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- AES S-box and inverse S-box (standard FIPS 197 values)
-- ---------------------------------------------------------------------------

local S = {
  0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
  0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
  0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
  0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
  0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
  0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
  0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
  0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
  0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
  0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
  0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
  0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
  0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
  0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
  0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
  0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
}

local Si = {
  0x52,0x09,0x6a,0xd5,0x30,0x36,0xa5,0x38,0xbf,0x40,0xa3,0x9e,0x81,0xf3,0xd7,0xfb,
  0x7c,0xe3,0x39,0x82,0x9b,0x2f,0xff,0x87,0x34,0x8e,0x43,0x44,0xc4,0xde,0xe9,0xcb,
  0x54,0x7b,0x94,0x32,0xa6,0xc2,0x23,0x3d,0xee,0x4c,0x95,0x0b,0x42,0xfa,0xc3,0x4e,
  0x08,0x2e,0xa1,0x66,0x28,0xd9,0x24,0xb2,0x76,0x5b,0xa2,0x49,0x6d,0x8b,0xd1,0x25,
  0x72,0xf8,0xf6,0x64,0x86,0x68,0x98,0x16,0xd4,0xa4,0x5c,0xcc,0x5d,0x65,0xb6,0x92,
  0x6c,0x70,0x48,0x50,0xfd,0xed,0xb9,0xda,0x5e,0x15,0x46,0x57,0xa7,0x8d,0x9d,0x84,
  0x90,0xd8,0xab,0x00,0x8c,0xbc,0xd3,0x0a,0xf7,0xe4,0x58,0x05,0xb8,0xb3,0x45,0x06,
  0xd0,0x2c,0x1e,0x8f,0xca,0x3f,0x0f,0x02,0xc1,0xaf,0xbd,0x03,0x01,0x13,0x8a,0x6b,
  0x3a,0x91,0x11,0x41,0x4f,0x67,0xdc,0xea,0x97,0xf2,0xcf,0xce,0xf0,0xb4,0xe6,0x73,
  0x96,0xac,0x74,0x22,0xe7,0xad,0x35,0x85,0xe2,0xf9,0x37,0xe8,0x1c,0x75,0xdf,0x6e,
  0x47,0xf1,0x1a,0x71,0x1d,0x29,0xc5,0x89,0x6f,0xb7,0x62,0x0e,0xaa,0x18,0xbe,0x1b,
  0xfc,0x56,0x3e,0x4b,0xc6,0xd2,0x79,0x20,0x9a,0xdb,0xc0,0xfe,0x78,0xcd,0x5a,0xf4,
  0x1f,0xdd,0xa8,0x33,0x88,0x07,0xc7,0x31,0xb1,0x12,0x10,0x59,0x27,0x80,0xec,0x5f,
  0x60,0x51,0x7f,0xa9,0x19,0xb5,0x4a,0x0d,0x2d,0xe5,0x7a,0x9f,0x93,0xc9,0x9c,0xef,
  0xa0,0xe0,0x3b,0x4d,0xae,0x2a,0xf5,0xb0,0xc8,0xeb,0xbb,0x3c,0x83,0x53,0x99,0x61,
  0x17,0x2b,0x04,0x7e,0xba,0x77,0xd6,0x26,0xe1,0x69,0x14,0x63,0x55,0x21,0x0c,0x7d,
}

-- S-box lookup is 1-indexed: S[x+1] for byte value x
-- Pre-shift to 0-indexed access pattern used in Lua tables (stored as 1-indexed)

-- ---------------------------------------------------------------------------
-- MixColumns multiplication tables
-- xtime(a) = a*2 in GF(2^8) with polynomial 0x11b
-- ---------------------------------------------------------------------------

local MUL2 = {}
local MUL3 = {}
local MUL9 = {}
local MUL11 = {}
local MUL13 = {}
local MUL14 = {}

local function xtime(a)
  if a >= 0x80 then
    return bxor(band(lshift(a, 1), 0xff), 0x1b)
  else
    return band(lshift(a, 1), 0xff)
  end
end

for i = 0, 255 do
  local x2 = xtime(i)
  local x4 = xtime(x2)
  local x8 = xtime(x4)
  MUL2[i] = x2
  MUL3[i] = bxor(i, x2)             -- 3*a = a XOR 2*a
  MUL9[i] = bxor(i, x8)             -- 9*a = a XOR 8*a
  MUL11[i] = bxor(bxor(i, x2), x8)  -- 11*a = a XOR 2*a XOR 8*a
  MUL13[i] = bxor(bxor(i, x4), x8)  -- 13*a = a XOR 4*a XOR 8*a
  MUL14[i] = bxor(bxor(x2, x4), x8) -- 14*a = 2*a XOR 4*a XOR 8*a
end

-- ---------------------------------------------------------------------------
-- Rcon: round constants for key schedule
-- ---------------------------------------------------------------------------

local Rcon = {
  0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36,
}

-- ---------------------------------------------------------------------------
-- Key expansion
-- Returns a flat array of round key bytes.
-- For AES-128: 11 * 16 = 176 bytes (round keys 0..10)
-- For AES-192: 13 * 16 = 208 bytes (round keys 0..12)
-- For AES-256: 15 * 16 = 240 bytes (round keys 0..14)
-- ---------------------------------------------------------------------------

local function key_expand(key)
  local key_s = key --[[:! string]]
  local klen = #key_s
  local nk   -- words in key
  local nr   -- rounds
  if klen == 16 then
    nk, nr = 4, 10
  elseif klen == 24 then
    nk, nr = 6, 12
  elseif klen == 32 then
    nk, nr = 8, 14
  else
    return nil, "key must be 16, 24, or 32 bytes"
  end

  local w = {}  -- expanded key words (each word = 4 bytes stored as 4 entries)
  -- Copy key into w as individual bytes
  for i = 1, klen do
    w[i] = byte(key_s, i)
  end

  local total_words = (nr + 1) * 4  -- 4 words per round
  local i = nk + 1  -- next word index (1-based, each word = 4 entries at (i-1)*4+1)

  -- We'll store words flat: word i occupies w[(i-1)*4+1 .. i*4]
  -- Re-represent: store as array of 4-byte groups
  local W = {}
  for wi = 1, nk do
    local base = (wi - 1) * 4 + 1
    W[wi] = { byte(key_s, base), byte(key_s, base+1), byte(key_s, base+2), byte(key_s, base+3) }
  end

  local rcon_i = 1
  for wi = nk + 1, total_words do
    local prev = W[wi - 1]
    local temp = { prev[1], prev[2], prev[3], prev[4] }
    if (wi - 1) % nk == 0 then
      -- RotWord then SubWord then XOR Rcon
      local t = temp[1]
      temp[1] = S[temp[2] + 1]
      temp[2] = S[temp[3] + 1]
      temp[3] = S[temp[4] + 1]
      temp[4] = S[t + 1]
      temp[1] = bxor(temp[1], Rcon[rcon_i])
      rcon_i = rcon_i + 1
    elseif nk > 6 and (wi - 1) % nk == 4 then
      -- AES-256 extra SubWord
      temp[1] = S[temp[1] + 1]
      temp[2] = S[temp[2] + 1]
      temp[3] = S[temp[3] + 1]
      temp[4] = S[temp[4] + 1]
    end
    local wbase = W[wi - nk]
    W[wi] = {
      bxor(wbase[1], temp[1]),
      bxor(wbase[2], temp[2]),
      bxor(wbase[3], temp[3]),
      bxor(wbase[4], temp[4]),
    }
  end

  -- Flatten W into a byte array (1-indexed)
  local rk = {}
  for wi = 1, total_words do
    local base = (wi - 1) * 4
    rk[base + 1] = W[wi][1]
    rk[base + 2] = W[wi][2]
    rk[base + 3] = W[wi][3]
    rk[base + 4] = W[wi][4]
  end

  return rk, nr
end

-- Cache expanded keys to avoid recomputing for repeated calls with same key
local key_cache = {}
local function get_round_keys(key)
  local cached = key_cache[key]
  if cached then return cached[1], cached[2] end
  local rk, nr = key_expand(key)
  if not rk then return nil, nr end
  key_cache[key] = { rk, nr }
  return rk, nr
end

-- ---------------------------------------------------------------------------
-- AddRoundKey: XOR state with round key bytes starting at offset
-- state is a 16-element array (1-indexed), rk offset is 0-based byte index
-- ---------------------------------------------------------------------------

local function add_round_key(s, rk, offset)
  local o = offset + 1  -- convert to 1-based
  s[1]  = bxor(s[1],  rk[o])
  s[2]  = bxor(s[2],  rk[o+1])
  s[3]  = bxor(s[3],  rk[o+2])
  s[4]  = bxor(s[4],  rk[o+3])
  s[5]  = bxor(s[5],  rk[o+4])
  s[6]  = bxor(s[6],  rk[o+5])
  s[7]  = bxor(s[7],  rk[o+6])
  s[8]  = bxor(s[8],  rk[o+7])
  s[9]  = bxor(s[9],  rk[o+8])
  s[10] = bxor(s[10], rk[o+9])
  s[11] = bxor(s[11], rk[o+10])
  s[12] = bxor(s[12], rk[o+11])
  s[13] = bxor(s[13], rk[o+12])
  s[14] = bxor(s[14], rk[o+13])
  s[15] = bxor(s[15], rk[o+14])
  s[16] = bxor(s[16], rk[o+15])
end

-- ---------------------------------------------------------------------------
-- SubBytes: replace each byte with S-box value
-- ---------------------------------------------------------------------------

local function sub_bytes(s)
  for i = 1, 16 do
    s[i] = S[s[i] + 1]
  end
end

-- ---------------------------------------------------------------------------
-- ShiftRows: cyclic left shift of rows
-- AES state is column-major: s[col*4 + row + 1]
-- Row 0: bytes 1,5,9,13   (shift 0)
-- Row 1: bytes 2,6,10,14  (shift 1 left)
-- Row 2: bytes 3,7,11,15  (shift 2 left)
-- Row 3: bytes 4,8,12,16  (shift 3 left)
-- ---------------------------------------------------------------------------

local function shift_rows(s)
  -- Row 1: left shift by 1
  local t = s[2]; s[2] = s[6]; s[6] = s[10]; s[10] = s[14]; s[14] = t
  -- Row 2: left shift by 2
  local t1, t2 = s[3], s[7]; s[3] = s[11]; s[7] = s[15]; s[11] = t1; s[15] = t2
  -- Row 3: left shift by 3 (= right shift by 1)
  local t = s[16]; s[16] = s[12]; s[12] = s[8]; s[8] = s[4]; s[4] = t
end

-- ---------------------------------------------------------------------------
-- MixColumns: mix each column using GF(2^8) matrix multiply
-- ---------------------------------------------------------------------------

local function mix_columns(s)
  for col = 0, 3 do
    local base = col * 4
    local a0 = s[base + 1]
    local a1 = s[base + 2]
    local a2 = s[base + 3]
    local a3 = s[base + 4]
    s[base + 1] = bxor(bxor(bxor(MUL2[a0], MUL3[a1]), a2), a3)
    s[base + 2] = bxor(bxor(bxor(a0, MUL2[a1]), MUL3[a2]), a3)
    s[base + 3] = bxor(bxor(bxor(a0, a1), MUL2[a2]), MUL3[a3])
    s[base + 4] = bxor(bxor(bxor(MUL3[a0], a1), a2), MUL2[a3])
  end
end

-- ---------------------------------------------------------------------------
-- Encrypt a single 16-byte block
-- ---------------------------------------------------------------------------

local function encrypt_block_raw(rk, nr, s)
  add_round_key(s, rk, 0)
  for round = 1, nr - 1 do
    sub_bytes(s)
    shift_rows(s)
    mix_columns(s)
    add_round_key(s, rk, round * 16)
  end
  sub_bytes(s)
  shift_rows(s)
  add_round_key(s, rk, nr * 16)
end

-- ---------------------------------------------------------------------------
-- InvShiftRows: inverse of ShiftRows (cyclic right shift)
-- ---------------------------------------------------------------------------

local function inv_shift_rows(s)
  -- Row 1: right shift by 1
  local t = s[14]; s[14] = s[10]; s[10] = s[6]; s[6] = s[2]; s[2] = t
  -- Row 2: right shift by 2
  local t1, t2 = s[3], s[7]; s[3] = s[11]; s[7] = s[15]; s[11] = t1; s[15] = t2
  -- Row 3: right shift by 3 (= left shift by 1)
  local t = s[4]; s[4] = s[8]; s[8] = s[12]; s[12] = s[16]; s[16] = t
end

-- ---------------------------------------------------------------------------
-- InvSubBytes
-- ---------------------------------------------------------------------------

local function inv_sub_bytes(s)
  for i = 1, 16 do
    s[i] = Si[s[i] + 1]
  end
end

-- ---------------------------------------------------------------------------
-- InvMixColumns
-- ---------------------------------------------------------------------------

local function inv_mix_columns(s)
  for col = 0, 3 do
    local base = col * 4
    local a0 = s[base + 1]
    local a1 = s[base + 2]
    local a2 = s[base + 3]
    local a3 = s[base + 4]
    s[base + 1] = bxor(bxor(bxor(MUL14[a0], MUL11[a1]), MUL13[a2]), MUL9[a3])
    s[base + 2] = bxor(bxor(bxor(MUL9[a0],  MUL14[a1]), MUL11[a2]), MUL13[a3])
    s[base + 3] = bxor(bxor(bxor(MUL13[a0], MUL9[a1]),  MUL14[a2]), MUL11[a3])
    s[base + 4] = bxor(bxor(bxor(MUL11[a0], MUL13[a1]), MUL9[a2]),  MUL14[a3])
  end
end

-- ---------------------------------------------------------------------------
-- Decrypt a single 16-byte block
-- ---------------------------------------------------------------------------

local function decrypt_block_raw(rk, nr, s)
  add_round_key(s, rk, nr * 16)
  for round = nr - 1, 1, -1 do
    inv_shift_rows(s)
    inv_sub_bytes(s)
    add_round_key(s, rk, round * 16)
    inv_mix_columns(s)
  end
  inv_shift_rows(s)
  inv_sub_bytes(s)
  add_round_key(s, rk, 0)
end

-- ---------------------------------------------------------------------------
-- Public: string-based single block encrypt/decrypt
-- ---------------------------------------------------------------------------

function M.encrypt_block(key, block)
  if #key ~= 16 and #key ~= 24 and #key ~= 32 then
    return nil, "key must be 16, 24, or 32 bytes"
  end
  if #block ~= 16 then
    return nil, "block must be 16 bytes"
  end
  local rk, nr = get_round_keys(key)
  if not rk then return nil, nr end
  local block_s = block --[[:! string]]
  local s = { byte(block_s, 1, 16) }
  encrypt_block_raw(rk, nr, s)
  return char(unpack(s))
end

function M.decrypt_block(key, block)
  if #key ~= 16 and #key ~= 24 and #key ~= 32 then
    return nil, "key must be 16, 24, or 32 bytes"
  end
  if #block ~= 16 then
    return nil, "block must be 16 bytes"
  end
  local rk, nr = get_round_keys(key)
  if not rk then return nil, nr end
  local block_s = block --[[:! string]]
  local s = { byte(block_s, 1, 16) }
  decrypt_block_raw(rk, nr, s)
  return char(unpack(s))
end

-- ---------------------------------------------------------------------------
-- PKCS#7 padding
-- ---------------------------------------------------------------------------

function M.pad(data, block_size)
  block_size = block_size or 16
  local pad_len = block_size - (#data % block_size)
  return data .. char(pad_len):rep(pad_len)
end

function M.unpad(data)
  local data_s = data --[[:! string]]
  if #data_s == 0 then
    return nil, "empty data"
  end
  local pad_len = byte(data_s, #data_s) or 0
  if pad_len == 0 or pad_len > 16 then
    return nil, "invalid PKCS#7 padding byte: " .. pad_len
  end
  if #data_s < pad_len then
    return nil, "data shorter than padding length"
  end
  -- Validate all padding bytes
  for i = #data_s - pad_len + 1, #data_s do
    if byte(data_s, i) ~= pad_len then
      return nil, "invalid PKCS#7 padding"
    end
  end
  return data_s:sub(1, #data_s - pad_len)
end

-- ---------------------------------------------------------------------------
-- ECB mode
-- ---------------------------------------------------------------------------

function M.ecb_encrypt(key, plaintext)
  local pt = plaintext --[[:! string]]
  if #pt % 16 ~= 0 then
    return nil, "plaintext length must be a multiple of 16 bytes"
  end
  local rk, nr = get_round_keys(key)
  if not rk then return nil, nr end
  local out = {}
  for i = 1, #pt, 16 do
    local s = { byte(pt, i, i + 15) }
    encrypt_block_raw(rk, nr, s)
    out[#out + 1] = char(unpack(s))
  end
  return table.concat(out)
end

function M.ecb_decrypt(key, ciphertext)
  local ct = ciphertext --[[:! string]]
  if #ct % 16 ~= 0 then
    return nil, "ciphertext length must be a multiple of 16 bytes"
  end
  local rk, nr = get_round_keys(key)
  if not rk then return nil, nr end
  local out = {}
  for i = 1, #ct, 16 do
    local s = { byte(ct, i, i + 15) }
    decrypt_block_raw(rk, nr, s)
    out[#out + 1] = char(unpack(s))
  end
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- CBC mode
-- CBC encrypt adds PKCS#7 padding automatically.
-- CBC decrypt removes PKCS#7 padding and validates it.
-- iv defaults to 16 zero bytes if not provided.
-- Returns ciphertext, used_iv on encrypt.
-- ---------------------------------------------------------------------------

function M.cbc_encrypt(key, plaintext, iv)
  local rk, nr = get_round_keys(key)
  if not rk then return nil, nr end
  iv = iv or ("\0"):rep(16)
  if #iv ~= 16 then
    return nil, "iv must be 16 bytes"
  end
  -- Apply PKCS#7 padding
  local padded = M.pad(plaintext, 16)
  local padded_s = padded --[[:! string]]
  local iv_s = iv --[[:! string]]
  local out = {}
  local prev = { byte(iv_s, 1, 16) }
  for i = 1, #padded_s, 16 do
    local s = { byte(padded_s, i, i + 15) }
    -- XOR with previous ciphertext block (or IV for first block)
    for j = 1, 16 do
      s[j] = bxor(s[j], prev[j])
    end
    encrypt_block_raw(rk, nr, s)
    out[#out + 1] = char(unpack(s))
    prev = s
  end
  return table.concat(out), iv
end

function M.cbc_decrypt(key, ciphertext, iv)
  local ct_s = ciphertext --[[:! string]]
  if #ct_s % 16 ~= 0 then
    return nil, "ciphertext length must be a multiple of 16 bytes"
  end
  local rk, nr = get_round_keys(key)
  if not rk then return nil, nr end
  iv = iv or ("\0"):rep(16)
  if #iv ~= 16 then
    return nil, "iv must be 16 bytes"
  end
  local iv_s = iv --[[:! string]]
  local out = {}
  local prev = { byte(iv_s, 1, 16) }
  for i = 1, #ct_s, 16 do
    local ct_block = { byte(ct_s, i, i + 15) }
    local s = { unpack(ct_block) }  -- copy for decrypt
    decrypt_block_raw(rk, nr, s)
    -- XOR with previous ciphertext block (or IV)
    for j = 1, 16 do
      s[j] = bxor(s[j], prev[j])
    end
    out[#out + 1] = char(unpack(s))
    prev = ct_block
  end
  local plaintext = table.concat(out)
  return M.unpad(plaintext)
end

-- ---------------------------------------------------------------------------
-- CTR mode
-- nonce: 16 bytes (treated as 128-bit big-endian counter, incremented per block)
-- Encrypt and decrypt are the same operation (XOR keystream).
-- ---------------------------------------------------------------------------

-- Increment a 16-byte counter (big-endian) stored as array of bytes
local function increment_counter(ctr)
  for i = 16, 1, -1 do
    ctr[i] = ctr[i] + 1
    if ctr[i] <= 255 then break end
    ctr[i] = 0
  end
end

local function ctr_crypt(key, data, nonce)
  local rk, nr = get_round_keys(key)
  if not rk then return nil, nr end
  if #nonce ~= 16 then
    return nil, "nonce must be 16 bytes"
  end
  local ctr = { byte(nonce, 1, 16) }
  local out = {}
  local dlen = #data
  local i = 1
  while i <= dlen do
    -- Encrypt counter block to get keystream block
    local ks = { unpack(ctr) }
    encrypt_block_raw(rk, nr, ks)
    -- XOR with plaintext/ciphertext bytes
    local block_end = math.min(i + 15, dlen)
    local block_bytes = {}
    for j = 1, block_end - i + 1 do
      block_bytes[j] = char(bxor(byte(data, i + j - 1), ks[j]))
    end
    out[#out + 1] = table.concat(block_bytes)
    increment_counter(ctr)
    i = i + 16
  end
  return table.concat(out)
end

function M.ctr_encrypt(key, plaintext, nonce)
  return ctr_crypt(key, plaintext, nonce)
end

function M.ctr_decrypt(key, ciphertext, nonce)
  return ctr_crypt(key, ciphertext, nonce)
end

return M
