-- lib/crypto/crypto_test.lua
-- Tests for lib/crypto: AES-256-GCM, ChaCha20-Poly1305, HKDF, random bytes.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local crypto = require("lib.crypto")

-- Helper: hex string to binary bytes.
local function hex(s)
	return (s:gsub("%s+", ""):gsub("..", function(h)
		return string.char(tonumber(h, 16))
	end))
end

-- Helper: binary bytes to hex string.
local function tohex(s)
	local out = {}
	for i = 1, #s do
		out[i] = string.format("%02x", string.byte(s, i))
	end
	return table.concat(out)
end

local is_system = crypto._tier == "system-libcrypto"
local is_pure   = crypto._tier == "pure-lua"

-- ── Tier ────────────────────────────────────────────────────────────────────

T.describe("crypto: tier", function()
	T.it("_tier is a known value", function()
		T.ok(is_system or is_pure,
			"_tier is system-libcrypto or pure-lua, got: " .. tostring(crypto._tier))
	end)
end)

-- ── AES-256-GCM ─────────────────────────────────────────────────────────────

T.describe("crypto: AES-256-GCM", function()
	local key   = string.rep("\1", 32)
	local nonce = string.rep("\2", 12)

	T.it("encrypt/decrypt round-trip", function()
		if is_pure then T.skip("requires system-libcrypto") end
		local pt = "hello, AES-GCM!"
		local ct, err = crypto.aes_gcm_encrypt(key, nonce, pt)
		T.ok(ct, "encrypt succeeded: " .. tostring(err))
		T.eq(#ct, #pt + 16, "ciphertext length = plaintext + 16-byte tag")
		local dec, err2 = crypto.aes_gcm_decrypt(key, nonce, ct)
		T.ok(dec, "decrypt succeeded: " .. tostring(err2))
		T.eq(dec, pt, "round-trip matches")
	end)

	T.it("wrong key fails authentication", function()
		if is_pure then T.skip("requires system-libcrypto") end
		local ct = crypto.aes_gcm_encrypt(key, nonce, "test")
		local bad_key = string.rep("\9", 32)
		local dec, err = crypto.aes_gcm_decrypt(bad_key, nonce, ct)
		T.eq(dec, nil, "decrypt returns nil")
		T.eq(err, "authentication failed", "error is authentication failed")
	end)

	T.it("wrong nonce fails authentication", function()
		if is_pure then T.skip("requires system-libcrypto") end
		local ct = crypto.aes_gcm_encrypt(key, nonce, "test")
		local bad_nonce = string.rep("\9", 12)
		local dec, err = crypto.aes_gcm_decrypt(key, bad_nonce, ct)
		T.eq(dec, nil, "decrypt returns nil")
		T.eq(err, "authentication failed", "error is authentication failed")
	end)

	T.it("tampered ciphertext fails authentication", function()
		if is_pure then T.skip("requires system-libcrypto") end
		local ct = crypto.aes_gcm_encrypt(key, nonce, "test data here")
		-- Flip a bit in the ciphertext body
		local tampered = string.char(bit.bxor(string.byte(ct, 1), 0x01)) .. ct:sub(2)
		local dec, err = crypto.aes_gcm_decrypt(key, nonce, tampered)
		T.eq(dec, nil, "decrypt returns nil")
		T.eq(err, "authentication failed", "error is authentication failed")
	end)

	T.it("with AAD: round-trip", function()
		if is_pure then T.skip("requires system-libcrypto") end
		local pt = "secret payload"
		local aad = "additional authenticated data"
		local ct = crypto.aes_gcm_encrypt(key, nonce, pt, aad)
		local dec = crypto.aes_gcm_decrypt(key, nonce, ct, aad)
		T.eq(dec, pt, "round-trip with AAD matches")
	end)

	T.it("with AAD: wrong AAD fails", function()
		if is_pure then T.skip("requires system-libcrypto") end
		local ct = crypto.aes_gcm_encrypt(key, nonce, "payload", "correct aad")
		local dec, err = crypto.aes_gcm_decrypt(key, nonce, ct, "wrong aad")
		T.eq(dec, nil, "decrypt returns nil")
		T.eq(err, "authentication failed", "error is authentication failed")
	end)

	T.it("empty plaintext", function()
		if is_pure then T.skip("requires system-libcrypto") end
		local ct, err = crypto.aes_gcm_encrypt(key, nonce, "")
		T.ok(ct, "encrypt empty succeeded: " .. tostring(err))
		T.eq(#ct, 16, "only tag for empty plaintext")
		local dec = crypto.aes_gcm_decrypt(key, nonce, ct)
		T.eq(dec, "", "decrypt empty matches")
	end)

	-- NIST AES-256-GCM test vector (GCM Spec, Test Case 16)
	T.it("NIST test vector", function()
		if is_pure then T.skip("requires system-libcrypto") end
		local tv_key   = hex("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308")
		local tv_nonce = hex("cafebabefacedbaddecaf888")
		local tv_pt    = hex("d9313225f88406e5a55909c5aff5269a"
			.. "86a7a9531534f7da2e4c303d8a318a72"
			.. "1c3c0c95956809532fcf0e2449a6b525"
			.. "b16aedf5aa0de657ba637b391aafd255")
		local tv_ct_expected = hex("522dc1f099567d07f47f37a32a84427d"
			.. "643a8cdcbfe5c0c97598a2bd2555d1aa"
			.. "8cb08e48590dbb3da7b08b1056828838"
			.. "c5f61e6393ba7a0abcc9f662898015ad")
		local tv_tag_expected = hex("b094dac5d93471bdec1a502270e3cc6c")

		local ct_with_tag = crypto.aes_gcm_encrypt(tv_key, tv_nonce, tv_pt)
		T.ok(ct_with_tag, "encrypt succeeded")
		local ct_part = ct_with_tag:sub(1, #ct_with_tag - 16)
		local tag_part = ct_with_tag:sub(#ct_with_tag - 15)
		T.eq(tohex(ct_part), tohex(tv_ct_expected), "ciphertext matches NIST vector")
		T.eq(tohex(tag_part), tohex(tv_tag_expected), "tag matches NIST vector")
	end)
end)

-- ── ChaCha20-Poly1305 ──────────────────────────────────────────────────────

T.describe("crypto: ChaCha20-Poly1305", function()
	local key   = string.rep("\3", 32)
	local nonce = string.rep("\4", 12)

	T.it("encrypt/decrypt round-trip", function()
		local pt = "hello, ChaCha20!"
		local ct, err = crypto.chacha20_encrypt(key, nonce, pt)
		T.ok(ct, "encrypt succeeded: " .. tostring(err))
		T.eq(#ct, #pt + 16, "ciphertext length = plaintext + 16-byte tag")
		local dec, err2 = crypto.chacha20_decrypt(key, nonce, ct)
		T.ok(dec, "decrypt succeeded: " .. tostring(err2))
		T.eq(dec, pt, "round-trip matches")
	end)

	T.it("wrong key fails authentication", function()
		local ct = crypto.chacha20_encrypt(key, nonce, "test")
		local bad_key = string.rep("\9", 32)
		local dec, err = crypto.chacha20_decrypt(bad_key, nonce, ct)
		T.eq(dec, nil, "decrypt returns nil")
		T.eq(err, "authentication failed", "error is authentication failed")
	end)

	T.it("tampered ciphertext fails authentication", function()
		local ct = crypto.chacha20_encrypt(key, nonce, "test data here")
		local tampered = string.char(bit.bxor(string.byte(ct, 1), 0x01)) .. ct:sub(2)
		local dec, err = crypto.chacha20_decrypt(key, nonce, tampered)
		T.eq(dec, nil, "decrypt returns nil")
		T.eq(err, "authentication failed", "error is authentication failed")
	end)

	T.it("with AAD: round-trip", function()
		local pt = "secret payload"
		local aad = "additional authenticated data"
		local ct = crypto.chacha20_encrypt(key, nonce, pt, aad)
		local dec = crypto.chacha20_decrypt(key, nonce, ct, aad)
		T.eq(dec, pt, "round-trip with AAD matches")
	end)

	T.it("with AAD: wrong AAD fails", function()
		local ct = crypto.chacha20_encrypt(key, nonce, "payload", "correct aad")
		local dec, err = crypto.chacha20_decrypt(key, nonce, ct, "wrong aad")
		T.eq(dec, nil, "decrypt returns nil")
		T.eq(err, "authentication failed")
	end)

	T.it("empty plaintext", function()
		local ct, err = crypto.chacha20_encrypt(key, nonce, "")
		T.ok(ct, "encrypt empty succeeded: " .. tostring(err))
		T.eq(#ct, 16, "only tag for empty plaintext")
		local dec = crypto.chacha20_decrypt(key, nonce, ct)
		T.eq(dec, "", "decrypt empty matches")
	end)

	T.it("large plaintext (1KB)", function()
		local pt = string.rep("A", 1024)
		local ct, err = crypto.chacha20_encrypt(key, nonce, pt)
		T.ok(ct, "encrypt 1KB succeeded: " .. tostring(err))
		T.eq(#ct, 1024 + 16, "ciphertext length correct")
		local dec = crypto.chacha20_decrypt(key, nonce, ct)
		T.eq(dec, pt, "1KB round-trip matches")
	end)

	-- RFC 8439 Section 2.8.2 test vector
	T.it("RFC 8439 test vector", function()
		local tv_key = hex(
			"808182838485868788898a8b8c8d8e8f"
			.. "909192939495969798999a9b9c9d9e9f")
		local tv_nonce = hex("070000004041424344454647")
		local tv_aad = hex("50515253c0c1c2c3c4c5c6c7")
		local tv_pt = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
		local tv_ct_expected = hex(
			"d31a8d34648e60db7b86afbc53ef7ec2"
			.. "a4aded51296e08fea9e2b5a736ee62d6"
			.. "3dbea45e8ca9671282fafb69da92728b"
			.. "1a71de0a9e060b2905d6a5b67ecd3b36"
			.. "92ddbd7f2d778b8c9803aee328091b58"
			.. "fab324e4fad675945585808b4831d7bc"
			.. "3ff4def08e4b7a9de576d26586cec64b"
			.. "6116")
		local tv_tag_expected = hex("1ae10b594f09e26a7e902ecbd0600691")

		local ct_with_tag, err = crypto.chacha20_encrypt(tv_key, tv_nonce, tv_pt, tv_aad)
		T.ok(ct_with_tag, "encrypt succeeded: " .. tostring(err))
		local ct_part = ct_with_tag:sub(1, #ct_with_tag - 16)
		local tag_part = ct_with_tag:sub(#ct_with_tag - 15)
		T.eq(tohex(ct_part), tohex(tv_ct_expected), "ciphertext matches RFC 8439")
		T.eq(tohex(tag_part), tohex(tv_tag_expected), "tag matches RFC 8439")

		-- Also verify decryption
		local dec = crypto.chacha20_decrypt(tv_key, tv_nonce, ct_with_tag, tv_aad)
		T.eq(dec, tv_pt, "decrypt matches RFC 8439 plaintext")
	end)
end)

-- ── HKDF ────────────────────────────────────────────────────────────────────

T.describe("crypto: HKDF", function()
	-- RFC 5869 Test Case 1
	T.it("RFC 5869 Test Case 1", function()
		local ikm  = hex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
		local salt = hex("000102030405060708090a0b0c")
		local info = hex("f0f1f2f3f4f5f6f7f8f9")
		local expected = hex("3cb25f25faacd57a90434f64d0362f2a"
			.. "2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
			.. "34007208d5b887185865")
		local derived = crypto.hkdf(ikm, salt, info, 42)
		T.eq(tohex(derived), tohex(expected), "matches RFC 5869 Test Case 1")
	end)

	T.it("different info produces different keys", function()
		local ikm = string.rep("\x0b", 22)
		local k1 = crypto.hkdf(ikm, "salt", "info-a", 32)
		local k2 = crypto.hkdf(ikm, "salt", "info-b", 32)
		T.neq(k1, k2, "different info -> different keys")
	end)

	T.it("different salt produces different keys", function()
		local ikm = string.rep("\x0b", 22)
		local k1 = crypto.hkdf(ikm, "salt-a", "info", 32)
		local k2 = crypto.hkdf(ikm, "salt-b", "info", 32)
		T.neq(k1, k2, "different salt -> different keys")
	end)
end)

-- ── Random bytes ────────────────────────────────────────────────────────────

T.describe("crypto: random_bytes", function()
	-- Pure tier: random_bytes(random_bytes_fn, n); System tier: random_bytes(n)
	local is_pure = crypto._tier == "pure-lua"
	local function urandom_bytes(n)
		local f = io.open("/dev/urandom", "rb")
		if not f then return nil end
		local bytes = f:read(n)
		f:close()
		return bytes
	end

	T.it("returns correct length", function()
		for _, n in ipairs({1, 16, 32, 64, 256}) do
			local bytes, err
			if is_pure then
				bytes, err = crypto.random_bytes(urandom_bytes, n)
			else
				bytes, err = crypto.random_bytes(n)
			end
			T.ok(bytes, "got " .. n .. " bytes: " .. tostring(err))
			T.eq(#bytes, n, "length is " .. n)
		end
	end)

	T.it("consecutive calls differ", function()
		local a, b
		if is_pure then
			a = crypto.random_bytes(urandom_bytes, 32)
			b = crypto.random_bytes(urandom_bytes, 32)
		else
			a = crypto.random_bytes(32)
			b = crypto.random_bytes(32)
		end
		T.neq(a, b, "two 32-byte random values differ")
	end)
end)

-- ── Parity: system vs pure (if both available) ─────────────────────────────

T.describe("crypto: tier parity", function()
	T.it("both tiers produce same HKDF output", function()
		local ok_sys, sys = pcall(require, "lib.crypto.system")
		local ok_pure, pure = pcall(require, "lib.crypto.pure")
		if not (ok_sys and ok_pure) then T.skip("both tiers not available") end

		local ikm = string.rep("\x0b", 22)
		local salt = "test-salt"
		local info = "test-info"
		local k_sys  = sys.hkdf(ikm, salt, info, 32)
		local k_pure = pure.hkdf(ikm, salt, info, 32)
		T.eq(tohex(k_sys), tohex(k_pure), "HKDF output matches across tiers")
	end)

	T.it("both tiers produce same ChaCha20-Poly1305 output", function()
		local ok_sys, sys = pcall(require, "lib.crypto.system")
		local ok_pure, pure = pcall(require, "lib.crypto.pure")
		if not (ok_sys and ok_pure) then T.skip("both tiers not available") end

		local key   = string.rep("\x05", 32)
		local nonce = string.rep("\x06", 12)
		local pt    = "parity test payload"
		local aad   = "parity aad"
		local ct_sys  = sys.chacha20_encrypt(key, nonce, pt, aad)
		local ct_pure = pure.chacha20_encrypt(key, nonce, pt, aad)
		T.eq(tohex(ct_sys), tohex(ct_pure), "ChaCha20 ciphertext+tag matches across tiers")
	end)
end)

return T._summary()
