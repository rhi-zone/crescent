if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local msgpack = require("lib.format.msgpack")

local function deep_eq(a, b)
  if a == b then return true end
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then
    if a ~= a and b ~= b then return true end -- NaN
    return false
  end
  for k, v in pairs(a) do
    if not deep_eq(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function roundtrip(v, msg)
  local packed = msgpack.encode(v)
  local decoded, pos = msgpack.decode(packed)
  T.ok(deep_eq(decoded, v), msg or ("roundtrip: " .. tostring(v)))
  T.eq(pos, #packed + 1, "pos after decode should be len+1")
  return packed
end

local function roundtrip_num(v, msg)
  local packed = msgpack.encode(v)
  local decoded, pos = msgpack.decode(packed)
  -- For NaN, decoded ~= decoded
  if v ~= v then
    T.ok(decoded ~= decoded, msg or "roundtrip NaN")
  else
    T.eq(decoded, v, msg or ("roundtrip: " .. tostring(v)))
  end
  T.eq(pos, #packed + 1, "pos after decode")
  return packed
end

T.describe("msgpack nil", function()
  T.it("encodes/decodes nil", function()
    local packed = msgpack.encode(nil)
    T.eq(packed, "\xc0")
    local val, pos = msgpack.decode(packed)
    T.eq(val, nil)
    T.eq(pos, 2)
  end)
end)

T.describe("msgpack booleans", function()
  T.it("encodes/decodes true", function()
    roundtrip_num(true, "true")
  end)

  T.it("encodes/decodes false", function()
    local packed = msgpack.encode(false)
    T.eq(packed, "\xc2")
    local val, pos = msgpack.decode(packed)
    T.eq(val, false)
    T.eq(pos, 2)
  end)
end)

T.describe("msgpack integers", function()
  T.it("positive fixint", function()
    local p = roundtrip_num(0, "zero")
    T.eq(#p, 1, "fixint 0 is 1 byte")
    T.eq(string.byte(p), 0)

    roundtrip_num(1, "one")
    roundtrip_num(127, "127")
    local p127 = msgpack.encode(127)
    T.eq(#p127, 1, "fixint 127 is 1 byte")
    T.eq(string.byte(p127), 127)
  end)

  T.it("negative fixint", function()
    roundtrip_num(-1, "-1")
    roundtrip_num(-32, "-32")
    local pm1 = msgpack.encode(-1)
    T.eq(#pm1, 1, "fixint -1 is 1 byte")
    T.eq(string.byte(pm1), 0xff)
    local pm32 = msgpack.encode(-32)
    T.eq(#pm32, 1, "fixint -32 is 1 byte")
    T.eq(string.byte(pm32), 0xe0)
  end)

  T.it("uint8", function()
    roundtrip_num(128, "128")
    roundtrip_num(255, "255")
    local p = msgpack.encode(128)
    T.eq(string.byte(p, 1), 0xcc, "uint8 prefix")
  end)

  T.it("uint16", function()
    roundtrip_num(256, "256")
    roundtrip_num(65535, "65535")
    local p = msgpack.encode(256)
    T.eq(string.byte(p, 1), 0xcd, "uint16 prefix")
  end)

  T.it("uint32", function()
    roundtrip_num(65536, "65536")
    roundtrip_num(2^32 - 1, "2^32-1")
    local p = msgpack.encode(65536)
    T.eq(string.byte(p, 1), 0xce, "uint32 prefix")
  end)

  T.it("uint64", function()
    roundtrip_num(2^32, "2^32")
    local p = msgpack.encode(2^32)
    T.eq(string.byte(p, 1), 0xcf, "uint64 prefix")
  end)

  T.it("int8", function()
    roundtrip_num(-33, "-33")
    roundtrip_num(-128, "-128")
    local p = msgpack.encode(-33)
    T.eq(string.byte(p, 1), 0xd0, "int8 prefix")
  end)

  T.it("int16", function()
    roundtrip_num(-129, "-129")
    roundtrip_num(-32768, "-32768")
    local p = msgpack.encode(-129)
    T.eq(string.byte(p, 1), 0xd1, "int16 prefix")
  end)

  T.it("int32", function()
    roundtrip_num(-32769, "-32769")
    roundtrip_num(-2^31, "-2^31")
    local p = msgpack.encode(-32769)
    T.eq(string.byte(p, 1), 0xd2, "int32 prefix")
  end)

  T.it("int64", function()
    roundtrip_num(-2^31 - 1, "-2^31-1")
    local p = msgpack.encode(-2^31 - 1)
    T.eq(string.byte(p, 1), 0xd3, "int64 prefix")
  end)
end)

T.describe("msgpack floats", function()
  T.it("float64 values", function()
    roundtrip_num(0.0, "0.0")
    roundtrip_num(1.5, "1.5")
    roundtrip_num(-1.5, "-1.5")
  end)

  T.it("infinity", function()
    roundtrip_num(math.huge, "inf")
    roundtrip_num(-math.huge, "-inf")
  end)

  T.it("NaN", function()
    roundtrip_num(0/0, "NaN")
  end)
end)

T.describe("msgpack strings", function()
  T.it("empty string", function()
    local p = roundtrip("", "empty string")
    T.eq(#p, 1, "empty fixstr is 1 byte")
    T.eq(string.byte(p, 1), 0xa0)
  end)

  T.it("fixstr", function()
    roundtrip("hello", "fixstr hello")
    local p = msgpack.encode("hello")
    T.eq(string.byte(p, 1), 0xa0 + 5, "fixstr prefix")
  end)

  T.it("str8", function()
    local s = string.rep("x", 32)
    roundtrip(s, "str8 32 bytes")
    local p = msgpack.encode(s)
    T.eq(string.byte(p, 1), 0xd9, "str8 prefix")

    local s2 = string.rep("y", 255)
    roundtrip(s2, "str8 255 bytes")
  end)

  T.it("str16", function()
    local s = string.rep("z", 256)
    roundtrip(s, "str16 256 bytes")
    local p = msgpack.encode(s)
    T.eq(string.byte(p, 1), 0xda, "str16 prefix")
  end)

  T.it("str32", function()
    local s = string.rep("w", 65536)
    roundtrip(s, "str32 65536 bytes")
    local p = msgpack.encode(s)
    T.eq(string.byte(p, 1), 0xdb, "str32 prefix")
  end)
end)

T.describe("msgpack arrays", function()
  T.it("empty array", function()
    local p = roundtrip({}, "empty array")
    T.eq(#p, 1, "empty fixarray is 1 byte")
    T.eq(string.byte(p, 1), 0x90)
  end)

  T.it("fixarray", function()
    roundtrip({1, 2, 3}, "small array")
    roundtrip({1, "hello", true, false}, "mixed array")
  end)

  T.it("nested arrays", function()
    roundtrip({{1, 2}, {3, 4}}, "nested arrays")
    roundtrip({{{}}}, "deeply nested")
  end)

  T.it("array with nil encoded explicitly", function()
    -- msgpack can encode nil in arrays, but Lua tables lose trailing nils
    -- Just verify encode doesn't crash
    local packed = msgpack.encode({1, 2, 3})
    T.ok(#packed > 0)
  end)
end)

T.describe("msgpack maps", function()
  T.it("empty map encodes as empty array", function()
    -- {} in Lua has #t == 0 and no pairs, so is_array returns true → fixarray
    local p = msgpack.encode({})
    T.eq(string.byte(p, 1), 0x90, "empty table → fixarray 0")
  end)

  T.it("string-keyed map", function()
    local t = { a = 1, b = 2 }
    local packed = msgpack.encode(t)
    local decoded, pos = msgpack.decode(packed)
    T.ok(deep_eq(decoded, t), "string-keyed map roundtrip")
  end)

  T.it("nested map", function()
    local t = { x = { y = 42 } }
    local packed = msgpack.encode(t)
    local decoded = msgpack.decode(packed)
    T.ok(deep_eq(decoded, t), "nested map roundtrip")
  end)

  T.it("mixed key types", function()
    local t = { [1] = "one", hello = "world" }
    local packed = msgpack.encode(t)
    local decoded = msgpack.decode(packed)
    T.ok(deep_eq(decoded, t), "mixed key map roundtrip")
  end)
end)

T.describe("msgpack streaming decode", function()
  T.it("returns correct position after decode", function()
    local a = msgpack.encode(42)
    local b = msgpack.encode("hi")
    local combined = a .. b
    local v1, pos = msgpack.decode(combined, 1)
    T.eq(v1, 42)
    local v2, pos2 = msgpack.decode(combined, pos)
    T.eq(v2, "hi")
    T.eq(pos2, #combined + 1)
  end)
end)

T.describe("msgpack error cases", function()
  T.it("truncated input", function()
    local val, err = msgpack.decode("")
    T.eq(val, nil)
    T.ok(type(err) == "string", "error is a string")
  end)

  T.it("truncated uint16", function()
    local val, err = msgpack.decode("\xcd\x01") -- needs 2 bytes, only 1
    T.eq(val, nil)
    T.ok(err:find("unexpected end"), "truncated uint16")
  end)

  T.it("invalid format byte 0xc1", function()
    local val, err = msgpack.decode("\xc1")
    T.eq(val, nil)
    T.ok(err:find("0xc1"), "mentions 0xc1")
  end)
end)

T.describe("msgpack complex roundtrip", function()
  T.it("complex nested structure", function()
    local t = {
      name = "test",
      version = 1,
      tags = {"lua", "msgpack"},
      nested = {
        flag = true,
        values = {1, -1, 0, 255, 65536, -32768},
      },
    }
    local packed = msgpack.encode(t)
    local decoded = msgpack.decode(packed)
    T.ok(deep_eq(decoded, t), "complex roundtrip")
  end)
end)
