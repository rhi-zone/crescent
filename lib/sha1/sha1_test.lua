local sha1 = require("lib.sha1")
local assert = require("lib.test.assert")

-- known test vectors (FIPS 180-1)
assert.eq(sha1.sha1(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709", "sha1 empty")
assert.eq(sha1.sha1("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d", "sha1 abc")
assert.eq(sha1.sha1("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
	"84983e441c3bd26ebaae4aa1f95129e5e54670f1", "sha1 448-bit")

-- binary returns raw bytes
assert.eq(#sha1.binary("abc"), 20, "binary length")

-- hmac
assert.eq(sha1.hmac("key", "The quick brown fox jumps over the lazy dog"),
	"de7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9", "hmac known vector")

-- hmac with empty key
assert.eq(sha1.hmac("", ""),
	"fbdb1d1b18aa6c08324b7d64b71fb76370690e1d", "hmac empty")
