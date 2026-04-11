-- lib/proto/init.lua
-- Protocol Buffers 3 wire format encoder and decoder.
-- Schemas are Lua tables — no .proto parser.
--
-- Public API:
--   M.message(fields) -> schema
--   M.repeated(type)  -> repeated descriptor
--   M.ENUM(n)         -> INT32 alias with enum hint
--   M.encode(schema, msg) -> string | nil, err
--   M.decode(schema, data) -> table | nil, err
--   M.INT32, M.INT64, M.UINT32, M.UINT64, M.SINT32, M.SINT64
--   M.BOOL, M.FLOAT, M.DOUBLE, M.STRING, M.BYTES
--   M._tier = "pure"

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ── Wire types ────────────────────────────────────────────────────────────────

local WIRE_VARINT = 0
local WIRE_64BIT  = 1
local WIRE_LEN    = 2
-- 3,4 = deprecated start/end group (not supported)
local WIRE_32BIT  = 5

-- ── Field type descriptors ────────────────────────────────────────────────────
-- Each descriptor is a table with at minimum: kind, wire
-- Message schemas have kind="message" and wire=WIRE_LEN (set in M.message).

M.INT32  = { kind = "int32",  wire = WIRE_VARINT }
M.INT64  = { kind = "int64",  wire = WIRE_VARINT }
M.UINT32 = { kind = "uint32", wire = WIRE_VARINT }
M.UINT64 = { kind = "uint64", wire = WIRE_VARINT }
M.SINT32 = { kind = "sint32", wire = WIRE_VARINT }
M.SINT64 = { kind = "sint64", wire = WIRE_VARINT }
M.BOOL   = { kind = "bool",   wire = WIRE_VARINT }
M.FLOAT  = { kind = "float",  wire = WIRE_32BIT  }
M.DOUBLE = { kind = "double", wire = WIRE_64BIT  }
M.STRING = { kind = "string", wire = WIRE_LEN    }
M.BYTES  = { kind = "bytes",  wire = WIRE_LEN    }

-- ENUM(n) is semantically INT32 (just annotated for the caller).
function M.ENUM(n) --luacheck: ignore
	return { kind = "int32", wire = WIRE_VARINT, enum = true }
end

-- message(fields) builds a message schema.
-- fields: array of { field_number, field_name, type_descriptor }
function M.message(fields)
	local schema = { kind = "message", wire = WIRE_LEN, fields = {}, by_number = {} }
	for _, f in ipairs(fields) do
		local number, name, ftype = f[1], f[2], f[3]
		local entry = { number = number, name = name, ftype = ftype }
		schema.fields[#schema.fields + 1] = entry
		schema.by_number[number] = entry
	end
	return schema
end

-- repeated(ftype) marks a field as repeated.
-- Scalar types use packed encoding (wire type LEN wrapping varints/fixed).
-- Message types use repeated LEN records.
function M.repeated(ftype)
	return { kind = "repeated", ftype = ftype, wire = WIRE_LEN }
end

-- ── Float / double packing via LuaJIT FFI ────────────────────────────────────
-- string.pack is not available in this LuaJIT build; use an FFI union instead.

local ffi = require("ffi")

ffi.cdef [[
	union pb_float_union  { float  f; uint8_t b[4]; };
	union pb_double_union { double d; uint8_t b[8]; };
]]

local _fu = ffi.new("union pb_float_union")
local _du = ffi.new("union pb_double_union")

local function pack_float(v)
	_fu.f = v
	return ffi.string(_fu.b, 4)
end

local function pack_double(v)
	_du.d = v
	return ffi.string(_du.b, 8)
end

local function unpack_float(s, i)
	-- i is 1-based Lua string index
	ffi.copy(_fu.b, s:sub(i, i + 3), 4)
	return _fu.f, i + 4
end

local function unpack_double(s, i)
	ffi.copy(_du.b, s:sub(i, i + 7), 8)
	return _du.d, i + 8
end

-- ── Varint encoding ───────────────────────────────────────────────────────────

-- encode_varint_u64: encode an unsigned 64-bit value split into hi/lo 32-bit halves.
-- For values that fit in 32 bits, hi=0.
local function encode_varint_u64(lo, hi)
	-- lo and hi are treated as unsigned 32-bit integers.
	-- We emit 7 bits at a time, little-endian.
	local bytes = {}
	local n = 0
	lo = lo % 0x100000000   -- ensure unsigned
	hi = (hi or 0) % 0x100000000
	while lo > 127 or hi > 0 do
		n = n + 1
		bytes[n] = string.char((lo % 128) + 128)
		-- shift right by 7: take top 25 bits of lo, and bottom 7 bits of hi become top 7 of lo
		lo = math.floor(lo / 128)
		if hi > 0 then
			-- hi's low 7 bits go into the top of lo (at bit 25 = 2^25)
			lo = lo + (hi % 128) * (0x100000000 / 128)
			hi = math.floor(hi / 128)
		end
	end
	n = n + 1
	bytes[n] = string.char(lo)
	return table.concat(bytes)
end

-- Encode a signed 32-bit integer as varint (two's complement, 10 bytes for negatives).
local function encode_varint_i32(v)
	if v >= 0 then
		return encode_varint_u64(v, 0)
	else
		-- Negative int32: sign-extend to 64-bit two's complement.
		-- low word: v + 2^32 (gives the unsigned bit pattern)
		-- high word: 0xFFFFFFFF (all ones = sign extension)
		local lo = v + 0x100000000
		return encode_varint_u64(lo, 0xFFFFFFFF)
	end
end

-- Encode a signed 64-bit integer (Lua double, exact up to ±2^53).
local function encode_varint_i64(v)
	if v >= 0 then
		return encode_varint_u64(v % 0x100000000, math.floor(v / 0x100000000))
	else
		-- Two's complement for 64-bit negative.
		-- For v in [-2^53, -1]:
		--   lo = (v mod 2^32) interpreted unsigned = v + k*2^32 for some k
		--   We want the standard C two's complement: add 2^64.
		-- Lua's % always returns non-negative, so:
		local lo = v % 0x100000000        -- unsigned low 32 bits (0..2^32-1)
		-- hi: take floor(v/2^32) which for negative v gives negative quotient.
		-- We need the unsigned interpretation of the high word.
		local hi_signed = math.floor(v / 0x100000000)
		local hi = hi_signed % 0x100000000   -- unsigned
		return encode_varint_u64(lo, hi)
	end
end

-- Zigzag encode sint32
local function zigzag32(v)
	if v >= 0 then
		return v * 2
	else
		return (-v - 1) * 2 + 1
	end
end

-- Zigzag encode sint64 (returns single value, fits in Lua double for |v| < 2^52)
local function zigzag64(v)
	if v >= 0 then
		return v * 2
	else
		return (-v - 1) * 2 + 1
	end
end

-- ── Encoder ───────────────────────────────────────────────────────────────────

-- Encode a single value given its type descriptor. Returns a string fragment.
local function encode_value(ftype, value)
	local k = ftype.kind

	if k == "int32" then
		return encode_varint_i32(value)

	elseif k == "int64" then
		return encode_varint_i64(value)

	elseif k == "uint32" then
		return encode_varint_u64(value % 0x100000000, 0)

	elseif k == "uint64" then
		return encode_varint_u64(value % 0x100000000, math.floor(value / 0x100000000))

	elseif k == "sint32" then
		return encode_varint_u64(zigzag32(value), 0)

	elseif k == "sint64" then
		local zz = zigzag64(value)
		return encode_varint_u64(zz % 0x100000000, math.floor(zz / 0x100000000))

	elseif k == "bool" then
		return value and "\1" or "\0"

	elseif k == "float" then
		return pack_float(value)

	elseif k == "double" then
		return pack_double(value)

	elseif k == "string" or k == "bytes" then
		local s = tostring(value)
		return encode_varint_u64(#s, 0) .. s

	elseif k == "message" then
		local inner, err = M.encode(ftype, value)
		if not inner then return nil, err end
		return encode_varint_u64(#inner, 0) .. inner

	else
		return nil, "unknown field kind: " .. tostring(k)
	end
end

-- Encode a field tag: (field_number << 3) | wire_type
local function encode_tag(number, wire)
	return encode_varint_u64((number * 8) + wire, 0)
end

-- M.encode(schema, msg) -> string | nil, err
function M.encode(schema, msg)
	if schema.kind ~= "message" then
		return nil, "encode: schema must be a message"
	end
	local parts = {}
	local n = 0
	for _, field in ipairs(schema.fields) do
		local value = msg[field.name]
		if value == nil then
			-- omit absent fields (proto3 default)
		else
			local ftype = field.ftype
			if ftype.kind == "repeated" then
				-- Repeated field
				if type(value) ~= "table" then
					return nil, "field '" .. field.name .. "': expected table for repeated"
				end
				local inner_ftype = ftype.ftype
				-- Empty repeated: emit nothing (proto3 default values are omitted)
				if #value == 0 then
					-- skip
				elseif inner_ftype.kind == "message" then
					-- One LEN record per element
					for _, elem in ipairs(value) do
						n = n + 1
						parts[n] = encode_tag(field.number, WIRE_LEN)
						local encoded, err = encode_value(inner_ftype, elem)
						if not encoded then return nil, err end
						n = n + 1
						parts[n] = encoded
					end
				elseif inner_ftype.kind == "string" or inner_ftype.kind == "bytes" then
					-- strings/bytes: each element is its own LEN record
					for _, elem in ipairs(value) do
						n = n + 1
						parts[n] = encode_tag(field.number, WIRE_LEN)
						local encoded, err = encode_value(inner_ftype, elem)
						if not encoded then return nil, err end
						n = n + 1
						parts[n] = encoded
					end
				else
					-- Packed scalar: tag(LEN) + length + concatenated values
					local packed = {}
					local pn = 0
					for _, elem in ipairs(value) do
						local encoded, err = encode_value(inner_ftype, elem)
						if not encoded then return nil, err end
						pn = pn + 1
						packed[pn] = encoded
					end
					local payload = table.concat(packed)
					n = n + 1
					parts[n] = encode_tag(field.number, WIRE_LEN)
					n = n + 1
					parts[n] = encode_varint_u64(#payload, 0) .. payload
				end
			else
				-- Singular field
				local tag = encode_tag(field.number, ftype.wire)
				local encoded, err = encode_value(ftype, value)
				if not encoded then return nil, err end
				n = n + 1
				parts[n] = tag
				n = n + 1
				parts[n] = encoded
			end
		end
	end
	return table.concat(parts)
end

-- alias
M.msg_to_string = M.encode

-- ── Varint decoding ───────────────────────────────────────────────────────────

-- decode_varint(data, pos) -> lo, hi, next_pos  |  nil, nil, nil, err
-- lo and hi are unsigned 32-bit halves; next_pos is the byte after the varint.
local function decode_varint(data, pos)
	local lo = 0
	local hi = 0
	local shift = 0
	local i = pos
	local len = #data
	while i <= len do
		local b = data:byte(i)
		i = i + 1
		if shift < 28 then
			lo = lo + (b % 128) * (2 ^ shift)
			shift = shift + 7
		elseif shift == 28 then
			-- bits 28..34 straddle lo and hi
			-- bits 28..31: low 4 bits of (b%128)
			lo = lo + (b % 16) * (2 ^ 28)
			lo = lo % 0x100000000
			-- bits 32..34: high 3 bits of (b%128) = floor((b%128)/16)
			hi = hi + math.floor((b % 128) / 16)
			shift = shift + 7
		else
			-- shift >= 35; all bits go into hi
			local hi_shift = shift - 32
			hi = hi + (b % 128) * (2 ^ hi_shift)
			shift = shift + 7
		end
		if b < 128 then
			lo = lo % 0x100000000
			hi = hi % 0x100000000
			return lo, hi, i
		end
		if shift >= 70 then
			return nil, nil, nil, "varint too long"
		end
	end
	return nil, nil, nil, "truncated varint"
end

-- Interpret lo as a signed 32-bit integer.
local function signed32(lo)
	if lo >= 0x80000000 then
		return lo - 0x100000000
	end
	return lo
end

-- Reconstruct a signed 64-bit integer from lo/hi unsigned halves.
-- Uses (hi - 2^32) for the high word when hi >= 2^31 to avoid float precision
-- loss that occurs when computing (lo + hi*2^32 - 2^64) with large intermediates.
local function signed64(lo, hi)
	if hi >= 0x80000000 then
		-- hi is the unsigned bit-pattern; treat as signed: hi_signed = hi - 2^32
		return lo + (hi - 0x100000000) * 0x100000000
	else
		return lo + hi * 0x100000000
	end
end

-- Zigzag decode
local function unzigzag(v)
	if v % 2 == 0 then
		return v / 2
	else
		return -(v + 1) / 2
	end
end

-- ── Decoder ───────────────────────────────────────────────────────────────────

-- skip_field(data, pos, wire_type) -> next_pos | nil, err
local function skip_field(data, pos, wire)
	if wire == WIRE_VARINT then
		local _, _, npos, err = decode_varint(data, pos)
		if err then return nil, err end
		return npos
	elseif wire == WIRE_64BIT then
		return pos + 8
	elseif wire == WIRE_LEN then
		local lo, _, npos, err = decode_varint(data, pos)
		if err then return nil, err end
		return npos + lo
	elseif wire == WIRE_32BIT then
		return pos + 4
	else
		return nil, "unsupported wire type: " .. tostring(wire)
	end
end

-- decode_value: decode one value from data at pos, given a type descriptor.
-- Returns value, next_pos | nil, nil, err
local function decode_value(ftype, data, pos)
	local k = ftype.kind

	if k == "int32" then
		local lo, _, npos, err = decode_varint(data, pos)
		if err then return nil, nil, err end
		return signed32(lo), npos

	elseif k == "int64" then
		local lo, hi, npos, err = decode_varint(data, pos)
		if err then return nil, nil, err end
		return signed64(lo, hi), npos

	elseif k == "uint32" then
		local lo, _, npos, err = decode_varint(data, pos)
		if err then return nil, nil, err end
		return lo, npos

	elseif k == "uint64" then
		local lo, hi, npos, err = decode_varint(data, pos)
		if err then return nil, nil, err end
		return lo + hi * 0x100000000, npos

	elseif k == "sint32" then
		local lo, _, npos, err = decode_varint(data, pos)
		if err then return nil, nil, err end
		return unzigzag(lo), npos

	elseif k == "sint64" then
		local lo, hi, npos, err = decode_varint(data, pos)
		if err then return nil, nil, err end
		return unzigzag(lo + hi * 0x100000000), npos

	elseif k == "bool" then
		local lo, _, npos, err = decode_varint(data, pos)
		if err then return nil, nil, err end
		return lo ~= 0, npos

	elseif k == "float" then
		if pos + 3 > #data then return nil, nil, "truncated float" end
		local v, npos = unpack_float(data, pos)
		return v, npos

	elseif k == "double" then
		if pos + 7 > #data then return nil, nil, "truncated double" end
		local v, npos = unpack_double(data, pos)
		return v, npos

	elseif k == "string" or k == "bytes" then
		local lo, _, npos, err = decode_varint(data, pos)
		if err then return nil, nil, err end
		if npos + lo - 1 > #data then return nil, nil, "truncated string/bytes" end
		return data:sub(npos, npos + lo - 1), npos + lo

	elseif k == "message" then
		local lo, _, npos, err = decode_varint(data, pos)
		if err then return nil, nil, err end
		if npos + lo - 1 > #data then return nil, nil, "truncated message" end
		local sub = data:sub(npos, npos + lo - 1)
		local result, derr = M.decode(ftype, sub)
		if not result then return nil, nil, derr end
		return result, npos + lo

	else
		return nil, nil, "unknown field kind: " .. tostring(k)
	end
end

-- M.decode(schema, data) -> table | nil, err
function M.decode(schema, data)
	if schema.kind ~= "message" then
		return nil, "decode: schema must be a message"
	end
	local result = {}
	local pos = 1
	local len = #data
	while pos <= len do
		local tag_lo, _, npos, err = decode_varint(data, pos)
		if err then return nil, "tag: " .. err end
		pos = npos
		local field_number = math.floor(tag_lo / 8)
		local wire_type = tag_lo % 8

		local field = schema.by_number[field_number]
		if not field then
			-- Unknown field: skip
			local skip_pos, skip_err = skip_field(data, pos, wire_type)
			if not skip_pos then return nil, "skip unknown field: " .. (skip_err or "?") end
			pos = skip_pos
		else
			local ftype = field.ftype
			local fname = field.name

			if ftype.kind == "repeated" then
				local inner_ftype = ftype.ftype
				if not result[fname] then result[fname] = {} end
				local arr = result[fname]

				if inner_ftype.kind == "message" or inner_ftype.kind == "string" or inner_ftype.kind == "bytes" then
					-- Each occurrence is a separate LEN record; decode_value handles the length prefix.
					local v, npos2, verr = decode_value(inner_ftype, data, pos)
					if verr then return nil, "field '" .. fname .. "': " .. verr end
					arr[#arr + 1] = v
					pos = npos2
				else
					-- May be packed (wire LEN) or unpacked (wire = scalar type)
					if wire_type == WIRE_LEN then
						-- Packed: read length-delimited block, then decode each scalar inside
						local lo, _, npos2, lerr = decode_varint(data, pos)
						if lerr then return nil, lerr end
						pos = npos2
						local end_pos = pos + lo
						while pos < end_pos do
							local v, npos3, verr = decode_value(inner_ftype, data, pos)
							if verr then return nil, "field '" .. fname .. "' packed: " .. verr end
							arr[#arr + 1] = v
							pos = npos3
						end
					else
						-- Unpacked: single element with scalar wire type
						local v, npos2, verr = decode_value(inner_ftype, data, pos)
						if verr then return nil, "field '" .. fname .. "': " .. verr end
						arr[#arr + 1] = v
						pos = npos2
					end
				end
			else
				-- Singular
				local v, npos2, verr = decode_value(ftype, data, pos)
				if verr then return nil, "field '" .. fname .. "': " .. verr end
				result[fname] = v
				pos = npos2
			end
		end
	end
	return result
end

-- alias
M.string_to_msg = M.decode

return M
