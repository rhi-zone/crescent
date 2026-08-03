-- lib/y_crdt/encoding.lua
--
-- lib0-compatible binary encoding/decoding primitives for the yjs wire
-- format. Verified byte-for-byte against upstream dmonad/lib0
-- (src/encoding.js, src/decoding.js, src/binary.js, fetched 2026-07-26).
--
-- Byte layout (all verified against upstream source, not derived from memory):
--   varUint:  LEB128. 7 payload bits per byte, continuation in bit 0x80.
--   varInt:   first byte holds 6 magnitude bits (bit 0x40 = sign, bit 0x80 =
--             continuation); subsequent bytes are standard 7-bit LEB128.
--   uint16/uint32: little-endian, byte-by-byte.
--   float32/float64: IEEE 754, BIG-endian (lib0's DataView.setFloat32/64 is
--             called with littleEndian=false). This is a real asymmetry
--             against the little-endian fixed-width integers above -- it
--             exists in upstream lib0 itself, not introduced here.
--   varString / varBuffer: varUint length prefix + raw bytes (UTF-8 for
--             strings; lib0 does not validate UTF-8 on encode or decode, and
--             neither do we).
--   writeAny: tagged union. Tags run 116-127, DESCENDING (127=undefined down
--             to 116=Uint8Array). Tags 0-115 are reserved by lib0 for
--             consumer-defined extensions on top of writeAny and are not
--             interpreted here. See the table below `write_any`.
--
-- Error convention (docs/conventions.md): decode functions operate on
-- untrusted wire bytes, so malformed/truncated input is a *data* error and
-- returns (nil, errmsg) -- it never throws. Encode functions that receive a
-- wrong-typed/out-of-range Lua argument throw (programming error), except
-- `write_any`, which walks caller-supplied structural data and returns
-- (nil, errmsg) for values it cannot represent on the wire (e.g. a map key
-- that isn't a string).
--
-- Tiering: fixed-width uint16/uint32 packing is plain arithmetic in every
-- tier (LE byte extraction via floor/mod has no meaningfully faster
-- alternative worth the complexity, so it is not tiered). float32/float64
-- packing IS tiered: an `ffi` tier reinterprets hardware IEEE 754 bits
-- (fast, and the correctness oracle used to parity-test the pure tier); a
-- `pure` tier assembles the sign/exponent/mantissa fields by hand via
-- math.frexp/math.ldexp so the library still works without FFI.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local null = require("lib.null")

local M = {}

local floor = math.floor
local huge = math.huge
local char = string.char
local byte = string.byte
local sub = string.sub
local concat = table.concat
local type = type
local error = error
local pairs = pairs
local setmetatable = setmetatable
local tostring = tostring

-- Sentinel for the wire "null" value (tag 126). Lua `nil` itself represents
-- wire "undefined" (tag 127) -- see docs/conventions.md "Null sentinels".
-- Shared across libraries (lib/null) so null values compare equal regardless
-- of which library produced them.
M.null = null.null

local MAX_SAFE_INTEGER = 9007199254740991 -- 2^53 - 1

-- TYPECHECKER WORKAROUND: calling string.byte's overloaded
-- `(string, integer, integer) -> ...integer` candidate (or destructuring /
-- spreading its multi-value result) from inside any function carrying a
-- `--:` signature annotation is resolved incorrectly by the typechecker --
-- only the first value survives typing and the rest silently become
-- `nil`/`never`, breaking arithmetic and argument-spread on the remaining
-- results. Repro: `--: () -> integer\nlocal function f() local a, b =
-- string.byte(s, 1, 2); return a + b end` fails to typecheck; the exact same
-- multi-byte read compiles fine with no annotation on `f`, or wrapped through
-- a helper carrying its own explicit non-overloaded signature (as below).
-- The natural code would call `string.byte(self.data, self.pos, self.pos +
-- n - 1)` once per multi-byte read and destructure N results; instead every
-- single-byte read here goes through this helper and multi-byte reads call
-- it N times. TODO.md has an entry to revert to direct multi-byte
-- `string.byte` destructuring once the typechecker gap is fixed.
--: (string, integer) -> (integer | nil)
local function byte_at(s, i)
	return byte(s, i)
end

--[[::
EncoderState = {
  chunks: { [integer]: string }, n: integer,
  write_uint8: (EncoderState, integer) -> nil,
  write_uint16: (EncoderState, integer) -> nil,
  write_uint32: (EncoderState, integer) -> nil,
  write_float32: (EncoderState, number) -> nil,
  write_float64: (EncoderState, number) -> nil,
  write_var_uint: (EncoderState, integer) -> nil,
  write_var_int: (EncoderState, integer) -> nil,
  write_var_string: (EncoderState, string) -> nil,
  write_var_uint8_array: (EncoderState, string) -> nil,
  write_var_buffer: (EncoderState, string) -> nil,
  write_any: (EncoderState, unknown) -> (true | nil, string | nil),
  to_string: (EncoderState) -> string,
  length: (EncoderState) -> integer,
  ...
}
]]

--[[::
DecoderState = {
  data: string, pos: integer, len: integer,
  has_content: (DecoderState) -> boolean,
  remaining: (DecoderState) -> integer,
  read_uint8: (DecoderState) -> (integer | nil, string | nil),
  read_uint16: (DecoderState) -> (integer | nil, string | nil),
  read_uint32: (DecoderState) -> (integer | nil, string | nil),
  read_float32: (DecoderState) -> (number | nil, string | nil),
  read_float64: (DecoderState) -> (number | nil, string | nil),
  read_var_uint: (DecoderState) -> (integer | nil, string | nil),
  read_var_int: (DecoderState) -> (integer | nil, string | nil),
  read_var_uint8_array: (DecoderState) -> (string | nil, string | nil),
  read_var_buffer: (DecoderState) -> (string | nil, string | nil),
  read_var_string: (DecoderState) -> (string | nil, string | nil),
  read_any: (DecoderState) -> (unknown, string | nil),
  ...
}
]]

--------------------------------------------------------------------------
-- float32 / float64 packing: tiered (ffi > pure), selected at load time.
-- Each tier is a real, independent implementation living in its own file
-- (lib/y_crdt/float_ffi.lua, lib/y_crdt/float_pure.lua) per
-- docs/conventions.md "Module structure" -- this also lets both be required
-- directly, regardless of which one loads here, for parity testing
-- (float_parity_test.lua).
--------------------------------------------------------------------------

--: string
M._tier = "pure"

-- Assigned unconditionally by exactly one branch below; left unannotated so
-- the typechecker doesn't require a same-line initializer (annotated in
-- float_ffi.lua / float_pure.lua instead, where they're actually defined).
local pack_float32
local unpack_float32
local pack_float64
local unpack_float64

do
	local ffi_ok, ffi_float = pcall(require, "lib.y_crdt.float_ffi")
	if ffi_ok then
		M._tier = "ffi"
		pack_float32 = ffi_float.pack_float32
		unpack_float32 = ffi_float.unpack_float32
		pack_float64 = ffi_float.pack_float64
		unpack_float64 = ffi_float.unpack_float64
	else
		local pure_float = require("lib.y_crdt.float_pure")
		pack_float32 = pure_float.pack_float32
		unpack_float32 = pure_float.unpack_float32
		pack_float64 = pure_float.pack_float64
		unpack_float64 = pure_float.unpack_float64
	end
end

--------------------------------------------------------------------------
-- Encoder
--------------------------------------------------------------------------

local Encoder = {}
Encoder.__index = Encoder

--: () -> EncoderState
M.encoder = function()
	local obj = { chunks = {}, n = 0 }
	return setmetatable(obj, Encoder) --[[: EncoderState]]
end

--: (EncoderState, string) -> nil
local function push(enc, s)
	local n = enc.n + 1
	enc.chunks[n] = s
	enc.n = n
end

--: (EncoderState, integer) -> nil
function Encoder:write_uint8(num)
	if type(num) ~= "number" or num % 1 ~= 0 or num < 0 or num > 255 then
		error("encoding: write_uint8 expects an integer in [0, 255], got " .. tostring(num), 2)
	end
	push(self, char(num))
end

--: (EncoderState, integer) -> nil
function Encoder:write_uint16(num)
	if type(num) ~= "number" or num % 1 ~= 0 or num < 0 or num > 65535 then
		error("encoding: write_uint16 expects an integer in [0, 65535], got " .. tostring(num), 2)
	end
	local b0 = num % 256
	local b1 = floor(num / 256) % 256
	push(self, char(b0, b1))
end

--: (EncoderState, integer) -> nil
function Encoder:write_uint32(num)
	if type(num) ~= "number" or num % 1 ~= 0 or num < 0 or num > 4294967295 then
		error("encoding: write_uint32 expects an integer in [0, 2^32-1], got " .. tostring(num), 2)
	end
	local b0 = num % 256; num = floor(num / 256)
	local b1 = num % 256; num = floor(num / 256)
	local b2 = num % 256; num = floor(num / 256)
	local b3 = num % 256
	push(self, char(b0, b1, b2, b3))
end

--: (EncoderState, number) -> nil
function Encoder:write_float32(num)
	if type(num) ~= "number" then
		error("encoding: write_float32 expects a number, got " .. tostring(num), 2)
	end
	push(self, pack_float32(num))
end

--: (EncoderState, number) -> nil
function Encoder:write_float64(num)
	if type(num) ~= "number" then
		error("encoding: write_float64 expects a number, got " .. tostring(num), 2)
	end
	push(self, pack_float64(num))
end

--: (EncoderState, integer) -> nil
function Encoder:write_var_uint(num)
	if type(num) ~= "number" or num % 1 ~= 0 or num < 0 then
		error("encoding: write_var_uint expects a nonnegative integer, got " .. tostring(num), 2)
	end
	while num > 127 do
		push(self, char(128 + (num % 128)))
		num = floor(num / 128)
	end
	push(self, char(num))
end

--: (EncoderState, integer) -> nil
function Encoder:write_var_int(num)
	if type(num) ~= "number" or num % 1 ~= 0 then
		error("encoding: write_var_int expects an integer, got " .. tostring(num), 2)
	end
	local is_negative = num < 0 or (num == 0 and 1 / num < 0)
	-- TYPECHECKER WORKAROUND: reassigning the `integer`-annotated parameter
	-- `num` itself (`num = 0 - num`) after the `num % 1 ~= 0` guard above
	-- makes the typechecker treat the RHS as `number` and reject the
	-- reassignment ("cannot assign number to integer"), even though
	-- `#__sub: (integer, integer) -> integer` is declared and a fresh local
	-- fed by the same expression infers `integer` correctly (repro: minimal
	-- case with `--: (integer) -> nil` + a `type(x)~="number" or x % 1 ~= 0`
	-- guard + later `x = 0 - x` fails; `local y = 0 - x` right after the same
	-- guard does not). The natural code would just reassign `num`. Using a
	-- separate local for the absolute value sidesteps the gap.
	-- TODO.md: fold `rest` back into `num` once the gap is fixed.
	local rest = is_negative and (0 - num) or num
	local first = (rest > 63 and 128 or 0) + (is_negative and 64 or 0) + (rest % 64)
	rest = floor(rest / 64)
	if rest == 0 then
		push(self, char(first))
		return
	end
	local chunks = { char(first) } --[[: { [integer]: string }]]
	local i = 1
	while rest > 0 do
		i = i + 1
		if rest > 127 then
			chunks[i] = char(128 + (rest % 128))
		else
			chunks[i] = char(rest % 128)
		end
		rest = floor(rest / 128)
	end
	push(self, concat(chunks))
end

--: (EncoderState, string) -> nil
function Encoder:write_var_string(s)
	if type(s) ~= "string" then
		error("encoding: write_var_string expects a string, got " .. tostring(s), 2)
	end
	self:write_var_uint(#s)
	if #s > 0 then push(self, s) end
end

--: (EncoderState, string) -> nil
function Encoder:write_var_uint8_array(s)
	if type(s) ~= "string" then
		error("encoding: write_var_uint8_array expects a string, got " .. tostring(s), 2)
	end
	self:write_var_uint(#s)
	if #s > 0 then push(self, s) end
end
Encoder.write_var_buffer = Encoder.write_var_uint8_array

--: (EncoderState, unknown) -> (true | nil, string | nil)
function Encoder:write_any(data)
	if type(data) == "string" then
		self:write_uint8(119)
		self:write_var_string(data)
		return true
	elseif type(data) == "number" then
		if data % 1 == 0 and data >= -2147483647 and data <= 2147483647 then
			self:write_uint8(125)
			self:write_var_int(floor(data))
		elseif data == data and data ~= huge and data ~= -huge then
			-- finite: prefer float32 when it round-trips exactly, else float64
			local f32 = pack_float32(data)
			local fb0 = byte_at(f32, 1)
			local fb1 = byte_at(f32, 2)
			local fb2 = byte_at(f32, 3)
			local fb3 = byte_at(f32, 4)
			if fb0 and fb1 and fb2 and fb3 and unpack_float32(fb0, fb1, fb2, fb3) == data then
				self:write_uint8(124)
				push(self, f32)
			else
				self:write_uint8(123)
				push(self, pack_float64(data))
			end
		else
			-- NaN or +-infinity: not exactly float32-representable in general,
			-- but NaN/Infinity round-trip through float32 fine; still prefer
			-- float64 to match lib0's isFloat32 semantics for these values.
			self:write_uint8(123)
			push(self, pack_float64(data))
		end
		return true
	elseif type(data) == "boolean" then
		self:write_uint8(data and 120 or 121)
		return true
	elseif data == nil then
		self:write_uint8(127)
		return true
	elseif data == M.null then
		self:write_uint8(126)
		return true
	elseif type(data) == "table" then
		-- `type(data) == "table"` alone narrows `data` to a table type with no
		-- usable indexer for `pairs`/`#` (see TYPECHECKER WORKAROUND below);
		-- this checked cast gives it the open, unknown-keyed shape it
		-- actually has (its keys/values are genuinely unknown here).
		local tbl = data --[[: { [unknown]: unknown, ... }]]
		local n = #tbl
		local is_array = true
		local count = 0
		-- TYPECHECKER WORKAROUND: narrowing `k` via a negated `or`-chain
		-- (`type(k) ~= "number" or k % 1 ~= 0 or ...`) does not narrow `k`
		-- for the later operands of the same `or` expression, leaving `k`
		-- typed `unknown` there and rejecting the arithmetic/comparisons
		-- (repro: `--: (unknown) -> nil` + `type(x)=="table"` + `for k in
		-- pairs(x) do if type(k) ~= "number" or k % 1 ~= 0 then` fails on the
		-- `%`; a nested `if type(k) == "number" then` with an `and`-chain
		-- inside narrows correctly). The natural code would use the `or`-
		-- chain directly; nesting the checks nested-if-style below is the
		-- workaround. TODO.md: flatten back once `or`-chain narrowing works.
		for k in pairs(tbl) do
			count = count + 1
			local k_is_index = false
			if type(k) == "number" then
				if k % 1 == 0 and k >= 1 and k <= n then
					k_is_index = true
				end
			end
			if not k_is_index then
				is_array = false
			end
		end
		if is_array and count == n then
			self:write_uint8(117)
			self:write_var_uint(n)
			for i = 1, n do
				local ok, err = self:write_any(tbl[i])
				if not ok then return nil, err end
			end
			return true
		else
			self:write_uint8(118)
			self:write_var_uint(count)
			for k, v in pairs(tbl) do
				if type(k) ~= "string" then
					return nil, "encoding: write_any cannot encode a non-string map key: " .. tostring(k)
				end
				self:write_var_string(k)
				local ok, err = self:write_any(v)
				if not ok then return nil, err end
			end
			return true
		end
	else
		-- functions, threads, userdata and anything else unidentifiable are
		-- encoded as undefined, mirroring lib0's writeAny default case.
		self:write_uint8(127)
		return true
	end
end

--: (EncoderState) -> string
function Encoder:to_string()
	return concat(self.chunks, "", 1, self.n)
end

--: (EncoderState) -> integer
function Encoder:length()
	local total = 0
	for i = 1, self.n do
		total = total + #self.chunks[i]
	end
	return total
end

--------------------------------------------------------------------------
-- Decoder
--------------------------------------------------------------------------

local Decoder = {}
Decoder.__index = Decoder

--: (string) -> DecoderState
M.decoder = function(s)
	if type(s) ~= "string" then
		error("encoding: decoder expects a string, got " .. tostring(s), 2)
	end
	local obj = { data = s, pos = 1, len = #s }
	return setmetatable(obj, Decoder) --[[: DecoderState]]
end

--: (DecoderState) -> boolean
function Decoder:has_content()
	return self.pos <= self.len
end

--: (DecoderState) -> integer
function Decoder:remaining()
	return self.len - self.pos + 1
end

--: (DecoderState, integer) -> (true | nil, string | nil)
local function need(dec, n)
	if dec.pos + n - 1 > dec.len then
		return nil, "encoding: unexpected end of buffer"
	end
	return true
end

--: (DecoderState) -> (integer | nil, string | nil)
function Decoder:read_uint8()
	local ok, err = need(self, 1)
	if not ok then return nil, err end
	local n = byte_at(self.data, self.pos)
	self.pos = self.pos + 1
	return n
end

--: (DecoderState) -> (integer | nil, string | nil)
function Decoder:read_uint16()
	local ok, err = need(self, 2)
	if not ok then return nil, err end
	local b0 = byte_at(self.data, self.pos)
	local b1 = byte_at(self.data, self.pos + 1)
	self.pos = self.pos + 2
	if not b0 or not b1 then return nil, "encoding: unexpected end of buffer" end
	return b0 + b1 * 256
end

--: (DecoderState) -> (integer | nil, string | nil)
function Decoder:read_uint32()
	local ok, err = need(self, 4)
	if not ok then return nil, err end
	local b0 = byte_at(self.data, self.pos)
	local b1 = byte_at(self.data, self.pos + 1)
	local b2 = byte_at(self.data, self.pos + 2)
	local b3 = byte_at(self.data, self.pos + 3)
	self.pos = self.pos + 4
	if not b0 or not b1 or not b2 or not b3 then return nil, "encoding: unexpected end of buffer" end
	return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
end

--: (DecoderState) -> (number | nil, string | nil)
function Decoder:read_float32()
	local ok, err = need(self, 4)
	if not ok then return nil, err end
	local b0 = byte_at(self.data, self.pos)
	local b1 = byte_at(self.data, self.pos + 1)
	local b2 = byte_at(self.data, self.pos + 2)
	local b3 = byte_at(self.data, self.pos + 3)
	self.pos = self.pos + 4
	if not b0 or not b1 or not b2 or not b3 then return nil, "encoding: unexpected end of buffer" end
	return unpack_float32(b0, b1, b2, b3)
end

--: (DecoderState) -> (number | nil, string | nil)
function Decoder:read_float64()
	local ok, err = need(self, 8)
	if not ok then return nil, err end
	local b0 = byte_at(self.data, self.pos)
	local b1 = byte_at(self.data, self.pos + 1)
	local b2 = byte_at(self.data, self.pos + 2)
	local b3 = byte_at(self.data, self.pos + 3)
	local b4 = byte_at(self.data, self.pos + 4)
	local b5 = byte_at(self.data, self.pos + 5)
	local b6 = byte_at(self.data, self.pos + 6)
	local b7 = byte_at(self.data, self.pos + 7)
	self.pos = self.pos + 8
	if not b0 or not b1 or not b2 or not b3 or not b4 or not b5 or not b6 or not b7 then
		return nil, "encoding: unexpected end of buffer"
	end
	return unpack_float64(b0, b1, b2, b3, b4, b5, b6, b7)
end

--: (DecoderState) -> (integer | nil, string | nil)
function Decoder:read_var_uint()
	local num = 0
	local mult = 1
	while true do
		local ok, err = need(self, 1)
		if not ok then return nil, "encoding: unexpected end of buffer while reading varUint" end
		local r = byte_at(self.data, self.pos)
		if not r then return nil, "encoding: unexpected end of buffer while reading varUint" end
		self.pos = self.pos + 1
		num = num + (r % 128) * mult
		mult = mult * 128
		if r < 128 then
			return num
		end
		if num > MAX_SAFE_INTEGER then
			return nil, "encoding: varUint out of safe integer range"
		end
	end
end

--: (DecoderState) -> (integer | nil, string | nil)
function Decoder:read_var_int()
	local ok, err = need(self, 1)
	if not ok then return nil, "encoding: unexpected end of buffer while reading varInt" end
	local r = byte_at(self.data, self.pos)
	if not r then return nil, "encoding: unexpected end of buffer while reading varInt" end
	self.pos = self.pos + 1
	local num = r % 64
	local mult = 64
	local sign = (floor(r / 64) % 2 == 1) and -1 or 1
	if floor(r / 128) == 0 then
		return sign * num
	end
	while true do
		local ok2 = need(self, 1)
		if not ok2 then return nil, "encoding: unexpected end of buffer while reading varInt" end
		r = byte_at(self.data, self.pos)
		if not r then return nil, "encoding: unexpected end of buffer while reading varInt" end
		self.pos = self.pos + 1
		num = num + (r % 128) * mult
		mult = mult * 128
		if r < 128 then
			return sign * num
		end
		if num > MAX_SAFE_INTEGER then
			return nil, "encoding: varInt out of safe integer range"
		end
	end
end

--: (DecoderState) -> (string | nil, string | nil)
function Decoder:read_var_uint8_array()
	local len, err = self:read_var_uint()
	if not len then return nil, err end
	local ok, err2 = need(self, len)
	if not ok then return nil, err2 end
	local s = len == 0 and "" or sub(self.data, self.pos, self.pos + len - 1)
	self.pos = self.pos + len
	return s
end
Decoder.read_var_buffer = Decoder.read_var_uint8_array

--: (DecoderState) -> (string | nil, string | nil)
function Decoder:read_var_string()
	return self:read_var_uint8_array()
end

-- Tags 127..116, in that order, mirroring lib0's readAnyLookupTable (indexed
-- by `127 - tag`).
--: (DecoderState) -> (unknown, string | nil)
function Decoder:read_any()
	local tag, err = self:read_uint8()
	if not tag then return nil, err end
	if tag == 127 then
		return nil
	elseif tag == 126 then
		return M.null
	elseif tag == 125 then
		return self:read_var_int()
	elseif tag == 124 then
		return self:read_float32()
	elseif tag == 123 then
		return self:read_float64()
	elseif tag == 122 then
		return nil, "encoding: read_any does not support bigint64 (tag 122)"
	elseif tag == 121 then
		return false
	elseif tag == 120 then
		return true
	elseif tag == 119 then
		return self:read_var_string()
	elseif tag == 118 then
		local len, err2 = self:read_var_uint()
		if not len then return nil, err2 end
		local obj = {}
		for _ = 1, len do
			local key, kerr = self:read_var_string()
			if not key then return nil, kerr end
			local val, verr = self:read_any()
			if val == nil and verr ~= nil then return nil, verr end
			obj[key] = val
		end
		return obj
	elseif tag == 117 then
		local len, err2 = self:read_var_uint()
		if not len then return nil, err2 end
		local arr = {}
		for i = 1, len do
			local val, verr = self:read_any()
			if val == nil and verr ~= nil then return nil, verr end
			arr[i] = val
		end
		return arr
	elseif tag == 116 then
		return self:read_var_uint8_array()
	else
		return nil, "encoding: read_any encountered unknown tag " .. tostring(tag)
	end
end

return M
