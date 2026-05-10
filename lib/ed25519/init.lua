-- lib/ed25519/init.lua
-- Ed25519 digital signatures (RFC 8032).
-- Tier 1: libsodium via ffi.load  (system)
-- Tier 2: pure LuaJIT with inline SHA-512 and big-integer GF(p) arithmetic  (pure)
--
-- Public API:
--   M.keypair(seed)                       → privkey(64 bytes), pubkey(32 bytes)  |  nil, err
--   M.sign(privkey, message)              → signature(64 bytes)                  |  nil, err
--   M.verify(pubkey, message, signature)  → true                                 |  false, err
--   M._tier                               → "system" | "pure"

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── Tier 1: libsodium ────────────────────────────────────────────────────────

local function try_system()
	local ffi = require("ffi")

	ffi.cdef [[
		int crypto_sign_ed25519_keypair(unsigned char *pk, unsigned char *sk);
		int crypto_sign_ed25519_seed_keypair(unsigned char *pk, unsigned char *sk,
		                                     const unsigned char *seed);
		int crypto_sign_ed25519_detached(unsigned char *sig,
		                                 unsigned long long *siglen_p,
		                                 const unsigned char *m,
		                                 unsigned long long mlen,
		                                 const unsigned char *sk);
		int crypto_sign_ed25519_verify_detached(const unsigned char *sig,
		                                         const unsigned char *m,
		                                         unsigned long long mlen,
		                                         const unsigned char *pk);
	]]

	-- lib is typed as any: ffi.load result passes through pcall so its type
	-- is unknown; the cdef block above fully specifies the ABI.
	local lib = nil --[[: any]]
	local names = { "sodium", "libsodium.so.26", "libsodium.so.23", "libsodium.so" }
	for _, name in ipairs(names) do
		local ok, l = pcall(ffi.load, name)
		if ok then lib = l; break end
	end
	if not lib then error("libsodium not found") end

	-- Smoke test
	local pk = ffi.new("unsigned char[32]")
	local sk = ffi.new("unsigned char[64]")
	local ok2, err2 = pcall(lib.crypto_sign_ed25519_keypair, pk, sk)
	if not ok2 then error("libsodium smoke test failed: " .. tostring(err2)) end

	--: (string | nil) -> (string, string) | (nil, string)
	local function keypair(seed)
		local _pk = ffi.new("unsigned char[32]")
		local _sk = ffi.new("unsigned char[64]")
		if seed then
			if #seed ~= 32 then return nil, "seed must be 32 bytes" end
			local ret = lib.crypto_sign_ed25519_seed_keypair(
				_pk, _sk, ffi.cast("const unsigned char *", seed))
			if ret ~= 0 then return nil, "crypto_sign_ed25519_seed_keypair failed" end
		else
			local ret = lib.crypto_sign_ed25519_keypair(_pk, _sk)
			if ret ~= 0 then return nil, "crypto_sign_ed25519_keypair failed" end
		end
		return ffi.string(_sk --[[:! Ptr<integer>]], 64), ffi.string(_pk --[[:! Ptr<integer>]], 32)
	end

	--: (string, string) -> (string | nil, string | nil)
	local function sign(privkey, message)
		if type(privkey) ~= "string" or #privkey ~= 64 then
			return nil, "private key must be 64 bytes"
		end
		local sig    = ffi.new("unsigned char[64]")
		local siglen = ffi.new("unsigned long long[1]")
		local ret = lib.crypto_sign_ed25519_detached(
			sig, siglen,
			ffi.cast("const unsigned char *", message), #message,
			ffi.cast("const unsigned char *", privkey))
		if ret ~= 0 then return nil, "signing failed" end
		return ffi.string(sig, 64)
	end

	--: (string, string, string) -> (boolean, string | nil)
	local function verify(pubkey, message, signature)
		if type(pubkey) ~= "string" or #pubkey ~= 32 then
			return false, "public key must be 32 bytes"
		end
		if type(signature) ~= "string" or #signature ~= 64 then
			return false, "signature must be 64 bytes"
		end
		local ret = lib.crypto_sign_ed25519_verify_detached(
			ffi.cast("const unsigned char *", signature),
			ffi.cast("const unsigned char *", message), #message,
			ffi.cast("const unsigned char *", pubkey))
		if ret ~= 0 then return false, "signature verification failed" end
		return true
	end

	return keypair, sign, verify
end

-- ── Tier 2: pure LuaJIT (inline SHA-512 + GF(2^255-19) + Ed25519) ────────────

local function make_pure()
	local ffi = require("ffi")
	local bit = require("bit")

	-- ── SHA-512 ──────────────────────────────────────────────────────────────
	-- Uses ffi uint64_t for 64-bit arithmetic.

	local u64 = ffi.typeof("uint64_t")

	-- SHA512_H0 and SHA512_K hold FFI uint64_t cdata; typed as number for arithmetic.
	local SHA512_H0 = { --: { [integer]: number }
		u64(0x6a09e667f3bcc908ULL), u64(0xbb67ae8584caa73bULL),
		u64(0x3c6ef372fe94f82bULL), u64(0xa54ff53a5f1d36f1ULL),
		u64(0x510e527fade682d1ULL), u64(0x9b05688c2b3e6c1fULL),
		u64(0x1f83d9abfb41bd6bULL), u64(0x5be0cd19137e2179ULL),
	}

	local SHA512_K = { --: { [integer]: number }
		u64(0x428a2f98d728ae22ULL), u64(0x7137449123ef65cdULL),
		u64(0xb5c0fbcfec4d3b2fULL), u64(0xe9b5dba58189dbbcULL),
		u64(0x3956c25bf348b538ULL), u64(0x59f111f1b605d019ULL),
		u64(0x923f82a4af194f9bULL), u64(0xab1c5ed5da6d8118ULL),
		u64(0xd807aa98a3030242ULL), u64(0x12835b0145706fbeULL),
		u64(0x243185be4ee4b28cULL), u64(0x550c7dc3d5ffb4e2ULL),
		u64(0x72be5d74f27b896fULL), u64(0x80deb1fe3b1696b1ULL),
		u64(0x9bdc06a725c71235ULL), u64(0xc19bf174cf692694ULL),
		u64(0xe49b69c19ef14ad2ULL), u64(0xefbe4786384f25e3ULL),
		u64(0x0fc19dc68b8cd5b5ULL), u64(0x240ca1cc77ac9c65ULL),
		u64(0x2de92c6f592b0275ULL), u64(0x4a7484aa6ea6e483ULL),
		u64(0x5cb0a9dcbd41fbd4ULL), u64(0x76f988da831153b5ULL),
		u64(0x983e5152ee66dfabULL), u64(0xa831c66d2db43210ULL),
		u64(0xb00327c898fb213fULL), u64(0xbf597fc7beef0ee4ULL),
		u64(0xc6e00bf33da88fc2ULL), u64(0xd5a79147930aa725ULL),
		u64(0x06ca6351e003826fULL), u64(0x142929670a0e6e70ULL),
		u64(0x27b70a8546d22ffcULL), u64(0x2e1b21385c26c926ULL),
		u64(0x4d2c6dfc5ac42aedULL), u64(0x53380d139d95b3dfULL),
		u64(0x650a73548baf63deULL), u64(0x766a0abb3c77b2a8ULL),
		u64(0x81c2c92e47edaee6ULL), u64(0x92722c851482353bULL),
		u64(0xa2bfe8a14cf10364ULL), u64(0xa81a664bbc423001ULL),
		u64(0xc24b8b70d0f89791ULL), u64(0xc76c51a30654be30ULL),
		u64(0xd192e819d6ef5218ULL), u64(0xd69906245565a910ULL),
		u64(0xf40e35855771202aULL), u64(0x106aa07032bbd1b8ULL),
		u64(0x19a4c116b8d2d0c8ULL), u64(0x1e376c085141ab53ULL),
		u64(0x2748774cdf8eeb99ULL), u64(0x34b0bcb5e19b48a8ULL),
		u64(0x391c0cb3c5c95a63ULL), u64(0x4ed8aa4ae3418acbULL),
		u64(0x5b9cca4f7763e373ULL), u64(0x682e6ff3d6b2b8a3ULL),
		u64(0x748f82ee5defb2fcULL), u64(0x78a5636f43172f60ULL),
		u64(0x84c87814a1f0ab72ULL), u64(0x8cc702081a6439ecULL),
		u64(0x90befffa23631e28ULL), u64(0xa4506cebde82bde9ULL),
		u64(0xbef9a3f7b2c67915ULL), u64(0xc67178f2e372532bULL),
		u64(0xca273eceea26619cULL), u64(0xd186b8c721c0c207ULL),
		u64(0xeada7dd6cde0eb1eULL), u64(0xf57d4f7fee6ed178ULL),
		u64(0x06f067aa72176fbaULL), u64(0x0a637dc5a2c898a6ULL),
		u64(0x113f9804bef90daeULL), u64(0x1b710b35131c471bULL),
		u64(0x28db77f523047d84ULL), u64(0x32caab7b40c72493ULL),
		u64(0x3c9ebe0a15c9bebcULL), u64(0x431d67c49c100d4cULL),
		u64(0x4cc5d4becb3e42b6ULL), u64(0x597f299cfc657e2aULL),
		u64(0x5fcb6fab3ad6faecULL), u64(0x6c44198c4a475817ULL),
	}

	local W512 = ffi.new("uint64_t[80]")

	local function rotr64(x, n)
		return bit.bor(bit.rshift(x, n), bit.lshift(x, 64 - n))
	end

	local function sha512_compress(h, data, off)
		for i = 0, 15 do
			local base = off + i * 8
			W512[i] = u64(0)
			for j = 0, 7 do
				W512[i] = bit.bor(bit.lshift(W512[i], 8),
					u64(string.byte(data, base + j + 1)))
			end
		end
		for i = 16, 79 do
			local w15 = W512[i - 15]
			local w2  = W512[i - 2]
			local s0 = bit.bxor(rotr64(w15, 1), rotr64(w15, 8), bit.rshift(w15, 7))
			local s1 = bit.bxor(rotr64(w2, 19), rotr64(w2, 61), bit.rshift(w2, 6))
			W512[i] = W512[i - 16] + s0 + W512[i - 7] + s1
		end
		local a = h[0]; local b = h[1]; local c = h[2]; local d = h[3]
		local e = h[4]; local f = h[5]; local g = h[6]; local hh = h[7]
		for i = 0, 79 do
			local S1    = bit.bxor(rotr64(e, 14), rotr64(e, 18), rotr64(e, 41))
			local ch    = bit.bxor(bit.band(e, f), bit.band(bit.bnot(e), g))
			local temp1 = hh + S1 + ch + SHA512_K[i + 1] + W512[i]
			local S0    = bit.bxor(rotr64(a, 28), rotr64(a, 34), rotr64(a, 39))
			local maj   = bit.bxor(bit.band(a, b), bit.band(a, c), bit.band(b, c))
			local temp2 = S0 + maj
			hh = g; g = f; f = e
			e  = d + temp1
			d  = c; c = b; b = a
			a  = temp1 + temp2
		end
		h[0] = h[0] + a; h[1] = h[1] + b
		h[2] = h[2] + c; h[3] = h[3] + d
		h[4] = h[4] + e; h[5] = h[5] + f
		h[6] = h[6] + g; h[7] = h[7] + hh
	end

	-- sha512(s) → 64-byte binary string
	local function sha512(s)
		local len = #s
		local h   = ffi.new("uint64_t[8]")
		for i = 0, 7 do h[i] = SHA512_H0[i + 1] end

		local nfull = math.floor(len / 128)
		for blk = 0, nfull - 1 do
			sha512_compress(h, s, blk * 128)
		end

		-- Padding
		local rem  = len - nfull * 128
		local tail = {} --: { [integer]: string }
		for i = nfull * 128 + 1, len do
			tail[#tail + 1] = string.char(string.byte(s, i))
		end
		tail[#tail + 1] = "\x80"
		-- Pad to 112 mod 128 (need 16 bytes for 128-bit big-endian bit count)
		local padlen = (112 - (rem + 1)) % 128
		for _ = 1, padlen do tail[#tail + 1] = "\x00" end
		-- 128-bit big-endian bit count; high 64 bits = 0 for Lua strings
		for _ = 1, 8 do tail[#tail + 1] = "\x00" end
		local bits = len * 8
		for sh = 56, 0, -8 do
			local byte_val = math.floor(bits / 2 ^ sh) % 256
			tail[#tail + 1] = string.char(byte_val)
		end
		local padded = table.concat(tail)
		for blk = 0, (#padded / 128) - 1 do
			sha512_compress(h, padded, blk * 128)
		end

		local out = {} --: { [integer]: string }
		for i = 0, 7 do
			local v = h[i]
			for sh = 56, 0, -8 do
				local byte_val = tonumber(bit.band(bit.rshift(v, sh), u64(0xff))) or 0
				out[#out + 1] = string.char(byte_val)
			end
		end
		return table.concat(out)
	end

	-- ── 256-bit little-endian integer arithmetic ──────────────────────────────
	-- Integers are Lua arrays of 32 bytes, index 1 = least significant byte.

	-- Parse a 64-char big-endian hex string into a 32-byte LE array.
	--: (string) -> { [integer]: number }
	local function hex32(h)
		local r = {} --: { [integer]: number }
		for i = 1, 32 do
			r[i] = tonumber(h:sub(65 - i * 2, 66 - i * 2), 16) or 0
		end
		return r
	end

	-- Parse a 32-byte little-endian binary string into a 32-byte LE array.
	--: (string) -> { [integer]: number }
	local function bin32(s)
		local r = {} --: { [integer]: number }
		for i = 1, 32 do r[i] = string.byte(s, i) or 0 end
		return r
	end

	-- Serialize a 32-byte LE array to a binary string.
	--: ({ [integer]: number }) -> string
	local function to_bin32(a)
		local t = {} --: { [integer]: string }
		for i = 1, 32 do t[i] = string.char(a[i] or 0) end
		return table.concat(t)
	end

	-- Compare two n-byte LE arrays. Returns -1, 0, or 1.
	local function le_cmp(a, b, n)
		n = n or 32
		for i = n, 1, -1 do
			if a[i] < b[i] then return -1
			elseif a[i] > b[i] then return 1
			end
		end
		return 0
	end

	-- Shallow copy of a 32-byte array.
	--: ({ [integer]: number }) -> { [integer]: number }
	local function copy32(a)
		local r = {} --: { [integer]: number }
		for i = 1, 32 do r[i] = a[i] or 0 end
		return r
	end

	-- ── Constants ─────────────────────────────────────────────────────────────

	local ZERO32 = {} --: { [integer]: number }
	for i = 1, 32 do ZERO32[i] = 0 end
	local ONE32 = {} --: { [integer]: number }
	for i = 1, 32 do ONE32[i] = 0 end; ONE32[1] = 1
	local TWO32 = {} --: { [integer]: number }
	for i = 1, 32 do TWO32[i] = 0 end; TWO32[1] = 2

	-- Field prime p = 2^255 - 19
	local P = hex32("7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed")

	-- Group order l = 2^252 + 27742317777372353535851937790883648493
	local L = hex32("1000000000000000000000000000000014def9dea2f79cd65812631a5cf5d3ed")

	-- ── Field arithmetic in GF(p) ─────────────────────────────────────────────

	-- Multiply two 32-byte LE integers; result is 64 bytes (no reduction).
	--: ({ [integer]: number }, { [integer]: number }) -> { [integer]: number }
	local function mul_raw(a, b)
		local r = {} --: { [integer]: number }
		for i = 1, 64 do r[i] = 0 end
		for i = 1, 32 do
			if (a[i] or 0) ~= 0 then
				local carry = 0
				for j = 1, 32 do
					local s = (r[i + j - 1] or 0) + (a[i] or 0) * (b[j] or 0) + carry
					r[i + j - 1] = s % 256
					carry = math.floor(s / 256)
				end
				r[i + 32] = (r[i + 32] or 0) + carry
			end
		end
		return r
	end

	-- Reduce a 64-byte LE integer modulo p = 2^255 - 19.
	-- Uses identity 2^256 ≡ 38 (mod p).
	--: ({ [integer]: number }) -> { [integer]: number }
	local function reduce_p(r)
		local acc = {} --: { [integer]: number }
		for i = 1, 32 do acc[i] = r[i] end
		local carry = 0
		for i = 1, 32 do
			local s = acc[i] + r[i + 32] * 38 + carry
			acc[i] = s % 256
			carry  = math.floor(s / 256)
		end
		-- carry * 38 residual
		if carry > 0 then
			local i = 1
			carry = carry * 38
			while carry > 0 and i <= 32 do
				local s = acc[i] + carry
				acc[i] = s % 256
				carry  = math.floor(s / 256)
				i = i + 1
			end
		end
		-- Final conditional subtraction (at most twice)
		for _ = 1, 2 do
			if le_cmp(acc, P) >= 0 then
				local borrow = 0
				for i = 1, 32 do
					local d = acc[i] - P[i] - borrow
					if d < 0 then acc[i] = d + 256; borrow = 1
					else acc[i] = d; borrow = 0
					end
				end
			end
		end
		return acc
	end

	--: ({ [integer]: number }, { [integer]: number }) -> { [integer]: number }
	local function fmul(a, b) return reduce_p(mul_raw(a, b)) end

	--: ({ [integer]: number }, { [integer]: number }) -> { [integer]: number }
	local function fadd(a, b)
		local r = {} --: { [integer]: number }
		local carry = 0
		for i = 1, 32 do
			local s = (a[i] or 0) + (b[i] or 0) + carry
			r[i] = s % 256; carry = math.floor(s / 256)
		end
		if carry > 0 or le_cmp(r, P) >= 0 then
			local borrow = 0
			for i = 1, 32 do
				local d = (r[i] or 0) - (P[i] or 0) - borrow
				if d < 0 then r[i] = d + 256; borrow = 1 else r[i] = d; borrow = 0 end
			end
		end
		return r
	end

	--: ({ [integer]: number }, { [integer]: number }) -> { [integer]: number }
	local function fsub(a, b)
		local r = {} --: { [integer]: number }
		local borrow = 0
		for i = 1, 32 do
			local d = (a[i] or 0) - (b[i] or 0) - borrow
			if d < 0 then r[i] = d + 256; borrow = 1 else r[i] = d; borrow = 0 end
		end
		if borrow > 0 then
			local carry = 0
			for i = 1, 32 do
				local s = (r[i] or 0) + (P[i] or 0) + carry
				r[i] = s % 256; carry = math.floor(s / 256)
			end
		end
		return r
	end

	--: ({ [integer]: number }) -> { [integer]: number }
	local function fneg(a) return fsub(P, a) end

	--: ({ [integer]: number }, { [integer]: number }) -> boolean
	local function feq(a, b) return le_cmp(a, b) == 0 end

	-- Field exponentiation: a^e mod p (e is a 32-byte LE integer).
	--: ({ [integer]: number }, { [integer]: number }) -> { [integer]: number }
	local function fpow(a, e)
		local r    = copy32(ONE32)
		local base = copy32(a)
		for byte_i = 1, 32 do
			local eb = e[byte_i]
			for bit_j = 0, 7 do
				if bit.band(eb, bit.lshift(1, bit_j)) ~= 0 then
					r = fmul(r, base)
				end
				base = fmul(base, base)
			end
		end
		return r
	end

	-- p - 2 in LE (for Fermat inversion)
	local P_MINUS2 = (function()
		local borrow = 0; local r = {}
		for i = 1, 32 do
			local d = P[i] - TWO32[i] - borrow
			if d < 0 then r[i] = d + 256; borrow = 1 else r[i] = d; borrow = 0 end
		end
		return r
	end)()

	local function finv(a) return fpow(a, P_MINUS2) end

	-- (p+3)/8 in LE: 2^252 - 2
	-- = 0x0ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe (BE)
	local P_PLUS3_DIV8 = hex32("0ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe")

	-- sqrt(-1) mod p = 2^((p-1)/4) mod p
	-- (p-1)/4 = 2^253 - 5 in LE: [0xfb, 0xff, ..., 0xff, 0x1f]
	local PM1_DIV4 = (function()
		local r = {} --: { [integer]: number }
		for i = 1, 31 do r[i] = 0xff end
		r[1] = 0xfb; r[32] = 0x1f
		return r
	end)()
	local SQRT_M1 = fpow(TWO32, PM1_DIV4)

	-- ── Edwards curve constants ───────────────────────────────────────────────
	-- Twisted Edwards curve: -x^2 + y^2 = 1 + d*x^2*y^2
	-- d = -121665/121666 mod p

	-- d = 0x52036cee2b6ffe738cc740797779e89800700a4d4141d8ab75eb4dca135978a3 (BE)
	local D = hex32("52036cee2b6ffe738cc740797779e89800700a4d4141d8ab75eb4dca135978a3")
	local D2 = fadd(D, D)

	-- Base point:
	-- By = 4/5 mod p
	-- Bx = sqrt((By^2 - 1) / (d*By^2 + 1)), positive (low bit 0)
	local FOUR = copy32(ZERO32); FOUR[1] = 4
	local FIVE = copy32(ZERO32); FIVE[1] = 5
	local BASE_Y = fmul(FOUR, finv(FIVE))
	local BASE_X = (function()
		local y  = BASE_Y
		local y2 = fmul(y, y)
		local u  = fsub(y2, ONE32)
		local v  = fadd(fmul(D, y2), ONE32)
		local uv = fmul(u, finv(v))
		local x  = fpow(uv, P_PLUS3_DIV8)
		-- Check x^2 * v == u; if not, multiply by sqrt(-1)
		local x2v = fmul(fmul(x, x), v)
		if not feq(x2v, u) then x = fmul(x, SQRT_M1) end
		-- Choose positive root (low bit 0)
		if bit.band(x[1], 1) ~= 0 then x = fneg(x) end
		return x
	end)()

	-- ── Extended twisted Edwards point arithmetic ─────────────────────────────
	-- Point: {X, Y, Z, T} where x = X/Z, y = Y/Z, T = X*Y/Z

	-- Neutral element: (0 : 1 : 1 : 0)
	--: { [integer]: { [integer]: number } }
	local NEUTRAL = {
		copy32(ZERO32), copy32(ONE32), copy32(ONE32), copy32(ZERO32)
	}

	-- Base point in extended coordinates, Z = 1
	--: { [integer]: { [integer]: number } }
	local BASE_PT = {
		copy32(BASE_X), copy32(BASE_Y), copy32(ONE32), fmul(BASE_X, BASE_Y)
	}

	-- Unified point addition (add-2008-hwcd, extended twisted Edwards)
	-- https://hyperelliptic.org/EFD/g1p/auto-twisted-extended.html#addition-add-2008-hwcd
	--: ({ [integer]: { [integer]: number } }, { [integer]: { [integer]: number } }) -> { [integer]: { [integer]: number } }
	local function point_add(p1, p2)
		local X1, Y1, Z1, T1 = p1[1], p1[2], p1[3], p1[4]
		local X2, Y2, Z2, T2 = p2[1], p2[2], p2[3], p2[4]
		local A  = fmul(fsub(Y1, X1), fsub(Y2, X2))
		local B  = fmul(fadd(Y1, X1), fadd(Y2, X2))
		local C  = fmul(fmul(T1, T2), D2)
		local D_ = fmul(fmul(Z1, Z2), TWO32)
		local E  = fsub(B, A)
		local F  = fsub(D_, C)
		local G  = fadd(D_, C)
		local H  = fadd(B, A)
		return { fmul(E, F), fmul(G, H), fmul(F, G), fmul(E, H) }
	end

	-- Scalar multiplication: n * P (n is a 32-byte LE integer)
	--: ({ [integer]: number }, { [integer]: { [integer]: number } }) -> { [integer]: { [integer]: number } }
	local function scalar_mult(n, pt)
		--: { [integer]: { [integer]: number } }
		local result = {
			copy32(NEUTRAL[1]), copy32(NEUTRAL[2]),
			copy32(NEUTRAL[3]), copy32(NEUTRAL[4])
		}
		--: { [integer]: { [integer]: number } }
		local addend = {
			copy32(pt[1]), copy32(pt[2]),
			copy32(pt[3]), copy32(pt[4])
		}
		for byte_i = 1, 32 do
			local nb = n[byte_i]
			for bit_j = 0, 7 do
				if bit.band(nb, bit.lshift(1, bit_j)) ~= 0 then
					result = point_add(result, addend)
				end
				addend = point_add(addend, addend)
			end
		end
		return result
	end

	-- Encode a point to 32 bytes (RFC 8032 §5.1.2)
	--: ({ [integer]: { [integer]: number } }) -> { [integer]: number }
	local function encode_point(pt)
		local Zinv = finv(pt[3])
		local x    = fmul(pt[1], Zinv)
		local y    = fmul(pt[2], Zinv)
		local out  = copy32(y)
		-- Store low bit of x in the high bit of the last byte
		out[32] = bit.bor(out[32], bit.lshift(bit.band(x[1], 1), 7))
		return out
	end

	-- Decode a 32-byte point (RFC 8032 §5.1.3)
	-- Returns a point table on success, or nil, errmsg on failure.
	--: ({ [integer]: number }) -> ({ [integer]: { [integer]: number } } | nil, string | nil)
	local function decode_point(bytes)
		local sign = bit.band(bit.rshift(bytes[32], 7), 1)
		local y    = copy32(bytes)
		y[32]      = bit.band(y[32], 0x7f)

		-- Recover x from y: x^2 = (y^2 - 1) / (d*y^2 + 1)
		local y2   = fmul(y, y)
		local u    = fsub(y2, ONE32)
		local v    = fadd(fmul(D, y2), ONE32)
		local uv   = fmul(u, finv(v))
		local x    = fpow(uv, P_PLUS3_DIV8)

		-- Verify square root
		local x2v  = fmul(fmul(x, x), v)
		if feq(x2v, u) then
			-- x is the correct root
		elseif feq(x2v, fneg(u)) then
			x = fmul(x, SQRT_M1)
		else
			return nil, "point not on curve"
		end

		-- Select the root with the correct sign
		if bit.band(x[1], 1) ~= sign then
			x = fneg(x)
		end

		-- (0, y) with sign bit 1 is invalid
		if feq(x, ZERO32) and sign == 1 then
			return nil, "invalid point encoding (x=0 with sign=1)"
		end

		return { copy32(x), copy32(y), copy32(ONE32), fmul(x, y) }
	end

	-- ── Scalar arithmetic mod l ───────────────────────────────────────────────

	-- Add two 32-byte LE integers mod l.
	local function scalar_add_mod_l(a, b)
		local r = {}; local carry = 0
		for i = 1, 32 do
			local s = a[i] + b[i] + carry
			r[i] = s % 256; carry = math.floor(s / 256)
		end
		if carry > 0 or le_cmp(r, L) >= 0 then
			local borrow = 0
			for i = 1, 32 do
				local d = r[i] - L[i] - borrow
				if d < 0 then r[i] = d + 256; borrow = 1 else r[i] = d; borrow = 0 end
			end
		end
		return r
	end

	-- Reduce a (up to 64-byte) LE integer mod l.
	-- Uses binary long division for correctness (not speed).
	--: ({ [integer]: number }, integer | nil) -> { [integer]: number }
	local function reduce_l(bytes, n)
		n = n or 64
		-- Extend to 64 bytes
		local a = {} --: { [integer]: number }
		for i = 1,  n do a[i] = bytes[i] or 0 end
		for i = n + 1, 64 do a[i] = 0 end

		-- Convert to big-endian for easier bit manipulation
		local a_be = {} --: { [integer]: number }
		for i = 1, 64 do a_be[i] = a[65 - i] or 0 end
		local l_be = {} --: { [integer]: number }
		for i = 1, 32 do l_be[i] = L[33 - i] or 0 end
		-- Extend L to 64 bytes BE (pad high bytes with 0)
		local l64 = {} --: { [integer]: number }
		for i = 1, 32 do l64[i] = 0 end
		for i = 1, 32 do l64[32 + i] = l_be[i] or 0 end

		-- Find position of highest set bit in big-endian 64-byte array
		local function msb(x)
			for i = 1, 64 do
				if x[i] ~= 0 then
					local v = x[i]; local pos = (64 - i) * 8
					while v >= 2 do v = math.floor(v / 2); pos = pos + 1 end
					return pos
				end
			end
			return -1
		end

		-- Subtract big-endian arrays (x -= y, assuming x >= y)
		--: ({ [integer]: number }, { [integer]: number }) -> { [integer]: number }
		local function be_sub(x, y)
			local r = {} --: { [integer]: number }
			for i = 1, 64 do r[i] = x[i] end
			local borrow = 0
			for i = 64, 1, -1 do
				local d = r[i] - y[i] - borrow
				if d < 0 then r[i] = d + 256; borrow = 1 else r[i] = d; borrow = 0 end
			end
			return r
		end

		-- Compare big-endian arrays
		local function be_cmp(x, y)
			for i = 1, 64 do
				if x[i] < y[i] then return -1 elseif x[i] > y[i] then return 1 end
			end
			return 0
		end

		-- Shift big-endian array left by 1 bit
		local function be_shl1(x)
			local r = {}; local carry = 0
			for i = 64, 1, -1 do
				local v = x[i] * 2 + carry
				r[i] = v % 256; carry = math.floor(v / 256)
			end
			return r
		end

		-- Shift big-endian array right by 1 bit
		local function be_shr1(x)
			local r = {}; local carry = 0
			for i = 1, 64 do
				local v = x[i] + carry * 256
				r[i] = math.floor(v / 2); carry = v % 2
			end
			return r
		end

		local a_bits = msb(a_be)
		local l_bits = msb(l64)

		if a_bits < l_bits then
			-- a < l; return low 32 bytes in LE
			local r = {}
			for i = 1, 32 do r[i] = a_be[65 - i] end
			return r
		end

		-- Align l64 to the top bit of a_be
		local shift = a_bits - l_bits
		local l_shifted = {}
		for i = 1, 64 do l_shifted[i] = l64[i] end
		for _ = 1, shift do
			l_shifted = be_shl1(l_shifted)
		end

		-- Binary long division: subtract l_shifted if a_be >= l_shifted
		for _ = 0, shift do
			if be_cmp(a_be, l_shifted) >= 0 then
				a_be = be_sub(a_be, l_shifted)
			end
			l_shifted = be_shr1(l_shifted)
		end

		-- Convert result (64-byte BE) back to 32-byte LE
		local r = {}
		for i = 1, 32 do r[i] = a_be[65 - i] end
		return r
	end

	-- Multiply two 32-byte LE scalars mod l.
	local function scalar_mul_mod_l(a, b)
		local r64 = mul_raw(a, b)
		return reduce_l(r64, 64)
	end

	-- ── RFC 8032 §5.1 key operations ──────────────────────────────────────────

	-- Hash seed with SHA-512, clamp, and return (a_scalar, nonce_prefix).
	local function clamp_and_hash(seed)
		local h = sha512(seed)
		-- a_bytes: first 32 bytes of hash, clamped (RFC 8032 §5.1.5)
		local a = {} --: { [integer]: number }
		for i = 1, 32 do a[i] = string.byte(h, i) or 0 end
		a[1]  = bit.band(a[1],  248)  -- clear low 3 bits
		a[32] = bit.band(a[32], 127)  -- clear high bit
		a[32] = bit.bor(a[32],   64)  -- set second-highest bit
		-- nonce_prefix: bytes 33..64 of hash
		local prefix = {} --: { [integer]: number }
		for i = 1, 32 do prefix[i] = string.byte(h, i + 32) or 0 end
		return a, prefix
	end

	-- Generate public key from 32-byte seed.
	local function pubkey_from_seed(seed)
		local a = clamp_and_hash(seed)
		local pt = scalar_mult(a, BASE_PT)
		return encode_point(pt)
	end

	-- ── Public functions ──────────────────────────────────────────────────────

	local function keypair(seed_input, random_bytes_fn)
		if seed_input and #seed_input ~= 32 then
			return nil, "seed must be 32 bytes"
		end
		local seed --: string | nil
		if seed_input then
			seed = seed_input
		else
			if type(random_bytes_fn) ~= "function" then
				return nil, "random_bytes_fn is required when seed is nil"
			end
			seed = random_bytes_fn(32) --[[:! string | nil]]
			if not seed then return nil, "failed to read 32 random bytes" end
			if #seed ~= 32 then return nil, "failed to read 32 random bytes" end
		end
		if not seed then return nil, "seed unavailable" end
		local seed_str = seed --[[:! string]]
		local pub_bytes = pubkey_from_seed(seed_str)
		local pub_str   = to_bin32(pub_bytes)
		-- Private key = seed (32) || public key (32)
		return seed_str .. pub_str, pub_str
	end

	local function sign(privkey, message)
		if type(privkey) ~= "string" or #privkey ~= 64 then
			return nil, "private key must be 64 bytes"
		end
		local seed    = privkey:sub(1, 32)
		local pub_str = privkey:sub(33, 64)

		local a_scalar, nonce_prefix = clamp_and_hash(seed)

		-- r = SHA-512(nonce_prefix || message) mod l
		local prefix_str = to_bin32(nonce_prefix)
		local r_hash     = sha512(prefix_str .. message)
		local r_bytes    = {} --: { [integer]: number }
		for i = 1, 64 do r_bytes[i] = string.byte(r_hash, i) or 0 end
		local r_scalar   = reduce_l(r_bytes, 64)

		-- R = r * B
		local R_pt  = scalar_mult(r_scalar, BASE_PT)
		local R_enc = encode_point(R_pt)
		local R_str = to_bin32(R_enc)

		-- k = SHA-512(R || A || message) mod l
		local k_hash   = sha512(R_str .. pub_str .. message)
		local k_bytes  = {} --: { [integer]: number }
		for i = 1, 64 do k_bytes[i] = string.byte(k_hash, i) or 0 end
		local k_scalar = reduce_l(k_bytes, 64)

		-- S = (r + k * a) mod l
		local ka       = scalar_mul_mod_l(k_scalar, a_scalar)
		local S_scalar = scalar_add_mod_l(r_scalar, ka)

		return R_str .. to_bin32(S_scalar)
	end

	local function verify(pubkey, message, signature)
		if type(pubkey) ~= "string" or #pubkey ~= 32 then
			return false, "public key must be 32 bytes"
		end
		if type(signature) ~= "string" or #signature ~= 64 then
			return false, "signature must be 64 bytes"
		end

		-- Decode A (public key)
		local A_bytes = {} --: { [integer]: number }
		for i = 1, 32 do A_bytes[i] = string.byte(pubkey, i) or 0 end
		local A_pt, err = decode_point(A_bytes)
		if not A_pt then return false, "invalid public key: " .. (err or "?") end

		-- Decode R
		local R_bytes = {} --: { [integer]: number }
		for i = 1, 32 do R_bytes[i] = string.byte(signature, i) or 0 end
		local R_pt, err2 = decode_point(R_bytes)
		if not R_pt then return false, "invalid R in signature: " .. (err2 or "?") end

		-- Decode S (scalar, 32 bytes LE)
		local S_bytes = {} --: { [integer]: number }
		for i = 1, 32 do S_bytes[i] = string.byte(signature, i + 32) or 0 end
		if le_cmp(S_bytes, L) >= 0 then
			return false, "S is out of range"
		end

		-- k = SHA-512(R || A || message) mod l
		local R_str  = signature:sub(1, 32)
		local k_hash = sha512(R_str .. pubkey .. message)
		local k_bytes = {} --: { [integer]: number }
		for i = 1, 64 do k_bytes[i] = string.byte(k_hash, i) or 0 end
		local k_scalar = reduce_l(k_bytes, 64)

		-- Check: S*B == R + k*A
		local SB   = scalar_mult(S_bytes, BASE_PT)
		local kA   = scalar_mult(k_scalar, A_pt)
		local RkA  = point_add(R_pt, kA)

		local SB_enc  = encode_point(SB)
		local RkA_enc = encode_point(RkA)

		if le_cmp(SB_enc, RkA_enc) ~= 0 then
			return false, "signature verification failed"
		end
		return true
	end

	return keypair, sign, verify
end

-- ── Tier selection ────────────────────────────────────────────────────────────

-- keypair_fn/sign_fn/verify_fn are typed as any: they are assigned from either
-- the system (libsodium) or pure-Lua tier, each with different signatures;
-- using any avoids a union that would block all calls.
local _init_errmsg = "Ed25519 not yet initialized"
local keypair_fn = function() return nil, _init_errmsg end --[[: any]]
local sign_fn    = function() return nil, _init_errmsg end --[[: any]]
local verify_fn  = function() return false, _init_errmsg end --[[: any]]

local ok_sys = pcall(function()
	keypair_fn, sign_fn, verify_fn = try_system()
end)
if ok_sys then
	M._tier = "system"
else
	local ok_pure, err_pure = pcall(function()
		keypair_fn, sign_fn, verify_fn = make_pure()
	end)
	if not ok_pure then
		local errmsg = "Ed25519 not available: " .. tostring(err_pure)
		keypair_fn = function() return nil, errmsg end
		sign_fn    = function() return nil, errmsg end
		verify_fn  = function() return false, errmsg end
	end
	M._tier = "pure"
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.keypair(seed, random_bytes_fn) return keypair_fn(seed, random_bytes_fn) end
function M.sign(sk, msg)   return sign_fn(sk, msg)                  end
function M.verify(pk, msg, sig) return verify_fn(pk, msg, sig)     end

return M
