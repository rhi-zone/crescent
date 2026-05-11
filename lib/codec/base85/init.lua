-- lib/codec/base85/init.lua
-- Base85 encoding and decoding.
-- Supports RFC 1924, Z85 (ZeroMQ), and Ascii85 (Adobe/PDF) variants.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local byte, char, concat = string.byte, string.char, table.concat
local floor = math.floor
local band, bor, rshift, lshift, tobit

-- Use LuaJIT bit library if available, fall back to bit32, else pure math
if bit then
  band   = bit.band
  bor    = bit.bor
  rshift = bit.rshift
  lshift = bit.lshift
  tobit  = bit.tobit
elseif rawget(_G, "bit32") then
  local bit32 = rawget(_G, "bit32") --[[: unknown]]
  band   = bit32.band
  bor    = bit32.bor
  rshift = bit32.rshift
  lshift = bit32.lshift
  tobit  = function(n) return n % 0x100000000 end
else
  -- Pure math fallbacks (slow, avoids overflow with doubles)
  band = function(a, b)
    local r, p = 0, 1
    for _ = 1, 32 do
      local ab, bb = a % 2, b % 2
      if ab == 1 and bb == 1 then r = r + p end
      a, b = floor(a / 2), floor(b / 2)
      p = p * 2
    end
    return r
  end
  lshift = function(a, n) return a * 2^n end
  rshift = function(a, n) return floor(a / 2^n) end
  tobit  = function(n) return n % 0x100000000 end
end

-- ── Alphabets ─────────────────────────────────────────────────────────────────

-- RFC 1924: 0–9 A–Z a–z ! # $ % & ( ) * + - ; < = > ? @ ^ _ ` { | } ~
local RFC1924_ALPHA = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+-;<=>?@^_`{|}~"
-- Z85 (ZeroMQ): 0–9 a–z A–Z . - : + = ^ ! / * ? & < > ( ) [ ] { } @ % $ #
local Z85_ALPHA     = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?&<>()[]{}@%$#"
-- Ascii85: chars 33–117 (! through u), 85 characters
local ASCII85_ALPHA = "!\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstu"

local function make_enc_table(alpha)
  local t = {}
  for i = 1, 85 do
    t[i - 1] = byte(alpha, i)
  end
  return t
end

local function make_dec_table(alpha)
  local t = {}
  for i = 1, 85 do
    t[byte(alpha, i)] = i - 1
  end
  return t
end

local rfc1924_enc = make_enc_table(RFC1924_ALPHA)
local rfc1924_dec = make_dec_table(RFC1924_ALPHA)
local z85_enc     = make_enc_table(Z85_ALPHA)
local z85_dec     = make_dec_table(Z85_ALPHA)
local ascii85_enc = make_enc_table(ASCII85_ALPHA)
local ascii85_dec = make_dec_table(ASCII85_ALPHA)

-- ── Core encode/decode helpers ────────────────────────────────────────────────

-- Encode a 32-bit unsigned integer (as number) to 5 chars using enc_table.
-- Returns 5 bytes as individual values (for char()).
local function encode_group(v, enc)
  -- v must be treated as unsigned 32-bit: use tobit to keep in range,
  -- but we need unsigned division, so work with the raw value carefully.
  -- LuaJIT: bit operations sign-extend; use modulo arithmetic for unsigned.
  local v0 = v % 0x100000000  -- force unsigned interpretation as double
  local d4 = v0 % 85;         v0 = floor(v0 / 85)
  local d3 = v0 % 85;         v0 = floor(v0 / 85)
  local d2 = v0 % 85;         v0 = floor(v0 / 85)
  local d1 = v0 % 85;         v0 = floor(v0 / 85)
  local d0 = v0 % 85
  return enc[d0], enc[d1], enc[d2], enc[d3], enc[d4]
end

-- Read 4 bytes from string s at position i (1-based), return as uint32 double.
local function read_group(s, i)
  local a, b, c, d = byte(s, i, i + 3)
  return a * 0x1000000 + b * 0x10000 + c * 0x100 + d
end

-- Decode 5 chars at positions p..p+4 of string s using dec_table.
-- Returns uint32 as number, or nil + errmsg on invalid char.
--: (s: string, p: integer, dec: { [integer]: integer | nil }, variant: string) -> (integer | nil, string | nil)
local function decode_group(s, p, dec, variant)
  local v = 0
  for i = p, p + 4 do
    local c = byte(s, i)
    local d = dec[c]
    if d == nil then
      return nil, string.format(
        "%s.decode: invalid character '%s' at position %d",
        variant, c and char(c) or "?", i
      )
    end
    v = v * 85 + d
  end
  return v
end

-- ── RFC 1924 ──────────────────────────────────────────────────────────────────

--- Encode binary string to RFC 1924 Base85.
--- Input length must be a multiple of 4.
--: (s: string) -> string | (nil, string)
local function rfc1924_encode(s)
  if type(s) ~= "string" then
    return nil, "base85.encode: expected string"
  end
  local n = #s
  if n % 4 ~= 0 then
    return nil, "base85.encode: input length must be a multiple of 4"
  end
  local t = {}
  local k = 1
  for i = 1, n, 4 do
    local v = read_group(s, i)
    local c0, c1, c2, c3, c4 = encode_group(v, rfc1924_enc)
    t[k] = char(c0, c1, c2, c3, c4)
    k = k + 1
  end
  return concat(t)
end

--- Decode RFC 1924 Base85 string to binary.
--- Input length must be a multiple of 5.
--: (s: string) -> string | (nil, string)
local function rfc1924_decode(s)
  if type(s) ~= "string" then
    return nil, "base85.decode: expected string"
  end
  local n = #s
  if n % 5 ~= 0 then
    return nil, "base85.decode: input length must be a multiple of 5"
  end
  local t = {}
  local k = 1
  for i = 1, n, 5 do
    local v, err = decode_group(s, i, rfc1924_dec, "base85")
    if v == nil then return nil, err or "decode error" end
    if v > 0xffffffff then
      return nil, "base85.decode: group value out of range at position " .. i
    end
    t[k] = char(
      floor(v / 0x1000000) % 256,
      floor(v / 0x10000) % 256,
      floor(v / 0x100) % 256,
      v % 256
    )
    k = k + 1
  end
  return concat(t)
end

-- ── Z85 ───────────────────────────────────────────────────────────────────────

--- Encode binary string to Z85 (ZeroMQ) Base85.
--- Input length must be a multiple of 4.
--: (s: string) -> string | (nil, string)
local function z85_encode(s)
  if type(s) ~= "string" then
    return nil, "base85.z85_encode: expected string"
  end
  local n = #s
  if n % 4 ~= 0 then
    return nil, "base85.z85_encode: input length must be a multiple of 4"
  end
  local t = {}
  local k = 1
  for i = 1, n, 4 do
    local v = read_group(s, i)
    local c0, c1, c2, c3, c4 = encode_group(v, z85_enc)
    t[k] = char(c0, c1, c2, c3, c4)
    k = k + 1
  end
  return concat(t)
end

--- Decode Z85 (ZeroMQ) Base85 string to binary.
--- Input length must be a multiple of 5.
--: (s: string) -> string | (nil, string)
local function z85_decode(s)
  if type(s) ~= "string" then
    return nil, "base85.z85_decode: expected string"
  end
  local n = #s
  if n % 5 ~= 0 then
    return nil, "base85.z85_decode: input length must be a multiple of 5"
  end
  local t = {}
  local k = 1
  for i = 1, n, 5 do
    local v, err = decode_group(s, i, z85_dec, "base85.z85")
    if v == nil then return nil, err or "decode error" end
    if v > 0xffffffff then
      return nil, "base85.z85_decode: group value out of range at position " .. i
    end
    t[k] = char(
      floor(v / 0x1000000) % 256,
      floor(v / 0x10000) % 256,
      floor(v / 0x100) % 256,
      v % 256
    )
    k = k + 1
  end
  return concat(t)
end

-- ── Ascii85 ───────────────────────────────────────────────────────────────────

--- Encode binary string to Ascii85 (Adobe/PDF) with <~ ... ~> delimiters.
--- Handles partial final group; encodes four zero bytes as "z".
--: (s: string) -> string | (nil, string)
local function ascii85_encode(s)
  if type(s) ~= "string" then
    return nil, "base85.ascii85_encode: expected string"
  end
  local n = #s
  local t = { "<~" }
  local k = 2
  local full = n - (n % 4)

  -- Full 4-byte groups
  for i = 1, full, 4 do
    local v = read_group(s, i)
    if v == 0 then
      -- "z" shorthand for all-zero group
      t[k] = "z"
    else
      local c0, c1, c2, c3, c4 = encode_group(v, ascii85_enc)
      t[k] = char(c0, c1, c2, c3, c4)
    end
    k = k + 1
  end

  -- Partial final group (1–3 bytes)
  local tail = n % 4
  if tail > 0 then
    -- Read available bytes and pad with zeros
    local a = byte(s, full + 1) or 0
    local b = (tail >= 2) and (byte(s, full + 2) or 0) or 0
    local c = (tail >= 3) and (byte(s, full + 3) or 0) or 0
    local v = a * 0x1000000 + b * 0x10000 + c * 0x100
    local c0, c1, c2, c3, c4 = encode_group(v, ascii85_enc)
    -- Output tail+1 characters (drop excess)
    local chars = { c0, c1, c2, c3, c4 }
    local out = {}
    for i = 1, tail + 1 do out[i] = chars[i] end
    t[k] = char(unpack(out))
    k = k + 1
  end

  t[k] = "~>"
  return concat(t)
end

--- Decode Ascii85 (Adobe/PDF) string to binary.
--- Strips <~ ... ~> delimiters if present. Handles "z" shorthand.
--: (s: string) -> string | (nil, string)
local function ascii85_decode(s)
  if type(s) ~= "string" then
    return nil, "base85.ascii85_decode: expected string"
  end

  -- Strip delimiters
  local inner = s
  if s:sub(1, 2) == "<~" and s:sub(-2) == "~>" then
    inner = s:sub(3, -3)
  end

  local t = {}
  local k = 1
  local i = 1
  local n = #inner

  while i <= n do
    local c = byte(inner, i)

    -- Skip whitespace
    if c == 32 or c == 9 or c == 10 or c == 13 or c == 12 then
      i = i + 1

    -- "z" shorthand: four zero bytes
    elseif c == byte("z") then
      t[k] = "\0\0\0\0"
      k = k + 1
      i = i + 1

    else
      -- Collect up to 5 non-whitespace chars
      local group = {}
      local gi = 1
      while gi <= 5 and i <= n do
        local gc = byte(inner, i)
        -- Skip whitespace within group collection
        if gc == 32 or gc == 9 or gc == 10 or gc == 13 or gc == 12 then
          i = i + 1
        else
          group[gi] = gc
          gi = gi + 1
          i = i + 1
        end
      end

      local glen = #group
      if glen == 0 then break end

      if glen < 5 then
        -- Partial final group: pad with 'u' (value 84, the max digit)
        local partial_count = glen
        while glen < 5 do
          group[glen + 1] = byte("u")
          glen = glen + 1
        end
        -- Decode padded group
        local v = 0
        for j = 1, 5 do
          local d = ascii85_dec[group[j]]
          if d == nil then
            return nil, string.format(
              "base85.ascii85_decode: invalid character '%s'",
              char(group[j])
            )
          end
          v = v * 85 + d
        end
        if v > 0xffffffff then
          return nil, "base85.ascii85_decode: group value out of range"
        end
        -- Extract partial_count bytes
        local bytes = {
          floor(v / 0x1000000) % 256,
          floor(v / 0x10000) % 256,
          floor(v / 0x100) % 256,
          v % 256,
        }
        local out = {}
        for j = 1, partial_count - 1 do out[j] = bytes[j] end
        if partial_count - 1 > 0 then
          t[k] = char(unpack(out))
          k = k + 1
        end
      else
        -- Full 5-char group
        local v = 0
        for j = 1, 5 do
          local d = ascii85_dec[group[j]]
          if d == nil then
            return nil, string.format(
              "base85.ascii85_decode: invalid character '%s'",
              char(group[j])
            )
          end
          v = v * 85 + d
        end
        if v > 0xffffffff then
          return nil, "base85.ascii85_decode: group value out of range"
        end
        t[k] = char(
          floor(v / 0x1000000) % 256,
          floor(v / 0x10000) % 256,
          floor(v / 0x100) % 256,
          v % 256
        )
        k = k + 1
      end
    end
  end

  return concat(t)
end

-- ── Streaming encoder ─────────────────────────────────────────────────────────

--- Create a streaming RFC 1924 Base85 encoder.
--- Buffers partial groups; call finish() to flush and get the full result.
--: () -> { write: (self: unknown, s: string) -> nil, finish: (self: unknown) -> string }
local function encoder()
  --: Arr<string>
  local buf = {}
  local buf_len = 0
  --: Arr<string>
  local out = {}
  local out_k = 1

  local enc = {
    --- Feed bytes to the encoder.
    --: (self: unknown, s: string) -> nil
    write = function(self, s)
      -- Append to buffer
      buf[#buf + 1] = s
      buf_len = buf_len + #s

      -- Process complete 4-byte groups from buffer
      while buf_len >= 4 do
        -- Flatten buffer to get next 4 bytes
        local flat = concat(buf)
        buf = {}
        buf_len = #flat

        -- Encode all complete groups
        local complete = buf_len - (buf_len % 4)
        for i = 1, complete, 4 do
          local v = read_group(flat, i)
          local c0, c1, c2, c3, c4 = encode_group(v, rfc1924_enc)
          out[out_k] = char(c0, c1, c2, c3, c4)
          out_k = out_k + 1
        end

        -- Keep remainder in buffer
        if buf_len % 4 ~= 0 then
          buf[1] = flat:sub(complete + 1)
          buf_len = buf_len % 4
        else
          buf_len = 0
        end
        break
      end
    end,

    --- Flush any remaining bytes and return the full encoded string.
    --: (self: unknown) -> string
    finish = function(self)
      -- Flush remaining buffer bytes (should be 0–3 bytes, but RFC 1924 requires
      -- input divisible by 4, so remaining bytes are silently dropped here).
      -- If there are leftover bytes, they are NOT encoded (RFC 1924 requirement).
      return concat(out)
    end,
  }
  return enc
end

-- ── Exports ───────────────────────────────────────────────────────────────────

M.rfc1924_encode = rfc1924_encode
M.rfc1924_decode = rfc1924_decode
M.z85_encode     = z85_encode
M.z85_decode     = z85_decode
M.ascii85_encode = ascii85_encode
M.ascii85_decode = ascii85_decode
M.encoder        = encoder

-- Default encode/decode: RFC 1924
M.encode = rfc1924_encode
M.decode = rfc1924_decode

-- Codec convention aliases
M.string_to_base85 = rfc1924_encode
M.base85_to_string = rfc1924_decode

return M
