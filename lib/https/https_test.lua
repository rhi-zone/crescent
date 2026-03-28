if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")

-- lib.https depends on lib.tls which requires libtls.so at load time.
-- Skip gracefully when the native library is not present.
local ok_load, https = pcall(require, "lib.https")
if not ok_load then return end

T.describe("lib.https", function()
	T.it("exports request and stream", function()
		T.ok(type(https.request) == "function", "request is a function")
		T.ok(type(https.stream) == "function", "stream is a function")
	end)

	T.it("request returns (nil, errmsg) for unreachable host", function()
		local res, err = https.request({
			method = "GET",
			host = "127.0.0.1",
			path = "/",
			headers = {},
		})
		T.ok(res == nil, "result is nil on failure")
		T.ok(type(err) == "string", "error is a string")
		T.ok(#err > 0, "error message is non-empty")
	end)

	T.it("stream returns (nil, errmsg) for unreachable host", function()
		local recv, err = https.stream({
			method = "GET",
			host = "127.0.0.1",
			path = "/",
			headers = {},
		})
		T.ok(recv == nil, "recv_fn is nil on failure")
		T.ok(type(err) == "string", "error is a string")
		T.ok(#err > 0, "error message is non-empty")
	end)

	T.it("request returns (nil, errmsg) for invalid host name", function()
		local res, err = https.request({
			method = "GET",
			host = "this.host.does.not.exist.invalid",
			path = "/",
			headers = {},
		})
		T.ok(res == nil, "result is nil on DNS failure")
		T.ok(type(err) == "string", "error is a string")
	end)
end)
