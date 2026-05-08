if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")

local M = {}
M._tier = "pure"

-- ========================
-- UTILITIES: pack/unpack big-endian integers
-- ========================

function M.pack_u8(n)
  return string.char(bit.band(n, 0xff))
end

function M.pack_u16(n)
  return string.char(
    bit.band(bit.rshift(n, 8), 0xff),
    bit.band(n, 0xff)
  )
end

function M.pack_u32(n)
  return string.char(
    bit.band(bit.rshift(n, 24), 0xff),
    bit.band(bit.rshift(n, 16), 0xff),
    bit.band(bit.rshift(n, 8), 0xff),
    bit.band(n, 0xff)
  )
end

function M.pack_i8(n)
  if n < 0 then n = n + 256 end
  return string.char(bit.band(n, 0xff))
end

function M.pack_i16(n)
  if n < 0 then n = n + 65536 end
  return M.pack_u16(n)
end

function M.pack_i32(n)
  -- bit.tobit handles signed conversion for bit ops
  local u = bit.tobit(n)
  return string.char(
    bit.band(bit.rshift(u, 24), 0xff),
    bit.band(bit.rshift(u, 16), 0xff),
    bit.band(bit.rshift(u, 8), 0xff),
    bit.band(u, 0xff)
  )
end

--: (s: string, pos: integer | nil) -> (integer, integer)
function M.unpack_u8(s, pos)
  local p = (pos or 1) --[[:! integer]]
  local byte = string.byte(s, p) --[[:! integer]]
  return byte, p + 1
end

--: (s: string, pos: integer | nil) -> (integer, integer)
function M.unpack_u16(s, pos)
  local p = (pos or 1) --[[:! integer]]
  local b1 = string.byte(s, p) --[[:! integer]]
  local b2 = string.byte(s, p + 1) --[[:! integer]]
  return bit.bor(bit.lshift(b1, 8), b2), p + 2
end

--: (s: string, pos: integer | nil) -> (integer, integer)
function M.unpack_u32(s, pos)
  local p = (pos or 1) --[[:! integer]]
  local b1 = string.byte(s, p) --[[:! integer]]
  local b2 = string.byte(s, p + 1) --[[:! integer]]
  local b3 = string.byte(s, p + 2) --[[:! integer]]
  local b4 = string.byte(s, p + 3) --[[:! integer]]
  -- use unsigned arithmetic to avoid sign issues on 32-bit values >= 2^31
  local hi = bit.bor(bit.lshift(b1, 8), b2)
  local lo = bit.bor(bit.lshift(b3, 8), b4)
  return hi * 65536 + lo, p + 4
end

--: (s: string, pos: integer | nil) -> (integer, integer)
function M.unpack_i8(s, pos)
  local p = (pos or 1) --[[:! integer]]
  local v = string.byte(s, p) --[[:! integer]]
  if v >= 128 then v = v - 256 end
  return v, p + 1
end

--: (s: string, pos: integer | nil) -> (integer, integer)
function M.unpack_i16(s, pos)
  local p = (pos or 1) --[[:! integer]]
  local v, next_pos = M.unpack_u16(s, p)
  -- sign-extend 16-bit
  v = bit.arshift(bit.lshift(v, 16), 16)
  return v, next_pos
end

--: (s: string, pos: integer | nil) -> (integer, integer)
function M.unpack_i32(s, pos)
  local p = (pos or 1) --[[:! integer]]
  local b1 = string.byte(s, p) --[[:! integer]]
  local b2 = string.byte(s, p + 1) --[[:! integer]]
  local b3 = string.byte(s, p + 2) --[[:! integer]]
  local b4 = string.byte(s, p + 3) --[[:! integer]]
  local v = bit.bor(
    bit.lshift(b1, 24),
    bit.lshift(b2, 16),
    bit.lshift(b3, 8),
    b4
  )
  return v, p + 4
end

-- ========================
-- VARINT (unsigned LEB128)
-- ========================

--: (n: integer) -> string
function M.encode_varint(n)
  local result = ""
  while n >= 128 do
    result = result .. string.char(bit.bor(bit.band(n, 0x7f), 0x80))
    n = bit.rshift(n, 7)
  end
  result = result .. string.char(n)
  return result
end

-- Decode varint from buf starting at pos (1-indexed).
-- Returns: value, pos_after
--: (buf: string, pos: integer | nil) -> (integer, integer) | (nil, string)
function M.decode_varint(buf, pos)
  local p = (pos or 1) --[[:! integer]]
  local result = 0
  local shift = 0
  local len = #buf
  while p <= len do
    local b = string.byte(buf, p) --[[:! integer]]
    p = p + 1
    result = bit.bor(result, bit.lshift(bit.band(b, 0x7f), shift))
    if bit.band(b, 0x80) == 0 then
      return result, p
    end
    shift = shift + 7
    if shift >= 35 then
      return nil, "varint too long"
    end
  end
  return nil, "buffer ended mid-varint"
end

-- ========================
-- LENGTH-DELIMITED FRAMING
-- ========================

function M.ld_encode(s)
  return M.encode_varint(#s) .. s
end

-- Decode length-delimited record from buf at pos.
-- Returns: data, pos_after
-- Or: nil, errmsg
--: (buf: string, pos: integer | nil) -> (string, integer) | (nil, string)
function M.ld_decode(buf, pos)
  local p = (pos or 1) --[[:! integer]]
  local len_val, npos_val = M.decode_varint(buf, p)
  if type(len_val) ~= "number" then
    return nil, tostring(npos_val)  -- npos_val is errmsg here
  end
  local len = len_val --[[:! integer]]
  local npos = (npos_val or p) --[[:! integer]]
  local data_end = npos + len - 1
  if data_end > #buf then
    return nil, "buffer too short for length-delimited data"
  end
  return string.sub(buf, npos, data_end), data_end + 1
end

-- ========================
-- NETSTRING
-- ========================

function M.encode(s)
  return tostring(#s) .. ":" .. s .. ","
end

-- Decode one netstring from the start of buf.
-- Returns: data, rest
-- Or: nil, errmsg
function M.decode(buf)
  local colon_pos_raw = string.find(buf, ":", 1, true)
  if not colon_pos_raw then
    return nil, "no colon found in netstring"
  end
  local colon_pos = colon_pos_raw --[[:! integer]]
  local len_str = string.sub(buf, 1, colon_pos - 1)
  if not len_str:match("^%d+$") then
    return nil, "invalid length in netstring"
  end
  local len_num = tonumber(len_str)
  if len_num == nil then
    return nil, "invalid length in netstring"
  end
  local len = math.floor(len_num) --: integer
  local data_start = colon_pos + 1
  local data_end = data_start + len - 1
  local comma_pos = data_end + 1
  if comma_pos > #buf then
    return nil, "buffer too short for netstring data"
  end
  if string.byte(buf, comma_pos) ~= string.byte(",") then
    return nil, "missing trailing comma in netstring"
  end
  return string.sub(buf, data_start, data_end), string.sub(buf, comma_pos + 1)
end

function M.decode_all(buf)
  local results = {}
  while buf ~= "" do
    local data, rest = M.decode(buf)
    if data == nil then
      -- rest is errmsg here
      if buf == "" then break end
      return results, buf
    end
    results[#results + 1] = data
    buf = rest
  end
  return results, buf
end

function M.encode_all(strings)
  local parts = {}
  for i = 1, #strings do
    parts[i] = M.encode(strings[i])
  end
  return table.concat(parts)
end

-- Streaming decoder
function M.decoder()
  local d = { buf = "" }
  function d:feed(bytes)
    self.buf = self.buf .. bytes
    local results = {}
    while true do
      local data, rest = M.decode(self.buf)
      if data == nil then break end
      results[#results + 1] = data
      self.buf = rest
    end
    return results, nil
  end
  return d
end

-- ========================
-- TLV (Type-Length-Value)
-- ========================

-- opts: {type_bytes=1|2, length_bytes=1|2|4}
function M.tlv_encode(type_tag, value, opts)
  opts = opts or {}
  local type_bytes = opts.type_bytes or 1
  local length_bytes = opts.length_bytes or 1
  local vlen = #value

  local type_str
  if type_bytes == 1 then
    if type_tag < 0 or type_tag > 255 then
      return nil, "type tag out of range for 1-byte type field"
    end
    type_str = M.pack_u8(type_tag)
  elseif type_bytes == 2 then
    if type_tag < 0 or type_tag > 65535 then
      return nil, "type tag out of range for 2-byte type field"
    end
    type_str = M.pack_u16(type_tag)
  else
    return nil, "type_bytes must be 1 or 2"
  end

  local len_str
  if length_bytes == 1 then
    if vlen > 255 then
      return nil, "value too long for 1-byte length field"
    end
    len_str = M.pack_u8(vlen)
  elseif length_bytes == 2 then
    if vlen > 65535 then
      return nil, "value too long for 2-byte length field"
    end
    len_str = M.pack_u16(vlen)
  elseif length_bytes == 4 then
    len_str = M.pack_u32(vlen)
  else
    return nil, "length_bytes must be 1, 2, or 4"
  end

  return type_str .. len_str .. value, nil
end

-- Decode one TLV record from buf at pos (1-indexed).
-- Returns: type_tag, value, pos_after
-- Or: nil, nil, nil, errmsg
function M.tlv_decode(buf, pos, opts)
  opts = opts or {}
  local type_bytes = opts.type_bytes or 1
  local length_bytes = opts.length_bytes or 1
  local p = pos or 1

  local buflen = #buf
  if p + type_bytes + length_bytes - 1 > buflen then
    return nil, nil, nil, "buffer too short for TLV header"
  end

  local type_tag = 0
  if type_bytes == 1 then
    type_tag, p = M.unpack_u8(buf, p)
  else
    type_tag, p = M.unpack_u16(buf, p)
  end

  local vlen = 0
  if length_bytes == 1 then
    vlen, p = M.unpack_u8(buf, p)
  elseif length_bytes == 2 then
    vlen, p = M.unpack_u16(buf, p)
  else
    vlen, p = M.unpack_u32(buf, p)
  end

  local data_end = p + vlen - 1
  if data_end > buflen then
    return nil, nil, nil, "buffer too short for TLV value"
  end

  return type_tag, string.sub(buf, p, data_end), data_end + 1, nil
end

-- Decode all TLV records from buf.
-- Returns: {{type, value},...}, err
function M.tlv_decode_all(buf, opts)
  local results = {}
  local pos = 1
  local buflen = #buf
  while pos <= buflen do
    local type_tag, value, next_pos, err = M.tlv_decode(buf, pos, opts)
    if err then
      return results, err
    end
    results[#results + 1] = { type_tag, value }
    pos = next_pos
  end
  return results, nil
end

return M
