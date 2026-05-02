if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local band, bxor, rshift, lshift = bit.band, bit.bxor, bit.rshift, bit.lshift

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Normalise a signed 32-bit LuaJIT integer to an unsigned Lua double.
local function u32(n)
  if n < 0 then return n + 4294967296 end
  return n
end

-- Build a 256-entry reflected (LSB-first) CRC-32 lookup table.
local function make_table(poly_reflected)
  local t = {}
  for i = 0, 255 do
    local crc = i
    for _ = 1, 8 do
      if band(crc, 1) ~= 0 then
        crc = bxor(rshift(crc, 1), poly_reflected)
      else
        crc = rshift(crc, 1)
      end
    end
    t[i] = crc
  end
  return t
end

-- ---------------------------------------------------------------------------
-- Precomputed lookup tables
-- ---------------------------------------------------------------------------

-- CRC-32/ISO-HDLC (IEEE 802.3, zlib, gzip, Ethernet): reflected poly 0xEDB88320
local IEEE_TABLE = make_table(0xEDB88320)

-- CRC-32C/Castagnoli (iSCSI, Btrfs, SCTP, SSE4.2): reflected poly 0x82F63B78
local CASTAGNOLI_TABLE = make_table(0x82F63B78)

-- CRC-32/Koopman: reflected poly 0xEB31D82E (reflection of 0x741B8CD7)
local KOOPMAN_TABLE = make_table(0xEB31D82E)

-- ---------------------------------------------------------------------------
-- Core computation
-- ---------------------------------------------------------------------------

--: ({ [integer]: integer }, string, number | nil) -> number
local function compute_with_table(tbl, data, init_crc)
  -- init_crc is a previous CRC result (unsigned double); bit.tobit converts
  -- to the signed 32-bit domain that the bit library requires.
  local crc = bxor(bit.tobit(init_crc or 0), 0xFFFFFFFF)
  for i = 1, #data do
    local byte = string.byte(data, i)
    local idx = band(bxor(crc, byte), 0xFF)
    crc = bxor(rshift(crc, 8), tbl[idx])
  end
  return u32(bxor(crc, 0xFFFFFFFF))
end

-- ---------------------------------------------------------------------------
-- Public API — IEEE (standard CRC-32)
-- ---------------------------------------------------------------------------

--- Standard CRC-32 (IEEE 802.3, zlib, gzip, PNG).
--- @param data string
--- @param prev_crc number|nil  previous CRC for incremental/streaming use
--- @return number  unsigned 32-bit CRC as a Lua double (0–4294967295)
function M.compute(data, prev_crc)
  return compute_with_table(IEEE_TABLE, data, prev_crc)
end

--- 8-character lowercase hex string of the CRC-32.
function M.hex(data)
  local crc_ = M.compute(data) --[[:! integer]]
  return string.format("%08x", crc_)
end

-- ---------------------------------------------------------------------------
-- Public API — Castagnoli (CRC-32C)
-- ---------------------------------------------------------------------------

--- CRC-32C (Castagnoli) — used by iSCSI, SCTP, Btrfs, SSE4.2.
--- @param data string
--- @param prev_crc number|nil
--- @return number  unsigned 32-bit CRC
function M.castagnoli(data, prev_crc)
  return compute_with_table(CASTAGNOLI_TABLE, data, prev_crc)
end

--- 8-character lowercase hex string of the CRC-32C.
function M.castagnoli_hex(data)
  local crc_ = M.castagnoli(data) --[[:! integer]]
  return string.format("%08x", crc_)
end

-- ---------------------------------------------------------------------------
-- Public API — Koopman
-- ---------------------------------------------------------------------------

--- CRC-32/Koopman.
--- @param data string
--- @param prev_crc number|nil
--- @return number  unsigned 32-bit CRC
function M.koopman(data, prev_crc)
  return compute_with_table(KOOPMAN_TABLE, data, prev_crc)
end

-- ---------------------------------------------------------------------------
-- Streaming accumulator
-- ---------------------------------------------------------------------------

--- Create a streaming CRC-32 accumulator (IEEE polynomial).
--- @return table  stream object with :update/:finish/:hex/:reset methods
function M.stream()
  local s = {}
  -- current CRC (unsigned double)
  local _crc = 0 --: number

  --- Feed more data into the accumulator.
  function s:update(chunk)
    _crc = M.compute(chunk, _crc)
  end

  --- Return the final CRC as an unsigned 32-bit integer.
  function s:finish()
    return _crc
  end

  --- Return the final CRC as an 8-char lowercase hex string.
  function s:hex()
    return string.format("%08x", _crc)
  end

  --- Reset the accumulator to start a new CRC computation.
  function s:reset()
    _crc = 0
  end

  return s
end

-- ---------------------------------------------------------------------------
-- combine(crc1, crc2, len2)
-- ---------------------------------------------------------------------------
-- Compute CRC-32(A || B) given CRC-32(A)=crc1, CRC-32(B)=crc2, #B=len2.
--
-- Mathematical basis:
--   CRC-32 is a GF(2)[x] polynomial remainder operation with pre/post XOR.
--   Treating the CRC as a linear map over GF(2)^32, the transform for data B
--   factors as: T_B(state) = L_B(state) XOR K_B, where L_B is linear.
--   Algebraic manipulation shows:
--       CRC(A || B) = L_B(CRC(A)) XOR CRC(B)
--   where L_B is the linear part of the CRC transform for data B.
--
--   Crucially, L_B depends only on the LENGTH of B (not its content), because
--   the CRC polynomial in GF(2)[x] satisfies:
--       L_B(x) = x * x^{8*len_B} mod P(x) [one-bit-shift applied len_B*8 times]
--   i.e., L_B is repeated application of the one-bit CRC step:
--       bit_step(v) = (v >> 1) XOR (POLY if v & 1 else 0)
--
--   We compute bit_step^{8*len2} via GF(2) matrix exponentiation (binary
--   exponentiation using 32×32 matrices over GF(2)).
--
-- Reference: zlib crc32.c — gf2_matrix_times / gf2_matrix_square / crc32_combine.

-- GF(2) matrix-vector multiply: mat * vec (all as signed 32-bit bit ops).
local function gf2_mv(mat, vec)
  local r = 0
  local v = bit.tobit(vec)
  for i = 1, 32 do
    if band(v, 1) ~= 0 then r = bxor(r, mat[i]) end
    v = rshift(v, 1)
  end
  return r
end

-- Square a 32×32 GF(2) matrix in-place into dst.
local function gf2_sq(dst, src)
  for i = 1, 32 do dst[i] = gf2_mv(src, src[i]) end
end

-- One-bit CRC step (IEEE polynomial): v' = (v>>1) XOR (POLY if v&1 else 0).
-- This is the generator for the GF(2) matrix representation.
local IEEE_POLY_BIT = bit.tobit(0xEDB88320)
local function bit_step(v)
  local r = bit.tobit(v)
  if band(r, 1) ~= 0 then
    return bxor(rshift(r, 1), IEEE_POLY_BIT)
  else
    return rshift(r, 1)
  end
end

-- Build the generator matrix G where G[i] = bit_step(2^{i-1}).
local function build_generator()
  local g = {}
  for i = 1, 32 do
    local ei
    if i < 32 then ei = lshift(1, i - 1)
    else ei = bit.tobit(0x80000000) end
    g[i] = bit_step(ei)
  end
  return g
end

--- Combine two CRC-32 values.
--- @param crc1 number  CRC-32 of block A (unsigned 32-bit)
--- @param crc2 number  CRC-32 of block B (unsigned 32-bit)
--- @param len2 number  byte length of block B
--- @return number  CRC-32 of A..B (unsigned 32-bit)
function M.combine(crc1, crc2, len2)
  if len2 == 0 then return crc1 end

  -- Apply bit_step^{8*len2} to crc1 via matrix binary exponentiation,
  -- then XOR with crc2 to get CRC(A || B).
  local mat = build_generator()
  local acc = bit.tobit(crc1)
  -- Identity matrix for accumulating the result matrix
  local res = {} --: { [integer]: integer }
  for i = 1, 32 do
    if i < 32 then res[i] = lshift(1, i - 1)
    else res[i] = bit.tobit(0x80000000) end
  end

  -- Exponent = 8 * len2; use plain Lua number arithmetic (not bit ops) so
  -- that large len2 values (> 2^28 bytes) don't overflow 32-bit signed int.
  local n = 8 * len2
  local tmp = {} --: { [integer]: integer }
  while n > 0 do
    if n % 2 ~= 0 then
      -- res = mat * res  (column-wise)
      for i = 1, 32 do tmp[i] = gf2_mv(mat, res[i]) end
      for i = 1, 32 do res[i] = tmp[i] end
    end
    gf2_sq(tmp, mat)
    for i = 1, 32 do mat[i] = tmp[i] end
    n = math.floor(n / 2)
  end

  local transformed = gf2_mv(res, acc)
  return u32(bxor(transformed, bit.tobit(crc2)))
end

return M
