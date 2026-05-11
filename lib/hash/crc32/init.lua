-- lib/hash/crc32/init.lua
-- CRC32 checksum (polynomial 0xEDB88320, ISO 3309 / ITU-T V.42 / zlib/gzip/PNG).
--
-- Public API:
--   M.crc32(data, seed?)      -> unsigned 32-bit number
--   M.crc32_hex(data, seed?)  -> 8-char lowercase hex string
--   M.new(seed?)              -> streaming hasher
--     hasher:update(data)
--     hasher:digest()         -> unsigned 32-bit number
--     hasher:hex()            -> 8-char lowercase hex string
--     hasher:reset(seed?)
--   M._tier = "pure"

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local bit    = require("bit")
local band   = bit.band
local bxor   = bit.bxor
local rshift = bit.rshift
local byte   = string.byte
local format = string.format

-- ── Pre-computed CRC-32 lookup table (reflected polynomial 0xEDB88320) ────────

local crc_table = {}
for i = 0, 255 do
	local c = i
	for _ = 1, 8 do
		if c % 2 == 1 then
			c = bxor(rshift(c, 1), 0xEDB88320)
		else
			c = rshift(c, 1)
		end
	end
	crc_table[i] = c
end

-- ── One-shot hash ─────────────────────────────────────────────────────────────

-- Returns the CRC32 of `data` as an unsigned 32-bit integer.
-- `seed` defaults to 0.  Pass a prior crc32() result to chain over multiple
-- buffers: crc32(b, crc32(a)) == crc32(a .. b).
function M.crc32(data, seed)
	seed = seed or 0
	local crc = bxor(seed, 0xFFFFFFFF)
	local s = data --[[:! string]]
	for i = 1, #s do
		local b = byte(s, i) or 0
		crc = bxor(rshift(crc, 8), crc_table[band(bxor(crc, b), 0xFF)])
	end
	crc = bxor(crc, 0xFFFFFFFF)
	-- Ensure unsigned (LuaJIT bit ops return signed int32)
	if crc < 0 then crc = (crc + 4294967296) --[[:! integer]] end
	return crc
end

-- Returns the CRC32 of `data` as an 8-character lowercase hex string.
function M.crc32_hex(data, seed)
	return format("%08x", M.crc32(data, seed))
end

-- ── Streaming hasher ──────────────────────────────────────────────────────────

local H = {}
H.__index = H

function H:update(data)
	local crc = self._crc
	local s = data --[[:! string]]
	for i = 1, #s do
		local b = byte(s, i) or 0
		crc = bxor(rshift(crc, 8), crc_table[band(bxor(crc, b), 0xFF)])
	end
	self._crc = crc
end

function H:digest()
	local crc = bxor(self._crc, 0xFFFFFFFF)
	if crc < 0 then crc = (crc + 4294967296) --[[:! integer]] end
	return crc
end

function H:hex()
	return format("%08x", self:digest())
end

function H:reset(seed)
	seed = seed or 0
	self._crc = bxor(seed, 0xFFFFFFFF)
end

-- Returns a new streaming CRC32 hasher.
-- `seed` defaults to 0.
function M.new(seed)
	local h_any = (setmetatable({}, H) --[[:! { reset: (unknown, unknown) -> unknown, update: (unknown, unknown) -> unknown, digest: (unknown) -> unknown, hex: (unknown) -> unknown }]])
	h_any:reset(seed)
	return h_any
end

return M
