-- lib/platform/caps/http_server_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T          = require("lib.test.assert")
local http_srv   = require("lib.platform.caps.http_server")

T.describe("http_server_cap", function()

	T.describe("factory", function()
		T.it("returns cap table and revoke function", function()
			local cap, revoke = http_srv.http_server_cap({ port = 19876 })
			T.ok(cap, "cap should not be nil")
			T.eq(type(revoke), "function")
		end)

		T.it("returns nil + error when port is missing", function()
			local cap, err = http_srv.http_server_cap({})
			T.eq(cap, nil)
			T.ok(err:find("port"), "error should mention port")
		end)

		T.it("returns nil + error when opts is nil", function()
			local cap, err = http_srv.http_server_cap(nil)
			T.eq(cap, nil)
			T.ok(err:find("opts"), "error should mention opts")
		end)
	end)

	T.describe("cap fields", function()
		T.it("has serve function, url and port", function()
			local cap = http_srv.http_server_cap({ port = 19877 })
			T.eq(type(cap.serve), "function")
			T.eq(cap.port, 19877)
			T.eq(cap.url, "http://localhost:19877")
		end)

		T.it("url uses localhost regardless of host opt", function()
			local cap = http_srv.http_server_cap({ port = 19878, host = "127.0.0.1" })
			T.eq(cap.url, "http://localhost:19878")
		end)
	end)

	T.describe("revocation", function()
		T.it("serve returns error after revocation", function()
			local cap, revoke = http_srv.http_server_cap({ port = 19879 })
			revoke()
			local ok, err = cap.serve(function() end)
			T.eq(ok, nil)
			T.ok(err:find("revoked"), "error should mention revoked")
		end)

		T.it("serve rejects non-function handler", function()
			local cap = http_srv.http_server_cap({ port = 19880 })
			local ok, err = cap.serve("not a function")
			T.eq(ok, nil)
			T.ok(err:find("function"), "error should mention function")
		end)
	end)

	T.describe("_split_target", function()
		T.it("splits path and query", function()
			local path, query = http_srv._split_target("/foo?bar=1&baz=2")
			T.eq(path, "/foo")
			T.eq(query, "bar=1&baz=2")
		end)

		T.it("returns nil query when no question mark", function()
			local path, query = http_srv._split_target("/foo/bar")
			T.eq(path, "/foo/bar")
			T.eq(query, nil)
		end)

		T.it("handles empty query string", function()
			local path, query = http_srv._split_target("/foo?")
			T.eq(path, "/foo")
			T.eq(query, "")
		end)

		T.it("handles root path", function()
			local path, query = http_srv._split_target("/")
			T.eq(path, "/")
			T.eq(query, nil)
		end)
	end)

	T.describe("daemon mode", function()
		T.it("does not bind a port; cap.port is 0", function()
			local captured
			local cap = http_srv.http_server_cap({
				daemon = true,
				url = "https://app-abc.example",
				on_serve = function(h) captured = h end,
			})
			T.ok(cap, "cap should not be nil")
			T.eq(cap.port, 0)
			T.eq(cap.url, "https://app-abc.example")
			T.eq(captured, nil, "on_serve not called until serve() invoked")
		end)

		T.it("cap.serve registers handler via on_serve and returns true", function()
			local captured
			local cap = http_srv.http_server_cap({
				daemon = true,
				on_serve = function(h) captured = h end,
			})
			local h = function() end
			local ok = cap.serve(h)
			T.eq(ok, true)
			T.eq(captured, h, "registered handler matches")
		end)

		T.it("rejects non-function handler", function()
			local cap = http_srv.http_server_cap({
				daemon = true,
				on_serve = function() end,
			})
			local ok, err = cap.serve("not a function")
			T.eq(ok, nil)
			T.ok(err:find("function"), "error mentions function")
		end)

		T.it("rejects serve after revocation", function()
			local cap, revoke = http_srv.http_server_cap({
				daemon = true,
				on_serve = function() end,
			})
			revoke()
			local ok, err = cap.serve(function() end)
			T.eq(ok, nil)
			T.ok(err:find("revoked"), "error mentions revoked")
		end)

		T.it("requires opts.on_serve", function()
			local cap, err = http_srv.http_server_cap({ daemon = true })
			T.eq(cap, nil)
			T.ok(err:find("on_serve"), "error mentions on_serve")
		end)

		T.it("url defaults to empty string when not provided", function()
			local cap = http_srv.http_server_cap({
				daemon = true,
				on_serve = function() end,
			})
			T.eq(cap.url, "")
		end)
	end)

	T.describe("_wrap_handler", function()
		-- Mock socket for testing the handler wrapper.
		local function mock_socket()
			local sock = {
				sent = {},
				closed = false,
			}
			function sock:send(data)
				self.sent[#self.sent + 1] = data
				return #data
			end
			function sock:close()
				self.closed = true
			end
			function sock:set_option() return true end
			return sock
		end

		T.it("passes sanitized req to app handler", function()
			local revoked_ref = { false }
			local captured_req
			local wrapped = http_srv._wrap_handler(function(req, res)
				captured_req = req
				res.status = 200
				res.body = "ok"
			end, revoked_ref)

			local raw_req = {
				method  = "GET",
				target  = "/api/data?x=1",
				headers = { ["host"] = { "localhost" } },
				body    = nil,
			}
			local raw_res = { headers = {} }
			local sock = mock_socket()

			wrapped(raw_req, raw_res, sock)

			T.ok(captured_req, "handler should have been called")
			T.eq(captured_req.method, "GET")
			T.eq(captured_req.path, "/api/data")
			T.eq(captured_req.query, "x=1")
			T.eq(type(captured_req.headers), "table")
			T.eq(captured_req.body, nil)
		end)

		T.it("does not expose socket to app handler", function()
			local revoked_ref = { false }
			local captured_req, captured_res
			local wrapped = http_srv._wrap_handler(function(req, res)
				captured_req = req
				captured_res = res
			end, revoked_ref)

			local raw_req = { method = "GET", target = "/", headers = {} }
			local raw_res = { headers = {} }
			local sock = mock_socket()

			wrapped(raw_req, raw_res, sock)

			-- req should not have socket-like methods
			T.eq(captured_req.send, nil)
			T.eq(captured_req.close, nil)
			T.eq(captured_req.receive, nil)
			-- res should have builder fields, not raw socket
			T.eq(type(captured_res.send_event), "function")
			T.eq(type(captured_res.close), "function")
		end)

		T.it("normal response sets status/headers/body on raw_res", function()
			local revoked_ref = { false }
			local wrapped = http_srv._wrap_handler(function(req, res)
				res.status = 201
				res.headers["x-custom"] = { "yes" }
				res.body = "created"
			end, revoked_ref)

			local raw_req = { method = "POST", target = "/items", headers = {} }
			local raw_res = { headers = {} }
			local sock = mock_socket()

			local result = wrapped(raw_req, raw_res, sock)

			T.eq(result, nil, "normal response should return nil (not streaming)")
			T.eq(raw_res.status, 201)
			T.eq(raw_res.headers["x-custom"][1], "yes")
			T.eq(raw_res.body, "created")
		end)

		T.it("SSE: send_event writes to socket and returns true", function()
			local revoked_ref = { false }
			local wrapped = http_srv._wrap_handler(function(req, res)
				res.send_event("hello")
				res.send_event("world")
				res.close()
			end, revoked_ref)

			local raw_req = { method = "GET", target = "/events", headers = {} }
			local raw_res = { headers = {} }
			local sock = mock_socket()

			local result = wrapped(raw_req, raw_res, sock)

			T.eq(result, true, "SSE response should return true (streaming)")
			-- First send is the SSE preamble (HTTP headers)
			T.ok(sock.sent[1]:find("text/event%-stream"), "preamble should have SSE content type")
			-- Second and third sends are the data frames
			T.eq(sock.sent[2], "data: hello\n\n")
			T.eq(sock.sent[3], "data: world\n\n")
			T.ok(sock.closed, "socket should be closed after res.close()")
		end)

		T.it("SSE: send_event after close returns error", function()
			local revoked_ref = { false }
			local send_result
			local wrapped = http_srv._wrap_handler(function(req, res)
				res.send_event("first")
				res.close()
				send_result = { res.send_event("after-close") }
			end, revoked_ref)

			local raw_req = { method = "GET", target = "/events", headers = {} }
			local raw_res = { headers = {} }
			local sock = mock_socket()

			wrapped(raw_req, raw_res, sock)

			T.eq(send_result[1], nil)
			T.ok(send_result[2]:find("closed"), "error should mention closed")
		end)

		T.it("revoked handler skips app_handler entirely", function()
			local revoked_ref = { true }
			local called = false
			local wrapped = http_srv._wrap_handler(function()
				called = true
			end, revoked_ref)

			local raw_req = { method = "GET", target = "/", headers = {} }
			local raw_res = { headers = {} }
			local sock = mock_socket()

			wrapped(raw_req, raw_res, sock)

			T.ok(not called, "handler should not be called when revoked")
		end)

		T.it("SSE: send_event returns error when revoked mid-stream", function()
			local revoked_ref = { false }
			local send_results = {}
			local wrapped = http_srv._wrap_handler(function(req, res)
				send_results[1] = { res.send_event("first") }
				revoked_ref[1] = true
				send_results[2] = { res.send_event("second") }
			end, revoked_ref)

			local raw_req = { method = "GET", target = "/events", headers = {} }
			local raw_res = { headers = {} }
			local sock = mock_socket()

			wrapped(raw_req, raw_res, sock)

			T.eq(send_results[1][1], true, "first send_event should succeed")
			T.eq(send_results[2][1], nil, "second send_event should fail")
			T.ok(send_results[2][2]:find("revoked"), "error should mention revoked")
		end)

		T.it("req includes body for POST requests", function()
			local revoked_ref = { false }
			local captured_req
			local wrapped = http_srv._wrap_handler(function(req, res)
				captured_req = req
			end, revoked_ref)

			local raw_req = {
				method  = "POST",
				target  = "/submit",
				headers = { ["content-type"] = { "application/json" } },
				body    = '{"key":"value"}',
			}
			local raw_res = { headers = {} }
			local sock = mock_socket()

			wrapped(raw_req, raw_res, sock)

			T.eq(captured_req.body, '{"key":"value"}')
			T.eq(captured_req.method, "POST")
		end)

		T.it("SSE: send_event(data, {id, event}) emits id/event lines", function()
			local revoked_ref = { false }
			local wrapped = http_srv._wrap_handler(function(req, res)
				res.send_event("hello", { id = 1, event = "schema" })
				res.send_event("world", { id = 2 })
				res.send_event("done", { event = "end" })
				res.close()
			end, revoked_ref)
			local sock = mock_socket()
			wrapped({ method = "GET", target = "/events", headers = {} }, { headers = {} }, sock)
			T.eq(sock.sent[2], "id: 1\nevent: schema\ndata: hello\n\n")
			T.eq(sock.sent[3], "id: 2\ndata: world\n\n")
			T.eq(sock.sent[4], "event: end\ndata: done\n\n")
		end)

		T.it("SSE: req.last_event_id parsed from header", function()
			local revoked_ref = { false }
			local captured_req
			local wrapped = http_srv._wrap_handler(function(req, res)
				captured_req = req
			end, revoked_ref)
			local raw_req = {
				method  = "GET",
				target  = "/events",
				headers = { ["last-event-id"] = { "42" } },
			}
			wrapped(raw_req, { headers = {} }, mock_socket())
			T.eq(captured_req.last_event_id, "42")
		end)

		T.it("SSE: send_event returns nil, err on socket send failure", function()
			local revoked_ref = { false }
			local results
			local wrapped = http_srv._wrap_handler(function(req, res)
				local r1 = { res.send_event("first") }
				-- next sock:send returns failure
				results = { r1 = r1 }
				local r2 = { res.send_event("second") }
				results.r2 = r2
			end, revoked_ref)
			local sent_count = 0
			local sock = {
				sent = {}, closed = false,
			}
			function sock:send(data)
				sent_count = sent_count + 1
				if sent_count >= 3 then return nil, "broken pipe" end
				self.sent[#self.sent + 1] = data
				return #data
			end
			function sock:close() self.closed = true end
			function sock:set_option() return true end
			wrapped({ method = "GET", target = "/events", headers = {} }, { headers = {} }, sock)
			T.eq(results.r1[1], true)
			T.eq(results.r2[1], nil)
			T.ok(tostring(results.r2[2]):find("broken pipe") ~= nil
				or tostring(results.r2[2]):find("client closed") ~= nil,
				"err should mention broken pipe or client closed")
		end)

		T.it("SSE: TCP_NODELAY set_option called when tcp_nodelay=true", function()
			local revoked_ref = { false }
			local wrapped = http_srv._wrap_handler(function(req, res)
				res.send_event("x")
				res.close()
			end, revoked_ref, true)
			local opts_calls = {}
			local sock = {
				sent = {}, closed = false,
			}
			function sock:send(data) self.sent[#self.sent + 1] = data; return #data end
			function sock:close() self.closed = true end
			function sock:set_option(key, val, level)
				opts_calls[#opts_calls + 1] = { key = key, val = val, level = level }
				return true
			end
			wrapped({ method = "GET", target = "/events", headers = {} }, { headers = {} }, sock)
			local saw_nodelay = false
			local saw_keepalive = false
			for _, c in ipairs(opts_calls) do
				if c.key == "tcp_nodelay" then saw_nodelay = true end
				if c.key == "so_keepalive" then saw_keepalive = true end
			end
			T.ok(saw_nodelay, "tcp_nodelay should be set")
			T.ok(saw_keepalive, "so_keepalive should be set")
		end)

		T.it("SSE: TCP_NODELAY skipped when tcp_nodelay=false; keepalive still on", function()
			local revoked_ref = { false }
			local wrapped = http_srv._wrap_handler(function(req, res)
				res.send_event("x")
				res.close()
			end, revoked_ref, false)
			local opts_calls = {}
			local sock = {
				sent = {}, closed = false,
			}
			function sock:send(data) self.sent[#self.sent + 1] = data; return #data end
			function sock:close() self.closed = true end
			function sock:set_option(key)
				opts_calls[#opts_calls + 1] = key
				return true
			end
			wrapped({ method = "GET", target = "/events", headers = {} }, { headers = {} }, sock)
			local saw_nodelay = false
			local saw_keepalive = false
			for _, k in ipairs(opts_calls) do
				if k == "tcp_nodelay"  then saw_nodelay   = true end
				if k == "so_keepalive" then saw_keepalive = true end
			end
			T.ok(not saw_nodelay,  "tcp_nodelay should be skipped")
			T.ok(saw_keepalive, "so_keepalive should still be set")
		end)
	end)

end)
