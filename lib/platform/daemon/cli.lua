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
local http_format = require("lib.http.format")
local socket_server = require("lib.socket.server")
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
local index_db
local idx, ierr = app_index.open(apps_dir .. "/index.db")
if idx then
	index_db = idx._db
else
	io.stderr:write("note: index DB not available (" .. tostring(ierr) .. ") — library will show empty.\n")
end

local d = daemon.make({
	host = daemon_host,
	time_fn = os.time,
	index_db = index_db,
})

-- ── Socket listener ────────────────────────────────────────────────────────
-- Single port. The http.server module in lib/http/server.lua doesn't expose
-- the `host` opt on socket.server, so we inline the request-reading path and
-- pass opts.host explicitly. This matches the structure of the http_server
-- cap (lib/platform/caps/http_server.lua).

local ffi = require("ffi")
local buf = ffi.new("char[65536]")
local max_header_size = 65536
local err_res = http_format.serialize_response({
	status = 400,
	headers = { ["content-length"] = { "0" } },
})

io.write("daemon: http://" .. daemon_host .. "/\n")
io.flush()

socket_server.server(function(client)
	local parts = {}
	local total = 0
	local header_end
	while not header_end do
		local s = client:receive(buf)
		if not s then return end
		parts[#parts + 1] = s
		total = total + #s
		if total > max_header_size then client:send(err_res); return end
		local combined = table.concat(parts)
		header_end = combined:find("\r\n\r\n", 1, true)
		if header_end then parts = { combined } end
	end
	local data = parts[1]
	local raw_req, i = http_format.parse_request(data)
	if not raw_req or not i then client:send(err_res); return end

	local content_length = raw_req.headers["content-length"]
	if content_length then
		content_length = tonumber(content_length[1])
		if content_length then
			local body_start = header_end + 4
			local body_so_far = #data - body_start + 1
			while body_so_far < content_length do
				local s = client:receive(buf)
				if not s then break end
				parts[#parts + 1] = s
				body_so_far = body_so_far + #s
			end
			if #parts > 1 then
				data = table.concat(parts)
				raw_req = http_format.parse_request(data)
				if not raw_req then client:send(err_res); return end
			end
		end
	end

	-- Split target into path + query (the daemon handler + the library app
	-- both expect req.path / req.query, not req.target).
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
	local res = { status = 200, headers = {}, body = nil }

	d.handle(req, res)

	client:send(http_format.serialize_response(res))
	client:close()
end, opts.port, nil, { host = opts.host })
