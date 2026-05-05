-- lib/hash/xxhash/init.lua
-- xxHash32 and xxHash64 non-cryptographic hash functions, pure Lua.
-- Reference: https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local band, bxor = bit.band, bit.bxor
local lshift, rshift = bit.lshift, bit.rshift
local rol = bit.rol
local tobit = bit.tobit
local byte = string.byte
local floor = math.floor

local M = {}
M._tier = "pure"

-- ── xxHash32 ────────────────────────────────────────────────────────────────

local PRIME32_1 = tobit(0x9E3779B1)
local PRIME32_2 = tobit(0x85EBCA77)
local PRIME32_3 = tobit(0xC2B2AE3D)
local PRIME32_4 = tobit(0x27D4EB2F)
local PRIME32_5 = tobit(0x165667B1)

-- Overflow-safe 32-bit multiply. Splits into 16-bit halves.
local function mul32(a, b)
	local a_lo = band(a, 0xFFFF)
	local a_hi = band(rshift(a, 16), 0xFFFF)
	local b_lo = band(b, 0xFFFF)
	local b_hi = band(rshift(b, 16), 0xFFFF)
	return tobit(a_lo * b_lo + lshift(a_lo * b_hi + a_hi * b_lo, 16))
end

-- Read uint32 little-endian from string at 1-based offset.
local function read32(s, i)
	local b0, b1, b2, b3 = byte(s, i, i + 3)
	return tobit(b0 + b1 * 256 + b2 * 65536 + b3 * 16777216)
end

local function round32(acc, input)
	acc = tobit(acc + mul32(input, PRIME32_2))
	acc = rol(acc, 13)
	return mul32(acc, PRIME32_1)
end

local function avalanche32(h)
	h = mul32(bxor(h, rshift(h, 15)), PRIME32_2)
	h = mul32(bxor(h, rshift(h, 13)), PRIME32_3)
	return bxor(h, rshift(h, 16))
end

-- Convert signed 32-bit to unsigned number.
local function u32(v)
	if v < 0 then return v + 4294967296 end
	return v
end

--: (data: string, seed: number | nil) -> number
function M.xxh32(data, seed)
	seed = tobit(seed or 0)
	local len = #data
	local h
	local i = 1

	if len >= 16 then
		local v1 = tobit(seed + PRIME32_1 + PRIME32_2)
		local v2 = tobit(seed + PRIME32_2)
		local v3 = seed
		local v4 = tobit(seed - PRIME32_1)
		local limit = len - 15
		while i <= limit do
			v1 = round32(v1, read32(data, i))
			v2 = round32(v2, read32(data, i + 4))
			v3 = round32(v3, read32(data, i + 8))
			v4 = round32(v4, read32(data, i + 12))
			i = i + 16
		end
		h = tobit(rol(v1, 1) + rol(v2, 7) + rol(v3, 12) + rol(v4, 18))
	else
		h = tobit(seed + PRIME32_5)
	end

	h = tobit(h + len)

	-- Remaining 4-byte chunks
	while i <= len - 3 do
		h = mul32(rol(tobit(h + mul32(read32(data, i), PRIME32_3)), 17), PRIME32_4)
		i = i + 4
	end

	-- Remaining bytes
	while i <= len do
		h = mul32(rol(tobit(h + mul32(byte(data, i), PRIME32_5)), 11), PRIME32_1)
		i = i + 1
	end

	return u32(avalanche32(h))
end

-- ── xxHash32 streaming ──────────────────────────────────────────────────────

local H32 = {}
H32.__index = H32

function H32:reset(seed)
	seed = tobit(seed or 0)
	self._seed = seed
	self._v1 = tobit(seed + PRIME32_1 + PRIME32_2)
	self._v2 = tobit(seed + PRIME32_2)
	self._v3 = seed
	self._v4 = tobit(seed - PRIME32_1)
	self._total_len = 0
	self._buf = ""
	self._large = false
end

function H32:update(data)
	if type(data) ~= "string" then return nil, "xxh32: update expects a string" end
	self._total_len = self._total_len + #data
	if #self._buf > 0 then
		data = self._buf .. data
		self._buf = ""
	end
	local len = #data
	local i = 1
	if len >= 16 then
		self._large = true
		local v1, v2, v3, v4 = self._v1, self._v2, self._v3, self._v4
		local limit = len - 15
		while i <= limit do
			v1 = round32(v1, read32(data, i))
			v2 = round32(v2, read32(data, i + 4))
			v3 = round32(v3, read32(data, i + 8))
			v4 = round32(v4, read32(data, i + 12))
			i = i + 16
		end
		self._v1, self._v2, self._v3, self._v4 = v1, v2, v3, v4
	end
	if i <= len then self._buf = data:sub(i) end
end

function H32:digest()
	local h
	if self._large then
		h = tobit(rol(self._v1, 1) + rol(self._v2, 7) + rol(self._v3, 12) + rol(self._v4, 18))
	else
		h = tobit(self._seed + PRIME32_5)
	end
	h = tobit(h + self._total_len)
	local buf = self._buf
	local blen = #buf
	local i = 1
	while i <= blen - 3 do
		h = mul32(rol(tobit(h + mul32(read32(buf, i), PRIME32_3)), 17), PRIME32_4)
		i = i + 4
	end
	while i <= blen do
		h = mul32(rol(tobit(h + mul32(byte(buf, i), PRIME32_5)), 11), PRIME32_1)
		i = i + 1
	end
	return u32(avalanche32(h))
end

function M.new32(seed)
	local self = setmetatable({}, H32)
	self:reset(seed)
	return self
end

-- ── xxHash64 (FFI uint64_t) ─────────────────────────────────────────────────

local ffi_ok, ffi = pcall(require, "ffi")

if ffi_ok then
	local uint64 = ffi.typeof("uint64_t")

	local P1 = ffi.cast("uint64_t", 0x9E3779B185EBCA87ULL)
	local P2 = ffi.cast("uint64_t", 0xC2B2AE3D27D4EB4FULL)
	local P3 = ffi.cast("uint64_t", 0x165667B19E3779F9ULL)
	local P4 = ffi.cast("uint64_t", 0x85EBCA77C2B2AE63ULL)
	local P5 = ffi.cast("uint64_t", 0x27D4EB2F165667C5ULL)

	-- Split uint64 into two unsigned 32-bit Lua numbers.
	local function split64(v)
		-- v is uint64_t cdata
		local lo = tonumber(v % 4294967296ULL)
		local hi = tonumber((v - (v % 4294967296ULL)) / 4294967296ULL)
		return hi, lo
	end

	-- Construct uint64 from two unsigned 32-bit Lua numbers.
	local function join64(hi, lo)
		return uint64(lo) + uint64(hi) * 4294967296ULL
	end

	-- XOR two uint64 values.
	local function xor64(a, b)
		local a_hi, a_lo = split64(a)
		local b_hi, b_lo = split64(b)
		return join64(
			u32(bxor(tobit(a_hi), tobit(b_hi))),
			u32(bxor(tobit(a_lo), tobit(b_lo)))
		)
	end

	-- Left rotate uint64 by n bits (0 < n < 64).
	local function rol64(v, n)
		-- (v << n) | (v >> (64-n))
		-- Use multiply for left shift, divide for right shift on uint64.
		local left = v * (2ULL ^ n)
		local right = (v - v % (2ULL ^ (64 - n))) / (2ULL ^ (64 - n))
		-- OR = add since bits don't overlap
		return left + right
	end

	-- Right shift uint64 by n bits.
	local function shr64(v, n)
		return (v - v % (2ULL ^ n)) / (2ULL ^ n)
	end

	-- Read uint64 little-endian from string at 1-based offset.
	local function read64(s, i)
		local lo = read32(s, i)
		local hi = read32(s, i + 4)
		return join64(u32(hi), u32(lo))
	end

	local function round64(acc, input)
		acc = acc + input * P2
		acc = rol64(acc, 31)
		return acc * P1
	end

	local function merge_round64(acc, val)
		val = round64(0ULL, val)
		acc = xor64(acc, val)
		return acc * P1 + P4
	end

	local function avalanche64(h)
		h = xor64(h, shr64(h, 33)) * P2
		h = xor64(h, shr64(h, 29)) * P3
		return xor64(h, shr64(h, 32))
	end

	local function to_hex64(h)
		local hi, lo = split64(h)
		return string.format("%08x%08x", hi, lo)
	end

	local function xxh64_oneshot(data, seed)
		local s = uint64(seed or 0)
		local len = #data
		local h
		local i = 1

		if len >= 32 then
			local v1 = s + P1 + P2
			local v2 = s + P2
			local v3 = s
			local v4 = s - P1
			local limit = len - 31
			while i <= limit do
				v1 = round64(v1, read64(data, i))
				v2 = round64(v2, read64(data, i + 8))
				v3 = round64(v3, read64(data, i + 16))
				v4 = round64(v4, read64(data, i + 24))
				i = i + 32
			end
			h = rol64(v1, 1) + rol64(v2, 7) + rol64(v3, 12) + rol64(v4, 18)
			h = merge_round64(h, v1)
			h = merge_round64(h, v2)
			h = merge_round64(h, v3)
			h = merge_round64(h, v4)
		else
			h = s + P5
		end

		h = h + uint64(len)

		-- Remaining 8-byte chunks
		while i <= len - 7 do
			local k1 = round64(0ULL, read64(data, i))
			h = rol64(xor64(h, k1), 27) * P1 + P4
			i = i + 8
		end

		-- Remaining 4-byte chunks
		while i <= len - 3 do
			local v32 = read32(data, i)
			h = rol64(xor64(h, uint64(u32(v32)) * P1), 23) * P2 + P3
			i = i + 4
		end

		-- Remaining bytes
		while i <= len do
			h = rol64(xor64(h, uint64(byte(data, i)) * P5), 11) * P1
			i = i + 1
		end

		return to_hex64(avalanche64(h))
	end

	--: (data: string, seed: number | nil) -> string
	M.xxh64 = xxh64_oneshot

	-- ── xxHash64 streaming ──────────────────────────────────────────────────

	local H64 = {}
	H64.__index = H64

	function H64:reset(seed)
		local s = uint64(seed or 0)
		self._seed = s
		self._v1 = s + P1 + P2
		self._v2 = s + P2
		self._v3 = s
		self._v4 = s - P1
		self._total_len = 0
		self._buf = ""
		self._large = false
	end

	function H64:update(data)
		if type(data) ~= "string" then return nil, "xxh64: update expects a string" end
		self._total_len = self._total_len + #data
		if #self._buf > 0 then
			data = self._buf .. data
			self._buf = ""
		end
		local len = #data
		local i = 1
		if len >= 32 then
			self._large = true
			local v1, v2, v3, v4 = self._v1, self._v2, self._v3, self._v4
			local limit = len - 31
			while i <= limit do
				v1 = round64(v1, read64(data, i))
				v2 = round64(v2, read64(data, i + 8))
				v3 = round64(v3, read64(data, i + 16))
				v4 = round64(v4, read64(data, i + 24))
				i = i + 32
			end
			self._v1, self._v2, self._v3, self._v4 = v1, v2, v3, v4
		end
		if i <= len then self._buf = data:sub(i) end
	end

	function H64:digest()
		local h
		if self._large then
			local v1, v2, v3, v4 = self._v1, self._v2, self._v3, self._v4
			h = rol64(v1, 1) + rol64(v2, 7) + rol64(v3, 12) + rol64(v4, 18)
			h = merge_round64(h, v1)
			h = merge_round64(h, v2)
			h = merge_round64(h, v3)
			h = merge_round64(h, v4)
		else
			h = self._seed + P5
		end
		h = h + uint64(self._total_len)
		local buf = self._buf
		local blen = #buf
		local i = 1
		while i <= blen - 7 do
			local k1 = round64(0ULL, read64(buf, i))
			h = rol64(xor64(h, k1), 27) * P1 + P4
			i = i + 8
		end
		while i <= blen - 3 do
			local v32 = read32(buf, i)
			h = rol64(xor64(h, uint64(u32(v32)) * P1), 23) * P2 + P3
			i = i + 4
		end
		while i <= blen do
			h = rol64(xor64(h, uint64(byte(buf, i)) * P5), 11) * P1
			i = i + 1
		end
		return to_hex64(avalanche64(h))
	end

	function M.new64(seed)
		local self = setmetatable({}, H64)
		self:reset(seed)
		return self
	end
else
	-- No FFI: xxHash64 unavailable
	M.xxh64 = function()
		return nil, "xxh64 requires LuaJIT FFI"
	end
	M.new64 = function()
		return nil, "xxh64 requires LuaJIT FFI"
	end
end

return M
