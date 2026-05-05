-- lib/hash/hmac/init.lua
-- HMAC construction (RFC 2104) using lib/hash/ algorithms.
--
-- Public API:
--   M.sha256(key, message)        -> hex_string
--   M.sha1(key, message)          -> hex_string
--   M.sha256_binary(key, message) -> binary_string
--   M.sha1_binary(key, message)   -> binary_string
--   M.compute(hash_fn, block_size, key, message) -> binary_string

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- Lazy-loaded hash modules.
local _sha256, _sha1

local function get_sha256()
	if not _sha256 then _sha256 = require("lib.hash.sha256") end
	return _sha256
end

local function get_sha1()
	if not _sha1 then _sha1 = require("lib.hash.sha1") end
	return _sha1
end

-- Convert hex string to binary string.
local function hex_to_binary(hex)
	return (hex:gsub("..", function(h) return string.char(tonumber(h, 16)) end))
end

-- Convert binary string to lowercase hex string.
local function binary_to_hex(bin)
	local s = bin --[[:! string]]
	local parts = {}
	for i = 1, #s do
		parts[i] = string.format("%02x", string.byte(s, i) or 0)
	end
	return table.concat(parts)
end

-- XOR each byte of a string with a constant byte value.
local function xor_bytes(s, byte_val)
	local str = s --[[:! string]]
	local out = {}
	for i = 1, #str do
		local b = string.byte(str, i) or 0
		out[i] = string.char(bit and bit.bxor(b, byte_val)
			or (((b + byte_val) % 256 ~= b)
				and b or 0))  -- fallback not needed, see below
	end
	return table.concat(out)
end

-- Pure Lua XOR fallback for environments without bit library.
-- Uses lookup table for correctness.
local xor_lookup
local function ensure_xor_lookup()
	if xor_lookup then return end
	xor_lookup = {}
	-- Build XOR table via decomposition.
	for a = 0, 255 do
		xor_lookup[a] = {}
		for b = 0, 255 do
			local val = 0 --: number
			local sa = a --: number
			local sb = b --: number
			for p = 0, 7 do
				local ba = sa % 2
				local bb = sb % 2
				if ba ~= bb then val = val + 2 ^ p end
				sa = (sa - ba) / 2
				sb = (sb - bb) / 2
			end
			xor_lookup[a][b] = val
		end
	end
end

-- XOR a string with a repeated byte value using the best available method.
local function xor_str_byte(s, byte_val)
	local ok, blib = pcall(require, "bit")
	if ok then
		local bxor = blib.bxor
		local out = {}
		for i = 1, #s do
			out[i] = string.char(bxor(string.byte(s, i), byte_val))
		end
		return table.concat(out)
	end
	-- Pure Lua fallback.
	ensure_xor_lookup()
	local out = {}
	for i = 1, #s do
		out[i] = string.char(xor_lookup[string.byte(s, i)][byte_val])
	end
	return table.concat(out)
end

--- Generic HMAC computation.
-- hash_fn: function(string) -> binary_string (raw bytes, NOT hex)
-- block_size: hash block size in bytes (64 for SHA-1/SHA-256)
-- key: HMAC key (any length)
-- message: data to authenticate
-- Returns: binary string (raw HMAC digest)
--: ((string) -> string, number, string, string) -> string
function M.compute(hash_fn, block_size, key, message)
	-- Step 1: If key longer than block size, hash it.
	if #key > block_size then
		key = hash_fn(key)
	end

	-- Step 2: Pad key to block_size with zeros.
	if #key < block_size then
		key = key .. string.rep("\0", (block_size - #key) --[[:! integer]])
	end

	-- Step 3: XOR key with ipad (0x36) and opad (0x5c).
	local ipad_key = xor_str_byte(key, 0x36)
	local opad_key = xor_str_byte(key, 0x5c)

	-- Step 4: HMAC = H(opad_key || H(ipad_key || message))
	local inner = hash_fn(ipad_key .. message)
	return hash_fn(opad_key .. inner)
end

--- HMAC-SHA256 returning raw binary.
--: (string, string) -> string
function M.sha256_binary(key, message)
	local sha = get_sha256()
	local function hash_bin(s)
		return hex_to_binary(sha.sha256(s))
	end
	return M.compute(hash_bin, 64, key, message)
end

--- HMAC-SHA256 returning hex string.
--: (string, string) -> string
function M.sha256(key, message)
	return binary_to_hex(M.sha256_binary(key, message))
end

--- HMAC-SHA1 returning raw binary.
--: (string, string) -> string
function M.sha1_binary(key, message)
	local sha = get_sha1()
	return M.compute(sha.binary, 64, key, message)
end

--- HMAC-SHA1 returning hex string.
--: (string, string) -> string
function M.sha1(key, message)
	return binary_to_hex(M.sha1_binary(key, message))
end

return M
