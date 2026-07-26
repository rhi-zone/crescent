-- lib/y_crdt/float_ffi.lua
--
-- FFI tier for lib0-compatible float32/float64 packing (BIG-endian wire
-- format -- see lib/y_crdt/encoding.lua for why). Reinterprets hardware
-- IEEE 754 bits via a union cdef instead of assembling sign/exponent/
-- mantissa fields by hand; this is the fast tier and also the oracle
-- `float_pure.lua` is parity-tested against (see float_parity_test.lua).
--
-- Requires FFI (LuaJIT). Callers select this tier with a pcall and fall back
-- to `lib/y_crdt/float_pure.lua` when it's unavailable -- this module does
-- not fall back internally.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi = require("ffi")

local char = string.char

ffi.cdef([[
	typedef union { uint16_t u16; uint8_t b[2]; } y_crdt_float_probe16_t;
	typedef union { float f32; uint8_t b[4]; } y_crdt_float_f32_t;
	typedef union { double f64; uint8_t b[8]; } y_crdt_float_f64_t;
]])

local probe = ffi.new("y_crdt_float_probe16_t")
probe.u16 = 1
local little_endian = probe.b[0] == 1

local f32 = ffi.new("y_crdt_float_f32_t")
local f64 = ffi.new("y_crdt_float_f64_t")

local M = {}

if little_endian then
	--: (number) -> string
	M.pack_float32 = function(v)
		f32.f32 = v
		return char(f32.b[3], f32.b[2], f32.b[1], f32.b[0])
	end
	--: (integer, integer, integer, integer) -> number
	M.unpack_float32 = function(b0, b1, b2, b3)
		f32.b[3] = b0; f32.b[2] = b1; f32.b[1] = b2; f32.b[0] = b3
		return f32.f32
	end
	--: (number) -> string
	M.pack_float64 = function(v)
		f64.f64 = v
		return char(f64.b[7], f64.b[6], f64.b[5], f64.b[4], f64.b[3], f64.b[2], f64.b[1], f64.b[0])
	end
	--: (integer, integer, integer, integer, integer, integer, integer, integer) -> number
	M.unpack_float64 = function(b0, b1, b2, b3, b4, b5, b6, b7)
		f64.b[7] = b0; f64.b[6] = b1; f64.b[5] = b2; f64.b[4] = b3
		f64.b[3] = b4; f64.b[2] = b5; f64.b[1] = b6; f64.b[0] = b7
		return f64.f64
	end
else
	--: (number) -> string
	M.pack_float32 = function(v)
		f32.f32 = v
		return char(f32.b[0], f32.b[1], f32.b[2], f32.b[3])
	end
	--: (integer, integer, integer, integer) -> number
	M.unpack_float32 = function(b0, b1, b2, b3)
		f32.b[0] = b0; f32.b[1] = b1; f32.b[2] = b2; f32.b[3] = b3
		return f32.f32
	end
	--: (number) -> string
	M.pack_float64 = function(v)
		f64.f64 = v
		return char(f64.b[0], f64.b[1], f64.b[2], f64.b[3], f64.b[4], f64.b[5], f64.b[6], f64.b[7])
	end
	--: (integer, integer, integer, integer, integer, integer, integer, integer) -> number
	M.unpack_float64 = function(b0, b1, b2, b3, b4, b5, b6, b7)
		f64.b[0] = b0; f64.b[1] = b1; f64.b[2] = b2; f64.b[3] = b3
		f64.b[4] = b4; f64.b[5] = b5; f64.b[6] = b6; f64.b[7] = b7
		return f64.f64
	end
end

return M
