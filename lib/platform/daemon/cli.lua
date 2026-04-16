-- lib/platform/daemon/cli.lua
-- CLI entry point for the platform daemon (single-port HTTP listener).
--
-- Usage:
--   luajit lib/platform/daemon/cli.lua [--host=IFACE] [--port=N] [--apps-dir=PATH]
--
-- Flags:
--   --host=IFACE     Bind interface (default 127.0.0.1)
--   --port=N         Listen port (default 7777)
--   --apps-dir=PATH  Where the app index DB lives (default ~/.crescent/apps)
--   --daemon-host=H  Canonical daemon host (default "<host>:<port>")
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

-- ── Arg parsing ────────────────────────────────────────────────────────────

--: ({ [integer]: string }) -> { host: string, port: integer, apps_dir: string | nil, daemon_host: string | nil }
local function parse_args(args)
	local opts = {
		host = "127.0.0.1",
		port = 7777,
		apps_dir = nil, --: string | nil
		daemon_host = nil, --: string | nil
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

-- Seed random with time + something per-process so each launch differs. This
-- is NOT a CSPRNG — see TODO.md "daemon v1: replace math.random with a
-- real CSPRNG". Adequate for local development; MUST be replaced before the
-- daemon handles untrusted sessions over a routable interface.
math.randomseed(os.time())

local opts = parse_args(arg)
local apps_dir = expand_home(opts.apps_dir or "~/.crescent/apps")
local daemon_host = opts.daemon_host or (opts.host .. ":" .. tostring(opts.port))

-- Open the app index DB (read-only use from the library app is fine; the DB
-- doesn't need to exist — the library app handles a nil/empty index).
-- `raw_index_db` is the underlying SQLite handle (used by the daemon for its
-- own SQL queries — `app_exists` + library app's `caps.index_db`).
-- `idx` is the wrapped index (exposes `:get(id)`), used by app_loader.
local raw_index_db
local idx, ierr = app_index.open(apps_dir .. "/index.db")
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

--: unknown
local loader_fn
if idx then
	loader_fn = app_loader.make({
		index_db = idx,
		context = { data_dir = apps_dir },
		entry_key = "server",
		app_url = app_url,
	})
end

local d = daemon.make({
	host = daemon_host,
	time_fn = os.time,
	index_db = raw_index_db,
	app_loader = loader_fn,
	on_handler_error = function(app_id, err, tb)
		io.stderr:write("daemon: app " .. app_id .. " handler error: " .. err .. "\n" .. tb .. "\n")
	end,
})

-- ── Socket listener ────────────────────────────────────────────────────────
-- http.server handles header/body framing; we wrap the handler to split
-- raw_req.target into path+query (daemon.handle expects them separately) and
-- delegate to d.handle. opts.host forwards all the way down to the bind call
-- so a loopback-only daemon stays loopback-only.

io.write("daemon: http://" .. daemon_host .. "/\n")
io.flush()

http_server.server(function(raw_req, res)
	local target = raw_req.target or "/"
	local q = target:find("?", 1, true)
	local path, query
	if q then
		path = target:sub(1, q - 1)
		query = target:sub(q + 1)
	else
		path = target
	end
	local req = {
		method = raw_req.method,
		path = path,
		query = query,
		headers = raw_req.headers,
		body = raw_req.body,
	}
	res.status = 200 -- http.server initialises headers={} but not status
	d.handle(req, res)
end, opts.port, nil, { host = opts.host })
