if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local http_client = require("lib.platform.caps.http_client")

T.describe("caps.http_client", function()
	T.it("factory returns cap table and revoke function", function()
		local cap, revoke = http_client.http_client_cap({ host = "example.com" })
		T.ok(cap, "cap table exists")
		T.ok(revoke, "revoke function exists")
		T.eq(type(cap), "table")
		T.eq(type(revoke), "function")
	end)

	T.it("cap has request and request_stream functions", function()
		local cap = http_client.http_client_cap({ host = "example.com" })
		T.eq(type(cap.request), "function")
		T.eq(type(cap.request_stream), "function")
	end)

	T.it("requires opts.host", function()
		local ok, err = pcall(http_client.http_client_cap, {})
		T.eq(ok, false)
		T.ok(err:find("opts.host is required"), "error mentions opts.host")
	end)

	T.it("requires opts", function()
		local ok, err = pcall(http_client.http_client_cap)
		T.eq(ok, false)
		T.ok(err:find("opts.host is required"), "error mentions opts.host")
	end)

	T.it("revocation blocks request", function()
		local cap, revoke = http_client.http_client_cap({ host = "example.com" })
		revoke()
		local res, err = cap.request({ method = "GET", path = "/" })
		T.eq(res, nil)
		T.eq(err, "capability revoked")
	end)

	T.it("revocation blocks request_stream", function()
		local cap, revoke = http_client.http_client_cap({ host = "example.com" })
		revoke()
		local res, err = cap.request_stream({ method = "GET", path = "/" }, function() end)
		T.eq(res, nil)
		T.eq(err, "capability revoked")
	end)

	T.it("request validates missing request", function()
		local cap = http_client.http_client_cap({ host = "example.com" })
		local res, err = cap.request()
		T.eq(res, nil)
		T.ok(err:find("missing request"), "error mentions missing request")
	end)

	T.it("request validates missing method", function()
		local cap = http_client.http_client_cap({ host = "example.com" })
		local res, err = cap.request({ path = "/" })
		T.eq(res, nil)
		T.ok(err:find("missing method"), "error mentions missing method")
	end)

	T.it("request validates missing path", function()
		local cap = http_client.http_client_cap({ host = "example.com" })
		local res, err = cap.request({ method = "GET" })
		T.eq(res, nil)
		T.ok(err:find("missing path"), "error mentions missing path")
	end)

	T.it("request_stream validates missing on_chunk", function()
		local cap = http_client.http_client_cap({ host = "example.com" })
		local res, err = cap.request_stream({ method = "GET", path = "/" })
		T.eq(res, nil)
		T.ok(err:find("missing on_chunk"), "error mentions missing on_chunk")
	end)

	T.it("host:port parsing works (port defaults to 80)", function()
		-- We can't easily test the internal parse_host_port, but we can verify
		-- that creating a cap with host:port doesn't error
		local cap1 = http_client.http_client_cap({ host = "localhost:11434" })
		T.ok(cap1, "cap with host:port created")
		local cap2 = http_client.http_client_cap({ host = "api.openai.com" })
		T.ok(cap2, "cap with host-only created")
	end)
end)
