-- lib/platform/caps/ws_server.lua
-- ws_server_cap(opts) -> cap_table, revoke_fn
-- Inbound WebSocket server capability for sandboxed apps.
-- The platform owns the socket — the app provides a handler table.
--
-- SECURITY WARNING (see M.risk below for the operator-facing copy):
--   Granting ws_server lets the app maintain persistent WebSocket connections
--   to the user's browser. After the handshake, the app can push arbitrary
--   data at any time. The platform's cap system does NOT mediate individual
--   WebSocket messages — it only controls whether the app can accept WS
--   upgrades at all. Combined with http_server, this gives the app full
--   bidirectional communication with the browser.
--
-- Modes:
--   Standalone (default): the cap binds its own port. cap.serve(handler_table) blocks.
--     opts.port  : integer (required) — port to bind
--     opts.host  : string  (default "0.0.0.0") — bind address
--
--   Daemon: the cap does not bind; cap.serve(handler_table) records the handler
--   and returns immediately. The daemon invokes ws_accept/ws through its own
--   listener.
--     opts.daemon   : true  (enables daemon mode)
--     opts.on_serve : (handler_table) -> nil (required) — daemon callback that
--                     captures the handler_table when the app calls cap.serve()
--
-- Capability API (both modes):
--   cap.serve(handler_table) — register WS handlers.
--     handler_table.ws_accept(req) -> (true | nil, errmsg) — optional pre-handshake
--       validator; receives request, returns true or (nil, errmsg). If absent,
--       accept all WS upgrades to this app.
--     handler_table.ws(ws_conn, req) -> nil — the message loop function, called
--       per WS connection after handshake. Required.
--     Standalone: blocks, runs the socket loop.
--     Daemon: returns immediately after registering.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: ws_server_opts = { port?: integer, host?: string, daemon?: boolean, on_serve?: (unknown) -> nil }
-- ws_server_cap(opts) -> cap_table, revoke_fn
--: (ws_server_opts | nil) -> (unknown, (() -> nil) | string | nil)
function M.ws_server_cap(opts)
	if not opts then
		return nil, "ws_server: opts required"
	end

	-- Shared revocation flag. Using a table so closures share the same reference.
	local revoked_ref = { false } --: { [integer]: boolean }

	-- Daemon mode: register handler only, no socket binding.
	if opts.daemon then
		local on_serve = opts.on_serve
		if type(on_serve) ~= "function" then
			return nil, "ws_server: daemon mode requires opts.on_serve callback"
		end
		local cap = {
			_type = "ws_server",
		}
		--: (unknown) -> (true | nil, string | nil)
		function cap.serve(handler_table)
			if revoked_ref[1] then return nil, "ws_server: revoked" end
			if type(handler_table) ~= "table" then
				return nil, "ws_server: handler must be a table"
			end
			if type(handler_table.ws) ~= "function" then
				return nil, "ws_server: handler_table.ws is required and must be a function"
			end
			if handler_table.ws_accept ~= nil and type(handler_table.ws_accept) ~= "function" then
				return nil, "ws_server: handler_table.ws_accept must be a function when present"
			end
			on_serve(handler_table)
			return true
		end
		--: () -> nil
		local function revoke_daemon() revoked_ref[1] = true end
		return cap, revoke_daemon
	end

	-- Standalone mode: bind own port.
	if not opts.port then
		return nil, "ws_server: opts.port is required"
	end

	local port = opts.port
	local host = opts.host or "0.0.0.0"

	local cap = {
		_type = "ws_server",
	}

	--: (unknown) -> (true | nil, string | nil)
	function cap.serve(handler_table)
		if revoked_ref[1] then return nil, "ws_server: revoked" end
		if type(handler_table) ~= "table" then
			return nil, "ws_server: handler must be a table"
		end
		if type(handler_table.ws) ~= "function" then
			return nil, "ws_server: handler_table.ws is required and must be a function"
		end
		if handler_table.ws_accept ~= nil and type(handler_table.ws_accept) ~= "function" then
			return nil, "ws_server: handler_table.ws_accept must be a function when present"
		end

		local server_ws = require("lib.http.server_ws")
		--: { host: string | nil, tls_cert: string | nil, tls_key: string | nil, idle_timeout: number | nil, max_requests: integer | nil }
		local srv_opts = { host = host, tls_cert = nil, tls_key = nil, idle_timeout = nil, max_requests = nil }
		server_ws.server(handler_table, port, nil, srv_opts)
	end

	--: () -> nil
	local function revoke()
		revoked_ref[1] = true
	end

	return cap, revoke
end

--: (unknown) -> { severity: string, text: string }
function M.risk(_)
	return {
		severity = "high",
		text = "WARNING: Granting ws_server lets this app maintain persistent WebSocket connections to your browser. After the initial handshake, the app can push arbitrary data to connected clients at any time. WebSocket messages are not mediated by the platform's cap boundary — the cap system only controls whether the app can accept WS upgrades at all. Combined with http_server, this gives the app full bidirectional communication with the browser. Do not grant this cap to apps you do not trust.",
	}
end

return M
