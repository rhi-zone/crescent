if not package.path:find("./?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

--- Create a codec from an encode/decode table.
--: (t: { encode: (unknown) -> unknown, decode: (unknown) -> unknown }) -> { encode: (unknown) -> unknown, decode: (unknown) -> unknown }
local function new(t)
  if not t then return nil, "codec: expected table" end
  if not t.encode then return nil, "codec: missing encode function" end
  if not t.decode then return nil, "codec: missing decode function" end
  return { encode = t.encode, decode = t.decode }
end
M.new = new

--- Create a codec from two functions.
--: (encode_fn: (unknown) -> unknown, decode_fn: (unknown) -> unknown) -> { encode: (unknown) -> unknown, decode: (unknown) -> unknown }
local function from(encode_fn, decode_fn)
  if not encode_fn then return nil, "codec: missing encode function" end
  if not decode_fn then return nil, "codec: missing decode function" end
  return { encode = encode_fn, decode = decode_fn }
end
M.from = from

--- Chain codecs: encode left-to-right, decode right-to-left.
--: (...{ encode: (unknown) -> unknown, decode: (unknown) -> unknown }) -> { encode: (unknown) -> unknown, decode: (unknown) -> unknown }
local function chain(...)
  local codecs = { ... }
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
--: (predicate: (unknown) -> boolean, codec: { encode: (unknown) -> unknown, decode: (unknown) -> unknown }) -> { encode: (unknown) -> unknown, decode: (unknown) -> unknown }
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
--: (encode_fn: (unknown) -> unknown, decode_fn: (unknown) -> unknown) -> { encode: (unknown) -> unknown, decode: (unknown) -> unknown }
local function map(encode_fn, decode_fn)
  if not encode_fn then return nil, "codec.map: missing encode function" end
  if not decode_fn then return nil, "codec.map: missing decode function" end
  return { encode = encode_fn, decode = decode_fn }
end
M.map = map

--- Test whether decode(encode(data)) == data.
--: (codec: { encode: (unknown) -> unknown, decode: (unknown) -> unknown }, data: unknown) -> boolean
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
M.identity = {
  encode = function(data) return data end,
  decode = function(data) return data end,
}

--- Hex codec: encode bytes to hex string, decode hex string to bytes.
M.hex = {
  encode = function(s)
    if type(s) ~= "string" then return nil, "codec.hex.encode: expected string" end
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
  end,
  decode = function(s)
    if type(s) ~= "string" then return nil, "codec.hex.decode: expected string" end
    if #s % 2 ~= 0 then return nil, "codec.hex.decode: odd-length hex string" end
    if s:find("[^%x]") then return nil, "codec.hex.decode: invalid hex character" end
    return (s:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
  end,
}

--- ROT13 codec: rotate ASCII letters by 13 positions. Self-inverse.
local function rot13_char(c)
  local b = c:byte()
  if b >= 65 and b <= 90 then return string.char((b - 65 + 13) % 26 + 65) end
  if b >= 97 and b <= 122 then return string.char((b - 97 + 13) % 26 + 97) end
  return c
end

local function rot13_fn(s)
  if type(s) ~= "string" then return nil, "codec.rot13: expected string" end
  return (s:gsub(".", rot13_char))
end

M.rot13 = {
  encode = rot13_fn,
  decode = rot13_fn,
}

--- Reverse codec: reverse the string.
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
--: (key: number) -> { encode: (string) -> string, decode: (string) -> string }
local function xor(key)
  if type(key) ~= "number" then return nil, "codec.xor: expected number key" end
  key = key % 256
  -- Use bit.bxor if available (LuaJIT), otherwise bit32 (PUC Lua 5.2+), otherwise pure fallback
  local bxor
  if bit then
    bxor = bit.bxor
  elseif bit32 then
    bxor = bit32.bxor
  end
  if bxor then
    local function xor_fn_fast(s)
      if type(s) ~= "string" then return nil, "codec.xor: expected string" end
      local t = {}
      for i = 1, #s do
        t[i] = string.char(bxor(s:byte(i), key))
      end
      return table.concat(t)
    end
    return { encode = xor_fn_fast, decode = xor_fn_fast }
  end
  -- Pure fallback: use lookup table
  local lookup = {}
  for i = 0, 255 do
    -- Manual XOR via decomposition
    local result = 0
    local a, b = i, key
    local p = 1
    for _ = 1, 8 do
      local a_bit = a % 2
      local b_bit = b % 2
      if a_bit ~= b_bit then result = result + p end
      a = (a - a_bit) / 2
      b = (b - b_bit) / 2
      p = p * 2
    end
    lookup[i] = string.char(result)
  end
  local function xor_fn_pure(s)
    if type(s) ~= "string" then return nil, "codec.xor: expected string" end
    local t = {}
    for i = 1, #s do
      t[i] = lookup[s:byte(i)]
    end
    return table.concat(t)
  end
  return { encode = xor_fn_pure, decode = xor_fn_pure }
end
M.xor = xor

return M
