-- lib/snappy/init.lua
-- Snappy compression/decompression, pure Lua.
-- Implements the Snappy format as described in:
--   https://github.com/google/snappy/blob/main/format_description.txt
--
-- Public API:
--   M.decompress(compressed)  -> decompressed, nil  OR  nil, errmsg
--   M.compress(input)         -> compressed, nil    OR  nil, errmsg
--   M.encode = M.compress     (codec alias)
--   M.decode = M.decompress   (codec alias)
--   M.is_valid(data)          -> boolean
--   M._tier = "pure"

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local band, bor = bit.band, bit.bor
local lshift, rshift = bit.lshift, bit.rshift
local byte = string.byte
local char = string.char
local sub = string.sub
local concat = table.concat

local M = {}
M._tier = "pure"

-- ── varint (LEB128) ──────────────────────────────────────────────────────────

-- Read a Snappy varint from data at position pos (1-based).
-- Returns: value, new_pos  OR  nil, errmsg
local function read_varint(data, pos)
  local len = #data
  local result = 0
  local shift = 0
  while pos <= len do
    local b = byte(data, pos)
    pos = pos + 1
    result = bor(result, lshift(band(b, 0x7F), shift))
    if band(b, 0x80) == 0 then
      return result, pos
    end
    shift = shift + 7
    if shift >= 35 then
      return nil, "varint: overflow (> 5 bytes for 32-bit value)"
    end
  end
  return nil, "varint: unexpected end of input"
end

-- Write a varint to a table of char() strings.
-- Returns: string representation of the varint
local function write_varint(v)
  if v < 128 then
    return char(v)
  end
  local parts = {} --[[: { [integer]: string }]]
  while v >= 128 do
    parts[#parts + 1] = char(bor(band(v, 0x7F), 0x80)) --[[:! string]]
    v = rshift(v, 7)
  end
  parts[#parts + 1] = char(v)
  return concat(parts)
end

-- ── helpers ──────────────────────────────────────────────────────────────────

local function read_u16_le(s, i)
  local a, b = byte(s, i, i + 1)
  return (a --[[:! integer]]) + (b --[[:! integer]]) * 256
end

local function read_u32_le(s, i)
  local a, b, c, d = byte(s, i, i + 3)
  return (a --[[:! integer]]) + (b --[[:! integer]]) * 256 + (c --[[:! integer]]) * 65536 + (d --[[:! integer]]) * 16777216
end

local function read_u24_le(s, i)
  local a, b, c = byte(s, i, i + 2)
  return (a --[[:! integer]]) + (b --[[:! integer]]) * 256 + (c --[[:! integer]]) * 65536
end

local function write_u16_le(v)
  return char(band(v, 0xFF), band(rshift(v, 8), 0xFF))
end

-- ── decompress ───────────────────────────────────────────────────────────────

-- Decompress a Snappy-compressed string.
-- Returns: decompressed_string, nil  OR  nil, errmsg
function M.decompress(compressed)
  if type(compressed) ~= "string" then
    return nil, "decompress: expected string"
  end
  local clen = #compressed
  if clen == 0 then
    return nil, "decompress: empty input"
  end

  -- Read uncompressed length varint
  local uncompressed_len, ip_or_err = read_varint(compressed, 1)
  if uncompressed_len == nil then
    return nil, "decompress: " .. ip_or_err --[[:! string]]
  end
  local ip = ip_or_err --[[:! integer]]

  -- Output buffer as a flat byte array (0-based indexing) for O(1) back-reference access
  local decoded = {}
  local out_len = 0

  while ip <= clen do
    local tag = byte(compressed, ip) --[[:! integer]]
    ip = ip + 1
    local tag_type = band(tag, 0x03)

    if tag_type == 0x00 then
      -- ── Literal ────────────────────────────────────────────────────────────
      local length_code = rshift(tag, 2)
      local lit_len
      if length_code <= 59 then
        lit_len = length_code + 1
      elseif length_code == 60 then
        -- 1 extra byte
        if ip > clen then
          return nil, "decompress: truncated literal length (1 byte)"
        end
        lit_len = (byte(compressed, ip) --[[:! integer]]) + 1
        ip = ip + 1
      elseif length_code == 61 then
        -- 2 extra bytes LE
        if ip + 1 > clen then
          return nil, "decompress: truncated literal length (2 bytes)"
        end
        lit_len = read_u16_le(compressed, ip) + 1
        ip = ip + 2
      elseif length_code == 62 then
        -- 3 extra bytes LE
        if ip + 2 > clen then
          return nil, "decompress: truncated literal length (3 bytes)"
        end
        lit_len = read_u24_le(compressed, ip) + 1
        ip = ip + 3
      else
        -- length_code == 63: 4 extra bytes LE
        if ip + 3 > clen then
          return nil, "decompress: truncated literal length (4 bytes)"
        end
        lit_len = read_u32_le(compressed, ip) + 1
        ip = ip + 4
      end
      -- Copy literal bytes
      if ip + lit_len - 1 > clen then
        return nil, "decompress: literal data extends beyond input"
      end
      for i = ip, ip + lit_len - 1 do
        decoded[out_len] = byte(compressed, i)
        out_len = out_len + 1
      end
      ip = ip + lit_len

    elseif tag_type == 0x01 then
      -- ── Copy with 1-byte offset ────────────────────────────────────────────
      -- length = ((tag >> 2) & 0x07) + 4
      -- offset = (tag >> 5) | (next_byte << 3)
      local copy_len = band(rshift(tag, 2), 0x07) + 4
      if ip > clen then
        return nil, "decompress: truncated copy-1 offset"
      end
      local next_b = byte(compressed, ip) --[[:! integer]]
      ip = ip + 1
      local offset = bor(rshift(tag, 5), lshift(next_b, 3))
      if offset == 0 then
        return nil, "decompress: copy-1 zero offset"
      end
      local match_start = out_len - offset
      if match_start < 0 then
        return nil, "decompress: copy-1 offset beyond start of output"
      end
      for i = 0, copy_len - 1 do
        decoded[out_len] = decoded[match_start + i]
        out_len = out_len + 1
      end

    elseif tag_type == 0x02 then
      -- ── Copy with 2-byte offset ────────────────────────────────────────────
      -- length = (tag >> 2) + 1
      -- offset = next 2 bytes LE
      local copy_len = rshift(tag, 2) + 1
      if ip + 1 > clen then
        return nil, "decompress: truncated copy-2 offset"
      end
      local offset = read_u16_le(compressed, ip)
      ip = ip + 2
      if offset == 0 then
        return nil, "decompress: copy-2 zero offset"
      end
      local match_start = out_len - offset
      if match_start < 0 then
        return nil, "decompress: copy-2 offset beyond start of output"
      end
      for i = 0, copy_len - 1 do
        decoded[out_len] = decoded[match_start + i]
        out_len = out_len + 1
      end

    else
      -- tag_type == 0x03
      -- ── Copy with 4-byte offset ────────────────────────────────────────────
      -- length = (tag >> 2) + 1
      -- offset = next 4 bytes LE
      local copy_len = rshift(tag, 2) + 1
      if ip + 3 > clen then
        return nil, "decompress: truncated copy-4 offset"
      end
      local offset = read_u32_le(compressed, ip)
      ip = ip + 4
      if offset == 0 then
        return nil, "decompress: copy-4 zero offset"
      end
      local match_start = out_len - offset
      if match_start < 0 then
        return nil, "decompress: copy-4 offset beyond start of output"
      end
      for i = 0, copy_len - 1 do
        decoded[out_len] = decoded[match_start + i]
        out_len = out_len + 1
      end
    end
  end

  -- Validate output length matches header
  if out_len ~= uncompressed_len then
    return nil, string.format(
      "decompress: output length mismatch (got %d, expected %d)",
      out_len, uncompressed_len
    )
  end

  -- Convert decoded byte array to string
  local result = {}
  for i = 0, out_len - 1 do
    result[i + 1] = char(decoded[i])
  end
  return concat(result), nil
end

-- ── compress ─────────────────────────────────────────────────────────────────

-- Hash a 4-byte window at position i (1-based) in input string.
-- Returns a value in [0, HASH_SIZE).
local HASH_SIZE = 16384  -- 16K entries — good coverage for repeated-pattern inputs

local function hash4(input, i)
  local a, b, c, d = byte(input, i, i + 3)
  -- Polynomial hash with a large prime, fits in Lua double (integers < 2^53)
  return (a + b * 256 + c * 65536 + d * 16777216) * 2654435761 % HASH_SIZE
end

-- Emit a literal run.
-- lit: string of literal bytes to emit
-- out: output accumulator table
local function emit_literal(lit)
  local n = #lit
  if n == 0 then return "" end
  local length_minus1 = n - 1
  local tag_and_extra
  if length_minus1 <= 59 then
    tag_and_extra = char(lshift(length_minus1, 2))
  elseif length_minus1 <= 0xFF then
    tag_and_extra = char(lshift(60, 2), length_minus1)
  elseif length_minus1 <= 0xFFFF then
    tag_and_extra = char(lshift(61, 2)) .. write_u16_le(length_minus1)
  elseif length_minus1 <= 0xFFFFFF then
    local lo = band(length_minus1, 0xFFFF)
    local hi = rshift(length_minus1, 16)
    tag_and_extra = char(lshift(62, 2)) .. write_u16_le(lo) .. char(hi)
  else
    -- 4-byte length
    tag_and_extra = char(lshift(63, 2))
      .. char(band(length_minus1, 0xFF))
      .. char(band(rshift(length_minus1, 8), 0xFF))
      .. char(band(rshift(length_minus1, 16), 0xFF))
      .. char(band(rshift(length_minus1, 24), 0xFF))
  end
  return tag_and_extra .. lit
end

-- Emit a single copy element for up to 64 bytes.
-- copy_len: 4..64 (copy-1), 1..64 (copy-2/4)
-- offset: distance back in output (1..65535)
-- Returns: encoded string
local function emit_copy_one(copy_len, offset)
  -- Try copy-1 first: length 4..11, offset 1..2047 (11-bit field: 3 bits high + 8 bits)
  -- copy-1: length = ((tag >> 2) & 0x07) + 4  → len in [4,11]
  --         offset = (tag >> 5) | (next_byte << 3) — 11 bits total
  if copy_len >= 4 and copy_len <= 11 and offset >= 1 and offset <= 2047 then
    local len_field = copy_len - 4           -- 0..7 (3 bits)
    local off_lo3   = band(offset, 0x07)     -- bits 0-2 of offset → go into tag[7:5]
    local off_hi8   = rshift(offset, 3)      -- bits 3-10 of offset → next byte
    local tag = bor(bor(lshift(off_lo3, 5), lshift(len_field, 2)), 0x01)
    return char(tag, off_hi8)
  end
  -- copy-2: length 1..64, offset 1..65535
  -- length = (tag >> 2) + 1  → tag bits [7:2] = length - 1
  -- copy_len is clamped to <=64 by caller
  local tag = bor(lshift(copy_len - 1, 2), 0x02)
  return char(tag) .. write_u16_le(offset)
end

-- Emit copy element(s) for a match of arbitrary length (>= 4 bytes).
-- copy-2/copy-4 tag encodes length in 6 bits → max 64 bytes per element.
-- Lengths > 64 are split into multiple copy elements.
-- offset: distance back in output (1..65535)
-- Returns: encoded string
local function emit_copy(copy_len, offset)
  if copy_len <= 64 then
    return emit_copy_one(copy_len, offset)
  end
  -- Split into chunks of at most 64 bytes.
  local parts = {}
  while copy_len > 0 do
    local chunk = copy_len > 64 and 64 or copy_len
    parts[#parts + 1] = emit_copy_one(chunk, offset)
    copy_len = copy_len - chunk
  end
  return concat(parts)
end

-- Compress input using Snappy format (greedy LZ77).
-- Returns: compressed_string, nil  OR  nil, errmsg
function M.compress(input)
  if type(input) ~= "string" then
    return nil, "compress: expected string"
  end
  local n = #input
  local out = { write_varint(n) }

  if n == 0 then
    return concat(out), nil
  end

  -- Hash table: hash → last seen 1-based position in input
  local ht = {} --: { [number]: integer }
  local ip = 1         -- current read position (1-based)
  local lit_start = 1  -- start of current pending literal run

  -- We need at least 4 bytes to attempt a match.
  -- Process up to n-3 (so we can always read 4 bytes at ip).
  local limit = n - 3

  while ip <= limit do
    local h = hash4(input, ip)
    local candidate = ht[h]
    ht[h] = ip

    local match_len = 0
    local match_offset = 0

    if candidate ~= nil and ip - candidate >= 1 and ip - candidate <= 65535 then
      local offs = ip - candidate --[[:! integer]]
      -- Verify match
      local max_match = n - ip + 1
      local ml = 0
      while ml < max_match and byte(input, (ip + ml) --[[:! integer]]) == byte(input, (candidate + ml) --[[:! integer]]) do
        ml = ml + 1
      end
      if ml >= 4 then
        match_len = ml
        match_offset = offs
      end
    end

    if match_len >= 4 then
      -- Emit pending literals
      if ip > lit_start then
        out[#out + 1] = emit_literal(sub(input, lit_start, ip - 1))
      end
      -- Emit copy
      out[#out + 1] = emit_copy(match_len, match_offset)
      ip = ip + match_len
      lit_start = ip
      -- Update ht for positions skipped inside the match (just the start for simplicity)
    else
      ip = ip + 1
    end
  end

  -- Emit remaining bytes as literals
  if lit_start <= n then
    out[#out + 1] = emit_literal(sub(input, lit_start, n))
  end

  return concat(out), nil
end

-- ── is_valid ─────────────────────────────────────────────────────────────────

-- Basic sanity check: can we read a valid-looking varint at the start?
-- Returns: boolean
function M.is_valid(data)
  if type(data) ~= "string" or #data == 0 then return false end
  local uncompressed_len, ip_or_err = read_varint(data, 1)
  if uncompressed_len == nil then return false end
  local ip = ip_or_err --[[:! integer]]
  -- Check that ip is plausible (at least within bounds)
  if ip > #data + 1 then return false end
  return true
end

-- ── codec aliases ─────────────────────────────────────────────────────────────

M.encode = M.compress
M.decode = M.decompress

return M
