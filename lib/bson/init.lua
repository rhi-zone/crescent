if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- BSON (Binary JSON) encode/decode — compatible with MongoDB wire format.
-- Spec: http://bsonspec.org/spec.html
-- All multi-byte integers are little-endian.

local M = {}

M._tier = "pure"

local ffi_ok, ffi = pcall(require, "ffi")
if not ffi_ok then ffi = nil end

local bit = require("bit")
local byte = string.byte
local char = string.char
local sub = string.sub
local concat = table.concat
local floor = math.floor
local type = type

-- ── sentinels ────────────────────────────────────────────────────────────────

local null_mt = {}
local datetime_mt = {}
local binary_mt = {}

--- BSON null sentinel. Use this to encode BSON null (distinct from Lua nil).
M.null = setmetatable({}, null_mt)

--- Wrap an integer millisecond timestamp as a BSON UTC datetime.
--: (ms: number) -> { _bson_type: string, ms: number }
function M.datetime(ms)
	return setmetatable({ ms = ms }, datetime_mt)
end

--- Wrap binary data as a BSON binary value.
--: (data: string, subtype: number) -> { _bson_type: string, data: string, subtype: number }
function M.binary(data, subtype)
	return setmetatable({ data = data, subtype = subtype or 0 }, binary_mt)
end

--- Returns true if v is a BSON datetime object.
--: (v: unknown) -> boolean
function M.is_datetime(v)
	return type(v) == "table" and getmetatable(v) == datetime_mt
end

--- Returns true if v is a BSON binary object.
--: (v: unknown) -> boolean
function M.is_binary(v)
	return type(v) == "table" and getmetatable(v) == binary_mt
end

-- ── little-endian pack helpers ───────────────────────────────────────────────

local function pack_i32(n)
	n = bit.tobit(n)
	return char(
		bit.band(n, 0xff),
		bit.band(bit.rshift(n, 8), 0xff),
		bit.band(bit.rshift(n, 16), 0xff),
		bit.band(bit.rshift(n, 24), 0xff)
	)
end

local function pack_u32(n)
	return char(
		n % 256,
		floor(n / 256) % 256,
		floor(n / 65536) % 256,
		floor(n / 16777216) % 256
	)
end

-- Pack int64 as little-endian 8 bytes.
-- n is a Lua number (double) — safe up to 2^53 in magnitude.
local function pack_i64(n)
	-- Split n into signed hi32 and unsigned lo32 via floor division.
	-- This avoids the precision loss of adding 2^64 as a double.
	local hi = floor(n / 4294967296)
	local lo = n - hi * 4294967296
	-- hi may be negative (e.g. -1 for values in [-2^32, 0)).
	-- Convert hi to unsigned 32-bit for byte extraction.
	if hi < 0 then hi = hi + 4294967296 end
	return char(
		lo % 256,
		floor(lo / 256) % 256,
		floor(lo / 65536) % 256,
		floor(lo / 16777216) % 256,
		hi % 256,
		floor(hi / 256) % 256,
		floor(hi / 65536) % 256,
		floor(hi / 16777216) % 256
	)
end

-- Pack IEEE 754 double as little-endian 8 bytes.
-- Uses FFI when available for exact bit-level representation.
local pack_double
if ffi then
	local _tmp = ffi.new("double[1]")
	local _ptr  -- will be cast after first use
	pack_double = function(n)
		_tmp[0] = n
		local p = ffi.cast("uint8_t*", _tmp)
		return char(p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7])
	end
else
	-- Pure-Lua IEEE 754 double → 8 bytes little-endian
	local huge = math.huge
	pack_double = function(n)
		if n == 0 then
			if 1 / n == -huge then
				-- -0
				return "\0\0\0\0\0\0\0\128"
			end
			return "\0\0\0\0\0\0\0\0"
		end
		if n ~= n then
			-- NaN
			return "\0\0\0\0\0\0\248\127"
		end
		local sign = 0
		if n < 0 then sign = 128; n = -n end
		if n == huge then
			return char(0, 0, 0, 0, 0, 0, 240, sign + 127)
		end
		local exp = 0
		local mant = n
		if mant >= 2 then
			while mant >= 2 do mant = mant / 2; exp = exp + 1 end
		elseif mant < 1 then
			while mant < 1 and exp > -1022 do mant = mant * 2; exp = exp - 1 end
		end
		if exp == -1022 and mant < 1 then
			-- subnormal
			local frac = mant * 4503599627370496
			local lo = frac % 4294967296
			local hi = floor(frac / 4294967296)
			return char(
				lo % 256, floor(lo / 256) % 256,
				floor(lo / 65536) % 256, floor(lo / 16777216) % 256,
				hi % 256, floor(hi / 256) % 256,
				floor(hi / 65536) % 256, sign
			)
		end
		exp = exp + 1023
		mant = mant - 1
		local frac = mant * 4503599627370496
		local lo = frac % 4294967296
		local hi = floor(frac / 4294967296)
		-- little-endian layout:
		-- byte0..3 = lo bits
		-- byte4..6 = hi bits (mantissa high)
		-- byte7 = sign | exp high bits
		local b5 = floor(hi / 256) % 256
		local b6 = (exp % 16) * 16 + floor(hi / 65536) % 16
		local b7 = sign + floor(exp / 16)
		return char(
			lo % 256, floor(lo / 256) % 256,
			floor(lo / 65536) % 256, floor(lo / 16777216) % 256,
			hi % 256, b5, b6, b7
		)
	end
end

-- ── little-endian unpack helpers ─────────────────────────────────────────────

local function unpack_i32(s, pos)
	local b1, b2, b3, b4 = byte(s, pos, pos + 3)
	local n = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
	if n >= 2147483648 then n = n - 4294967296 end
	return n, pos + 4
end

local function unpack_u32(s, pos)
	local b1, b2, b3, b4 = byte(s, pos, pos + 3)
	return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216, pos + 4
end

local function unpack_i64(s, pos)
	local lo, hi
	lo, pos = unpack_u32(s, pos)
	hi, pos = unpack_u32(s, pos)
	-- Convert hi to signed 32-bit, then compute: hi_signed * 2^32 + lo_unsigned.
	-- This avoids the precision loss of adding/subtracting 2^64 as a double.
	if hi >= 2147483648 then hi = hi - 4294967296 end
	return hi * 4294967296 + lo, pos
end

-- Unpack IEEE 754 double from little-endian 8 bytes.
local unpack_double
if ffi then
	local _tmp = ffi.new("uint8_t[8]")
	local _dptr = ffi.cast("double*", _tmp)
	unpack_double = function(s, pos)
		for i = 0, 7 do
			_tmp[i] = byte(s, pos + i)
		end
		return tonumber(_dptr[0]), pos + 8
	end
else
	local huge = math.huge
	unpack_double = function(s, pos)
		local b1, b2, b3, b4, b5, b6, b7, b8 = byte(s, pos, pos + 7)
		-- little-endian: b1=byte0(lsb), b8=byte7(msb)
		local sign = 1
		if b8 >= 128 then sign = -1; b8 = b8 - 128 end
		local exp = b8 * 16 + floor(b7 / 16)
		local hi = (b7 % 16) * 65536 + b6 * 256 + b5
		local lo = b4 * 16777216 + b3 * 65536 + b2 * 256 + b1
		local mant = hi * 4294967296 + lo
		if exp == 0 then
			if mant == 0 then return sign * 0, pos + 8 end
			return sign * mant * 2^(-1074), pos + 8
		elseif exp == 2047 then
			if mant == 0 then return sign * huge, pos + 8 end
			return 0/0, pos + 8
		end
		return sign * (1 + mant / 4503599627370496) * 2^(exp - 1023), pos + 8
	end
end

-- ── encode ────────────────────────────────────────────────────────────────────

-- Returns true if t is a BSON array (sequential integer keys 1..n).
local function is_array(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	if n == 0 then return false end
	for i = 1, n do
		if t[i] == nil then return false end
	end
	return true
end

-- Returns true if t looks like an array-document (keys "0","1",...,"n-1").
local function is_array_doc(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	if n == 0 then return false end
	for i = 0, n - 1 do
		if t[tostring(i)] == nil then return false end
	end
	return true
end

-- Convert a decoded array-document (keys "0","1",...) to a Lua array (keys 1,2,...).
local function array_doc_to_array(t)
	local arr = {}
	for k, v in pairs(t) do
		local i = tonumber(k)
		if i then arr[i + 1] = v end
	end
	return arr
end

local encode_document  -- forward decl (encodes a Lua table as BSON document body)
local encode_value     -- forward decl

-- Encode a single BSON element (type byte + cstring key + value).
-- Returns the element bytes or (nil, errmsg).
local function encode_element(key, val)
	local venc, err = encode_value(val)
	if venc == nil then return nil, err end
	-- type byte is embedded in venc[1], value follows
	-- We pack as: type_byte + key_cstring + value_bytes
	-- encode_value returns {type_byte, value_bytes} as two values for efficiency
	-- Actually we return a table {typebyte_str, key_cstr, value_bytes}
	return venc, key .. "\0"
end

-- Returns: type_byte_char .. value_bytes, or (nil, errmsg)
encode_value = function(v)
	local tv = type(v)

	if tv == "nil" or (tv == "table" and getmetatable(v) == null_mt) then
		-- null
		return "\x0a"
	end

	if tv == "boolean" then
		return "\x08" .. (v and "\x01" or "\x00")
	end

	if tv == "number" then
		-- integer-valued?
		if v == floor(v) and v >= -2147483648 and v <= 2147483647 then
			return "\x10" .. pack_i32(v)
		elseif v == floor(v) and v >= -9007199254740992 and v <= 9007199254740992 then
			return "\x12" .. pack_i64(v)
		else
			return "\x01" .. pack_double(v)
		end
	end

	if tv == "string" then
		local len = #v
		return "\x02" .. pack_i32(len + 1) .. v .. "\0"
	end

	if tv == "table" then
		local mt = getmetatable(v)
		if mt == datetime_mt then
			return "\x09" .. pack_i64(v.ms)
		end
		if mt == binary_mt then
			local data = v.data
			local subtype = v.subtype or 0
			return "\x05" .. pack_i32(#data) .. char(subtype) .. data
		end
		-- embedded document or array
		local doc, derr = encode_document(v)
		if not doc then return nil, derr end
		if is_array(v) then
			return "\x04" .. doc
		else
			return "\x03" .. doc
		end
	end

	return nil, "unsupported type: " .. tv
end

-- Encode a Lua table as a BSON document (size + elements + terminator).
-- Returns: bytes string, or (nil, errmsg)
encode_document = function(t)
	local parts = {}
	local tv = type(t)
	if tv ~= "table" then
		return nil, "expected table, got " .. tv
	end

	if is_array(t) then
		-- array: keys are "0", "1", ...
		for i = 1, #t do
			local venc, err = encode_value(t[i])
			if venc == nil then return nil, err end
			parts[#parts + 1] = sub(venc, 1, 1)     -- type byte
			parts[#parts + 1] = tostring(i - 1) .. "\0"  -- key as cstring
			parts[#parts + 1] = sub(venc, 2)         -- value bytes
		end
	else
		for k, v in pairs(t) do
			local ks = tostring(k)
			local venc, err = encode_value(v)
			if venc == nil then return nil, err end
			parts[#parts + 1] = sub(venc, 1, 1)     -- type byte
			parts[#parts + 1] = ks .. "\0"            -- key as cstring
			parts[#parts + 1] = sub(venc, 2)         -- value bytes
		end
	end

	local body = concat(parts)
	-- total size = 4 (size field) + body + 1 (terminator)
	local total = 4 + #body + 1
	return pack_i32(total) .. body .. "\0"
end

--- Encode a Lua value as a BSON document.
-- A top-level nil encodes as an empty document.
-- Returns: bytes string, or (nil, errmsg)
--: (value: unknown) -> string | (nil, string)
function M.encode(value)
	if value == nil then
		-- empty document
		return pack_i32(5) .. "\0"
	end
	if type(value) ~= "table" then
		return nil, "BSON top-level must be a table (document)"
	end
	return encode_document(value)
end

-- ── decode ────────────────────────────────────────────────────────────────────

-- Read a null-terminated cstring starting at pos.
-- Returns: string, pos_after_null
local function read_cstring(s, pos)
	local nul = s:find("\0", pos, true)
	if not nul then
		return nil, "unterminated cstring"
	end
	return sub(s, pos, nul - 1), nul + 1
end

-- Decode a BSON document starting at pos.
-- Returns: table, pos_after_doc, or (nil, errmsg)
local function decode_document(s, pos)
	local slen = #s
	if pos + 4 > slen + 1 then
		return nil, "truncated document size"
	end
	local doc_size, npos = unpack_i32(s, pos)
	if doc_size < 5 then
		return nil, "invalid document size: " .. doc_size
	end
	local doc_end = pos + doc_size - 1  -- position of terminator byte
	if doc_end > slen then
		return nil, "truncated document (size=" .. doc_size .. ", available=" .. (slen - pos + 1) .. ")"
	end

	local t = {}
	local cur = npos

	while cur < doc_end do
		-- read type byte
		local tbyte = byte(s, cur)
		if tbyte == nil then return nil, "truncated element type" end
		cur = cur + 1

		-- read key
		local key, err
		key, cur = read_cstring(s, cur)
		if not key then return nil, err end

		-- read value
		local val
		if tbyte == 0x01 then
			-- double
			if cur + 7 > slen then return nil, "truncated double" end
			val, cur = unpack_double(s, cur)

		elseif tbyte == 0x02 then
			-- UTF-8 string: int32 len (including null), bytes, null
			if cur + 3 > slen then return nil, "truncated string length" end
			local ssize
			ssize, cur = unpack_i32(s, cur)
			if cur + ssize - 1 > slen then return nil, "truncated string data" end
			val = sub(s, cur, cur + ssize - 2)  -- exclude trailing null
			cur = cur + ssize

		elseif tbyte == 0x03 then
			-- embedded document
			val, cur, err = decode_document(s, cur)
			if not val then return nil, err end

		elseif tbyte == 0x04 then
			-- array (document with "0","1",... keys → convert to Lua array)
			local arr_t
			arr_t, cur, err = decode_document(s, cur)
			if not arr_t then return nil, err end
			-- arr_t has string keys "0","1","2"... — convert to 1-indexed Lua array
			local arr = {}
			for k, v in pairs(arr_t) do
				local i = tonumber(k)
				if i then
					arr[i + 1] = v  -- BSON 0-indexed → Lua 1-indexed
				end
			end
			val = arr

		elseif tbyte == 0x05 then
			-- binary: int32 length, uint8 subtype, bytes
			if cur + 4 > slen then return nil, "truncated binary length" end
			local blen
			blen, cur = unpack_i32(s, cur)
			if cur > slen then return nil, "truncated binary subtype" end
			local subtype = byte(s, cur)
			cur = cur + 1
			if cur + blen - 1 > slen then return nil, "truncated binary data" end
			val = M.binary(sub(s, cur, cur + blen - 1), subtype)
			cur = cur + blen

		elseif tbyte == 0x08 then
			-- boolean
			local bval = byte(s, cur)
			cur = cur + 1
			val = (bval == 0x01)

		elseif tbyte == 0x09 then
			-- UTC datetime: int64 ms
			if cur + 7 > slen then return nil, "truncated datetime" end
			local ms
			ms, cur = unpack_i64(s, cur)
			val = M.datetime(ms)

		elseif tbyte == 0x0a then
			-- null
			val = M.null

		elseif tbyte == 0x10 then
			-- int32
			if cur + 3 > slen then return nil, "truncated int32" end
			val, cur = unpack_i32(s, cur)

		elseif tbyte == 0x12 then
			-- int64
			if cur + 7 > slen then return nil, "truncated int64" end
			val, cur = unpack_i64(s, cur)

		else
			return nil, string.format("unsupported BSON type: 0x%02x", tbyte)
		end

		t[key] = val
	end

	-- verify terminator
	if byte(s, doc_end) ~= 0 then
		return nil, "missing document terminator"
	end

	return t, doc_end + 1
end

--- Decode a BSON document from bytes.
-- pos defaults to 1.
-- Returns: table, pos_after, nil on success; nil, nil, errmsg on error.
--: (bytes: string, pos: number) -> unknown, number, nil | (nil, nil, string)
function M.decode(bytes, pos)
	if type(bytes) ~= "string" then
		return nil, nil, "expected string"
	end
	pos = pos or 1
	if #bytes == 0 then
		return nil, nil, "empty input"
	end
	local t, npos = decode_document(bytes, pos)
	if not t then
		return nil, nil, npos  -- npos holds errmsg when t is nil
	end
	-- Auto-convert array-documents (keys "0","1",...) to Lua arrays.
	if is_array_doc(t) then t = array_doc_to_array(t) end
	return t, npos, nil
end

--- Decode all concatenated BSON documents from bytes.
-- Returns: array of tables, or (nil, errmsg)
--: (bytes: string) -> { unknown } | (nil, string)
function M.decode_all(bytes)
	if type(bytes) ~= "string" then
		return nil, "expected string"
	end
	local results = {}
	local pos = 1
	local len = #bytes
	while pos <= len do
		local t, npos = decode_document(bytes, pos)
		if not t then return nil, npos end  -- npos holds errmsg when t is nil
		results[#results + 1] = t
		pos = npos
	end
	return results
end

return M
