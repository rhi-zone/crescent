-- lib/platform/daemon/init.lua
-- Platform daemon v1 HTTP skeleton.
--
-- Single-port listener. Routes by Host header to one of:
--   - daemon origin  (e.g. "localhost:7777")    → library app + future grant UI
--   - app-<id>.host  (e.g. "app-alice.localhost:7777") → per-app handler (stub)
--   - 127.0.0.<n>:port loopback fallback         → treated as app <n>
--
-- v1 scope is intentionally narrow. NOT implemented here:
--   launch tokens, grant UI, CSRF, rate limiting, CSP emission, per-app VM
--   host, audit log, TLS, admin policy. See docs/daemon-design.md and the
--   "daemon v1" entries in TODO.md for the bring-up sequence.
--
-- Capability-based I/O: the daemon accepts injected time / random / socket /
-- getenv functions via opts. It does not reach for globals. This matches the
-- project-wide rule in CLAUDE.md ("Capability-based I/O") and keeps the
-- daemon testable without a real socket.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local router = require("lib.router")
local url = require("lib.url")
local library = require("lib.platform.apps.library.server")

local M = {}

--:: http_req = { method: string | nil, path: string | nil, query: string | nil, headers: { [string]: string[] } | nil, body: string | nil }
--:: http_res = { status: integer | nil, headers: { [string]: unknown }, body: string | nil }
--:: host_class = { kind: "daemon" | "app" | "unknown", id: string | nil, loopback: boolean | nil }
--:: app_handler_fn = (http_req, http_res) -> nil
--:: maybe_app_handler = app_handler_fn | nil
--:: app_loader_fn = (string) -> (maybe_app_handler, string | nil)
--:: source_entry = { id: string, name: string, discover: (({ [string]: string }) -> unknown) }
--:: daemon_opts = {
--::   host: string | nil,
--::   time_fn: (() -> integer) | nil,
--::   random_bytes_fn: ((n: integer) -> { [integer]: number }) | nil,
--::   index_db: unknown,
--::   remove_fn: ((path: string) -> (true | nil, string | nil)) | nil,
--::   sources: { [integer]: source_entry } | nil,
--::   app_handler: ((http_req, http_res, string) -> nil) | nil,
--::   app_loader: app_loader_fn | nil,
--::   handler_cache_size: integer | nil,
--::   secure_cookie: boolean | nil,
--::   prefer_loopback: boolean | nil,
--::   on_handler_error: ((app_id: string, err: string, traceback: string) -> nil) | nil,
--:: }
--:: session_record = { created_at: integer, last_seen: integer }
--:: launch_token_record = { app_id: string, session_id: string, expires_at: integer }
--:: app_session_record = { app_id: string, created_at: integer, last_seen: integer }
--:: daemon = {
--::   handle: (http_req, http_res) -> nil,
--::   register_app: (string) -> string,
--::   sessions: { [string]: session_record },
--::   launch_tokens: { [string]: launch_token_record },
--::   app_sessions: { [string]: { [string]: app_session_record } },
--::   loopback_id_to_ip: { [string]: string },
--::   loopback_ip_to_id: { [string]: string },
--::   _host: string,
--::   _library_app: unknown,
--:: }

-- ── Helpers ────────────────────────────────────────────────────────────────

-- Lowercase and strip surrounding whitespace. Host header is case-insensitive
-- per RFC 9110 §4.2.3; normalise before matching.
--: (string | nil) -> string
local function norm_host(h)
	if not h then return "" end
	return (h:lower():gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Extract the first Cookie header value for a given cookie name, or nil.
-- headers is { [lower_name]: string[] } (see lib/http/format.lua).
-- Cookies are whitespace-separated "name=value; name2=value2".
--: ({ [string]: string[] }, string) -> string | nil
local function get_cookie(headers, name)
	if not headers then return nil end
	local arr = headers["cookie"]
	if not arr then return nil end
	for i = 1, #arr do
		local cookie_str = arr[i]
		-- Walk `name=val; name=val; ...`
		for k, v in cookie_str:gmatch("([^=;%s]+)=([^;]*)") do
			if k == name then
				-- Trim leading/trailing whitespace from value.
				return (v:gsub("^%s+", ""):gsub("%s+$", ""))
			end
		end
	end
	return nil
end
M._get_cookie = get_cookie

-- Build a hex string from a sequence of byte-valued integers. Used for
-- session IDs (16 bytes → 32 hex chars).
--: ({ [integer]: number }) -> string
local function bytes_to_hex(bytes)
	local parts = {} --: { [integer]: string }
	for i = 1, #bytes do
		parts[i] = string.format("%02x", bytes[i] % 256)
	end
	return table.concat(parts)
end
M._bytes_to_hex = bytes_to_hex

-- Classify the Host header:
--   "127.0.0.<n>:port" → { kind = "app", id = "<n>", loopback = true }
--   "app-<id>.<rest>"  → { kind = "app", id = "<id>" }
--   "<daemon_host>"    → { kind = "daemon" }
-- Unknown → { kind = "unknown" }.
--
-- daemon_host is the operator-configured canonical host (e.g. "localhost:7777").
-- Matching is case-insensitive on daemon_host; port is compared exactly if
-- present on both sides. For the loopback branch we do NOT require the daemon
-- port to match (the daemon listens on one port but may be addressed by any of
-- its loopback aliases — see docs/daemon-design.md "Distinct loopback
-- addresses" fallback).
--: (string, string, { [string]: string }) -> host_class
function M.classify_host(host, daemon_host, loopback_ip_to_id)
	host = norm_host(host)
	daemon_host = norm_host(daemon_host)
	if host == "" then return { kind = "unknown", id = nil, loopback = nil } end
	if host == daemon_host then return { kind = "daemon", id = nil, loopback = nil } end

	-- "app-<id>.<suffix>"  — <suffix> must be the daemon_host's hostname part
	-- (we don't require the port to match because subdomain cookies ignore
	-- port anyway; daemon_host's hostname is what we're pivoting on).
	local daemon_name = daemon_host:match("^([^:]+)") or daemon_host
	local id, suffix = host:match("^app%-([^.]+)%.(.+)$")
	if id and suffix then
		local suffix_name = suffix:match("^([^:]+)") or suffix
		if suffix_name == daemon_name then
			return { kind = "app", id = id, loopback = nil }
		end
	end

	-- Loopback-IP fallback: 127.0.0.<n>[:port].
	local ip = host:match("^(127%.0%.0%.%d+)")
	if ip and loopback_ip_to_id then
		local mapped = loopback_ip_to_id[ip]
		if mapped then
			return { kind = "app", id = mapped, loopback = true }
		end
	end

	return { kind = "unknown", id = nil, loopback = nil }
end

-- ── Daemon construction ────────────────────────────────────────────────────

-- make(opts) -> daemon
--
-- opts:
--   host           : string — canonical daemon host, e.g. "localhost:7777"
--   time_fn        : () -> integer — seconds since epoch (injected)
--   random_bytes_fn: (integer) -> { [integer]: number } — n random bytes 0..255
--   index_db       : unknown | nil — handle passed to the library app's `caps.index_db`
--   app_handler    : ((req, res, app_id) -> nil) | nil — direct override for
--                    app-origin requests. Primarily for tests. If set, skips
--                    app_loader entirely.
--   app_loader     : (app_id) -> handler, err | nil — on-demand factory that
--                    returns a (req, res) handler for the app. Called once per
--                    app_id; the result is cached. Returning nil + err produces
--                    a 500 response. If neither app_loader nor app_handler is
--                    provided, app-origin requests return the v1 stub response.
--
-- Returned daemon:
--   d.handle(req, res)        — top-level request handler (Host-based dispatch)
--   d.register_app(id)        — reserve a loopback IP for app <id>, returns ip
--   d.sessions                — in-memory session store (exposed for tests)
--   d.loopback_id_to_ip       — exposed for tests
--   d.loopback_ip_to_id       — exposed for tests
--
-- Seams left for future work (track steps 2+):
--   - `app_handler` will be replaced by the per-app VM host (step 2).
--   - The daemon router's `/grant/*` and `/auth/*` prefixes are reserved but
--     unimplemented — the route tree has room but no handlers.
--: (daemon_opts) -> daemon
function M.make(opts)
	local host = opts.host or "localhost:7777"
	local time_fn = opts.time_fn or os.time --: () -> integer
	--:: bytes_fn = (n: integer) -> { [integer]: number }
	local random_bytes_fn --: bytes_fn
	if opts.random_bytes_fn then
		random_bytes_fn = opts.random_bytes_fn
	else
		-- Default: lib/rand, which uses getrandom(2) or /dev/urandom. On
		-- platforms where neither is available (e.g. no ffi, or Windows
		-- without the cryptography shim) we fall back to math.random —
		-- NOT cryptographically secure, suitable only for local dev. A
		-- routable-interface deployment MUST inject `random_bytes_fn`.
		--: (integer) -> { [integer]: number }
		local function insecure(n)
			local out = {} --: { [integer]: number }
			for i = 1, n do
				out[i] = math.random(0, 255)
			end
			return out
		end
		local ok_rand, rand = pcall(require, "lib.rand")
		if ok_rand then
			-- Probe at startup so we know the CSPRNG path actually works
			-- before a session mint first relies on it.
			local probe = rand.bytes(1)
			if probe then
				random_bytes_fn = function(n)
					local s = rand.bytes(n)
					if not s then return insecure(n) end
					local out = {} --: { [integer]: number }
					for i = 1, n do out[i] = s:byte(i) end
					return out
				end
			else
				random_bytes_fn = insecure
			end
		else
			random_bytes_fn = insecure
		end
	end
	-- `any` is a deliberate escape hatch: the library app's `caps.index_db`
	-- is a SQLite handle, a nil, or a test stub; we don't want to bake a
	-- schema here. Library app tolerates nil.
	local index_db = opts.index_db --: any
	-- Injected for testability. Defaults to os.remove.
	--: (string) -> (true | nil, string | nil)
	local remove_fn = opts.remove_fn or os.remove

	-- Library app handler. The daemon mounts the library app at "/" of the
	-- daemon origin. We call create() directly; there is no sandbox in v1
	-- because the library is first-party trusted code running in-process.
	-- Future: the library could move to the same VM-host model as untrusted
	-- apps, but for v1 the seam is just the handler pointer.
	-- library.create expects `caps.index_db` to be a SQLite-like handle (with a
	-- :query method) or nil. We propagate whatever the caller passed — library
	-- tolerates nil and falls back to an empty list.
	local library_app = library.create({ index_db = index_db, sources = opts.sources }) --: { handler: (http_req, http_res) -> (boolean | nil) }

	-- App-origin handler. Three modes, in priority order:
	--   1. opts.app_handler — direct override (tests use this to bypass loading).
	--   2. opts.app_loader  — on-demand factory; result is cached per app_id.
	--   3. v1 stub — informational response for unconfigured daemons.
	-- Normalizes string header values to { string } arrays on the way out so
	-- downstream serialize_response (which expects array form after f3e01b9)
	-- does not throw on handlers that set plain strings.
	--: ({ [string]: unknown }) -> nil
	local function normalize_headers(headers)
		if not headers then return end
		for k, v in pairs(headers) do
			if type(v) == "string" then
				headers[k] = { v }
			end
		end
	end

	-- LRU cache for loaded app handlers. Bounded size prevents unbounded
	-- growth on a daemon that has served a large number of distinct apps
	-- over its lifetime (e.g. during local iteration — edit, reinstall
	-- under a new rowid, try again). Eviction drops the closure so the
	-- next request for that app_id re-runs the loader. Default 64 is a
	-- guess; override via `handler_cache_size` if you actually serve
	-- many apps concurrently.
	local cache = require("lib.cache")
	local handler_cache_cap = opts.handler_cache_size or 64
	local app_handlers = assert(cache.new(handler_cache_cap)) --: unknown

	-- Negative cache for load failures. Retained across requests so a broken
	-- app doesn't retrigger tarball parsing on every hit, but each entry has
	-- a TTL so transient failures (e.g. a partially-written tarball during
	-- `pkg install`) recover without operator intervention.
	local app_load_errors = {} --: { [string]: { err: string, retry_at: integer } }
	local LOAD_ERROR_TTL = 5 -- seconds; see docs/daemon-design.md

	-- Per-request handler invocation. App handlers are untrusted code running
	-- in the daemon process; an uncaught `error()` must not bubble past the
	-- request loop. On failure: 500 with a fixed body (never the actual
	-- error message — that's operator-visible only, per daemon-isolation.md).
	-- The optional `on_handler_error` callback receives (app_id, err, tb) so
	-- operators see the crash on stderr while clients see a clean 500.
	--: (string, (http_req, http_res) -> nil, http_req, http_res) -> nil
	local function invoke_app_handler(app_id, fn, req, res)
		local tb --: string
		local function tb_handler(err)
			tb = debug.traceback(tostring(err), 2)
			return err
		end
		local ok, err = xpcall(function() fn(req, res) end, tb_handler)
		if not ok then
			res.status = 500
			res.headers["Content-Type"] = { "text/plain; charset=utf-8" }
			res.body = "internal server error"
			if opts.on_handler_error then
				opts.on_handler_error(app_id, tostring(err), tb or "")
			end
			return
		end
		normalize_headers(res.headers)
	end

	local app_handler --: (http_req, http_res, string) -> nil
	if opts.app_handler then
		local override = opts.app_handler --: (http_req, http_res, string) -> nil
		--: (http_req, http_res, string) -> nil
		app_handler = function(req, res, app_id)
			invoke_app_handler(app_id, function(rq, rs) override(rq, rs, app_id) end, req, res)
		end
	elseif opts.app_loader then
		local loader = opts.app_loader --: app_loader_fn
		--: (http_req, http_res, string) -> nil
		app_handler = function(req, res, app_id)
			local cached = app_handlers:get(app_id) --: ((http_req, http_res) -> nil) | nil
			if cached then
				invoke_app_handler(app_id, cached, req, res)
				return
			end
			local cached_err = app_load_errors[app_id]
			if cached_err then
				if time_fn() < cached_err.retry_at then
					res.status = 500
					res.headers["Content-Type"] = { "text/plain; charset=utf-8" }
					res.body = "app load failed: " .. cached_err.err
					return
				end
				rawset(app_load_errors, app_id, nil)
			end
			local handler, err = loader(app_id)
			if not handler then
				local msg = tostring(err or "unknown error")
				app_load_errors[app_id] = { err = msg, retry_at = time_fn() + LOAD_ERROR_TTL }
				res.status = 500
				res.headers["Content-Type"] = { "text/plain; charset=utf-8" }
				res.body = "app load failed: " .. msg
				return
			end
			-- `assert` is the idiomatic narrowing cast: returns its first arg if
			-- truthy, raises otherwise. Unreachable here because of the check
			-- above, but the typechecker cannot narrow `handler` across the
			-- tuple-return + early-return boundary, so we re-state the invariant.
			local fn = assert(handler)
			-- Cache BEFORE invoking: a throwing handler must not be evicted.
			app_handlers:set(app_id, fn)
			invoke_app_handler(app_id, fn, req, res)
		end
	else
		--: (http_req, http_res, string) -> nil
		app_handler = function(req, res, app_id)
			res.status = 200
			res.headers["Content-Type"] = { "text/plain; charset=utf-8" }
			res.body = "app " .. tostring(app_id) .. " not yet mountable — VM host pending"
		end
	end

	-- Daemon-origin router. Reserved prefixes: /grant/*, /auth/* (future).
	-- /launch/:id is registered inside `make` (below) once all closure state
	-- is in scope.
	local r = router.new()
	r:get("/healthz",
		--: (http_req, http_res) -> nil
		function(req, res)
			res.status = 200
			res.headers["Content-Type"] = { "text/plain; charset=utf-8" }
			res.body = "ok"
		end)

	-- Session store: in-memory only for v1. { [sid] = { created_at, last_seen } }.
	local sessions = {} --: { [string]: session_record }
	local SESSION_IDLE_TTL = 86400 -- 24h; drops sessions that haven't been seen in this long

	-- Launch-token map: { [hex_token] = { app_id, session_id, expires_at } }.
	-- One-shot: consumed (deleted) on first redemption. 5-min expiry.
	-- v1 does not garbage-collect stale entries (next bring-up step). If/when
	-- this starts to bloat, sweep at mint-time or add a dedicated reaper.
	-- TODO.md: "Launch flow — token reaping".
	local launch_tokens = {} --: { [string]: launch_token_record }

	-- Per-app session store, keyed by app_id then session token.
	-- { [app_id] = { [token] = { app_id, created_at, last_seen } } }.
	-- Separate from `sessions` because the two cookies authorize different
	-- surfaces and must not be interchangeable. See docs/daemon-design.md
	-- "Per-app subdomain (canonical)".
	local app_sessions = {} --: { [string]: { [string]: app_session_record } }
	local APP_SESSION_IDLE_TTL = 86400 -- 24h; mirrors SESSION_IDLE_TTL semantics

	-- Loopback mapping: app_id <-> 127.0.0.<n>. <n> starts at 2 (127.0.0.1 is
	-- the daemon). Grows monotonically; v1 does not reclaim.
	local loopback_id_to_ip = {} --: { [string]: string }
	local loopback_ip_to_id = {} --: { [string]: string }
	local next_loopback_n = 2

	-- register_app(id) -> ip. Assigns a loopback IP for this app id (idempotent).
	--: (string) -> string
	local function register_app(id)
		local existing = loopback_id_to_ip[id]
		if existing then return existing end
		local ip = "127.0.0." .. tostring(next_loopback_n)
		next_loopback_n = next_loopback_n + 1
		loopback_id_to_ip[id] = ip
		loopback_ip_to_id[ip] = id
		return ip
	end

	-- Mint a new session and record it. Returns the session id (hex string).
	-- Sweeps idle sessions before mint — same amortized pattern as launch
	-- tokens. Session records are tiny; a 24h-idle one is almost certainly
	-- a closed browser tab that will never reconnect, so dropping it is
	-- both harmless and bounds the map.
	--: () -> string
	local function mint_session()
		local now = time_fn()
		for s, rec in pairs(sessions) do
			if now - rec.last_seen >= SESSION_IDLE_TTL then
				rawset(sessions, s, nil)
			end
		end
		local sid = bytes_to_hex(random_bytes_fn(16))
		sessions[sid] = { created_at = now, last_seen = now }
		return sid
	end

	-- App-index lookup: does this app_id exist in the index DB?
	-- We query the raw SQLite handle (not the wrapped index object) — the
	-- daemon accepts an unwrapped handle per the skeleton convention.
	-- `any` here is the same escape hatch justified at `index_db = opts.index_db`
	-- (mixed handle/nil/stub callsite).
	--: (string) -> boolean
	local function app_exists(app_id)
		if not index_db then return false end
		local db = index_db --: any
		local ok, iter = pcall(db.query, db, "SELECT 1 FROM apps WHERE id = ? LIMIT 1", app_id)
		if not ok or not iter then return false end
		local row = iter()
		return row ~= nil
	end

	local parse_query_string = url.parse_query

	-- Build the Set-Cookie value for __Host-session=<sid>. Skip `Secure` when
	-- the listener binds to loopback without TLS — browsers reject `Secure`
	-- cookies sent over plain http://, so `__Host-` + `Secure` would prevent
	-- the daemon from working at all on localhost. On routable interfaces the
	-- daemon MUST front TLS and re-enable Secure.
	-- See docs/daemon-design.md "Session token confidentiality: keep the
	-- token out of JS reach" for the full rationale.
	--: (string) -> string
	local function build_session_cookie(sid)
		-- RFC 6265bis — __Host- prefix forbids Domain and requires Path=/.
		-- HttpOnly hides the value from document.cookie.
		-- SameSite=Strict stops cross-site navigation from carrying the cookie.
		if opts.secure_cookie then
			return "__Host-session=" .. sid .. "; HttpOnly; Secure; SameSite=Strict; Path=/"
		end
		return "__Host-session=" .. sid .. "; HttpOnly; SameSite=Strict; Path=/"
	end

	-- App-origin session cookie. Different name from the daemon-origin cookie
	-- so browsers (and humans reading headers) can never confuse the two —
	-- they authorize different surfaces (daemon admin vs the running app).
	-- Scoped to the app origin: the cookie is set in a response from the
	-- app origin, so the browser pins it there.
	--: (string, string) -> string
	local function build_app_session_cookie(app_id, token)
		local name = "__Host-app-session-" .. app_id
		if opts.secure_cookie then
			return name .. "=" .. token .. "; HttpOnly; Secure; SameSite=Strict; Path=/"
		end
		return name .. "=" .. token .. "; HttpOnly; SameSite=Strict; Path=/"
	end

	-- Compute the launch target origin URL for app <id>. Subdomain form is
	-- canonical (`app-<id>.<daemon-host>`); loopback-IP form (`127.0.0.<n>`)
	-- is the fallback for environments without wildcard DNS. Caller selects
	-- via `opts.prefer_loopback`; when true we also register the app's IP
	-- so `classify_host` will route future requests to that app.
	--: (string) -> string
	local function launch_origin_url(app_id)
		if opts.prefer_loopback then
			local ip = register_app(app_id)
			-- Preserve the daemon's port part (if any) when building the URL.
			local port = host:match(":(%d+)$")
			if port then
				return "http://" .. ip .. ":" .. port
			end
			return "http://" .. ip
		end
		return "http://app-" .. app_id .. "." .. host
	end
	M._launch_origin_url = launch_origin_url

	-- POST a plain-text response.
	--: (http_res, integer, string) -> nil
	local function plain(res, status, body)
		res.status = status
		res.headers["Content-Type"] = { "text/plain; charset=utf-8" }
		res.body = body
	end

	-- /launch/:id — mint a one-shot launch token bound to the current session
	-- and 303-redirect to the app origin with `?__launch=<hex>`. The browser
	-- follows the redirect; the app-origin branch below consumes the token
	-- and issues the per-app session cookie.
	--
	-- Security:
	--   - Requires an EXISTING session cookie. Missing/unknown → 401, NO new
	--     session minted (the skeleton would normally auto-mint here; the
	--     launch path opts out because "can navigate to /launch" is stronger
	--     authority than "has any cookie at all").
	--   - Sec-Fetch-Dest must be `document` — this is a top-level navigation,
	--     not a fetch/image/script. Anything else → 400. Cheap layered defense
	--     on top of SameSite=Strict.
	--   - Why GET + session cookie is sufficient (no CSRF token needed):
	--     SameSite=Strict on the daemon session cookie means cross-site
	--     navigations do not carry it, so a third-party page's
	--     `<a href>`/`<img src>`/etc. arriving here will have no cookie →
	--     401, not a redirect. See docs/daemon-design.md.
	--   - TODO: rate limiting on /launch (tracked in TODO.md as "Rate limiting"
	--     under the platform daemon track).
	--
	-- Error cases:
	--   401 no / invalid session       400 wrong Sec-Fetch-Dest
	--   404 app id not in index        500 shouldn't reach (empty :id slot)
	--: (http_req, http_res) -> nil
	r:get("/launch/:id", function(req, res)
		local req_headers = req.headers or {}
		local presented = get_cookie(req_headers, "__Host-session")
		local sess_rec = presented and sessions[presented] or nil
		if not sess_rec or (time_fn() - sess_rec.last_seen) >= SESSION_IDLE_TTL then
			if sess_rec and presented then rawset(sessions, presented, nil) end
			plain(res, 401, "unauthorized")
			return
		end

		local sfd_arr = req_headers["sec-fetch-dest"]
		local sfd = sfd_arr and sfd_arr[1]
		-- Accept a missing Sec-Fetch-Dest (old browsers, curl) to avoid
		-- breaking non-browser smoke tests. When present, it must be `document`.
		if sfd and sfd ~= "document" then
			plain(res, 400, "launch requires top-level navigation")
			return
		end

		local app_id = (req.path or ""):match("^/launch/(.+)$")
		if not app_id or app_id == "" then
			plain(res, 404, "app not found")
			return
		end

		if not app_exists(app_id) then
			plain(res, 404, "app not found")
			return
		end

		-- Sweep expired tokens before minting. Amortized cheap — mint is a
		-- user-initiated action (operator clicks Launch), so N runs in the
		-- hundreds at most for a single-operator local daemon. Revisit if
		-- the daemon ever serves many concurrent operators.
		local now = time_fn()
		for t, rec in pairs(launch_tokens) do
			if rec.expires_at <= now then
				rawset(launch_tokens, t, nil)
			end
		end

		-- Mint: 16 random bytes → 32 hex chars. Collisions are vanishingly
		-- unlikely at the 5-minute expiry window, but we still guard with a
		-- bounded retry loop in case a mock RNG (tests) produces duplicates.
		local token --: string
		for _ = 1, 8 do
			local candidate = bytes_to_hex(random_bytes_fn(16))
			if not launch_tokens[candidate] then
				token = candidate
				break
			end
		end
		if not token then
			plain(res, 500, "launch token mint failed")
			return
		end

		launch_tokens[token] = {
			app_id = app_id,
			session_id = presented,
			expires_at = now + 300, -- 5 minutes
		}

		local origin = launch_origin_url(app_id)
		res.status = 303
		res.headers["Location"] = { origin .. "/?__launch=" .. token }
		res.headers["Content-Type"] = { "text/plain; charset=utf-8" }
		-- Keep the token out of the Referer that an app's first page might
		-- leak if it fetches a third-party resource on first paint.
		res.headers["Referrer-Policy"] = { "no-referrer" }
		res.body = ""
	end)

	-- DELETE /api/apps/:id — uninstall an app from the index and disk.
	--
	-- Requires an existing valid session (same policy as /launch — destructive
	-- ops must not be reachable via auto-minted sessions from anonymous requests).
	-- File deletion failure is non-fatal: the index row is already gone so the
	-- app is effectively uninstalled. The operator sees the error via
	-- on_handler_error if configured.
	r:delete("/api/apps/:id", function(req, res)
		local req_headers = req.headers or {}
		local presented = get_cookie(req_headers, "__Host-session")
		local sess_rec = presented and sessions[presented] or nil
		if not sess_rec or (time_fn() - sess_rec.last_seen) >= SESSION_IDLE_TTL then
			if sess_rec and presented then rawset(sessions, presented, nil) end
			plain(res, 401, "unauthorized")
			return
		end

		local app_id_str = (req.path or ""):match("^/api/apps/(.+)$")
		local app_id = tonumber(app_id_str)
		if not app_id then
			plain(res, 400, "invalid app id")
			return
		end

		if not index_db then
			plain(res, 503, "index unavailable")
			return
		end

		local db = index_db --: any
		local ok_q, iter = pcall(db.query, db, "SELECT path FROM apps WHERE id = ? LIMIT 1", app_id)
		if not ok_q or not iter then
			plain(res, 404, "app not found")
			return
		end
		local app_path = iter()
		if not app_path then
			plain(res, 404, "app not found")
			return
		end

		db:execute("DELETE FROM app_tags WHERE app_id = ?", app_id)
		db:execute("DELETE FROM apps_fts WHERE rowid = ?", app_id)
		db:execute("DELETE FROM apps WHERE id = ?", app_id)

		local ok_rm, rm_err = remove_fn(app_path)
		if not ok_rm and opts.on_handler_error then
			opts.on_handler_error("library",
				"uninstall " .. tostring(app_path) .. ": " .. tostring(rm_err), "")
		end

		res.status = 200
		res.headers["Content-Type"] = { "application/json" }
		res.body = '{"ok":true}'
	end)

	-- App-origin: consume a presented `?__launch=<hex>` token, issue the
	-- per-app session cookie, and clean-URL-redirect to "/". If the request
	-- already carries the per-app session cookie AND has no __launch, fall
	-- through to the (stub) app handler.
	--: (http_req, http_res, string) -> boolean
	local function consume_launch_if_present(req, res, app_id)
		local path = req.path or "/"
		local qs_from_path = path:match("%?(.+)$")
		local qs = req.query or qs_from_path
		local params = parse_query_string(qs)
		local token = params["__launch"]
		if not token then return false end

		local rec = launch_tokens[token]
		-- Consume even on failure — one-shot policy. If the token existed but
		-- was stale/wrong-app, burning it prevents a racing replay from the
		-- same operator re-submitting after a time jump.
		-- `rawset` sidesteps the typechecker's "cannot assign nil" on a
		-- map-of-record; Lua's delete-via-nil-assignment is a runtime idiom
		-- that the static type system deliberately rejects.
		if rec then rawset(launch_tokens, token, nil) end

		if not rec then
			plain(res, 403, "launch token invalid or expired")
			return true
		end
		if rec.app_id ~= app_id then
			plain(res, 403, "launch token invalid or expired")
			return true
		end
		local now = time_fn()
		if now >= rec.expires_at then
			plain(res, 403, "launch token invalid or expired")
			return true
		end

		-- Mint an app-session token. Same 16-byte hex shape as the daemon
		-- session; different store + different cookie name, different origin.
		local app_tok = bytes_to_hex(random_bytes_fn(16))
		local bucket = app_sessions[app_id]
		if not bucket then
			bucket = {} --: { [string]: app_session_record }
			app_sessions[app_id] = bucket
		else
			-- Sweep-on-mint: bound the bucket by discarding idle tokens.
			-- Mint frequency is per-launch (operator action), so this is rare.
			for t, r0 in pairs(bucket) do
				if (now - r0.last_seen) >= APP_SESSION_IDLE_TTL then
					rawset(bucket, t, nil)
				end
			end
		end
		bucket[app_tok] = { app_id = app_id, created_at = now, last_seen = now }

		local cookie = build_app_session_cookie(app_id, app_tok)
		local existing = res.headers["Set-Cookie"]
		if type(existing) == "table" then
			existing[#existing + 1] = cookie
		else
			res.headers["Set-Cookie"] = { cookie }
		end

		-- Clean URL: drop the ?__launch query param. 303 See Other sends the
		-- browser back to the same origin at "/" with a GET, no query string.
		res.status = 303
		res.headers["Location"] = { "/" }
		res.headers["Content-Type"] = { "text/plain; charset=utf-8" }
		res.body = ""
		return true
	end

	-- Daemon-origin request: session middleware + path router + library fallback.
	--: (http_req, http_res) -> nil
	local function handle_daemon(req, res)
		-- Session: look up existing, mint on miss EXCEPT on /launch/* — that path
		-- requires prior authority (came-from-library), so a missing/invalid
		-- session must fail cleanly with 401 rather than auto-minting. The
		-- canonical flow reaches /launch with a cookie already set by the
		-- operator's previous visit to the library. Direct address-bar paste of
		-- /launch/<id> is not a supported entry point.
		local req_headers = req.headers or {}
		local presented = get_cookie(req_headers, "__Host-session")
		local path = req.path or "/"
		local is_launch_path = path:sub(1, 8) == "/launch/"
		local sid --: string | nil
		local minted = false
		local now = time_fn()
		local sess_rec = presented and sessions[presented] or nil
		if sess_rec and (now - sess_rec.last_seen) >= SESSION_IDLE_TTL then
			-- Stale cookie: drop it and treat as unauthenticated. On non-launch
			-- paths this falls through to mint_session (which also sweeps).
			if presented then rawset(sessions, presented, nil) end
			sess_rec = nil
		end
		if sess_rec and presented then
			sid = presented
			sess_rec.last_seen = now
		elseif not is_launch_path then
			sid = mint_session()
			minted = true
		end

		-- Router first (internal daemon endpoints like /healthz, future /grant/*).
		local match = r:find(req.method or "GET", req.path or "/")
		if match then
			local h = match.handler --: (http_req, http_res) -> nil
			h(req, res)
		else
			-- Mount the library app at the root of the daemon origin. The
			-- library app's handler may itself return nil for unknown paths;
			-- in that case we fall through to a 404.
			library_app.handler(req, res)
			if res.status == nil then
				res.status = 404
				res.headers["Content-Type"] = { "text/plain; charset=utf-8" }
				res.body = "not found"
			end
		end

		-- Attach the Set-Cookie on mint ONLY. If the session already existed,
		-- we don't re-issue the cookie — the browser already has it.
		if minted and sid then
			local cookie = build_session_cookie(sid)
			local existing = res.headers["Set-Cookie"]
			if type(existing) == "table" then
				existing[#existing + 1] = cookie
			else
				res.headers["Set-Cookie"] = { cookie }
			end
		end
	end

	-- Top-level Host dispatch.
	--: (http_req, http_res) -> nil
	local function handle(req, res)
		local headers = req.headers or {}
		local host_arr = headers["host"]
		local host_val = host_arr and host_arr[1] or ""
		local classified = M.classify_host(host_val, host, loopback_ip_to_id)

		if classified.kind == "daemon" then
			handle_daemon(req, res)
			return
		end
		if classified.kind == "app" then
			-- IMPORTANT: App-origin responses do NOT set or require the
			-- __Host-session cookie. Apps get their own session story later.
			-- See docs/daemon-design.md "Per-app subdomain (canonical)".
			local app_id = classified.id or ""
			-- Launch-token redemption: presented `?__launch=<hex>` is always
			-- handled before the stub app handler sees the request. On valid
			-- redemption, we 303 to "/"; on any failure, we 403. The app
			-- handler is invoked only when no `__launch` param is present.
			if consume_launch_if_present(req, res, app_id) then return end
			app_handler(req, res, app_id)
			return
		end
		-- Unknown host.
		res.status = 404
		res.headers["Content-Type"] = { "text/plain; charset=utf-8" }
		res.body = "unknown host"
	end

	return {
		handle = handle,
		register_app = register_app,
		sessions = sessions,
		launch_tokens = launch_tokens,
		app_sessions = app_sessions,
		loopback_id_to_ip = loopback_id_to_ip,
		loopback_ip_to_id = loopback_ip_to_id,
		_host = host,
		_library_app = library_app,
	}
end

return M
