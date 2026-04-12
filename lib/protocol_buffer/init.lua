if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- Protocol Buffers wire format encoder/decoder.
-- Schema-driven: schemas are Lua tables, not .proto files.
-- Schema field spec: { field_number, type_string, required=bool, repeated=bool, packed=bool, schema=table }
local M = {}
M._tier = "pure"

local bit = require("bit")
local band, bor, lshift, rshift, arshift = bit.band, bit.bor, bit.lshift, bit.rshift, bit.arshift
local ffi = require("ffi")

-- FFI types for float/double/fixed encoding without string.pack
ffi.cdef([[
  typedef union { float f; uint8_t b[4]; } pb_float32_t;
  typedef union { double d; uint8_t b[8]; } pb_float64_t;
  typedef union { uint32_t u; uint8_t b[4]; } pb_uint32_t;
  typedef union { int32_t i; uint8_t b[4]; } pb_int32_t;
  typedef union { uint64_t u; uint8_t b[8]; } pb_uint64_t;
  typedef union { int64_t i; uint8_t b[8]; } pb_int64_t;
]])

local _f32  = ffi.new("pb_float32_t")
local _f64  = ffi.new("pb_float64_t")
local _u32  = ffi.new("pb_uint32_t")
local _i32  = ffi.new("pb_int32_t")
local _u64  = ffi.new("pb_uint64_t[1]")
local _i64  = ffi.new("pb_int64_t[1]")

-- Encode float as 4 little-endian bytes
local function pack_float(v)
  _f32.f = v
  return string.char(_f32.b[0], _f32.b[1], _f32.b[2], _f32.b[3])
end

-- Encode double as 8 little-endian bytes
local function pack_double(v)
  _f64.d = v
  return string.char(_f64.b[0], _f64.b[1], _f64.b[2], _f64.b[3],
                     _f64.b[4], _f64.b[5], _f64.b[6], _f64.b[7])
end

-- Encode uint32 as 4 little-endian bytes
local function pack_uint32(v)
  _u32.u = v
  return string.char(_u32.b[0], _u32.b[1], _u32.b[2], _u32.b[3])
end

-- Encode int32 as 4 little-endian bytes
local function pack_int32(v)
  _i32.i = v
  return string.char(_i32.b[0], _i32.b[1], _i32.b[2], _i32.b[3])
end

-- Encode uint64 as 8 little-endian bytes (v is a Lua number)
local function pack_uint64(v)
  _u64[0].u = v
  return string.char(_u64[0].b[0], _u64[0].b[1], _u64[0].b[2], _u64[0].b[3],
                     _u64[0].b[4], _u64[0].b[5], _u64[0].b[6], _u64[0].b[7])
end

-- Encode int64 as 8 little-endian bytes (v is a Lua number)
local function pack_int64(v)
  _i64[0].i = v
  return string.char(_i64[0].b[0], _i64[0].b[1], _i64[0].b[2], _i64[0].b[3],
                     _i64[0].b[4], _i64[0].b[5], _i64[0].b[6], _i64[0].b[7])
end

-- Decode float from bytes at offset (4 bytes, little-endian)
local function unpack_float(bytes, offset)
  _f32.b[0] = string.byte(bytes, offset)
  _f32.b[1] = string.byte(bytes, offset + 1)
  _f32.b[2] = string.byte(bytes, offset + 2)
  _f32.b[3] = string.byte(bytes, offset + 3)
  return _f32.f
end

-- Decode double from bytes at offset (8 bytes, little-endian)
local function unpack_double(bytes, offset)
  _f64.b[0] = string.byte(bytes, offset)
  _f64.b[1] = string.byte(bytes, offset + 1)
  _f64.b[2] = string.byte(bytes, offset + 2)
  _f64.b[3] = string.byte(bytes, offset + 3)
  _f64.b[4] = string.byte(bytes, offset + 4)
  _f64.b[5] = string.byte(bytes, offset + 5)
  _f64.b[6] = string.byte(bytes, offset + 6)
  _f64.b[7] = string.byte(bytes, offset + 7)
  return _f64.d
end

-- Decode uint32 from bytes at offset (4 bytes, little-endian)
local function unpack_uint32(bytes, offset)
  _u32.b[0] = string.byte(bytes, offset)
  _u32.b[1] = string.byte(bytes, offset + 1)
  _u32.b[2] = string.byte(bytes, offset + 2)
  _u32.b[3] = string.byte(bytes, offset + 3)
  return tonumber(_u32.u)
end

-- Decode int32 from bytes at offset (4 bytes, little-endian)
local function unpack_int32(bytes, offset)
  _i32.b[0] = string.byte(bytes, offset)
  _i32.b[1] = string.byte(bytes, offset + 1)
  _i32.b[2] = string.byte(bytes, offset + 2)
  _i32.b[3] = string.byte(bytes, offset + 3)
  return tonumber(_i32.i)
end

-- Decode uint64 from bytes at offset (8 bytes, little-endian) → Lua number
local function unpack_uint64(bytes, offset)
  _u64[0].b[0] = string.byte(bytes, offset)
  _u64[0].b[1] = string.byte(bytes, offset + 1)
  _u64[0].b[2] = string.byte(bytes, offset + 2)
  _u64[0].b[3] = string.byte(bytes, offset + 3)
  _u64[0].b[4] = string.byte(bytes, offset + 4)
  _u64[0].b[5] = string.byte(bytes, offset + 5)
  _u64[0].b[6] = string.byte(bytes, offset + 6)
  _u64[0].b[7] = string.byte(bytes, offset + 7)
  return tonumber(_u64[0].u)
end

-- Decode int64 from bytes at offset (8 bytes, little-endian) → Lua number
local function unpack_int64(bytes, offset)
  _i64[0].b[0] = string.byte(bytes, offset)
  _i64[0].b[1] = string.byte(bytes, offset + 1)
  _i64[0].b[2] = string.byte(bytes, offset + 2)
  _i64[0].b[3] = string.byte(bytes, offset + 3)
  _i64[0].b[4] = string.byte(bytes, offset + 4)
  _i64[0].b[5] = string.byte(bytes, offset + 5)
  _i64[0].b[6] = string.byte(bytes, offset + 6)
  _i64[0].b[7] = string.byte(bytes, offset + 7)
  return tonumber(_i64[0].i)
end

-- Wire types
M.WIRE_VARINT = 0  -- int32, int64, uint32, uint64, sint32, sint64, bool, enum
M.WIRE_64BIT  = 1  -- fixed64, sfixed64, double
M.WIRE_LEN    = 2  -- string, bytes, embedded messages, packed repeated
M.WIRE_32BIT  = 5  -- fixed32, sfixed32, float

-- Map type name → wire type
local TYPE_WIRE = {
  int32   = 0, int64    = 0, uint32  = 0, uint64  = 0,
  sint32  = 0, sint64   = 0, bool    = 0, enum    = 0,
  fixed64 = 1, sfixed64 = 1, double  = 1,
  string  = 2, bytes    = 2, message = 2,
  fixed32 = 5, sfixed32 = 5, float   = 5,
}

-- ── Varint ────────────────────────────────────────────────────────────────────

-- Encode a non-negative integer as a varint using math (handles > 2^31 safely).
local function encode_varint64(n)
  if n == 0 then return "\0" end
  local bytes = {}
  local i = 0
  while n ~= 0 do
    i = i + 1
    local byte = n % 128
    n = math.floor(n / 128)
    if n ~= 0 then byte = byte + 128 end
    bytes[i] = string.char(byte)
  end
  return table.concat(bytes)
end

-- For negative int32/int64: protobuf always uses 10-byte two's-complement varint.
-- We build the 10 bytes using the FFI int64 union for correct bit patterns.
local _neg_buf = ffi.new("pb_int64_t")
local function encode_varint_signed(n)
  _neg_buf.i = n  -- stores two's complement 64-bit representation
  -- Now extract 10 varint groups of 7 bits from the 8 bytes
  local b = _neg_buf.b
  local bytes = {}
  -- bits: b[0]..b[7] = bytes 0..7, LSB first (little-endian)
  -- Group into 7-bit chunks across 64 bits = 10 groups (last group ≤ 1 bit)
  -- group 0: bits 0-6   = b[0] & 0x7F
  -- group 1: bits 7-13  = (b[0]>>7) | ((b[1]&0x3F)<<1)
  -- group 2: bits 14-20 = (b[1]>>6) | ((b[2]&0x1F)<<2)
  -- group 3: bits 21-27 = (b[2]>>5) | ((b[3]&0x0F)<<3)
  -- group 4: bits 28-34 = (b[3]>>4) | ((b[4]&0x07)<<4)
  -- group 5: bits 35-41 = (b[4]>>3) | ((b[5]&0x03)<<5)
  -- group 6: bits 42-48 = (b[5]>>2) | ((b[6]&0x01)<<6)
  -- group 7: bits 49-55 = b[6]>>1
  -- group 8: bits 56-62 = b[7] & 0x7F
  -- group 9: bit  63    = b[7] >> 7
  local b0,b1,b2,b3,b4,b5,b6,b7 =
    tonumber(b[0]),tonumber(b[1]),tonumber(b[2]),tonumber(b[3]),
    tonumber(b[4]),tonumber(b[5]),tonumber(b[6]),tonumber(b[7])
  local g = {
    band(b0, 0x7F),
    bor(rshift(b0, 7), band(lshift(band(b1, 0x3F), 1), 0x7F)),
    bor(rshift(b1, 6), band(lshift(band(b2, 0x1F), 2), 0x7F)),
    bor(rshift(b2, 5), band(lshift(band(b3, 0x0F), 3), 0x7F)),
    bor(rshift(b3, 4), band(lshift(band(b4, 0x07), 4), 0x7F)),
    bor(rshift(b4, 3), band(lshift(band(b5, 0x03), 5), 0x7F)),
    bor(rshift(b5, 2), band(lshift(band(b6, 0x01), 6), 0x7F)),
    band(rshift(b6, 1), 0x7F),
    band(b7, 0x7F),
    band(rshift(b7, 7), 0x7F),
  }
  -- All 10 bytes emitted (protobuf always uses 10 bytes for negative ints)
  for i = 1, 9 do
    bytes[i] = string.char(bor(g[i], 0x80))
  end
  bytes[10] = string.char(g[10])
  return table.concat(bytes)
end

-- Public encode_varint: handles both non-negative and negative integers.
function M.encode_varint(n)
  if n >= 0 then
    return encode_varint64(n)
  else
    return encode_varint_signed(n)
  end
end

-- Decode a varint from bytes at offset (1-based).
-- Returns (value, next_offset) or (nil, errmsg).
-- For 10-byte varints (negative int64), reconstructs as Lua number (may lose precision > 2^53).
function M.decode_varint(bytes, offset)
  local result = 0
  local shift = 0
  local len = #bytes
  local byte_count = 0
  while offset <= len do
    local byte = string.byte(bytes, offset)
    offset = offset + 1
    byte_count = byte_count + 1
    result = result + band(byte, 0x7f) * (2 ^ shift)
    shift = shift + 7
    if band(byte, 0x80) == 0 then
      return result, offset
    end
    if byte_count >= 10 then
      return nil, "protocol_buffer: varint too long"
    end
  end
  return nil, "protocol_buffer: truncated varint"
end

-- Decode a signed varint (int32/int64) — handles 10-byte negative encoding.
-- Reconstructs the sign by re-reading via FFI int64 union.
local _dec_buf = ffi.new("pb_int64_t")
local function decode_signed_varint(bytes, offset)
  local result = 0
  local shift = 0
  local len = #bytes
  local byte_count = 0
  local raw_bytes = {}
  while offset <= len do
    local byte = string.byte(bytes, offset)
    offset = offset + 1
    byte_count = byte_count + 1
    raw_bytes[byte_count] = byte
    result = result + band(byte, 0x7f) * (2 ^ shift)
    shift = shift + 7
    if band(byte, 0x80) == 0 then break end
    if byte_count >= 10 then
      return nil, "protocol_buffer: varint too long"
    end
  end
  -- For values that may be negative int64 (result >= 2^63 as unsigned),
  -- reinterpret via FFI to get the signed value.
  -- We reassemble the bit pattern into _dec_buf.
  _dec_buf.i = 0  -- zero it
  local bit_pos = 0
  for i = 1, #raw_bytes do
    local b = raw_bytes[i]
    local payload = band(b, 0x7f)
    -- Set bits bit_pos..bit_pos+6 of _dec_buf
    -- Use byte-level writes
    local byte_idx = math.floor(bit_pos / 8)
    local bit_off  = bit_pos % 8
    -- payload is 7 bits; may span two bytes
    local lo_part = band(lshift(payload, bit_off), 0xFF)
    local hi_part = rshift(payload, 8 - bit_off)
    _dec_buf.b[byte_idx] = bor(tonumber(_dec_buf.b[byte_idx]), lo_part)
    if byte_idx + 1 < 8 then
      _dec_buf.b[byte_idx + 1] = bor(tonumber(_dec_buf.b[byte_idx + 1]), hi_part)
    end
    bit_pos = bit_pos + 7
  end
  return tonumber(_dec_buf.i), offset
end

-- ZigZag encoding: maps signed integers to unsigned.
-- n >= 0 → 2n, n < 0 → 2*(-n)-1
function M.encode_zigzag(n)
  if n >= 0 then
    return 2 * n
  else
    return 2 * (-n) - 1
  end
end

-- ZigZag decoding: maps unsigned integers to signed.
function M.decode_zigzag(n)
  if n % 2 == 0 then
    return n / 2
  else
    return -((n + 1) / 2)
  end
end

-- Field tag: (field_number << 3) | wire_type, encoded as varint.
function M.field_tag(field_number, wire_type)
  return M.encode_varint(field_number * 8 + wire_type)
end

-- ── Low-level encode/decode ───────────────────────────────────────────────────

-- Encode a single field value given its type string.
-- Returns encoded bytes or (nil, err).
local function encode_value(type_str, value, schema)
  if type_str == "int32" or type_str == "int64" or
     type_str == "uint32" or type_str == "uint64" or type_str == "enum" then
    return M.encode_varint(value)
  elseif type_str == "sint32" or type_str == "sint64" then
    return encode_varint64(M.encode_zigzag(value))
  elseif type_str == "bool" then
    return M.encode_varint(value and 1 or 0)
  elseif type_str == "string" or type_str == "bytes" then
    return M.encode_varint(#value) .. value
  elseif type_str == "message" then
    if not schema then return nil, "protocol_buffer: message field missing schema" end
    local inner, err = M.encode(schema, value)
    if not inner then return nil, err end
    return M.encode_varint(#inner) .. inner
  elseif type_str == "fixed32" then
    return pack_uint32(value)
  elseif type_str == "sfixed32" then
    return pack_int32(value)
  elseif type_str == "float" then
    return pack_float(value)
  elseif type_str == "fixed64" then
    return pack_uint64(value)
  elseif type_str == "sfixed64" then
    return pack_int64(value)
  elseif type_str == "double" then
    return pack_double(value)
  else
    return nil, "protocol_buffer: unknown type: " .. tostring(type_str)
  end
end

-- Decode a single field value given wire type and type string.
-- Returns (value, next_offset) or (nil, err).
local function decode_value(type_str, wire_type, bytes, offset, schema)
  if wire_type == M.WIRE_VARINT then
    local v, next
    -- Signed types: use signed decoder for correct negative reconstruction
    if type_str == "int32" or type_str == "int64" then
      v, next = decode_signed_varint(bytes, offset)
    else
      v, next = M.decode_varint(bytes, offset)
    end
    if v == nil then return nil, next end
    if type_str == "sint32" or type_str == "sint64" then
      return M.decode_zigzag(v), next
    elseif type_str == "bool" then
      return v ~= 0, next
    end
    return v, next
  elseif wire_type == M.WIRE_LEN then
    local len, next_off = M.decode_varint(bytes, offset)
    if not len then return nil, next_off end
    local data = bytes:sub(next_off, next_off + len - 1)
    if #data < len then return nil, "protocol_buffer: truncated length-delimited field" end
    if type_str == "message" then
      if not schema then return nil, "protocol_buffer: message field missing schema" end
      local msg, err = M.decode(schema, data)
      if not msg then return nil, err end
      return msg, next_off + len
    else
      return data, next_off + len
    end
  elseif wire_type == M.WIRE_32BIT then
    if offset + 3 > #bytes + 1 then return nil, "protocol_buffer: truncated 32-bit field" end
    if type_str == "float" then
      return unpack_float(bytes, offset), offset + 4
    elseif type_str == "sfixed32" then
      return unpack_int32(bytes, offset), offset + 4
    else -- fixed32
      return unpack_uint32(bytes, offset), offset + 4
    end
  elseif wire_type == M.WIRE_64BIT then
    if offset + 7 > #bytes + 1 then return nil, "protocol_buffer: truncated 64-bit field" end
    if type_str == "double" then
      return unpack_double(bytes, offset), offset + 8
    elseif type_str == "sfixed64" then
      return unpack_int64(bytes, offset), offset + 8
    else -- fixed64
      return unpack_uint64(bytes, offset), offset + 8
    end
  else
    return nil, "protocol_buffer: unknown wire type " .. tostring(wire_type)
  end
end

-- ── encode_raw / decode_raw ───────────────────────────────────────────────────

-- Encode an array of {field_number, wire_type, value} triples.
-- WIRE_LEN value: raw bytes (length prefix added automatically).
-- WIRE_VARINT value: integer.
-- WIRE_32BIT / WIRE_64BIT value: raw bytes (4 or 8 bytes respectively).
function M.encode_raw(fields)
  local parts = {}
  for i = 1, #fields do
    local f = fields[i]
    local field_num, wire_type, value = f[1], f[2], f[3]
    parts[#parts + 1] = M.field_tag(field_num, wire_type)
    if wire_type == M.WIRE_VARINT then
      parts[#parts + 1] = M.encode_varint(value)
    elseif wire_type == M.WIRE_LEN then
      parts[#parts + 1] = M.encode_varint(#value)
      parts[#parts + 1] = value
    elseif wire_type == M.WIRE_32BIT then
      parts[#parts + 1] = value
    elseif wire_type == M.WIRE_64BIT then
      parts[#parts + 1] = value
    end
  end
  return table.concat(parts)
end

-- Decode bytes into an array of {field_number, wire_type, value} triples.
-- WIRE_LEN value is the raw bytes (without length prefix).
-- Returns (fields_array, nil) or (nil, errmsg).
function M.decode_raw(bytes)
  local fields = {}
  local offset = 1
  local len = #bytes
  while offset <= len do
    local tag, next_off = M.decode_varint(bytes, offset)
    if not tag then return nil, next_off end
    offset = next_off
    local field_number = math.floor(tag / 8)
    local wire_type = tag % 8
    if wire_type == M.WIRE_VARINT then
      local v, no = M.decode_varint(bytes, offset)
      if not v then return nil, no end
      fields[#fields + 1] = {field_number, wire_type, v}
      offset = no
    elseif wire_type == M.WIRE_LEN then
      local flen, no = M.decode_varint(bytes, offset)
      if not flen then return nil, no end
      local data = bytes:sub(no, no + flen - 1)
      if #data < flen then return nil, "protocol_buffer: truncated length-delimited data" end
      fields[#fields + 1] = {field_number, wire_type, data}
      offset = no + flen
    elseif wire_type == M.WIRE_32BIT then
      if offset + 3 > len then return nil, "protocol_buffer: truncated 32-bit field" end
      fields[#fields + 1] = {field_number, wire_type, bytes:sub(offset, offset + 3)}
      offset = offset + 4
    elseif wire_type == M.WIRE_64BIT then
      if offset + 7 > len then return nil, "protocol_buffer: truncated 64-bit field" end
      fields[#fields + 1] = {field_number, wire_type, bytes:sub(offset, offset + 7)}
      offset = offset + 8
    else
      return nil, "protocol_buffer: unknown wire type " .. tostring(wire_type)
    end
  end
  return fields
end

-- ── Schema-driven encode/decode ───────────────────────────────────────────────

-- Build a reverse map: field_number → {name, spec} from schema.
local function build_number_map(schema)
  local map = {}
  for name, spec in pairs(schema) do
    map[spec[1]] = {name = name, spec = spec}
  end
  return map
end

-- Encode a Lua table using schema.
-- Returns (bytes_string, nil) or (nil, errmsg).
function M.encode(schema, msg)
  local parts = {}
  -- Collect and sort by field_number for deterministic output
  local ordered = {}
  for name, spec in pairs(schema) do
    ordered[#ordered + 1] = {name = name, spec = spec}
  end
  table.sort(ordered, function(a, b) return a.spec[1] < b.spec[1] end)

  for i = 1, #ordered do
    local name = ordered[i].name
    local spec = ordered[i].spec
    local field_number = spec[1]
    local type_str     = spec[2]
    local required     = spec.required
    local repeated     = spec.repeated
    local packed       = spec.packed
    local nested_schema = spec.schema
    local value = msg[name]

    if value == nil then
      if required == true then
        return nil, "protocol_buffer: required field missing: " .. name
      end
    elseif repeated then
      if type(value) ~= "table" then
        return nil, "protocol_buffer: repeated field must be table: " .. name
      end
      local wire = TYPE_WIRE[type_str]
      if wire == nil then
        return nil, "protocol_buffer: unknown type: " .. tostring(type_str)
      end
      if packed and wire == M.WIRE_VARINT then
        -- Pack all values into one length-delimited field
        local packed_parts = {}
        for j = 1, #value do
          local enc, err = encode_value(type_str, value[j], nested_schema)
          if enc == nil then return nil, err end
          packed_parts[j] = enc
        end
        local payload = table.concat(packed_parts)
        parts[#parts + 1] = M.field_tag(field_number, M.WIRE_LEN)
        parts[#parts + 1] = M.encode_varint(#payload)
        parts[#parts + 1] = payload
      else
        for j = 1, #value do
          local enc, err = encode_value(type_str, value[j], nested_schema)
          if enc == nil then return nil, err end
          parts[#parts + 1] = M.field_tag(field_number, wire)
          parts[#parts + 1] = enc
        end
      end
    else
      local wire = TYPE_WIRE[type_str]
      if wire == nil then
        return nil, "protocol_buffer: unknown type: " .. tostring(type_str)
      end
      local enc, err = encode_value(type_str, value, nested_schema)
      if enc == nil then return nil, err end
      parts[#parts + 1] = M.field_tag(field_number, wire)
      parts[#parts + 1] = enc
    end
  end
  return table.concat(parts)
end

-- Decode bytes into a Lua table using schema.
-- Unknown fields are collected in msg._unknown as {field_number, wire_type, value} triples.
-- Returns (msg_table, nil) or (nil, errmsg).
function M.decode(schema, bytes)
  local number_map = build_number_map(schema)
  local msg = {}
  local offset = 1
  local len = #bytes

  -- Pre-initialize repeated fields
  for name, spec in pairs(schema) do
    if spec.repeated then msg[name] = {} end
  end

  while offset <= len do
    local tag, next_off = M.decode_varint(bytes, offset)
    if not tag then return nil, next_off end
    offset = next_off

    local field_number = math.floor(tag / 8)
    local wire_type = tag % 8

    if wire_type ~= M.WIRE_VARINT and wire_type ~= M.WIRE_LEN and
       wire_type ~= M.WIRE_32BIT and wire_type ~= M.WIRE_64BIT then
      return nil, "protocol_buffer: unknown wire type " .. tostring(wire_type)
    end

    local field_info = number_map[field_number]

    if field_info then
      local name = field_info.name
      local spec = field_info.spec
      local type_str = spec[2]
      local repeated = spec.repeated
      local packed = spec.packed
      local nested_schema = spec.schema

      -- Handle packed repeated (LEN wire type for numeric types)
      if packed and wire_type == M.WIRE_LEN then
        local flen, no = M.decode_varint(bytes, offset)
        if not flen then return nil, no end
        local inner = bytes:sub(no, no + flen - 1)
        if #inner < flen then return nil, "protocol_buffer: truncated packed field" end
        offset = no + flen
        local arr = msg[name] or {}
        local ioff = 1
        while ioff <= #inner do
          local v, noff
          if type_str == "int32" or type_str == "int64" then
            v, noff = decode_signed_varint(inner, ioff)
          else
            v, noff = M.decode_varint(inner, ioff)
          end
          if not v then return nil, noff end
          if type_str == "sint32" or type_str == "sint64" then
            v = M.decode_zigzag(v)
          elseif type_str == "bool" then
            v = v ~= 0
          end
          arr[#arr + 1] = v
          ioff = noff
        end
        msg[name] = arr
      else
        local value, no = decode_value(type_str, wire_type, bytes, offset, nested_schema)
        if value == nil then return nil, no end
        offset = no
        if repeated then
          local arr = msg[name]
          arr[#arr + 1] = value
        else
          msg[name] = value
        end
      end
    else
      -- Unknown field: skip and record
      local raw_value, no
      if wire_type == M.WIRE_VARINT then
        raw_value, no = M.decode_varint(bytes, offset)
        if not raw_value then return nil, no end
      elseif wire_type == M.WIRE_LEN then
        local flen, fno = M.decode_varint(bytes, offset)
        if not flen then return nil, fno end
        raw_value = bytes:sub(fno, fno + flen - 1)
        no = fno + flen
      elseif wire_type == M.WIRE_32BIT then
        raw_value = bytes:sub(offset, offset + 3)
        no = offset + 4
      elseif wire_type == M.WIRE_64BIT then
        raw_value = bytes:sub(offset, offset + 7)
        no = offset + 8
      end
      if not msg._unknown then msg._unknown = {} end
      msg._unknown[#msg._unknown + 1] = {field_number, wire_type, raw_value}
      offset = no
    end
  end

  return msg
end

-- ── Validation ────────────────────────────────────────────────────────────────

-- Validate a message against a schema.
-- Returns (true, nil) or (false, errors_list).
function M.validate(schema, msg)
  local errors = {}
  for name, spec in pairs(schema) do
    if spec.required == true and msg[name] == nil then
      errors[#errors + 1] = "required field missing: " .. name
    end
  end
  if #errors > 0 then return false, errors end
  return true, nil
end

return M
