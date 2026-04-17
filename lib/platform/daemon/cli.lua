-- lib/platform/daemon/cli.lua
-- CLI entry point for the platform daemon (single-port HTTP listener).
--
-- Usage:
--   luajit lib/platform/daemon/cli.lua [--host=IFACE] [--port=N] [--apps-dir=PATH]
--
-- Flags:
--   --host=IFACE          Bind interface (default 127.0.0.1)
--   --port=N              Listen port (default 7777)
--   --apps-dir=PATH       Where the app index DB lives (default ~/.crescent/apps)
--   --daemon-host=H       Canonical daemon host (default "<host>:<port>")
--   --runtime-dir=PATH    Card app runtime directory (default lib/platform/apps/charactercardv2)
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

-- ── Arg parsing ────────────────────────────────────────────────────────────

--: ({ [integer]: string }) -> { host: string, port: integer, apps_dir: string | nil, daemon_host: string | nil, runtime_dir: string | nil }
local function parse_args(args)
	local opts = {
		host = "127.0.0.1",
		port = 7777,
		apps_dir = nil, --: string | nil
		daemon_host = nil, --: string | nil
		runtime_dir = nil, --: string | nil
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

-- Seed math.random so the daemon's math.random fallback (only used if
-- lib/rand's CSPRNG probe fails at startup) produces different values per
-- process. daemon.make's default random_bytes_fn now prefers lib/rand
-- (getrandom(2) / /dev/urandom); this seed is only a belt-and-suspenders.
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
			headers = {},
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
			local handler, lerr = loader_fn(id_str)
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
local runtime_files, runtime_manifest
do
	local mf = io.open(runtime_dir .. "/manifest.json", "rb")
	if mf then
		local raw = mf:read("*a")
		mf:close()
		local decoded = json.decode(raw)
		if decoded then
			runtime_manifest = decoded
			runtime_files = {}
			local entries = decoded.entry or {}
			local seen = {}
			for _, entry_def in pairs(entries) do
				local main = type(entry_def) == "table" and entry_def.main
				if main and not seen[main] then
					seen[main] = true
					local f = io.open(runtime_dir .. "/" .. main, "rb")
					if f then
						runtime_files[#runtime_files + 1] = { name = main, data = f:read("*a") }
						f:close()
					end
				end
			end
		end
	end
	if runtime_manifest then
		io.stderr:write("daemon: runtime loaded from " .. runtime_dir .. " (" .. #runtime_files .. " files)\n")
	else
		io.stderr:write("note: runtime dir not available (" .. runtime_dir .. ") — import endpoint disabled.\n")
	end
end

local function write_file(path, data)
	local f, err = io.open(path, "wb")
	if not f then return nil, err end
	f:write(data)
	f:close()
	return true
end

local d = daemon.make({
	host = daemon_host,
	time_fn = os.time,
	index_db = raw_index_db,
	index_obj = idx,
	sources = sources,
	app_loader = loader_fn,
	apps_dir = apps_dir,
	write_fn = write_file,
	runtime_files = runtime_files,
	runtime_manifest = runtime_manifest,
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
