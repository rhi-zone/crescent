-- lib/http/server_origin_test.lua
-- Covers what lib/http/server tells a handler about the connection it is
-- answering on: scheme, host, and port (see http_server_request).
-- RFC 9112 §3.3 — Reconstructing the Target URI.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local http_server = require("lib.http.server")

--:: require "lib.http.server"

-- Minimal client socket: hands back queued reads, records writes.
-- _loop is nil so the connection core skips the idle-timeout race.
-- Observations live in a separate `log` table so the socket itself carries
-- exactly the members http_client_sock declares.
--: ({ [integer]: string }) -> (http_client_sock, { sent: { [integer]: string }, closed: boolean })
local function mock_client(chunks)
	local i = 0
	local log = { sent = {}, closed = false }
	local c = {
		fd = 0,
		_loop = nil,
		on_send = nil,
		on_receive = nil,
		--: (self: http_client_sock, unknown) -> string | nil
		receive = function(_self, _buf)
			i = i + 1
			return chunks[i]
		end,
		--: (self: http_client_sock, string) -> unknown
		send = function(_self, d)
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
	return c, log
end

--: (string) -> string
local function req_bytes(head)
	return head .. "\r\n"
end

-- Run one request through a connection handler and return the request the
-- handler saw.
--: (string, http_origin | nil) -> http_server_request
local function capture_request(raw, origin)
	local captured --: http_server_request | nil
	--: (http_server_request, http_server_response, http_client_sock) -> (boolean | nil)
	local handler = function(req, res, _sock)
		captured = req
		res.status = 200
		res.body = "ok"
	end
	local conn = http_server.make_connection_handler(handler, nil, origin)
	conn(mock_client({ req_bytes(raw) }))
	local c = captured
	if not c then error("handler was never called — the request did not parse") end
	return c
end

T.describe("http/server request origin", function()

	T.describe("host", function()
		T.it("uses the Host field value when present", function()
			local req = capture_request(
				"GET /x HTTP/1.1\r\nhost: example.com\r\nconnection: close\r\n",
				{ scheme = "http", host = "127.0.0.1", port = 8080 })
			T.eq(req.host, "example.com", "Host field wins over the bind host")
		end)

		T.it("keeps the port the client sent in Host (RFC 9112 §3.3 authority)", function()
			local req = capture_request(
				"GET /x HTTP/1.1\r\nhost: example.com:8443\r\nconnection: close\r\n",
				{ scheme = "http", host = "127.0.0.1", port = 8080 })
			T.eq(req.host, "example.com:8443",
				"the authority is the field value verbatim, port included")
		end)

		T.it("falls back to the configured host when no Host field is sent", function()
			local req = capture_request(
				"GET /x HTTP/1.0\r\nconnection: close\r\n",
				{ scheme = "http", host = "dash.local", port = 8080 })
			T.eq(req.host, "dash.local")
		end)

		T.it("falls back when the Host field is present but empty", function()
			local req = capture_request(
				"GET /x HTTP/1.1\r\nhost: \r\nconnection: close\r\n",
				{ scheme = "http", host = "dash.local", port = 8080 })
			T.eq(req.host, "dash.local", "an empty field value is not an authority")
		end)

		T.it("is nil when neither a Host field nor a configured host exists", function()
			local req = capture_request(
				"GET /x HTTP/1.0\r\nconnection: close\r\n",
				{ scheme = "http", host = nil, port = 8080 })
			T.eq(req.host, nil,
				"no host name exists, so none is reported — callers must not be handed a fabricated one")
		end)

		T.it("reports a wildcard bind address verbatim rather than filtering it", function()
			local req = capture_request(
				"GET /x HTTP/1.0\r\nconnection: close\r\n",
				{ scheme = "http", host = "0.0.0.0", port = 8080 })
			T.eq(req.host, "0.0.0.0")
		end)
	end)

	T.describe("scheme and port", function()
		T.it("reports the origin scheme", function()
			local req = capture_request(
				"GET /x HTTP/1.1\r\nhost: a\r\nconnection: close\r\n",
				{ scheme = "https", host = nil, port = 443 })
			T.eq(req.scheme, "https")
		end)

		T.it("reports the bound port, not any port in the Host field", function()
			local req = capture_request(
				"GET /x HTTP/1.1\r\nhost: example.com:9999\r\nconnection: close\r\n",
				{ scheme = "http", host = nil, port = 8080 })
			T.eq(req.port, 8080)
		end)

		T.it("defaults to http with no host or port when no origin is given", function()
			local req = capture_request(
				"GET /x HTTP/1.0\r\nconnection: close\r\n", nil)
			T.eq(req.scheme, "http")
			T.eq(req.host, nil)
			T.eq(req.port, nil)
		end)
	end)

	T.describe("parsed message is unchanged", function()
		T.it("still carries method, target, version, headers and body", function()
			local body = '{"k":1}'
			local req = capture_request(
				"POST /submit HTTP/1.1\r\nhost: a\r\nconnection: close\r\n"
					.. "content-length: " .. #body .. "\r\n\r\n" .. body,
				{ scheme = "http", host = nil, port = 80 })
			T.eq(req.method, "POST")
			T.eq(req.target, "/submit")
			T.eq(req.version, "HTTP/1.1")
			T.eq(req.headers["host"][1], "a")
			T.eq(req.body, body)
		end)
	end)

end)
