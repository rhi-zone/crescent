-- lib/platform/apps/terminal_mux/server.lua
-- Terminal multiplexer platform app — entry point.
--
-- Connects browser clients to server-side PTY sessions via WebSocket.
-- Maintains VT state per session for reconnect snapshots.
--
-- Wire protocol: type-byte prefix on all WS messages.
--   0x00 = PTY data (binary), 0x01 = control (JSON text).
--
-- Client -> server:
--   0x00 + raw keystrokes              (binary)
--   0x01 + {"type":"resize",...}        (text)
--   0x01 + {"type":"attach",...}        (text)  -- not used on initial connect
--
-- Server -> client:
--   0x00 + raw PTY output              (binary)
--   0x01 + {"type":"session",...}       (text)  -- on new session
--   0x01 + {"type":"snapshot",...}      (text)  -- on reconnect
--   0x01 + {"type":"error",...}         (text)
--   0x01 + {"type":"closed"}           (text)  -- PTY exited

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local vt = require("lib.vt")

--:: require "lib.platform.caps.cap_types"
--:: require "lib.http.server_ws"
--:: require "lib.http.server"

-- ── Type declarations ─────────────────────────────────────────────────────────

--:: TermSession = {
--::   id: string,
--::   pty: PtyHandle,
--::   vt_term: Term,
--::   clients: { [integer]: WsConn },
--::   task_handle: TaskHandle | nil,
--::   rows: integer,
--::   cols: integer,
--::   dead: boolean,
--:: }

--:: TermMuxCaps = {
--::   http_server: HttpServerCap,
--::   ws_server: WsServerCap,
--::   pty: PtyCap,
--::   task: TaskCap,
--::   self: SelfCap,
--:: }

-- Sandbox global — injected by the platform before the entry script runs.
--:: declare caps = TermMuxCaps

-- Outbound control message variants.
--:: CtrlSession  = { type: "session",  id: string, rows: integer, cols: integer }
--:: CtrlSnapshot = { type: "snapshot", data: string }
--:: CtrlError    = { type: "error",    message: string }
--:: CtrlClosed   = { type: "closed" }
--:: CtrlMsg = CtrlSession | CtrlSnapshot | CtrlError | CtrlClosed

-- Inbound control message variants.
--:: CtrlResize = { type: "resize", rows: integer, cols: integer }
--:: CtrlAttach = { type: "attach", session: string }
--:: InCtrlMsg = CtrlResize | CtrlAttach

-- ── Constants ─────────────────────────────────────────────────────────────────

local DEFAULT_ROWS = 24
local DEFAULT_COLS = 80

local DATA_PREFIX = "\0"  -- 0x00
local CTRL_PREFIX = "\1"  -- 0x01

-- ── JSON helpers ──────────────────────────────────────────────────────────────
-- Minimal encode/decode for the flat control messages used by this protocol.
-- Not a general-purpose JSON library.

local str_byte = string.byte
local format = string.format

-- Escape a Lua string for embedding in a JSON string literal.
--: (string) -> string
local function json_escape(s)
	--: string
	local result = s:gsub('[%z\1-\31\\"]', function(c)
		--: string
		local ch = c
		if ch == '"' then return '\\"'
		elseif ch == '\\' then return '\\\\'
		elseif ch == '\n' then return '\\n'
		elseif ch == '\r' then return '\\r'
		elseif ch == '\t' then return '\\t'
		else return format('\\u%04x', str_byte(ch)) end
	end)
	return result
end

-- Encode specific control message types to JSON. Separate functions avoid
-- union-narrowing limitations in the typechecker.
--: (CtrlSession) -> string
local function encode_session(m)
	return '{"type":"session","id":"' .. json_escape(m.id) .. '"'
		.. ',"rows":' .. format("%d", m.rows)
		.. ',"cols":' .. format("%d", m.cols) .. '}'
end

--: (CtrlSnapshot) -> string
local function encode_snapshot(m)
	return '{"type":"snapshot","data":"' .. json_escape(m.data) .. '"}'
end

--: (CtrlError) -> string
local function encode_error(m)
	return '{"type":"error","message":"' .. json_escape(m.message) .. '"}'
end

--: () -> string
local function encode_closed()
	return '{"type":"closed"}'
end

-- Decode a client control message from JSON. Only two shapes are valid:
--   {"type":"resize","rows":N,"cols":M}
--   {"type":"attach","session":"<id>"}
--: (string) -> (InCtrlMsg | nil, string | nil)
local function decode_control(s)
	local msg_type = s:match('"type"%s*:%s*"([^"]+)"')
	if not msg_type then return nil, "missing type field" end
	if msg_type == "resize" then
		local rows_n = tonumber(s:match('"rows"%s*:%s*(%d+)'))
		local cols_n = tonumber(s:match('"cols"%s*:%s*(%d+)'))
		if not rows_n or not cols_n then return nil, "resize: missing rows/cols" end
		-- math.floor: tonumber returns `number`; the typechecker needs `integer`.
		-- The pattern `%d+` guarantees whole numbers.
		--: CtrlResize
		local result = { type = "resize", rows = math.floor(rows_n), cols = math.floor(cols_n) }
		return result
	elseif msg_type == "attach" then
		local session_id = s:match('"session"%s*:%s*"([^"]*)"')
		if not session_id then return nil, "attach: missing session" end
		--: CtrlAttach
		local result = { type = "attach", session = session_id }
		return result
	end
	return nil, "unknown control type: " .. msg_type
end

-- ── URL helpers ──────────────────────────────────────────────────────────────

-- Extract a single query parameter value from a query string.
-- Returns nil when the key is absent.
--: (string | nil, string) -> string | nil
local function query_param(qs, key)
	if not qs then return nil end
	-- Match key=value, accounting for leading ? or &
	local pattern = "[?&]?" .. key .. "=([^&]*)"
	return qs:match(pattern)
end

-- ── Session registry ──────────────────────────────────────────────────────────

local sessions = {} --: { [string]: TermSession | nil }
local session_counter = 0

--: () -> string
local function next_session_id()
	session_counter = session_counter + 1
	return tostring(session_counter)
end

-- ── Client management ─────────────────────────────────────────────────────────

-- Remove a client from a session's client list. Returns true if found.
--: (TermSession, WsConn) -> boolean
local function remove_client(session, ws_conn)
	local clients = session.clients
	for i = 1, #clients do
		if clients[i] == ws_conn then
			-- Swap-remove for O(1) deletion; order does not matter for broadcast.
			clients[i] = clients[#clients]
			clients[#clients] = nil
			return true
		end
	end
	return false
end

-- Send a pre-encoded JSON control string to a client. Errors are silently
-- ignored (the client may have disconnected between the decision to send
-- and the actual write).
--: (WsConn, string) -> nil
local function send_raw_control(ws_conn, json_str)
	pcall(ws_conn.send, ws_conn, CTRL_PREFIX .. json_str, "text")
end

-- Broadcast raw PTY data to all connected clients. Dead clients are removed.
--: (TermSession, string) -> nil
local function broadcast_data(session, data)
	local frame = DATA_PREFIX .. data
	local clients = session.clients
	local i = 1
	while i <= #clients do
		local ok = pcall(clients[i].send, clients[i], frame, "binary")
		if not ok then
			-- Swap-remove dead client.
			clients[i] = clients[#clients]
			clients[#clients] = nil
		else
			i = i + 1
		end
	end
end

-- ── Session lifecycle ─────────────────────────────────────────────────────────

-- Create a new terminal session. Spawns a PTY and a background reader task.
-- Returns the session on success, or (nil, errmsg).
--: (TermMuxCaps, integer, integer) -> (TermSession | nil, string | nil)
local function create_session(caps_t, rows, cols)
	local r = rows > 0 and rows or DEFAULT_ROWS
	local c = cols > 0 and cols or DEFAULT_COLS

	--: PtySpawnOpts
	local spawn_opts = {
		args = nil,
		rows = r,
		cols = c,
		env = { TERM = "xterm-256color" },
	}
	local pty_handle, pty_err = caps_t.pty.spawn(caps_t.pty.default_cmd, spawn_opts)
	if not pty_handle then
		return nil, "pty spawn failed: " .. tostring(pty_err)
	end

	local vt_term = vt.new(c, r)
	local id = next_session_id()

	--: TermSession
	local session = {
		id = id,
		pty = pty_handle,
		vt_term = vt_term,
		clients = {} --[[: { [integer]: WsConn }]],
		task_handle = nil,
		rows = r,
		cols = c,
		dead = false,
	}

	-- Spawn the PTY reader as a background task. It reads PTY output, feeds
	-- the VT parser, and broadcasts to connected clients.
	local task_handle, task_err = caps_t.task.spawn(function()
		while true do
			local data, read_err = pty_handle.read()
			if not data then
				-- PTY closed (child exited) or error.
				session.dead = true
				-- Notify all connected clients.
				local closed_json = encode_closed()
				for i = 1, #session.clients do
					send_raw_control(session.clients[i], closed_json)
				end
				-- Clean up the session.
				rawset(sessions, id, nil)
				return
			end
			vt_term:feed(data)
			broadcast_data(session, data)
		end
	end)

	if not task_handle then
		pty_handle.close()
		return nil, "task spawn failed: " .. tostring(task_err)
	end

	session.task_handle = task_handle
	sessions[id] = session
	return session
end

-- ── WS handlers ───────────────────────────────────────────────────────────────

-- Accept only connections to /terminal (with optional query params).
--: (HttpReq) -> (boolean | nil, string | nil)
local function ws_accept(req)
	if req.path == "/terminal" then return true end
	return nil, "not a terminal endpoint"
end

-- Per-connection WebSocket handler. Runs as a coroutine on the daemon's
-- event loop (one per connected client).
--: (TermMuxCaps) -> (ws_conn: WsConn, req: HttpReq) -> nil
local function make_ws_handler(caps_t)
	--: (WsConn, HttpReq) -> nil
	return function(ws_conn, req)
		local session_id = query_param(req.query, "session")
		local session --: TermSession | nil

		if session_id then
			-- Reconnect to existing session.
			session = sessions[session_id]
			if not session then
				send_raw_control(ws_conn, encode_error({
					type = "error",
					message = "session not found: " .. session_id,
				}))
				ws_conn:close()
				return
			end
			if session.dead then
				send_raw_control(ws_conn, encode_error({
					type = "error", message = "session has ended",
				}))
				ws_conn:close()
				return
			end
			-- Send snapshot so the client can reconstruct screen state.
			local snapshot = session.vt_term:snapshot()
			send_raw_control(ws_conn, encode_snapshot({
				type = "snapshot", data = snapshot,
			}))
		else
			-- New session.
			local new_session, err = create_session(caps_t, DEFAULT_ROWS, DEFAULT_COLS)
			if not new_session then
				send_raw_control(ws_conn, encode_error({
					type = "error",
					message = err or "failed to create session",
				}))
				ws_conn:close()
				return
			end
			session = new_session
		end

		-- At this point session is non-nil (early returns above handle nil cases).
		-- Bind to a local with a definite type.
		if not session then return end -- unreachable; satisfies narrowing
		local sess = session

		-- Add this client to the session.
		local clients = sess.clients
		clients[#clients + 1] = ws_conn

		-- Tell the client which session they are on.
		send_raw_control(ws_conn, encode_session({
			type = "session",
			id = sess.id,
			rows = sess.rows,
			cols = sess.cols,
		}))

		-- Message loop: read from WebSocket, dispatch by type byte.
		while true do
			local msg, recv_err = ws_conn:recv()
			if not msg then
				-- Client disconnected.
				remove_client(sess, ws_conn)
				return
			end

			local payload = msg.payload
			if #payload == 0 then
				-- Empty message, ignore.
			elseif str_byte(payload, 1) == 0x00 then
				-- PTY input: forward keystrokes to the PTY.
				if not sess.dead then
					local input = payload:sub(2)
					if #input > 0 then
						sess.pty.write(input)
					end
				end
			elseif str_byte(payload, 1) == 0x01 then
				-- Control message: decode JSON.
				local ctrl, decode_err = decode_control(payload:sub(2))
				if ctrl then
					if ctrl.type == "resize" then
						local new_rows = ctrl.rows
						local new_cols = ctrl.cols
						if new_rows > 0 and new_cols > 0 and not sess.dead then
							sess.rows = new_rows
							sess.cols = new_cols
							sess.pty.resize(new_rows, new_cols)
							sess.vt_term:resize(new_rows, new_cols)
						end
					end
					-- "attach" is handled at connection time via query param,
					-- not mid-session. Ignore if received here.
				end
			end
		end
	end
end

-- ── Frontend HTML ─────────────────────────────────────────────────────────────
-- Renders with xterm.js (vendored in dep/xterm-js/, symlinked into static/ —
-- see dep/xterm-js/README.md) for full terminal emulation: colors, cursor,
-- alternate screen. xterm.js parses PTY output itself, so the server sends
-- raw bytes straight through — no ANSI stripping needed here.

local FRONTEND_HTML = [==[<!doctype html>
<title>terminal mux</title>
<link rel="stylesheet" href="/xterm.css">
<style>
*{margin:0;padding:0;box-sizing:border-box}
html,body{height:100%;background:#1a1a2e;overflow:hidden}
#term{width:100%;height:100%;padding:4px 8px}
#status{position:fixed;top:4px;right:8px;font-size:11px;color:#666;font-family:sans-serif;z-index:10}
</style>
<div id="term"></div>
<div id="status">connecting...</div>
<script src="/xterm.min.js"></script>
<script src="/addon-fit.min.js"></script>
<script>
(function(){
  'use strict';
  var status = document.getElementById('status');
  var sessionId = null;
  var ws = null;
  var reconnectTimer = null;

  var term = new Terminal({
    cursorBlink: true,
    fontFamily: "'Cascadia Code','Fira Code','SF Mono','Menlo','Consolas',monospace",
    fontSize: 14,
    theme: { background: '#1a1a2e', foreground: '#e0e0e0' }
  });
  var fitAddon = new FitAddon.FitAddon();
  term.loadAddon(fitAddon);
  term.open(document.getElementById('term'));
  fitAddon.fit();

  function setStatus(msg) { status.textContent = msg; }

  function connect() {
    var url = 'ws://' + location.host + '/terminal';
    if (sessionId) url += '?session=' + encodeURIComponent(sessionId);
    setStatus('connecting...');

    ws = new WebSocket(url);
    ws.binaryType = 'arraybuffer';

    ws.onopen = function() { setStatus('connected'); };

    ws.onmessage = function(ev) {
      var data;
      if (ev.data instanceof ArrayBuffer) {
        data = new Uint8Array(ev.data);
      } else {
        // Text frame: convert to bytes.
        var enc = new TextEncoder();
        data = enc.encode(ev.data);
      }
      if (data.length === 0) return;
      var typeByte = data[0];
      var payload = data.subarray(1);
      if (typeByte === 0x00) {
        // PTY data: xterm.js parses raw bytes (including ANSI/VT sequences)
        // directly — no decoding or stripping needed.
        term.write(payload);
      } else if (typeByte === 0x01) {
        // Control message.
        var json = new TextDecoder().decode(payload);
        try {
          var msg = JSON.parse(json);
          if (msg.type === 'session') {
            sessionId = msg.id;
            setStatus('session ' + msg.id + ' (' + msg.cols + 'x' + msg.rows + ')');
          } else if (msg.type === 'snapshot') {
            // On reconnect, replace terminal content with the VT snapshot
            // (an ANSI stream that reconstructs screen state + cursor pos).
            term.reset();
            term.write(msg.data);
          } else if (msg.type === 'error') {
            setStatus('error: ' + msg.message);
          } else if (msg.type === 'closed') {
            setStatus('session ended');
            sessionId = null;
          }
        } catch(e) {}
      }
    };

    ws.onclose = function() {
      setStatus('disconnected');
      // Attempt reconnect after 2 seconds.
      if (reconnectTimer) clearTimeout(reconnectTimer);
      reconnectTimer = setTimeout(connect, 2000);
    };

    ws.onerror = function() { /* onclose will fire */ };
  }

  // Send raw keystrokes (xterm.js already encodes special/control keys into
  // the correct byte sequences) as binary with 0x00 prefix.
  term.onData(function(str) {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    var enc = new TextEncoder();
    var payload = enc.encode(str);
    var frame = new Uint8Array(1 + payload.length);
    frame[0] = 0x00;
    frame.set(payload, 1);
    ws.send(frame.buffer);
  });

  // Send a control message as text with 0x01 prefix.
  function sendControl(obj) {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    var json = JSON.stringify(obj);
    ws.send('\x01' + json);
  }

  // term.resize() (called internally by fitAddon.fit()) fires onResize;
  // forward the new dimensions to the server.
  term.onResize(function(size) {
    sendControl({ type: 'resize', rows: size.rows, cols: size.cols });
  });

  var resizeTimer = null;
  window.addEventListener('resize', function() {
    if (resizeTimer) clearTimeout(resizeTimer);
    resizeTimer = setTimeout(function() { fitAddon.fit(); }, 150);
  });

  // Initial connect.
  connect();
})();
</script>
]==]

-- ── HTTP handler ──────────────────────────────────────────────────────────────
-- Tarball-bundled static assets (vendored xterm.js/CSS, see dep/xterm-js/),
-- served via caps.self.entry("static/<name>"). Unlike optional theming
-- assets in other apps, these are required for the terminal UI to function
-- at all, so a missing entry is a 500 (loud failure), not a silent fallback.

--:: StaticAsset = { entry: string, content_type: string }
--:: StaticRoutes = { [string]: StaticAsset }

--: StaticRoutes
local STATIC_ROUTES = {
	["/xterm.min.js"]    = { entry = "static/xterm.min.js",    content_type = "application/javascript; charset=utf-8" },
	["/xterm.css"]       = { entry = "static/xterm.css",       content_type = "text/css; charset=utf-8" },
	["/addon-fit.min.js"] = { entry = "static/addon-fit.min.js", content_type = "application/javascript; charset=utf-8" },
}

--: (TermMuxCaps) -> (req: HttpReq, res: HttpRes) -> nil
local function make_http_handler(caps_t)
	--: (HttpReq, HttpRes) -> nil
	return function(req, res)
		if req.path == "/" or req.path == "/index.html" then
			res.status = 200
			res.headers["Content-Type"] = { "text/html; charset=utf-8" }
			res.body = FRONTEND_HTML
			return
		end

		local asset = STATIC_ROUTES[req.path]
		if asset then
			local content, entry_err = caps_t.self.entry(asset.entry)
			if not content then
				res.status = 500
				res.headers["Content-Type"] = { "text/plain; charset=utf-8" }
				res.body = "static asset unavailable: " .. asset.entry .. " (" .. tostring(entry_err) .. ")"
				return
			end
			res.status = 200
			res.headers["Content-Type"] = { asset.content_type }
			res.body = content
			return
		end

		res.status = 404
		res.headers["Content-Type"] = { "text/plain; charset=utf-8" }
		res.body = "not found"
	end
end

-- ── Register handlers ─────────────────────────────────────────────────────────

--: TermMuxCaps
local caps_t = caps

caps_t.http_server.serve(make_http_handler(caps_t))

local ws_handler = make_ws_handler(caps_t)
caps_t.ws_server.serve({
	ws_accept = ws_accept,
	ws = ws_handler,
})
