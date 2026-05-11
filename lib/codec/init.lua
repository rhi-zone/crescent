if not package.path:find("./?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

--:: Codec = { encode: (unknown) -> unknown, decode: (unknown) -> unknown }

--- Create a codec from an encode/decode table.
--: (t: Codec) -> (Codec | nil, string | nil)
local function new(t)
  if not t then return nil, "codec: expected table" end
  if not t.encode then return nil, "codec: missing encode function" end
  if not t.decode then return nil, "codec: missing decode function" end
  local c = { encode = t.encode, decode = t.decode } --: Codec
  return c
end
M.new = new

--- Create a codec from two functions.
--: (encode_fn: (unknown) -> unknown, decode_fn: (unknown) -> unknown) -> (Codec | nil, string | nil)
local function from(encode_fn, decode_fn)
  if not encode_fn then return nil, "codec: missing encode function" end
  if not decode_fn then return nil, "codec: missing decode function" end
  local c = { encode = encode_fn, decode = decode_fn } --: Codec
  return c
end
M.from = from

--- Chain codecs: encode left-to-right, decode right-to-left.
--: (...Codec) -> (Codec | nil, string | nil)
local function chain(...)
  local codecs = { ... } --: { [integer]: Codec }
  local n = #codecs
  if n == 0 then return nil, "codec.chain: expected at least one codec" end
  if n == 1 then return codecs[1] end
  return {
    encode = function(data)
      local v = data
      for i = 1, n do
        local err
        v, err = codecs[i].encode(v)
        if v == nil then return nil, err end
      end
      return v
    end,
    decode = function(data)
      local v = data
      for i = n, 1, -1 do
        local err
        v, err = codecs[i].decode(v)
        if v == nil then return nil, err end
      end
      return v
    end,
  }
end
M.chain = chain

--- Conditional codec: apply only when predicate returns true, otherwise passthrough.
--: (predicate: (unknown) -> boolean, codec: Codec) -> (Codec | nil, string | nil)
local function when(predicate, codec)
  if not predicate then return nil, "codec.when: missing predicate" end
  if not codec then return nil, "codec.when: missing codec" end
  return {
    encode = function(data)
      if predicate(data) then return codec.encode(data) end
      return data
    end,
    decode = function(data)
      if predicate(data) then return codec.decode(data) end
      return data
    end,
  }
end
M.when = when

--- Map codec: transform with arbitrary functions.
--: (encode_fn: (unknown) -> unknown, decode_fn: (unknown) -> unknown) -> (Codec | nil, string | nil)
local function map(encode_fn, decode_fn)
  if not encode_fn then return nil, "codec.map: missing encode function" end
  if not decode_fn then return nil, "codec.map: missing decode function" end
  local c = { encode = encode_fn, decode = decode_fn } --: Codec
  return c
end
M.map = map

--- Test whether decode(encode(data)) == data.
--: (codec: Codec, data: unknown) -> (boolean, string | nil)
local function roundtrip(codec, data)
  local encoded, err = codec.encode(data)
  if encoded == nil then return false, err end
  local decoded
  decoded, err = codec.decode(encoded)
  if decoded == nil then return false, err end
  return decoded == data
end
M.roundtrip = roundtrip

--- Identity codec: passthrough.
--: Codec
M.identity = {
  encode = function(data) return data end,
  decode = function(data) return data end,
}

--- Hex codec: encode bytes to hex string, decode hex string to bytes.
--: Codec
M.hex = {
  encode = function(s)
    if type(s) ~= "string" then return nil, "codec.hex.encode: expected string" end
    return (s:gsub(".", function(c) return string.format("%02x", string.byte(c, 1)) end))
  end,
  decode = function(s)
    if type(s) ~= "string" then return nil, "codec.hex.decode: expected string" end
    if #s % 2 ~= 0 then return nil, "codec.hex.decode: odd-length hex string" end
    if s:find("[^%x]") then return nil, "codec.hex.decode: invalid hex character" end
    return (s:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
  end,
}

--- ROT13 codec: rotate ASCII letters by 13 positions. Self-inverse.
--: (string) -> string
local function rot13_char(c)
  local b = string.byte(c, 1) or 0
  if b >= 65 and b <= 90 then return string.char((b - 65 + 13) % 26 + 65) end
  if b >= 97 and b <= 122 then return string.char((b - 97 + 13) % 26 + 97) end
  return c
end

local function rot13_fn(s)
  if type(s) ~= "string" then return nil, "codec.rot13: expected string" end
  local rot13_char_ = rot13_char --[[:! (string) -> string | nil]]
  return (s:gsub(".", rot13_char_))
end

--: Codec
M.rot13 = {
  encode = rot13_fn,
  decode = rot13_fn,
}

--- Reverse codec: reverse the string.
--: Codec
M.reverse = {
  encode = function(s)
    if type(s) ~= "string" then return nil, "codec.reverse.encode: expected string" end
    return s:reverse()
  end,
  decode = function(s)
    if type(s) ~= "string" then return nil, "codec.reverse.decode: expected string" end
    return s:reverse()
  end,
}

--- XOR codec: XOR each byte with a key byte. Self-inverse.
--: (key: number) -> (Codec | nil, string | nil)
local function xor(key)
  if type(key) ~= "number" then return nil, "codec.xor: expected number key" end
  local key_ = (key % 256) --[[:! integer]]
  -- Use bit.bxor if available (LuaJIT), otherwise bit32 (PUC Lua 5.2+), otherwise pure fallback
  local ok_bit, bit_mod = pcall(require, "bit")
  local bxor_fn --: ((integer, integer) -> integer) | nil
  if ok_bit then
    bxor_fn = (bit_mod --[[: unknown]]).bxor --[[:! (integer, integer) -> integer]]
  else
    local ok_bit32, bit32_mod = pcall(require, "bit32")
    if ok_bit32 then
      bxor_fn = (bit32_mod --[[: unknown]]).bxor --[[:! (integer, integer) -> integer]]
    end
  end
  if bxor_fn then
    local bxor_ = bxor_fn --[[:! (integer, integer) -> integer]]
    local function xor_fn_fast(s)
      if type(s) ~= "string" then return nil, "codec.xor: expected string" end
      local t = {} --: { [integer]: string }
      for i = 1, #s do
        local b = (string.byte(s, i, i) or 0) --[[:! integer]]
        local xored = bxor_(b, key_) --: integer
        t[i] = string.char(xored)
      end
      return table.concat(t)
    end
    local c = { encode = xor_fn_fast --[[:! (unknown) -> unknown]], decode = xor_fn_fast --[[:! (unknown) -> unknown]] } --: Codec
    return c
  end
  -- Pure fallback: use lookup table
  local lookup = {} --: { [integer]: string }
  for i = 0, 255 do
    -- Manual XOR via decomposition
    local result = 0
    local a, b = i, key_
    local p = 1
    for _ = 1, 8 do
      local a_bit = a % 2
      local b_bit = b % 2
      if a_bit ~= b_bit then result = result + p end
      a = math.floor((a - a_bit) / 2)
      b = math.floor((b - b_bit) / 2)
      p = p * 2
    end
    lookup[i] = string.char(result)
  end
  local function xor_fn_pure(s)
    if type(s) ~= "string" then return nil, "codec.xor: expected string" end
    local t = {} --: { [integer]: string }
    for i = 1, #s do
      local b = (string.byte(s, i, i)) or 0 --[[:! integer]]
      t[i] = lookup[b]
    end
    return table.concat(t)
  end
  local c = { encode = xor_fn_pure --[[:! (unknown) -> unknown]], decode = xor_fn_pure --[[:! (unknown) -> unknown]] } --: Codec
  return c
end
M.xor = xor

return M
