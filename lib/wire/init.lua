-- lib/wire: binary protocol framing — length-prefixed message framing
-- Reader/writer for structured binary data: varints, fixed-width integers,
-- strings, bytes, and length-prefixed message framing.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "ffi"

local byte   = string.byte
local char   = string.char
local sub    = string.sub
local band   = bit.band
local bor    = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift

-- FFI unions for float/double <-> bytes conversion (LuaJIT only; no string.pack)
local ffi = require("ffi")
ffi.cdef [[
  typedef union { float    f; uint8_t b[4]; } wire_f32u;
  typedef union { double   d; uint8_t b[8]; } wire_f64u;
]]
local _f32u = ffi.new("wire_f32u")
local _f64u = ffi.new("wire_f64u")

-- ---------------------------------------------------------------------------
-- Writer
-- ---------------------------------------------------------------------------

local Writer = {}
Writer.__index = Writer

function M.writer()
	return setmetatable({ _buf = {}, _len = 0 }, Writer)
end

function Writer:len()
	return self._len
end

function Writer:reset()
	self._buf = {}
	self._len = 0
end

function Writer:build()
	return table.concat(self._buf)
end

local function w_byte(self, b)
	self._buf[#self._buf + 1] = char(b)
	self._len = self._len + 1
end

local function w_raw(self, s)
	self._buf[#self._buf + 1] = s
	self._len = self._len + #s
end

function Writer:uint8(n)
	w_byte(self, band(n, 0xff))
end

function Writer:uint16_le(n)
	w_byte(self, band(n, 0xff))
	w_byte(self, band(rshift(n, 8), 0xff))
end

function Writer:uint16_be(n)
	w_byte(self, band(rshift(n, 8), 0xff))
	w_byte(self, band(n, 0xff))
end

function Writer:uint32_le(n)
	w_byte(self, band(n,          0xff))
	w_byte(self, band(rshift(n,  8), 0xff))
	w_byte(self, band(rshift(n, 16), 0xff))
	w_byte(self, band(rshift(n, 24), 0xff))
end

function Writer:uint32_be(n)
	w_byte(self, band(rshift(n, 24), 0xff))
	w_byte(self, band(rshift(n, 16), 0xff))
	w_byte(self, band(rshift(n,  8), 0xff))
	w_byte(self, band(n,             0xff))
end

function Writer:int8(n)
	self:uint8(band(n, 0xff))
end

function Writer:int16_le(n)
	self:uint16_le(band(n, 0xffff))
end

function Writer:int16_be(n)
	self:uint16_be(band(n, 0xffff))
end

function Writer:int32_le(n)
	-- Use tobit to handle negative numbers correctly with bit ops
	self:uint32_le(band(n, 0xffffffff))
end

function Writer:int32_be(n)
	self:uint32_be(band(n, 0xffffffff))
end

function Writer:float_le(n)
	_f32u.f = n
	w_byte(self, _f32u.b[0]); w_byte(self, _f32u.b[1])
	w_byte(self, _f32u.b[2]); w_byte(self, _f32u.b[3])
end

function Writer:float_be(n)
	_f32u.f = n
	w_byte(self, _f32u.b[3]); w_byte(self, _f32u.b[2])
	w_byte(self, _f32u.b[1]); w_byte(self, _f32u.b[0])
end

function Writer:double_le(n)
	_f64u.d = n
	w_byte(self, _f64u.b[0]); w_byte(self, _f64u.b[1])
	w_byte(self, _f64u.b[2]); w_byte(self, _f64u.b[3])
	w_byte(self, _f64u.b[4]); w_byte(self, _f64u.b[5])
	w_byte(self, _f64u.b[6]); w_byte(self, _f64u.b[7])
end

function Writer:double_be(n)
	_f64u.d = n
	w_byte(self, _f64u.b[7]); w_byte(self, _f64u.b[6])
	w_byte(self, _f64u.b[5]); w_byte(self, _f64u.b[4])
	w_byte(self, _f64u.b[3]); w_byte(self, _f64u.b[2])
	w_byte(self, _f64u.b[1]); w_byte(self, _f64u.b[0])
end

function Writer:varint(n)
	-- LEB128 unsigned
	repeat
		local b = band(n, 0x7f)
		n = rshift(n, 7)
		if n ~= 0 then b = bor(b, 0x80) end
		w_byte(self, b)
	until n == 0
end

function Writer:varint_signed(n)
	-- zigzag encode then LEB128 unsigned
	local zz
	if n >= 0 then
		zz = n * 2
	else
		zz = (-n - 1) * 2 + 1
	end
	self:varint(zz)
end

function Writer:bytes(s)
	w_raw(self, s)
end

function Writer:bytes_n(s, n)
	if #s >= n then
		w_raw(self, sub(s, 1, n))
	else
		w_raw(self, s)
		for _ = 1, n - #s do w_byte(self, 0) end
	end
end

function Writer:str8(s)
	self:uint8(#s)
	w_raw(self, s)
end

function Writer:str16(s)
	self:uint16_le(#s)
	w_raw(self, s)
end

function Writer:str32(s)
	self:uint32_le(#s)
	w_raw(self, s)
end

function Writer:str_varint(s)
	self:varint(#s)
	w_raw(self, s)
end

-- ---------------------------------------------------------------------------
-- Reader
-- ---------------------------------------------------------------------------

local Reader = {}
Reader.__index = Reader

function M.reader(data)
	return setmetatable({ _data = data, _pos = 1 }, Reader)
end

function Reader:pos()
	return self._pos
end

function Reader:remaining()
	return #self._data - self._pos + 1
end

function Reader:at_end()
	return self._pos > #self._data
end

function Reader:seek(pos)
	self._pos = pos
end

function Reader:peek(n)
	local e = self._pos + n - 1
	if e > #self._data then
		return nil, "unexpected end of data"
	end
	return sub(self._data, self._pos, e)
end

function Reader:skip(n)
	if self._pos + n - 1 > #self._data then
		return nil, "unexpected end of data"
	end
	self._pos = self._pos + n
	return true
end

function Reader:bytes(n)
	local s, err = self:peek(n)
	if not s then return nil, err end
	self._pos = self._pos + n
	return s
end

function Reader:uint8()
	if self._pos > #self._data then
		return nil, "unexpected end of data"
	end
	local b = byte(self._data, self._pos)
	self._pos = self._pos + 1
	return b
end

function Reader:uint16_le()
	local s, err = self:bytes(2)
	if not s then return nil, err end
	local b0, b1 = byte(s, 1, 2)
	return bor(b0, lshift(b1, 8))
end

function Reader:uint16_be()
	local s, err = self:bytes(2)
	if not s then return nil, err end
	local b0, b1 = byte(s, 1, 2)
	return bor(lshift(b0, 8), b1)
end

function Reader:uint32_le()
	local s, err = self:bytes(4)
	if not s then return nil, err end
	local b0, b1, b2, b3 = byte(s, 1, 4)
	-- use bit.bor to avoid sign issues; cast to number
	local v = bor(bor(b0, lshift(b1, 8)), bor(lshift(b2, 16), lshift(b3, 24)))
	-- bor on LuaJIT returns signed int32; convert to unsigned lua number
	if v < 0 then v = v + 4294967296 end
	return v
end

function Reader:uint32_be()
	local s, err = self:bytes(4)
	if not s then return nil, err end
	local b0, b1, b2, b3 = byte(s, 1, 4)
	local v = bor(bor(lshift(b0, 24), lshift(b1, 16)), bor(lshift(b2, 8), b3))
	if v < 0 then v = v + 4294967296 end
	return v
end

function Reader:int8()
	local v, err = self:uint8()
	if not v then return nil, err end
	return (v >= 0x80) and (v - 0x100) or v
end

function Reader:int16_le()
	local v, err = self:uint16_le()
	if not v then return nil, err end
	return (v >= 0x8000) and (v - 0x10000) or v
end

function Reader:int16_be()
	local v, err = self:uint16_be()
	if not v then return nil, err end
	return (v >= 0x8000) and (v - 0x10000) or v
end

function Reader:int32_le()
	local v, err = self:uint32_le()
	if not v then return nil, err end
	-- v is unsigned 0..4294967295; sign-extend
	if v >= 0x80000000 then return v - 4294967296 end
	return v
end

function Reader:int32_be()
	local v, err = self:uint32_be()
	if not v then return nil, err end
	if v >= 0x80000000 then return v - 4294967296 end
	return v
end

function Reader:float_le()
	local s, err = self:bytes(4)
	if not s then return nil, err end
	_f32u.b[0] = byte(s,1); _f32u.b[1] = byte(s,2)
	_f32u.b[2] = byte(s,3); _f32u.b[3] = byte(s,4)
	return _f32u.f
end

function Reader:float_be()
	local s, err = self:bytes(4)
	if not s then return nil, err end
	_f32u.b[3] = byte(s,1); _f32u.b[2] = byte(s,2)
	_f32u.b[1] = byte(s,3); _f32u.b[0] = byte(s,4)
	return _f32u.f
end

function Reader:double_le()
	local s, err = self:bytes(8)
	if not s then return nil, err end
	_f64u.b[0] = byte(s,1); _f64u.b[1] = byte(s,2)
	_f64u.b[2] = byte(s,3); _f64u.b[3] = byte(s,4)
	_f64u.b[4] = byte(s,5); _f64u.b[5] = byte(s,6)
	_f64u.b[6] = byte(s,7); _f64u.b[7] = byte(s,8)
	return _f64u.d
end

function Reader:double_be()
	local s, err = self:bytes(8)
	if not s then return nil, err end
	_f64u.b[7] = byte(s,1); _f64u.b[6] = byte(s,2)
	_f64u.b[5] = byte(s,3); _f64u.b[4] = byte(s,4)
	_f64u.b[3] = byte(s,5); _f64u.b[2] = byte(s,6)
	_f64u.b[1] = byte(s,7); _f64u.b[0] = byte(s,8)
	return _f64u.d
end

function Reader:varint()
	-- LEB128 unsigned
	local result = 0
	local shift  = 0
	while true do
		if self._pos > #self._data then
			return nil, "unexpected end of data"
		end
		local b = byte(self._data, self._pos)
		self._pos = self._pos + 1
		result = bor(result, lshift(band(b, 0x7f), shift))
		if band(b, 0x80) == 0 then break end
		shift = shift + 7
	end
	-- result may be negative if bit 31 set; convert to unsigned
	if result < 0 then result = result + 4294967296 end
	return result
end

function Reader:varint_signed()
	local zz, err = self:varint()
	if not zz then return nil, err end
	-- zigzag decode
	if band(zz, 1) == 0 then
		return rshift(zz, 1)
	else
		return -(rshift(zz, 1) + 1)
	end
end

function Reader:str8()
	local n, err = self:uint8()
	if not n then return nil, err end
	return self:bytes(n)
end

function Reader:str16()
	local n, err = self:uint16_le()
	if not n then return nil, err end
	return self:bytes(n)
end

function Reader:str32()
	local n, err = self:uint32_le()
	if not n then return nil, err end
	return self:bytes(n)
end

function Reader:str_varint()
	local n, err = self:varint()
	if not n then return nil, err end
	return self:bytes(n)
end

-- ---------------------------------------------------------------------------
-- Framing
-- ---------------------------------------------------------------------------

-- Encode a single message with a length prefix.
-- opts.prefix: "u32_be" (default) | "u32_le" | "u16_be" | "u16_le" | "varint"
function M.frame(data, opts)
	local prefix = (opts and opts.prefix) or "u32_be"
	local w = M.writer()
	if prefix == "u32_be" then
		w:uint32_be(#data)
	elseif prefix == "u32_le" then
		w:uint32_le(#data)
	elseif prefix == "u16_be" then
		w:uint16_be(#data)
	elseif prefix == "u16_le" then
		w:uint16_le(#data)
	elseif prefix == "varint" then
		w:varint(#data)
	else
		return nil, "unknown prefix type: " .. tostring(prefix)
	end
	w:bytes(data)
	return w:build()
end

-- Decode one message from data.
-- Returns payload, remaining  (remaining = bytes after this frame)
-- Returns nil, errmsg on error or incomplete data.
function M.unframe(data, opts)
	local prefix = (opts and opts.prefix) or "u32_be"
	local r = M.reader(data)
	local n, err
	if prefix == "u32_be" then
		n, err = r:uint32_be()
	elseif prefix == "u32_le" then
		n, err = r:uint32_le()
	elseif prefix == "u16_be" then
		n, err = r:uint16_be()
	elseif prefix == "u16_le" then
		n, err = r:uint16_le()
	elseif prefix == "varint" then
		n, err = r:varint()
	else
		return nil, "unknown prefix type: " .. tostring(prefix)
	end
	if not n then return nil, err end
	local payload, perr = r:bytes(n)
	if not payload then return nil, perr end
	local remaining = sub(data, r:pos())
	return payload, remaining
end

-- ---------------------------------------------------------------------------
-- Streaming unframer (for TCP streams)
-- ---------------------------------------------------------------------------

local Unframer = {}
Unframer.__index = Unframer

function M.unframer(opts)
	return setmetatable({ _buf = "", _opts = opts or {} }, Unframer)
end

function Unframer:feed(chunk)
	self._buf = self._buf .. chunk
end

-- Returns next complete message payload, or nil if not enough data yet.
-- On hard error returns nil, errmsg.
function Unframer:next()
	local prefix = self._opts.prefix or "u32_be"
	local r = M.reader(self._buf)

	-- Try to read length prefix
	local n, err
	if prefix == "u32_be" then
		n, err = r:uint32_be()
	elseif prefix == "u32_le" then
		n, err = r:uint32_le()
	elseif prefix == "u16_be" then
		n, err = r:uint16_be()
	elseif prefix == "u16_le" then
		n, err = r:uint16_le()
	elseif prefix == "varint" then
		n, err = r:varint()
	else
		return nil, "unknown prefix type: " .. tostring(prefix)
	end

	if not n then
		-- Not enough data for the length prefix yet
		return nil
	end

	-- Check if full payload is available
	if r:remaining() < n then
		return nil
	end

	local payload = sub(self._buf, r:pos(), r:pos() + n - 1)
	self._buf = sub(self._buf, r:pos() + n)
	return payload
end

return M
