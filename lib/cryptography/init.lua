-- lib/cryptography/init.lua
-- Pure Lua cryptographic primitives: SHA-256, SHA-512, HMAC, PBKDF2,
-- ChaCha20, ChaCha20-Poly1305, Poly1305, constant-time compare.
--
-- Public API:
--   M.sha256(data)                               -> hex_string (64 chars)
--   M.sha256_bytes(data)                         -> raw_bytes (32 bytes)
--   M.sha512(data)                               -> hex_string (128 chars)
--   M.sha512_bytes(data)                         -> raw_bytes (64 bytes)
--   M.hmac_sha256(key, data)                     -> hex_string
--   M.hmac_sha512(key, data)                     -> hex_string
--   M.pbkdf2(password, salt, iters, key_len, h?) -> raw_bytes | (nil, errmsg)
--   M.chacha20(key, nonce, counter, data)        -> ciphertext | (nil, errmsg)
--   M.chacha20_poly1305_encrypt(key, nonce, pt, aad?) -> ct_with_tag | (nil, errmsg)
--   M.chacha20_poly1305_decrypt(key, nonce, ct,  aad?) -> plaintext  | (nil, errmsg)
--   M.poly1305(key, data)                        -> 16-byte tag
--   M.ct_eq(a, b)                                -> bool
--   M.random_bytes(n)                            -> string (NOT crypto-secure without /dev/urandom)
--   M.hex(bytes)                                 -> hex_string
--   M.unhex(hex_string)                          -> bytes | nil
--   M._tier = "pure"

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local bit    = require("bit")
local band   = bit.band
local bxor   = bit.bxor
local bor    = bit.bor
local bnot   = bit.bnot
local lshift = bit.lshift
local rshift = bit.rshift
local rol    = bit.rol
local ror    = bit.ror
local tobit  = bit.tobit

local M = {}
M._tier = "pure"

-- ── Utilities ────────────────────────────────────────────────────────────────

-- Convert bytes string to hex.
--: (string) -> string
function M.hex(bytes)
	local out = {}
	for i = 1, #bytes do
		out[i] = string.format("%02x", string.byte(bytes, i))
	end
	return table.concat(out)
end

-- Convert hex string to bytes, or nil on invalid input.
--: (string) -> string | nil
function M.unhex(s)
	if #s % 2 ~= 0 then return nil end
	if s:find("[^0-9a-fA-F]") then return nil end
	local result = (s:gsub("..", function(h) return string.char((tonumber(h, 16) or 0) --[[:! integer]]) end)) --[[: string]]
	return result
end

-- Read a big-endian uint32 from string at 1-based offset.
--: (string, integer) -> integer
local function u32be(s, off)
	local a = string.byte(s, off)     or 0
	local b = string.byte(s, off + 1) or 0
	local c = string.byte(s, off + 2) or 0
	local d = string.byte(s, off + 3) or 0
	-- Use unsigned arithmetic via tobit trick: build the value then mask.
	-- For values where MSB is set, the double sum is correct; tobit signs it.
	return tobit(a * 0x1000000 + b * 0x10000 + c * 0x100 + d)
end

-- Read a little-endian uint32 from string at 0-based offset.
--: (string, integer) -> integer
local function u32le(s, off)
	local a = string.byte(s, off + 1) or 0
	local b = string.byte(s, off + 2) or 0
	local c = string.byte(s, off + 3) or 0
	local d = string.byte(s, off + 4) or 0
	return tobit(a + b * 0x100 + c * 0x10000 + d * 0x1000000)
end

-- Write a little-endian uint32 into byte table at 1-based position.
--: ({ [integer]: integer }, integer, number) -> ()
local function put_u32le(t, pos, v)
	local vi = tobit(v)
	t[pos]     = band(vi, 0xff)
	t[pos + 1] = band(rshift(vi, 8), 0xff)
	t[pos + 2] = band(rshift(vi, 16), 0xff)
	t[pos + 3] = band(rshift(vi, 24), 0xff)
end

-- Write a big-endian uint32 into byte table at 1-based position.
--: ({ [integer]: integer }, integer, integer) -> ()
local function put_u32be(t, pos, v)
	t[pos]     = band(rshift(v, 24), 0xff)
	t[pos + 1] = band(rshift(v, 16), 0xff)
	t[pos + 2] = band(rshift(v, 8), 0xff)
	t[pos + 3] = band(v, 0xff)
end

-- Convert unsigned representation: tobit() produces signed, so correct.
--: (number) -> number
local function unsigned(v)
	if v < 0 then return v + 0x100000000 end
	return v
end

-- ── SHA-256 ──────────────────────────────────────────────────────────────────

-- SHA-256 round constants (first 32 bits of fractional cube roots of primes 2..311).
local SHA256_K = { --: { [integer]: number }
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
	0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
	0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
	0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
	0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
	0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
	0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
	0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
	0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

-- SHA-256 initial hash values (first 32 bits of fractional sqrt of primes 2..19).
local SHA256_H0 = { --: { [integer]: number }
	0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
	0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

-- Reusable message schedule array (avoids per-block allocation in hot path).
local sha256_W = {} --: { [integer]: integer }
for i = 1, 64 do sha256_W[i] = 0 end

-- Compress one 64-byte SHA-256 block. h is an 8-element array of uint32 (signed via bit.*).
--: (string, integer, { [integer]: number }) -> ()
local function sha256_compress(msg, offset, h)
	local W = sha256_W
	-- Load 16 big-endian words from msg at byte offset (1-based string).
	for i = 0, 15 do
		local o = offset + i * 4
		W[i + 1] = tobit(u32be(msg, o + 1))
	end
	-- Extend schedule.
	for i = 17, 64 do
		local w15 = W[i - 15]
		local w2  = W[i - 2]
		local s0  = bxor(ror(w15, 7),  ror(w15, 18), rshift(w15, 3))
		local s1  = bxor(ror(w2,  17), ror(w2,  19), rshift(w2,  10))
		W[i] = tobit(W[i - 16] + s0 + W[i - 7] + s1)
	end

	local a = tobit(h[1]); local b = tobit(h[2])
	local c = tobit(h[3]); local d = tobit(h[4])
	local e = tobit(h[5]); local f = tobit(h[6])
	local g = tobit(h[7]); local hh = tobit(h[8])

	for i = 1, 64 do
		local S1    = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
		local ch    = bxor(band(e, f), band(bnot(e), g))
		local temp1 = tobit(hh + S1 + ch + SHA256_K[i] + W[i])
		local S0    = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
		local maj   = bxor(band(a, b), band(a, c), band(b, c))
		local temp2 = tobit(S0 + maj)

		hh = g; g = f; f = e
		e  = tobit(d + temp1)
		d  = c; c = b; b = a
		a  = tobit(temp1 + temp2)
	end

	h[1] = tobit(h[1] + a); h[2] = tobit(h[2] + b)
	h[3] = tobit(h[3] + c); h[4] = tobit(h[4] + d)
	h[5] = tobit(h[5] + e); h[6] = tobit(h[6] + f)
	h[7] = tobit(h[7] + g); h[8] = tobit(h[8] + hh)
end

-- Internal SHA-256 returning 8-word hash array.
--: (string) -> { [integer]: number }
local function sha256_raw(data)
	local h = {} --: { [integer]: number }
	for i = 1, 8 do h[i] = SHA256_H0[i] end

	local len    = #data
	local padlen = 64 - ((len + 9) % 64)
	if padlen == 64 then padlen = 0 end
	-- Build padded message: original || 0x80 || zeros || 64-bit big-endian bit length.
	local bits_hi = math.floor(len / 0x20000000)  -- len*8 high 32 bits (len in bytes)
	local bits_lo = (len * 8) % 0x100000000

	local padded = data
		.. "\x80"
		.. string.rep("\0", padlen)
		.. string.char(
			math.floor(bits_hi / 0x1000000) % 256,
			math.floor(bits_hi / 0x10000)   % 256,
			math.floor(bits_hi / 0x100)     % 256,
			bits_hi % 256,
			math.floor(bits_lo / 0x1000000) % 256,
			math.floor(bits_lo / 0x10000)   % 256,
			math.floor(bits_lo / 0x100)     % 256,
			bits_lo % 256
		)

	local nblocks = math.floor(#padded / 64)
	for blk = 0, nblocks - 1 do
		sha256_compress(padded, blk * 64, h)
	end
	return h
end

-- SHA-256: returns 32-byte raw digest.
--: (string) -> string
function M.sha256_bytes(data)
	local h   = sha256_raw(data)
	local out = {}
	for i = 1, 8 do
		put_u32be(out, (i - 1) * 4 + 1, tobit(h[i]))
	end
	local bytes = {}
	for i = 1, 32 do bytes[i] = string.char(out[i]) end
	return table.concat(bytes)
end

-- SHA-256: returns 64-char lowercase hex digest.
--: (string) -> string
function M.sha256(data)
	return M.hex(M.sha256_bytes(data))
end

-- ── SHA-512 ──────────────────────────────────────────────────────────────────
-- SHA-512 requires 64-bit integer arithmetic.  We represent each 64-bit word
-- as a pair of Lua numbers: (hi, lo) each 32-bit unsigned (stored as Lua doubles).

-- SHA-512 round constants (first 64 bits of cube roots of first 80 primes).
-- Stored as {hi, lo} pairs (each 32-bit unsigned).
local SHA512_K = { --: { [integer]: { [integer]: number } }
	{0x428a2f98, 0xd728ae22}, {0x71374491, 0x23ef65cd},
	{0xb5c0fbcf, 0xec4d3b2f}, {0xe9b5dba5, 0x8189dbbc},
	{0x3956c25b, 0xf348b538}, {0x59f111f1, 0xb605d019},
	{0x923f82a4, 0xaf194f9b}, {0xab1c5ed5, 0xda6d8118},
	{0xd807aa98, 0xa3030242}, {0x12835b01, 0x45706fbe},
	{0x243185be, 0x4ee4b28c}, {0x550c7dc3, 0xd5ffb4e2},
	{0x72be5d74, 0xf27b896f}, {0x80deb1fe, 0x3b1696b1},
	{0x9bdc06a7, 0x25c71235}, {0xc19bf174, 0xcf692694},
	{0xe49b69c1, 0x9ef14ad2}, {0xefbe4786, 0x384f25e3},
	{0x0fc19dc6, 0x8b8cd5b5}, {0x240ca1cc, 0x77ac9c65},
	{0x2de92c6f, 0x592b0275}, {0x4a7484aa, 0x6ea6e483},
	{0x5cb0a9dc, 0xbd41fbd4}, {0x76f988da, 0x831153b5},
	{0x983e5152, 0xee66dfab}, {0xa831c66d, 0x2db43210},
	{0xb00327c8, 0x98fb213f}, {0xbf597fc7, 0xbeef0ee4},
	{0xc6e00bf3, 0x3da88fc2}, {0xd5a79147, 0x930aa725},
	{0x06ca6351, 0xe003826f}, {0x14292967, 0x0a0e6e70},
	{0x27b70a85, 0x46d22ffc}, {0x2e1b2138, 0x5c26c926},
	{0x4d2c6dfc, 0x5ac42aed}, {0x53380d13, 0x9d95b3df},
	{0x650a7354, 0x8baf63de}, {0x766a0abb, 0x3c77b2a8},
	{0x81c2c92e, 0x47edaee6}, {0x92722c85, 0x1482353b},
	{0xa2bfe8a1, 0x4cf10364}, {0xa81a664b, 0xbc423001},
	{0xc24b8b70, 0xd0f89791}, {0xc76c51a3, 0x0654be30},
	{0xd192e819, 0xd6ef5218}, {0xd6990624, 0x5565a910},
	{0xf40e3585, 0x5771202a}, {0x106aa070, 0x32bbd1b8},
	{0x19a4c116, 0xb8d2d0c8}, {0x1e376c08, 0x5141ab53},
	{0x2748774c, 0xdf8eeb99}, {0x34b0bcb5, 0xe19b48a8},
	{0x391c0cb3, 0xc5c95a63}, {0x4ed8aa4a, 0xe3418acb},
	{0x5b9cca4f, 0x7763e373}, {0x682e6ff3, 0xd6b2b8a3},
	{0x748f82ee, 0x5defb2fc}, {0x78a5636f, 0x43172f60},
	{0x84c87814, 0xa1f0ab72}, {0x8cc70208, 0x1a6439ec},
	{0x90befffa, 0x23631e28}, {0xa4506ceb, 0xde82bde9},
	{0xbef9a3f7, 0xb2c67915}, {0xc67178f2, 0xe372532b},
	{0xca273ece, 0xea26619c}, {0xd186b8c7, 0x21c0c207},
	{0xeada7dd6, 0xcde0eb1e}, {0xf57d4f7f, 0xee6ed178},
	{0x06f067aa, 0x72176fba}, {0x0a637dc5, 0xa2c898a6},
	{0x113f9804, 0xbef90dae}, {0x1b710b35, 0x131c471b},
	{0x28db77f5, 0x23047d84}, {0x32caab7b, 0x40c72493},
	{0x3c9ebe0a, 0x15c9bebc}, {0x431d67c4, 0x9c100d4c},
	{0x4cc5d4be, 0xcb3e42b6}, {0x597f299c, 0xfc657e2a},
	{0x5fcb6fab, 0x3ad6faec}, {0x6c44198c, 0x4a475817},
}

-- SHA-512 initial hash values (sqrt of primes 2..19).
local SHA512_H0 = { --: { [integer]: { [integer]: number } }
	{0x6a09e667, 0xf3bcc908}, {0xbb67ae85, 0x84caa73b},
	{0x3c6ef372, 0xfe94f82b}, {0xa54ff53a, 0x5f1d36f1},
	{0x510e527f, 0xade682d1}, {0x9b05688c, 0x2b3e6c1f},
	{0x1f83d9ab, 0xfb41bd6b}, {0x5be0cd19, 0x137e2179},
}

-- 64-bit add: (hi1,lo1) + (hi2,lo2) -> (hi, lo), all 32-bit unsigned.
--: (number, number, number, number) -> (number, number)
local function add64(ah, al, bh, bl)
	local lo = al + bl
	local carry = math.floor(lo / 0x100000000)
	lo = lo % 0x100000000
	local hi = (ah + bh + carry) % 0x100000000
	return hi, lo
end

-- 64-bit XOR.
--: (number, number, number, number) -> (number, number)
local function xor64(ah, al, bh, bl)
	return unsigned(bxor(tobit(ah), tobit(bh))), unsigned(bxor(tobit(al), tobit(bl)))
end

-- 64-bit right-rotate by n bits (n < 32 or n >= 32 handled).
--: (number, number, integer) -> (number, number)
local function ror64(hi, lo, n)
	if n == 0 then return hi, lo end
	if n >= 32 then
		-- swap halves first, then rotate remainder
		hi, lo = lo, hi
		n = tobit(n - 32) --[[:! integer]]
	end
	if n == 0 then return hi, lo end
	local n_ = n --[[:! integer]]
	local nh = bor(rshift(tobit(hi), n_), lshift(tobit(lo), 32 - n_))
	local nl = bor(rshift(tobit(lo), n_), lshift(tobit(hi), 32 - n_))
	return unsigned(nh), unsigned(nl)
end

-- 64-bit right-shift by n bits.
--: (number, number, integer) -> (number, number)
local function shr64(hi, lo, n)
	if n == 0 then return hi, lo end
	if n >= 32 then
		return 0, rshift(tobit(hi), tobit(n - 32)) % 0x100000000
	end
	local n_ = n --[[:! integer]]
	local nh = rshift(tobit(hi), n_)
	local nl = bor(rshift(tobit(lo), n_), lshift(tobit(hi), 32 - n_))
	return unsigned(nh), unsigned(nl)
end

-- SHA-512 message schedule: 160 entries (80 pairs hi/lo), stored flat: W[2i-1]=hi, W[2i]=lo.
local sha512_W = {} --: { [integer]: number }
for i = 1, 160 do sha512_W[i] = 0 end

-- Compress one 128-byte SHA-512 block. h is a flat array: h[2i-1]=hi, h[2i]=lo.
--: (string, integer, { [integer]: number }) -> ()
local function sha512_compress(msg, offset, h)
	local W = sha512_W
	-- Load 16 big-endian 64-bit words (each word = 2 x 32-bit).
	for i = 0, 15 do
		local o = offset + i * 8
		local a  = (string.byte(msg, o + 1, o + 1) or 0) --[[:! integer]]
		local b  = (string.byte(msg, o + 2, o + 2) or 0) --[[:! integer]]
		local c  = (string.byte(msg, o + 3, o + 3) or 0) --[[:! integer]]
		local d  = (string.byte(msg, o + 4, o + 4) or 0) --[[:! integer]]
		local e  = (string.byte(msg, o + 5, o + 5) or 0) --[[:! integer]]
		local f  = (string.byte(msg, o + 6, o + 6) or 0) --[[:! integer]]
		local g  = (string.byte(msg, o + 7, o + 7) or 0) --[[:! integer]]
		local hb = (string.byte(msg, o + 8, o + 8) or 0) --[[:! integer]]
		W[i * 2 + 1] = a * 0x1000000 + b * 0x10000 + c * 0x100 + d  -- hi
		W[i * 2 + 2] = e * 0x1000000 + f * 0x10000 + g * 0x100 + hb -- lo
	end
	-- Extend schedule to 80 words.
	for i = 16, 79 do
		local w15h, w15l = W[(i-15)*2+1], W[(i-15)*2+2]
		local w2h,  w2l  = W[(i-2) *2+1], W[(i-2) *2+2]

		local r1h, r1l = ror64(w15h, w15l, 1)
		local r8h, r8l = ror64(w15h, w15l, 8)
		local s7h, s7l = shr64(w15h, w15l, 7)
		local s0h = unsigned(bxor(tobit(r1h), tobit(r8h), tobit(s7h)))
		local s0l = unsigned(bxor(tobit(r1l), tobit(r8l), tobit(s7l)))

		local r19h, r19l = ror64(w2h, w2l, 19)
		local r61h, r61l = ror64(w2h, w2l, 61)
		local s6h,  s6l  = shr64(w2h, w2l, 6)
		local s1h = unsigned(bxor(tobit(r19h), tobit(r61h), tobit(s6h)))
		local s1l = unsigned(bxor(tobit(r19l), tobit(r61l), tobit(s6l)))

		local w16h, w16l = W[(i-16)*2+1], W[(i-16)*2+2]
		local w7h,  w7l  = W[(i-7) *2+1], W[(i-7) *2+2]

		local nh, nl = add64(w16h, w16l, s0h, s0l)
		    nh, nl = add64(nh, nl, w7h, w7l)
		    nh, nl = add64(nh, nl, s1h, s1l)
		W[i*2+1] = nh
		W[i*2+2] = nl
	end

	-- Working vars (hi, lo pairs).
	local ah, al = h[1],  h[2]
	local bh, bl = h[3],  h[4]
	local ch, cl = h[5],  h[6]
	local dh, dl = h[7],  h[8]
	local eh, el = h[9],  h[10]
	local fh, fl = h[11], h[12]
	local gh, gl = h[13], h[14]
	local hh, hl = h[15], h[16]

	for i = 0, 79 do
		local kh, kl = SHA512_K[i+1][1], SHA512_K[i+1][2]
		local wh, wl = W[i*2+1], W[i*2+2]

		-- S1 = ror(e,14) ^ ror(e,18) ^ ror(e,41)
		local r14h, r14l = ror64(eh, el, 14)
		local r18h, r18l = ror64(eh, el, 18)
		local r41h, r41l = ror64(eh, el, 41)
		local S1h = unsigned(bxor(tobit(r14h), tobit(r18h), tobit(r41h)))
		local S1l = unsigned(bxor(tobit(r14l), tobit(r18l), tobit(r41l)))

		-- Ch = (e & f) ^ (~e & g)
		local chxh = unsigned(bxor(band(tobit(eh), tobit(fh)), band(bnot(tobit(eh)), tobit(gh))))
		local chxl = unsigned(bxor(band(tobit(el), tobit(fl)), band(bnot(tobit(el)), tobit(gl))))

		-- temp1 = h + S1 + Ch + K[i] + W[i]
		local t1h, t1l = add64(hh, hl, S1h, S1l)
		t1h, t1l = add64(t1h, t1l, chxh, chxl)
		t1h, t1l = add64(t1h, t1l, kh, kl)
		t1h, t1l = add64(t1h, t1l, wh, wl)

		-- S0 = ror(a,28) ^ ror(a,34) ^ ror(a,39)
		local r28h, r28l = ror64(ah, al, 28)
		local r34h, r34l = ror64(ah, al, 34)
		local r39h, r39l = ror64(ah, al, 39)
		local S0h = unsigned(bxor(tobit(r28h), tobit(r34h), tobit(r39h)))
		local S0l = unsigned(bxor(tobit(r28l), tobit(r34l), tobit(r39l)))

		-- Maj = (a & b) ^ (a & c) ^ (b & c)
		local mjh = unsigned(bxor(bxor(band(tobit(ah), tobit(bh)), band(tobit(ah), tobit(ch))), band(tobit(bh), tobit(ch))))
		local mjl = unsigned(bxor(bxor(band(tobit(al), tobit(bl)), band(tobit(al), tobit(cl))), band(tobit(bl), tobit(cl))))

		-- temp2 = S0 + Maj
		local t2h, t2l = add64(S0h, S0l, mjh, mjl)

		hh, hl = gh, gl
		gh, gl = fh, fl
		fh, fl = eh, el
		eh, el = add64(dh, dl, t1h, t1l)
		dh, dl = ch, cl
		ch, cl = bh, bl
		bh, bl = ah, al
		ah, al = add64(t1h, t1l, t2h, t2l)
	end

	h[1],  h[2]  = add64(h[1],  h[2],  ah, al)
	h[3],  h[4]  = add64(h[3],  h[4],  bh, bl)
	h[5],  h[6]  = add64(h[5],  h[6],  ch, cl)
	h[7],  h[8]  = add64(h[7],  h[8],  dh, dl)
	h[9],  h[10] = add64(h[9],  h[10], eh, el)
	h[11], h[12] = add64(h[11], h[12], fh, fl)
	h[13], h[14] = add64(h[13], h[14], gh, gl)
	h[15], h[16] = add64(h[15], h[16], hh, hl)
end

-- Internal SHA-512 returning flat hi/lo hash array.
--: (string) -> { [integer]: number }
local function sha512_raw(data)
	local h = {} --: { [integer]: number }
	for i = 1, 8 do h[(i-1)*2+1] = SHA512_H0[i][1]; h[(i-1)*2+2] = SHA512_H0[i][2] end

	local len = #data
	-- Pad: append 0x80, zeros, then 128-bit big-endian bit count.
	-- We store bit count as (hi64, lo64) both as hi/lo 32-bit pairs.
	-- For Lua strings len < 2^32 bytes, so bits_hi64 = 0, bits_lo64 = len*8.
	local padlen = 128 - ((len + 17) % 128)
	if padlen == 128 then padlen = 0 end
	local bits_lo = (len * 8) % 0x100000000
	local bits_hi = math.floor(len / 0x20000000) % 0x100000000  -- len*8 >> 32

	local padded = data
		.. "\x80"
		.. string.rep("\0", padlen)
		.. string.rep("\0", 8)   -- high 64 bits of bit length = 0 for our purposes
		.. string.char(
			math.floor(bits_hi / 0x1000000) % 256,
			math.floor(bits_hi / 0x10000)   % 256,
			math.floor(bits_hi / 0x100)     % 256,
			bits_hi % 256,
			math.floor(bits_lo / 0x1000000) % 256,
			math.floor(bits_lo / 0x10000)   % 256,
			math.floor(bits_lo / 0x100)     % 256,
			bits_lo % 256
		)

	local nblocks = math.floor(#padded / 128)
	for blk = 0, nblocks - 1 do
		sha512_compress(padded, blk * 128, h)
	end
	return h
end

-- SHA-512: returns 64-byte raw digest.
--: (string) -> string
function M.sha512_bytes(data)
	local h   = sha512_raw(data)
	local out = {}
	for i = 0, 7 do
		local hi, lo = h[i*2+1], h[i*2+2]
		put_u32be(out, i * 8 + 1, tobit(hi))
		put_u32be(out, i * 8 + 5, tobit(lo))
	end
	local bytes = {}
	for i = 1, 64 do bytes[i] = string.char(out[i]) end
	return table.concat(bytes)
end

-- SHA-512: returns 128-char lowercase hex digest.
--: (string) -> string
function M.sha512(data)
	return M.hex(M.sha512_bytes(data))
end

-- ── HMAC ─────────────────────────────────────────────────────────────────────

-- Generic HMAC construction (RFC 2104).
-- hash_fn: function(string) -> raw_bytes.
-- block_size: block size in bytes (64 for SHA-256, 128 for SHA-512).
--: ((string) -> string, integer, string, string) -> string
local function hmac(hash_fn, block_size, key, data)
	-- Shorten key if longer than block size.
	if #key > block_size then key = hash_fn(key) end
	-- Pad key to block size.
	if #key < block_size then key = key .. string.rep("\0", block_size - #key) end

	-- Inner and outer padding.
	local ipad_key = {} --: { [integer]: string }
	local opad_key = {} --: { [integer]: string }
	for i = 1, block_size do
		local kb_raw = string.byte(key, i, i) or 0
		local kb = kb_raw --[[:! integer]]
		ipad_key[i] = string.char(bxor(kb, 0x36))
		opad_key[i] = string.char(bxor(kb, 0x5c))
	end
	local ipad_key_s = table.concat(ipad_key)
	local opad_key_s = table.concat(opad_key)

	return hash_fn(opad_key_s .. hash_fn(ipad_key_s .. data))
end

-- HMAC-SHA256: returns 32-byte raw binary.
--: (string, string) -> string
local function hmac_sha256_raw(key, data)
	return hmac(M.sha256_bytes, 64, key, data)
end

-- HMAC-SHA512: returns 64-byte raw binary.
--: (string, string) -> string
local function hmac_sha512_raw(key, data)
	return hmac(M.sha512_bytes, 128, key, data)
end

-- HMAC-SHA256: returns hex string.
--: (string, string) -> string
function M.hmac_sha256(key, data)
	return M.hex(hmac_sha256_raw(key, data))
end

-- HMAC-SHA512: returns hex string.
--: (string, string) -> string
function M.hmac_sha512(key, data)
	return M.hex(hmac_sha512_raw(key, data))
end

-- ── PBKDF2 ───────────────────────────────────────────────────────────────────

-- PBKDF2 (RFC 2898 / PKCS#5 v2).
-- password: string, salt: string, iterations: integer, key_len: integer.
-- hash: "sha256" (default) or "sha512".
-- Returns key_len raw bytes, or (nil, errmsg) on error.
--: (string, string, number, number, (string | nil)) -> (string | nil, string | nil)
function M.pbkdf2(password, salt, iterations, key_len, hash)
	hash = hash or "sha256"
	if iterations < 1 then return nil, "iterations must be >= 1" end
	if key_len < 1   then return nil, "key_len must be >= 1" end

	local prf_raw --: ((string, string) -> string) | nil
	local hlen = 0 --: integer
	if hash == "sha256" then
		prf_raw = hmac_sha256_raw
		hlen    = 32
	elseif hash == "sha512" then
		prf_raw = hmac_sha512_raw
		hlen    = 64
	else
		return nil, "unsupported hash: " .. tostring(hash)
	end
	if not prf_raw then return nil, "unsupported hash" end
	local prf_raw_ = prf_raw --[[:! (string, string) -> string]]

	local max_blocks = math.floor((key_len + hlen - 1) / hlen)
	if max_blocks > 0xffffffff then return nil, "key_len too large" end

	local blocks = {}
	for blk = 1, max_blocks do
		-- U1 = PRF(password, salt || INT(i))
		local salt_i = salt .. string.char(
			math.floor(blk / 0x1000000) % 256,
			math.floor(blk / 0x10000)   % 256,
			math.floor(blk / 0x100)     % 256,
			blk % 256
		)
		local u = prf_raw_(password, salt_i)
		local f = u
		for _ = 2, iterations do
			u = prf_raw_(password, u)
			-- XOR f with u byte-by-byte.
			local ft = {} --: { [integer]: string }
			for j = 1, hlen do
				local fb_raw = string.byte(f, j, j) or 0
				local ub_raw = string.byte(u, j, j) or 0
				local fb = fb_raw --[[:! integer]]
				local ub = ub_raw --[[:! integer]]
				ft[j] = string.char(bxor(fb, ub))
			end
			f = table.concat(ft)
		end
		blocks[#blocks + 1] = f
	end

	local result = table.concat(blocks)
	return result:sub(1, math.floor(key_len))
end

-- ── ChaCha20 ─────────────────────────────────────────────────────────────────

-- ChaCha20 quarter round (RFC 7539 section 2.1).
--: ({ [integer]: integer }, integer, integer, integer, integer) -> ()
local function qr(s, a, b, c, d)
	s[a] = tobit(s[a] + s[b]); s[d] = rol(bxor(s[d], s[a]), 16)
	s[c] = tobit(s[c] + s[d]); s[b] = rol(bxor(s[b], s[c]), 12)
	s[a] = tobit(s[a] + s[b]); s[d] = rol(bxor(s[d], s[a]), 8)
	s[c] = tobit(s[c] + s[d]); s[b] = rol(bxor(s[b], s[c]), 7)
end

-- ChaCha20 block function. Returns 64 keystream bytes.
-- state: 16-element table of uint32 (index 1-based).
--: ({ [integer]: integer }) -> string
local function chacha20_block(state)
	local s = {}
	for i = 1, 16 do s[i] = state[i] end

	for _ = 1, 10 do
		-- Column rounds
		qr(s, 1, 5, 9,  13)
		qr(s, 2, 6, 10, 14)
		qr(s, 3, 7, 11, 15)
		qr(s, 4, 8, 12, 16)
		-- Diagonal rounds
		qr(s, 1, 6, 11, 16)
		qr(s, 2, 7, 12, 13)
		qr(s, 3, 8,  9, 14)
		qr(s, 4, 5, 10, 15)
	end

	-- Add original state and serialize as 64 LE bytes.
	local out = {}
	for i = 1, 16 do
		put_u32le(out, (i - 1) * 4 + 1, tobit(s[i] + state[i]))
	end
	local bytes = {}
	for i = 1, 64 do bytes[i] = string.char(out[i]) end
	return table.concat(bytes)
end

-- Initialize ChaCha20 state (RFC 7539 section 2.3).
-- key: 32 bytes, nonce: 12 bytes, counter: integer.
--: (string, string, integer) -> { [integer]: integer }
local function chacha20_init(key, nonce, counter)
	return {
		-- "expand 32-byte k" constant
		0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
		-- Key words (8 x 32-bit LE)
		u32le(key, 0),  u32le(key, 4),  u32le(key, 8),  u32le(key, 12),
		u32le(key, 16), u32le(key, 20), u32le(key, 24), u32le(key, 28),
		-- Counter (32-bit)
		tobit(counter),
		-- Nonce words (3 x 32-bit LE)
		u32le(nonce, 0), u32le(nonce, 4), u32le(nonce, 8),
	}
end

-- ChaCha20 encrypt/decrypt (symmetric XOR).
-- key: 32 bytes, nonce: 12 bytes, counter: integer, data: string.
-- Returns ciphertext or (nil, errmsg).
--: (string, string, integer, string) -> (string | nil, string | nil)
function M.chacha20(key, nonce, counter, data)
	if #key ~= 32   then return nil, "key must be 32 bytes" end
	if #nonce ~= 12 then return nil, "nonce must be 12 bytes" end
	if #data == 0   then return "" end

	local state  = chacha20_init(key, nonce, counter)
	local blocks = {}
	local pos    = 1
	local dlen   = #data
	while pos <= dlen do
		local ks        = chacha20_block(state)
		local chunk_len = math.min(64, dlen - pos + 1)
		local out       = {}
		for i = 1, chunk_len do
			out[i] = string.char(bxor((string.byte(data, pos + i - 1, pos + i - 1) or 0) --[[:! integer]], (string.byte(ks, i, i) or 0) --[[:! integer]]))
		end
		blocks[#blocks + 1] = table.concat(out)
		pos = pos + 64
		state[13] = tobit(state[13] + 1)
	end
	return table.concat(blocks)
end

-- ── Poly1305 MAC ─────────────────────────────────────────────────────────────
-- RFC 8439 / RFC 7539 section 2.5.
-- Uses LuaJIT FFI uint64_t for intermediate 64-bit products to avoid
-- double-precision overflow in the 130-bit accumulator arithmetic.

local ffi_ok, ffi = pcall(require, "ffi")
--: (number) -> number
local function u64(n) if ffi_ok then return ffi.new("uint64_t", n) else return n end end
--: (number) -> number
local function u64n(v) if ffi_ok then return tonumber(v) or 0 else return v end end

-- Poly1305 MAC.
-- key: 32 bytes (r = key[1..16], s = key[17..32]).
-- msg: arbitrary-length message.
-- Returns 16-byte MAC.
--: (string, string) -> string
function M.poly1305(key, msg)
	-- Parse and clamp r (little-endian, 4 x 32-bit words, clamped per spec).
	local r0_ = unsigned(band(u32le(key, 0),  0x0fffffff))
	local r1_ = unsigned(band(u32le(key, 4),  0x0ffffffc))
	local r2_ = unsigned(band(u32le(key, 8),  0x0ffffffc))
	local r3_ = unsigned(band(u32le(key, 12), 0x0ffffffc))

	-- Decompose r into 5 x 26-bit limbs.
	local rr0 = r0_ % 0x4000000
	local rr1 = (math.floor(r0_ / 0x4000000) + r1_ * 64) % 0x4000000
	local rr2 = (math.floor(r1_ / 0x100000)  + r2_ * 4096) % 0x4000000
	local rr3 = (math.floor(r2_ / 0x4000)    + r3_ * 262144) % 0x4000000
	local rr4 = math.floor(r3_ / 0x100)

	-- Precompute 5*r limbs.
	local sr1 = rr1 * 5
	local sr2 = rr2 * 5
	local sr3 = rr3 * 5
	local sr4 = rr4 * 5

	-- Parse s (last 16 bytes, little-endian, unsigned).
	local us0 = unsigned(u32le(key, 16))
	local us1 = unsigned(u32le(key, 20))
	local us2 = unsigned(u32le(key, 24))
	local us3 = unsigned(u32le(key, 28))

	-- Accumulator h (5 x 26-bit limbs).
	local h0 = 0 --: number
	local h1 = 0 --: number
	local h2 = 0 --: number
	local h3 = 0 --: number
	local h4 = 0 --: number

	local R0, R1, R2, R3, R4 = u64(rr0), u64(rr1), u64(rr2), u64(rr3), u64(rr4)
	local S1, S2, S3, S4     = u64(sr1),  u64(sr2),  u64(sr3),  u64(sr4)

	local pos  = 0
	local mlen = #msg
	while pos < mlen do
		local chunk = math.min(16, mlen - pos)

		-- Read block bytes as 4 little-endian uint32 words (unsigned).
		local t0 = 0 --: number
		local t1 = 0 --: number
		local t2 = 0 --: number
		local t3 = 0 --: number
		if chunk >= 4 then
			t0 = unsigned(u32le(msg, pos))
		else
			for i = 0, chunk - 1 do t0 = t0 + (string.byte(msg, pos + i + 1) or 0) * (256 ^ i) end
		end
		if chunk >= 8 then
			t1 = unsigned(u32le(msg, pos + 4))
		elseif chunk > 4 then
			for i = 0, chunk - 5 do t1 = t1 + (string.byte(msg, pos + i + 5) or 0) * (256 ^ i) end
		end
		if chunk >= 12 then
			t2 = unsigned(u32le(msg, pos + 8))
		elseif chunk > 8 then
			for i = 0, chunk - 9 do t2 = t2 + (string.byte(msg, pos + i + 9) or 0) * (256 ^ i) end
		end
		if chunk >= 16 then
			t3 = unsigned(u32le(msg, pos + 12))
		elseif chunk > 12 then
			for i = 0, chunk - 13 do t3 = t3 + (string.byte(msg, pos + i + 13) or 0) * (256 ^ i) end
		end

		-- Decompose block into 5 x 26-bit limbs and add sentinel.
		local n0, n1, n2, n3, n4
		if chunk == 16 then
			n0 = t0 % 0x4000000
			n1 = (math.floor(t0 / 0x4000000) + t1 * 64) % 0x4000000
			n2 = (math.floor(t1 / 0x100000)  + t2 * 4096) % 0x4000000
			n3 = (math.floor(t2 / 0x4000)    + t3 * 262144) % 0x4000000
			n4 = math.floor(t3 / 0x100) + 0x1000000
		else
			local byte_at     = chunk
			local word_idx    = math.floor(byte_at / 4)
			local byte_in_w   = byte_at % 4
			local sentinel    = 256 ^ byte_in_w
			if     word_idx == 0 then t0 = t0 + sentinel
			elseif word_idx == 1 then t1 = t1 + sentinel
			elseif word_idx == 2 then t2 = t2 + sentinel
			elseif word_idx == 3 then t3 = t3 + sentinel
			end
			n0 = t0 % 0x4000000
			n1 = (math.floor(t0 / 0x4000000) + t1 * 64) % 0x4000000
			n2 = (math.floor(t1 / 0x100000)  + t2 * 4096) % 0x4000000
			n3 = (math.floor(t2 / 0x4000)    + t3 * 262144) % 0x4000000
			n4 = math.floor(t3 / 0x100)
		end

		h0 = h0 + n0; h1 = h1 + n1; h2 = h2 + n2; h3 = h3 + n3; h4 = h4 + n4

		-- Multiply h * r (mod 2^130 - 5) using uint64 accumulators.
		local H0, H1, H2, H3, H4 = u64(h0), u64(h1), u64(h2), u64(h3), u64(h4)

		local d0 = H0*R0 + H1*S4 + H2*S3 + H3*S2 + H4*S1
		local d1 = H0*R1 + H1*R0 + H2*S4 + H3*S3 + H4*S2
		local d2 = H0*R2 + H1*R1 + H2*R0 + H3*S4 + H4*S3
		local d3 = H0*R3 + H1*R2 + H2*R1 + H3*R0 + H4*S4
		local d4 = H0*R4 + H1*R3 + H2*R2 + H3*R1 + H4*R0

		-- Carry propagation.
		h0 = u64n(d0 % 0x4000000); d1 = d1 + (d0 - d0 % 0x4000000) / 0x4000000
		h1 = u64n(d1 % 0x4000000); d2 = d2 + (d1 - d1 % 0x4000000) / 0x4000000
		h2 = u64n(d2 % 0x4000000); d3 = d3 + (d2 - d2 % 0x4000000) / 0x4000000
		h3 = u64n(d3 % 0x4000000); d4 = d4 + (d3 - d3 % 0x4000000) / 0x4000000
		h4 = u64n(d4 % 0x4000000)
		local carry_top = u64n((d4 - d4 % 0x4000000) / 0x4000000)
		h0 = h0 + carry_top * 5
		local c2 = math.floor(h0 / 0x4000000); h0 = h0 - c2 * 0x4000000; h1 = h1 + c2

		pos = pos + 16
	end

	-- Final reduction mod 2^130 - 5.
	local c
	c = math.floor(h0 / 0x4000000); h0 = h0 - c * 0x4000000; h1 = h1 + c
	c = math.floor(h1 / 0x4000000); h1 = h1 - c * 0x4000000; h2 = h2 + c
	c = math.floor(h2 / 0x4000000); h2 = h2 - c * 0x4000000; h3 = h3 + c
	c = math.floor(h3 / 0x4000000); h3 = h3 - c * 0x4000000; h4 = h4 + c
	c = math.floor(h4 / 0x4000000); h4 = h4 - c * 0x4000000; h0 = h0 + c * 5
	c = math.floor(h0 / 0x4000000); h0 = h0 - c * 0x4000000; h1 = h1 + c

	-- Compute h + -(2^130 - 5) to determine if reduction applies.
	local g0 = h0 + 5
	c = math.floor(g0 / 0x4000000); g0 = g0 - c * 0x4000000
	local g1 = h1 + c; c = math.floor(g1 / 0x4000000); g1 = g1 - c * 0x4000000
	local g2 = h2 + c; c = math.floor(g2 / 0x4000000); g2 = g2 - c * 0x4000000
	local g3 = h3 + c; c = math.floor(g3 / 0x4000000); g3 = g3 - c * 0x4000000
	local g4 = h4 + c - 0x4000000

	if g4 >= 0 then
		h0, h1, h2, h3, h4 = g0, g1, g2, g3, g4
	end

	-- Reassemble from 5 x 26-bit limbs to 4 x 32-bit words.
	local f0 = (h0 + h1 * 0x4000000) % 0x100000000
	local f1 = (math.floor(h1 / 64) + h2 * 0x100000) % 0x100000000
	local f2 = (math.floor(h2 / 4096) + h3 * 0x4000) % 0x100000000
	local f3 = (math.floor(h3 / 0x40000) + h4 * 0x100) % 0x100000000

	-- Add s (mod 2^128).
	f0 = f0 + us0; local carry2 = math.floor(f0 / 0x100000000); f0 = f0 - carry2 * 0x100000000
	f1 = f1 + us1 + carry2; carry2 = math.floor(f1 / 0x100000000); f1 = f1 - carry2 * 0x100000000
	f2 = f2 + us2 + carry2; carry2 = math.floor(f2 / 0x100000000); f2 = f2 - carry2 * 0x100000000
	f3 = f3 + us3 + carry2; f3 = f3 % 0x100000000

	-- Serialize as 16 LE bytes.
	local out = {}
	put_u32le(out, 1,  f0)
	put_u32le(out, 5,  f1)
	put_u32le(out, 9,  f2)
	put_u32le(out, 13, f3)
	local bytes = {}
	for i = 1, 16 do bytes[i] = string.char(out[i]) end
	return table.concat(bytes)
end

-- ── ChaCha20-Poly1305 AEAD ────────────────────────────────────────────────────

-- Pad to 16-byte boundary with zeros.
--: (string) -> string
local function pad16(s)
	local rem = #s % 16
	if rem == 0 then return "" end
	return string.rep("\0", 16 - rem)
end

-- Encode a 64-bit length as 8-byte little-endian (input: Lua number < 2^53).
--: (number) -> string
local function le64(n)
	local out = {}
	for i = 1, 8 do
		out[i] = string.char(n % 256)
		n = math.floor(n / 256)
	end
	return table.concat(out)
end

-- ChaCha20-Poly1305 encrypt (RFC 8439 section 2.8).
-- key: 32 bytes, nonce: 12 bytes, plaintext: string, aad: optional string.
-- Returns ciphertext || 16-byte tag, or (nil, errmsg).
--: (string, string, string, (string | nil)) -> (string | nil, string | nil)
function M.chacha20_poly1305_encrypt(key, nonce, plaintext, aad)
	if #key ~= 32   then return nil, "key must be 32 bytes" end
	if #nonce ~= 12 then return nil, "nonce must be 12 bytes" end
	aad = aad or ""

	-- Poly1305 one-time key: first 32 bytes of ChaCha20 keystream with counter=0.
	local otk_result, otk_err = M.chacha20(key, nonce, 0, string.rep("\0", 32))
	if not otk_result then return nil, otk_err end
	local otk = otk_result --[[:! string]]

	-- Encrypt plaintext with counter=1.
	local ciphertext, ct_err = M.chacha20(key, nonce, 1, plaintext)
	if not ciphertext then return nil, ct_err end
	local ct = ciphertext --[[:! string]]

	-- Build MAC input per RFC 8439 section 2.8.
	local mac_input = aad .. pad16(aad)
		.. ct .. pad16(ct)
		.. le64(#aad) .. le64(#ct)

	local tag = M.poly1305(otk, mac_input)
	return ct .. tag
end

-- ChaCha20-Poly1305 decrypt (RFC 8439 section 2.8).
-- Returns plaintext or (nil, errmsg).
--: (string, string, string, (string | nil)) -> (string | nil, string | nil)
function M.chacha20_poly1305_decrypt(key, nonce, ciphertext_with_tag, aad)
	if #key ~= 32   then return nil, "key must be 32 bytes" end
	if #nonce ~= 12 then return nil, "nonce must be 12 bytes" end
	if #ciphertext_with_tag < 16 then return nil, "ciphertext too short" end
	aad = aad or ""

	local ct_len    = #ciphertext_with_tag - 16
	local ciphertext = ciphertext_with_tag:sub(1, ct_len)
	local tag        = ciphertext_with_tag:sub(ct_len + 1)

	-- Poly1305 one-time key.
	local otk_result, otk_err = M.chacha20(key, nonce, 0, string.rep("\0", 32))
	if not otk_result then return nil, otk_err end
	local otk = otk_result --[[:! string]]

	-- Verify tag.
	local mac_input = aad .. pad16(aad)
		.. ciphertext .. pad16(ciphertext)
		.. le64(#aad) .. le64(ct_len)

	local expected_tag = M.poly1305(otk, mac_input)

	-- Constant-time tag comparison.
	if not M.ct_eq(tag, expected_tag) then
		return nil, "authentication failed"
	end

	local pt, pt_err = M.chacha20(key, nonce, 1, ciphertext)
	if not pt then return nil, pt_err end
	return pt --[[:! string]]
end

-- ── Constant-time comparison ─────────────────────────────────────────────────

-- ct_eq: constant-time string comparison (no early exit).
-- Returns false immediately on length mismatch (lengths are not secret).
--: (string, string) -> boolean
function M.ct_eq(a, b)
	if #a ~= #b then return false end
	local diff = 0
	for i = 1, #a do
		diff = bor(diff, bxor((string.byte(a, i, i) or 0) --[[:! integer]], (string.byte(b, i, i) or 0) --[[:! integer]]))
	end
	return diff == 0
end

-- ── Random bytes ─────────────────────────────────────────────────────────────

-- random_bytes: NOT cryptographically secure without OS entropy.
-- Uses math.random as a fallback only; inject /dev/urandom via FFI for real use.
--: (number) -> string
function M.random_bytes(n)
	local out = {}
	for i = 1, n do
		out[i] = string.char(math.random(0, 255))
	end
	return table.concat(out)
end

return M
