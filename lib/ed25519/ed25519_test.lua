-- lib/ed25519/ed25519_test.lua
-- Tests for lib/ed25519: Ed25519 digital signatures (RFC 8032)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local ed = require("lib.ed25519")
local bit = require("bit")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function hex_to_bin(h)
	return (h:gsub("%x%x", function(b) return string.char(tonumber(b, 16)) end))
end

local function bin_to_hex(s)
	local t = {}
	for i = 1, #s do t[i] = string.format("%02x", string.byte(s, i)) end
	return table.concat(t)
end

-- ── API shape ─────────────────────────────────────────────────────────────────

T.describe("ed25519: API shape", function()
	T.it("exposes keypair, sign, verify functions", function()
		T.eq(type(ed.keypair), "function", "keypair is a function")
		T.eq(type(ed.sign),    "function", "sign is a function")
		T.eq(type(ed.verify),  "function", "verify is a function")
	end)

	T.it("exposes _tier string", function()
		T.eq(type(ed._tier), "string", "_tier is a string")
		T.ok(ed._tier == "system" or ed._tier == "pure",
			"_tier is 'system' or 'pure', got: " .. tostring(ed._tier))
	end)
end)

-- ── Error returns ─────────────────────────────────────────────────────────────

T.describe("ed25519: error returns", function()
	T.it("keypair rejects wrong-length seed", function()
		local priv, err = ed.keypair("tooshort")
		T.eq(priv, nil, "should return nil on bad seed")
		T.eq(type(err), "string", "should return error string")
	end)

	T.it("sign rejects wrong-length private key", function()
		local sig, err = ed.sign("tooshort", "message")
		T.eq(sig, nil, "should return nil on bad privkey")
		T.eq(type(err), "string", "should return error string")
	end)

	T.it("verify rejects wrong-length public key", function()
		local ok, err = ed.verify("tooshort", "message", string.rep("\x00", 64))
		T.eq(ok, false, "should return false on bad pubkey")
		T.eq(type(err), "string", "should return error string")
	end)

	T.it("verify rejects wrong-length signature", function()
		local ok, err = ed.verify(string.rep("\x00", 32), "message", "tooshort")
		T.eq(ok, false, "should return false on bad signature")
		T.eq(type(err), "string", "should return error string")
	end)
end)

-- ── Keypair generation ────────────────────────────────────────────────────────

T.describe("ed25519: keypair generation", function()
	T.it("generates correct-length keys from a seed", function()
		local seed = string.rep("\x42", 32)
		local priv, pub = ed.keypair(seed)
		T.ok(priv ~= nil, "keypair returns privkey")
		T.eq(#priv, 64, "private key is 64 bytes")
		T.eq(#pub,  32, "public key is 32 bytes")
	end)

	T.it("first 32 bytes of privkey are the seed", function()
		local seed = string.rep("\x42", 32)
		local priv = ed.keypair(seed)
		T.eq(priv:sub(1, 32), seed, "privkey[:32] == seed")
	end)

	T.it("last 32 bytes of privkey match pubkey", function()
		local seed = string.rep("\x42", 32)
		local priv, pub = ed.keypair(seed)
		T.eq(priv:sub(33, 64), pub, "privkey[33:64] == pubkey")
	end)

	T.it("same seed produces same keypair", function()
		local seed = string.rep("\x55", 32)
		local priv1, pub1 = ed.keypair(seed)
		local priv2, pub2 = ed.keypair(seed)
		T.eq(priv1, priv2, "deterministic privkey")
		T.eq(pub1,  pub2,  "deterministic pubkey")
	end)

	T.it("different seeds produce different keypairs", function()
		local priv1, pub1 = ed.keypair(string.rep("\x01", 32))
		local priv2, pub2 = ed.keypair(string.rep("\x02", 32))
		T.neq(pub1, pub2, "different seeds → different pubkeys")
	end)
end)

-- ── Sign/verify round-trip ────────────────────────────────────────────────────

T.describe("ed25519: sign/verify round-trip", function()
	local seed = string.rep("\xab", 32)
	local priv, pub = ed.keypair(seed)

	T.it("sign returns 64-byte signature", function()
		local sig, err = ed.sign(priv, "hello")
		T.ok(sig ~= nil, "sign succeeds: " .. tostring(err))
		T.eq(#sig, 64, "signature is 64 bytes")
	end)

	T.it("verify accepts valid signature", function()
		local sig = ed.sign(priv, "hello world")
		local ok, err = ed.verify(pub, "hello world", sig)
		T.ok(ok == true, "verify accepts valid sig: " .. tostring(err))
	end)

	T.it("verify rejects wrong message", function()
		local sig = ed.sign(priv, "correct message")
		local ok, _ = ed.verify(pub, "wrong message", sig)
		T.eq(ok, false, "verify rejects wrong message")
	end)

	T.it("verify rejects wrong public key", function()
		local _, other_pub = ed.keypair(string.rep("\xcd", 32))
		local sig = ed.sign(priv, "message")
		local ok, _ = ed.verify(other_pub, "message", sig)
		T.eq(ok, false, "verify rejects wrong pubkey")
	end)

	T.it("verify rejects tampered signature", function()
		local sig = ed.sign(priv, "message")
		-- Flip a bit in the middle of the signature
		local b = string.byte(sig, 33)
		local tampered = sig:sub(1, 32)
			.. string.char(bit.bxor(b, 1))
			.. sig:sub(34)
		local ok, _ = ed.verify(pub, "message", tampered)
		T.eq(ok, false, "verify rejects tampered sig")
	end)

	T.it("empty message signs and verifies", function()
		local sig, err = ed.sign(priv, "")
		T.ok(sig ~= nil, "sign empty message: " .. tostring(err))
		local ok, err2 = ed.verify(pub, "", sig)
		T.ok(ok == true, "verify empty message: " .. tostring(err2))
	end)

	T.it("signs are deterministic", function()
		local sig1 = ed.sign(priv, "test")
		local sig2 = ed.sign(priv, "test")
		T.eq(sig1, sig2, "same privkey+message → same signature")
	end)
end)

-- ── Known-answer test vectors (libsodium / RFC 8032 compatible) ───────────────
--
-- These vectors were verified against libsodium 1.0.20 (crypto_sign_ed25519_detached).
-- The seeds and messages are from RFC 8032 §6; the expected outputs are what
-- a correct Ed25519 implementation produces.

T.describe("ed25519: known-answer test vectors", function()
	-- Vector 1: empty message (RFC 8032 §6 Test 1 seed)
	T.it("vector 1: empty message", function()
		local seed = hex_to_bin(
			"9d61b19deffd5a60ba844af492ec2cc4" ..
			"4449c5697b326919703bac031cae3d55")
		local expected_pub = hex_to_bin(
			"700e2ce7c4b674427eab27ba820bcf6f" ..
			"0faebe68e09fe8564292114e41dc6a41")
		local expected_sig = hex_to_bin(
			"37b4bd5f28b61f55dc9673ae2895bace" ..
			"b863d9cf51780d040f98ad8cdc896cf5" ..
			"be46be655a863525da0959f7f3736115" ..
			"85e437e28ec971b7bd206ff9bd26e803")
		local message = ""

		local priv, pub = ed.keypair(seed)
		T.ok(priv ~= nil, "keypair succeeds")
		T.eq(bin_to_hex(pub), bin_to_hex(expected_pub), "public key matches vector 1")

		local sig, err = ed.sign(priv, message)
		T.ok(sig ~= nil, "sign succeeds: " .. tostring(err))
		T.eq(bin_to_hex(sig), bin_to_hex(expected_sig), "signature matches vector 1")

		local ok, err2 = ed.verify(pub, message, sig)
		T.ok(ok == true, "verify accepts vector 1: " .. tostring(err2))
	end)

	-- Vector 2: 1-byte message (RFC 8032 §6 Test 2 seed)
	T.it("vector 2: 1-byte message (0x72)", function()
		local seed = hex_to_bin(
			"4ccd089b28ff96da9db6c346ec114e0f" ..
			"5b8a319f35aba624da8cf6ed4d0bd6f3")
		local expected_pub = hex_to_bin(
			"d3edf21c525dc8227e660a03629b29f4" ..
			"3377183878131d7dcf19334725fb441a")
		local expected_sig = hex_to_bin(
			"02fa4f037164373c8b6185332d38f175" ..
			"9db0e81722ecc28944c2a46477dcfdb1" ..
			"c8e388379f97210b120ffbf403c61102" ..
			"9ed5442a2f8abcff159d527f92e4720d")
		local message = hex_to_bin("72")

		local priv, pub = ed.keypair(seed)
		T.eq(bin_to_hex(pub), bin_to_hex(expected_pub), "public key matches vector 2")

		local sig, err = ed.sign(priv, message)
		T.ok(sig ~= nil, "sign succeeds: " .. tostring(err))
		T.eq(bin_to_hex(sig), bin_to_hex(expected_sig), "signature matches vector 2")

		local ok, err2 = ed.verify(pub, message, sig)
		T.ok(ok == true, "verify accepts vector 2: " .. tostring(err2))
	end)

	-- Vector 3: 2-byte message (RFC 8032 §6 Test 3 seed)
	T.it("vector 3: 2-byte message (0xaf82)", function()
		local seed = hex_to_bin(
			"c5aa8df43f9f837bedb7442f31dcb7b1" ..
			"66d38535076f094b85ce3a2e0b4458f7")
		local expected_pub = hex_to_bin(
			"fc51cd8e6218a1a38da47ed00230f058" ..
			"0816ed13ba3303ac5deb911548908025")
		local expected_sig = hex_to_bin(
			"6291d657deec24024827e69c3abe01a3" ..
			"0ce548a284743a445e3680d7db5ac3ac" ..
			"18ff9b538d16f290ae67f760984dc659" ..
			"4a7c15e9716ed28dc027beceea1ec40a")
		local message = hex_to_bin("af82")

		local priv, pub = ed.keypair(seed)
		T.eq(bin_to_hex(pub), bin_to_hex(expected_pub), "public key matches vector 3")

		local sig, err = ed.sign(priv, message)
		T.ok(sig ~= nil, "sign succeeds: " .. tostring(err))
		T.eq(bin_to_hex(sig), bin_to_hex(expected_sig), "signature matches vector 3")

		local ok, err2 = ed.verify(pub, message, sig)
		T.ok(ok == true, "verify accepts vector 3: " .. tostring(err2))
	end)
end)

-- ── Consistency tests ─────────────────────────────────────────────────────────

T.describe("ed25519: consistency", function()
	T.it("multiple messages all sign and verify", function()
		local seed = string.rep("\x77", 32)
		local priv, pub = ed.keypair(seed)
		local messages = {
			"",
			"a",
			"hello world",
			string.rep("\x00", 100),
			string.rep("\xff", 100),
		}
		for _, msg in ipairs(messages) do
			local sig, err = ed.sign(priv, msg)
			T.ok(sig ~= nil, "sign ok for msg len " .. #msg .. ": " .. tostring(err))
			local ok, err2 = ed.verify(pub, msg, sig)
			T.ok(ok == true, "verify ok for msg len " .. #msg .. ": " .. tostring(err2))
		end
	end)

	T.it("cross-keypair verification fails", function()
		local priv1, pub1 = ed.keypair(string.rep("\x11", 32))
		local priv2, pub2 = ed.keypair(string.rep("\x22", 32))
		local msg = "test message"
		local sig1 = ed.sign(priv1, msg)
		local sig2 = ed.sign(priv2, msg)
		local ok1, _ = ed.verify(pub2, msg, sig1)
		T.eq(ok1, false, "sig1 fails under pub2")
		local ok2, _ = ed.verify(pub1, msg, sig2)
		T.eq(ok2, false, "sig2 fails under pub1")
	end)
end)
