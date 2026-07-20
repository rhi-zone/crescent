-- lib/platform/daemon/cli.lua
-- CLI entry point for the platform daemon (single-port HTTP listener).
--
-- Usage:
--   luajit lib/platform/daemon/cli.lua [--host=IFACE] [--port=N] [--apps-dir=PATH]
--   luajit lib/platform/daemon/cli.lua --status
--
-- Flags:
--   --host=IFACE          Bind interface (default 127.0.0.1)
--   --port=N              Listen port (default 7777)
--   --apps-dir=PATH       App tarball directory (default $XDG_STATE_HOME/crescent/apps).
--                          Index/audit/session DBs default to $XDG_STATE_HOME/crescent/db.
--   --daemon-host=H       Canonical daemon host (default "<host>:<port>")
--   --runtime-dir=PATH    Card app runtime directory (default lib/platform/apps/charactercardv2)
--   --status              Print URL of running daemon (from PID file) and exit;
--                          exit 0 if running, 1 if not.
--
-- The daemon writes its PID + host + port to a runtime file (Linux/macOS:
-- $XDG_RUNTIME_DIR/crescent/daemon.pid; Windows: %LOCALAPPDATA%\crescent\runtime\daemon.pid).
-- `cr open` reads this file to discover an already-running daemon.
--
-- v1: only serves the library app at the daemon origin + an app-origin stub.
-- See docs/daemon-design.md and TODO.md for the multi-step bring-up plan.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local daemon = require("lib.platform.daemon")
local app_loader = require("lib.platform.daemon.app_loader")
local http_server = require("lib.http.server")
local app_index = require("lib.platform.index")
local json = require("lib.format.json")
local xdg = require("lib.platform.xdg")
local pid_mod = require("lib.platform.daemon.pid")
local io_poll = require("lib.io_poll")
local async = require("lib.async")

-- ── Arg parsing ────────────────────────────────────────────────────────────

--: ({ [integer]: string }) -> { host: string, port: integer, apps_dir: string | nil, daemon_host: string | nil, runtime_dir: string | nil, tls_cert: string | nil, tls_key: string | nil, status: boolean }
local function parse_args(args)
	local opts = {
		host = "127.0.0.1",
		port = 7777,
		apps_dir = nil --[[: string | nil]],
		daemon_host = nil --[[: string | nil]],
		runtime_dir = nil --[[: string | nil]],
		tls_cert = nil --[[: string | nil]],
		tls_key = nil --[[: string | nil]],
		status = false,
	}
	for i = 1, #args do
		local a = args[i]
		local key, val = a:match("^%-%-([^=]+)=(.*)")
		if key == "host" then
			opts.host = val
		elseif key == "port" then
			local p = tonumber(val)
			if p then opts.port = math.floor(p) end
		elseif key == "apps-dir" then
			opts.apps_dir = val
		elseif key == "daemon-host" then
			opts.daemon_host = val
		elseif key == "runtime-dir" then
			opts.runtime_dir = val
		elseif key == "tls-cert" then
			opts.tls_cert = val
		elseif key == "tls-key" then
			opts.tls_key = val
		elseif a == "--status" then
			-- Marker; handled before parse_args returns (see main).
			opts.status = true
		elseif a:sub(1, 1) == "-" then
			io.stderr:write("unknown flag: " .. a .. "\n")
			os.exit(1)
		end
	end
	return opts
end

--: (string) -> string
local function expand_home(path)
	if path:sub(1, 1) == "~" then
		local home = os.getenv("HOME") or ""
		return home .. path:sub(2)
	end
	return path
end

-- ── Module export ─────────────────────────────────────────────────────────

local M = {}

function M.main(argv)

-- Seed math.random so the daemon's math.random fallback (only used if
-- lib/rand's CSPRNG probe fails at startup) produces different values per
-- process. daemon.make's default random_bytes_fn now prefers lib/rand
-- (getrandom(2) / /dev/urandom); this seed is only a belt-and-suspenders.
math.randomseed(os.time())

local opts = parse_args(argv)

-- ── --status: report whether a daemon is running ──────────────────────────
-- Reads the PID file written by a running instance and verifies the process
-- is alive. Prints a URL on success, exits non-zero if no daemon found.
if opts.status then
	local pid_io = pid_mod.make({ pid_file = xdg.pid_file() })
	local info, err = pid_io.read()
	if not info then
		io.stderr:write("daemon: not running (" .. tostring(err) .. ")\n")
		os.exit(1)
	end
	io.write("http://" .. tostring(info.host) .. ":" .. tostring(info.port) .. "/\n")
	os.exit(0)
end

-- Legacy migration hint.
do
	local function path_exists(p)
		local f = io.open(p, "r")
		if f then f:close(); return true end
		return os.execute('test -e "' .. p:gsub('"', '\\"') .. '"') == 0
	end
	local legacy = xdg.legacy_path_if_present(path_exists)
	if legacy then
		io.stderr:write("note: legacy " .. legacy .. " detected. Crescent now uses XDG paths;\n")
		io.stderr:write("      consider moving it to " .. xdg.data_home() .. " (no automatic migration).\n")
	end
end
-- Apps tarball dir + DB dir. When --apps-dir is given, keep the index DB next
-- to the apps (legacy / test layout). On the default path, split per XDG:
-- apps under STATE/apps, DBs under STATE/db.
local apps_dir, db_dir
if opts.apps_dir then
	apps_dir = expand_home(opts.apps_dir)
	db_dir = apps_dir
else
	apps_dir = xdg.apps_dir()
	db_dir = xdg.db_dir()
end
os.execute(("mkdir -p %q %q"):format(apps_dir, db_dir))
local daemon_host = opts.daemon_host or (opts.host .. ":" .. tostring(opts.port))

-- Open the app index DB (read-only use from the library app is fine; the DB
-- doesn't need to exist — the library app handles a nil/empty index).
-- `raw_index_db` is the underlying SQLite handle (used by the daemon for its
-- own SQL queries — `app_exists` + library app's `caps.index_db`).
-- `idx` is the wrapped index (exposes `:get(id)`), used by app_loader.
local raw_index_db
local idx, ierr = app_index.open(db_dir .. "/index.db")
if idx then
	raw_index_db = idx._db
else
	io.stderr:write("note: index DB not available (" .. tostring(ierr) .. ") — library will show empty.\n")
end

-- Per-app URL: subdomain form `http://app-<id>.<daemon-host>/`. Matches the
-- canonical origin set by classify_host / launch_origin_url.
--: (string) -> string
local function app_url(app_id)
	return "http://app-" .. app_id .. "." .. daemon_host
end

-- ── Shared event loop + DaemonCtx ───────────────────────────────────────────
-- The poller and loop are shared between the HTTP server and DaemonCtx. cli.lua
-- owns the top-level loop drive; socket.server receives the loop via opts and
-- skips its own internal drive loop.
local poller = io_poll.new()
local loop = async.loop(poller)

-- DaemonCtx: host-side wiring for async cap support. Passed through
-- context.daemon_ctx to cap factories. Never exposed to apps.
local daemon_ctx = {
	poller = poller,
	loop = loop,
	--: (fd: integer, on_readable: () -> nil) -> (() -> nil)
	register_fd = function(fd, on_readable)
		local _, remove_fn, err = poller:add(fd, on_readable, nil, true)
		if err then error("daemon_ctx.register_fd: " .. err) end
		--: () -> nil
		return function()
			if remove_fn then remove_fn() end
		end
	end,
	--: (fn: () -> nil) -> nil
	schedule = function(fn)
		loop:queue(fn)
	end,
}

--: unknown
local loader_fn
if idx then
	loader_fn = app_loader.make({
		index_db = idx,
		context = { data_dir = apps_dir, user_id = nil, daemon_ctx = daemon_ctx },
		entry_key = "server",
		app_url = app_url,
		-- Threaded for the create_instance cap (lets an app install a new
		-- instance of itself through the existing import pipeline).
		apps_dir = apps_dir,
		write_fn = function(path, data)
			local f, err = io.open(path, "wb")
			if not f then return nil, err end
			f:write(data)
			f:close()
			return true, nil
		end,
		time_fn = os.time,
		audit_log = nil,
	})
end

-- Build a discover(params) wrapper around an already-loaded app handler.
-- The handler expects (req, res); we synthesise a request to /discover and
-- return the parsed JSON response. Errors return an empty entries response.
--: ((http_req, http_res) -> nil) -> (({ [string]: string }) -> unknown)
local function make_discover_fn(handler)
	return function(params)
		local qs_parts = {}
		for k, v in pairs(params) do
			qs_parts[#qs_parts + 1] = tostring(k) .. "=" .. tostring(v)
		end
		local req = {
			method = "GET",
			path   = "/discover",
			query  = table.concat(qs_parts, "&"),
			headers = {} --[[: { [string]: { [number]: string } } | nil]],
			body   = nil --[[: string | nil]],
		}
		local res = { status = nil, headers = {}, body = nil }
		local ok, err = pcall(handler, req, res)
		if not ok or not res.body then
			return { entries = {}, total = 0, error = tostring(ok and "empty body" or err) }
		end
		local decoded = json.decode(res.body)
		if not decoded then
			return { entries = {}, total = 0, error = "json decode failed" }
		end
		return decoded
	end
end

-- Discover source adapter apps in the index (meta.source_adapter = true).
-- Uses the app_loader to initialise each one's handler. Failures are logged
-- but don't prevent the daemon from starting.
local sources = {}
if idx and loader_fn and raw_index_db then
	local ok_q, src_iter = pcall(
		raw_index_db.query, raw_index_db,
		"SELECT id, name FROM apps WHERE json_extract(manifest_json, '$.meta.source_adapter') = 1"
	)
	if ok_q and src_iter then
		while true do
			local src_id, src_name = src_iter()
			if not src_id then break end
			local id_str = tostring(src_id)
			local handler, lerr = (loader_fn --[[:! (string) -> ((http_req, http_res) -> nil, string | nil)]])(id_str)
			if handler then
				sources[#sources + 1] = {
					id       = id_str,
					name     = src_name or id_str,
					discover = make_discover_fn(handler),
					handler  = handler,  -- retained for future in-process calls (e.g. GET /card/:id)
				}
				io.stderr:write("daemon: source adapter loaded: " .. (src_name or id_str) .. "\n")
			else
				io.stderr:write("daemon: source adapter " .. id_str .. " load failed: " .. tostring(lerr) .. "\n")
			end
		end
	end
end

-- Load the card app runtime files for the import endpoint.
-- Reads the manifest.json from runtime_dir, then loads each entry's main file.
-- Falls back gracefully if the directory or files are missing.
local runtime_dir = expand_home(opts.runtime_dir or "lib/platform/apps/charactercardv2")
local runtime_files --: { [integer]: { name: string, data: string } } | nil
local runtime_manifest
do
	local mf = io.open(runtime_dir .. "/manifest.json", "rb")
	if mf then
		local raw = mf:read("*a") --[[:! string]]
		mf:close()
		local decoded_raw = json.decode(raw)
		local decoded = decoded_raw --[[:! { entry: { [string]: unknown } | nil, ... } | nil]]
		if decoded then
			runtime_manifest = decoded
			runtime_files = {} --: { [integer]: { name: string, data: string } }
			local entries = decoded.entry or {}
			local seen = {}
			for _, entry_def in pairs(entries) do
				local main
				if type(entry_def) == "table" then
					local entry_def_ = entry_def --[[:! { main: string | nil, ... }]]
					main = entry_def_.main
				end
				if main then
					local main_str = main --[[:! string]]
					if not seen[main_str] then
						seen[main_str] = true
						local f = io.open(runtime_dir .. "/" .. main_str, "rb")
						if f then
							runtime_files[#runtime_files + 1] = { name = main_str, data = f:read("*a") }
							f:close()
						end
					end
				end
			end
		end
	end
	if runtime_manifest then
		io.stderr:write("daemon: runtime loaded from " .. runtime_dir .. " (" .. #(runtime_files or {}) .. " files)\n")
	else
		io.stderr:write("note: runtime dir not available (" .. runtime_dir .. ") — import endpoint disabled.\n")
	end
end

--: (path: string, data: string) -> (true | nil, string | nil)
local function write_file(path, data)
	local f, err = io.open(path, "wb")
	if not f then return nil, err end
	f:write(data)
	f:close()
	return true, nil
end

local d = daemon.make({
	host = daemon_host,
	time_fn = os.time,
	index_db = raw_index_db,
	index_obj = idx,
	sources = sources,
	app_loader = loader_fn --[[:! (string) -> (((http_req, http_res) -> nil) | nil, string | nil)]],
	apps_dir = apps_dir,
	write_fn = write_file,
	runtime_files = runtime_files or nil,
	runtime_manifest = runtime_manifest,
	session_db_path = db_dir .. "/session_store.db",
	on_handler_error = function(app_id, err, tb)
		io.stderr:write("daemon: app " .. app_id .. " handler error: " .. err .. "\n" .. tb .. "\n")
	end,
})

-- ── Socket listener ────────────────────────────────────────────────────────
-- http.server handles header/body framing; we wrap the handler to split
-- raw_req.target into path+query (daemon.handle expects them separately) and
-- delegate to d.handle. opts.host forwards all the way down to the bind call
-- so a loopback-only daemon stays loopback-only.

-- Non-loopback without TLS: warn the operator. The loopback check is a simple
-- prefix match — 127. covers all 127.x.x.x loopback aliases. "localhost" is
-- also considered loopback. Anything else is potentially routable.
local is_loopback = opts.host == "localhost"
	or opts.host:sub(1, 4) == "127."
	or opts.host == "::1"
if not is_loopback and not opts.tls_cert then
	io.stderr:write("daemon: WARNING: binding to non-loopback interface ("
		.. opts.host .. ") without TLS — not recommended for production\n")
end

local scheme = opts.tls_cert and "https" or "http"
io.write("daemon: " .. scheme .. "://" .. daemon_host .. "/\n")
io.flush()

-- Write PID file so `cr open` and `cr daemon --status` can discover us.
-- Best-effort: a failure here logs but does not abort the daemon.
do
	local pid_io = pid_mod.make({ pid_file = xdg.pid_file() })
	local ffi_ok, ffi = pcall(require, "ffi")
	local self_pid = 0
	if ffi_ok then
		local ok_decl = pcall(function() ffi.cdef("int getpid(void);") end)
		if ok_decl then
			local ok_call, pid_ret = pcall(ffi.C.getpid)
			if ok_call then
				local n = tonumber(pid_ret)
				if n then self_pid = math.floor(n) end
			end
		end
	end
	-- If we can't get a real pid, write 0; --status will treat it as stale.
	local _, perr = pid_io.write({
		pid  = self_pid,
		host = opts.host,
		port = opts.port,
	})
	if perr then
		io.stderr:write("daemon: pid file write failed: " .. tostring(perr) .. "\n")
	end
end

local server_opts = {
	host = opts.host,
	tls_cert = opts.tls_cert,
	tls_key = opts.tls_key,
	loop = loop,
}

http_server.server(function(raw_req, res, _sock)
	local target = (raw_req.target or "/") --[[:! string]]
	local q = target:find("?", 1, true)
	local path, query
	if q then
		path = target:sub(1, q - 1)
		query = target:sub(q + 1)
	else
		path = target
	end
	local req = {
		method = raw_req.method --[[:! string | nil]],
		path = path,
		query = query --[[:! string | nil]],
		headers = raw_req.headers --[[:! { [string]: { [number]: string } } | nil]],
		body = raw_req.body --[[:! string | nil]],
	}
	res.status = 200 -- http.server initialises headers={} but not status
	d.handle(req, res)
end, opts.port, nil, server_opts)

-- cli.lua owns the event loop. socket.server registered its accept fd on the
-- shared poller but deferred driving to us (because we passed opts.loop).
while true do loop:step() end

end

if arg then M.main(arg) end

return M
