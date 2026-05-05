-- lib/cbor/init.lua
-- CBOR (Concise Binary Object Representation) encoder and decoder (RFC 7049).
--
-- Public API:
--   M.encode(value)        → string | (nil, errmsg)
--   M.decode(data)         → value | (nil, errmsg)
--   M.bytes(s)             → cbor_bytes  (wraps string as byte string, major type 2)
--   M.is_bytes(v)          → boolean
--   M._tier                → "pure"
--
-- Codec aliases:
--   M.cbor_to_string = M.encode   (Lua value → binary CBOR string)
--   M.string_to_cbor = M.decode   (binary CBOR string → Lua value)
--
-- Note on nil: CBOR null (0xf6) decodes to Lua nil. M.decode returns (nil, nil)
-- on success when the value is null, and (nil, errmsg) on error.
-- Callers that need to distinguish null from error should check the second return.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ── Byte string wrapper ────────────────────────────────────────────────────────

local bytes_mt = { __name = "cbor.bytes" }

function M.bytes(s)
  return setmetatable({ s = s }, bytes_mt)
end

function M.is_bytes(v)
  return type(v) == "table" and getmetatable(v) == bytes_mt
end

-- ── Float64 pack/unpack ───────────────────────────────────────────────────────
-- Big-endian IEEE 754 double. Uses LuaJIT FFI when available.

local pack_f64, unpack_f64

local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then
  ffi.cdef[[
    typedef union { double d; uint8_t b[8]; } cbor_f64_u;
  ]]
  local u = ffi.new("cbor_f64_u")

  pack_f64 = function(n)
    u.d = n
    return string.char(
      u.b[7], u.b[6], u.b[5], u.b[4],
      u.b[3], u.b[2], u.b[1], u.b[0]
    )
  end

  --: (string, integer) -> number
  unpack_f64 = function(data, pos)
    u.b[7] = string.byte(data, pos)
    u.b[6] = string.byte(data, pos+1)
    u.b[5] = string.byte(data, pos+2)
    u.b[4] = string.byte(data, pos+3)
    u.b[3] = string.byte(data, pos+4)
    u.b[2] = string.byte(data, pos+5)
    u.b[1] = string.byte(data, pos+6)
    u.b[0] = string.byte(data, pos+7)
    return u.d
  end

else
  -- Pure Lua fallback using manual IEEE 754 decomposition.
  pack_f64 = function(n)
    if n ~= n then
      -- canonical quiet NaN
      return "\x7f\xf8\x00\x00\x00\x00\x00\x00"
    end
    local sign = 0
    if n < 0 or (n == 0 and 1/n < 0) then sign = 1; n = -n end
    if n == math.huge then
      return string.char(0x7f + sign * 0x80, 0xf0, 0, 0, 0, 0, 0, 0)
    end
    if n == 0 then
      return string.char(sign * 0x80, 0, 0, 0, 0, 0, 0, 0)
    end

    local exp = math.floor(math.log(n) / math.log(2))
    local mant = n / (2^exp) - 1
    mant = math.max(mant, 0)
    if mant >= 1 then mant = mant - 1; exp = exp + 1 end
    exp = exp + 1023  -- bias

    local m52 = mant * (2^52)

    local b1 = sign * 0x80 + math.floor(exp / 16)
    local b2 = (exp % 16) * 16 + math.floor(m52 / (2^48))
    local m48 = m52 % (2^48)
    local b3 = math.floor(m48 / (2^40)) % 256
    local b4 = math.floor(m48 / (2^32)) % 256
    local b5 = math.floor(m48 / (2^24)) % 256
    local b6 = math.floor(m48 / (2^16)) % 256
    local b7 = math.floor(m48 / (2^8))  % 256
    local b8 = m48 % 256

    return string.char(b1, b2, b3, b4, b5, b6, b7, b8)
  end

  --: (string, integer) -> number
  unpack_f64 = function(data, pos)
    local b1, b2, b3, b4 = string.byte(data, pos, pos+3)
    local b5, b6, b7, b8 = string.byte(data, pos+4, pos+7)
    local _b1 = b1 or 0 --[[:! integer]]
    local _b2 = b2 or 0 --[[:! integer]]
    local _b3 = b3 or 0 --[[:! integer]]
    local _b4 = b4 or 0 --[[:! integer]]
    local _b5 = b5 or 0 --[[:! integer]]
    local _b6 = b6 or 0 --[[:! integer]]
    local _b7 = b7 or 0 --[[:! integer]]
    local _b8 = b8 or 0 --[[:! integer]]
    local sign = math.floor(_b1 / 0x80)
    local exp  = (_b1 % 0x80) * 16 + math.floor(_b2 / 16)
    local mant = (_b2 % 16) * (2^48)
      + _b3 * (2^40) + _b4 * (2^32)
      + _b5 * (2^24) + _b6 * (2^16)
      + _b7 * (2^8)  + _b8
    mant = mant / (2^52)
    if exp == 0x7ff then
      if mant ~= 0 then return 0/0 end
      return sign == 1 and -math.huge or math.huge
    end
    if exp == 0 then
      local v = mant * (2^(-1022))
      return sign == 1 and -v or v
    end
    local v = (1 + mant) * (2^(exp - 1023))
    return sign == 1 and -v or v
  end
end

-- ── Encoder helpers ────────────────────────────────────────────────────────────

-- Encode CBOR head: major type (0-7) + unsigned argument n.
local function encode_head(major, n)
  local mt = major * 32
  if n <= 23 then
    return string.char(mt + n)
  elseif n <= 0xff then
    return string.char(mt + 24, n)
  elseif n <= 0xffff then
    return string.char(mt + 25, math.floor(n / 256), n % 256)
  elseif n <= 0xffffffff then
    local b4 = n % 256; n = math.floor(n / 256)
    local b3 = n % 256; n = math.floor(n / 256)
    local b2 = n % 256
    local b1 = math.floor(n / 256)
    return string.char(mt + 26, b1, b2, b3, b4)
  else
    local lo = n % (2^32)
    local hi = math.floor(n / (2^32))
    local lo4 = lo % 256; lo = math.floor(lo / 256)
    local lo3 = lo % 256; lo = math.floor(lo / 256)
    local lo2 = lo % 256
    local lo1 = math.floor(lo / 256)
    local hi4 = hi % 256; hi = math.floor(hi / 256)
    local hi3 = hi % 256; hi = math.floor(hi / 256)
    local hi2 = hi % 256
    local hi1 = math.floor(hi / 256)
    return string.char(mt + 27, hi1, hi2, hi3, hi4, lo1, lo2, lo3, lo4)
  end
end

local encode_value  -- forward declaration

local function is_array(t)
  local n = #t
  local count = 0
  for _ in pairs(t) do count = count + 1 end
  return count == n
end

encode_value = function(v)
  local t = type(v)
  if v == nil then
    return "\xf6"  -- null
  elseif t == "boolean" then
    return v and "\xf5" or "\xf4"
  elseif t == "number" then
    if v == v and v == math.floor(v) and v >= -(2^53) and v <= 2^53 then
      -- integer
      if v >= 0 then
        return encode_head(0, v)
      else
        return encode_head(1, -1 - v)
      end
    else
      return "\xfb" .. pack_f64(v)
    end
  elseif t == "string" then
    return encode_head(3, #v) .. v
  elseif t == "table" then
    if M.is_bytes(v) then
      local s = v.s
      return encode_head(2, #s) .. s
    elseif is_array(v) then
      local parts = { encode_head(4, #v) }
      for i = 1, #v do
        local enc, err = encode_value(v[i])
        if err then return nil, err end
        parts[#parts+1] = enc
      end
      return table.concat(parts)
    else
      -- map
      local keys = {}
      for k in pairs(v) do keys[#keys+1] = k end
      table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then return ta < tb end
        return tostring(a) < tostring(b)
      end)
      local parts = { encode_head(5, #keys) }
      for _, k in ipairs(keys) do
        local ek, err1 = encode_value(k)
        if err1 then return nil, err1 end
        local ev, err2 = encode_value(v[k])
        if err2 then return nil, err2 end
        parts[#parts+1] = ek
        parts[#parts+1] = ev
      end
      return table.concat(parts)
    end
  else
    return nil, "cbor.encode: unsupported type: " .. t
  end
end

-- ── Public encoder ─────────────────────────────────────────────────────────────

function M.encode(value)
  return encode_value(value)
end

-- ── Decoder internals ─────────────────────────────────────────────────────────
--
-- decode_value(data, pos) returns one of:
--   (value, new_pos)     — success; new_pos is a number
--   (nil, errmsg)        — error; errmsg is a string
--   (nil, new_pos)       — CBOR null/undefined decoded as nil; new_pos is a number
--
-- To distinguish null-success from error, callers check: type(second) == "number"

local decode_value  -- forward declaration

-- Read argument value from additional-info field.
-- Returns (arg, new_pos) or (nil, errmsg).
-- For indefinite length, returns (-1, pos).
--: (string, integer, integer) -> (number | nil, integer | string)
local function read_arg(data, info, pos)
  if info <= 23 then
    return info, pos
  elseif info == 24 then
    if pos > #data then return nil, "cbor.decode: truncated" end
    local byte1 = string.byte(data, pos) or 0
    return byte1 --[[:! integer]], pos + 1
  elseif info == 25 then
    if pos + 1 > #data then return nil, "cbor.decode: truncated" end
    local hi, _ = string.byte(data, pos, pos)
    local lo, __ = string.byte(data, pos+1, pos+1)
    hi = (hi or 0) --[[:! integer]]
    lo = (lo or 0) --[[:! integer]]
    return hi * 256 + lo, pos + 2
  elseif info == 26 then
    if pos + 3 > #data then return nil, "cbor.decode: truncated" end
    local b1, b2, b3, b4 = string.byte(data, pos, pos+3)
    local _b1 = b1 or 0 --[[:! integer]]
    local _b2 = b2 or 0 --[[:! integer]]
    local _b3 = b3 or 0 --[[:! integer]]
    local _b4 = b4 or 0 --[[:! integer]]
    return ((_b1 * 256 + _b2) * 256 + _b3) * 256 + _b4, pos + 4
  elseif info == 27 then
    if pos + 7 > #data then return nil, "cbor.decode: truncated" end
    local b1, b2, b3, b4 = string.byte(data, pos, pos+3)
    local b5, b6, b7, b8 = string.byte(data, pos+4, pos+7)
    local _b1 = b1 or 0 --[[:! integer]]
    local _b2 = b2 or 0 --[[:! integer]]
    local _b3 = b3 or 0 --[[:! integer]]
    local _b4 = b4 or 0 --[[:! integer]]
    local _b5 = b5 or 0 --[[:! integer]]
    local _b6 = b6 or 0 --[[:! integer]]
    local _b7 = b7 or 0 --[[:! integer]]
    local _b8 = b8 or 0 --[[:! integer]]
    local hi = ((_b1 * 256 + _b2) * 256 + _b3) * 256 + _b4
    local lo = ((_b5 * 256 + _b6) * 256 + _b7) * 256 + _b8
    return hi * (2^32) + lo, pos + 8
  elseif info == 31 then
    return -1, pos  -- indefinite length
  else
    return nil, "cbor.decode: reserved additional info: " .. info
  end
end

--: (string, integer) -> (unknown, integer | string | nil)
decode_value = function(data, pos)
  if pos > #data then
    return nil, "cbor.decode: unexpected end of input"
  end

  local b = string.byte(data, pos) or 0
  local major = math.floor(b / 32)
  local info  = b % 32
  pos = pos + 1

  if major == 0 then
    -- unsigned integer
    local arg, npos = read_arg(data, info, pos)
    if npos == nil then return nil, arg end
    arg = arg --[[:! integer]]  -- arg is errmsg
    return arg, npos

  elseif major == 1 then
    -- negative integer: value = -1 - arg
    local arg, npos = read_arg(data, info, pos)
    if npos == nil then return nil, arg end
    arg = arg --[[:! integer]]
    return -1 - arg, npos

  elseif major == 2 then
    -- byte string
    local arg, npos = read_arg(data, info, pos)
    if npos == nil then return nil, arg end
    arg = arg --[[:! integer]]
    pos = npos --[[:! integer]]
    if arg == -1 then
      -- indefinite length byte string
      local chunks = {}
      while true do
        if pos > #data then return nil, "cbor.decode: unterminated indefinite byte string" end
        if string.byte(data, pos) == 0xff then
          pos = pos + 1; break
        end
        local chunk, cpos = decode_value(data, pos)
        if type(cpos) ~= "number" then return nil, cpos end  -- cpos is errmsg
        if not M.is_bytes(chunk) then
          return nil, "cbor.decode: non-byte-string chunk in indefinite byte string"
        end
        chunks[#chunks+1] = chunk.s
        pos = cpos --[[:! integer]]
      end
      return M.bytes(table.concat(chunks)), pos
    end
    if pos + arg - 1 > #data then return nil, "cbor.decode: truncated byte string" end
    return M.bytes(string.sub(data, pos, pos + arg - 1)), pos + arg

  elseif major == 3 then
    -- text string
    local arg, npos = read_arg(data, info, pos)
    if npos == nil then return nil, arg end
    arg = arg --[[:! integer]]
    pos = npos --[[:! integer]]
    if arg == -1 then
      local chunks = {}
      while true do
        if pos > #data then return nil, "cbor.decode: unterminated indefinite text string" end
        if string.byte(data, pos) == 0xff then
          pos = pos + 1; break
        end
        local chunk, cpos = decode_value(data, pos)
        if type(cpos) ~= "number" then return nil, cpos end
        if type(chunk) ~= "string" then
          return nil, "cbor.decode: non-string chunk in indefinite text string"
        end
        chunks[#chunks+1] = chunk
        pos = cpos --[[:! integer]]
      end
      return table.concat(chunks), pos
    end
    if pos + arg - 1 > #data then return nil, "cbor.decode: truncated text string" end
    return string.sub(data, pos, pos + arg - 1), pos + arg

  elseif major == 4 then
    -- array
    local arg, npos = read_arg(data, info, pos)
    if npos == nil then return nil, arg end
    arg = arg --[[:! integer]]
    pos = npos --[[:! integer]]
    local arr = {}
    if arg == -1 then
      while true do
        if pos > #data then return nil, "cbor.decode: unterminated indefinite array" end
        if string.byte(data, pos) == 0xff then
          pos = pos + 1; break
        end
        local v, vpos = decode_value(data, pos)
        if type(vpos) ~= "number" then return nil, vpos end
        arr[#arr+1] = v  -- v may be nil (CBOR null); that's valid
        pos = vpos --[[:! integer]]
      end
    else
      for _ = 1, arg do
        local v, vpos = decode_value(data, pos)
        if type(vpos) ~= "number" then return nil, vpos end
        arr[#arr+1] = v
        pos = vpos --[[:! integer]]
      end
    end
    return arr, pos

  elseif major == 5 then
    -- map
    local arg, npos = read_arg(data, info, pos)
    if npos == nil then return nil, arg end
    arg = arg --[[:! integer]]
    pos = npos --[[:! integer]]
    local map = {}
    local function read_pair()
      local k, kpos = decode_value(data, pos)
      if type(kpos) ~= "number" then return nil, kpos end
      pos = kpos --[[:! integer]]
      local v, vpos = decode_value(data, pos)
      if type(vpos) ~= "number" then return nil, vpos end
      pos = vpos --[[:! integer]]
      -- byte string keys: use the raw string as map key
      if M.is_bytes(k) then k = k.s end
      map[k] = v
      return true
    end
    if arg == -1 then
      while true do
        if pos > #data then return nil, "cbor.decode: unterminated indefinite map" end
        if string.byte(data, pos) == 0xff then
          pos = pos + 1; break
        end
        local ok, err = read_pair()
        if not ok then return nil, err end
      end
    else
      for _ = 1, arg do
        local ok, err = read_pair()
        if not ok then return nil, err end
      end
    end
    return map, pos

  elseif major == 6 then
    -- tagged value — skip tag, return inner value
    local _, npos = read_arg(data, info, pos)
    if npos == nil then return nil, _ end
    return decode_value(data, npos)

  elseif major == 7 then
    -- float / simple
    if info == 20 then return false, pos
    elseif info == 21 then return true, pos
    elseif info == 22 then return nil, pos   -- null → nil; pos is number, signals success
    elseif info == 23 then return nil, pos   -- undefined → nil
    elseif info == 25 then
      -- float16: 2 bytes already available via read_arg
      local arg, npos = read_arg(data, info, pos)
      if npos == nil then return nil, arg end
      arg = arg --[[:! integer]]
    arg = arg --[[:! integer]]
      local sign16 = math.floor(arg / (2^15))
      local exp16  = math.floor(arg / (2^10)) % 32
      local mant16 = arg % (2^10)
      local v
      if exp16 == 31 then
        v = mant16 ~= 0 and (0/0) or math.huge
      elseif exp16 == 0 then
        v = mant16 * (2^(-24))
      else
        v = (1 + mant16 / (2^10)) * (2^(exp16 - 15))
      end
      if sign16 == 1 then v = -v end
      return v, npos
    elseif info == 26 then
      -- float32: reconstruct from 4-byte arg
      local arg, npos = read_arg(data, info, pos)
      if npos == nil then return nil, arg end
      arg = arg --[[:! integer]]
    arg = arg --[[:! integer]]
      local sign32 = math.floor(arg / (2^31)) % 2
      local exp32  = math.floor(arg / (2^23)) % 256
      local mant32 = arg % (2^23)
      local v
      if exp32 == 255 then
        v = mant32 ~= 0 and (0/0) or math.huge
      elseif exp32 == 0 then
        v = mant32 * (2^(-149))
      else
        v = (1 + mant32 / (2^23)) * (2^(exp32 - 127))
      end
      if sign32 == 1 then v = -v end
      return v, npos
    elseif info == 27 then
      -- float64: read 8 bytes
      if pos + 7 > #data then return nil, "cbor.decode: truncated float64" end
      local v = unpack_f64(data, pos)
      return v, pos + 8
    elseif info == 31 then
      return nil, "cbor.decode: unexpected break code"
    else
      -- simple value (0-19 inline or info==24 for extended)
      local arg, npos = read_arg(data, info, pos)
      if npos == nil then return nil, arg end
      arg = arg --[[:! integer]]
    arg = arg --[[:! integer]]
      return nil, "cbor.decode: unsupported simple value: " .. arg
    end
  end

  return nil, "cbor.decode: unknown major type: " .. major
end

-- ── Public decoder ────────────────────────────────────────────────────────────

function M.decode(data)
  if type(data) ~= "string" then
    return nil, "cbor.decode: expected string, got " .. type(data)
  end
  if #data == 0 then
    return nil, "cbor.decode: empty input"
  end

  local value, pos_or_err = decode_value(data, 1)
  -- Success: pos_or_err is a number.
  if type(pos_or_err) == "number" then
    return value  -- may be nil for CBOR null
  end
  -- Error: pos_or_err is a string.
  return nil, pos_or_err
end

-- Aliases
M.cbor_to_string = M.encode
M.string_to_cbor = M.decode

return M
