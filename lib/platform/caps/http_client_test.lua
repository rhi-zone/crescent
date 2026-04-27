if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local ffi = require("ffi")
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

T.describe("caps.http_client risk", function()
	T.it("no paths has high severity", function()
		local result = http_client.risk({ type = "http_client", host = "api.example.com" })
		T.eq(result.severity, "high")
		T.ok(result.text:find("api.example.com"), "text includes host")
	end)

	T.it("with paths has medium severity", function()
		local result = http_client.risk({ type = "http_client", host = "api.example.com", paths = {"/v1"} })
		T.eq(result.severity, "medium")
		T.ok(result.text:find("api.example.com"), "text includes host")
	end)

	T.it("missing host uses fallback text", function()
		local result = http_client.risk({ type = "http_client" })
		T.ok(result ~= nil)
		T.ok(result.text:find("a configured host"), "text mentions configured host")
	end)
end)

-- ── TLS integration ───────────────────────────────────────────────────────────
-- Forks a minimal TLS HTTP server, then exercises the full TLS client path in
-- http_client_cap (tls_make_client → tls_write_all → tls_read_response).
-- Skipped when libtls or openssl are absent (CI without LibreSSL, Windows, etc.)

T.describe("caps.http_client TLS integration", function()
	T.it("TLS round-trip: request returns 200 + correct body over self-signed cert", function()
		-- Require libtls (used by http_client_cap internally; also needed for the
		-- in-process test server).
		local tls_lib
		if not pcall(function() tls_lib = require("lib.tls") end) then
			T.ok(true, "SKIP: libtls unavailable")
			return
		end

		-- Generate a self-signed cert with IP SAN so libtls hostname verification passes.
		local key_path  = os.tmpname() .. "_http_client_tls.key"
		local cert_path = os.tmpname() .. "_http_client_tls.crt"
		local openssl_cmd =
			"openssl req -x509 -newkey rsa:2048"
			.. " -keyout " .. key_path
			.. " -out "    .. cert_path
			.. " -days 1 -nodes -subj '/CN=127.0.0.1'"
			.. " -addext 'subjectAltName=IP:127.0.0.1'"
			.. " 2>/dev/null"
		local gen_rc = os.execute(openssl_cmd)
		if gen_rc ~= 0 and gen_rc ~= true then
			T.ok(true, "SKIP: openssl unavailable or cert generation failed")
			return
		end

		-- FFI: minimal POSIX socket + fork/waitpid interface.
		-- pcall guards against re-cdef errors when tests share a LuaJIT process.
		pcall(ffi.cdef, [[
			int socket(int domain, int type, int protocol);
			int setsockopt(int sockfd, int level, int optname,
			               const void *optval, unsigned int optlen);
			int bind(int sockfd, const void *addr, unsigned int addrlen);
			int listen(int sockfd, int backlog);
			int accept(int sockfd, void *addr, unsigned int *addrlen);
			int getsockname(int sockfd, void *addr, unsigned int *addrlen);
			int close(int fd);
			int fork();
			int waitpid(int pid, int *status, int options);
			void _exit(int status);
			uint16_t htons(uint16_t v);
			uint16_t ntohs(uint16_t v);
			uint32_t htonl(uint32_t v);
		]])

		local AF_INET     = 2
		local SOCK_STREAM = 1
		local SOL_SOCKET  = 1
		local SO_REUSEADDR = 2

		-- Bind to 127.0.0.1:0 (OS picks the port).
		-- sockaddr_in layout: uint16 family, uint16 port, uint32 addr, uint8[8] zero
		local addr = ffi.new("uint8_t[16]")
		ffi.cast("uint16_t*", addr)[0] = AF_INET
		ffi.cast("uint16_t*", addr)[1] = ffi.C.htons(0)          -- port = 0
		ffi.cast("uint32_t*", addr)[1] = ffi.C.htonl(0x7F000001) -- 127.0.0.1

		local srv_fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
		if srv_fd < 0 then
			os.remove(cert_path); os.remove(key_path)
			T.ok(false, "socket() failed"); return
		end

		local one = ffi.new("int[1]", { 1 })
		ffi.C.setsockopt(srv_fd, SOL_SOCKET, SO_REUSEADDR, one, ffi.sizeof("int"))

		if ffi.C.bind(srv_fd, addr, 16) ~= 0 then
			ffi.C.close(srv_fd); os.remove(cert_path); os.remove(key_path)
			T.ok(false, "bind() failed"); return
		end

		-- Retrieve the OS-assigned port.
		local bound     = ffi.new("uint8_t[16]")
		local bound_len = ffi.new("unsigned int[1]", { 16 })
		ffi.C.getsockname(srv_fd, bound, bound_len)
		local port = tonumber(ffi.C.ntohs(ffi.cast("uint16_t*", bound)[1]))

		if ffi.C.listen(srv_fd, 5) ~= 0 then
			ffi.C.close(srv_fd); os.remove(cert_path); os.remove(key_path)
			T.ok(false, "listen() failed"); return
		end

		local pid = ffi.C.fork()
		if pid < 0 then
			ffi.C.close(srv_fd); os.remove(cert_path); os.remove(key_path)
			T.ok(false, "fork() failed"); return
		end

		if pid == 0 then
			-- ── Child: minimal TLS HTTP server (handles exactly one request) ──
			local cfg = tls_lib.config_new()
			if tls_lib.config_set_keypair_file(cfg, cert_path, key_path) < 0 then
				ffi.C._exit(1)
			end
			local srv_ctx = tls_lib.server()
			if tls_lib.configure(srv_ctx, cfg) < 0 then
				tls_lib.config_free(cfg); ffi.C._exit(1)
			end
			tls_lib.config_free(cfg)

			local cli_fd = ffi.C.accept(srv_fd, nil, nil)
			ffi.C.close(srv_fd)
			if cli_fd < 0 then ffi.C._exit(1) end

			local cli_ctx_p = tls_lib.tls_c_ptr()
			if tls_lib.accept_socket(srv_ctx, cli_ctx_p, cli_fd) < 0 then
				ffi.C.close(cli_fd); ffi.C._exit(1)
			end
			local cli_ctx = cli_ctx_p[0]

			-- Drive handshake.
			local WANT_IN  = tls_lib.e.TLS_WANT_POLLIN
			local WANT_OUT = tls_lib.e.TLS_WANT_POLLOUT
			local hs = WANT_IN
			for _ = 1, 200 do
				hs = tls_lib.handshake(cli_ctx)
				if hs ~= WANT_IN and hs ~= WANT_OUT then break end
			end
			if hs ~= 0 then ffi.C.close(cli_fd); ffi.C._exit(1) end

			-- Consume request (read until double CRLF).
			local BUF = ffi.new("uint8_t[4096]")
			local req = ""
			while not req:find("\r\n\r\n", 1, true) do
				local n = tls_lib.read(cli_ctx, BUF, 4096)
				if n <= 0 then break end
				req = req .. ffi.string(BUF, n)
			end

			-- Send a minimal HTTP 200 response.
			local resp_str = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"
			local p = 1
			while p <= #resp_str do
				local n = tls_lib.write(cli_ctx, resp_str:sub(p), #resp_str - p + 1)
				if n < 0 then break end
				p = p + tonumber(n)
			end

			tls_lib.close(cli_ctx)
			tls_lib.free(cli_ctx)
			tls_lib.free(srv_ctx)
			ffi.C.close(cli_fd)
			ffi.C._exit(0)
		end

		-- ── Parent: http_client_cap TLS request ──────────────────────────────
		ffi.C.close(srv_fd)

		local cap = http_client.http_client_cap({
			host = "127.0.0.1:" .. tostring(port),
			tls  = true,
		})
		local resp, req_err = cap.request({ method = "GET", path = "/" })

		local wstatus = ffi.new("int[1]")
		ffi.C.waitpid(pid, wstatus, 0)
		local child_ok = math.floor(tonumber(wstatus[0]) / 256) == 0

		os.remove(cert_path); os.remove(key_path)

		if not resp then
			T.ok(false, "TLS request failed: " .. tostring(req_err))
			return
		end
		T.eq(resp.status, 200, "HTTP status is 200")
		T.eq(resp.body, "hello", "response body is correct")
		T.ok(child_ok, "server child exited cleanly")
	end)
end)
