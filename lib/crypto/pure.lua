-- lib/crypto/pure.lua
-- Pure Lua tier: ChaCha20-Poly1305, HKDF, random bytes.
-- AES-GCM is not implemented in pure Lua (requires system-libcrypto tier).
-- Uses LuaJIT bit.* for 32-bit operations.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local bit    = require("bit")
local band   = bit.band
local bxor   = bit.bxor
local bor    = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift
local rol    = bit.rol
local tobit  = bit.tobit

local hmac = require("lib.hash.hmac")

local M = {}
M._tier = "pure-lua"

-- ── AES-256-GCM stubs ──────────────────────────────────────────────────────

--: (string, string, string, string | nil) -> (nil, string)
function M.aes_gcm_encrypt(key, nonce, plaintext, aad)
	return nil, "AES-GCM requires system-libcrypto tier"
end

--: (string, string, string, string | nil) -> (nil, string)
function M.aes_gcm_decrypt(key, nonce, ciphertext_with_tag, aad)
	return nil, "AES-GCM requires system-libcrypto tier"
end

-- ── ChaCha20-Poly1305 ──────────────────────────────────────────────────────

-- Read a 32-bit little-endian word from a string at offset (0-based).
--: (string, integer) -> integer
local function u32le(s, off)
	local a, b, c, d = string.byte(s, off + 1, off + 4)
	return tobit((a or 0) + (b or 0) * 0x100 + (c or 0) * 0x10000 + (d or 0) * 0x1000000)
end

-- Write a 32-bit little-endian word to a table of bytes.
--: ({ [integer]: integer }, integer, number) -> ()
local function put_u32le(t, pos, v)
	local vi = math.floor(v) --[[:! integer]]
	t[pos]     = band(vi, 0xff)
	t[pos + 1] = band(rshift(vi, 8), 0xff)
	t[pos + 2] = band(rshift(vi, 16), 0xff)
	t[pos + 3] = band(rshift(vi, 24), 0xff)
end

-- ChaCha20 quarter round.
--: ({ [integer]: integer }, integer, integer, integer, integer) -> ()
local function quarter_round(s, a, b, c, d)
	s[a] = tobit(s[a] + s[b]); s[d] = rol(bxor(s[d], s[a]), 16)
	s[c] = tobit(s[c] + s[d]); s[b] = rol(bxor(s[b], s[c]), 12)
	s[a] = tobit(s[a] + s[b]); s[d] = rol(bxor(s[d], s[a]), 8)
	s[c] = tobit(s[c] + s[d]); s[b] = rol(bxor(s[b], s[c]), 7)
end

-- ChaCha20 block function. Returns 64 bytes of keystream.
-- state: 16 uint32 words, counter at index 13 (1-based).
--: ({ [integer]: integer }) -> string
local function chacha20_block(state)
	-- Working copy
	local s = {} --[[:! { [integer]: integer }]]
	for i = 1, 16 do s[i] = state[i] end

	-- 20 rounds (10 double rounds)
	for _ = 1, 10 do
		-- Column rounds
		quarter_round(s, 1, 5, 9, 13)
		quarter_round(s, 2, 6, 10, 14)
		quarter_round(s, 3, 7, 11, 15)
		quarter_round(s, 4, 8, 12, 16)
		-- Diagonal rounds
		quarter_round(s, 1, 6, 11, 16)
		quarter_round(s, 2, 7, 12, 13)
		quarter_round(s, 3, 8, 9, 14)
		quarter_round(s, 4, 5, 10, 15)
	end

	-- Add original state
	local out = {} --[[:! { [integer]: integer }]]
	for i = 1, 16 do
		put_u32le(out, (i - 1) * 4 + 1, tobit(s[i] + state[i]))
	end
	local bytes = {} --[[:! { [integer]: string }]]
	for i = 1, 64 do bytes[i] = string.char(out[i]) end
	return table.concat(bytes)
end

-- Initialize ChaCha20 state from key (32 bytes), nonce (12 bytes), counter.
--: (string, string, integer) -> { [integer]: integer }
local function chacha20_init(key, nonce, counter)
	return {
		-- "expand 32-byte k"
		0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
		-- Key (8 words)
		u32le(key, 0), u32le(key, 4), u32le(key, 8), u32le(key, 12),
		u32le(key, 16), u32le(key, 20), u32le(key, 24), u32le(key, 28),
		-- Counter
		tobit(counter),
		-- Nonce (3 words)
		u32le(nonce, 0), u32le(nonce, 4), u32le(nonce, 8),
	}
end

-- Encrypt/decrypt with ChaCha20 (XOR with keystream).
--: (string, string, integer, string) -> string
local function chacha20_crypt(key, nonce, counter, data)
	if #data == 0 then return "" end
	local state = chacha20_init(key, nonce, counter)
	local blocks = {}
	local pos = 1
	while pos <= #data do
		local ks = chacha20_block(state)
		local chunk_len = math.min(64, #data - pos + 1)
		local out = {} --[[:! { [integer]: string }]]
		for i = 1, chunk_len do
			out[i] = string.char(bxor(string.byte(data, pos + i - 1) or 0, string.byte(ks, i) or 0))
		end
		blocks[#blocks + 1] = table.concat(out)
		pos = pos + 64
		state[13] = tobit(state[13] + 1) -- increment counter
	end
	return table.concat(blocks)
end

-- ── Poly1305 MAC ────────────────────────────────────────────────────────────

-- Poly1305: arithmetic mod 2^130 - 5.
-- Uses LuaJIT FFI uint64_t for intermediate products to avoid
-- double-precision overflow (26-bit limbs * 26-bit limbs = 52-bit products,
-- but summing 5 of them can reach ~55 bits, exceeding double's 53-bit mantissa).

local ffi_ok, ffi_mod = pcall(require, "ffi")
local u64
if ffi_ok then
	u64 = function(n) return ffi_mod.new("uint64_t", n) end
else
	u64 = function(n) return n end -- fallback (may lose precision for large messages)
end

-- Convert uint64_t to Lua number (loses precision above 2^53 but we only use
-- this after reducing to 26-bit limb values).
local function u64_to_num(v)
	return tonumber(v)
end

-- Poly1305 MAC computation.
-- key: 32 bytes (first 16 = r, last 16 = s).
-- msg: arbitrary length message.
-- Returns 16-byte MAC as string.
--: (string, string) -> string
local function poly1305_mac(key, msg)
	-- Parse and clamp r from first 16 bytes of key (little-endian 4x32-bit words)
	local r0 = band(u32le(key, 0), 0x0fffffff) --[[:! number]]
	local r1 = band(u32le(key, 4), 0x0ffffffc) --[[:! number]]
	local r2 = band(u32le(key, 8), 0x0ffffffc) --[[:! number]]
	local r3 = band(u32le(key, 12), 0x0ffffffc) --[[:! number]]
	-- Make unsigned
	if r0 < 0 then r0 = r0 + 0x100000000 end
	if r1 < 0 then r1 = r1 + 0x100000000 end
	if r2 < 0 then r2 = r2 + 0x100000000 end
	if r3 < 0 then r3 = r3 + 0x100000000 end

	-- Decompose r into 5 x 26-bit limbs
	local rr0 = r0 % 0x4000000
	local rr1 = (math.floor(r0 / 0x4000000) + r1 * 64) % 0x4000000
	local rr2 = (math.floor(r1 / 0x100000) + r2 * 4096) % 0x4000000
	local rr3 = (math.floor(r2 / 0x4000) + r3 * 262144) % 0x4000000
	local rr4 = math.floor(r3 / 0x100)

	-- Precompute 5*r for modular reduction
	local sr1 = rr1 * 5
	local sr2 = rr2 * 5
	local sr3 = rr3 * 5
	local sr4 = rr4 * 5

	-- s from last 16 bytes (as unsigned numbers)
	local us0 = u32le(key, 16) --[[:! number]]; if us0 < 0 then us0 = us0 + 0x100000000 end
	local us1 = u32le(key, 20) --[[:! number]]; if us1 < 0 then us1 = us1 + 0x100000000 end
	local us2 = u32le(key, 24) --[[:! number]]; if us2 < 0 then us2 = us2 + 0x100000000 end
	local us3 = u32le(key, 28) --[[:! number]]; if us3 < 0 then us3 = us3 + 0x100000000 end

	-- Accumulator h = 0 (5 limbs, as Lua numbers)
	local h0 = 0.0 --[[:! number]]
	local h1 = 0.0 --[[:! number]]
	local h2 = 0.0 --[[:! number]]
	local h3 = 0.0 --[[:! number]]
	local h4 = 0.0 --[[:! number]]

	-- Convert r limbs to uint64 for multiplication
	local R0 = u64(rr0)
	local R1 = u64(rr1)
	local R2 = u64(rr2)
	local R3 = u64(rr3)
	local R4 = u64(rr4)
	local S1 = u64(sr1)
	local S2 = u64(sr2)
	local S3 = u64(sr3)
	local S4 = u64(sr4)

	local pos = 0
	local len = #msg
	while pos < len do
		local chunk = math.min(16, len - pos)

		-- Read block bytes into 4 LE uint32 words (as Lua unsigned numbers)
		local t0 = 0.0 --[[:! number]]
		local t1 = 0.0 --[[:! number]]
		local t2 = 0.0 --[[:! number]]
		local t3 = 0.0 --[[:! number]]
		if chunk >= 4 then
			t0 = u32le(msg, pos) --[[:! number]]; if t0 < 0 then t0 = t0 + 0x100000000 end
		else
			for i = 0, chunk - 1 do t0 = t0 + (string.byte(msg, pos + i + 1) or 0) * (256 ^ i) end
		end
		if chunk >= 8 then
			t1 = u32le(msg, pos + 4) --[[:! number]]; if t1 < 0 then t1 = t1 + 0x100000000 end
		elseif chunk > 4 then
			for i = 0, chunk - 5 do t1 = t1 + (string.byte(msg, pos + i + 5) or 0) * (256 ^ i) end
		end
		if chunk >= 12 then
			t2 = u32le(msg, pos + 8) --[[:! number]]; if t2 < 0 then t2 = t2 + 0x100000000 end
		elseif chunk > 8 then
			for i = 0, chunk - 9 do t2 = t2 + (string.byte(msg, pos + i + 9) or 0) * (256 ^ i) end
		end
		if chunk >= 16 then
			t3 = u32le(msg, pos + 12) --[[:! number]]; if t3 < 0 then t3 = t3 + 0x100000000 end
		elseif chunk > 12 then
			for i = 0, chunk - 13 do t3 = t3 + (string.byte(msg, pos + i + 13) or 0) * (256 ^ i) end
		end

		-- Decompose block + sentinel into 5 x 26-bit limbs
		local n0, n1, n2, n3, n4
		if chunk == 16 then
			n0 = t0 % 0x4000000
			n1 = (math.floor(t0 / 0x4000000) + t1 * 64) % 0x4000000
			n2 = (math.floor(t1 / 0x100000) + t2 * 4096) % 0x4000000
			n3 = (math.floor(t2 / 0x4000) + t3 * 262144) % 0x4000000
			n4 = math.floor(t3 / 0x100) + 0x1000000 -- hibit at bit 24 of limb 4
		else
			-- Partial block: add 0x01 sentinel byte at position chunk
			local byte_at = chunk
			local word_idx = math.floor(byte_at / 4)
			local byte_in_word = byte_at % 4
			local sentinel = 256 ^ byte_in_word
			if word_idx == 0 then t0 = t0 + sentinel
			elseif word_idx == 1 then t1 = t1 + sentinel
			elseif word_idx == 2 then t2 = t2 + sentinel
			elseif word_idx == 3 then t3 = t3 + sentinel
			end
			n0 = t0 % 0x4000000
			n1 = (math.floor(t0 / 0x4000000) + t1 * 64) % 0x4000000
			n2 = (math.floor(t1 / 0x100000) + t2 * 4096) % 0x4000000
			n3 = (math.floor(t2 / 0x4000) + t3 * 262144) % 0x4000000
			n4 = math.floor(t3 / 0x100)
		end

		h0 = h0 + n0
		h1 = h1 + n1
		h2 = h2 + n2
		h3 = h3 + n3
		h4 = h4 + n4

		-- Multiply h by r (mod 2^130 - 5) using uint64_t accumulators
		local H0 = u64(h0)
		local H1 = u64(h1)
		local H2 = u64(h2)
		local H3 = u64(h3)
		local H4 = u64(h4)

		local d0 = H0*R0 + H1*S4 + H2*S3 + H3*S2 + H4*S1
		local d1 = H0*R1 + H1*R0 + H2*S4 + H3*S3 + H4*S2
		local d2 = H0*R2 + H1*R1 + H2*R0 + H3*S4 + H4*S3
		local d3 = H0*R3 + H1*R2 + H2*R1 + H3*R0 + H4*S4
		local d4 = H0*R4 + H1*R3 + H2*R2 + H3*R1 + H4*R0

		-- Carry propagation (extract 26-bit limbs from uint64_t)
		local MASK26 = 0x3ffffff
		-- For carry propagation with uint64:
		h0 = u64_to_num(d0 % 0x4000000) or 0.0
		d1 = d1 + (d0 - d0 % 0x4000000) / 0x4000000
		h1 = u64_to_num(d1 % 0x4000000) or 0.0
		d2 = d2 + (d1 - d1 % 0x4000000) / 0x4000000
		h2 = u64_to_num(d2 % 0x4000000) or 0.0
		d3 = d3 + (d2 - d2 % 0x4000000) / 0x4000000
		h3 = u64_to_num(d3 % 0x4000000) or 0.0
		d4 = d4 + (d3 - d3 % 0x4000000) / 0x4000000
		h4 = u64_to_num(d4 % 0x4000000) or 0.0
		local carry_top = u64_to_num((d4 - d4 % 0x4000000) / 0x4000000) or 0.0
		h0 = h0 + carry_top * 5
		local c2 = math.floor(h0 / 0x4000000) or 0.0
		h0 = h0 - c2 * 0x4000000
		h1 = h1 + c2

		pos = pos + 16
	end

	-- Final reduction
	local c
	c = math.floor(h0 / 0x4000000); h0 = h0 - c * 0x4000000; h1 = h1 + c
	c = math.floor(h1 / 0x4000000); h1 = h1 - c * 0x4000000; h2 = h2 + c
	c = math.floor(h2 / 0x4000000); h2 = h2 - c * 0x4000000; h3 = h3 + c
	c = math.floor(h3 / 0x4000000); h3 = h3 - c * 0x4000000; h4 = h4 + c
	c = math.floor(h4 / 0x4000000); h4 = h4 - c * 0x4000000; h0 = h0 + c * 5
	c = math.floor(h0 / 0x4000000); h0 = h0 - c * 0x4000000; h1 = h1 + c

	-- Compute h + -(2^130 - 5) = h - 2^130 + 5
	local g0 = h0 + 5
	c = math.floor(g0 / 0x4000000); g0 = g0 - c * 0x4000000
	local g1 = h1 + c
	c = math.floor(g1 / 0x4000000); g1 = g1 - c * 0x4000000
	local g2 = h2 + c
	c = math.floor(g2 / 0x4000000); g2 = g2 - c * 0x4000000
	local g3 = h3 + c
	c = math.floor(g3 / 0x4000000); g3 = g3 - c * 0x4000000
	local g4 = h4 + c - 0x4000000

	if g4 >= 0 then
		h0, h1, h2, h3, h4 = g0, g1, g2, g3, g4
	end

	-- Reassemble h into 4 x 32-bit words (from 5 x 26-bit limbs)
	local f0 = (h0 + h1 * 0x4000000) % 0x100000000
	local f1 = (math.floor(h1 / 64) + h2 * 0x100000) % 0x100000000
	local f2 = (math.floor(h2 / 4096) + h3 * 0x4000) % 0x100000000
	local f3 = (math.floor(h3 / 0x40000) + h4 * 0x100) % 0x100000000

	-- Add s (mod 2^128)
	f0 = f0 + us0
	local carry = math.floor(f0 / 0x100000000); f0 = f0 - carry * 0x100000000
	f1 = f1 + us1 + carry
	carry = math.floor(f1 / 0x100000000); f1 = f1 - carry * 0x100000000
	f2 = f2 + us2 + carry
	carry = math.floor(f2 / 0x100000000); f2 = f2 - carry * 0x100000000
	f3 = f3 + us3 + carry
	f3 = f3 % 0x100000000

	-- Serialize as 16 bytes little-endian
	local out = {}
	put_u32le(out, 1, f0)
	put_u32le(out, 5, f1)
	put_u32le(out, 9, f2)
	put_u32le(out, 13, f3)
	local bytes = {}
	for i = 1, 16 do bytes[i] = string.char(out[i]) end
	return table.concat(bytes)
end

-- Pad data to 16-byte boundary with zeros.
--: (string) -> string
local function pad16(data)
	local rem = #data % 16
	if rem == 0 then return "" end
	return string.rep("\0", 16 - rem)
end

-- Encode a 64-bit length as 8-byte little-endian string.
--: (number) -> string
local function le64(n)
	local out = {}
	for i = 1, 8 do
		out[i] = string.char(n % 256)
		n = math.floor(n / 256)
	end
	return table.concat(out)
end

-- ChaCha20-Poly1305 AEAD encrypt (RFC 8439).
--: (string, string, string, string | nil) -> (string | nil, string | nil)
function M.chacha20_encrypt(key, nonce, plaintext, aad)
	if #key ~= 32 then return nil, "key must be 32 bytes" end
	if #nonce ~= 12 then return nil, "nonce must be 12 bytes" end
	aad = aad or ""

	-- Generate Poly1305 one-time key (counter=0)
	local otk = chacha20_crypt(key, nonce, 0, string.rep("\0", 32))

	-- Encrypt plaintext (counter=1)
	local ciphertext = chacha20_crypt(key, nonce, 1, plaintext)

	-- Construct Poly1305 MAC input (RFC 8439 Section 2.8)
	local mac_data = aad .. pad16(aad)
		.. ciphertext .. pad16(ciphertext)
		.. le64(#aad) .. le64(#ciphertext)

	local tag = poly1305_mac(otk, mac_data)

	return ciphertext .. tag
end

-- ChaCha20-Poly1305 AEAD decrypt (RFC 8439).
--: (string, string, string, string | nil) -> (string | nil, string | nil)
function M.chacha20_decrypt(key, nonce, ciphertext_with_tag, aad)
	if #key ~= 32 then return nil, "key must be 32 bytes" end
	if #nonce ~= 12 then return nil, "nonce must be 12 bytes" end
	if #ciphertext_with_tag < 16 then return nil, "ciphertext too short" end
	aad = aad or ""

	local ct_len = #ciphertext_with_tag - 16
	local ciphertext = ciphertext_with_tag:sub(1, ct_len)
	local tag = ciphertext_with_tag:sub(ct_len + 1)

	-- Generate Poly1305 one-time key (counter=0)
	local otk = chacha20_crypt(key, nonce, 0, string.rep("\0", 32))

	-- Verify tag
	local mac_data = aad .. pad16(aad)
		.. ciphertext .. pad16(ciphertext)
		.. le64(#aad) .. le64(#ciphertext)

	local expected_tag = poly1305_mac(otk, mac_data)

	-- Constant-time comparison
	local diff = 0
	for i = 1, 16 do
		diff = bor(diff, bxor(string.byte(tag, i) or 0, string.byte(expected_tag, i) or 0))
	end
	if diff ~= 0 then
		return nil, "authentication failed"
	end

	-- Decrypt (counter=1)
	local plaintext = chacha20_crypt(key, nonce, 1, ciphertext)
	return plaintext
end

-- ── HKDF (RFC 5869) using HMAC-SHA256 ───────────────────────────────────────

-- HMAC-SHA256 returning raw binary bytes.
--: (string, string) -> string
local function hmac_sha256_bin(key, msg)
	return hmac.sha256_binary(key, msg)
end

--: (string, string | nil, string | nil, integer | nil) -> (string | nil, string | nil)
function M.hkdf(ikm, salt, info, length)
	length = length or 32
	info = info or ""
	if length > 255 * 32 then return nil, "length too large (max 8160)" end
	if length <= 0 then return nil, "length must be positive" end

	-- HKDF-Extract
	salt = (salt and #salt > 0) and salt or string.rep("\0", 32)
	local prk = hmac_sha256_bin(salt, ikm)

	-- HKDF-Expand
	local t = ""
	local okm = {}
	local n = math.ceil(length / 32)
	for i = 1, n do
		t = hmac_sha256_bin(prk, t .. info .. string.char(i))
		okm[i] = t
	end
	local result = table.concat(okm)
	return result:sub(1, length)
end

-- ── Random bytes ────────────────────────────────────────────────────────────

--: ((integer) -> string, integer) -> (string | nil, string | nil)
function M.random_bytes(random_bytes_fn, n)
	if type(random_bytes_fn) ~= "function" then
		error("crypto.pure.random_bytes: random_bytes_fn function is required")
	end
	if n <= 0 then return "" end
	return random_bytes_fn(n)
end

return M
