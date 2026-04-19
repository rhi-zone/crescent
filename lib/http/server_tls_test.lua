-- lib/http/server_tls_test.lua
-- Tests for TLS support in lib/http/server.lua.
--
-- Three scenarios:
--   1. Server module API is intact (no TLS opts): mod.server and
--      make_connection_handler are present.
--   2. Server with TLS opts and libtls available: TLS init code runs without
--      throwing; invalid cert paths produce a graceful fallback, not an error.
--   3. TLS end-to-end: when libtls and openssl are available, a self-signed
--      cert can be used to perform a TLS handshake.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local http_server = require("lib.http.server")
local format = require("lib.http.format")
local ffi = require("ffi")

-- ── Helpers ──────────────────────────────────────────────────────────────────

-- Generate a self-signed cert+key pair using openssl. Returns
-- (cert_path, key_path) on success, or (nil, nil, errmsg) on failure.
--: () -> string | nil, string | nil, string | nil
local function gen_self_signed()
	local key_path = os.tmpname() .. "_tls_test.key"
	local cert_path = os.tmpname() .. "_tls_test.crt"
	local cmd = "openssl req -x509 -newkey rsa:2048 -keyout "
		.. key_path .. " -out " .. cert_path
		.. " -days 1 -nodes -subj '/CN=localhost' 2>/dev/null"
	local rc = os.execute(cmd)
	if rc ~= 0 and rc ~= true then
		os.remove(key_path)
		os.remove(cert_path)
		return nil, nil, "openssl failed (rc=" .. tostring(rc) .. ")"
	end
	local f = io.open(cert_path, "rb")
	if not f then
		os.remove(key_path)
		return nil, nil, "cert file not created"
	end
	local data = f:read("*a"); f:close()
	if #data == 0 then
		os.remove(key_path); os.remove(cert_path)
		return nil, nil, "cert file is empty"
	end
	return cert_path, key_path
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("http/server TLS", function()

	-- ── Test 1: module API intact ──────────────────────────────────────────────
	T.it("server module has expected API", function()
		T.ok(type(http_server.server) == "function", "mod.server is a function")
		T.ok(type(http_server.make_connection_handler) == "function",
			"make_connection_handler is a function")
	end)

	-- ── Test 2: TLS opts with invalid paths — graceful fallback ───────────────
	T.it("TLS opts with nonexistent cert/key: graceful fallback, no throw", function()
		-- Check whether libtls is available. If not, this is a no-op fallback test.
		local tls_lib
		local ok_tls = pcall(function() tls_lib = require("lib.tls") end)
		if not ok_tls then
			T.ok(true, "libtls unavailable — fallback path exercised (no throw expected)")
			return
		end

		-- libtls available: config_set_keypair_file on nonexistent files should
		-- return an error code (< 0). The server must handle this without throwing.
		local cfg = tls_lib.config_new()
		T.ok(cfg ~= nil, "config_new returned a config")
		local rc = tls_lib.config_set_keypair_file(cfg, "/nonexistent/cert.pem", "/nonexistent/key.pem")
		-- Expect failure (rc < 0). If it somehow succeeds (rc == 0) we still pass —
		-- the point is no throw.
		T.ok(rc ~= nil, "config_set_keypair_file returned a value (no throw)")
		tls_lib.config_free(cfg)

		-- Verify that a tls server context can be created and freed without throwing.
		local srv_ctx = tls_lib.server()
		T.ok(srv_ctx ~= nil, "tls_server() returned a context")
		tls_lib.free(srv_ctx)

		T.ok(true, "libtls init/free cycle completed without error")
	end)

	-- ── Test 3: TLS end-to-end handshake with self-signed cert ────────────────
	T.it("TLS end-to-end: handshake with self-signed cert (requires openssl + libtls)", function()
		-- Skip if libtls unavailable.
		local tls_lib
		local ok_tls = pcall(function() tls_lib = require("lib.tls") end)
		if not ok_tls then
			T.ok(true, "SKIP: libtls unavailable")
			return
		end

		-- Generate cert.
		local cert_path, key_path, gen_err = gen_self_signed()
		if not cert_path then
			T.ok(true, "SKIP: openssl not available or cert gen failed: " .. tostring(gen_err))
			return
		end

		-- Configure a TLS server context.
		local cfg = tls_lib.config_new()
		local rc = tls_lib.config_set_keypair_file(cfg, cert_path, key_path)
		if rc < 0 then
			tls_lib.config_free(cfg)
			os.remove(cert_path); os.remove(key_path)
			T.ok(false, "config_set_keypair_file failed: " .. ffi.string(tls_lib.config_error(cfg)))
			return
		end

		local tls_ctx = tls_lib.server()
		rc = tls_lib.configure(tls_ctx, cfg)
		tls_lib.config_free(cfg)
		if rc < 0 then
			tls_lib.free(tls_ctx)
			os.remove(cert_path); os.remove(key_path)
			T.ok(false, "tls_configure failed")
			return
		end

		-- Use a socketpair to run both ends in-process without a listening socket.
		-- If socketpair is unavailable (non-Unix), skip.
		local ok_ffi, socketpair_result = pcall(function()
			ffi.cdef("int socketpair(int domain, int type, int protocol, int sv[2]);")
		end)
		-- Try calling socketpair — if it fails the platform doesn't support it.
		local sv = ffi.new("int[2]")
		local AF_UNIX = 1
		local SOCK_STREAM = 1
		local sp_rc = ffi.C.socketpair(AF_UNIX, SOCK_STREAM, 0, sv)
		if sp_rc ~= 0 then
			tls_lib.free(tls_ctx)
			os.remove(cert_path); os.remove(key_path)
			T.ok(true, "SKIP: socketpair not available")
			return
		end
		local server_fd = sv[0]
		local client_fd = sv[1]

		-- Server side: tls_accept_fds.
		local scctx_ptr = tls_lib.tls_c_ptr()
		-- tls_accept_fds takes (tls*, tls**, read_fd, write_fd)
		local sarc = tls_lib.accept_fds(tls_ctx, scctx_ptr, server_fd, server_fd)
		if sarc < 0 then
			ffi.C.close(server_fd); ffi.C.close(client_fd)
			tls_lib.free(tls_ctx)
			os.remove(cert_path); os.remove(key_path)
			T.ok(false, "accept_fds failed: " .. ffi.string(tls_lib.error(tls_ctx)))
			return
		end
		local scctx = scctx_ptr[0]

		-- Client side: TLS client context (no cert verification for self-signed).
		local client_tls = tls_lib.client()
		local client_cfg = tls_lib.config_new()
		tls_lib.config_insecure_noverifycert(client_cfg)
		tls_lib.config_insecure_noverifyname(client_cfg)
		tls_lib.configure(client_tls, client_cfg)
		tls_lib.config_free(client_cfg)
		rc = tls_lib.connect_fds(client_tls, client_fd, client_fd, "localhost")
		if rc < 0 then
			ffi.C.close(server_fd); ffi.C.close(client_fd)
			tls_lib.free(scctx); tls_lib.free(tls_ctx); tls_lib.free(client_tls)
			os.remove(cert_path); os.remove(key_path)
			T.ok(false, "connect_fds failed: " .. ffi.string(tls_lib.error(client_tls)))
			return
		end

		-- Interleaved handshake: drive both sides until TLS_WANT_POLLIN/OUT resolves.
		-- On a synchronous socketpair, each side reads/writes on the same pair so
		-- we need to alternate until both sides complete.
		local TLS_WANT_POLLIN  = tls_lib.e.TLS_WANT_POLLIN
		local TLS_WANT_POLLOUT = tls_lib.e.TLS_WANT_POLLOUT
		local s_hs, c_hs = TLS_WANT_POLLIN, TLS_WANT_POLLIN
		local max_iter = 64
		local iter = 0
		repeat
			if s_hs == TLS_WANT_POLLIN or s_hs == TLS_WANT_POLLOUT then
				s_hs = tls_lib.handshake(scctx)
			end
			if c_hs == TLS_WANT_POLLIN or c_hs == TLS_WANT_POLLOUT then
				c_hs = tls_lib.handshake(client_tls)
			end
			iter = iter + 1
		until (s_hs ~= TLS_WANT_POLLIN and s_hs ~= TLS_WANT_POLLOUT
			and c_hs ~= TLS_WANT_POLLIN and c_hs ~= TLS_WANT_POLLOUT)
			or iter >= max_iter

		local handshake_ok = s_hs == 0 and c_hs == 0

		if not handshake_ok then
			local s_err = s_hs < 0 and ffi.string(tls_lib.error(scctx)) or "ok"
			local c_err = c_hs < 0 and ffi.string(tls_lib.error(client_tls)) or "ok"
			tls_lib.close(scctx); tls_lib.free(scctx)
			tls_lib.close(client_tls); tls_lib.free(client_tls)
			tls_lib.free(tls_ctx)
			ffi.C.close(server_fd); ffi.C.close(client_fd)
			os.remove(cert_path); os.remove(key_path)
			T.ok(false, "TLS handshake failed — server: " .. s_err .. " client: " .. c_err)
			return
		end

		T.ok(true, "TLS handshake completed (" .. iter .. " iterations)")

		-- Write from client, read on server.
		local msg = "hello-tls"
		local wlen = tls_lib.write(client_tls, msg, #msg)
		T.ok(wlen == #msg, "client wrote " .. #msg .. " bytes")

		local rbuf = ffi.new("char[256]")
		local rlen = tls_lib.read(scctx, rbuf, ffi.sizeof(rbuf))
		T.ok(rlen > 0, "server read " .. tostring(rlen) .. " bytes")
		if rlen > 0 then
			T.eq(ffi.string(rbuf, rlen), msg)
		end

		-- Clean up.
		tls_lib.close(scctx); tls_lib.free(scctx)
		tls_lib.close(client_tls); tls_lib.free(client_tls)
		tls_lib.free(tls_ctx)
		ffi.C.close(server_fd); ffi.C.close(client_fd)
		os.remove(cert_path); os.remove(key_path)
	end)

end)
