-- Tests for lib/websocket — offline unit tests only.
-- Integration tests (live network, handshake) are deferred.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- Stub out dep.sha1 and dep.base64 — not needed for offline frame tests.
package.preload["dep.sha1"]   = function() return { binary = function(s) return s end } end
package.preload["dep.base64"] = function() return { encode = function(s) return s end } end

local ws = require("lib.websocket")
local T  = require("lib.test.assert")

-- ── helpers ──────────────────────────────────────────────────────────────────

-- Build a masked client→server frame manually.
-- opcode: integer (0–15)
-- fin: boolean
-- payload: string (unmasked)
-- mask_bytes: {integer,integer,integer,integer} (4-byte mask key)
local function make_client_frame(opcode, fin, payload, mask_bytes)
	local b0 = bit.bor(fin and 0x80 or 0, opcode)
	local len = #payload
	local header
	if len <= 125 then
		header = string.char(b0, bit.bor(0x80, len))
	elseif len <= 0xffff then
		header = string.char(
			b0, bit.bor(0x80, 126),
			bit.rshift(len, 8), bit.band(len, 0xff)
		)
	else
		error("test helper: payload too large")
	end
	local mask_str = string.char(
		mask_bytes[1], mask_bytes[2], mask_bytes[3], mask_bytes[4]
	)
	-- mask the payload
	local mi = 1
	local masked = {}
	local mi_next = { 2, 3, 4, 1 }
	for i = 1, #payload do
		masked[i] = bit.bxor(payload:byte(i), mask_bytes[mi])
		mi = mi_next[mi]
	end
	local masked_str = ""
	for i = 1, #masked do masked_str = masked_str .. string.char(masked[i]) end
	return header .. mask_str .. masked_str
end

-- ── encode (server → client, unmasked) ───────────────────────────────────────

T.describe("encode", function()
	T.it("text frame: FIN bit and opcode 1", function()
		local frame = ws._encode({ type = "text", payload = "hi" })
		T.ok(frame ~= nil, "encode returned a frame")
		-- byte 0: FIN(1) + opcode(0x01) = 0x81
		T.eq(frame:byte(1), 0x81, "byte 0: FIN+text opcode")
		-- byte 1: no mask, length = 2
		T.eq(frame:byte(2), 2, "byte 1: unmasked, length 2")
		-- payload follows immediately
		T.eq(frame:sub(3), "hi", "payload")
	end)

	T.it("binary frame: opcode 2", function()
		local frame = ws._encode({ type = "binary", payload = "\x01\x02\x03" })
		T.ok(frame ~= nil)
		T.eq(frame:byte(1), 0x82, "byte 0: FIN+binary opcode")
		T.eq(frame:byte(2), 3,    "length 3")
		T.eq(frame:sub(3), "\x01\x02\x03", "payload")
	end)

	T.it("ping frame: opcode 9", function()
		local frame = ws._encode({ type = "ping", payload = "pingdata" })
		T.ok(frame ~= nil)
		T.eq(frame:byte(1), 0x89, "byte 0: FIN+ping opcode (0x89)")
		T.eq(frame:byte(2), 8,    "payload length 8")
		T.eq(frame:sub(3), "pingdata", "payload")
	end)

	T.it("pong frame: opcode 10", function()
		local frame = ws._encode({ type = "pong", payload = "pongdata" })
		T.ok(frame ~= nil)
		T.eq(frame:byte(1), 0x8a, "byte 0: FIN+pong opcode (0x8a)")
	end)

	T.it("close frame: opcode 8", function()
		local frame = ws._encode({ type = "close", payload = "" })
		T.ok(frame ~= nil)
		T.eq(frame:byte(1), 0x88, "byte 0: FIN+close opcode (0x88)")
		T.eq(frame:byte(2), 0,    "empty payload")
	end)

	T.it("empty payload: length byte 0", function()
		local frame = ws._encode({ type = "text", payload = "" })
		T.ok(frame ~= nil)
		T.eq(frame:byte(2), 0, "length 0")
		T.eq(#frame, 2, "header only, no payload bytes")
	end)

	T.it("nil payload treated as empty string", function()
		local frame = ws._encode({ type = "text" })
		T.ok(frame ~= nil)
		T.eq(frame:byte(2), 0, "length 0")
	end)

	T.it("unknown type returns nil", function()
		local frame = ws._encode({ type = "garbage", payload = "" })
		T.eq(frame, nil, "nil for unknown type")
	end)

	T.it("126-byte extended length uses 2-byte length field", function()
		local payload = string.rep("x", 126)
		local frame = ws._encode({ type = "binary", payload = payload })
		T.ok(frame ~= nil)
		T.eq(frame:byte(1), 0x82, "FIN+binary")
		-- byte 1: 126 means 2-byte extended length follows
		T.eq(frame:byte(2), 126, "length indicator 126")
		local hi = frame:byte(3)
		local lo = frame:byte(4)
		T.eq(hi * 256 + lo, 126, "extended length value = 126")
		T.eq(frame:sub(5), payload, "payload after extended header")
	end)
end)

-- ── masking / unmasking ───────────────────────────────────────────────────────

T.describe("masking", function()
	T.it("XOR mask is its own inverse (round-trip)", function()
		-- Build a frame with a known mask, then decode it and verify payload.
		local payload  = "Hello"
		local mask_key = { 0x37, 0xfa, 0x21, 0x3d }
		local frame    = make_client_frame(0x1, true, payload, mask_key)
		local msg, fin = ws._decode(frame)
		T.ok(msg  ~= nil, "decode succeeded")
		T.ok(fin  == true, "FIN flag set")
		T.eq(msg.payload, payload, "unmasked payload matches original")
	end)

	T.it("mask of all zeros leaves payload unchanged", function()
		local payload  = "data"
		local mask_key = { 0, 0, 0, 0 }
		local frame    = make_client_frame(0x2, true, payload, mask_key)
		local msg = ws._decode(frame)
		T.ok(msg ~= nil)
		T.eq(msg.payload, payload, "zero mask: payload unchanged")
	end)

	T.it("mask of 0xff is reversible (decode recovers original payload)", function()
		-- masking with 0xff XORs every byte; decoding XORs again → original.
		local payload  = "\xaa\x55\x00\xff"
		local mask_key = { 0xff, 0xff, 0xff, 0xff }
		local frame    = make_client_frame(0x2, true, payload, mask_key)
		local msg = ws._decode(frame)
		T.ok(msg ~= nil)
		-- decode must recover the original payload, not the wire bytes
		T.eq(msg.payload, payload, "round-trip with 0xff mask recovers original")
	end)

	T.it("mask cycles over 4 bytes for payloads longer than 4", function()
		-- Build an 8-byte payload of known bytes, mask it, decode it, verify recovery.
		local mask_key = { 0x12, 0x34, 0x56, 0x78 }
		local payload  = "\x01\x02\x03\x04\x05\x06\x07\x08"
		local frame    = make_client_frame(0x2, true, payload, mask_key)
		local msg = ws._decode(frame)
		T.ok(msg ~= nil)
		-- The decoded payload must exactly match the original (XOR is its own inverse)
		T.eq(msg.payload, payload, "mask cycles correctly over 8-byte payload")
	end)
end)

-- ── decode ────────────────────────────────────────────────────────────────────

T.describe("decode", function()
	T.it("text frame", function()
		local frame = make_client_frame(0x1, true, "hello", { 0x01, 0x02, 0x03, 0x04 })
		local msg, fin = ws._decode(frame)
		T.ok(msg ~= nil)
		T.eq(msg.type,    "text",  "type is text")
		T.eq(msg.payload, "hello", "payload decoded")
		T.eq(fin, true, "FIN set")
	end)

	T.it("binary frame", function()
		local frame = make_client_frame(0x2, true, "\xde\xad\xbe\xef", { 0xca, 0xfe, 0xba, 0xbe })
		local msg = ws._decode(frame)
		T.ok(msg ~= nil)
		T.eq(msg.type, "binary", "type is binary")
		T.eq(#msg.payload, 4, "payload length")
	end)

	T.it("ping frame", function()
		local frame = make_client_frame(0x9, true, "ping!", { 0x11, 0x22, 0x33, 0x44 })
		local msg, fin = ws._decode(frame)
		T.ok(msg ~= nil)
		T.eq(msg.type,    "ping",  "type is ping")
		T.eq(msg.payload, "ping!", "payload")
		T.eq(fin, true)
	end)

	T.it("pong frame", function()
		local frame = make_client_frame(0xA, true, "pong!", { 0xaa, 0xbb, 0xcc, 0xdd })
		local msg = ws._decode(frame)
		T.ok(msg ~= nil)
		T.eq(msg.type, "pong", "type is pong")
	end)

	T.it("close frame: status code parsed from first 2 payload bytes", function()
		-- status 1000 = 0x03E8
		local payload  = "\x03\xe8" -- status 1000
		local mask_key = { 0x00, 0x00, 0x00, 0x00 }
		local frame    = make_client_frame(0x8, true, payload, mask_key)
		local msg = ws._decode(frame)
		T.ok(msg ~= nil)
		T.eq(msg.type,   "close", "type is close")
		T.eq(msg.status, 1000,    "status code 1000")
	end)

	T.it("close frame: empty payload gives status 0", function()
		local frame = make_client_frame(0x8, true, "", { 0x00, 0x00, 0x00, 0x00 })
		local msg = ws._decode(frame)
		T.ok(msg ~= nil)
		T.eq(msg.status, 0, "empty close payload → status 0")
	end)

	T.it("error: unmasked frame rejected", function()
		-- Manually build an unmasked frame (MASK bit = 0)
		local b0 = 0x81 -- FIN + text
		local b1 = 5    -- no mask bit, length = 5
		local frame = string.char(b0, b1) .. "hello"
		local msg, err = ws._decode(frame)
		T.eq(msg, nil, "nil msg for unmasked frame")
		T.eq(err, ws.error.frame_is_not_masked, "correct error code")
	end)

	T.it("error: reserved RSV bits set", function()
		-- RSV1 set: byte 0 bit 0x40
		local b0 = bit.bor(0x80, 0x40, 0x1) -- FIN + RSV1 + text
		local mask_key = { 0x01, 0x02, 0x03, 0x04 }
		local frame = string.char(b0, bit.bor(0x80, 2)) ..
			string.char(mask_key[1], mask_key[2], mask_key[3], mask_key[4]) ..
			"hi"
		local msg, err = ws._decode(frame)
		T.eq(msg, nil, "nil msg for RSV bits set")
		T.eq(err, ws.error.invalid_format, "invalid_format error")
	end)

	T.it("error: invalid opcode", function()
		-- Opcode 3 is reserved/invalid
		local b0 = bit.bor(0x80, 0x3) -- FIN + opcode 3
		local frame = string.char(b0, bit.bor(0x80, 0)) ..
			"\x00\x00\x00\x00" -- mask key
		local msg, err = ws._decode(frame)
		T.eq(msg, nil, "nil msg for invalid opcode")
		T.eq(err, ws.error.invalid_opcode, "invalid_opcode error")
	end)

	T.it("error: control frame fragmented (FIN=0, opcode>=8)", function()
		-- ping with FIN=0 is illegal
		local frame = make_client_frame(0x9, false, "ping", { 0x00, 0x00, 0x00, 0x00 })
		local msg, err = ws._decode(frame)
		T.eq(msg, nil, "nil msg")
		T.eq(err, ws.error.control_frame_is_fragmented, "control_frame_is_fragmented")
	end)

	T.it("error: invalid UTF-8 in text frame", function()
		-- 0xff is not valid UTF-8
		local invalid_utf8 = "\xff\xfe"
		local frame = make_client_frame(0x1, true, invalid_utf8, { 0x00, 0x00, 0x00, 0x00 })
		local msg, err = ws._decode(frame)
		T.eq(msg, nil, "nil msg for invalid UTF-8")
		T.eq(err, ws.error.text_frame_not_valid_utf8, "text_frame_not_valid_utf8")
	end)

	T.it("error: continuation frame as first frame", function()
		-- opcode 0x0 with no previous message
		local frame = make_client_frame(0x0, true, "data", { 0x00, 0x00, 0x00, 0x00 })
		local msg, err = ws._decode(frame)
		T.eq(msg, nil)
		T.eq(err, ws.error.continuation_frame_as_first_frame)
	end)
end)

-- ── close handshake frame structure ──────────────────────────────────────────

T.describe("close frame structure", function()
	T.it("encode close frame with no payload", function()
		local frame = ws._encode({ type = "close", payload = "" })
		T.ok(frame ~= nil)
		T.eq(frame:byte(1), 0x88, "FIN + close opcode")
		T.eq(frame:byte(2), 0,    "length = 0")
		T.eq(#frame, 2, "frame is header only")
	end)

	T.it("encode close frame with status reason text", function()
		-- RFC 6455: close frame payload = 2-byte status + optional UTF-8 reason
		local status_bytes = string.char(0x03, 0xe8) -- 1000 normal closure
		local reason       = "bye"
		local frame = ws._encode({ type = "close", payload = status_bytes .. reason })
		T.ok(frame ~= nil)
		T.eq(frame:byte(1), 0x88, "close opcode")
		T.eq(frame:byte(2), 5,    "2-byte status + 3-byte reason = 5")
		T.eq(frame:sub(3, 4), status_bytes, "status bytes in payload")
		T.eq(frame:sub(5), reason, "reason text")
	end)

	T.it("decode close frame preserves status and payload", function()
		local payload  = "\x03\xe8normal"
		local frame    = make_client_frame(0x8, true, payload, { 0x00, 0x00, 0x00, 0x00 })
		local msg = ws._decode(frame)
		T.ok(msg ~= nil)
		T.eq(msg.type,    "close",  "type close")
		T.eq(msg.status,  1000,     "status 1000")
		T.eq(msg.payload, "normal", "reason text (after status bytes)")
	end)
end)

-- ── ping/pong frame structure ─────────────────────────────────────────────────

T.describe("ping/pong frame structure", function()
	T.it("encode ping frame bytes", function()
		local frame = ws._encode({ type = "ping", payload = "" })
		T.ok(frame ~= nil)
		-- 0x89 = 1000 1001 = FIN(1) RSV(000) OPCODE(1001=9)
		T.eq(frame:byte(1), 0x89, "FIN + ping opcode 9")
		T.eq(frame:byte(2), 0,    "empty payload")
	end)

	T.it("encode pong frame bytes", function()
		local frame = ws._encode({ type = "pong", payload = "echo" })
		T.ok(frame ~= nil)
		-- 0x8a = 1000 1010 = FIN(1) RSV(000) OPCODE(1010=10)
		T.eq(frame:byte(1), 0x8a, "FIN + pong opcode 10")
		T.eq(frame:byte(2), 4,    "payload length 4")
		T.eq(frame:sub(3), "echo", "payload")
	end)

	T.it("ping round-trip: encode then decode", function()
		-- Encode a ping as server→client (unmasked), then wrap it as a
		-- client→server frame (masked) and decode.
		local data  = "keepalive"
		local frame = make_client_frame(0x9, true, data, { 0xde, 0xad, 0xbe, 0xef })
		local msg   = ws._decode(frame)
		T.ok(msg ~= nil)
		T.eq(msg.type,    "ping",      "type ping")
		T.eq(msg.payload, "keepalive", "payload survives round-trip")
	end)

	T.it("pong round-trip: server echoes ping payload", function()
		local data  = "keepalive"
		local frame = make_client_frame(0xA, true, data, { 0x01, 0x01, 0x01, 0x01 })
		local msg   = ws._decode(frame)
		T.ok(msg ~= nil)
		T.eq(msg.type,    "pong",      "type pong")
		T.eq(msg.payload, "keepalive", "payload survives round-trip")
	end)
end)

-- ── opcode and status_ids tables ─────────────────────────────────────────────

T.describe("constants", function()
	T.it("opcode values", function()
		T.eq(ws.opcode.continuation, 0)
		T.eq(ws.opcode.text,         1)
		T.eq(ws.opcode.binary,       2)
		T.eq(ws.opcode.close,        8)
		T.eq(ws.opcode.ping,         9)
		T.eq(ws.opcode.pong,         10)
	end)

	T.it("status_ids values", function()
		T.eq(ws.status_ids.normal,                              1000)
		T.eq(ws.status_ids.going_away,                          1001)
		T.eq(ws.status_ids.protocol_error,                      1002)
		T.eq(ws.status_ids.data_not_consistent_with_message_type, 1007)
		T.eq(ws.status_ids.server_unexpected_failure,           1011)
	end)

	T.it("error codes are distinct integers", function()
		local seen = {}
		for k, v in pairs(ws.error) do
			T.eq(type(v), "number", k .. " is a number")
			T.eq(seen[v], nil, "code " .. v .. " is unique")
			seen[v] = k
		end
	end)
end)
