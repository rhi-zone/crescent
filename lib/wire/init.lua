-- lib/wire: binary protocol framing — length-prefixed message framing
-- Reader/writer for structured binary data: varints, fixed-width integers,
-- strings, bytes, and length-prefixed message framing.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "ffi"

--:: Writer = { _buf: { [integer]: string }, _len: integer, uint8: (Writer, integer) -> nil, uint16_le: (Writer, integer) -> nil, uint16_be: (Writer, integer) -> nil, uint32_le: (Writer, integer) -> nil, uint32_be: (Writer, integer) -> nil, varint: (Writer, integer) -> nil, bytes: (Writer, string) -> nil, build: (Writer) -> string, ... }
--:: Reader = { _data: string, _pos: integer, peek: (Reader, integer) -> (string | nil, string | nil), bytes: (Reader, integer) -> (string | nil, string | nil), uint8: (Reader) -> (integer | nil, string | nil), uint16_le: (Reader) -> (integer | nil, string | nil), uint16_be: (Reader) -> (integer | nil, string | nil), uint32_le: (Reader) -> (integer | nil, string | nil), uint32_be: (Reader) -> (integer | nil, string | nil), varint: (Reader) -> (integer | nil, string | nil), remaining: (Reader) -> integer, pos: (Reader) -> integer, ... }
--:: Unframer = { _buf: string, _opts: { prefix: string | nil, ... }, ... }

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

--: () -> Writer
function M.writer()
	return setmetatable({ _buf = {}, _len = 0 }, Writer) --[[:! Writer]]
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

--: (Writer, integer) -> nil
local function w_byte(self, b)
	local self = self --[[:! Writer]]
	self._buf[#self._buf + 1] = char(b)
	self._len = self._len + 1
end

--: (Writer, string) -> nil
local function w_raw(self, s)
	local self = self --[[:! Writer]]
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

--: (self: Writer, string, integer) -> nil
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

--: (string) -> Reader
function M.reader(data)
	return setmetatable({ _data = data, _pos = 1 }, Reader) --[[:! Reader]]
end

function Reader:pos()
	local rd = self --[[:! Reader]]
	return rd._pos
end

function Reader:remaining()
	local rd = self --[[:! Reader]]
	return #rd._data - rd._pos + 1
end

function Reader:at_end()
	local rd = self --[[:! Reader]]
	return rd._pos > #rd._data
end

function Reader:seek(pos)
	local rd = self --[[:! Reader]]
	rd._pos = pos
end

--: (self: Reader, integer) -> (string | nil, string | nil)
function Reader:peek(n)
	local rd = self --[[:! Reader]]
	local e = rd._pos + n - 1
	if e > #rd._data then
		return nil, "unexpected end of data"
	end
	return sub(rd._data, rd._pos, e)
end

--: (self: Reader, integer) -> (boolean | nil, string | nil)
function Reader:skip(n)
	local rd = self --[[:! Reader]]
	if rd._pos + n - 1 > #rd._data then
		return nil, "unexpected end of data"
	end
	rd._pos = rd._pos + n
	return true
end

function Reader:bytes(n)
	local rd = self --[[:! Reader]]
	local s, err = rd:peek(n)
	if not s then return nil, err end
	s = s --[[:! string]]
	rd._pos = rd._pos + n
	return s
end

function Reader:uint8()
	local rd = self --[[:! Reader]]
	if rd._pos > #rd._data then
		return nil, "unexpected end of data"
	end
	local b = byte(rd._data, rd._pos)
	rd._pos = rd._pos + 1
	return b
end

function Reader:uint16_le()
	local rd = self --[[:! Reader]]
	local s, err = rd:bytes(2)
	if not s then return nil, err end
	s = s --[[:! string]]
	local b0 = byte(s, 1) or 0
	local b1 = byte(s, 2) or 0
	return bor(b0, lshift(b1, 8))
end

function Reader:uint16_be()
	local rd = self --[[:! Reader]]
	local s, err = rd:bytes(2)
	if not s then return nil, err end
	s = s --[[:! string]]
	local b0 = byte(s, 1) or 0
	local b1 = byte(s, 2) or 0
	return bor(lshift(b0, 8), b1)
end

function Reader:uint32_le()
	local rd = self --[[:! Reader]]
	local s, err = rd:bytes(4)
	if not s then return nil, err end
	s = s --[[:! string]]
	local b0 = byte(s, 1) or 0
	local b1 = byte(s, 2) or 0
	local b2 = byte(s, 3) or 0
	local b3 = byte(s, 4) or 0
	-- use bit.bor to avoid sign issues; cast to number
	local v = bor(bor(b0, lshift(b1, 8)), bor(lshift(b2, 16), lshift(b3, 24)))
	-- bor on LuaJIT returns signed int32; convert to unsigned lua number
	if v < 0 then v = (v + 4294967296) --[[:! integer]] end
	return v
end

function Reader:uint32_be()
	local rd = self --[[:! Reader]]
	local s, err = rd:bytes(4)
	if not s then return nil, err end
	s = s --[[:! string]]
	local b0 = byte(s, 1) or 0
	local b1 = byte(s, 2) or 0
	local b2 = byte(s, 3) or 0
	local b3 = byte(s, 4) or 0
	local v = bor(bor(lshift(b0, 24), lshift(b1, 16)), bor(lshift(b2, 8), b3))
	if v < 0 then v = (v + 4294967296) --[[:! integer]] end
	return v
end

function Reader:int8()
	local rd = self --[[:! Reader]]
	local v, err = rd:uint8()
	if not v then return nil, err end
	v = v --[[: unknown]]; v = v --[[:! integer]]
	return (v >= 0x80) and (v - 0x100) or v
end

function Reader:int16_le()
	local rd = self --[[:! Reader]]
	local v, err = rd:uint16_le()
	if not v then return nil, err end
	v = v --[[: unknown]]; v = v --[[:! integer]]
	return (v >= 0x8000) and (v - 0x10000) or v
end

function Reader:int16_be()
	local rd = self --[[:! Reader]]
	local v, err = rd:uint16_be()
	if not v then return nil, err end
	v = v --[[: unknown]]; v = v --[[:! integer]]
	return (v >= 0x8000) and (v - 0x10000) or v
end

function Reader:int32_le()
	local rd = self --[[:! Reader]]
	local v, err = rd:uint32_le()
	if not v then return nil, err end
	v = v --[[: unknown]]; v = v --[[:! integer]]
	-- v is unsigned 0..4294967295; sign-extend
	if v >= 0x80000000 then return v - 4294967296 end
	return v
end

function Reader:int32_be()
	local rd = self --[[:! Reader]]
	local v, err = rd:uint32_be()
	if not v then return nil, err end
	v = v --[[: unknown]]; v = v --[[:! integer]]
	if v >= 0x80000000 then return v - 4294967296 end
	return v
end

function Reader:float_le()
	local rd = self --[[:! Reader]]
	local s, err = rd:bytes(4)
	if not s then return nil, err end
	s = s --[[:! string]]
	_f32u.b[0] = byte(s,1) or 0; _f32u.b[1] = byte(s,2) or 0
	_f32u.b[2] = byte(s,3) or 0; _f32u.b[3] = byte(s,4) or 0
	return _f32u.f
end

function Reader:float_be()
	local rd = self --[[:! Reader]]
	local s, err = rd:bytes(4)
	if not s then return nil, err end
	s = s --[[:! string]]
	_f32u.b[3] = byte(s,1) or 0; _f32u.b[2] = byte(s,2) or 0
	_f32u.b[1] = byte(s,3) or 0; _f32u.b[0] = byte(s,4) or 0
	return _f32u.f
end

function Reader:double_le()
	local rd = self --[[:! Reader]]
	local s, err = rd:bytes(8)
	if not s then return nil, err end
	s = s --[[:! string]]
	_f64u.b[0] = byte(s,1) or 0; _f64u.b[1] = byte(s,2) or 0
	_f64u.b[2] = byte(s,3) or 0; _f64u.b[3] = byte(s,4) or 0
	_f64u.b[4] = byte(s,5) or 0; _f64u.b[5] = byte(s,6) or 0
	_f64u.b[6] = byte(s,7) or 0; _f64u.b[7] = byte(s,8) or 0
	return _f64u.d
end

function Reader:double_be()
	local rd = self --[[:! Reader]]
	local s, err = rd:bytes(8)
	if not s then return nil, err end
	s = s --[[:! string]]
	_f64u.b[7] = byte(s,1) or 0; _f64u.b[6] = byte(s,2) or 0
	_f64u.b[5] = byte(s,3) or 0; _f64u.b[4] = byte(s,4) or 0
	_f64u.b[3] = byte(s,5) or 0; _f64u.b[2] = byte(s,6) or 0
	_f64u.b[1] = byte(s,7) or 0; _f64u.b[0] = byte(s,8) or 0
	return _f64u.d
end

function Reader:varint()
	-- LEB128 unsigned
	local rd = self --[[:! Reader]]
	local result = 0
	local shift  = 0
	while true do
		if rd._pos > #rd._data then
			return nil, "unexpected end of data"
		end
		local b = byte(rd._data, rd._pos) or 0
		rd._pos = rd._pos + 1
		result = bor(result, lshift(band(b, 0x7f), shift))
		if band(b, 0x80) == 0 then break end
		shift = shift + 7
	end
	-- result may be negative if bit 31 set; convert to unsigned
	if result < 0 then result = (result + 4294967296) --[[:! integer]] end
	return result
end

function Reader:varint_signed()
	local rd = self --[[:! Reader]]
	local zz, err = rd:varint()
	if not zz then return nil, err end
	zz = zz --[[: unknown]]; zz = zz --[[:! integer]]
	-- zigzag decode
	if band(zz, 1) == 0 then
		return rshift(zz, 1)
	else
		return -(rshift(zz, 1) + 1)
	end
end

function Reader:str8()
	local rd = self --[[:! Reader]]
	local n, err = rd:uint8()
	if not n then return nil, err end
	return rd:bytes(n --[[:! integer]])
end

function Reader:str16()
	local rd = self --[[:! Reader]]
	local n, err = rd:uint16_le()
	if not n then return nil, err end
	return rd:bytes(n --[[:! integer]])
end

function Reader:str32()
	local rd = self --[[:! Reader]]
	local n, err = rd:uint32_le()
	if not n then return nil, err end
	return rd:bytes(n --[[:! integer]])
end

function Reader:str_varint()
	local rd = self --[[:! Reader]]
	local n, err = rd:varint()
	if not n then return nil, err end
	return rd:bytes(n --[[:! integer]])
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
	local payload, perr = r:bytes(n --[[:! integer]])
	if not payload then return nil, perr end
	payload = payload --[[:! string]]
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
	local uf = self --[[:! Unframer]]
	uf._buf = uf._buf .. chunk
end

-- Returns next complete message payload, or nil if not enough data yet.
-- On hard error returns nil, errmsg.
function Unframer:next()
	local uf = self --[[:! Unframer]]
	local prefix = uf._opts.prefix or "u32_be"
	local r = M.reader(uf._buf)

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

	local msglen = n --[[:! integer]]
	-- Check if full payload is available
	if r:remaining() < msglen then
		return nil
	end

	local rpos = r:pos()
	local payload = sub(uf._buf, rpos, rpos + msglen - 1)
	uf._buf = sub(uf._buf, rpos + msglen)
	return payload
end

return M
