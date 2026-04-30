-- WebSocket frame codec
-- RFC 6455 §5 — Data Framing

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local mod = {}

--:: ws_message = { type: string, payload: string, status?: integer }
--:: ws_mask = { [integer]: integer }

local byte = string.byte
local char = string.char
local sub = string.sub
local band = bit.band
local bor = bit.bor
local bxor = bit.bxor
local lshift = bit.lshift
local rshift = bit.rshift
local floor = math.floor
local min = math.min

-- RFC 6455 §7.4.1 — Status Code Definitions
--: { [string]: integer }
mod.status = {
	normal = 1000,
	going_away = 1001,
	protocol_error = 1002,
	unknown_data_format = 1003,
	-- 1004 reserved
	status_missing = 1005,        -- reserved, must not be set in close frame
	abnormal_closure = 1006,      -- reserved, must not be set in close frame
	data_not_consistent = 1007,
	violates_policy = 1008,
	message_too_big = 1009,
	extension_not_negotiated = 1010,
	server_unexpected_failure = 1011,
	tls_handshake_failure = 1015, -- reserved, must not be set in close frame
}

-- RFC 6455 §5.2 — opcodes
--: { [string]: integer }
mod.opcode = {
	continuation = 0, text = 1, binary = 2,
	close = 8, ping = 9, pong = 10,
}

--: { [string]: integer }
mod.error = {
	invalid_format = 1,
	invalid_opcode = 2,
	frame_is_not_masked = 3,
	text_frame_not_valid_utf8 = 4,
	control_frame_is_fragmented = 5,
	continuation_frame_as_first_frame = 6,
	continuation_frame_has_incorrect_opcode = 7,
}

local is_valid_opcode = {
	true, true, true, false, false, false, false, false,
	true, true, true, false, false, false, false, false,
}

local mi_next = { 2, 3, 4, 1 }

-- RFC 6455 §5.3 — Client-to-Server Masking
-- XOR each payload byte with mask[i % 4]
local bytes_to_string
if jit then
	local ffi = require("ffi")
	bytes_to_string = function(bytes) return ffi.string(ffi.new("const char[?]", #bytes, bytes), #bytes) end
else
	bytes_to_string = function(bytes)
		local chars = {}
		for i = 1, #bytes do chars[i] = char(bytes[i]) end
		return table.concat(chars)
	end
end

--: (string, integer, integer, {[1]:integer,[2]:integer,[3]:integer,[4]:integer} | nil, integer) -> (string, integer | nil)
local unmask = function(packet, i, payload_len, mask, mi)
	if mask then
		local bytes = {}
		for j = 1, min(payload_len, #packet - i + 1) do
			bytes[j] = bxor(byte(packet, i + j - 1), mask[mi])
			mi = mi_next[mi]
		end
		return bytes_to_string(bytes), mi
	else
		return sub(packet, i, i + payload_len - 1)
	end
end

-- Export unmask for internal use by websocket handler
mod._unmask = unmask

-- RFC 6455 §5.2 — Encode server-to-client frame (unmasked)
--:: ws_frame = { type: string, payload: string | nil, status: integer | nil }
--: (ws_frame) -> string | nil
mod.encode = function(msg)
	local opcode = mod.opcode[msg.type]
	if not opcode then return nil end
	-- RFC 6455 §5.2 — FIN bit (0x80) always set (no fragmentation in encode)
	local s = char(bor(0x80, opcode))
	local payload = msg.payload or ""
	local len = #payload
	if len <= 125 then
		s = s .. char(len)
	elseif len <= 0xffff then
		-- RFC 6455 §5.2 — 16-bit extended payload length
		s = s .. char(126, rshift(len, 8), band(len, 0xff))
	else
		-- RFC 6455 §5.2 — 64-bit extended payload length
		local len_hi = floor(len / 0x100000000)
		s = s .. char(
			127,
			rshift(len_hi, 24), band(rshift(len_hi, 16), 0xff),
			band(rshift(len_hi, 8), 0xff), band(len_hi, 0xff),
			rshift(len, 24), band(rshift(len, 16), 0xff),
			band(rshift(len, 8), 0xff), band(len, 0xff)
		)
	end
	return s .. payload
end

-- RFC 6455 §5.3 — Encode client-to-server frame (masked)
--: (ws_frame, integer, integer, integer, integer) -> string | nil
mod.encode_masked = function(msg, m1, m2, m3, m4)
	local opcode = mod.opcode[msg.type]
	if not opcode then return nil end
	local payload = msg.payload or ""
	local len = #payload
	-- FIN + opcode
	local parts = { char(bor(0x80, opcode)) }
	-- length with mask bit set
	if len <= 125 then
		parts[#parts + 1] = char(bor(0x80, len))
	elseif len <= 0xffff then
		parts[#parts + 1] = char(bor(0x80, 126), rshift(len, 8), band(len, 0xff))
	else
		local len_hi = floor(len / 0x100000000)
		parts[#parts + 1] = char(
			bor(0x80, 127),
			rshift(len_hi, 24), band(rshift(len_hi, 16), 0xff),
			band(rshift(len_hi, 8), 0xff), band(len_hi, 0xff),
			rshift(len, 24), band(rshift(len, 16), 0xff),
			band(rshift(len, 8), 0xff), band(len, 0xff)
		)
	end
	-- mask key
	parts[#parts + 1] = char(m1, m2, m3, m4)
	-- mask payload
	local mask = { m1, m2, m3, m4 }
	local mi = 1
	local masked = {}
	for i = 1, len do
		masked[i] = bxor(byte(payload, i), mask[mi])
		mi = mi_next[mi]
	end
	if len > 0 then
		parts[#parts + 1] = bytes_to_string(masked)
	end
	return table.concat(parts)
end

-- RFC 6455 §5.2 — Decode one frame
-- Returns: msg, fin_or_error, mask, mask_index, consumed_length
--: (string, ws_message | nil) -> (ws_message | nil, boolean|integer, ws_mask | nil, integer | nil, integer)
local decode_impl = function(packet, acc)
	local h0 = byte(packet, 1)
	local fin = band(h0, 0x80) ~= 0
	-- RFC 6455 §5.2 — RSV bits must be 0 (no extensions)
	if band(h0, 0x70) ~= 0 then return nil, mod.error.invalid_format, nil, nil, 0 end
	local opcode = band(h0, 0x0f)
	if not is_valid_opcode[opcode + 1] then return nil, mod.error.invalid_opcode, nil, nil, 0 end
	local h1 = byte(packet, 2)
	local payload_len = band(h1, 0x7f)
	local mask
	local pi = 3
	if payload_len == 126 then
		-- RFC 6455 §5.2 — 16-bit extended length
		local b1, b2 = byte(packet, 3, 4)
		payload_len = bor(lshift(b1, 8), b2)
		pi = 5
	elseif payload_len == 127 then
		-- RFC 6455 §5.2 — 64-bit extended length
		local b1, b2, b3, b4, b5, b6, b7, b8 = byte(packet, 3, 10)
		local hi = bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
		local lo = bor(lshift(b5, 24), lshift(b6, 16), lshift(b7, 8), b8)
		payload_len = hi * 0x100000000 + lo
		pi = 11
	end
	if band(h1, 0x80) ~= 0 then
		-- RFC 6455 §5.3 — masking key present
		mask = { byte(packet, pi, pi + 3) }
		pi = pi + 4
	else
		return nil, mod.error.frame_is_not_masked, nil, nil, 0
	end
	local payload, mi = unmask(packet, pi, payload_len, mask, 1)
	-- RFC 6455 §5.5 — control frames must not be fragmented
	if not fin and opcode >= 0x8 then return nil, mod.error.control_frame_is_fragmented, nil, nil, 0 end
	-- RFC 6455 §5.6 — Data frames
	if opcode == 0x1 then -- text
		if not fin and acc then return nil, mod.error.continuation_frame_has_incorrect_opcode, nil, nil, 0 end
		local utf8 = require("lib.encode.utf8")
		if not utf8.is_valid(payload) then return nil, mod.error.text_frame_not_valid_utf8, nil, nil, 0 end
		acc = { type = "text", payload = payload }
	elseif opcode == 0x2 then -- binary
		if not fin and acc then return nil, mod.error.continuation_frame_has_incorrect_opcode, nil, nil, 0 end
		acc = { type = "binary", payload = payload }
	elseif opcode == 0x0 then -- RFC 6455 §5.4 — continuation
		if not acc then return nil, mod.error.continuation_frame_as_first_frame, nil, nil, 0 end
		acc.payload = acc.payload .. payload
	-- RFC 6455 §5.5.2 — Ping
	elseif opcode == 0x9 then
		acc = { type = "ping", payload = payload }
	-- RFC 6455 §5.5.3 — Pong
	elseif opcode == 0xA then
		acc = { type = "pong", payload = payload }
	-- RFC 6455 §5.5.1 — Close
	elseif opcode == 0x8 then
		local status = 0
		if #payload > 0 then
			local a, b = byte(payload, 1, 2)
			status = bor(lshift(a, 8), b)
		end
		acc = { type = "close", status = status, payload = sub(payload, 3) }
	end
	return acc, fin, mask, mi, (payload_len + pi - 1)
end

-- Public decode: (s, i?, acc?) -> msg?, fin_or_error, consumed_length
-- When called with (s, acc) where acc is a table, treats it as (s, nil, acc)
-- for backward compatibility.
--: (string, integer | nil, ws_message | nil) -> (ws_message | nil, boolean|integer, integer)
mod.decode = function(s, i, acc)
	local packet
	if type(i) == "table" then
		-- called as decode(s, acc) — backward-compat two-arg form
		acc = i
		i = 1
		packet = s
	elseif i == nil or i == 1 then
		i = 1
		packet = s
	else
		packet = sub(s, i)
	end
	local msg, fin_or_err, mask, mi, consumed = decode_impl(packet, acc)
	return msg, fin_or_err, consumed
end

-- Internal decode that returns all 5 values (for websocket handler)
--: (string, ws_message | nil) -> (ws_message | nil, boolean|integer, ws_mask | nil, integer | nil, integer)
mod._decode_full = function(packet, acc)
	return decode_impl(packet, acc)
end

return mod
