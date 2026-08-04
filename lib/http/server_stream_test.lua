-- lib/http/server_stream_test.lua
-- Covers incremental (streamed) responses: lib/http/server's response_stream,
-- the head-only serializer it uses, and the per-response keep-alive override.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local http_server = require("lib.http.server")
local format = require("lib.http.format")

--:: require "lib.http.server"

--:: MockLog = { sent: { [integer]: string }, closed: boolean }

-- Socket mock. `fail_after` is the number of sends that succeed before every
-- later send reports a dead peer; nil means none ever fail. Observations live
-- in the returned log so the socket carries exactly the members
-- http_client_sock declares.
--: ({ [integer]: string } | nil, integer | nil) -> (http_client_sock, MockLog)
local function mock_sock(chunks, fail_after)
	local i = 0
	local n = 0
	local log = { sent = {}, closed = false } --: MockLog
	local s = {
		fd = 0,
		_loop = nil,
		on_send = nil,
		on_receive = nil,
		--: (self: http_client_sock, unknown) -> string | nil
		receive = function(_self, _buf)
			if not chunks then return nil end
			i = i + 1
			return chunks[i]
		end,
		--: (self: http_client_sock, string) -> unknown
		send = function(_self, d)
			n = n + 1
			if fail_after and n > fail_after then return nil, "broken pipe" end
			log.sent[#log.sent + 1] = d
			return #d
		end,
		-- TYPECHECKER WORKAROUND: the natural code is `log.closed = true`.
		-- A dot-form field assignment to an upvalue or parameter, inside a
		-- function body carrying a `--:` signature, has its expected type
		-- resolved to the *enclosing function's* type rather than the field's,
		-- so `true` is reported as unassignable to a function type. The
		-- bracket form of the same assignment is unaffected. Minimal repro and
		-- revert tracked in TODO.md.
		--: (self: http_client_sock) -> unknown
		close = function(_self) log["closed"] = true; return true end,
		--: (self: http_client_sock, string, unknown, string | nil) -> (boolean | nil, string | nil)
		set_option = function(_self, _k, _v, _level) return true end,
	}
	return s, log
end

--: () -> http_server_response
local function blank_res()
	return { status = 200, reason = "", version = "HTTP/1.1", headers = {}, body = nil, raw = nil, keep_alive = nil }
end

T.describe("http/format serialize_response_head", function()
	T.it("emits status line and fields with no body", function()
		local head = format.serialize_response_head({
			status = 200, reason = "OK", version = "HTTP/1.1",
			headers = { ["content-type"] = { "text/event-stream" } },
			body = nil,
		})
		T.eq(head, "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n")
	end)

	T.it("synthesizes no content-length (RFC 9112 §6.1)", function()
		local head = format.serialize_response_head({
			status = 200, reason = "OK", version = "HTTP/1.1", headers = {}, body = nil,
		})
		T.eq(head:find("content-length", 1, true), nil,
			"a declared length would make the streamed bytes that follow undefined")
	end)

	T.it("keeps a content-length the caller stated itself", function()
		local head = format.serialize_response_head({
			status = 200, reason = "OK", version = "HTTP/1.1",
			headers = { ["content-length"] = { "42" } }, body = nil,
		})
		T.ok(head:find("content-length: 42", 1, true) ~= nil)
	end)

	T.it("serialize_response still synthesizes one, unchanged", function()
		local full = format.serialize_response({
			status = 200, reason = "OK", version = "HTTP/1.1", headers = {}, body = "hi",
		})
		T.ok(full:find("content-length: 2", 1, true) ~= nil)
	end)
end)

T.describe("http/server response_stream", function()

	T.it("marks the response raw so the core stops managing it", function()
		local res = blank_res()
		local sock = mock_sock(nil, nil)
		http_server.response_stream(res, sock)
		T.eq(res.raw, true)
	end)

	T.it("writes nothing until the first send_head or write", function()
		local sock, log = mock_sock(nil, nil)
		http_server.response_stream(blank_res(), sock)
		T.eq(#log.sent, 0, "creating a stream must not commit a response")
	end)

	T.it("send_head serializes status and headers once", function()
		local res = blank_res()
		res.reason = "OK"
		res.headers["content-type"] = { "text/event-stream" }
		local sock, log = mock_sock(nil, nil)
		local stream = http_server.response_stream(res, sock)

		T.eq(stream:send_head(), true)
		T.eq(log.sent[1], "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n")

		T.eq(stream:send_head(), true, "second call succeeds")
		T.eq(#log.sent, 1, "and writes nothing more")
	end)

	T.it("write sends the head first when it has not gone out", function()
		local res = blank_res()
		res.reason = "OK"
		local sock, log = mock_sock(nil, nil)
		local stream = http_server.response_stream(res, sock)

		T.eq(stream:write("chunk-1"), true)
		T.ok(log.sent[1]:find("^HTTP/1.1 200 OK") ~= nil, "head precedes the first chunk")
		T.eq(log.sent[2], "chunk-1")
	end)

	T.it("writes chunks incrementally, in order", function()
		local sock, log = mock_sock(nil, nil)
		local stream = http_server.response_stream(blank_res(), sock)
		stream:send_head()
		stream:write("a")
		stream:write("b")
		stream:write("c")
		T.eq(log.sent[2], "a")
		T.eq(log.sent[3], "b")
		T.eq(log.sent[4], "c")
	end)

	T.it("close ends the response and closes the socket", function()
		local sock, log = mock_sock(nil, nil)
		local stream = http_server.response_stream(blank_res(), sock)
		stream:send_head()
		T.eq(stream:is_open(), true)
		stream:close()
		T.ok(log.closed, "closing is what delimits a body with no declared length")
		T.eq(stream:is_open(), false)
	end)

	T.it("close is idempotent", function()
		local sock, log = mock_sock(nil, nil)
		local stream = http_server.response_stream(blank_res(), sock)
		stream:close()
		stream:close()
		T.ok(log.closed)
	end)

	T.it("write after close returns an error instead of writing", function()
		local sock, log = mock_sock(nil, nil)
		local stream = http_server.response_stream(blank_res(), sock)
		stream:send_head()
		stream:close()
		local ok, err = stream:write("late")
		T.eq(ok, nil)
		T.ok(tostring(err):find("closed") ~= nil, "error should mention closed, got " .. tostring(err))
		T.eq(#log.sent, 1)
	end)

	T.it("surfaces a write failure and closes the stream", function()
		-- head succeeds, first chunk fails
		local sock = mock_sock(nil, 1)
		local stream = http_server.response_stream(blank_res(), sock)
		T.eq(stream:send_head(), true)
		local ok, err = stream:write("x")
		T.eq(ok, nil)
		T.ok(tostring(err):find("broken pipe") ~= nil,
			"error should carry the socket error, got " .. tostring(err))
		T.eq(stream:is_open(), false)
	end)

	T.it("surfaces a head failure", function()
		local sock = mock_sock(nil, 0)
		local stream = http_server.response_stream(blank_res(), sock)
		local ok, err = stream:send_head()
		T.eq(ok, nil)
		T.ok(tostring(err):find("broken pipe") ~= nil, "got " .. tostring(err))
	end)
end)

T.describe("http/server streaming through the connection core", function()

	T.it("does not serialize or close a streamed response", function()
		--: (http_server_request, http_server_response, http_client_sock) -> (boolean | nil)
		local handler = function(_req, res, sock)
			res.reason = "OK"
			res.headers["content-type"] = { "text/event-stream" }
			local stream = http_server.response_stream(res, sock)
			stream:write("data: one\n\n")
			stream:write("data: two\n\n")
		end
		local conn = http_server.make_connection_handler(handler, nil, nil)
		local client, log = mock_sock({ "GET /events HTTP/1.1\r\nhost: a\r\n\r\n" }, nil)
		conn(client)

		T.eq(#log.sent, 3, "head plus two chunks, and no serialized response after them")
		T.ok(log.sent[1]:find("text/event%-stream") ~= nil)
		T.eq(log.sent[1]:find("content-length", 1, true), nil)
		T.eq(log.sent[2], "data: one\n\n")
		T.eq(log.sent[3], "data: two\n\n")
		T.ok(not log.closed, "the stream owns the socket lifetime, not the core")
	end)

	T.it("lets the handler close the stream when the stream ends", function()
		--: (http_server_request, http_server_response, http_client_sock) -> (boolean | nil)
		local handler = function(_req, res, sock)
			local stream = http_server.response_stream(res, sock)
			stream:write("data: only\n\n")
			stream:close()
		end
		local conn = http_server.make_connection_handler(handler, nil, nil)
		local client, log = mock_sock({ "GET /events HTTP/1.1\r\nhost: a\r\n\r\n" }, nil)
		conn(client)
		T.ok(log.closed)
	end)

	T.it("buffered responses are unaffected", function()
		--: (http_server_request, http_server_response, http_client_sock) -> (boolean | nil)
		local handler = function(_req, res, _sock)
			res.reason = "OK"
			res.body = "hello"
		end
		local conn = http_server.make_connection_handler(handler, nil, nil)
		local client, log = mock_sock({ "GET / HTTP/1.1\r\nhost: a\r\nconnection: close\r\n\r\n" }, nil)
		conn(client)
		T.eq(#log.sent, 1)
		T.ok(log.sent[1]:find("content-length: 5", 1, true) ~= nil,
			"a buffered body still declares its length")
		T.ok(log.closed)
	end)
end)

T.describe("http/server per-response keep-alive override", function()

	T.it("keeps the connection open across requests by default", function()
		local seen = 0
		--: (http_server_request, http_server_response, http_client_sock) -> (boolean | nil)
		local handler = function(_req, res, _sock)
			seen = seen + 1
			res.reason = "OK"
			res.body = "r" .. seen
		end
		local conn = http_server.make_connection_handler(handler, nil, nil)
		local client = mock_sock({
			"GET /1 HTTP/1.1\r\nhost: a\r\n\r\n",
			"GET /2 HTTP/1.1\r\nhost: a\r\n\r\n",
		}, nil)
		conn(client)
		T.eq(seen, 2, "both requests served on one connection")
	end)

	T.it("res.keep_alive = false pins a single response on the connection", function()
		local seen = 0
		--: (http_server_request, http_server_response, http_client_sock) -> (boolean | nil)
		local handler = function(_req, res, _sock)
			seen = seen + 1
			res.reason = "OK"
			res.body = "once"
			res.keep_alive = false
		end
		local conn = http_server.make_connection_handler(handler, nil, nil)
		local client, log = mock_sock({
			"GET /1 HTTP/1.1\r\nhost: a\r\n\r\n",
			"GET /2 HTTP/1.1\r\nhost: a\r\n\r\n",
		}, nil)
		conn(client)
		T.eq(seen, 1, "the second request is not served")
		T.ok(log.sent[1]:find("connection: close", 1, true) ~= nil,
			"and the client is told the connection is closing")
		T.ok(log.closed)
	end)

	T.it("server-wide max_requests remains available alongside it", function()
		local seen = 0
		--: (http_server_request, http_server_response, http_client_sock) -> (boolean | nil)
		local handler = function(_req, res, _sock)
			seen = seen + 1
			res.reason = "OK"
			res.body = "x"
		end
		local conn = http_server.make_connection_handler(handler, { idle_timeout = nil, max_requests = 1 }, nil)
		local client = mock_sock({
			"GET /1 HTTP/1.1\r\nhost: a\r\n\r\n",
			"GET /2 HTTP/1.1\r\nhost: a\r\n\r\n",
		}, nil)
		conn(client)
		T.eq(seen, 1)
	end)
end)
