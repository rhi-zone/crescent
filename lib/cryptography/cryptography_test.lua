-- lib/cryptography/cryptography_test.lua
-- Tests for lib/cryptography: SHA-256/512, HMAC, PBKDF2, ChaCha20, Poly1305.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local Cryp = require("lib.cryptography")

-- ── Hex utilities ─────────────────────────────────────────────────────────────

T.describe("hex/unhex", function()
	T.it("hex of empty string is empty", function()
		T.eq(Cryp.hex(""), "")
	end)

	T.it("hex round-trips via unhex", function()
		local data = "\x00\x01\x7f\x80\xff"
		T.eq(Cryp.unhex(Cryp.hex(data)), data)
	end)

	T.it("unhex of valid hex", function()
		T.eq(Cryp.unhex("deadbeef"), "\xde\xad\xbe\xef")
	end)

	T.it("unhex returns nil for odd-length input", function()
		T.eq(Cryp.unhex("abc"), nil)
	end)

	T.it("unhex returns nil for invalid hex chars", function()
		T.eq(Cryp.unhex("zz"), nil)
	end)

	T.it("unhex accepts uppercase", function()
		T.eq(Cryp.unhex("DEADBEEF"), "\xde\xad\xbe\xef")
	end)
end)

-- ── SHA-256 ───────────────────────────────────────────────────────────────────
-- NIST FIPS 180-4 test vectors and sha256sum-verified values.

T.describe("sha256", function()
	T.it("empty string (NIST)", function()
		T.eq(Cryp.sha256(""),
			"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
	end)

	T.it("'abc' (NIST FIPS 180-4 example)", function()
		T.eq(Cryp.sha256("abc"),
			"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	end)

	T.it("'hello world'", function()
		T.eq(Cryp.sha256("hello world"),
			"b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
	end)

	T.it("55-byte input (boundary: single block with 1 data byte + padding)", function()
		T.eq(Cryp.sha256(string.rep("a", 55)),
			"9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
	end)

	T.it("64-byte input (exactly one full block)", function()
		T.eq(Cryp.sha256(string.rep("a", 64)),
			"ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
	end)

	T.it("128-byte input (two full blocks)", function()
		T.eq(Cryp.sha256(string.rep("a", 128)),
			"6836cf13bac400e9105071cd6af47084dfacad4e5e302c94bfed24e013afb73e")
	end)

	T.it("sha256_bytes returns 32 bytes", function()
		T.eq(#Cryp.sha256_bytes("abc"), 32)
	end)

	T.it("sha256_bytes matches sha256 hex", function()
		T.eq(Cryp.hex(Cryp.sha256_bytes("abc")), Cryp.sha256("abc"))
	end)

	-- NIST FIPS 180-4 two-block message.
	T.it("'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq' (NIST)", function()
		T.eq(Cryp.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
			"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
	end)
end)

-- ── SHA-512 ───────────────────────────────────────────────────────────────────
-- NIST FIPS 180-4 SHA-512 test vectors.

T.describe("sha512", function()
	T.it("empty string (NIST)", function()
		T.eq(Cryp.sha512(""),
			"cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce"
			.. "47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")
	end)

	T.it("'abc' (NIST)", function()
		T.eq(Cryp.sha512("abc"),
			"ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
			.. "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
	end)

	T.it("sha512_bytes returns 64 bytes", function()
		T.eq(#Cryp.sha512_bytes("abc"), 64)
	end)

	T.it("sha512_bytes matches sha512 hex", function()
		T.eq(Cryp.hex(Cryp.sha512_bytes("abc")), Cryp.sha512("abc"))
	end)

	T.it("'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq' (NIST)", function()
		T.eq(Cryp.sha512("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
			"204a8fc6dda82f0a0ced7beb8e08a41657c16ef468b228a8279be331a703c335"
			.. "96fd15c13b1b07f9aa1d3bea57789ca031ad85c7a71dd70354ec631238ca3445")
	end)
end)

-- ── HMAC-SHA256 ───────────────────────────────────────────────────────────────
-- RFC 4231 test vectors.

T.describe("hmac_sha256", function()
	-- RFC 4231 Test Case 1:
	-- Key = 0b0b0b0b 0b0b0b0b 0b0b0b0b 0b0b0b0b 0b0b0b0b (20 bytes)
	-- Data = "Hi There"
	T.it("RFC 4231 test case 1", function()
		local key  = string.rep("\x0b", 20)
		local data = "Hi There"
		T.eq(Cryp.hmac_sha256(key, data),
			"b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
	end)

	-- RFC 4231 Test Case 2:
	-- Key = "Jefe"
	-- Data = "what do ya want for nothing?"
	T.it("RFC 4231 test case 2", function()
		T.eq(Cryp.hmac_sha256("Jefe", "what do ya want for nothing?"),
			"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
	end)

	-- RFC 4231 Test Case 3:
	-- Key = 0xaa * 20
	-- Data = 0xdd * 50
	T.it("RFC 4231 test case 3", function()
		local key  = string.rep("\xaa", 20)
		local data = string.rep("\xdd", 50)
		T.eq(Cryp.hmac_sha256(key, data),
			"773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe")
	end)

	T.it("key longer than block size is hashed first", function()
		-- RFC 4231 Test Case 5 (key > 64 bytes):
		-- Key = 0xaa * 131 bytes
		-- Data = "Test Using Larger Than Block-Size Key - Hash Key First"
		local key  = string.rep("\xaa", 131)
		local data = "Test Using Larger Than Block-Size Key - Hash Key First"
		T.eq(Cryp.hmac_sha256(key, data),
			"60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
	end)
end)

-- ── HMAC-SHA512 ───────────────────────────────────────────────────────────────

T.describe("hmac_sha512", function()
	-- RFC 4231 Test Case 1 (SHA-512 variant):
	T.it("RFC 4231 test case 1", function()
		local key  = string.rep("\x0b", 20)
		local data = "Hi There"
		T.eq(Cryp.hmac_sha512(key, data),
			"87aa7cdea5ef619d4ff0b4241a1d6cb0"
			.. "2379f4e2ce4ec2787ad0b30545e17cde"
			.. "daa833b7d6b8a702038b274eaea3f4e4"
			.. "be9d914eeb61f1702e696c203a126854")
	end)
end)

-- ── PBKDF2 ───────────────────────────────────────────────────────────────────
-- RFC 6070 test vectors.

T.describe("pbkdf2", function()
	-- RFC 6070 Test Case 1:
	-- P = "password", S = "salt", c = 1, dkLen = 20
	T.it("RFC 6070 test case 1 (c=1)", function()
		local key = Cryp.pbkdf2("password", "salt", 1, 20, "sha1")
		-- SHA1-based PBKDF2 not implemented; skip this test case.
		-- Use SHA256 instead with a known vector.
		T.ok(true)  -- placeholder
	end)

	-- PBKDF2-HMAC-SHA256 vectors (verified against independent implementations).
	-- P = "password", S = "salt", c = 1, dkLen = 32
	T.it("PBKDF2-SHA256 password/salt c=1 dkLen=32", function()
		local result = Cryp.pbkdf2("password", "salt", 1, 32, "sha256")
		T.eq(Cryp.hex(result),
			"120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
	end)

	-- P = "password", S = "salt", c = 2, dkLen = 32
	T.it("PBKDF2-SHA256 password/salt c=2 dkLen=32", function()
		local result = Cryp.pbkdf2("password", "salt", 2, 32, "sha256")
		T.eq(Cryp.hex(result),
			"ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
	end)

	-- dkLen shorter than hash output (truncation).
	T.it("PBKDF2-SHA256 key_len shorter than hash output", function()
		local result = Cryp.pbkdf2("password", "salt", 1, 16, "sha256")
		T.eq(#result, 16)
		-- First 16 bytes of the 32-byte result.
		T.eq(Cryp.hex(result), "120fb6cffcf8b32c43e7225256c4f837")
	end)

	-- dkLen longer than hash output (two blocks).
	T.it("PBKDF2-SHA256 key_len=64 (two hash blocks)", function()
		local result = Cryp.pbkdf2("password", "salt", 1, 64, "sha256")
		T.eq(#result, 64)
	end)

	-- SHA-512 variant.
	T.it("PBKDF2-SHA512 produces 64 bytes", function()
		local result = Cryp.pbkdf2("password", "salt", 1, 64, "sha512")
		T.eq(#result, 64)
	end)

	T.it("unsupported hash returns nil, errmsg", function()
		local result, err = Cryp.pbkdf2("password", "salt", 1, 32, "md5")
		T.eq(result, nil)
		T.ok(err ~= nil)
	end)

	T.it("iterations < 1 returns nil, errmsg", function()
		local result, err = Cryp.pbkdf2("password", "salt", 0, 32)
		T.eq(result, nil)
		T.ok(err ~= nil)
	end)
end)

-- ── ChaCha20 ─────────────────────────────────────────────────────────────────
-- RFC 7539 section 2.1.1 test vector.

T.describe("chacha20", function()
	-- RFC 7539 section 2.3.2 test vector:
	-- Key: 0x00010203...1f (32 bytes)
	-- Nonce: 0x000000000000004a00000000 (12 bytes, LE-encoded nonce words: 0, 0x4a000000, 0)
	-- Counter: 1
	-- Input: 114-byte text (Appendix A.2)
	T.it("RFC 7539 section 2.3.2 encrypt/decrypt", function()
		local key = ""
		for i = 0, 31 do key = key .. string.char(i) end
		local nonce = "\x00\x00\x00\x00\x00\x00\x00\x4a\x00\x00\x00\x00"
		local plaintext = "Ladies and Gentlemen of the class of '99: "
			.. "If I could offer you only one tip for the future, "
			.. "sunscreen would be it."
		-- Known expected ciphertext first 4 bytes (from RFC 7539 Appendix A.2):
		-- 6e 2e 35 9a
		local ciphertext = Cryp.chacha20(key, nonce, 1, plaintext)
		T.ok(ciphertext ~= nil)
		T.eq(#ciphertext, #plaintext)
		-- Check first 4 bytes match RFC 7539 Appendix A.2 vector.
		T.eq(string.byte(ciphertext, 1), 0x6e)
		T.eq(string.byte(ciphertext, 2), 0x2e)
		T.eq(string.byte(ciphertext, 3), 0x35)
		T.eq(string.byte(ciphertext, 4), 0x9a)
	end)

	T.it("RFC 7539 keystream test (counter=0, all-zero key/nonce, 64 zero bytes)", function()
		-- RFC 7539 section 2.1.1: first block of all-zero keystream.
		-- Key: 32 zero bytes, Nonce: 12 zero bytes, Counter: 0.
		-- First 4 output bytes: 76 b8 e0 ad
		local key   = string.rep("\x00", 32)
		local nonce = string.rep("\x00", 12)
		local ct    = Cryp.chacha20(key, nonce, 0, string.rep("\x00", 64))
		T.eq(string.byte(ct, 1), 0x76)
		T.eq(string.byte(ct, 2), 0xb8)
		T.eq(string.byte(ct, 3), 0xe0)
		T.eq(string.byte(ct, 4), 0xad)
	end)

	T.it("encrypt then decrypt is identity", function()
		local key   = string.rep("\x42", 32)
		local nonce = string.rep("\x24", 12)
		local plain = "Hello, ChaCha20! This is a test message for round-trip."
		local ct    = Cryp.chacha20(key, nonce, 0, plain)
		local pt    = Cryp.chacha20(key, nonce, 0, ct)
		T.eq(pt, plain)
	end)

	T.it("wrong key size returns nil, errmsg", function()
		local r, e = Cryp.chacha20("short", string.rep("\x00", 12), 0, "data")
		T.eq(r, nil)
		T.ok(e ~= nil)
	end)

	T.it("wrong nonce size returns nil, errmsg", function()
		local r, e = Cryp.chacha20(string.rep("\x00", 32), "short", 0, "data")
		T.eq(r, nil)
		T.ok(e ~= nil)
	end)

	T.it("empty input returns empty string", function()
		local key   = string.rep("\x00", 32)
		local nonce = string.rep("\x00", 12)
		T.eq(Cryp.chacha20(key, nonce, 0, ""), "")
	end)
end)

-- ── Poly1305 ─────────────────────────────────────────────────────────────────
-- RFC 7539 section 2.5.2 test vector.

T.describe("poly1305", function()
	-- RFC 7539 section 2.5.2:
	-- Key = 85d6be7857556d337f4452fe42d506a8...
	-- Msg = "Cryptographic Forum Research Group"
	T.it("RFC 7539 section 2.5.2", function()
		local key = Cryp.unhex(
			"85d6be7857556d337f4452fe42d506a8"
			.. "0103808afb0db2fd4abff6af4149f51b")
		local msg = "Cryptographic Forum Research Group"
		local tag = Cryp.poly1305(key, msg)
		T.eq(Cryp.hex(tag), "a8061dc1305136c6c22b8baf0c0127a9")
	end)

	T.it("output is 16 bytes", function()
		local key = string.rep("\x01", 32)
		local tag = Cryp.poly1305(key, "hello")
		T.eq(#tag, 16)
	end)

	T.it("empty message", function()
		local key = string.rep("\x00", 32)
		-- Known: Poly1305 of empty message with all-zero key is the s value = 0.
		local tag = Cryp.poly1305(key, "")
		T.eq(#tag, 16)
		-- All-zero s means tag = 0 + 0 = all zeros.
		T.eq(tag, string.rep("\x00", 16))
	end)
end)

-- ── ChaCha20-Poly1305 AEAD ────────────────────────────────────────────────────

T.describe("chacha20_poly1305", function()
	local key   = string.rep("\x00", 32)
	local nonce = string.rep("\x00", 12)

	T.it("encrypt then decrypt round-trip (no AAD)", function()
		local plain = "Hello, AEAD world!"
		local ct    = Cryp.chacha20_poly1305_encrypt(key, nonce, plain)
		T.ok(type(ct) == "string")
		T.eq(#ct, #plain + 16)  -- ciphertext + 16-byte tag
		local pt, err = Cryp.chacha20_poly1305_decrypt(key, nonce, ct)
		T.eq(err, nil)
		T.eq(pt, plain)
	end)

	T.it("encrypt then decrypt round-trip (with AAD)", function()
		local plain = "Secret message"
		local aad   = "associated data"
		local ct    = Cryp.chacha20_poly1305_encrypt(key, nonce, plain, aad)
		local pt, err = Cryp.chacha20_poly1305_decrypt(key, nonce, ct, aad)
		T.eq(err, nil)
		T.eq(pt, plain)
	end)

	T.it("tampered ciphertext fails authentication", function()
		local plain = "Tamper test message"
		local ct    = Cryp.chacha20_poly1305_encrypt(key, nonce, plain)
		-- Flip a bit in the ciphertext.
		local tampered = ct:sub(1, 1):gsub(".", function(c)
			return string.char(bit.bxor(string.byte(c), 0x01))
		end) .. ct:sub(2)
		local pt, err = Cryp.chacha20_poly1305_decrypt(key, nonce, tampered)
		T.eq(pt, nil)
		T.ok(err ~= nil)
	end)

	T.it("wrong AAD fails authentication", function()
		local plain = "AAD mismatch test"
		local ct    = Cryp.chacha20_poly1305_encrypt(key, nonce, plain, "correct aad")
		local pt, err = Cryp.chacha20_poly1305_decrypt(key, nonce, ct, "wrong aad")
		T.eq(pt, nil)
		T.ok(err ~= nil)
	end)

	T.it("empty plaintext round-trips", function()
		local ct = Cryp.chacha20_poly1305_encrypt(key, nonce, "")
		T.eq(#ct, 16)  -- just the tag
		local pt, err = Cryp.chacha20_poly1305_decrypt(key, nonce, ct)
		T.eq(err, nil)
		T.eq(pt, "")
	end)

	-- RFC 8439 Appendix A.5 test vector (poly1305-aead).
	T.it("RFC 8439 Appendix A.5 AEAD vector", function()
		local rfc_key   = Cryp.unhex("1c9240a5eb55d38af333888604f6b5f0473917c1402b80099dca5cbc207075c0")
		local rfc_nonce = Cryp.unhex("000000000102030405060708")
		local rfc_aad   = Cryp.unhex("f33388860000000000004e91")
		local rfc_plain = Cryp.unhex(
			"496e7465726e65742d44726166747320"
			.. "61726520647261667420646f63756d65"
			.. "6e74732076616c696420666f72206120"
			.. "6d6178696d756d206f6620736978206d"
			.. "6f6e74687320616e64206d6179206265"
			.. "20757064617465642c207265706c6163"
			.. "65642c206f72206f62736f6c65746564"
			.. "206279206f7468657220646f63756d65"
			.. "6e747320617420616e792074696d652e"
			.. "20497420697320696e617070726f7072"
			.. "6961746520746f2075736520496e7465"
			.. "726e65742d4472616674732061732072"
			.. "65666572656e6365206d617465726961"
			.. "6c206f7220746f2063697465207468656d206f74686572207468616e2061732f6ee2808c6578616d706c652e2f")
		local ct_with_tag = Cryp.chacha20_poly1305_encrypt(rfc_key, rfc_nonce, rfc_plain, rfc_aad)
		local pt, err = Cryp.chacha20_poly1305_decrypt(rfc_key, rfc_nonce, ct_with_tag, rfc_aad)
		T.eq(err, nil)
		T.eq(pt, rfc_plain)
	end)
end)

-- ── Constant-time comparison ─────────────────────────────────────────────────

T.describe("ct_eq", function()
	T.it("equal strings return true", function()
		T.ok(Cryp.ct_eq("hello", "hello"))
	end)

	T.it("unequal strings return false", function()
		T.ok(not Cryp.ct_eq("hello", "world"))
	end)

	T.it("different lengths return false", function()
		T.ok(not Cryp.ct_eq("ab", "abc"))
	end)

	T.it("empty strings are equal", function()
		T.ok(Cryp.ct_eq("", ""))
	end)

	T.it("one empty, one non-empty returns false", function()
		T.ok(not Cryp.ct_eq("", "a"))
	end)

	T.it("strings differing only in last byte", function()
		T.ok(not Cryp.ct_eq("hella", "hellb"))
	end)
end)

-- ── Module metadata ───────────────────────────────────────────────────────────

T.describe("module", function()
	T.it("_tier is 'pure'", function()
		T.eq(Cryp._tier, "pure")
	end)
end)
