if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local cbor = require("lib.format.cbor")

T.describe("cbor.encode", function()
  T.it("encodes an integer", function()
    local result, err = cbor.encode(42)
    T.ok(err == nil, "no error")
    T.ok(type(result) == "string", "got bytes")
  end)

  T.it("encodes a negative integer", function()
    local result, err = cbor.encode(-1)
    T.ok(err == nil, "no error")
    T.ok(type(result) == "string", "got bytes")
  end)

  T.it("encodes a float", function()
    local result, err = cbor.encode(3.14)
    T.ok(err == nil, "no error")
    T.ok(type(result) == "string", "got bytes")
  end)

  T.it("encodes a string", function()
    local result, err = cbor.encode("hello")
    T.ok(err == nil, "no error")
    T.ok(type(result) == "string", "got bytes")
  end)

  T.it("encodes a boolean true", function()
    local result, err = cbor.encode(true)
    T.ok(err == nil, "no error")
    T.eq(result, "\245")
  end)

  T.it("encodes a boolean false", function()
    local result, err = cbor.encode(false)
    T.ok(err == nil, "no error")
    T.eq(result, "\244")
  end)

  T.it("encodes nil", function()
    local result, err = cbor.encode(nil)
    T.ok(err == nil, "no error")
    T.ok(type(result) == "string", "got bytes")
  end)

  T.it("encodes an array table", function()
    local result, err = cbor.encode({1, 2, 3})
    T.ok(err == nil, "no error")
    T.ok(type(result) == "string", "got bytes")
  end)

  T.it("returns nil,err for function value", function()
    local result, err = cbor.encode(function() end)
    T.eq(result, nil)
    T.ok(type(err) == "string", "err is a string")
  end)

  T.it("_encode_raw throws on function value", function()
    T.throws(function() cbor._encode_raw(function() end) end)
  end)
end)

T.describe("cbor.decode", function()
  T.it("decodes an integer", function()
    local encoded = cbor._encode_raw(42)
    local result, err = cbor.decode(encoded)
    T.ok(err == nil, "no error")
    T.eq(result, 42)
  end)

  T.it("decodes a negative integer", function()
    local encoded = cbor._encode_raw(-5)
    local result, err = cbor.decode(encoded)
    T.ok(err == nil, "no error")
    T.eq(result, -5)
  end)

  T.it("decodes a string", function()
    local encoded = cbor._encode_raw("hello")
    local result, err = cbor.decode(encoded)
    T.ok(err == nil, "no error")
    T.eq(result, "hello")
  end)

  T.it("decodes boolean true", function()
    local encoded = cbor._encode_raw(true)
    local result, err = cbor.decode(encoded)
    T.ok(err == nil, "no error")
    T.eq(result, true)
  end)

  T.it("decodes boolean false", function()
    local encoded = cbor._encode_raw(false)
    local result, err = cbor.decode(encoded)
    T.ok(err == nil, "no error")
    T.eq(result, false)
  end)

  T.it("decodes an array", function()
    local encoded = cbor._encode_raw({10, 20, 30})
    local result, err = cbor.decode(encoded)
    T.ok(err == nil, "no error")
    T.eq(result[1], 10)
    T.eq(result[2], 20)
    T.eq(result[3], 30)
  end)

  T.it("returns nil,err for empty input", function()
    local result, err = cbor.decode("")
    T.eq(result, nil)
    T.ok(type(err) == "string", "err is a string")
  end)

  T.it("returns nil,err for truncated input", function()
    -- a 2-byte string header claiming length 4 but only 1 byte of data
    local result, err = cbor.decode("\x62\x41")
    T.eq(result, nil)
    T.ok(type(err) == "string", "err is a string")
  end)

  T.it("_decode_raw throws on empty input", function()
    T.throws(function() cbor._decode_raw("") end)
  end)
end)

T.describe("cbor encode/decode round-trip", function()
  T.it("round-trips integer zero", function()
    local v = 0
    local decoded = cbor._decode_raw(cbor._encode_raw(v))
    T.eq(decoded, v)
  end)

  T.it("round-trips large integer", function()
    local v = 1000000
    local decoded = cbor._decode_raw(cbor._encode_raw(v))
    T.eq(decoded, v)
  end)

  T.it("round-trips a string", function()
    local v = "round-trip test"
    local decoded = cbor._decode_raw(cbor._encode_raw(v))
    T.eq(decoded, v)
  end)

  T.it("round-trips an array via safe API", function()
    local v = {1, 2, 3}
    local encoded, err1 = cbor.encode(v)
    T.ok(err1 == nil, "encode ok")
    local decoded, err2 = cbor.decode(encoded)
    T.ok(err2 == nil, "decode ok")
    T.eq(decoded[1], 1)
    T.eq(decoded[2], 2)
    T.eq(decoded[3], 3)
  end)
end)
