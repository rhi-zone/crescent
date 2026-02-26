local format = require("lib.http.format")

local function assert_eq(a, b, msg)
	if a ~= b then error(msg .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

-- parse a basic GET request
local raw = "GET /path?foo=bar&baz=qux HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\n\r\n"
local req = format.string_to_http_request(raw)
assert(req, "should parse request")
assert_eq(req.method, "GET", "method")
assert_eq(req.path, "/path", "path")
assert_eq(req.params.foo, "bar", "param foo")
assert_eq(req.params.baz, "qux", "param baz")
assert_eq(req.version, 1.1, "version")
assert_eq(req.headers["host"][1], "example.com", "host header")

-- parse POST with body
local raw_post = "POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Length: 11\r\n\r\nhello=world"
local req_post = format.string_to_http_request(raw_post)
assert(req_post, "should parse POST")
assert_eq(req_post.method, "POST", "post method")
assert_eq(req_post.body, "hello=world", "post body")

-- serialize a response
local res_str = format.http_response_to_string({
	status = 200,
	headers = { ["content-type"] = "text/plain" },
	body = "ok",
})
assert(res_str:find("HTTP/1.1 200 OK"), "status line")
assert(res_str:find("Content%-Length: 2"), "content-length")
assert(res_str:find("ok$"), "body at end")

-- error on invalid input
local bad, err = format.string_to_http_request("not http")
assert_eq(bad, nil, "should fail on bad input")
assert(err, "should have error message")

-- query params with encoded characters
local raw_enc = "GET /search?q=hello%20world HTTP/1.1\r\nHost: example.com\r\n\r\n"
local req_enc = format.string_to_http_request(raw_enc)
assert(req_enc, "should parse encoded request")
assert_eq(req_enc.params.q, "hello world", "decoded param")
