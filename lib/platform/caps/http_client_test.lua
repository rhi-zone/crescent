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

	T.describe("path whitelist", function()
		T.it("paths=nil allows all paths", function()
			local cap = http_client.http_client_cap({ host = "example.com" })
			-- Should not be blocked by path check (will fail later at network).
			-- We verify the error is NOT "path not allowed".
			local _, err = cap.request({ method = "GET", path = "/v2/models" })
			T.ok(not err or not err:find("path not allowed"), "nil paths allows any path")
		end)

		T.it("paths=empty table allows all paths", function()
			local cap = http_client.http_client_cap({ host = "example.com", paths = {} })
			local _, err = cap.request({ method = "GET", path = "/v2/models" })
			T.ok(not err or not err:find("path not allowed"), "empty paths allows any path")
		end)

		T.it("blocks path not in whitelist", function()
			local cap = http_client.http_client_cap({
				host  = "example.com",
				paths = { "/v1/chat/completions" },
			})
			local res, err = cap.request({ method = "GET", path = "/v2/models" })
			T.eq(res, nil)
			T.ok(err:find("path not allowed"), "error mentions path not allowed")
			T.ok(err:find("/v2/models"), "error includes the rejected path")
		end)

		T.it("allows exact path match", function()
			local cap = http_client.http_client_cap({
				host  = "example.com",
				paths = { "/v1/chat/completions", "/v1/models" },
			})
			local _, err = cap.request({ method = "GET", path = "/v1/models" })
			T.ok(not err or not err:find("path not allowed"), "exact path is allowed")
		end)

		T.it("prefix match: /v1/ allows /v1/chat/completions", function()
			local cap = http_client.http_client_cap({
				host  = "example.com",
				paths = { "/v1/" },
			})
			local _, err = cap.request({ method = "GET", path = "/v1/chat/completions" })
			T.ok(not err or not err:find("path not allowed"), "prefix match allows subpath")
		end)

		T.it("prefix match: /v1/ blocks /v2/models", function()
			local cap = http_client.http_client_cap({
				host  = "example.com",
				paths = { "/v1/" },
			})
			local res, err = cap.request({ method = "GET", path = "/v2/models" })
			T.eq(res, nil)
			T.ok(err:find("path not allowed"), "prefix does not match different root")
		end)

		T.it("entry without trailing slash does not prefix-match", function()
			-- /v1 (no slash) should not match /v1/chat; only exact /v1 is allowed
			local cap = http_client.http_client_cap({
				host  = "example.com",
				paths = { "/v1" },
			})
			local res, err = cap.request({ method = "GET", path = "/v1/chat" })
			T.eq(res, nil)
			T.ok(err:find("path not allowed"), "no-slash entry does not prefix-match")
		end)

		T.it("request_stream also enforces path whitelist", function()
			local cap = http_client.http_client_cap({
				host  = "example.com",
				paths = { "/v1/chat/completions" },
			})
			local res, err = cap.request_stream(
				{ method = "POST", path = "/v2/bad" },
				function() end
			)
			T.eq(res, nil)
			T.ok(err:find("path not allowed"), "request_stream blocks disallowed path")
		end)
	end)
end)
