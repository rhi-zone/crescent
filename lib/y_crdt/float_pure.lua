-- lib/y_crdt/float_pure.lua
--
-- Pure Lua tier for lib0-compatible float32/float64 packing (BIG-endian wire
-- format -- see lib/y_crdt/encoding.lua for why). No FFI, no LuaJIT `bit`
-- library: assembles IEEE 754 sign/exponent/mantissa fields with
-- math.frexp/math.floor arithmetic only, so this is the correctness
-- reference the `float_ffi.lua` tier is parity-tested against (see
-- float_parity_test.lua) and the fallback used when FFI is unavailable.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local floor = math.floor
local huge = math.huge
local frexp = math.frexp
local char = string.char

-- Round nonnegative `x` to the nearest integer, ties to even -- matches
-- IEEE 754 default (round-to-nearest-even) rounding so this tier stays
-- byte-for-byte compatible with the ffi tier's hardware rounding.
--: (number) -> number
local function round_nearest_even(x)
	local fl = floor(x)
	local diff = x - fl
	if diff < 0.5 then
		return fl
	elseif diff > 0.5 then
		return fl + 1
	elseif fl % 2 == 0 then
		return fl
	else
		return fl + 1
	end
end

local M = {}

--: (number) -> string
M.pack_float32 = function(v)
	local sign = 0
	if v < 0 or (v == 0 and 1 / v < 0) then
		sign = 1
		v = -v
	end
	local exp, mant
	if v ~= v then
		exp, mant = 255, 1
	elseif v == huge then
		exp, mant = 255, 0
	elseif v == 0 then
		exp, mant = 0, 0
	else
		local m, e = frexp(v) -- v == m * 2^e, 0.5 <= m < 1
		local fexp = e - 1 + 127
		if fexp >= 255 then
			exp, mant = 255, 0
		elseif fexp <= 0 then
			mant = round_nearest_even(m * 2 ^ (e + 149))
			exp = 0
			if mant >= 8388608 then -- 2^23: rounded up into smallest normal
				exp, mant = 1, 0
			end
		else
			mant = round_nearest_even((m * 2 - 1) * 8388608)
			exp = fexp
			if mant >= 8388608 then
				mant = 0
				exp = exp + 1
				if exp >= 255 then exp = 255 end
			end
		end
	end
	local b0 = sign * 128 + floor(exp / 2)
	local mant_hi7 = floor(mant / 65536)
	local b1 = (exp % 2) * 128 + mant_hi7
	local mant_lo16 = mant % 65536
	local b2 = floor(mant_lo16 / 256)
	local b3 = mant_lo16 % 256
	return char(b0, b1, b2, b3)
end

--: (number, number, number, number) -> number
M.unpack_float32 = function(b0, b1, b2, b3)
	local sign = floor(b0 / 128)
	local exp = (b0 % 128) * 2 + floor(b1 / 128)
	local mant = (b1 % 128) * 65536 + b2 * 256 + b3
	local v
	if exp == 255 then
		v = (mant == 0) and huge or (0 / 0)
	elseif exp == 0 then
		v = (mant == 0) and 0 or (mant * 2 ^ -149)
	else
		v = (1 + mant / 8388608) * 2 ^ (exp - 127)
	end
	if sign == 1 then v = -v end
	return v
end

--: (number) -> string
M.pack_float64 = function(v)
	local sign = 0
	if v < 0 or (v == 0 and 1 / v < 0) then
		sign = 1
		v = -v
	end
	local exp, mant
	if v ~= v then
		exp, mant = 2047, 1
	elseif v == huge then
		exp, mant = 2047, 0
	elseif v == 0 then
		exp, mant = 0, 0
	else
		local m, e = frexp(v)
		local fexp = e - 1 + 1023
		if fexp >= 2047 then
			exp, mant = 2047, 0
		elseif fexp <= 0 then
			mant = round_nearest_even(m * 2 ^ (e + 1074))
			exp = 0
			if mant >= 4503599627370496 then -- 2^52
				exp, mant = 1, 0
			end
		else
			mant = round_nearest_even((m * 2 - 1) * 4503599627370496)
			exp = fexp
			if mant >= 4503599627370496 then
				mant = 0
				exp = exp + 1
				if exp >= 2047 then exp = 2047 end
			end
		end
	end
	local b0 = sign * 128 + floor(exp / 16)
	local mant_hi4 = floor(mant / 281474976710656) -- mant >> 48
	local b1 = (exp % 16) * 16 + mant_hi4
	local rest = mant % 281474976710656 -- low 48 bits
	local b2 = floor(rest / 1099511627776); rest = rest % 1099511627776
	local b3 = floor(rest / 4294967296); rest = rest % 4294967296
	local b4 = floor(rest / 16777216); rest = rest % 16777216
	local b5 = floor(rest / 65536); rest = rest % 65536
	local b6 = floor(rest / 256)
	local b7 = rest % 256
	return char(b0, b1, b2, b3, b4, b5, b6, b7)
end

--: (number, number, number, number, number, number, number, number) -> number
M.unpack_float64 = function(b0, b1, b2, b3, b4, b5, b6, b7)
	local sign = floor(b0 / 128)
	local exp = (b0 % 128) * 16 + floor(b1 / 16)
	local mant = (b1 % 16) * 281474976710656
		+ b2 * 1099511627776
		+ b3 * 4294967296
		+ b4 * 16777216
		+ b5 * 65536
		+ b6 * 256
		+ b7
	local v
	if exp == 2047 then
		v = (mant == 0) and huge or (0 / 0)
	elseif exp == 0 then
		v = (mant == 0) and 0 or (mant * 2 ^ -1074)
	else
		v = (1 + mant / 4503599627370496) * 2 ^ (exp - 1023)
	end
	if sign == 1 then v = -v end
	return v
end

return M
