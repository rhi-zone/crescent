if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local base64 = require("lib.base64")
local T = require("lib.test.assert")

-- ── RFC 4648 section 10 test vectors ──────────────────────────────────────────

T.describe("encode", function()
    T.it("RFC 4648 test vectors", function()
        T.eq(base64.encode(""), "")
        T.eq(base64.encode("f"), "Zg==")
        T.eq(base64.encode("fo"), "Zm8=")
        T.eq(base64.encode("foo"), "Zm9v")
        T.eq(base64.encode("foob"), "Zm9vYg==")
        T.eq(base64.encode("fooba"), "Zm9vYmE=")
        T.eq(base64.encode("foobar"), "Zm9vYmFy")
    end)
end)

T.describe("decode", function()
    T.it("RFC 4648 test vectors", function()
        T.eq(base64.decode(""), "")
        T.eq(base64.decode("Zg=="), "f")
        T.eq(base64.decode("Zm8="), "fo")
        T.eq(base64.decode("Zm9v"), "foo")
        T.eq(base64.decode("Zm9vYg=="), "foob")
        T.eq(base64.decode("Zm9vYmE="), "fooba")
        T.eq(base64.decode("Zm9vYmFy"), "foobar")
    end)
end)

-- ── Codec aliases ─────────────────────────────────────────────────────────────

T.describe("aliases", function()
    T.it("string_to_base64 is encode", function()
        T.eq(base64.string_to_base64, base64.encode)
    end)
    T.it("base64_to_string is decode", function()
        T.eq(base64.base64_to_string, base64.decode)
    end)
end)

-- ── Binary data ───────────────────────────────────────────────────────────────

T.describe("binary", function()
    T.it("encodes all 256 byte values", function()
        local bytes = {}
        for i = 0, 255 do bytes[i + 1] = string.char(i) end
        local all = table.concat(bytes)
        T.eq(base64.decode(base64.encode(all)), all)
    end)

    T.it("encodes null bytes", function()
        T.eq(base64.encode("\0\0\0"), "AAAA")
        T.eq(base64.decode("AAAA"), "\0\0\0")
    end)

    T.it("encodes 0xff bytes", function()
        T.eq(base64.encode("\xff\xff\xff"), "////")
        T.eq(base64.decode("////"), "\xff\xff\xff")
    end)
end)

-- ── URL-safe variant ──────────────────────────────────────────────────────────

T.describe("encode_url", function()
    T.it("uses - and _ instead of + and /", function()
        -- \xfb\xff\xfe encodes to +//+ in standard, -__- in URL-safe
        local out = base64.encode_url("\xfb\xff\xfe")
        T.ok(not out:find("+", 1, true), "no + in URL-safe output")
        T.ok(not out:find("/", 1, true), "no / in URL-safe output")
    end)

    T.it("omits padding by default", function()
        T.eq(base64.encode_url("f"), "Zg")
        T.eq(base64.encode_url("fo"), "Zm8")
        T.eq(base64.encode_url("foo"), "Zm9v")
    end)

    T.it("RFC 4648 vectors URL-safe", function()
        T.eq(base64.encode_url(""), "")
        T.eq(base64.encode_url("foobar"), "Zm9vYmFy")
    end)
end)

T.describe("decode_url", function()
    T.it("decodes URL-safe without padding", function()
        T.eq(base64.decode_url("Zg"), "f")
        T.eq(base64.decode_url("Zm8"), "fo")
        T.eq(base64.decode_url("Zm9v"), "foo")
    end)

    T.it("decodes URL-safe with padding", function()
        T.eq(base64.decode_url("Zg=="), "f")
        T.eq(base64.decode_url("Zm8="), "fo")
    end)

    T.it("roundtrips URL-safe", function()
        local inputs = { "", "hello", "\xfb\xff\xfe", "\0\1\2\255" }
        for _, input in ipairs(inputs) do
            T.eq(base64.decode_url(base64.encode_url(input)), input)
        end
    end)
end)

-- ── Decode without padding ────────────────────────────────────────────────────

T.describe("decode without padding", function()
    T.it("handles missing padding on standard alphabet", function()
        T.eq(base64.decode("Zg"), "f")
        T.eq(base64.decode("Zm8"), "fo")
        T.eq(base64.decode("Zm9v"), "foo")
        T.eq(base64.decode("Zm9vYg"), "foob")
        T.eq(base64.decode("Zm9vYmE"), "fooba")
    end)
end)

-- ── No-padding mode ───────────────────────────────────────────────────────────

T.describe("encode no-padding", function()
    T.it("omits = when pad=false", function()
        T.eq(base64.encode("f", { pad = false }), "Zg")
        T.eq(base64.encode("fo", { pad = false }), "Zm8")
        T.eq(base64.encode("foo", { pad = false }), "Zm9v")
        T.eq(base64.encode("foob", { pad = false }), "Zm9vYg")
        T.eq(base64.encode("fooba", { pad = false }), "Zm9vYmE")
    end)
end)

-- ── Whitespace handling ───────────────────────────────────────────────────────

T.describe("decode whitespace", function()
    T.it("strips newlines", function()
        T.eq(base64.decode("Zm9v\nYmFy"), "foobar")
    end)
    T.it("strips carriage returns", function()
        T.eq(base64.decode("Zm9v\r\nYmFy"), "foobar")
    end)
    T.it("strips spaces", function()
        T.eq(base64.decode("Zm9v YmFy"), "foobar")
    end)
    T.it("strips tabs", function()
        T.eq(base64.decode("Zm9v\tYmFy"), "foobar")
    end)
    T.it("strips mixed whitespace", function()
        T.eq(base64.decode(" Zm9v\t\r\n YmFy "), "foobar")
    end)
end)

-- ── Invalid input errors ──────────────────────────────────────────────────────

T.describe("decode errors", function()
    T.it("bad length (1 char)", function()
        local r, e = base64.decode("Z")
        T.eq(r, nil)
        T.ok(type(e) == "string")
    end)

    T.it("bad character", function()
        local r, e = base64.decode("Z!!!")
        T.eq(r, nil)
        T.ok(type(e) == "string")
    end)

    T.it("data after padding", function()
        local r, e = base64.decode("Zg==X")
        T.eq(r, nil)
        T.ok(type(e) == "string")
        T.ok(e:find("padding"), "error mentions padding")
    end)

    T.it("bad length (5 chars, rem=1)", function()
        local r, e = base64.decode("AAAAA")
        T.eq(r, nil)
        T.ok(e:find("length"), "error mentions length")
    end)

    T.it("non-alphabet character in middle", function()
        local r, e = base64.decode("Zm9v$mFy")
        T.eq(r, nil)
        T.ok(type(e) == "string")
    end)
end)

-- ── Roundtrip tests ───────────────────────────────────────────────────────────

T.describe("roundtrip", function()
    T.it("standard alphabet various lengths", function()
        local cases = {
            "", "a", "ab", "abc", "abcd", "abcde", "abcdef",
            "hello world", string.rep("x", 100), string.rep("y", 999),
        }
        for _, input in ipairs(cases) do
            T.eq(base64.decode(base64.encode(input)), input)
        end
    end)

    T.it("URL-safe alphabet various lengths", function()
        local cases = {
            "", "a", "ab", "abc", "abcd", "abcde", "abcdef",
            "hello world", string.rep("x", 100),
        }
        for _, input in ipairs(cases) do
            T.eq(base64.decode_url(base64.encode_url(input)), input)
        end
    end)

    T.it("pseudo-random binary strings", function()
        local seed = 0xCAFEBABE
        local function next_byte()
            seed = (seed * 1664525 + 1013904223) % 0x100000000
            return seed % 256
        end
        for len = 0, 30 do
            local bytes = {}
            for i = 1, len do bytes[i] = string.char(next_byte()) end
            local input = table.concat(bytes)
            T.eq(base64.decode(base64.encode(input)), input)
            T.eq(base64.decode_url(base64.encode_url(input)), input)
        end
    end)
end)

-- ── _tier introspection ───────────────────────────────────────────────────────

T.describe("module metadata", function()
    T.it("_tier is pure", function()
        T.eq(base64._tier, "pure")
    end)
end)
