-- lib/base58/init.lua
-- Base58 and Base58Check encoding/decoding (Bitcoin/IPFS alphabet).
-- Pure Lua — no dependencies beyond lib.hash.sha256 (for Base58Check only).
--
-- Public API:
--   M.encode(data)          -> base58_string
--   M.decode(str)           -> binary_string | (nil, errmsg)
--   M.encode_check(data)    -> base58check_string
--   M.decode_check(str)     -> data_without_checksum | (nil, errmsg)
--   M._tier = "pure"

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local sbyte  = string.byte
local schar  = string.char
local floor  = math.floor
local concat = table.concat
local insert = table.insert

-- Bitcoin/IPFS alphabet: excludes 0, O, I, l to avoid visual ambiguity.
local ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

-- Decode table: byte value → 0-based index in alphabet.
-- Entries are numbers for valid chars; absent for invalid chars.
local DECODE = {}
for i = 1, 58 do
	DECODE[sbyte(ALPHABET, i)] = i - 1
end

-- ── Encode ────────────────────────────────────────────────────────────────────

--- Encode a binary string to Base58.
--- Leading zero bytes each become a leading '1' character.
--: (string) -> string
function M.encode(data)
	-- Count leading zero bytes.
	local lz = 0
	local n = #data
	for i = 1, n do
		if sbyte(data, i) == 0 then
			lz = lz + 1
		else
			break
		end
	end

	-- Convert non-zero-prefix bytes to a big-integer represented as an array
	-- of base-256 digits, most-significant first.
	local digits = {}
	for i = lz + 1, n do
		digits[#digits + 1] = sbyte(data, i)
	end

	-- Repeatedly divide by 58; collect remainders (= base-58 digits, LSB first).
	local result = {}
	while #digits > 0 do
		local rem = 0
		local new = {}
		for _, d in ipairs(digits) do
			if type(d) == "number" then
				local val = rem * 256 + d
				local q = floor(val / 58)
				rem = floor(val % 58)
				if #new > 0 or q > 0 then
					new[#new + 1] = q
				end
			end
		end
		result[#result + 1] = ALPHABET:sub(rem + 1, rem + 1)
		digits = new
	end

	-- Build output: N leading '1's + base-58 digits in big-endian order.
	local parts = {}
	if lz > 0 then
		parts[1] = string.rep("1", lz)
	end
	for i = #result, 1, -1 do
		parts[#parts + 1] = result[i]
	end
	return concat(parts)
end

-- ── Decode ────────────────────────────────────────────────────────────────────

--- Decode a Base58 string to binary.
--- Returns (nil, errmsg) on invalid characters.
--: (string) -> (string | nil, string | nil)
function M.decode(str)
	local n = #str
	if n == 0 then return "" end

	-- Count leading '1' characters (each maps to one leading zero byte).
	local lz = 0
	for i = 1, n do
		if sbyte(str, i) == 49 then -- '1' = 49
			lz = lz + 1
		else
			break
		end
	end

	-- Convert remaining chars to base-58 digits (big-endian).
	local digits = {}
	for i = lz + 1, n do
		local b = sbyte(str, i)
		local v = DECODE[b]
		if not v then
			return nil, "invalid base58 character: " .. str:sub(i, i)
		end
		digits[#digits + 1] = v
	end

	-- Repeatedly multiply current byte-array by 58 and add next digit.
	-- bytes is a big-endian array of integers 0-255.
	local bytes = {}
	for _, d in ipairs(digits) do
		if type(d) == "number" then
			local carry = d
			for j = #bytes, 1, -1 do
				local bj = bytes[j]
				if type(bj) == "number" then
					local val = bj * 58 + carry
					bytes[j] = floor(val % 256)
					carry = floor(val / 256)
				end
			end
			while carry > 0 do
				insert(bytes, 1, floor(carry % 256))
				carry = floor(carry / 256)
			end
		end
	end

	-- Prepend leading zero bytes and assemble output.
	local out = {}
	if lz > 0 then
		out[1] = string.rep("\0", lz)
	end
	for _, b in ipairs(bytes) do
		if type(b) == "number" then
			out[#out + 1] = schar(b)
		end
	end
	return concat(out)
end

-- ── SHA-256 helper (lazy-loaded for Base58Check only) ─────────────────────────

local _sha256  -- cached sha256 module

local function get_sha256()
	if not _sha256 then
		_sha256 = require("lib.hash.sha256")
	end
	return _sha256.sha256
end

local function hex_to_bin(hex)
	return (hex:gsub("..", function(h)
		return string.char(tonumber(h, 16))
	end))
end

-- Compute first 4 bytes of SHA256(SHA256(data)).
local function checksum4(data)
	local sha256fn = get_sha256()
	local h1bin = hex_to_bin(sha256fn(data))
	local h2hex = sha256fn(h1bin)
	return hex_to_bin(h2hex):sub(1, 4)
end

-- ── Base58Check ───────────────────────────────────────────────────────────────

--- Base58Check encode: append 4-byte double-SHA256 checksum then Base58-encode.
--: (string) -> string
function M.encode_check(data)
	return M.encode(data .. checksum4(data))
end

--- Base58Check decode: Base58-decode, verify 4-byte checksum, return payload.
--- Returns (nil, errmsg) on decode failure or checksum mismatch.
--: (string) -> (string | nil, string | nil)
function M.decode_check(str)
	local raw, err = M.decode(str)
	if not raw then
		return nil, err
	end
	if #raw < 4 then
		return nil, "base58check: decoded data too short (missing checksum)"
	end
	local payload = raw:sub(1, #raw - 4)
	local got_cs  = raw:sub(#raw - 3)
	local want_cs = checksum4(payload)
	if got_cs ~= want_cs then
		return nil, "base58check: checksum mismatch"
	end
	return payload
end

-- ── Codec aliases (crescent convention) ──────────────────────────────────────

M.encode_to_string   = M.encode
M.decode_from_string = M.decode
M.string_to_base58   = M.encode
M.base58_to_string   = M.decode

return M
