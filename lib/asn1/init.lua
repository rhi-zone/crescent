-- lib/asn1/init.lua
-- ASN.1 DER (Distinguished Encoding Rules) parser and writer.
-- Pure Lua — no dependencies beyond require("bit") for bitwise ops.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local bit = require("bit")
local band, bor, bxor = bit.band, bit.bor, bit.bxor
local rshift, lshift = bit.rshift, bit.lshift
local byte, char, sub = string.byte, string.char, string.sub
local slen = string.len
local concat = table.concat
local floor = math.floor

-- ── Tag class constants ──────────────────────────────────────────────────────

M.CLASS_UNIVERSAL   = 0
M.CLASS_APPLICATION = 1
M.CLASS_CONTEXT     = 2
M.CLASS_PRIVATE     = 3

local CLASS_NAME = { [0]="universal", [1]="application", [2]="context", [3]="private" }

--:: TlvNode = { tag: integer, class: string, class_num: integer, constructed: boolean, value: string, length: integer, next_pos: integer }

-- UNIVERSAL tag numbers
M.TAG_BOOLEAN          = 1
M.TAG_INTEGER          = 2
M.TAG_BIT_STRING       = 3
M.TAG_OCTET_STRING     = 4
M.TAG_NULL             = 5
M.TAG_OID              = 6
M.TAG_UTF8STRING       = 12
M.TAG_SEQUENCE         = 16
M.TAG_SET              = 17
M.TAG_PRINTABLESTRING  = 19
M.TAG_IA5STRING        = 22
M.TAG_UTCTIME          = 23
M.TAG_GENERALIZEDTIME  = 24

-- ── Low-level length encoding ────────────────────────────────────────────────

-- Encode a non-negative integer as DER definite-form length bytes.
local function encode_length(n)
  if n <= 127 then
    return char(n)
  elseif n <= 255 then
    return char(0x81, n)
  elseif n <= 65535 then
    return char(0x82, rshift(n, 8), band(n, 0xff))
  elseif n <= 16777215 then
    return char(0x83, rshift(n, 16), band(rshift(n, 8), 0xff), band(n, 0xff))
  else
    return char(0x84,
      band(rshift(n, 24), 0xff),
      band(rshift(n, 16), 0xff),
      band(rshift(n, 8),  0xff),
      band(n, 0xff))
  end
end

-- ── DECODING ─────────────────────────────────────────────────────────────────

-- Decode one TLV from data starting at pos (1-based, default 1).
-- Returns: node table, nil  OR  nil, errmsg
-- node = { tag, class, class_num, constructed, value, length, next_pos }
--: (string, integer | nil) -> (TlvNode | nil, string | nil)
function M.decode_tlv(data, pos)
  pos = pos or 1
  local data_len = slen(data)
  if pos > data_len then
    return nil, "no data at pos " .. pos
  end

  -- ── Tag byte(s) ──
  local tag_byte = (byte(data, pos) or 0) --[[:! integer]]
  local class_num   = band(rshift(tag_byte, 6), 0x03)
  local constructed = band(tag_byte, 0x20) ~= 0
  local tag_num     = band(tag_byte, 0x1f)
  pos = pos + 1

  -- Long-form tag (tag_num == 31 signals continuation bytes)
  if tag_num == 31 then
    tag_num = 0
    repeat
      if pos > data_len then
        return nil, "unexpected end of data in long-form tag"
      end
      local b = (byte(data, pos) or 0) --[[:! integer]]
      pos = pos + 1
      tag_num = tag_num * 128 + band(b, 0x7f)
      if band(b, 0x80) == 0 then break end
    until false
  end

  -- ── Length ──
  if pos > data_len then
    return nil, "unexpected end of data before length"
  end
  local len_byte = (byte(data, pos) or 0) --[[:! integer]]
  pos = pos + 1
  local vlen = 0
  if band(len_byte, 0x80) == 0 then
    -- Short form
    vlen = len_byte
  else
    local num_bytes = band(len_byte, 0x7f)
    if num_bytes == 0 then
      return nil, "indefinite length not supported in DER"
    end
    if num_bytes > 4 then
      return nil, "length field too long: " .. num_bytes .. " bytes"
    end
    vlen = 0
    for _ = 1, num_bytes do
      if pos > data_len then
        return nil, "unexpected end of data in length field"
      end
      vlen = vlen * 256 + ((byte(data, pos) or 0) --[[:! integer]])
      pos = pos + 1
    end
  end

  -- ── Value ──
  local end_pos = pos + vlen - 1
  if end_pos > data_len then
    return nil, "value extends beyond data (need " .. vlen
      .. " bytes at pos " .. pos .. ", have " .. (data_len - pos + 1) .. ")"
  end
  local value = (vlen > 0) and sub(data, pos, end_pos) or ""
  local next_pos = pos + vlen

  return {
    tag         = tag_num,
    class       = CLASS_NAME[class_num] or "unknown",
    class_num   = class_num,
    constructed = constructed,
    value       = value,
    length      = vlen,
    next_pos    = next_pos,
  }, nil
end

-- Parse a sequence of TLVs from data[pos..end_pos].
-- pos defaults to 1, end_pos defaults to slen(data).
-- Returns: array of TLV nodes, nil  OR  nil, errmsg
--: (string, integer | nil, integer | nil) -> ({ [integer]: TlvNode } | nil, string | nil)
function M.decode_sequence(data, pos, end_pos)
  pos = pos or 1
  end_pos = end_pos or slen(data)
  local result = {}
  while pos <= end_pos do
    local node, err = M.decode_tlv(data, pos)
    if not node then return nil, err end
    result[#result + 1] = node
    pos = node.next_pos
  end
  return result, nil
end

-- ── Typed decoders ────────────────────────────────────────────────────────────

-- Decode INTEGER value bytes → Lua number (or "0x..." hex string for large).
function M.decode_integer(value_bytes)
  if slen(value_bytes) == 0 then
    return nil, "empty INTEGER value"
  end
  local first = (byte(value_bytes, 1) or 0) --[[:! integer]]
  local negative = band(first, 0x80) ~= 0
  local n = 0 --: number
  if negative then
    -- Two's complement: each byte inverted, then +1 at the end, then negated.
    for i = 1, slen(value_bytes) do
      n = n * 256 + bxor((byte(value_bytes, i) or 0) --[[:! integer]], 0xff)
    end
    n = -(n + 1)
  else
    for i = 1, slen(value_bytes) do
      n = n * 256 + ((byte(value_bytes, i) or 0) --[[:! integer]])
    end
  end
  -- 2^53 boundary for safe integer representation
  local n_ = n --[[:! number]]
  if n_ > 9007199254740992 or n_ < -9007199254740992 then
    local hex = {}
    for i = 1, slen(value_bytes) do
      hex[i] = string.format("%02x", (byte(value_bytes, i) or 0) --[[:! integer]])
    end
    return "0x" .. concat(hex), nil
  end
  return n_, nil
end

-- Decode BOOLEAN value bytes → true | false
function M.decode_boolean(value_bytes)
  if slen(value_bytes) ~= 1 then
    return nil, "BOOLEAN value must be exactly 1 byte"
  end
  return byte(value_bytes, 1) ~= 0, nil
end

-- Decode OID value bytes → dotted-decimal string "1.2.840.113549.1.1.11"
function M.decode_oid(value_bytes)
  local vlen = slen(value_bytes)
  if vlen == 0 then
    return nil, "empty OID value"
  end
  local first = byte(value_bytes, 1)
  -- First byte encodes first two components: 40*c1 + c2
  -- c1 can only be 0, 1, or 2.  For c1=2, c2 may exceed 39.
  local c1, c2
  if first < 40 then
    c1, c2 = 0, first
  elseif first < 80 then
    c1, c2 = 1, first - 40
  else
    c1, c2 = 2, first - 80
  end
  local parts = { c1, c2 }
  local i = 2
  while i <= vlen do
    local val = 0
    repeat
      if i > vlen then
        return nil, "unexpected end of data in OID component"
      end
      local b = byte(value_bytes, i)
      i = i + 1
      val = val * 128 + band(b, 0x7f)
      if band(b, 0x80) == 0 then break end
    until false
    parts[#parts + 1] = val
  end
  return concat(parts, "."), nil
end

-- Decode BIT STRING value bytes → { bits=binary_string, unused_bits=n }
function M.decode_bit_string(value_bytes)
  if slen(value_bytes) == 0 then
    return nil, "empty BIT STRING value"
  end
  local unused = byte(value_bytes, 1)
  if unused > 7 then
    return nil, "unused bits count out of range: " .. unused
  end
  return { bits = sub(value_bytes, 2), unused_bits = unused }, nil
end

-- Decode any string type (UTF8String, PrintableString, IA5String, etc.)
-- DER string types are raw bytes; just return them as a Lua string.
function M.decode_string(value_bytes)
  return value_bytes, nil
end

-- Decode UTCTime or GeneralizedTime → ISO 8601 string "2023-01-01T00:00:00Z"
function M.decode_time(value_bytes, tag)
  local s = value_bytes
  if tag == M.TAG_UTCTIME then
    -- YYMMDDHHMMSSZ  (or YYMMDDHHMMSS±HHMM, simplified to Z-only here)
    local yy = tonumber(sub(s, 1, 2))
    if not yy then return nil, "invalid UTCTime: " .. s end
    local yy_ = (yy or 0) --[[:! number]]
    local year = (yy_ >= 50) and (1900 + yy_) or (2000 + yy_)
    return string.format("%04d-%s-%sT%s:%s:%sZ",
      year, sub(s, 3, 4), sub(s, 5, 6),
      sub(s, 7, 8), sub(s, 9, 10), sub(s, 11, 12)), nil
  elseif tag == M.TAG_GENERALIZEDTIME then
    -- YYYYMMDDHHMMSSZ
    return string.format("%s-%s-%sT%s:%s:%sZ",
      sub(s, 1, 4), sub(s, 5, 6), sub(s, 7, 8),
      sub(s, 9, 10), sub(s, 11, 12), sub(s, 13, 14)), nil
  else
    return nil, "not a time tag: " .. tostring(tag)
  end
end

-- ── High-level decode dispatcher ─────────────────────────────────────────────

local TYPE_NAME = {
  [1]  = "boolean",
  [2]  = "integer",
  [3]  = "bit_string",
  [4]  = "octet_string",
  [5]  = "null",
  [6]  = "oid",
  [12] = "utf8string",
  [16] = "sequence",
  [17] = "set",
  [19] = "printablestring",
  [22] = "ia5string",
  [23] = "utctime",
  [24] = "generalizedtime",
}

-- Decode one TLV and dispatch value bytes to a typed decoder.
-- Returns: { type, value, raw, tag, class, constructed, length, next_pos }
function M.decode(data, pos)
  local node, err = M.decode_tlv(data, pos)
  if not node then return nil, err end

  local type_name     = "unknown"
  local decoded_value = node.value
  local t             = node.tag

  if node.class == "universal" then
    type_name = TYPE_NAME[t] or ("tag_" .. t)
    local v, e
    if     t == M.TAG_BOOLEAN then
      v, e = M.decode_boolean(node.value)
      if v == nil and e then return nil, e end
      decoded_value = v
    elseif t == M.TAG_INTEGER then
      v, e = M.decode_integer(node.value)
      if v == nil then return nil, e end
      decoded_value = v
    elseif t == M.TAG_BIT_STRING then
      v, e = M.decode_bit_string(node.value)
      if not v then return nil, e end
      decoded_value = v
    elseif t == M.TAG_OID then
      v, e = M.decode_oid(node.value)
      if not v then return nil, e end
      decoded_value = v
    elseif t == M.TAG_NULL then
      decoded_value = nil
    elseif t == M.TAG_SEQUENCE or t == M.TAG_SET then
      v, e = M.decode_sequence(node.value)
      if not v then return nil, e end
      decoded_value = v
    elseif t == M.TAG_UTCTIME or t == M.TAG_GENERALIZEDTIME then
      v, e = M.decode_time(node.value, t)
      if not v then return nil, e end
      decoded_value = v
    elseif t == M.TAG_UTF8STRING or t == M.TAG_PRINTABLESTRING
        or t == M.TAG_IA5STRING then
      decoded_value = node.value
    elseif t == M.TAG_OCTET_STRING then
      decoded_value = node.value
    end
  end

  return {
    type        = type_name,
    value       = decoded_value,
    raw         = node.value,
    tag         = t,
    class       = node.class,
    constructed = node.constructed,
    length      = node.length,
    next_pos    = node.next_pos,
  }, nil
end

-- ── ENCODING ─────────────────────────────────────────────────────────────────

-- Encode raw TLV: tag_num, class_num, constructed flag, value bytes.
function M.encode_tlv(tag_num, class_num, constructed, value_bytes)
  value_bytes = value_bytes or ""
  local tag_bytes
  if tag_num <= 30 then
    local first = bor(lshift(class_num, 6), constructed and 0x20 or 0, tag_num)
    tag_bytes = char(first)
  else
    -- Long-form tag: first byte has low 5 bits = 0x1f
    local first = bor(lshift(class_num, 6), constructed and 0x20 or 0, 0x1f)
    local chunk = {}
    local n = tag_num
    chunk[1] = band(n, 0x7f)
    n = floor(n / 128)
    while n > 0 do
      table.insert(chunk, 1, bor(band(n, 0x7f), 0x80))
      n = floor(n / 128)
    end
    local cs = {}
    for _, b in ipairs(chunk) do cs[#cs + 1] = char(b) end
    tag_bytes = char(first) .. concat(cs)
  end
  return tag_bytes .. encode_length(slen(value_bytes)) .. value_bytes
end

-- Encode NULL
function M.encode_null()
  return "\x05\x00"
end

-- Encode BOOLEAN
function M.encode_boolean(b)
  return "\x01\x01" .. (b and "\xff" or "\x00")
end

-- Encode INTEGER (Lua number or hex string "0x...")
function M.encode_integer(n)
  local bytes = {} --: { [integer]: integer }

  if type(n) == "string" then
    -- Hex string "0x..." → raw big-endian bytes
    local n_ = n --[[:! string]]
    local hex = (n_:match("^0[xX](.+)$") or n_) --[[:! string]]
    if #hex % 2 ~= 0 then hex = "0" .. hex end
    for i = 1, #hex, 2 do
      local chunk = "0x" .. sub(hex, i, i + 1)
      bytes[#bytes + 1] = math.floor(tonumber(chunk) or 0) --[[:! integer]]
    end
    -- Strip leading zeros (but keep at least one byte)
    while #bytes > 1 and bytes[1] == 0 and band(bytes[2] --[[:! integer]], 0x80) == 0 do
      table.remove(bytes, 1)
    end
    -- Ensure positive: prepend 0x00 if high bit set
    if band(bytes[1] --[[:! integer]], 0x80) ~= 0 then
      table.insert(bytes, 1, 0x00)
    end
  else
    local v = floor(n)
    if v == 0 then
      bytes = { 0 }
    elseif v > 0 then
      while v > 0 do
        table.insert(bytes, 1, band(v, 0xff))
        v = floor(v / 256)
      end
      -- Prepend 0x00 if high bit is set (would look negative)
      if band(bytes[1], 0x80) ~= 0 then
        table.insert(bytes, 1, 0x00)
      end
    else
      -- Negative: two's complement
      -- Work with magnitude, build bytes, then invert+add-carry
      local magnitude = -v
      while magnitude > 0 do
        table.insert(bytes, 1, band(magnitude, 0xff))
        magnitude = floor(magnitude / 256)
      end
      -- Two's complement: flip all bits then add 1
      local carry = 1
      for i = #bytes, 1, -1 do
        local val = bxor(bytes[i], 0xff) + carry
        bytes[i] = band(val, 0xff)
        carry = rshift(val, 8)
      end
      -- If high bit is not set after complement, the number
      -- would be interpreted as positive — prepend 0xff
      if band(bytes[1], 0x80) == 0 then
        table.insert(bytes, 1, 0xff)
      end
    end
  end

  local vchars = {}
  for i, b in ipairs(bytes) do vchars[i] = char(b) end
  return M.encode_tlv(M.TAG_INTEGER, M.CLASS_UNIVERSAL, false, concat(vchars))
end

-- Encode OCTET STRING
function M.encode_octet_string(bytes)
  return M.encode_tlv(M.TAG_OCTET_STRING, M.CLASS_UNIVERSAL, false, bytes)
end

-- Encode UTF8String
function M.encode_utf8_string(s)
  return M.encode_tlv(M.TAG_UTF8STRING, M.CLASS_UNIVERSAL, false, s)
end

-- Encode SEQUENCE from array of already-encoded DER items
function M.encode_sequence(items)
  local body = concat(items)
  return M.encode_tlv(M.TAG_SEQUENCE, M.CLASS_UNIVERSAL, true, body)
end

-- Encode OID from dotted-decimal string "1.2.840.113549.1.1.11"
function M.encode_oid(oid_string)
  local parts = {} --: { [integer]: number }
  for part in oid_string:gmatch("[^.]+") do
    local pn = tonumber(part)
    if not pn then
      return nil, "invalid OID component: " .. part
    end
    parts[#parts + 1] = pn
  end
  if #parts < 2 then
    return nil, "OID must have at least two components"
  end

  local buf = {} --: { [integer]: any }
  -- First two components: combined as 40*c1 + c2
  buf[#buf + 1] = char(math.floor(parts[1] * 40 + parts[2]) --[[:! integer]])

  -- Remaining components: base-128 big-endian, MSB set on all but last byte
  for i = 3, #parts do
    local v = math.floor(parts[i]) --[[:! integer]]
    if v == 0 then
      buf[#buf + 1] = char(0)
    else
      local chunk = {} --: { [integer]: integer }
      chunk[1] = band(v, 0x7f)
      v = floor(v / 128) --[[:! integer]]
      while v > 0 do
        table.insert(chunk, 1, bor(band(v, 0x7f), 0x80))
        v = floor(v / 128)
      end
      for _, b in ipairs(chunk) do
        buf[#buf + 1] = char(b)
      end
    end
  end

  local value = concat(buf)
  return M.encode_tlv(M.TAG_OID, M.CLASS_UNIVERSAL, false, value), nil
end

return M
