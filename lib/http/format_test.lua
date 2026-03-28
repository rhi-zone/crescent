if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local format = require("lib.http.format")
local cookies = require("lib.http.format.cookies")
local T = require("lib.test.assert")

T.describe("parse_request", function()
	T.it("basic GET request", function()
		local raw = "GET /path?foo=bar HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\n\r\n"
		local req, pos = format.parse_request(raw)
		T.ok(req ~= nil)
		T.eq(req.method, "GET")
		T.eq(req.target, "/path?foo=bar")
		T.eq(req.version, "HTTP/1.1")
		T.eq(req.headers["host"][1], "example.com")
		T.eq(req.headers["accept"][1], "*/*")
	end)

	T.it("POST with body", function()
		local raw = "POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Length: 11\r\n\r\nhello=world"
		local req = format.parse_request(raw)
		T.ok(req ~= nil)
		T.eq(req.method, "POST")
		T.eq(req.body, "hello=world")
	end)

	T.it("headers are lowercased", function()
		local raw = "GET / HTTP/1.1\r\nContent-Type: text/html\r\nX-Custom: foo\r\n\r\n"
		local req = format.parse_request(raw)
		T.ok(req ~= nil)
		T.eq(req.headers["content-type"][1], "text/html")
		T.eq(req.headers["x-custom"][1], "foo")
	end)

	T.it("multiple values for same header", function()
		local raw = "GET / HTTP/1.1\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\n"
		local req = format.parse_request(raw)
		T.ok(req ~= nil)
		T.eq(#req.headers["set-cookie"], 2)
		T.eq(req.headers["set-cookie"][1], "a=1")
		T.eq(req.headers["set-cookie"][2], "b=2")
	end)

	-- RFC 9112 §5.6 — obs-fold
	T.it("obs-fold: continuation line with SP", function()
		local raw = "GET / HTTP/1.1\r\nX-Long: value1\r\n value2\r\n\r\n"
		local req = format.parse_request(raw)
		T.ok(req ~= nil)
		T.eq(req.headers["x-long"][1], "value1 value2")
	end)

	T.it("obs-fold: continuation line with HTAB", function()
		local raw = "GET / HTTP/1.1\r\nX-Long: value1\r\n\tvalue2\r\n\r\n"
		local req = format.parse_request(raw)
		T.ok(req ~= nil)
		T.eq(req.headers["x-long"][1], "value1 value2")
	end)

	-- RFC 9110 §5.5 — OWS trimming
	T.it("OWS trimming on header values", function()
		local raw = "GET / HTTP/1.1\r\nX-Padded:   value   \r\n\r\n"
		local req = format.parse_request(raw)
		T.ok(req ~= nil)
		T.eq(req.headers["x-padded"][1], "value")
	end)

	T.it("nil body when empty", function()
		local raw = "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
		local req = format.parse_request(raw)
		T.ok(req ~= nil)
		T.eq(req.body, nil)
	end)

	T.it("returns error on incomplete message", function()
		local req, pos, err = format.parse_request("GET / HTTP/1.1\r\nHost: x\r\n")
		T.eq(req, nil)
		T.ok(err ~= nil)
	end)

	T.it("returns error on malformed request line", function()
		local req, pos, err = format.parse_request("BADLINE\r\n\r\n")
		T.eq(req, nil)
		T.ok(err ~= nil)
	end)
end)

T.describe("parse_response", function()
	T.it("basic 200 response", function()
		local raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
		local res = format.parse_response(raw)
		T.ok(res ~= nil)
		T.eq(res.status, 200)
		T.eq(res.reason, "OK")
		T.eq(res.version, "HTTP/1.1")
		T.eq(res.body, "ok")
	end)

	T.it("response with no body", function()
		local raw = "HTTP/1.1 204 No Content\r\n\r\n"
		local res = format.parse_response(raw)
		T.ok(res ~= nil)
		T.eq(res.status, 204)
		T.eq(res.reason, "No Content")
		T.eq(res.body, nil)
	end)

	T.it("response with empty reason phrase", function()
		local raw = "HTTP/1.1 200 \r\nContent-Length: 0\r\n\r\n"
		local res = format.parse_response(raw)
		T.ok(res ~= nil)
		T.eq(res.status, 200)
		T.eq(res.reason, "")
	end)

	T.it("multiple header values", function()
		local raw = "HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nContent-Length: 0\r\n\r\n"
		local res = format.parse_response(raw)
		T.ok(res ~= nil)
		T.eq(#res.headers["set-cookie"], 2)
	end)

	T.it("error on incomplete", function()
		local res, pos, err = format.parse_response("HTTP/1.1 200")
		T.eq(res, nil)
		T.ok(err ~= nil)
	end)
end)

T.describe("serialize_request", function()
	T.it("basic request", function()
		local s = format.serialize_request({
			method = "GET", target = "/foo", version = "HTTP/1.1",
			headers = { host = { "example.com" } },
		})
		T.ok(s:find("GET /foo HTTP/1.1\r\n"))
		T.ok(s:find("host: example.com\r\n"))
		T.ok(s:find("\r\n\r\n"))
	end)

	T.it("request with body", function()
		local s = format.serialize_request({
			method = "POST", target = "/data", version = "HTTP/1.1",
			headers = { ["content-length"] = { "5" } },
			body = "hello",
		})
		T.ok(s:find("hello$"))
	end)
end)

T.describe("serialize_response", function()
	T.it("basic response", function()
		local s = format.serialize_response({
			status = 200, reason = "OK", version = "HTTP/1.1",
			headers = { ["content-type"] = { "text/plain" } },
			body = "ok",
		})
		T.ok(s:find("HTTP/1.1 200 OK\r\n"))
		T.ok(s:find("content%-type: text/plain\r\n"))
		T.ok(s:find("content%-length: 2\r\n"))
		T.ok(s:find("ok$"))
	end)

	T.it("adds content-length if missing", function()
		local s = format.serialize_response({
			status = 200, body = "test",
		})
		T.ok(s:find("content%-length: 4\r\n"))
	end)

	T.it("does not duplicate content-length", function()
		local s = format.serialize_response({
			status = 200,
			headers = { ["content-length"] = { "4" } },
			body = "test",
		})
		-- should only appear once
		local count = 0
		for _ in s:gmatch("content%-length") do count = count + 1 end
		T.eq(count, 1)
	end)

	T.it("defaults to 200 OK", function()
		local s = format.serialize_response({ body = "" })
		T.ok(s:find("HTTP/1.1 200 OK\r\n"))
	end)
end)

T.describe("round-trip", function()
	T.it("request round-trip", function()
		local original = {
			method = "PUT", target = "/api/item", version = "HTTP/1.1",
			headers = { ["content-type"] = { "application/json" }, host = { "api.example.com" } },
			body = '{"key":"value"}',
		}
		local wire = format.serialize_request(original)
		local parsed = format.parse_request(wire)
		T.ok(parsed ~= nil)
		T.eq(parsed.method, "PUT")
		T.eq(parsed.target, "/api/item")
		T.eq(parsed.version, "HTTP/1.1")
		T.eq(parsed.headers["content-type"][1], "application/json")
		T.eq(parsed.headers["host"][1], "api.example.com")
	end)

	T.it("response round-trip", function()
		local original = {
			status = 404, reason = "Not Found", version = "HTTP/1.1",
			headers = { ["content-type"] = { "text/plain" } },
			body = "not found",
		}
		local wire = format.serialize_response(original)
		local parsed = format.parse_response(wire)
		T.ok(parsed ~= nil)
		T.eq(parsed.status, 404)
		T.eq(parsed.reason, "Not Found")
		T.eq(parsed.body, "not found")
	end)
end)


T.describe("cookies", function()
	T.it("parse single cookie", function()
		local req = { headers = { cookie = { "session=abc123" } } }
		local c = cookies.parse_cookies(req)
		T.ok(c ~= nil)
		T.eq(c.session, "abc123")
	end)

	T.it("parse multiple cookies", function()
		local req = { headers = { cookie = { "a=1; b=2; c=3" } } }
		local c = cookies.parse_cookies(req)
		T.ok(c ~= nil)
		T.eq(c.a, "1")
		T.eq(c.b, "2")
		T.eq(c.c, "3")
	end)

	T.it("no cookie header returns nil", function()
		local req = { headers = {} }
		local c = cookies.parse_cookies(req)
		T.eq(c, nil)
	end)

	T.it("backward compat alias", function()
		T.eq(cookies.http_request_to_cookies, cookies.parse_cookies)
	end)
end)
