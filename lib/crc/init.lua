if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local band, bxor, rshift, lshift = bit.band, bit.bxor, bit.rshift, bit.lshift

-- LuaJIT's bit library operates on signed 32-bit integers.  All CRC return
-- values are normalised to unsigned doubles (0 – 4294967295) so callers can
-- compare them against standard hex literals such as 0xcbf43926 without
-- needing to know about the signed representation.
local function u32(n)
  if n < 0 then return n + 4294967296 end
  return n
end

-- Reflect the bottom `width` bits of a value.
local function reflect(val, width)
  local result = 0
  for _ = 1, width do
    result = lshift(result, 1)
    if band(val, 1) ~= 0 then result = bxor(result, 1) end
    val = rshift(val, 1)
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Table builders
-- ---------------------------------------------------------------------------

-- Build a 256-entry lookup table for a reflected (LSB-first) CRC.
-- `poly_reflected` is the bit-reversed polynomial (without the leading 1).
local function make_reflected_table(poly_reflected)
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

-- Build a 256-entry lookup table for a non-reflected (MSB-first) CRC.
-- `poly` is the normal polynomial (without the leading 1), `width` in bits.
local function make_normal_table(poly, width)
  local t = {}
  local topbit = lshift(1, width - 1)
  local mask = width == 32 and 0xFFFFFFFF or (lshift(1, width) - 1)
  for i = 0, 255 do
    local crc = lshift(i, width - 8)
    for _ = 1, 8 do
      if band(crc, topbit) ~= 0 then
        crc = bxor(lshift(crc, 1), poly)
      else
        crc = lshift(crc, 1)
      end
      crc = band(crc, mask)
    end
    t[i] = crc
  end
  return t
end

-- Public: precompute lookup table (reflected when width==32 by default).
-- The `reflect` flag selects reflected vs normal.
function M.make_table(poly, width, reflected)
  if reflected == nil then reflected = true end
  if reflected then
    return make_reflected_table(reflect(poly, width))
  else
    return make_normal_table(poly, width)
  end
end

-- ---------------------------------------------------------------------------
-- Precomputed tables
-- ---------------------------------------------------------------------------

-- CRC-32/ISO-HDLC (a.k.a. zlib CRC-32, Ethernet, gzip)
-- poly = 0x04C11DB7, reflected poly = 0xEDB88320
local CRC32_TABLE = make_reflected_table(0xEDB88320)

-- CRC-32C / Castagnoli (iSCSI, Btrfs, SCTP)
-- poly = 0x1EDC6F41, reflected poly = 0x82F63B78
local CRC32C_TABLE = make_reflected_table(0x82F63B78)

-- CRC-16/IBM (a.k.a. CRC-16/ARC, Modbus)
-- poly = 0x8005, reflected poly = 0xA001
local CRC16_TABLE = make_reflected_table(0xA001)

-- CRC-16/CCITT-FALSE (poly = 0x1021, MSB-first, init = 0xFFFF)
local CRC16_CCITT_TABLE = make_normal_table(0x1021, 16)

-- CRC-8 (poly = 0x07, MSB-first, init = 0x00)
local CRC8_TABLE = make_normal_table(0x07, 8)

-- CRC-8/MAXIM (poly = 0x31, reflected)
local CRC8_MAXIM_TABLE = make_reflected_table(reflect(0x31, 8))

-- CRC-64/ECMA-182 (poly = 0x42F0E1EBA9EA3693, reflected)
-- We split into two 32-bit halves and maintain parallel tables.
-- Reflected poly hi/lo: reflect(0x42F0E1EBA9EA3693)
-- = 0x9C26492649082FBD (we derive this via the reflected table logic below)
local CRC64_TABLE_HI = {}
local CRC64_TABLE_LO = {}
do
  -- CRC-64/ECMA-182 normal poly:
  --   hi = 0x42F0E1EB, lo = 0xA9EA3693
  -- Reflected poly = 0xC96C5795D7870F42 -- but we compute by bit arithmetic
  -- We'll use the reflected variant: poly reflected from MSB to LSB.
  -- Since we can't do 64-bit arithmetic directly, build the tables manually.
  -- poly_hi = 0x42F0E1EB, poly_lo = 0xA9EA3693  (normal)
  -- reflected: reverse all 64 bits
  -- reflect_hi, reflect_lo = reverse_64(poly_hi, poly_lo)
  --
  -- A simpler approach: use the well-known reflected CRC-64/JONES polynomial
  -- which equals the reflection of ECMA-182:
  --   0xad93d23594c935a9  (hi=0xad93d235, lo=0x94c935a9)
  -- We use that for CRC-64/JONES (same polynomial, reflected representation).
  local POLY64_HI = 0xad93d235
  local POLY64_LO = 0x94c935a9

  for i = 0, 255 do
    local crc_hi = 0
    local crc_lo = i
    for _ = 1, 8 do
      local carry = band(crc_lo, 1)
      -- logical right shift 64-bit pair
      crc_lo = bxor(rshift(crc_lo, 1), lshift(band(crc_hi, 1), 31))
      crc_hi = rshift(crc_hi, 1)
      if carry ~= 0 then
        crc_lo = bxor(crc_lo, POLY64_LO)
        crc_hi = bxor(crc_hi, POLY64_HI)
      end
    end
    CRC64_TABLE_HI[i] = crc_hi
    CRC64_TABLE_LO[i] = crc_lo
  end
end

-- ---------------------------------------------------------------------------
-- CRC-32
-- ---------------------------------------------------------------------------

--- CRC-32/ISO-HDLC (zlib, gzip, Ethernet).
--- @param data string
--- @param init number|nil  initial CRC value (default 0); pass previous result for incremental use
--- @return number  32-bit CRC
function M.crc32(data, init)
  -- `init` is the unsigned double returned by a previous call.  Convert to
  -- signed 32-bit before XOR so the bit library works correctly.
  local crc = bxor(bit.tobit(init or 0), 0xFFFFFFFF)
  local s = data --[[:! string]]
  for i = 1, #s do
    local byte = string.byte(s, i) or 0
    local idx = band(bxor(crc, byte), 0xFF)
    crc = bxor(rshift(crc, 8), CRC32_TABLE[idx])
  end
  return u32(bxor(crc, 0xFFFFFFFF))
end

--- CRC-32C / Castagnoli (iSCSI, Btrfs, SCTP).
function M.crc32c(data, init)
  local crc = bxor(bit.tobit(init or 0), 0xFFFFFFFF)
  local s = data --[[:! string]]
  for i = 1, #s do
    local byte = string.byte(s, i) or 0
    local idx = band(bxor(crc, byte), 0xFF)
    crc = bxor(rshift(crc, 8), CRC32C_TABLE[idx])
  end
  return u32(bxor(crc, 0xFFFFFFFF))
end

--- Hex string for CRC-32 (8 lowercase hex digits).
function M.crc32_hex(data, init)
  -- crc is already an unsigned double (0–4294967295).
  local crc = M.crc32(data, init)
  return string.format("%08x", crc)
end

-- ---------------------------------------------------------------------------
-- CRC-16
-- ---------------------------------------------------------------------------

--- CRC-16/IBM (a.k.a. CRC-16/ARC, Modbus style, reflected).
function M.crc16(data, init)
  local crc = init or 0
  local s = data --[[:! string]]
  for i = 1, #s do
    local byte = string.byte(s, i) or 0
    local idx = band(bxor(crc, byte), 0xFF)
    crc = bxor(rshift(crc, 8), CRC16_TABLE[idx])
  end
  return band(crc, 0xFFFF)
end

--- CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, MSB-first).
function M.crc16_ccitt(data, init)
  local crc = init or 0xFFFF
  local s = data --[[:! string]]
  for i = 1, #s do
    local byte = string.byte(s, i) or 0
    local idx = band(bxor(rshift(crc, 8), byte), 0xFF)
    crc = bxor(lshift(crc, 8), CRC16_CCITT_TABLE[idx])
    crc = band(crc, 0xFFFF)
  end
  return crc
end

--- Hex string for CRC-16 (4 uppercase hex digits).
function M.crc16_hex(data, init)
  return string.format("%04X", M.crc16(data, init))
end

-- ---------------------------------------------------------------------------
-- CRC-8
-- ---------------------------------------------------------------------------

--- CRC-8 (poly 0x07, init 0x00, MSB-first).
function M.crc8(data, init)
  local crc = init or 0
  local s = data --[[:! string]]
  for i = 1, #s do
    local byte = string.byte(s, i) or 0
    local idx = band(bxor(crc, byte), 0xFF)
    crc = CRC8_TABLE[idx]
  end
  return band(crc, 0xFF)
end

--- CRC-8/MAXIM (poly 0x31, reflected, init 0x00).
function M.crc8_maxim(data, init)
  local crc = init or 0
  local s = data --[[:! string]]
  for i = 1, #s do
    local byte = string.byte(s, i) or 0
    local idx = band(bxor(crc, byte), 0xFF)
    crc = bxor(rshift(crc, 8), CRC8_MAXIM_TABLE[idx])
    crc = band(crc, 0xFF)
  end
  return crc
end

-- ---------------------------------------------------------------------------
-- CRC-64
-- ---------------------------------------------------------------------------

--- CRC-64 (ECMA-182-compatible reflected polynomial 0xad93d23594c935a9).
--- Returns two 32-bit integers (hi, lo) since Lua numbers are doubles.
--- @param data string
--- @param init_hi number|nil  high 32 bits of initial value (default 0)
--- @param init_lo number|nil  low  32 bits of initial value (default 0)
--- @return number hi, number lo
function M.crc64(data, init_hi, init_lo)
  local crc_hi = bxor(bit.tobit(init_hi or 0), 0xFFFFFFFF)
  local crc_lo = bxor(bit.tobit(init_lo or 0), 0xFFFFFFFF)
  local s = data --[[:! string]]
  for i = 1, #s do
    local byte = string.byte(s, i) or 0
    local idx = band(bxor(crc_lo, byte), 0xFF)
    local tlo = CRC64_TABLE_LO[idx]
    local thi = CRC64_TABLE_HI[idx]
    crc_lo = bxor(bxor(rshift(crc_lo, 8), lshift(band(crc_hi, 0xFF), 24)), tlo)
    crc_hi = bxor(rshift(crc_hi, 8), thi)
  end
  return u32(bxor(crc_hi, 0xFFFFFFFF)), u32(bxor(crc_lo, 0xFFFFFFFF))
end

-- ---------------------------------------------------------------------------
-- Generic CRC
-- ---------------------------------------------------------------------------

--:: GenericCrcOpts = { poly: integer, width: integer, init: integer | nil, refin: boolean | nil, refout: boolean | nil, xorout: integer | nil }

--- Generic CRC computation (width 8, 16, or 32).
--: (string, GenericCrcOpts) -> (number | nil, string | nil)
function M.generic(data, opts)
  local opts_ = opts --[[:! GenericCrcOpts]]
  if not opts_ or not opts_.poly or not opts_.width then
    return nil, "opts.poly and opts.width are required"
  end
  local poly   = opts_.poly --[[:! integer]]
  local width  = opts_.width --[[:! integer]]
  local init   = opts_.init   or 0
  local refin  = opts_.refin  ~= false  -- default true
  local refout = opts_.refout ~= false  -- default true
  local xorout = opts_.xorout or 0
  local mask   = width == 32 and 0xFFFFFFFF or (lshift(1, width) - 1)

  local tbl
  if refin then
    tbl = make_reflected_table(reflect(poly, width))
  else
    tbl = make_normal_table(poly, width)
  end

  local crc = init --: integer
  if refin then
    for i = 1, #data do
      local byte = (string.byte(data, i)) or 0 --[[:! integer]]
      local idx = band(bxor(crc, byte), 0xFF)
      crc = bxor(rshift(crc, 8), tbl[idx])
    end
  else
    for i = 1, #data do
      local byte = (string.byte(data, i)) or 0 --[[:! integer]]
      local width_ = width --[[:! integer]]
      local idx = band(bxor(rshift(crc, width_ - 8), byte), 0xFF)
      crc = bxor(lshift(crc, 8), tbl[idx])
      crc = band(crc, mask)
    end
  end

  if refout ~= refin then
    local crc_ = crc --[[:! integer]]
    local width_ = width --[[:! integer]]
    crc = reflect(crc_, width_)
  end
  local crc_ = crc --[[:! integer]]
  local xorout_ = xorout --[[:! integer]]
  local result = bxor(band(crc_, mask), xorout_)
  -- Normalise to unsigned double for 32-bit results.
  if width == 32 then return u32(result) end
  return result
end

-- ---------------------------------------------------------------------------
-- Check values (CRC of "123456789")
-- ---------------------------------------------------------------------------

M.CHECK = {
  crc32      = 0xcbf43926,
  crc32c     = 0xe3069283,
  crc16      = 0xBB3D,
  crc16_ccitt = 0x29B1,
  crc8       = 0xF4,
}

return M
