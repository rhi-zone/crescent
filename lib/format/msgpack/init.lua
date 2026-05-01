if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- MessagePack encoder/decoder
-- https://github.com/msgpack/msgpack/blob/master/spec.md
-- Pure Lua implementation — no FFI needed.

local M = {}

local byte = string.byte
local char = string.char
local sub = string.sub
local concat = table.concat
local floor = math.floor
local huge = math.huge
local pairs = pairs
local ipairs = ipairs
local type = type
local tostring = tostring

-- IEEE 754 double → 8 bytes (big-endian)
local function encode_double(n)
  -- NaN
  if n ~= n then
    return char(0xcb, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff)
  end
  local sign = 0
  if n < 0 or (n == 0 and 1 / n < 0) then
    sign = 0x80
    n = -n
  end
  if n == huge then
    return char(0xcb, sign + 0x7f, 0xf0, 0, 0, 0, 0, 0, 0)
  end
  if n == 0 then
    return char(0xcb, sign, 0, 0, 0, 0, 0, 0, 0)
  end
  local frac, exp = math.frexp(n)
  frac = frac * 2 - 1 -- normalize to [0, 1)
  exp = exp - 1 + 1023 -- bias
  -- pack exponent (11 bits) + fraction (52 bits)
  local e_hi = floor(exp / 16)       -- top 7 bits of exponent
  local e_lo = (exp % 16) * 16       -- bottom 4 bits, shifted
  local f1 = frac * 2^52
  local b2 = e_lo + floor(f1 / 2^48) % 16
  f1 = f1 % 2^48
  local b3 = floor(f1 / 2^40) % 256
  local b4 = floor(f1 / 2^32) % 256
  local b5 = floor(f1 / 2^24) % 256
  local b6 = floor(f1 / 2^16) % 256
  local b7 = floor(f1 / 2^8) % 256
  local b8 = floor(f1) % 256
  return char(0xcb, sign + e_hi, b2, b3, b4, b5, b6, b7, b8)
end

-- 8 bytes big-endian → IEEE 754 double
--: (string, integer) -> number
local function decode_double(s, pos)
  local b1i = byte(s, pos)
  local b2i = byte(s, pos + 1)
  local b3i = byte(s, pos + 2)
  local b4i = byte(s, pos + 3)
  local b5i = byte(s, pos + 4)
  local b6i = byte(s, pos + 5)
  local b7i = byte(s, pos + 6)
  local b8i = byte(s, pos + 7)
  local sign = b1i >= 128 and -1 or 1
  local exp = (b1i % 128) * 16 + floor(b2i / 16)
  local frac = (b2i % 16) * 2^48 + b3i * 2^40 + b4i * 2^32
               + b5i * 2^24 + b6i * 2^16 + b7i * 2^8 + b8i
  if exp == 0 then
    if frac == 0 then return sign * 0.0 end
    return sign * math.ldexp(frac, -1074) -- subnormal
  elseif exp == 0x7ff then
    if frac == 0 then return sign * huge end
    return 0/0 -- NaN
  end
  return sign * math.ldexp(frac + 2^52, exp - 1075)
end

-- 4 bytes big-endian → IEEE 754 float
--: (string, integer) -> number
local function decode_float(s, pos)
  local b1i = byte(s, pos)
  local b2i = byte(s, pos + 1)
  local b3i = byte(s, pos + 2)
  local b4i = byte(s, pos + 3)
  local sign = b1i >= 128 and -1 or 1
  local exp = (b1i % 128) * 2 + floor(b2i / 128)
  local frac = (b2i % 128) * 2^16 + b3i * 2^8 + b4i
  if exp == 0 then
    if frac == 0 then return sign * 0.0 end
    return sign * math.ldexp(frac, -149) -- subnormal
  elseif exp == 0xff then
    if frac == 0 then return sign * huge end
    return 0/0
  end
  return sign * math.ldexp(frac + 2^23, exp - 150)
end

-- Encode a 16-bit unsigned int as 2 big-endian bytes
--: (number) -> string
local function u16be(n)
  return char(floor(n / 256) % 256, n % 256)
end

-- Encode a 32-bit unsigned int as 4 big-endian bytes
--: (number) -> string
local function u32be(n)
  return char(floor(n / 2^24) % 256, floor(n / 2^16) % 256,
              floor(n / 2^8) % 256, n % 256)
end

-- Encode a 64-bit unsigned int as 8 big-endian bytes
local function u64be(n)
  local hi = floor(n / 2^32)
  local lo = n % 2^32
  return u32be(hi) .. u32be(lo)
end

-- Encode a signed 8-bit int
--: (number) -> string
local function i8(n)
  if n < 0 then n = n + 256 end
  return char(n % 256)
end

-- Encode a signed 16-bit int as 2 big-endian bytes
--: (number) -> string
local function i16be(n)
  if n < 0 then n = n + 65536 end
  return u16be(n)
end

-- Encode a signed 32-bit int as 4 big-endian bytes
--: (number) -> string
local function i32be(n)
  if n < 0 then n = n + 2^32 end
  return u32be(n)
end

-- Encode a signed 64-bit int as 8 big-endian bytes
-- Cannot simply add 2^64 — loses LSBs for values near -2^31.
-- Instead, split into hi:lo 32-bit words and two's-complement each.
local function i64be(n)
  if n >= 0 then return u64be(n) end
  -- For negative n: compute lo = n mod 2^32, hi = (n - lo) / 2^32
  -- Both in unsigned two's complement form.
  -- n = hi*2^32 + lo where 0 <= lo < 2^32
  local lo = n % 2^32       -- Lua % always returns non-negative for positive divisor
  local hi = (n - lo) / 2^32 -- negative or zero
  -- hi is negative (or zero if lo absorbed it all), convert to unsigned
  if hi < 0 then hi = hi + 2^32 end
  return u32be(hi) .. u32be(lo)
end

----------------------------------------------------------------
-- Encoder
----------------------------------------------------------------

local encode -- forward declaration

local function is_integer(n)
  return n == floor(n) and n ~= huge and n ~= -huge
end

-- Detect whether a table is an array (consecutive integer keys 1..n).
--: ({ [unknown]: unknown }) -> boolean
local function is_array(t)
  local n = #t
  -- Verify no keys outside 1..n
  local count = 0
  for _ in pairs(t) do
    count = count + 1
    if count > n then return false end
  end
  return count == n
end

local function encode_nil()
  return "\xc0"
end

local function encode_boolean(v)
  return v and "\xc3" or "\xc2"
end

--: (number) -> string
local function encode_integer(n)
  -- positive fixint: 0 to 127
  if n >= 0 and n <= 0x7f then
    return char(n)
  end
  -- negative fixint: -32 to -1
  if n >= -32 and n < 0 then
    return char(256 + n) -- 0xe0..0xff
  end
  -- uint8
  if n >= 0 and n <= 0xff then
    return "\xcc" .. char(n)
  end
  -- uint16
  if n >= 0 and n <= 0xffff then
    return "\xcd" .. u16be(n)
  end
  -- uint32
  if n >= 0 and n <= 0xffffffff then
    return "\xce" .. u32be(n)
  end
  -- uint64
  if n >= 0 then
    return "\xcf" .. u64be(n)
  end
  -- int8
  if n >= -128 then
    return "\xd0" .. i8(n)
  end
  -- int16
  if n >= -32768 then
    return "\xd1" .. i16be(n)
  end
  -- int32
  if n >= -2147483648 then
    return "\xd2" .. i32be(n)
  end
  -- int64
  return "\xd3" .. i64be(n)
end

--: (string) -> string
local function encode_string(s)
  local n = #s
  local prefix
  if n <= 31 then
    prefix = char(0xa0 + n) -- fixstr
  elseif n <= 0xff then
    prefix = "\xd9" .. char(n) -- str8
  elseif n <= 0xffff then
    prefix = "\xda" .. u16be(n) -- str16
  else
    prefix = "\xdb" .. u32be(n) -- str32
  end
  return prefix .. s
end

local function encode_array(t)
  local n = #t
  local prefix
  if n <= 15 then
    prefix = char(0x90 + n) -- fixarray
  elseif n <= 0xffff then
    prefix = "\xdc" .. u16be(n) -- array16
  else
    prefix = "\xdd" .. u32be(n) -- array32
  end
  local parts = { prefix }
  for i = 1, n do
    parts[i + 1] = encode(t[i])
  end
  return concat(parts)
end

local function encode_map(t)
  local parts = {}
  local count = 0
  for k, v in pairs(t) do
    count = count + 1
    parts[count * 2 - 1] = encode(k)
    parts[count * 2] = encode(v)
  end
  local prefix
  if count <= 15 then
    prefix = char(0x80 + count) -- fixmap
  elseif count <= 0xffff then
    prefix = "\xde" .. u16be(count) -- map16
  else
    prefix = "\xdf" .. u32be(count) -- map32
  end
  return prefix .. concat(parts)
end

local function encode_table(t)
  if is_array(t) then
    return encode_array(t)
  else
    return encode_map(t)
  end
end

--: (nil | boolean | number | string | { [unknown]: unknown }) -> string
encode = function(v)
  local tv = type(v)
  if tv == "nil" then
    return encode_nil()
  elseif tv == "boolean" then
    return encode_boolean(--[[:! boolean]] v)
  elseif tv == "number" then
    local vn = --[[:! number]] v
    if is_integer(vn) then
      return encode_integer(vn)
    else
      return encode_double(vn)
    end
  elseif tv == "string" then
    return encode_string(--[[:! string]] v)
  elseif tv == "table" then
    return encode_table(--[[:! { [unknown]: unknown }]] v)
  else
    error("msgpack: cannot encode type " .. tv)
  end
end

--: (nil | boolean | number | string | { [unknown]: unknown }) -> string
M.encode = encode

----------------------------------------------------------------
-- Decoder
----------------------------------------------------------------

local decode -- forward declaration

--: (string, number, number) -> (boolean | nil, string | nil)
local function check_len(s, pos, need)
  if pos + need - 1 > #s then
    return nil, "msgpack: unexpected end of input"
  end
  return true
end

decode = function(s, pos)
  pos = pos or 1
  pos = --[[:! integer]] pos
  if pos > #s then
    return nil, "msgpack: unexpected end of input"
  end

  local b = byte(s, pos)

  -- positive fixint: 0x00-0x7f
  if b <= 0x7f then
    return b, pos + 1
  end

  -- fixmap: 0x80-0x8f
  if b >= 0x80 and b <= 0x8f then
    local n = b - 0x80
    local t = {}
    local p = pos + 1
    for _ = 1, n do
      local k, v
      local err
      k, p = decode(s, p)
      if k == nil and type(p) == "string" then return nil, p end
      v, p = decode(s, p)
      if v == nil and type(p) == "string" then return nil, p end
      t[k] = v
    end
    return t, p
  end

  -- fixarray: 0x90-0x9f
  if b >= 0x90 and b <= 0x9f then
    local n = b - 0x90
    local t = {}
    local p = pos + 1
    for i = 1, n do
      local v, err
      v, p = decode(s, p)
      if v == nil and type(p) == "string" then return nil, p end
      t[i] = v
    end
    return t, p
  end

  -- fixstr: 0xa0-0xbf
  if b >= 0xa0 and b <= 0xbf then
    local n = b - 0xa0
    local ok, err = check_len(s, pos + 1, n)
    if not ok then return nil, err end
    return sub(s, pos + 1, pos + n), pos + 1 + n
  end

  -- nil
  if b == 0xc0 then return nil, pos + 1 end

  -- (never used) 0xc1
  if b == 0xc1 then return nil, "msgpack: invalid format byte 0xc1" end

  -- false
  if b == 0xc2 then return false, pos + 1 end

  -- true
  if b == 0xc3 then return true, pos + 1 end

  -- bin8
  if b == 0xc4 then
    local ok, err = check_len(s, pos + 1, 1)
    if not ok then return nil, err end
    local n = byte(s, pos + 1)
    ok, err = check_len(s, pos + 2, n)
    if not ok then return nil, err end
    return sub(s, pos + 2, pos + 1 + n), pos + 2 + n
  end

  -- bin16
  if b == 0xc5 then
    local ok, err = check_len(s, pos + 1, 2)
    if not ok then return nil, err end
    local _b1 = byte(s, pos + 1)
    local _b2 = byte(s, pos + 2)
    local n = _b1 * 256 + _b2
    ok, err = check_len(s, pos + 3, n)
    if not ok then return nil, err end
    return sub(s, pos + 3, pos + 2 + n), pos + 3 + n
  end

  -- bin32
  if b == 0xc6 then
    local ok, err = check_len(s, pos + 1, 4)
    if not ok then return nil, err end
    local _b1 = byte(s, pos + 1)
    local _b2 = byte(s, pos + 2)
    local _b3 = byte(s, pos + 3)
    local _b4 = byte(s, pos + 4)
    local n = floor(_b1 * 2^24 + _b2 * 2^16 + _b3 * 2^8 + _b4)
    ok, err = check_len(s, pos + 5, n)
    if not ok then return nil, err end
    return sub(s, pos + 5, pos + 4 + n), pos + 5 + n
  end

  -- ext8, ext16, ext32, fixext1/2/4/8/16 (0xc7-0xc9, 0xd4-0xd8)
  -- Not implemented in v1; skip with error
  if (b >= 0xc7 and b <= 0xc9) or (b >= 0xd4 and b <= 0xd8) then
    return nil, "msgpack: ext types not supported"
  end

  -- float32
  if b == 0xca then
    local ok, err = check_len(s, pos + 1, 4)
    if not ok then return nil, err end
    return decode_float(s, pos + 1), pos + 5
  end

  -- float64
  if b == 0xcb then
    local ok, err = check_len(s, pos + 1, 8)
    if not ok then return nil, err end
    return decode_double(s, pos + 1), pos + 9
  end

  -- uint8
  if b == 0xcc then
    local ok, err = check_len(s, pos + 1, 1)
    if not ok then return nil, err end
    return byte(s, pos + 1), pos + 2
  end

  -- uint16
  if b == 0xcd then
    local ok, err = check_len(s, pos + 1, 2)
    if not ok then return nil, err end
    local _u1 = byte(s, pos + 1)
    local _u2 = byte(s, pos + 2)
    return _u1 * 256 + _u2, pos + 3
  end

  -- uint32
  if b == 0xce then
    local ok, err = check_len(s, pos + 1, 4)
    if not ok then return nil, err end
    local _u1 = byte(s, pos + 1)
    local _u2 = byte(s, pos + 2)
    local _u3 = byte(s, pos + 3)
    local _u4 = byte(s, pos + 4)
    return _u1 * 2^24 + _u2 * 2^16 + _u3 * 2^8 + _u4, pos + 5
  end

  -- uint64
  if b == 0xcf then
    local ok, err = check_len(s, pos + 1, 8)
    if not ok then return nil, err end
    local _u1 = byte(s, pos + 1)
    local _u2 = byte(s, pos + 2)
    local _u3 = byte(s, pos + 3)
    local _u4 = byte(s, pos + 4)
    local _u5 = byte(s, pos + 5)
    local _u6 = byte(s, pos + 6)
    local _u7 = byte(s, pos + 7)
    local _u8 = byte(s, pos + 8)
    return _u1 * 2^56 + _u2 * 2^48 + _u3 * 2^40 + _u4 * 2^32
         + _u5 * 2^24 + _u6 * 2^16 + _u7 * 2^8 + _u8, pos + 9
  end

  -- int8
  if b == 0xd0 then
    local ok, err = check_len(s, pos + 1, 1)
    if not ok then return nil, err end
    local v = byte(s, pos + 1)
    if v >= 128 then v = v - 256 end
    return v, pos + 2
  end

  -- int16
  if b == 0xd1 then
    local ok, err = check_len(s, pos + 1, 2)
    if not ok then return nil, err end
    local _i1 = byte(s, pos + 1)
    local _i2 = byte(s, pos + 2)
    local v = _i1 * 256 + _i2
    if v >= 32768 then v = v - 65536 end
    return v, pos + 3
  end

  -- int32
  if b == 0xd2 then
    local ok, err = check_len(s, pos + 1, 4)
    if not ok then return nil, err end
    local _i1 = byte(s, pos + 1)
    local _i2 = byte(s, pos + 2)
    local _i3 = byte(s, pos + 3)
    local _i4 = byte(s, pos + 4)
    local v = _i1 * 2^24 + _i2 * 2^16 + _i3 * 2^8 + _i4
    if v >= 2^31 then v = v - 2^32 end
    return v, pos + 5
  end

  -- int64
  -- Split into hi:lo 32-bit halves to avoid double precision loss.
  -- Accumulating all 8 bytes loses the LSB for values near -(2^31).
  if b == 0xd3 then
    local ok, err = check_len(s, pos + 1, 8)
    if not ok then return nil, err end
    local _i1 = byte(s, pos + 1)
    local _i2 = byte(s, pos + 2)
    local _i3 = byte(s, pos + 3)
    local _i4 = byte(s, pos + 4)
    local _i5 = byte(s, pos + 5)
    local _i6 = byte(s, pos + 6)
    local _i7 = byte(s, pos + 7)
    local _i8 = byte(s, pos + 8)
    local hi = _i1 * 2^24 + _i2 * 2^16 + _i3 * 2^8 + _i4
    local lo = _i5 * 2^24 + _i6 * 2^16 + _i7 * 2^8 + _i8
    -- Sign-extend: if hi >= 2^31, the number is negative
    if hi >= 2^31 then
      hi = hi - 2^32
    end
    return hi * 2^32 + lo, pos + 9
  end

  -- str8
  if b == 0xd9 then
    local ok, err = check_len(s, pos + 1, 1)
    if not ok then return nil, err end
    local n = byte(s, pos + 1)
    ok, err = check_len(s, pos + 2, n)
    if not ok then return nil, err end
    return sub(s, pos + 2, pos + 1 + n), pos + 2 + n
  end

  -- str16
  if b == 0xda then
    local ok, err = check_len(s, pos + 1, 2)
    if not ok then return nil, err end
    local _s1 = byte(s, pos + 1)
    local _s2 = byte(s, pos + 2)
    local n = _s1 * 256 + _s2
    ok, err = check_len(s, pos + 3, n)
    if not ok then return nil, err end
    return sub(s, pos + 3, pos + 2 + n), pos + 3 + n
  end

  -- str32
  if b == 0xdb then
    local ok, err = check_len(s, pos + 1, 4)
    if not ok then return nil, err end
    local _s1 = byte(s, pos + 1)
    local _s2 = byte(s, pos + 2)
    local _s3 = byte(s, pos + 3)
    local _s4 = byte(s, pos + 4)
    local n = floor(_s1 * 2^24 + _s2 * 2^16 + _s3 * 2^8 + _s4)
    ok, err = check_len(s, pos + 5, n)
    if not ok then return nil, err end
    return sub(s, pos + 5, pos + 4 + n), pos + 5 + n
  end

  -- array16
  if b == 0xdc then
    local ok, err = check_len(s, pos + 1, 2)
    if not ok then return nil, err end
    local _a1 = byte(s, pos + 1)
    local _a2 = byte(s, pos + 2)
    local n = _a1 * 256 + _a2
    local t = {}
    local p = pos + 3
    for i = 1, n do
      local v
      v, p = decode(s, p)
      if v == nil and type(p) == "string" then return nil, p end
      t[i] = v
    end
    return t, p
  end

  -- array32
  if b == 0xdd then
    local ok, err = check_len(s, pos + 1, 4)
    if not ok then return nil, err end
    local _a1 = byte(s, pos + 1)
    local _a2 = byte(s, pos + 2)
    local _a3 = byte(s, pos + 3)
    local _a4 = byte(s, pos + 4)
    local n = _a1 * 2^24 + _a2 * 2^16 + _a3 * 2^8 + _a4
    local t = {}
    local p = pos + 5
    for i = 1, n do
      local v
      v, p = decode(s, p)
      if v == nil and type(p) == "string" then return nil, p end
      t[i] = v
    end
    return t, p
  end

  -- map16
  if b == 0xde then
    local ok, err = check_len(s, pos + 1, 2)
    if not ok then return nil, err end
    local _m1 = byte(s, pos + 1)
    local _m2 = byte(s, pos + 2)
    local n = _m1 * 256 + _m2
    local t = {}
    local p = pos + 3
    for _ = 1, n do
      local k, v
      k, p = decode(s, p)
      if k == nil and type(p) == "string" then return nil, p end
      v, p = decode(s, p)
      if v == nil and type(p) == "string" then return nil, p end
      t[k] = v
    end
    return t, p
  end

  -- map32
  if b == 0xdf then
    local ok, err = check_len(s, pos + 1, 4)
    if not ok then return nil, err end
    local _m1 = byte(s, pos + 1)
    local _m2 = byte(s, pos + 2)
    local _m3 = byte(s, pos + 3)
    local _m4 = byte(s, pos + 4)
    local n = _m1 * 2^24 + _m2 * 2^16 + _m3 * 2^8 + _m4
    local t = {}
    local p = pos + 5
    for _ = 1, n do
      local k, v
      k, p = decode(s, p)
      if k == nil and type(p) == "string" then return nil, p end
      v, p = decode(s, p)
      if v == nil and type(p) == "string" then return nil, p end
      t[k] = v
    end
    return t, p
  end

  -- negative fixint: 0xe0-0xff
  if b >= 0xe0 then
    return b - 256, pos + 1
  end

  return nil, "msgpack: unknown format byte 0x" .. string.format("%02x", b)
end

--: (string, number | nil) -> (any, number | string)
M.decode = decode

return M
