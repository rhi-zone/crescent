-- Tests for WebSocket upgrade support in lib/http/server.lua.
-- Unit tests for validation, frame sizing, accept key, and mock-socket recv/send.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local server = require("lib.http.server")
local ws_frame = require("lib.websocket.frame")
local sha1_binary = require("lib.hash.sha1").binary
local base64_encode = require("lib.encode.base64").encode
local T = require("lib.test.assert")

-- ── helpers ──────────────────────────────────────────────────────────────────

-- Build a minimal http_request table for upgrade validation.
--: (string, string, string, string) -> { method: string, target: string, version: string, headers: { [string]: { [integer]: string } }, body: string | nil }
local function make_upgrade_req(connection, version, key, ws_version)
	return {
		method = "GET", target = "/ws", version = "HTTP/1.1", body = nil,
		headers = {
			["upgrade"] = { "websocket" },
			["connection"] = { connection },
			["sec-websocket-version"] = { version },
			["sec-websocket-key"] = { key },
		},
	}
end

-- Build a masked client-to-server frame (same helper as websocket_test.lua).
--: (integer, boolean, string, { [integer]: integer }) -> string
local function make_client_frame(opcode, fin, payload, mask_bytes)
	local b0 = bit.bor(fin and 0x80 or 0, opcode)
	local len = #payload
	local header = string.char(b0, bit.bor(0x80, len))
	local mask_str = string.char(mask_bytes[1], mask_bytes[2], mask_bytes[3], mask_bytes[4])
	local mi_next = { 2, 3, 4, 1 } --: { [integer]: integer }
	local mi = 1
	local masked = {} --: { [integer]: integer }
	for i = 1, #payload do
		masked[i] = bit.bxor(payload:byte(i) or 0, mask_bytes[mi])
		mi = mi_next[mi]
	end
	local masked_str = ""
	for i = 1, #masked do masked_str = masked_str .. string.char(masked[i] or 0) end
	return header .. mask_str .. masked_str
end

-- Create a mock socket with a queue of receive data and a send capture buffer.
local function mock_socket(receive_chunks)
	local idx = 0
	local sent = {} --: { [integer]: string }
	return {
		fd = 999,
		receive = function(self, recv_buf)
			idx = idx + 1
			local chunk = receive_chunks[idx]
			if not chunk then return nil end
			return chunk
		end,
		send = function(self, data)
			sent[#sent + 1] = data
			return #data
		end,
		close = function(self) end,
		on_send = nil,
		on_receive = nil,
		_loop = nil,
		_sent = sent,
	}
end

-- ── ws_validate_upgrade ──────────────────────────────────────────────────────

T.describe("ws_validate_upgrade", function()
	local validate = server._ws_validate_upgrade

	T.it("accepts a valid upgrade request", function()
		local req = make_upgrade_req("Upgrade", "13", "dGhlIHNhbXBsZSBub25jZQ==", "13")
		local key, err = validate(req)
		T.ok(key ~= nil, "should return key")
		T.eq(err, nil)
		T.eq(key, "dGhlIHNhbXBsZSBub25jZQ==")
	end)

	T.it("accepts Connection header with multiple tokens", function()
		local req = make_upgrade_req("keep-alive, Upgrade", "13", "dGhlIHNhbXBsZSBub25jZQ==", "13")
		local key = validate(req)
		T.ok(key ~= nil, "should accept 'keep-alive, Upgrade'")
	end)

	T.it("rejects missing Connection: Upgrade", function()
		local req = make_upgrade_req("keep-alive", "13", "dGhlIHNhbXBsZSBub25jZQ==", "13")
		local key, err = validate(req)
		T.eq(key, nil)
		T.ok(err ~= nil)
	end)

	T.it("rejects wrong WebSocket version", function()
		local req = make_upgrade_req("Upgrade", "8", "dGhlIHNhbXBsZSBub25jZQ==", "8")
		req.headers["sec-websocket-version"] = { "8" }
		local key, err = validate(req)
		T.eq(key, nil)
		T.ok(err ~= nil)
	end)

	T.it("rejects missing Sec-WebSocket-Key", function()
		local req = make_upgrade_req("Upgrade", "13", "dGhlIHNhbXBsZSBub25jZQ==", "13")
		req.headers["sec-websocket-key"] = nil
		local key, err = validate(req)
		T.eq(key, nil)
		T.ok(err ~= nil)
	end)

	T.it("rejects key with wrong length", function()
		local req = make_upgrade_req("Upgrade", "13", "short==", "13")
		local key, err = validate(req)
		T.eq(key, nil)
		T.ok(err ~= nil)
	end)

	T.it("rejects key with invalid base64", function()
		local req = make_upgrade_req("Upgrade", "13", "!!!!!!!!!!!!!!!!!!!!!!==" , "13")
		local key, err = validate(req)
		T.eq(key, nil)
		T.ok(err ~= nil)
	end)
end)

-- ── accept key computation (RFC 6455 §4.2.2 test vector) ────────────────────

T.describe("accept key computation", function()
	T.it("matches RFC 6455 example", function()
		-- RFC 6455 §4.2.2: client key "dGhlIHNhbXBsZSBub25jZQ==" produces
		-- accept value "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
		local client_key = "dGhlIHNhbXBsZSBub25jZQ=="
		local accept = base64_encode(sha1_binary(client_key .. server._WS_GUID))
		T.eq(accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
	end)
end)

-- ── ws_frame_byte_count ──────────────────────────────────────────────────────

T.describe("ws_frame_byte_count", function()
	local fbc = server._ws_frame_byte_count

	T.it("returns nil for fewer than 2 bytes", function()
		T.eq(fbc("x", 1), nil)
		T.eq(fbc("", 0), nil)
	end)

	T.it("small masked frame: 2 header + 4 mask + payload", function()
		-- Build a 5-byte payload masked frame header.
		local frame = make_client_frame(0x1, true, "hello", { 0, 0, 0, 0 })
		T.eq(fbc(frame, #frame), #frame)
	end)

	T.it("empty payload masked frame", function()
		local frame = make_client_frame(0x1, true, "", { 0, 0, 0, 0 })
		-- 2 (header) + 4 (mask) + 0 (payload) = 6
		T.eq(fbc(frame, #frame), 6)
	end)

	T.it("unmasked server frame: no mask bytes", function()
		-- Server-to-client: mask bit NOT set.
		--: string | nil
		local frame = ws_frame.encode({ type = "text", payload = "hi" })
		T.ok(frame ~= nil)
		if not frame then return end
		local frame_str = frame --: string
		-- 2 (header) + 2 (payload) = 4
		T.eq(fbc(frame_str, #frame_str), 4)
	end)
end)

-- ── make_ws_conn with mock socket ────────────────────────────────────────────

T.describe("make_ws_conn recv", function()
	local ffi = require("ffi")
	local test_buf = ffi.new("char[65536]")

	T.it("receives a single text frame", function()
		local frame_data = make_client_frame(0x1, true, "hello", { 1, 2, 3, 4 })
		local sock = mock_socket({ frame_data })
		local conn = server._make_ws_conn(sock, test_buf)
		local msg, err = conn:recv()
		T.ok(msg ~= nil, "should receive message")
		T.eq(err, nil)
		T.eq(msg.type, "text")
		T.eq(msg.payload, "hello")
	end)

	T.it("receives a binary frame", function()
		local frame_data = make_client_frame(0x2, true, "\xde\xad", { 0, 0, 0, 0 })
		local sock = mock_socket({ frame_data })
		local conn = server._make_ws_conn(sock, test_buf)
		local msg = conn:recv()
		T.ok(msg ~= nil)
		T.eq(msg.type, "binary")
		T.eq(msg.payload, "\xde\xad")
	end)

	T.it("handles two frames in one read (no frame drops)", function()
		local f1 = make_client_frame(0x1, true, "first", { 1, 2, 3, 4 })
		local f2 = make_client_frame(0x1, true, "second", { 5, 6, 7, 8 })
		-- Both frames arrive in a single socket read.
		local sock = mock_socket({ f1 .. f2 })
		local conn = server._make_ws_conn(sock, test_buf)
		local msg1 = conn:recv()
		T.ok(msg1 ~= nil, "first message received")
		T.eq(msg1.payload, "first")
		local msg2 = conn:recv()
		T.ok(msg2 ~= nil, "second message received")
		T.eq(msg2.payload, "second")
	end)

	T.it("handles frame split across two reads", function()
		local frame_data = make_client_frame(0x1, true, "split", { 0, 0, 0, 0 })
		local mid = math.floor(#frame_data / 2)
		local part1 = frame_data:sub(1, mid)
		local part2 = frame_data:sub(mid + 1)
		local sock = mock_socket({ part1, part2 })
		local conn = server._make_ws_conn(sock, test_buf)
		local msg = conn:recv()
		T.ok(msg ~= nil, "should reassemble split frame")
		T.eq(msg.payload, "split")
	end)

	T.it("handles fragmented message (continuation frames)", function()
		local f1 = make_client_frame(0x1, false, "hel", { 0, 0, 0, 0 })
		local f2 = make_client_frame(0x0, true, "lo", { 0, 0, 0, 0 })
		local sock = mock_socket({ f1 .. f2 })
		local conn = server._make_ws_conn(sock, test_buf)
		local msg = conn:recv()
		T.ok(msg ~= nil)
		T.eq(msg.payload, "hello")
		T.eq(msg.type, "text")
	end)

	T.it("auto-responds to ping with pong", function()
		local ping = make_client_frame(0x9, true, "keepalive", { 0, 0, 0, 0 })
		local text = make_client_frame(0x1, true, "data", { 0, 0, 0, 0 })
		local sock = mock_socket({ ping .. text })
		local conn = server._make_ws_conn(sock, test_buf)
		-- recv should skip the ping and return the text frame.
		local msg = conn:recv()
		T.ok(msg ~= nil, "should return data frame, not ping")
		T.eq(msg.payload, "data")
		-- Verify pong was sent.
		T.ok(#sock._sent > 0, "should have sent pong")
		local pong_frame = sock._sent[1]
		-- Pong opcode: 0x8a (FIN + opcode 10)
		T.eq(string.byte(pong_frame, 1), 0x8a)
	end)

	T.it("returns nil on close frame and echoes close", function()
		local close_payload = "\x03\xe8" -- status 1000
		local close = make_client_frame(0x8, true, close_payload, { 0, 0, 0, 0 })
		local sock = mock_socket({ close })
		local conn = server._make_ws_conn(sock, test_buf)
		local msg, err = conn:recv()
		T.eq(msg, nil)
		T.eq(err, "closed")
		-- Verify close frame was echoed.
		T.ok(#sock._sent > 0, "should have echoed close")
		local resp = sock._sent[1]
		T.eq(string.byte(resp, 1), 0x88) -- FIN + close opcode
	end)

	T.it("returns nil on connection loss", function()
		local sock = mock_socket({}) -- no data, receive returns nil immediately
		local conn = server._make_ws_conn(sock, test_buf)
		local msg, err = conn:recv()
		T.eq(msg, nil)
		T.eq(err, "connection closed")
	end)
end)

T.describe("make_ws_conn send", function()
	local ffi = require("ffi")
	local test_buf = ffi.new("char[65536]")

	T.it("sends a text frame", function()
		local sock = mock_socket({})
		local conn = server._make_ws_conn(sock, test_buf)
		local ok, err = conn:send("hello")
		T.ok(ok, "send should succeed")
		T.eq(err, nil)
		T.ok(#sock._sent > 0)
		-- Decode the sent frame to verify.
		local sent = sock._sent[1]
		-- Server frames are unmasked: FIN + text opcode = 0x81, length = 5
		T.eq(string.byte(sent, 1), 0x81)
		T.eq(string.byte(sent, 2), 5)
		T.eq(sent:sub(3), "hello")
	end)

	T.it("sends a binary frame", function()
		local sock = mock_socket({})
		local conn = server._make_ws_conn(sock, test_buf)
		local ok = conn:send("\x01\x02", "binary")
		T.ok(ok)
		local sent = sock._sent[1]
		T.eq(string.byte(sent, 1), 0x82) -- FIN + binary
	end)

	T.it("returns error after close", function()
		local sock = mock_socket({})
		local conn = server._make_ws_conn(sock, test_buf)
		conn:close()
		local ok, err = conn:send("after close")
		T.eq(ok, nil)
		T.eq(err, "closed")
	end)
end)

T.describe("make_ws_conn close", function()
	local ffi = require("ffi")
	local test_buf = ffi.new("char[65536]")

	T.it("sends close frame with default status 1000", function()
		local sock = mock_socket({})
		local conn = server._make_ws_conn(sock, test_buf)
		conn:close()
		T.ok(#sock._sent > 0)
		local sent = sock._sent[1]
		T.eq(string.byte(sent, 1), 0x88) -- FIN + close
		-- Payload: 2 bytes for status 1000 = 0x03E8
		T.eq(string.byte(sent, 3), 0x03)
		T.eq(string.byte(sent, 4), 0xE8)
	end)

	T.it("sends close frame with custom code and reason", function()
		local sock = mock_socket({})
		local conn = server._make_ws_conn(sock, test_buf)
		conn:close(1001, "going away")
		T.ok(#sock._sent > 0)
		local sent = sock._sent[1]
		T.eq(string.byte(sent, 1), 0x88)
		T.eq(string.byte(sent, 3), 0x03)
		T.eq(string.byte(sent, 4), 0xE9) -- 1001
		T.eq(sent:sub(5), "going away")
	end)

	T.it("is idempotent", function()
		local sock = mock_socket({})
		local conn = server._make_ws_conn(sock, test_buf)
		conn:close()
		conn:close()
		-- Only one close frame should be sent.
		T.eq(#sock._sent, 1)
	end)
end)

-- ── handler table normalization via make_connection_handler ──────────────────

T.describe("make_connection_handler", function()
	T.it("accepts a plain function (backward compat)", function()
		local called = false
		local handler = function(req, res, sock)
			called = true
			res.status = 200
			res.body = "ok"
		end
		-- Should not error during construction.
		local conn_handler = server.make_connection_handler(handler)
		T.ok(conn_handler ~= nil, "returns a connection handler function")
	end)

	T.it("accepts a handler table", function()
		local conn_handler = server.make_connection_handler({
			http = function(req, res, sock) res.status = 200 end,
			ws = function(ws_conn, req) end,
		})
		T.ok(conn_handler ~= nil, "returns a connection handler function")
	end)

	T.it("accepts a table with ws_accept", function()
		local conn_handler = server.make_connection_handler({
			http = function(req, res, sock) res.status = 200 end,
			ws_accept = function(req) return true end,
			ws = function(ws_conn, req) end,
		})
		T.ok(conn_handler ~= nil, "returns a connection handler function")
	end)
end)
