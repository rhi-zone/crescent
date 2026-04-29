-- lib/sha256/init.lua
-- Tiered SHA-256: system crypto (OpenSSL) → LuaJIT FFI scalar → pure Lua.
-- Tier selected at load time via pcall; best available wins.
--
-- Public API:
--   M.sha256(s) -> hex_string   (lowercase, 64 chars)
--   M.tier      -> "system" | "ffi" | "lua"

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── SHA-256 constants (shared across tiers) ───────────────────────────────────

-- First 32 bits of fractional parts of cube roots of first 64 primes.
local K = {
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

local HEX = "0123456789abcdef"

-- ── Tier 1: OpenSSL via ffi.load ──────────────────────────────────────────────
--
-- Tries known library names in order.  SHA256() is the one-shot EVP API
-- available since OpenSSL 0.9.x.

local function try_system()
	local ffi = require("ffi")
	local bit = require("bit")
	local rshift = bit.rshift

	ffi.cdef [[
		unsigned char *SHA256(const unsigned char *d, size_t n, unsigned char *md);
	]]

	local lib
	local names = { "ssl", "crypto", "libssl.so.3", "libssl.so.1.1" }
	for _, name in ipairs(names) do
		local ok, l = pcall(ffi.load, name)
		if ok then lib = l; break end
	end
	if not lib then
		error("no ssl/crypto library found")
	end
	local lib_typed = lib --[[:! $FfiC]]

	-- Verify the SHA256 symbol is accessible.
	local probe_buf = ffi.new("unsigned char[32]")
	local ok2, err2 = pcall(lib_typed.SHA256, ffi.cast("const unsigned char *", ""), 0, probe_buf)
	if not ok2 then error("SHA256 symbol not callable: " .. tostring(err2)) end

	return function(s)
		local result = ffi.new("unsigned char[32]")
		lib_typed.SHA256(ffi.cast("const unsigned char *", s), #s, result)
		local parts = {}
		for i = 0, 31 do
			local b = result[i]
			parts[#parts + 1] = HEX:sub(rshift(b, 4) + 1, rshift(b, 4) + 1)
				.. HEX:sub(bit.band(b, 0xf) + 1, bit.band(b, 0xf) + 1)
		end
		return table.concat(parts)
	end
end

-- ── Tier 2: LuaJIT FFI scalar implementation ─────────────────────────────────
--
-- SHA-256 using ffi uint32_t arrays + bit.* ops.  No ffi.load.
-- JIT-compiles to ~200-500 MB/s.

local function try_ffi()
	local ffi  = require("ffi")
	local bit  = require("bit")
	local bxor = bit.bxor
	local band = bit.band
	local bnot = bit.bnot
	local rshift = bit.rshift
	local lshift = bit.lshift
	local rrotate = bit.ror

	-- Pre-allocate reusable work buffers (module-level, avoid per-call GC).
	local W  = ffi.new("uint32_t[64]")   -- message schedule
	local Kffi = ffi.new("uint32_t[64]")
	for i = 1, 64 do Kffi[i - 1] = K[i] end

	-- Initial hash values (sqrt of primes 2..19, fractional parts).
	local H0 = {
		0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
		0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
	}

	local function compress(data, offset, h)
		-- Load 16 words big-endian.
		for i = 0, 15 do
			local o = offset + i * 4
			W[i] = lshift(data[o], 24)
				+ lshift(data[o + 1], 16)
				+ lshift(data[o + 2], 8)
				+ data[o + 3]
		end
		-- Extend schedule.
		for i = 16, 63 do
			local w15 = W[i - 15]
			local w2  = W[i - 2]
			local s0 = bxor(rrotate(w15, 7), rrotate(w15, 18), rshift(w15, 3))
			local s1 = bxor(rrotate(w2, 17), rrotate(w2, 19),  rshift(w2, 10))
			W[i] = W[i - 16] + s0 + W[i - 7] + s1
		end

		-- Working state.
		local a = h[0]; local b = h[1]; local c = h[2]; local d = h[3]
		local e = h[4]; local f = h[5]; local g = h[6]; local hh = h[7]

		for i = 0, 63 do
			local S1    = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
			local ch    = bxor(band(e, f), band(bnot(e), g))
			local temp1 = hh + S1 + ch + Kffi[i] + W[i]
			local S0    = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
			local maj   = bxor(band(a, b), band(a, c), band(b, c))
			local temp2 = S0 + maj

			hh = g; g = f; f = e
			e = d + temp1
			d = c; c = b; b = a
			a = temp1 + temp2
		end

		h[0] = h[0] + a; h[1] = h[1] + b
		h[2] = h[2] + c; h[3] = h[3] + d
		h[4] = h[4] + e; h[5] = h[5] + f
		h[6] = h[6] + g; h[7] = h[7] + hh
	end

	local function u32_to_hex8(v)
		-- 8 hex chars for a uint32_t, big-endian nibbles.
		local out = {}
		for s = 28, 0, -4 do
			out[#out + 1] = HEX:sub(rshift(v, s) % 16 + 1, rshift(v, s) % 16 + 1)
		end
		return table.concat(out)
	end

	-- Reusable padded-message buffer; grown on first call that needs more space.
	local data_buf     = ffi.new("uint8_t[?]", 4096)
	local data_buf_cap = 4096

	return function(s)
		local slen  = #s
		local padded = math.ceil((slen + 9) / 64) * 64

		if data_buf_cap < padded then
			data_buf_cap = padded + 64
			data_buf     = ffi.new("uint8_t[?]", data_buf_cap)
		end

		ffi.copy(data_buf, s, slen)
		data_buf[slen] = 0x80

		for i = slen + 1, padded - 9 do data_buf[i] = 0 end

		-- 64-bit bit-length, big-endian.  High 32 bits = 0 for Lua strings.
		local bits_lo = slen * 8
		data_buf[padded - 8] = 0; data_buf[padded - 7] = 0
		data_buf[padded - 6] = 0; data_buf[padded - 5] = 0
		data_buf[padded - 4] = rshift(bits_lo, 24) % 256
		data_buf[padded - 3] = rshift(bits_lo, 16) % 256
		data_buf[padded - 2] = rshift(bits_lo, 8)  % 256
		data_buf[padded - 1] = bits_lo % 256

		local h = ffi.new("uint32_t[8]")
		for i = 1, 8 do h[i - 1] = H0[i] end

		local nblocks = padded / 64
		for blk = 0, nblocks - 1 do
			compress(data_buf, blk * 64, h)
		end

		local parts = {}
		for i = 0, 7 do parts[i + 1] = u32_to_hex8(h[i]) end
		return table.concat(parts)
	end
end

-- ── Tier 3: Pure Lua fallback ─────────────────────────────────────────────────
--
-- Works on PUC-Rio Lua 5.x.  Bitwise ops via modular arithmetic on doubles.
-- ~10 MB/s.

local function make_lua()
	-- 32-bit modular truncation.
	local function u32(x) return x % 0x100000000 end

	-- Bitwise helpers via modular arithmetic (Lua 5.1 compatible).
	-- We need: XOR, AND, NOT, right-rotate.
	-- Use LuaJIT's bit library if available; else fall back to math.

	local _bxor, _band, _bnot, _rshift, _lshift, _rrotate

	local ok_bit, bit_mod = pcall(require, "bit")
	if ok_bit then
		_bxor   = bit_mod.bxor
		_band   = bit_mod.band
		_bnot   = bit_mod.bnot
		_rshift = bit_mod.rshift
		_lshift = bit_mod.lshift
		_rrotate = bit_mod.ror
	else
		-- Pure-math fallback for standard Lua 5.1 without bit lib.
		local function bitval(x, n)
			return math.floor(x / (2 ^ n)) % 2
		end
		local function fold(a, b, op, bits)
			local result = 0
			for i = 0, bits - 1 do
				if op(bitval(a, i), bitval(b, i)) == 1 then
					result = result + 2 ^ i
				end
			end
			return result
		end
		_bxor = function(a, b) return fold(u32(a), u32(b), function(x,y) return x ~= y and 1 or 0 end, 32) end
		_band = function(a, b) return fold(u32(a), u32(b), function(x,y) return x == 1 and y == 1 and 1 or 0 end, 32) end
		_bnot = function(a) return u32(0xffffffff - u32(a)) end  -- same as XOR with MASK
		_rshift = function(a, n) return math.floor(u32(a) / (2 ^ n)) end
		_lshift = function(a, n) return u32(u32(a) * (2 ^ n)) end
		_rrotate = function(a, n) a = u32(a); return u32(_rshift(a, n) + _lshift(a, 32 - n)) end
	end

	local W2  = {}
	local blk = {}  -- 64-byte block buffer (Lua table of bytes)
	for i = 1, 64 do W2[i] = 0; blk[i] = 0 end

	-- Compress one 64-byte block stored in blk[1..64].
	local function compress_block(h)
		for i = 1, 16 do
			local o = (i - 1) * 4
			W2[i] = blk[o + 1] * 0x1000000
				+ blk[o + 2] * 0x10000
				+ blk[o + 3] * 0x100
				+ blk[o + 4]
		end
		for i = 17, 64 do
			local w15 = W2[i - 15]
			local w2  = W2[i - 2]
			local s0 = _bxor(_rrotate(w15, 7), _rrotate(w15, 18), _rshift(w15, 3))
			local s1 = _bxor(_rrotate(w2, 17),  _rrotate(w2, 19),  _rshift(w2, 10))
			W2[i] = u32(W2[i - 16] + s0 + W2[i - 7] + s1)
		end

		local a  = h[1]; local b  = h[2]; local c = h[3]; local d  = h[4]
		local e  = h[5]; local f  = h[6]; local g = h[7]; local hh = h[8]

		for i = 1, 64 do
			local S1    = _bxor(_rrotate(e, 6), _rrotate(e, 11), _rrotate(e, 25))
			local ch    = _bxor(_band(e, f), _band(_bnot(e), g))
			local temp1 = u32(hh + S1 + ch + K[i] + W2[i])
			local S0    = _bxor(_rrotate(a, 2), _rrotate(a, 13), _rrotate(a, 22))
			local maj   = _bxor(_band(a, b), _band(a, c), _band(b, c))
			local temp2 = u32(S0 + maj)

			hh = g; g = f; f = e
			e  = u32(d + temp1)
			d  = c; c = b; b = a
			a  = u32(temp1 + temp2)
		end

		h[1] = u32(h[1] + a); h[2] = u32(h[2] + b)
		h[3] = u32(h[3] + c); h[4] = u32(h[4] + d)
		h[5] = u32(h[5] + e); h[6] = u32(h[6] + f)
		h[7] = u32(h[7] + g); h[8] = u32(h[8] + hh)
	end

	-- Process input in 64-byte (512-bit) blocks, streaming from the string.
	-- Avoids building a full byte-table for large inputs.
	return function(s)
		local len = #s

		local h = {
			0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
			0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
		}

		-- Process all full 64-byte blocks from input.
		local nfull = math.floor(len / 64)
		for b_idx = 0, nfull - 1 do
			local base = b_idx * 64 + 1  -- 1-indexed string position
			for j = 1, 64 do
				blk[j] = string.byte(s, base + j - 1)
			end
			compress_block(h)
		end

		-- Build final block(s): remaining bytes + padding + length.
		-- remaining bytes from input (0-63 bytes).
		local rem_start = nfull * 64 + 1
		local rem_len   = len - nfull * 64  -- 0..63

		-- Fill blk with remaining bytes.
		for j = 1, rem_len do
			blk[j] = string.byte(s, rem_start + j - 1)
		end

		-- Append 0x80 sentinel.
		blk[rem_len + 1] = 0x80

		-- Zero rest of block.
		for j = rem_len + 2, 64 do blk[j] = 0 end

		-- If not enough room for 8-byte length (need 9 bytes: 1 sentinel + 8 len),
		-- flush this block and start another.
		if rem_len >= 56 then
			compress_block(h)
			for j = 1, 64 do blk[j] = 0 end
		end

		-- Write 64-bit big-endian bit count into bytes 57-64.
		local bits = len * 8
		blk[57] = 0; blk[58] = 0; blk[59] = 0; blk[60] = 0
		blk[61] = math.floor(bits / 0x1000000) % 256
		blk[62] = math.floor(bits / 0x10000)   % 256
		blk[63] = math.floor(bits / 0x100)     % 256
		blk[64] = bits % 256

		compress_block(h)

		local parts = {}
		for i = 1, 8 do
			local v = h[i]
			for sh = 24, 0, -8 do
				local byte = math.floor(v / (2 ^ sh)) % 256
				parts[#parts + 1] = HEX:sub(math.floor(byte / 16) + 1, math.floor(byte / 16) + 1)
					.. HEX:sub(byte % 16 + 1, byte % 16 + 1)
			end
		end
		return table.concat(parts)
	end
end

-- ── Tier selection ────────────────────────────────────────────────────────────

-- Always build the Lua tier (used as fallback and for parity testing).
M._lua_sha256 = make_lua()

local ok1, result1 = pcall(try_system)
if ok1 then
	M.sha256       = result1
	M.tier         = "system"
	M._system_sha256 = result1
	local ok2, result2 = pcall(try_ffi)
	if ok2 then M._ffi_sha256 = result2 end
else
	local ok2, result2 = pcall(try_ffi)
	if ok2 then
		M.sha256     = result2
		M.tier       = "ffi"
		M._ffi_sha256 = result2
	else
		M.sha256 = M._lua_sha256
		M.tier   = "lua"
	end
end

-- M._tiers: ordered list of {name, fn} for all successfully loaded tiers.
M._tiers = {}
if M._system_sha256 then M._tiers[#M._tiers + 1] = { name = "system", fn = M._system_sha256 } end
if M._ffi_sha256    then M._tiers[#M._tiers + 1] = { name = "ffi",    fn = M._ffi_sha256    } end
M._tiers[#M._tiers + 1] = { name = "lua", fn = M._lua_sha256 }

return M
