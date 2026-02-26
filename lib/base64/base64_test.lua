local base64 = require("lib.base64")
local assert = require("lib.test.assert")

-- RFC 4648 test vectors
assert.eq(base64.encode(""), "", "encode empty")
assert.eq(base64.encode("f"), "Zg==", "encode f")
assert.eq(base64.encode("fo"), "Zm8=", "encode fo")
assert.eq(base64.encode("foo"), "Zm9v", "encode foo")
assert.eq(base64.encode("foob"), "Zm9vYg==", "encode foob")
assert.eq(base64.encode("fooba"), "Zm9vYmE=", "encode fooba")
assert.eq(base64.encode("foobar"), "Zm9vYmFy", "encode foobar")

-- decode
assert.eq(base64.decode("Zm9vYmFy"), "foobar", "decode foobar")
assert.eq(base64.decode("Zg=="), "f", "decode f")
assert.eq(base64.decode("Zm8="), "fo", "decode fo")
assert.eq(base64.decode(""), "", "decode empty")

-- round-trip
local cases = { "", "hello", "hello world", "\0\1\2\255", string.rep("x", 1000) }
for _, input in ipairs(cases) do
	assert.eq(base64.decode(base64.encode(input)), input, "round-trip")
end

-- aliases
assert.eq(base64.string_to_base64, base64.encode, "alias encode")
assert.eq(base64.base64_to_string, base64.decode, "alias decode")
