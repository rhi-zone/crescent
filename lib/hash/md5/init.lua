-- lib/hash/md5/init.lua
-- MD5 message digest (RFC 1321), pure Lua implementation.
-- Uses LuaJIT bit library for 32-bit operations.
--
-- Public API:
--   M.digest(s)       -> string (32-char lowercase hex)
--   M.digest_raw(s)   -> string (16 raw bytes)
--   M.new()           -> hasher with :update/:digest/:digest_raw/:reset
--   M.encode          = M.digest (codec alias)
--   M._tier           = "pure"

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local band = bit.band
local bor = bit.bor
local bxor = bit.bxor
local bnot = bit.bnot
local lshift = bit.lshift
local rshift = bit.rshift
local rol = bit.rol
local tobit = bit.tobit

local M = {}

M._tier = "pure"

-- ── MD5 constants ────────────────────────────────────────────────────────────

-- T[i] = floor(2^32 * abs(sin(i))) for i = 1..64
--: { [integer]: number }
local T = {
	0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
	0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
	0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
	0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
	0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
	0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
	0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
	0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
	0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
	0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
	0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
	0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
	0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
	0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
	0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
	0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
}

-- Per-round shift amounts
--: { [integer]: integer }
local S = {
	7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
	5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20,
	4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
	6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

-- Message word index per round (0-indexed into the 16-word block)
--: { [integer]: integer }
local G_IDX = {
	0, 1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15,
	1, 6, 11,  0,  5, 10, 15,  4,  9, 14,  3,  8, 13,  2,  7, 12,
	5, 8, 11, 14,  1,  4,  7, 10, 13,  0,  3,  6,  9, 12, 15,  2,
	0, 7, 14,  5, 12,  3, 10,  1,  8, 15,  6, 13,  4, 11,  2,  9,
}

local HEX = "0123456789abcdef"

local byte = string.byte
local char = string.char
local sub = string.sub
local concat = table.concat
local floor = math.floor

-- ── Helper: read a 32-bit little-endian word from a byte string ──────────────

--: (string, integer) -> integer
local function le32(s, i)
	local b0, b1, b2, b3 = byte(s, i, i + 3)
	return bor(b0 or 0, lshift(b1 or 0, 8), lshift(b2 or 0, 16), lshift(b3 or 0, 24))
end

-- ── Helper: write a 32-bit value as 4 little-endian bytes ────────────────────

--: (number) -> string
local function to_le32(v)
	local vi = v --[[:! integer]]
	return char(
		band(vi, 0xff),
		band(rshift(vi, 8), 0xff),
		band(rshift(vi, 16), 0xff),
		band(rshift(vi, 24), 0xff)
	)
end

-- ── Helper: convert 16 raw bytes to 32-char hex ─────────────────────────────

--: (string) -> string
local function raw_to_hex(raw)
	local parts = {}
	for i = 1, 16 do
		local b = byte(raw, i) or 0
		parts[#parts + 1] = sub(HEX, rshift(b, 4) + 1, rshift(b, 4) + 1)
			.. sub(HEX, band(b, 0xf) + 1, band(b, 0xf) + 1)
	end
	return concat(parts)
end

-- ── Core: process one 64-byte block ─────────────────────────────────────────

--: (string, integer, integer, integer, integer, integer) -> (number, number, number, number)
local function process_block(block, offset, a, b, c, d)
	-- Read 16 little-endian 32-bit words
	local m = {} --: { [integer]: integer }
	for i = 0, 15 do
		m[i] = le32(block, offset + i * 4)
	end

	local aa, bb, cc, dd = a, b, c, d

	for i = 1, 64 do
		local f = 0 --: integer
		local g = 0 --: integer
		if i <= 16 then
			f = bor(band(b, c), band(bnot(b), d))
			g = G_IDX[i] or 0
		elseif i <= 32 then
			f = bor(band(d, b), band(bnot(d), c))
			g = G_IDX[i] or 0
		elseif i <= 48 then
			f = bxor(b, c, d)
			g = G_IDX[i] or 0
		else
			f = bxor(c, bor(b, bnot(d)))
			g = G_IDX[i] or 0
		end

		f = tobit(f + a + (T[i] or 0) + (m[g] or 0))
		a = d
		d = c
		c = b
		b = tobit(b + rol(f, S[i] or 0))
	end

	return aa + a, bb + b, cc + c, dd + d
end

-- ── Pad message per RFC 1321 ────────────────────────────────────────────────

local function pad_message(msg)
	local len = #msg
	local bit_len = len * 8

	-- Append 0x80 byte, then zeros, then 64-bit LE length
	-- Padded length must be 0 mod 64, with room for 1 + padding + 8 bytes
	local pad_len = (56 - (len + 1) % 64) % 64
	local padding = char(0x80) .. char(0):rep(pad_len)

	-- 64-bit little-endian bit length
	-- For strings up to ~256 MB, low 32 bits suffice; high 32 bits are 0
	-- but we must handle lengths > 2^29 bytes (bit_len > 2^32)
	local lo = bit_len % 0x100000000
	local hi = floor(bit_len / 0x100000000)

	return msg .. padding .. to_le32(lo) .. to_le32(hi)
end

-- ── One-shot digest_raw ─────────────────────────────────────────────────────

local function digest_raw(data)
	if type(data) ~= "string" then
		return nil, "md5: expected string"
	end

	local padded = pad_message(data)
	local a = 0x67452301 --: integer
	local b = tobit(0xefcdab89) --: integer
	local c = tobit(0x98badcfe) --: integer
	local d = 0x10325476 --: integer

	for i = 1, #padded, 64 do
		local na, nb, nc, nd = process_block(padded, i, a, b, c, d)
		a = tobit(na); b = tobit(nb); c = tobit(nc); d = tobit(nd)
	end

	return to_le32(a) .. to_le32(b) .. to_le32(c) .. to_le32(d)
end

-- ── One-shot digest (hex) ───────────────────────────────────────────────────

local function digest(data)
	local raw, err = digest_raw(data)
	if not raw then return nil, err end
	return raw_to_hex(raw)
end

-- ── Streaming hasher ────────────────────────────────────────────────────────

--:: HasherState = { _a: integer, _b: integer, _c: integer, _d: integer, _buf: string, _len: integer }

local Hasher = {}
Hasher.__index = Hasher

--: (self: HasherState, string) -> (HasherState | nil, string | nil)
function Hasher:update(data)
	if type(data) ~= "string" then
		return nil, "md5: expected string"
	end
	self._buf = self._buf .. data
	self._len = self._len + #data

	-- Process complete 64-byte blocks
	local buf = self._buf
	local off = 1
	while #buf - off + 1 >= 64 do
		local na, nb, nc, nd = process_block(buf, off, self._a, self._b, self._c, self._d)
		self._a = tobit(na); self._b = tobit(nb); self._c = tobit(nc); self._d = tobit(nd)
		off = off + 64
	end
	if off > 1 then
		self._buf = sub(buf, off)
	end
	return self
end

--: (self: HasherState) -> string
function Hasher:digest_raw()
	-- Finalize without mutating state (allow continued use after digest)
	local remaining = self._buf
	local total_bits = self._len * 8

	local pad_len = (56 - (#remaining + 1) % 64) % 64
	local padded = remaining .. char(0x80) .. char(0):rep(pad_len)

	local lo = total_bits % 0x100000000
	local hi = floor(total_bits / 0x100000000)
	padded = padded .. to_le32(lo) .. to_le32(hi)

	local a, b, c, d = self._a, self._b, self._c, self._d
	for i = 1, #padded, 64 do
		local na, nb, nc, nd = process_block(padded, i, a, b, c, d)
		a = tobit(na); b = tobit(nb); c = tobit(nc); d = tobit(nd)
	end

	return to_le32(a) .. to_le32(b) .. to_le32(c) .. to_le32(d)
end

function Hasher:digest()
	return raw_to_hex(self:digest_raw())
end

function Hasher:reset()
	self._a = 0x67452301 --: integer
	self._b = tobit(0xefcdab89) --: integer
	self._c = tobit(0x98badcfe) --: integer
	self._d = 0x10325476 --: integer
	self._buf = ""
	self._len = 0
	return self
end

local function new()
	local h = setmetatable({}, Hasher)
	h:reset()
	return h
end

-- ── Module exports ──────────────────────────────────────────────────────────

M.digest = digest
M.digest_raw = digest_raw
M.new = new
M.encode = digest

return M
