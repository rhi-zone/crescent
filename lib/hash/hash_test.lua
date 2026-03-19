-- lib/hash/hash_test.lua
-- Cross-module parity tests: shared interface shape + known vectors for sha1 and sha256.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local sha1   = require("lib.hash.sha1")
local sha256 = require("lib.hash.sha256")

-- ── Interface shape ─────────────────────────────────────────────────────────

T.describe("hash interface: API shape", function()
	T.it("sha1 exposes expected functions", function()
		T.eq(type(sha1.sha1), "function", "sha1.sha1 is a function")
		T.eq(type(sha1.binary), "function", "sha1.binary is a function")
		T.eq(type(sha1.hmac), "function", "sha1.hmac is a function")
		T.eq(type(sha1.hmac_binary), "function", "sha1.hmac_binary is a function")
	end)

	T.it("sha256 exposes expected functions", function()
		T.eq(type(sha256.sha256), "function", "sha256.sha256 is a function")
		T.eq(type(sha256.tier), "string", "sha256.tier is a string")
		T.ok(sha256.tier == "system" or sha256.tier == "ffi" or sha256.tier == "lua",
			"sha256.tier is a valid tier name")
	end)
end)

-- ── Return type consistency ─────────────────────────────────────────────────

T.describe("hash interface: return types", function()
	local inputs = { "", "abc", "hello world", string.rep("x", 256) }

	T.it("sha1 always returns a 40-char lowercase hex string", function()
		for _, inp in ipairs(inputs) do
			local h = sha1.sha1(inp)
			T.eq(type(h), "string", "returns a string")
			T.eq(#h, 40, "hex length is 40 for input of length " .. #inp)
			T.ok(h:match("^[0-9a-f]+$"), "only lowercase hex chars")
		end
	end)

	T.it("sha256 always returns a 64-char lowercase hex string", function()
		for _, inp in ipairs(inputs) do
			local h = sha256.sha256(inp)
			T.eq(type(h), "string", "returns a string")
			T.eq(#h, 64, "hex length is 64 for input of length " .. #inp)
			T.ok(h:match("^[0-9a-f]+$"), "only lowercase hex chars")
		end
	end)

	T.it("sha1.binary returns a 20-byte raw string", function()
		for _, inp in ipairs(inputs) do
			local b = sha1.binary(inp)
			T.eq(type(b), "string", "returns a string")
			T.eq(#b, 20, "binary length is 20 for input of length " .. #inp)
		end
	end)
end)

-- ── Known test vectors: SHA-1 ───────────────────────────────────────────────
-- Sources: FIPS 180-1, RFC 3174

T.describe("hash: SHA-1 known vectors", function()
	local vectors = {
		{ input = "",
		  hex   = "da39a3ee5e6b4b0d3255bfef95601890afd80709",
		  label = "empty string" },
		{ input = "abc",
		  hex   = "a9993e364706816aba3e25717850c26c9cd0d89d",
		  label = "abc" },
		{ input = "hello world",
		  hex   = "2aae6c35c94fcfb415dbe95f408b9ce91ee846ed",
		  label = "hello world" },
		{ input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
		  hex   = "84983e441c3bd26ebaae4aa1f95129e5e54670f1",
		  label = "448-bit NIST" },
		{ input = "The quick brown fox jumps over the lazy dog",
		  hex   = "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12",
		  label = "quick brown fox" },
		{ input = "The quick brown fox jumps over the lazy cog",
		  hex   = "de9f2c7fd25e1b3afad3e85a0bd17d9b100db4b3",
		  label = "quick brown cog" },
		{ input = string.rep("a", 1000000),
		  hex   = "34aa973cd4c4daa4f61eeb2bdbad27316534016f",
		  label = "one million 'a'" },
	}

	for _, v in ipairs(vectors) do
		T.it(v.label, function()
			T.eq(sha1.sha1(v.input), v.hex)
		end)
	end
end)

-- ── Known test vectors: SHA-256 ─────────────────────────────────────────────
-- Sources: FIPS 180-4, NIST CSRC

T.describe("hash: SHA-256 known vectors", function()
	local vectors = {
		{ input = "",
		  hex   = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		  label = "empty string" },
		{ input = "abc",
		  hex   = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
		  label = "abc" },
		{ input = "hello world",
		  hex   = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9",
		  label = "hello world" },
		{ input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
		  hex   = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
		  label = "448-bit NIST" },
		{ input = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
		  hex   = "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
		  label = "896-bit NIST" },
		{ input = "The quick brown fox jumps over the lazy dog",
		  hex   = "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592",
		  label = "quick brown fox" },
		{ input = "The quick brown fox jumps over the lazy dog.",
		  hex   = "ef537f25c895bfa782526529a9b63d97aa631564d5d789c2b765448c8635fb6c",
		  label = "quick brown fox with period" },
	}

	for _, v in ipairs(vectors) do
		T.it(v.label, function()
			T.eq(sha256.sha256(v.input), v.hex)
		end)
	end
end)

-- ── Cross-algorithm sanity ──────────────────────────────────────────────────

T.describe("hash: cross-algorithm sanity", function()
	T.it("sha1 and sha256 produce different outputs for the same input", function()
		local inputs = { "", "abc", "hello world", string.rep("z", 100) }
		for _, inp in ipairs(inputs) do
			local h1 = sha1.sha1(inp)
			local h256 = sha256.sha256(inp)
			T.ok(h1 ~= h256, "sha1 != sha256 for input of length " .. #inp)
		end
	end)

	T.it("different inputs produce different hashes (collision resistance sanity)", function()
		local h1a = sha1.sha1("abc")
		local h1b = sha1.sha1("abd")
		T.ok(h1a ~= h1b, "sha1(abc) != sha1(abd)")

		local h256a = sha256.sha256("abc")
		local h256b = sha256.sha256("abd")
		T.ok(h256a ~= h256b, "sha256(abc) != sha256(abd)")
	end)
end)

-- ── HMAC known vectors (SHA-1) ──────────────────────────────────────────────
-- Source: RFC 2202

T.describe("hash: SHA-1 HMAC known vectors", function()
	T.it("RFC 2202 test case 2", function()
		T.eq(sha1.hmac("Jefe", "what do ya want for nothing?"),
			"effcdf6ae5eb2fa2d27416d5f184df9c259a7c79")
	end)

	T.it("empty key and empty text", function()
		T.eq(sha1.hmac("", ""),
			"fbdb1d1b18aa6c08324b7d64b71fb76370690e1d")
	end)

	T.it("hmac_binary returns 20 raw bytes", function()
		local b = sha1.hmac_binary("key", "data")
		T.eq(type(b), "string")
		T.eq(#b, 20)
	end)
end)

-- ── Determinism ─────────────────────────────────────────────────────────────

T.describe("hash: determinism", function()
	T.it("sha1 is deterministic across repeated calls", function()
		local inp = "determinism test input"
		local h1 = sha1.sha1(inp)
		local h2 = sha1.sha1(inp)
		local h3 = sha1.sha1(inp)
		T.eq(h1, h2)
		T.eq(h2, h3)
	end)

	T.it("sha256 is deterministic across repeated calls", function()
		local inp = "determinism test input"
		local h1 = sha256.sha256(inp)
		local h2 = sha256.sha256(inp)
		local h3 = sha256.sha256(inp)
		T.eq(h1, h2)
		T.eq(h2, h3)
	end)
end)
