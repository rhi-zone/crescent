local base64 = require("lib.encode.base64")
local pure   = require("lib.encode.base64.pure")
local ffi_ok, ffi_impl = pcall(require, "lib.encode.base64.ffi")
local T = require("lib.test.assert")

-- RFC 4648 §10 test vectors
T.eq(base64.encode(""), "", "encode empty")
T.eq(base64.encode("f"), "Zg==", "encode f")
T.eq(base64.encode("fo"), "Zm8=", "encode fo")
T.eq(base64.encode("foo"), "Zm9v", "encode foo")
T.eq(base64.encode("foob"), "Zm9vYg==", "encode foob")
T.eq(base64.encode("fooba"), "Zm9vYmE=", "encode fooba")
T.eq(base64.encode("foobar"), "Zm9vYmFy", "encode foobar")

-- decode
T.eq(base64.decode(""), "", "decode empty")
T.eq(base64.decode("Zg=="), "f", "decode f")
T.eq(base64.decode("Zm8="), "fo", "decode fo")
T.eq(base64.decode("Zm9v"), "foo", "decode foo")
T.eq(base64.decode("Zm9vYg=="), "foob", "decode foob")
T.eq(base64.decode("Zm9vYmE="), "fooba", "decode fooba")
T.eq(base64.decode("Zm9vYmFy"), "foobar", "decode foobar")

-- round-trip: standard
local cases = { "", "hello", "hello world", "\0\1\2\255", string.rep("x", 1000), string.rep("\xff", 100) }
for _, input in ipairs(cases) do
    T.eq(base64.decode(base64.encode(input)), input, "round-trip std")
end

-- round-trip: URL-safe
for _, input in ipairs(cases) do
    T.eq(base64.decode(base64.encode(input, {url=true}), {url=true}), input, "round-trip url")
end

-- URL-safe alphabet uses - and _ not + and /
local url_out = base64.encode("\xfb\xff\xfe", {url=true})
T.ok(not url_out:find("+"), "url-safe no +")
T.ok(not url_out:find("/"), "url-safe no /")

-- no-padding mode
T.eq(base64.encode("f",    {pad=false}), "Zg",   "encode no-pad 1")
T.eq(base64.encode("fo",   {pad=false}), "Zm8",  "encode no-pad 2")
T.eq(base64.encode("foo",  {pad=false}), "Zm9v", "encode no-pad 0")

-- decode handles whitespace
T.eq(base64.decode("Zm9v\nYmFy"), "foobar", "decode strips newline")
T.eq(base64.decode("Zm9v YmFy"), "foobar", "decode strips space")

-- error cases
local r1, e1 = base64.decode("Z")  -- length 1 after strip → bad
T.eq(r1, nil, "decode bad length nil")
T.ok(type(e1) == "string", "decode bad length err string")

local r2, e2 = base64.decode("Z!!!")
T.eq(r2, nil, "decode bad char nil")
T.ok(type(e2) == "string", "decode bad char err string")

-- binary round-trip: all byte values
local all_bytes = {}
for i = 0, 255 do all_bytes[i+1] = string.char(i) end
local all_str = table.concat(all_bytes)
T.eq(base64.decode(base64.encode(all_str)), all_str, "round-trip all bytes")

-- _tier is set
T.ok(base64._tier == "ffi" or base64._tier == "pure", "tier is ffi or pure")
T.ok(base64._impl ~= nil, "_impl is set")

-- parity tests: pure vs ffi (50 random-ish inputs of varying sizes 1–1000 bytes)
if ffi_ok and ffi_impl and ffi_impl.encode then
    -- Deterministic "random" inputs using a simple LCG.
    local seed = 0xdeadbeef
    local function next_byte()
        seed = (seed * 1664525 + 1013904223) % 0x100000000
        return seed % 256
    end
    local function make_input(len)
        local bytes2 = {}
        for i = 1, len do bytes2[i] = string.char(next_byte()) end
        return table.concat(bytes2)
    end

    for trial = 1, 50 do
        local len = (trial * 19 + 1) % 1000 + 1  -- sizes 1..1000, varied
        local input = make_input(len)

        -- encode parity
        local pe = pure.encode(input)
        local fe = ffi_impl.encode(input)
        T.eq(pe, fe, "parity encode trial " .. trial)

        -- url encode parity
        local peu = pure.encode(input, {url=true})
        local feu = ffi_impl.encode(input, {url=true})
        T.eq(peu, feu, "parity encode url trial " .. trial)

        -- decode round-trip via pure
        local pd = pure.decode(pe)
        T.eq(pd, input, "parity pure round-trip trial " .. trial)

        -- decode round-trip via ffi
        local fd = ffi_impl.decode(fe)
        T.eq(fd, input, "parity ffi round-trip trial " .. trial)

        -- cross: ffi encodes, pure decodes
        local pd2 = pure.decode(fe)
        T.eq(pd2, input, "parity cross-decode trial " .. trial)
    end
end
