if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

local byte = string.byte
local char = string.char
local sub = string.sub
local concat = table.concat
local floor = math.floor
local huge = math.huge
local type = type

-- ── sentinel ────────────────────────────────────────────────────────────────

--: { _msgpack_bin: true }
local bin_mt = {}

--- Wrap a raw string as msgpack binary (bin8/bin16/bin32) instead of str.
--: (s: string) -> { _msgpack_bin: true, data: string }
function M.bin(s)
	return setmetatable({ data = s }, bin_mt)
end

-- ── encoding helpers ────────────────────────────────────────────────────────

--: (number) -> string
local function encode_uint16(n)
	return char(floor(n / 256) % 256, n % 256)
end

--: (number) -> string
local function encode_uint32(n)
	return char(
		floor(n / 16777216) % 256,
		floor(n / 65536) % 256,
		floor(n / 256) % 256,
		n % 256
	)
end

--: (number) -> string
local function encode_int8(n)
	if n < 0 then n = n + 256 end
	return char(n)
end

--: (number) -> string
local function encode_int16(n)
	if n < 0 then n = n + 65536 end
	return encode_uint16(n)
end

--: (number) -> string
local function encode_int32(n)
	if n < 0 then n = n + 4294967296 end
	return encode_uint32(n)
end

-- IEEE 754 double, big-endian (8 bytes)
local function encode_double(n)
	if n == 0 then
		-- distinguish +0 and -0
		if 1 / n == -huge then
			return "\128\0\0\0\0\0\0\0"
		end
		return "\0\0\0\0\0\0\0\0"
	end
	if n ~= n then
		return "\127\248\0\0\0\0\0\0" -- canonical NaN
	end
	local sign = 0
	if n < 0 then
		sign = 128
		n = -n
	end
	if n == huge then
		return char(sign + 127, 240, 0, 0, 0, 0, 0, 0)
	end
	-- normalize
	local exp = 0
	local mant = n
	if mant >= 2 then
		while mant >= 2 do mant = mant / 2; exp = exp + 1 end
	elseif mant < 1 then
		while mant < 1 and exp > -1022 do mant = mant * 2; exp = exp - 1 end
	end
	-- subnormal
	if exp == -1022 and mant < 1 then
		-- subnormal: no implicit leading 1
		local frac = mant * 4503599627370496 -- 2^52
		local lo = frac % 4294967296
		local hi = floor(frac / 4294967296)
		return char(
			sign, hi / 65536 % 256, floor(hi / 256) % 256, hi % 256,
			floor(lo / 16777216) % 256, floor(lo / 65536) % 256,
			floor(lo / 256) % 256, lo % 256
		)
	end
	exp = exp + 1023
	mant = mant - 1 -- remove implicit leading 1
	local frac = mant * 4503599627370496 -- 2^52
	local lo = frac % 4294967296
	local hi = floor(frac / 4294967296)
	local b1 = sign + floor(exp / 16)
	local b2 = (exp % 16) * 16 + floor(hi / 65536) % 16
	return char(
		b1, b2,
		floor(hi / 256) % 256, hi % 256,
		floor(lo / 16777216) % 256, floor(lo / 65536) % 256,
		floor(lo / 256) % 256, lo % 256
	)
end

-- ── encode ──────────────────────────────────────────────────────────────────

local encode_value -- forward decl

local function encode_nil()
	return "\192"
end

local function encode_bool(v)
	return v and "\195" or "\194"
end

local function encode_integer(n)
	-- positive fixint: 0..127
	if n >= 0 and n <= 127 then
		return char(n)
	end
	-- negative fixint: -32..-1
	if n >= -32 and n < 0 then
		return char(256 + n)
	end
	-- uint8
	if n >= 0 and n <= 255 then
		return char(0xcc, n)
	end
	-- uint16
	if n >= 0 and n <= 65535 then
		return char(0xcd) .. encode_uint16(n)
	end
	-- uint32
	if n >= 0 and n <= 4294967295 then
		return char(0xce) .. encode_uint32(n)
	end
	-- int8
	if n >= -128 and n <= 127 then
		return char(0xd0) .. encode_int8(n)
	end
	-- int16
	if n >= -32768 and n <= 32767 then
		return char(0xd1) .. encode_int16(n)
	end
	-- int32
	if n >= -2147483648 and n <= 2147483647 then
		return char(0xd2) .. encode_int32(n)
	end
	-- uint64 / int64: encode as float64 for now (pure Lua, no 64-bit int)
	return nil
end

local function encode_number(n)
	-- check if integer (but not -0.0, which must stay float)
	if n == floor(n) and n >= -2147483648 and n <= 4294967295
		and not (n == 0 and 1 / n < 0) then
		return encode_integer(n)
	end
	-- float64
	return char(0xcb) .. encode_double(n)
end

local function encode_string(s)
	local len = #s
	if len <= 31 then
		return char(0xa0 + len) .. s
	elseif len <= 255 then
		return char(0xd9, len) .. s
	elseif len <= 65535 then
		return char(0xda) .. encode_uint16(len) .. s
	elseif len <= 4294967295 then
		return char(0xdb) .. encode_uint32(len) .. s
	end
	return nil, "string too long"
end

local function encode_binary(s)
	local len = #s
	if len <= 255 then
		return char(0xc4, len) .. s
	elseif len <= 65535 then
		return char(0xc5) .. encode_uint16(len) .. s
	elseif len <= 4294967295 then
		return char(0xc6) .. encode_uint32(len) .. s
	end
	return nil, "binary too long"
end

local function is_array(t)
	local max = 0
	local count = 0
	for k in pairs(t) do
		if type(k) ~= "number" then return false end
		if k ~= floor(k) or k < 1 then return false end
		if k > max then max = k end
		count = count + 1
	end
	return count == max
end

local function encode_array(t)
	local len = #t
	local header
	if len <= 15 then
		header = char(0x90 + len)
	elseif len <= 65535 then
		header = char(0xdc) .. encode_uint16(len)
	else
		header = char(0xdd) .. encode_uint32(len)
	end
	local parts = { header }
	for i = 1, len do
		local v, err = encode_value(t[i])
		if not v then return nil, err end
		parts[#parts + 1] = v
	end
	return concat(parts)
end

local function encode_map(t)
	local count = 0
	for _ in pairs(t) do count = count + 1 end
	local header
	if count <= 15 then
		header = char(0x80 + count)
	elseif count <= 65535 then
		header = char(0xde) .. encode_uint16(count)
	else
		header = char(0xdf) .. encode_uint32(count)
	end
	local parts = { header }
	for k, v in pairs(t) do
		local ek, err = encode_value(k)
		if not ek then return nil, err end
		local ev
		ev, err = encode_value(v)
		if not ev then return nil, err end
		parts[#parts + 1] = ek
		parts[#parts + 1] = ev
	end
	return concat(parts)
end

encode_value = function(v)
	if v == nil then
		return encode_nil()
	end
	local tv = type(v)
	if tv == "boolean" then
		return encode_bool(v)
	elseif tv == "number" then
		return encode_number(v)
	elseif tv == "string" then
		return encode_string(v)
	elseif tv == "table" then
		if getmetatable(v) == bin_mt then
			return encode_binary(v.data)
		end
		if is_array(v) then
			return encode_array(v)
		end
		return encode_map(v)
	end
	return nil, "unsupported type: " .. tv
end

-- ── decode ──────────────────────────────────────────────────────────────────

--: (string, integer) -> (integer | nil, integer)
local function decode_uint8(s, pos)
	return byte(s, pos), pos + 1
end

local function decode_uint16(s, pos)
	local b1, b2 = byte(s, pos, pos + 1)
	return b1 * 256 + b2, pos + 2
end

local function decode_uint32(s, pos)
	local b1, b2, b3, b4 = byte(s, pos, pos + 3)
	return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4, pos + 4
end

local function decode_int8(s, pos)
	local n = byte(s, pos)
	if n >= 128 then n = n - 256 end
	return n, pos + 1
end

local function decode_int16(s, pos)
	local b1, b2 = byte(s, pos, pos + 1)
	local n = b1 * 256 + b2
	if n >= 32768 then n = n - 65536 end
	return n, pos + 2
end

local function decode_int32(s, pos)
	local b1, b2, b3, b4 = byte(s, pos, pos + 3)
	local n = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
	if n >= 2147483648 then n = n - 4294967296 end
	return n, pos + 4
end

local function decode_uint64(s, pos)
	-- decode as two uint32 halves, combine as double
	local hi = decode_uint32(s, pos)
	local lo = decode_uint32(s, pos + 4)
	return hi * 4294967296 + lo, pos + 8
end

local function decode_int64(s, pos)
	local hi = decode_uint32(s, pos)
	local lo = decode_uint32(s, pos + 4)
	local n = hi * 4294967296 + lo
	-- if sign bit set
	if hi >= 2147483648 then
		n = n - 18446744073709551616 -- 2^64
	end
	return n, pos + 8
end

local function decode_float32(s, pos)
	local b1, b2, b3, b4 = byte(s, pos, pos + 3)
	local sign = 1
	if b1 >= 128 then sign = -1; b1 = b1 - 128 end
	local exp = b1 * 2 + floor(b2 / 128)
	local mant = (b2 % 128) * 65536 + b3 * 256 + b4
	if exp == 0 then
		if mant == 0 then return sign * 0, pos + 4 end
		-- subnormal
		return sign * mant * 2^(-149), pos + 4
	elseif exp == 255 then
		if mant == 0 then return sign * huge, pos + 4 end
		return 0/0, pos + 4
	end
	return sign * (1 + mant / 8388608) * 2^(exp - 127), pos + 4
end

local function decode_float64(s, pos)
	local b1, b2, b3, b4, b5, b6, b7, b8 = byte(s, pos, pos + 7)
	local sign = 1
	if b1 >= 128 then sign = -1; b1 = b1 - 128 end
	local exp = b1 * 16 + floor(b2 / 16)
	local hi = (b2 % 16) * 65536 + b3 * 256 + b4
	local lo = b5 * 16777216 + b6 * 65536 + b7 * 256 + b8
	local mant = hi * 4294967296 + lo
	if exp == 0 then
		if mant == 0 then return sign * 0, pos + 8 end
		-- subnormal
		return sign * mant * 2^(-1074), pos + 8
	elseif exp == 2047 then
		if mant == 0 then return sign * huge, pos + 8 end
		return 0/0, pos + 8
	end
	return sign * (1 + mant / 4503599627370496) * 2^(exp - 1023), pos + 8
end

local decode_one -- forward decl

decode_one = function(s, pos)
	if pos > #s then
		return nil, "unexpected end of input"
	end
	local b = byte(s, pos)

	-- positive fixint: 0x00..0x7f
	if b <= 0x7f then
		return b, pos + 1
	end

	-- fixmap: 0x80..0x8f
	if b >= 0x80 and b <= 0x8f then
		local count = b - 0x80
		local t = {}
		pos = pos + 1
		for _ = 1, count do
			local k, err
			k, pos, err = decode_one(s, pos)
			if err then return nil, err end
			local v
			v, pos, err = decode_one(s, pos)
			if err then return nil, err end
			t[k] = v
		end
		return t, pos
	end

	-- fixarray: 0x90..0x9f
	if b >= 0x90 and b <= 0x9f then
		local count = b - 0x90
		local t = {}
		pos = pos + 1
		for i = 1, count do
			local v, err
			v, pos, err = decode_one(s, pos)
			if err then return nil, err end
			t[i] = v
		end
		return t, pos
	end

	-- fixstr: 0xa0..0xbf
	if b >= 0xa0 and b <= 0xbf then
		local len = b - 0xa0
		return sub(s, pos + 1, pos + len), pos + 1 + len
	end

	-- nil
	if b == 0xc0 then return nil, pos + 1 end

	-- (never used): 0xc1
	if b == 0xc1 then return nil, "reserved byte 0xc1" end

	-- false
	if b == 0xc2 then return false, pos + 1 end

	-- true
	if b == 0xc3 then return true, pos + 1 end

	-- bin8
	if b == 0xc4 then
		local len = byte(s, pos + 1)
		return sub(s, pos + 2, pos + 1 + len), pos + 2 + len
	end

	-- bin16
	if b == 0xc5 then
		local len = decode_uint16(s, pos + 1)
		return sub(s, pos + 3, pos + 2 + len), pos + 3 + len
	end

	-- bin32
	if b == 0xc6 then
		local len = decode_uint32(s, pos + 1)
		return sub(s, pos + 5, pos + 4 + len), pos + 5 + len
	end

	-- float32
	if b == 0xca then
		return decode_float32(s, pos + 1)
	end

	-- float64
	if b == 0xcb then
		return decode_float64(s, pos + 1)
	end

	-- uint8
	if b == 0xcc then return decode_uint8(s, pos + 1) end

	-- uint16
	if b == 0xcd then return decode_uint16(s, pos + 1) end

	-- uint32
	if b == 0xce then return decode_uint32(s, pos + 1) end

	-- uint64
	if b == 0xcf then return decode_uint64(s, pos + 1) end

	-- int8
	if b == 0xd0 then return decode_int8(s, pos + 1) end

	-- int16
	if b == 0xd1 then return decode_int16(s, pos + 1) end

	-- int32
	if b == 0xd2 then return decode_int32(s, pos + 1) end

	-- int64
	if b == 0xd3 then return decode_int64(s, pos + 1) end

	-- str8
	if b == 0xd9 then
		local len = byte(s, pos + 1)
		return sub(s, pos + 2, pos + 1 + len), pos + 2 + len
	end

	-- str16
	if b == 0xda then
		local len = decode_uint16(s, pos + 1)
		return sub(s, pos + 3, pos + 2 + len), pos + 3 + len
	end

	-- str32
	if b == 0xdb then
		local len = decode_uint32(s, pos + 1)
		return sub(s, pos + 5, pos + 4 + len), pos + 5 + len
	end

	-- array16
	if b == 0xdc then
		local count = decode_uint16(s, pos + 1)
		pos = pos + 3
		local t = {}
		for i = 1, count do
			local v, err
			v, pos, err = decode_one(s, pos)
			if err then return nil, err end
			t[i] = v
		end
		return t, pos
	end

	-- array32
	if b == 0xdd then
		local count = decode_uint32(s, pos + 1)
		pos = pos + 5
		local t = {}
		for i = 1, count do
			local v, err
			v, pos, err = decode_one(s, pos)
			if err then return nil, err end
			t[i] = v
		end
		return t, pos
	end

	-- map16
	if b == 0xde then
		local count = decode_uint16(s, pos + 1)
		pos = pos + 3
		local t = {}
		for _ = 1, count do
			local k, err
			k, pos, err = decode_one(s, pos)
			if err then return nil, err end
			local v
			v, pos, err = decode_one(s, pos)
			if err then return nil, err end
			t[k] = v
		end
		return t, pos
	end

	-- map32
	if b == 0xdf then
		local count = decode_uint32(s, pos + 1)
		pos = pos + 5
		local t = {}
		for _ = 1, count do
			local k, err
			k, pos, err = decode_one(s, pos)
			if err then return nil, err end
			local v
			v, pos, err = decode_one(s, pos)
			if err then return nil, err end
			t[k] = v
		end
		return t, pos
	end

	-- negative fixint: 0xe0..0xff
	if b >= 0xe0 then
		return b - 256, pos + 1
	end

	return nil, "unknown msgpack byte: " .. b
end

-- ── public API ──────────────────────────────────────────────────────────────

--: (v: unknown) -> string | (nil, string)
function M.value_to_string(v)
	return encode_value(v)
end

--: (s: string) -> unknown | (nil, string)
function M.string_to_value(s)
	if type(s) ~= "string" or #s == 0 then
		return nil, "expected non-empty string"
	end
	local val, pos_or_err = decode_one(s, 1)
	-- decode_one returns (nil, errmsg) on error, (val, pos) on success
	-- but val can legitimately be nil (msgpack nil), so check pos type
	if type(pos_or_err) == "string" then
		return nil, pos_or_err
	end
	return val, pos_or_err
end

M.encode = M.value_to_string
M.decode = M.string_to_value

return M
