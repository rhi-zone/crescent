-- lib/platform/server.lua
-- HTTP server wiring for a platform app's dom entrypoint.
--
-- API:
--   server.new(app, caps, opts?) -> srv
--   srv:handle(req)              -> res  (pure: no networking, for testing)
--   srv:start(host, port)        -> ok | nil, err
--   srv:stop()
--
-- opts:
--   opts.entry = "dom"  (default)
--
-- Routes:
--   GET /          -> minimal HTML bootstrap shell
--   GET /app.js    -> transpiled dom entrypoint (lua2ts), cached until app reload
--   GET /runtime.js -> browser-side cap proxy runtime (generated from caps table)
--   GET /static/*  -> file from app.entries by path suffix
--   POST /api/cap  -> RPC dispatch to server-side caps

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local tar     = require("lib.tar")
local lua2ts  = require("lib.lua2ts")
local rpc     = require("lib.platform.rpc")
local runtime = require("lib.platform.runtime")

local M = {}

-- ── Content-type helpers ──────────────────────────────────────────────────────

--: { [string]: string }
local EXT_TYPES = {
	html  = "text/html; charset=utf-8",
	css   = "text/css",
	js    = "application/javascript",
	json  = "application/json",
	png   = "image/png",
	jpg   = "image/jpeg",
	jpeg  = "image/jpeg",
	gif   = "image/gif",
	svg   = "image/svg+xml",
	txt   = "text/plain; charset=utf-8",
	xml   = "application/xml",
	ico   = "image/x-icon",
	woff  = "font/woff",
	woff2 = "font/woff2",
	ttf   = "font/ttf",
	otf   = "font/otf",
}

--: (string) -> string
local function content_type_for(p)
	local ext = p:match("%.([^./]+)$")
	if ext then
		return EXT_TYPES[ext:lower()] or "application/octet-stream"
	end
	return "application/octet-stream"
end

-- ── HTML bootstrap ────────────────────────────────────────────────────────────

-- HTML bootstrap for transpiled Lua dom entries (lua2ts).
--: string
local HTML_TRANSPILED = [[<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>crescent app</title></head>
<body><script type="module">
import { caps } from "/runtime.js";
const app = await import("/app.js");
if (app.default && app.default.init) await app.default.init(caps);
</script></body>
</html>]]

-- HTML bootstrap for static JS entries (hand-written JS in static/).
--: string
local HTML_STATIC = [[<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>crescent app</title></head>
<body><script type="module">
import { caps } from "/runtime.js";
const app = await import("/static/app.js");
if (app.default) await app.default(caps);
else if (app.init) await app.init(caps);
</script></body>
</html>]]

-- ── Response constructors ─────────────────────────────────────────────────────

--: (integer, string, string) -> { status: integer, headers: { [string]: string }, body: string }
local function make_res(status, content_type, body)
	return {
		status  = status,
		headers = { ["Content-Type"] = content_type },
		body    = body,
	}
end

--: (integer, string) -> { status: integer, headers: { [string]: string }, body: string }
local function make_err(status, msg)
	return make_res(status, "text/plain; charset=utf-8", msg)
end

-- ── Server object ─────────────────────────────────────────────────────────────

--:: srv_opts = { entry: string | nil }
--:: platform_srv_req = { method: string, path: string, headers: { [string]: string } | nil, body: string | nil }
--:: platform_srv_res = { status: integer, headers: { [string]: string }, body: string }
--:: platform_srv = { _app: any, _caps: any, _entry_key: string, _entry_path: string | nil, _js_cache: string | nil, _sock: any }

local Srv = {}
Srv.__index = Srv

-- new(app, caps, opts?) -> srv
--: (any, any, srv_opts | nil) -> platform_srv
function M.new(app, caps, opts)
	--: string | nil
	local entry_key_opt = opts and opts.entry
	--: string
	local entry_key = entry_key_opt or "dom"

	-- Resolve the entry path from the manifest
	--: any
	local entry_map = app.manifest and app.manifest.entry
	--: any
	local entry_def = entry_map and entry_map[entry_key]
	--: string | nil
	local entry_path = (type(entry_def) == "table" and entry_def.main) or
	                   (type(entry_def) == "string" and entry_def) or nil

	-- Detect serving strategy: static if entry path starts with "static/" or
	-- if no dom entry but tarball has static/app.js or static/index.html.
	local is_static = false
	if entry_path and entry_path:sub(1, 7) == "static/" then
		is_static = true
	elseif not entry_path then
		is_static = tar.get(app.entries, "static/app.js") ~= nil
			or tar.get(app.entries, "static/index.html") ~= nil
	end

	local srv = setmetatable({
		_app        = app,
		_caps       = caps,
		_entry_key  = entry_key,
		_entry_path = entry_path,
		_is_static  = is_static,
		_js_cache   = nil,
		_rt_cache   = nil,
		_dispatch   = rpc.make_dispatcher(caps),
		_sock       = nil,
	}, Srv)
	--: platform_srv
	return srv
end

-- transpile_entrypoint(srv) -> js_string | nil, err
-- Transpiles the dom entrypoint to TypeScript/JavaScript via lua2ts.
-- Result is cached on srv._js_cache.
--
-- TODO: full dep bundling — follow require() calls within the tarball
-- and include all in-app deps in the output bundle. Currently only
-- the entrypoint file itself is transpiled.
--: (platform_srv) -> string | nil, string | nil
local function transpile_entrypoint(srv)
	if srv._js_cache then
		return srv._js_cache
	end

	if not srv._entry_path then
		return nil, "platform.server: no entry path for key '" .. srv._entry_key .. "'"
	end
	--: string
	local entry_path = srv._entry_path

	local src = tar.get(srv._app.entries, entry_path)
	if not src then
		return nil, "platform.server: entry file '" .. entry_path .. "' not found in tarball"
	end

	local js, err = lua2ts.transpile(src, {
		filename = entry_path,
		module   = "esm",
	})
	if not js then
		return nil, "platform.server: transpile failed: " .. tostring(err)
	end

	srv._js_cache = js
	return js
end

-- handle(req) -> res
-- Pure HTTP dispatch (no networking). req must have: method, path, headers?, body?
-- Returns a res table: { status, headers, body }
--: (platform_srv, { method: string, path: string, headers: { [string]: string } | nil, body: string | nil }) -> { status: integer, headers: { [string]: string }, body: string }
function Srv:handle(req)
	--: string
	local method = req.method:upper()
	--: string
	local path = req.path

	-- Strip query string
	local qmark, _qmark_end = string.find(path, "?", 1, true)
	if qmark then
		path = string.sub(path, 1, qmark - 1)
	end

	-- GET /
	if method == "GET" and path == "/" then
		-- Static apps: check for static/index.html first (full custom HTML)
		if self._is_static then
			local custom_html = tar.get(self._app.entries, "static/index.html")
			if custom_html then
				return make_res(200, "text/html; charset=utf-8", custom_html)
			end
			return make_res(200, "text/html; charset=utf-8", HTML_STATIC)
		end
		return make_res(200, "text/html; charset=utf-8", HTML_TRANSPILED)
	end

	-- GET /app.js
	if method == "GET" and path == "/app.js" then
		local js, err = transpile_entrypoint(self)
		if not js then
			return make_err(500, err or "transpile error")
		end
		return make_res(200, "application/javascript", js)
	end

	-- GET /runtime.js — browser-side cap proxies
	if method == "GET" and path == "/runtime.js" then
		if not self._rt_cache then
			self._rt_cache = runtime.generate(self._caps)
		end
		return make_res(200, "application/javascript", self._rt_cache)
	end

	-- GET /static/<path>
	-- The URL /static/foo/bar.txt maps to tarball path "static/foo/bar.txt"
	-- (the "static/" prefix is kept as part of the tarball key).
	if method == "GET" and string.sub(path, 1, 8) == "/static/" then
		-- Security: reject path traversal
		if string.find(path, "..", 1, true) then
			return make_err(400, "Bad Request")
		end

		-- Strip leading "/" only — tarball paths do not have a leading slash
		--: string
		local file_path = string.sub(path, 2)  -- "/static/foo.txt" → "static/foo.txt"
		if file_path == "" then
			return make_err(404, "Not Found")
		end

		local data = tar.get(self._app.entries, file_path)
		if not data then
			return make_err(404, "Not Found")
		end

		return make_res(200, content_type_for(file_path), data)
	end

	-- POST /api/cap — RPC dispatch to server-side caps
	if method == "POST" and path == "/api/cap" then
		local body = req.body or ""
		local status, resp_body = self._dispatch(body)
		return make_res(status, "application/json", resp_body)
	end

	-- Other /api/* routes — reserved for future app request handlers
	if string.sub(path, 1, 5) == "/api/" then
		return make_err(404, "Not Found")
	end

	return make_err(404, "Not Found")
end

-- invalidate_cache() — force re-transpile on next /app.js request (e.g. after app reload)
--: (platform_srv) -> ()
function Srv:invalidate_cache()
	self._js_cache = nil
	self._rt_cache = nil
end

-- start(host, port) -> ok | nil, err
-- Bind and start the HTTP server. Blocks until stop() is called.
-- Uses lib/http/server (ljsocket + epoll under the hood).
--: (platform_srv, string, integer) -> boolean | nil, string | nil
function Srv:start(host, port)
	local ok_http, http_server = pcall(require, "lib.http.server")
	if not ok_http then
		return nil, "platform.server: lib.http.server unavailable: " .. tostring(http_server)
	end
	local ok_sock, socket_mod = pcall(require, "lib.socket.server")
	if not ok_sock then
		return nil, "platform.server: lib.socket.server unavailable: " .. tostring(socket_mod)
	end

	--: any
	local self_ref = self

	-- Adapter: convert lib/http/format request → srv:handle() response → wire bytes
	--: (any, any, any) -> ()
	local function handler(raw_req, raw_res, _client)
		-- lib/http/format request has .target (path + query), .method, .headers, .body
		local req = {
			method  = raw_req.method,
			path    = raw_req.target or "/",
			headers = {},
			body    = raw_req.body,
		}
		-- Flatten header arrays from lib/http/format into single strings
		if raw_req.headers then
			for k, arr in pairs(raw_req.headers) do
				if type(arr) == "table" then
					req.headers[k] = arr[1]
				else
					req.headers[k] = arr
				end
			end
		end

		local res = self_ref:handle(req)

		-- lib/http/format.serialize_response expects headers as { [string]: string[] }
		raw_res.status  = res.status
		raw_res.body    = res.body or ""
		raw_res.headers = {}
		for k, v in pairs(res.headers or {}) do
			raw_res.headers[k] = { v }
		end
		-- Content-Length is added by serialize_response automatically
	end

	--: any
	local http_srv = http_server
	--: any
	local sock_srv = socket_mod

	local ok2, result = pcall(function()
		return sock_srv.server(
			http_srv.make_connection_handler(handler),
			port,
			nil,  -- no external epoll: blocking call
			{ host = host }
		)
	end)
	if not ok2 then
		return nil, "platform.server: bind failed: " .. tostring(result)
	end
	self._sock = result
	return true
end

-- stop() — close the server socket
--: (platform_srv) -> ()
function Srv:stop()
	if self._sock then
		pcall(function() self._sock:close() end)
		self._sock = nil
	end
end

return M
