-- lib/format/json/json_test.lua
-- Tests for the three-tier JSON library.
-- Covers: parity (pure == ffi), edge cases, error cases, round-trips,
-- and integration with the tier-selection init.lua.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local json = require("lib.format.json")
local pure = require("lib.format.json.pure")
local ffi  = require("lib.format.json.ffi")

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Deep equality for decoded JSON values (handles tables recursively).
local function deep_eq(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table"  then return a == b end
    for k, v in pairs(a) do
        if not deep_eq(v, b[k]) then return false end
    end
    for k, _ in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- Assert that pure and ffi produce identical encoded output for a value.
-- Pass json.null (the init.lua sentinel) so both tiers recognize it.
local function assert_encode_parity(label, v)
    local ps = pure._encode_raw(v, json.null)
    local fs = ffi._encode_raw(v, json.null)
    T.eq(ps, fs, label .. ": encode parity")
end

-- Assert that pure and ffi produce deep-equal decoded values for a string.
-- Use json.null as the shared null sentinel so both tiers return the same value.
local function assert_decode_parity(label, s)
    local pv = pure._decode_raw(s, json.null)
    local fv = ffi._decode_raw(s, json.null)
    T.ok(deep_eq(pv, fv), label .. ": decode parity (pure=" .. tostring(pv) .. " ffi=" .. tostring(fv) .. ")")
end

-- Assert both tiers error on the same input.
local function assert_both_error(label, s)
    local ok1 = pcall(pure._decode_raw, s)
    local ok2 = pcall(ffi._decode_raw, s)
    T.ok(not ok1, label .. ": pure should error")
    T.ok(not ok2, label .. ": ffi should error")
end

-- ── Tier selection ────────────────────────────────────────────────────────────

T.describe("json: tier selection", function()
    T.it("selected a tier", function()
        T.ok(json._tier == "simd" or json._tier == "ffi" or json._tier == "pure",
            "tier is one of simd/ffi/pure")
    end)
    T.it("_impl is a table with encode/decode", function()
        T.ok(type(json._impl) == "table")
        T.ok(type(json._impl.encode) == "function")
        T.ok(type(json._impl.decode) == "function")
    end)
    T.it("null sentinel is shared with impl", function()
        T.ok(json.null == json._impl.null)
    end)
end)

-- ── Public API (via init.lua, exercises the selected tier) ────────────────────

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

-- ── Edge cases: tested on both pure and ffi ────────────────────────────────────

T.describe("json: edge cases", function()

    T.it("empty object {}", function()
        assert_decode_parity("empty object", "{}")
        assert_encode_parity("empty object", {})
        local v = pure._decode_raw("{}")
        T.ok(type(v) == "table")
        T.eq(next(v), nil)
    end)

    T.it("empty array []", function()
        assert_decode_parity("empty array", "[]")
        local v = pure._decode_raw("[]")
        T.ok(type(v) == "table")
        T.eq(#v, 0)
    end)

    T.it("deeply nested (depth 100)", function()
        -- Build a 100-deep nested array.
        local s = string.rep("[", 100) .. "42" .. string.rep("]", 100)
        assert_decode_parity("deep nested", s)
        local pv = pure._decode_raw(s)
        -- Walk down to the innermost value.
        local cur = pv
        for _ = 1, 99 do cur = cur[1] end
        T.eq(cur[1], 42)
    end)

    T.it("unicode escape \\u0041 → A", function()
        assert_decode_parity("\\u0041", '"\\u0041"')
        T.eq(pure._decode_raw('"\\u0041"'), "A")
    end)

    T.it("unicode escape \\u00e9 → é", function()
        assert_decode_parity("\\u00e9", '"\\u00e9"')
        T.eq(pure._decode_raw('"\\u00e9"'), "\195\169")
    end)

    T.it("unicode escape \\u4e2d (CJK)", function()
        assert_decode_parity("\\u4e2d", '"\\u4e2d"')
    end)

    T.it("surrogate pair \\uD83D\\uDE00 → 😀", function()
        local s = '"\\uD83D\\uDE00"'
        assert_decode_parity("surrogate pair", s)
        -- U+1F600 encodes as 4-byte UTF-8: F0 9F 98 80
        local v = pure._decode_raw(s)
        T.eq(string.byte(v, 1), 0xF0)
        T.eq(string.byte(v, 2), 0x9F)
        T.eq(string.byte(v, 3), 0x98)
        T.eq(string.byte(v, 4), 0x80)
    end)

    T.it("all named escape sequences", function()
        local cases = {
            ['"\\b"'] = "\b",
            ['"\\f"'] = "\f",
            ['"\\n"'] = "\n",
            ['"\\r"'] = "\r",
            ['"\\t"'] = "\t",
            ['"\\/"'] = "/",
            ['"\\\\"'] = "\\",
            ['"\\""'] = '"',
        }
        for input, expected in pairs(cases) do
            local pv = pure._decode_raw(input)
            local fv = ffi._decode_raw(input)
            T.eq(pv, expected, "pure decode " .. input)
            T.eq(fv, expected, "ffi decode " .. input)
        end
    end)

    T.it("large integer (2^53)", function()
        local n = 2^53
        assert_encode_parity("2^53", n)
        assert_decode_parity("2^53", tostring(math.floor(n)))
    end)

    T.it("1e308 (large float)", function()
        local s = "1e308"
        assert_decode_parity("1e308", s)
        local v = pure._decode_raw(s)
        T.ok(v > 0, "positive")
        T.ok(v < math.huge, "finite")
    end)

    T.it("-0 decodes as 0", function()
        -- JSON -0 is valid; Lua treats it as 0 or -0.0 depending on context.
        -- Both tiers must agree.
        local pv = pure._decode_raw("-0")
        local fv = ffi._decode_raw("-0")
        -- They must be equal and both numerically zero.
        T.eq(pv, fv, "-0 parity")
        T.ok(pv == 0 or pv == -0.0, "-0 is zero")
    end)

    T.it("null decodes to null sentinel", function()
        assert_decode_parity("null", "null")
        T.eq(pure._decode_raw("null", json.null), json.null)
        T.eq(ffi._decode_raw("null",  json.null), json.null)
    end)

    T.it("true and false", function()
        assert_decode_parity("true", "true")
        assert_decode_parity("false", "false")
        T.eq(pure._decode_raw("true"), true)
        T.eq(pure._decode_raw("false"), false)
    end)

    T.it("whitespace variants", function()
        local variants = { " 42", "\t42", "\n42", "\r\n42", "  [  1 , 2  ]  " }
        for _, s in ipairs(variants) do
            assert_decode_parity("ws: " .. s, s)
        end
    end)

    T.it("string with all printable ASCII", function()
        -- Build a string with every printable ASCII char that doesn't need escaping.
        local chars = {}
        for i = 0x20, 0x7E do
            if i ~= 0x22 and i ~= 0x5C then  -- skip " and \
                chars[#chars + 1] = string.char(i)
            end
        end
        local s = table.concat(chars)
        local encoded = pure._encode_raw(s)
        assert_decode_parity("printable ASCII", encoded)
        T.eq(pure._decode_raw(encoded), s)
    end)

    T.it("string with control chars encodes to \\uXXXX", function()
        local s = "\0\1\2\3\4\5\6\7\8\11\12\14\15\16\17\18\19\20\21\22\23\24\25\26\27\28\29\30\31"
        local encoded = pure._encode_raw(s)
        -- All should be \uXXXX sequences; no raw bytes below 0x20 in output.
        for i = 1, #encoded do
            T.ok(string.byte(encoded, i) >= 0x20, "no raw control chars in output")
        end
        -- And it must round-trip.
        assert_encode_parity("control chars", s)
    end)

    T.it("number: integer format for whole numbers", function()
        T.eq(pure._encode_raw(0), "0")
        T.eq(pure._encode_raw(1), "1")
        T.eq(pure._encode_raw(-1), "-1")
        T.eq(pure._encode_raw(100), "100")
        assert_encode_parity("integer 0", 0)
        assert_encode_parity("integer 100", 100)
    end)

    T.it("number: %.17g for non-integer doubles", function()
        local v = 3.141592653589793
        local s = pure._encode_raw(v)
        T.ok(s:find("%.") or s:find("e"), "float has decimal or exponent")
        assert_encode_parity("pi", v)
    end)

    T.it("cycle detection", function()
        local t = {}
        t.self = t
        local ok1 = pcall(pure._encode_raw, t)
        local ok2 = pcall(ffi._encode_raw, t)
        T.ok(not ok1, "pure detects cycle")
        T.ok(not ok2, "ffi detects cycle")
    end)

    T.it("depth 512 is ok, depth 513 errors", function()
        -- 512 deep array: valid
        local s512 = string.rep("[", 512) .. "0" .. string.rep("]", 512)
        local ok1 = pcall(pure._decode_raw, s512)
        local ok2 = pcall(ffi._decode_raw, s512)
        T.ok(ok1, "pure: depth 512 ok")
        T.ok(ok2, "ffi: depth 512 ok")
        -- 513 deep array: error
        local s513 = string.rep("[", 513) .. "0" .. string.rep("]", 513)
        local ok3 = pcall(pure._decode_raw, s513)
        local ok4 = pcall(ffi._decode_raw, s513)
        T.ok(not ok3, "pure: depth 513 errors")
        T.ok(not ok4, "ffi: depth 513 errors")
    end)
end)

-- ── Error case parity ─────────────────────────────────────────────────────────

T.describe("json: error cases (both tiers must error)", function()
    T.it("truncated string", function()
        assert_both_error("truncated string", '"hello')
    end)
    T.it("trailing comma in array", function()
        assert_both_error("trailing comma array", "[1,2,]")
    end)
    T.it("trailing comma in object", function()
        assert_both_error("trailing comma object", '{"a":1,}')
    end)
    T.it("bad escape sequence", function()
        assert_both_error("bad escape", '"\\q"')
    end)
    T.it("unescaped control char in string", function()
        assert_both_error("unescaped control", '"\x01"')
    end)
    T.it("unpaired high surrogate", function()
        assert_both_error("unpaired high surrogate", '"\\uD800"')
    end)
    T.it("unpaired low surrogate", function()
        assert_both_error("unpaired low surrogate", '"\\uDC00"')
    end)
    T.it("trailing garbage", function()
        assert_both_error("trailing garbage", "42 extra")
    end)
    T.it("bare identifier", function()
        assert_both_error("bare identifier", "foo")
    end)
    T.it("empty input", function()
        assert_both_error("empty input", "")
    end)
    T.it("truncated true", function()
        assert_both_error("truncated true", "tru")
    end)
    T.it("truncated false", function()
        assert_both_error("truncated false", "fals")
    end)
    T.it("truncated null", function()
        assert_both_error("truncated null", "nul")
    end)
    T.it("number with leading zero", function()
        -- "01" is not valid JSON.
        assert_both_error("leading zero number", "01")
    end)
    T.it("number with trailing dot", function()
        assert_both_error("trailing dot number", "1.")
    end)
    T.it("encode nan errors", function()
        local ok1 = pcall(pure._encode_raw, 0/0)
        local ok2 = pcall(ffi._encode_raw, 0/0)
        T.ok(not ok1, "pure: nan errors")
        T.ok(not ok2, "ffi: nan errors")
    end)
    T.it("encode inf errors", function()
        local ok1 = pcall(pure._encode_raw, math.huge)
        local ok2 = pcall(ffi._encode_raw, math.huge)
        T.ok(not ok1, "pure: inf errors")
        T.ok(not ok2, "ffi: inf errors")
    end)
end)

-- ── Encode parity: same output from both tiers ────────────────────────────────

T.describe("json: encode parity (pure == ffi)", function()
    local cases = {
        { "null",         json.null },
        { "true",         true },
        { "false",        false },
        { "zero",         0 },
        { "integer",      42 },
        { "negative",     -1 },
        { "float",        3.14 },
        { "large int",    2^50 },
        { "string",       "hello world" },
        { "string escapes", "tab:\t nl:\n quote:\"" },
        { "empty array",  {} },
        { "array",        {1, 2, 3} },
        { "nested",       {a = {b = {c = 99}}} },
        { "mixed",        {x = 1, y = "two", z = true} },
    }
    for _, c in ipairs(cases) do
        local label, v = c[1], c[2]
        T.it("encode parity: " .. label, function()
            assert_encode_parity(label, v)
        end)
    end
end)

-- ── Decode parity: same result from both tiers ────────────────────────────────

T.describe("json: decode parity (pure == ffi)", function()
    local cases = {
        { "null",         "null" },
        { "true",         "true" },
        { "false",        "false" },
        { "integer",      "42" },
        { "negative",     "-1" },
        { "float",        "3.14" },
        { "scientific",   "1.5e10" },
        { "string",       '"hello"' },
        { "escape n",     '"\\n"' },
        { "escape t",     '"\\t"' },
        { "unicode",      '"\\u0041"' },
        { "empty obj",    "{}" },
        { "empty arr",    "[]" },
        { "array",        "[1,2,3]" },
        { "nested obj",   '{"a":{"b":1}}' },
        { "ws around",    "  42  " },
        { "surrogate",    '"\\uD83D\\uDE00"' },
    }
    for _, c in ipairs(cases) do
        local label, s = c[1], c[2]
        T.it("decode parity: " .. label, function()
            assert_decode_parity(label, s)
        end)
    end
end)

-- ── Round-trip property (via both tiers independently) ────────────────────────

T.describe("json: round-trip", function()
    local function rt(label, v)
        T.it("pure round-trip: " .. label, function()
            local s = pure._encode_raw(v)
            local v2 = pure._decode_raw(s)
            T.ok(deep_eq(v, v2), label .. ": pure rt")
        end)
        T.it("ffi round-trip: " .. label, function()
            local s = ffi._encode_raw(v)
            local v2 = ffi._decode_raw(s)
            T.ok(deep_eq(v, v2), label .. ": ffi rt")
        end)
    end
    rt("integer", 42)
    rt("float", 3.14)
    rt("string", "hello world")
    rt("escape", "tab\tnewline\n")
    rt("array", {1, 2, 3, 4, 5})
    rt("object", {name = "bob", age = 25})
    rt("nested", {a = {b = {c = {d = {e = 1}}}}})
    rt("unicode string", "\195\169\226\128\153")  -- é + '
end)
