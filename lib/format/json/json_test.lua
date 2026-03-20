if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local json = require("lib.format.json")

T.describe("json.encode", function()
  T.it("encodes a string", function()
    local result, err = json.encode("hello")
    T.ok(err == nil, "no error")
    T.eq(result, '"hello"')
  end)

  T.it("encodes a number", function()
    local result, err = json.encode(42)
    T.ok(err == nil, "no error")
    T.eq(result, "42")
  end)

  T.it("encodes a float", function()
    local result, err = json.encode(3.14)
    T.ok(err == nil, "no error")
    T.ok(result ~= nil, "got result")
  end)

  T.it("encodes a boolean true", function()
    local result, err = json.encode(true)
    T.ok(err == nil, "no error")
    T.eq(result, "true")
  end)

  T.it("encodes a boolean false", function()
    local result, err = json.encode(false)
    T.ok(err == nil, "no error")
    T.eq(result, "false")
  end)

  T.it("encodes null sentinel", function()
    local result, err = json.encode(json.null)
    T.ok(err == nil, "no error")
    T.eq(result, "null")
  end)

  T.it("encodes an array table", function()
    local result, err = json.encode({1, 2, 3})
    T.ok(err == nil, "no error")
    T.eq(result, "[1,2,3]")
  end)

  T.it("encodes an object table", function()
    -- single key to avoid ordering issues
    local result, err = json.encode({key = "val"})
    T.ok(err == nil, "no error")
    T.eq(result, '{"key":"val"}')
  end)

  T.it("returns nil,err for invalid number (inf)", function()
    local result, err = json.encode(math.huge)
    T.eq(result, nil)
    T.ok(type(err) == "string", "err is a string")
  end)

  T.it("returns nil,err for non-string key", function()
    local t = {}
    t[1] = "x"
    -- force it to be seen as object by using a non-integer key alongside nil[1]
    -- simplest: a table with only numeric keys won't trigger that path,
    -- so use rawset with a non-string key on an object-shaped table
    local bad = {}
    rawset(bad, true, "v")
    local result, err = json.encode(bad)
    T.eq(result, nil)
    T.ok(type(err) == "string", "err is a string")
  end)

  T.it("_encode_raw throws on error", function()
    T.throws(function() json._encode_raw(math.huge) end)
  end)
end)

T.describe("json.decode", function()
  T.it("decodes a string", function()
    local result, err = json.decode('"hello"')
    T.ok(err == nil, "no error")
    T.eq(result, "hello")
  end)

  T.it("decodes a number", function()
    local result, err = json.decode("42")
    T.ok(err == nil, "no error")
    T.eq(result, 42)
  end)

  T.it("decodes a boolean", function()
    local result, err = json.decode("true")
    T.ok(err == nil, "no error")
    T.eq(result, true)
  end)

  T.it("decodes null", function()
    local result, err = json.decode("null")
    T.ok(err == nil, "no error")
    T.eq(result, json.null)
  end)

  T.it("decodes an array", function()
    local result, err = json.decode("[1,2,3]")
    T.ok(err == nil, "no error")
    T.eq(result[1], 1)
    T.eq(result[2], 2)
    T.eq(result[3], 3)
  end)

  T.it("decodes an object", function()
    local result, err = json.decode('{"key":"val"}')
    T.ok(err == nil, "no error")
    T.eq(result.key, "val")
  end)

  T.it("returns nil,err for truncated input", function()
    local result, err = json.decode('{"key":')
    T.eq(result, nil)
    T.ok(type(err) == "string", "err is a string")
  end)

  T.it("returns nil,err for invalid token", function()
    local result, err = json.decode("xyz")
    T.eq(result, nil)
    T.ok(type(err) == "string", "err is a string")
  end)

  T.it("returns nil,err for empty input", function()
    local result, err = json.decode("")
    T.eq(result, nil)
    T.ok(type(err) == "string", "err is a string")
  end)

  T.it("_decode_raw throws on error", function()
    T.throws(function() json._decode_raw("!!!") end)
  end)
end)

T.describe("json encode/decode round-trip", function()
  T.it("round-trips a nested structure", function()
    local val = {name = "alice", scores = {10, 20, 30}, active = true}
    local encoded, err1 = json.encode(val)
    T.ok(err1 == nil, "encode ok")
    local decoded, err2 = json.decode(encoded)
    T.ok(err2 == nil, "decode ok")
    T.eq(decoded.name, "alice")
    T.eq(decoded.active, true)
    T.eq(decoded.scores[2], 20)
  end)

  T.it("round-trips a string with escape chars", function()
    local val = "hello\nworld\t!"
    local encoded = json._encode_raw(val)
    local decoded = json._decode_raw(encoded)
    T.eq(decoded, val)
  end)
end)
