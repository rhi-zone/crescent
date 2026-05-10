-- lib/web/init.lua
-- Web application framework — middleware pipeline, routing, cookie handling,
-- CSRF protection, static file serving. Operates on request/response tables
-- directly, fully testable without a running HTTP server.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json")

local M = {}

--:: web_request = { method: string, path: string, query?: { [string]: string }, params?: { [string]: string }, headers?: { [string]: unknown }, body?: unknown, cookies?: { [string]: string }, _start_time?: number, ... }
--:: web_response = { status: integer, headers: { [string]: string[] }, body: string, ... }
--:: web_handler = (req: web_request, res: web_response) -> nil
--:: web_middleware = (req: web_request, res: web_response, next: () -> nil) -> nil
--:: web_app = { _middleware: web_middleware[], _routes: { method: string, pattern_parts: string[], pattern: string, handler: web_handler }[], ... }
--:: web_logger_opts = { log?: (msg: string) -> nil, clock?: () -> number }
--:: web_cors_opts = { origins?: string[], methods?: string[], headers?: string[], max_age?: string }
--:: web_csrf_opts = { secret: string, ... }
--:: web_cookie_opts = { path?: string, domain?: string, maxAge?: integer, httpOnly?: boolean, secure?: boolean, sameSite?: string }

local clock_default = os and os.clock or nil
local concat = table.concat
local insert = table.insert
local find = string.find
local sub = string.sub
local lower = string.lower
local format = string.format

-- ── Query string parsing ─────────────────────────────────────────────────────

--: (string) -> string
local function url_decode(s)
	local r = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16) or 0) end) --[[: any]]
	r = r:gsub("+", " ")
	return tostring(r)
end

--: (string) -> { [string]: string }
local function parse_query(qs)
	local params = {} --[[: { [string]: string }]]
	local pos = 1
	local len = #qs
	while pos <= len do
		local amp = find(qs, "&", pos, true)
		local pair = sub(qs, pos, amp and amp - 1 or len)
		pos = amp and amp + 1 or len + 1
		local eq = find(pair, "=", 1, true)
		if eq then
			local key = sub(pair, 1, eq - 1)
			local val = sub(pair, eq + 1)
			params[url_decode(key)] = url_decode(val)
		elseif #pair > 0 then
			params[url_decode(pair)] = ""
		end
	end
	return params
end

-- ── Path splitting ───────────────────────────────────────────────────────────

--: (string) -> string[]
local function split_path(path)
	local parts = {}
	local pos = 1
	local len = #path
	-- skip leading /
	if pos <= len and sub(path, pos, pos) == "/" then pos = pos + 1 end
	while pos <= len do
		local slash = find(path, "/", pos, true)
		if slash then
			parts[#parts + 1] = sub(path, pos, slash - 1)
			pos = slash + 1
		else
			parts[#parts + 1] = sub(path, pos)
			break
		end
	end
	return parts
end

-- ── Route matching ───────────────────────────────────────────────────────────

--: (string[], string[]) -> { [string]: string } | nil
local function match_route(pattern_parts, path_parts)
	if #pattern_parts ~= #path_parts then return nil end
	local params = {}
	for i = 1, #pattern_parts do
		local pat = pattern_parts[i]
		local seg = path_parts[i]
		if sub(pat, 1, 1) == ":" then
			params[sub(pat, 2)] = seg
		elseif pat ~= seg then
			return nil
		end
	end
	return params
end

-- ── Content type map ─────────────────────────────────────────────────────────

--: { [string]: string }
local EXT_TYPES = {
	html = "text/html",
	htm = "text/html",
	css = "text/css",
	js = "application/javascript",
	json = "application/json",
	png = "image/png",
	jpg = "image/jpeg",
	jpeg = "image/jpeg",
	gif = "image/gif",
	svg = "image/svg+xml",
	txt = "text/plain",
	xml = "application/xml",
	pdf = "application/pdf",
	ico = "image/x-icon",
	woff = "font/woff",
	woff2 = "font/woff2",
	ttf = "font/ttf",
	otf = "font/otf",
}

--: (string) -> string
local function content_type_for(path)
	local dot = path:match(".*%.()")
	if dot then
		local ext = lower(sub(path, dot))
		return EXT_TYPES[ext] or "application/octet-stream"
	end
	return "application/octet-stream"
end

-- ── Response helpers ─────────────────────────────────────────────────────────

local res_mt = {}
res_mt.__index = res_mt

--: (web_response, unknown) -> web_response
function res_mt:json(data)
	self.headers["Content-Type"] = { "application/json" }
	local ok, encoded = pcall(json.encode, data)
	if ok then
		self.body = encoded --[[:! string]]
	else
		self.body = "{}"
	end
	return self
end

--: (web_response, string) -> web_response
function res_mt:html(s)
	self.headers["Content-Type"] = { "text/html" }
	self.body = s
	return self
end

--: (web_response, integer) -> web_response
function res_mt:set_status(code)
	self.status = code
	return self
end

--: (web_response, string, (integer | nil)) -> web_response
function res_mt:redirect(url, code)
	self.status = code or 302
	self.headers["Location"] = { url }
	return self
end

-- ── App ──────────────────────────────────────────────────────────────────────

local App = {}
App.__index = App

--: () -> web_app
function M.app()
	local self = setmetatable({}, App)
	self._middleware = {}
	self._routes = {}
	return self
end

--: (web_app, web_middleware) -> web_app
function App:use(mw)
	self._middleware[#self._middleware + 1] = mw
	return self
end

-- Internal: add a route
--: (web_app, string, string, web_handler) -> ()
function App:_add_route(method, path, handler)
	self._routes[#self._routes + 1] = {
		method = method:upper(),
		pattern_parts = split_path(path),
		pattern = path,
		handler = handler,
	}
end

function App:get(path, handler) self:_add_route("GET", path, handler) return self end
function App:post(path, handler) self:_add_route("POST", path, handler) return self end
function App:put(path, handler) self:_add_route("PUT", path, handler) return self end
function App:delete(path, handler) self:_add_route("DELETE", path, handler) return self end
function App:patch(path, handler) self:_add_route("PATCH", path, handler) return self end
function App:options(path, handler) self:_add_route("OPTIONS", path, handler) return self end
function App:head(path, handler) self:_add_route("HEAD", path, handler) return self end

-- ── Route groups ─────────────────────────────────────────────────────────────

local Group = {}
Group.__index = Group

--: (web_app, string) -> { _app: web_app, _prefix: string, ... }
function App:group(prefix)
	return setmetatable({ _app = self, _prefix = prefix }, Group)
end

function Group:get(path, handler) self._app:_add_route("GET", self._prefix .. path, handler) return self end
function Group:post(path, handler) self._app:_add_route("POST", self._prefix .. path, handler) return self end
function Group:put(path, handler) self._app:_add_route("PUT", self._prefix .. path, handler) return self end
function Group:delete(path, handler) self._app:_add_route("DELETE", self._prefix .. path, handler) return self end
function Group:patch(path, handler) self._app:_add_route("PATCH", self._prefix .. path, handler) return self end
function Group:options(path, handler) self._app:_add_route("OPTIONS", self._prefix .. path, handler) return self end
function Group:head(path, handler) self._app:_add_route("HEAD", self._prefix .. path, handler) return self end

-- ── Request dispatch ─────────────────────────────────────────────────────────

--: (web_app, web_request) -> web_response
function App:handle(req)
	-- Parse query string from path
	local qmark = find(req.path, "?", 1, true)
	if qmark then
		local q = parse_query(sub(req.path, qmark + 1)) --[[:! { [string]: string }]]
		req.query = q
		req.path = sub(req.path, 1, qmark - 1)
	else
		req.query = req.query or {}
	end
	req.params = req.params or {}
	req.method = (req.method or "GET"):upper()
	if not req.headers then req.headers = {} end

	local res = setmetatable({
		status = 200,
		headers = { ["Content-Type"] = { "text/plain" } },
		body = "",
	}, res_mt)

	-- Build middleware chain + route dispatch
	local mw = self._middleware
	local routes = self._routes
	local idx = 0

	local function next_mw()
		idx = idx + 1
		if idx <= #mw then
			mw[idx](req, res, next_mw)
		else
			-- After all middleware, do route dispatch
			local path_parts = split_path(req.path)
			local method = req.method

			-- First pass: exact match (no params)
			for i = 1, #routes do
				local r = routes[i]
				if r.method == method then
					local params = match_route(r.pattern_parts, path_parts)
					if params then
						local has_params = false
						for _ in pairs(params) do has_params = true; break end
						if not has_params then
							req.params = params
							r.handler(req, res)
							return
						end
					end
				end
			end

			-- Second pass: parameterized match
			for i = 1, #routes do
				local r = routes[i]
				if r.method == method then
					local params = match_route(r.pattern_parts, path_parts)
					if params then
						req.params = params
						r.handler(req, res)
						return
					end
				end
			end

			-- No route matched
			res.status = 404
			res.body = "Not Found"
		end
	end

	next_mw()
	return res
end

-- ── Built-in middleware: logger ───────────────────────────────────────────────

--: ((web_logger_opts | nil)) -> web_middleware
function M.logger(opts)
	local log_fn = ((opts and opts.log) or print) --[[:! (string) -> nil]]
	local clock = (opts and opts.clock) or clock_default
	if not clock then error("web.logger: requires opts.clock (function returning seconds)", 2) end
	local clock_nn = clock --[[:! () -> number]]
	--: (req: web_request, res: web_response, next: () -> nil) -> nil
	return function(req, res, next)
		req._start_time = clock_nn()
		next()
		local start = req._start_time --[[:! number]]
		local elapsed = clock_nn() - start
		log_fn(format("%s %s %d %.3fms", req.method, req.path, res.status, elapsed * 1000))
	end
end

-- ── Built-in middleware: CORS ────────────────────────────────────────────────

--: ((web_cors_opts | nil)) -> web_middleware
function M.cors(opts)
	opts = opts or {}
	local origins = opts.origins or { "*" }
	local methods = opts.methods or { "GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS" }
	local headers_allowed = opts.headers or { "Content-Type", "Authorization", "X-CSRF-Token" }
	local max_age = opts.max_age or "86400"

	local origin_str = concat(origins --[[:! { [integer]: string | number }]], ", ")
	local methods_str = concat(methods --[[:! { [integer]: string | number }]], ", ")
	local headers_str = concat(headers_allowed --[[:! { [integer]: string | number }]], ", ")

	--: (req: web_request, res: web_response, next: () -> nil) -> nil
	return function(req, res, next)
		res.headers["Access-Control-Allow-Origin"] = { origin_str }
		res.headers["Access-Control-Allow-Methods"] = { methods_str }
		res.headers["Access-Control-Allow-Headers"] = { headers_str }

		if req.method == "OPTIONS" then
			res.headers["Access-Control-Max-Age"] = { max_age }
			res.status = 204
			res.body = ""
			return
		else
			next()
		end
	end
end

-- ── Built-in middleware: static files ────────────────────────────────────────

-- static(url_prefix, dir, read_fn) -> middleware
-- read_fn: (path: string) -> string | nil — reads a file by path.
-- In sandbox: use caps.fs.read. Outside: wrap io.open.
--: (string, string, (string) -> string | nil) -> web_middleware
function M.static(url_prefix, dir, read_fn)
	if not read_fn then error("web.static: requires read_fn (function reading file by path)", 2) end
	-- Normalize: ensure url_prefix starts with / and has no trailing /
	if sub(url_prefix, 1, 1) ~= "/" then url_prefix = "/" .. url_prefix end
	if sub(url_prefix, -1) == "/" and #url_prefix > 1 then
		url_prefix = sub(url_prefix, 1, -2) --[[:! string]]
	end
	-- Normalize dir: remove trailing /
	if sub(dir, -1) == "/" and #dir > 1 then
		dir = sub(dir, 1, -2) --[[:! string]]
	end

	local prefix_len = #url_prefix

	--: (req: web_request, res: web_response, next: () -> nil) -> nil
	return function(req, res, next)
		if req.method ~= "GET" and req.method ~= "HEAD" then
			next()
			return
		end

		local path = req.path
		if sub(path, 1, prefix_len) ~= url_prefix then
			next()
			return
		end

		-- Check that the character after the prefix is / or end-of-string
		local rest = sub(path, prefix_len + 1)
		if rest == "" then rest = "/" end
		if sub(rest, 1, 1) ~= "/" then
			next()
			return
		end

		-- Security: reject path traversal
		if find(rest, "..", 1, true) then
			next()
			return
		end

		local file_path = dir .. rest
		local contents = read_fn(file_path)
		if not contents then
			next()
			return
		end

		res.status = 200
		res.headers["Content-Type"] = { content_type_for(file_path) }
		res.body = contents
	end
end

-- ── Built-in middleware: JSON body parser ────────────────────────────────────

--: () -> web_middleware
function M.json_body()
	--: (req: web_request, res: web_response, next: () -> nil) -> nil
	local mw = function(req, res, next)
		local headers = req.headers or ({} --[[:! { [string]: unknown }]])
		local ct = headers["content-type"] or headers["Content-Type"] or ""
		local body = req.body
		if find(ct --[[:! string]], "application/json", 1, true) and type(body) == "string" and #(body --[[:! string]]) > 0 then
			local ok, decoded = pcall(json.decode, body --[[:! string]])
			if ok and decoded ~= nil then
				req.body = decoded
			end
		end
		next()
	end
	return mw
end

-- ── Built-in middleware: cookies ──────────────────────────────────────────────

--: () -> web_middleware
function M.cookies()
	--: (req: web_request, res: web_response, next: () -> nil) -> nil
	local mw = function(req, res, next)
		-- Parse Cookie header
		local headers = req.headers or ({} --[[:! { [string]: unknown }]])
		local cookie_header = (headers["cookie"] or headers["Cookie"] or "") --[[:! string]]
		local cookies = {}
		for pair in cookie_header:gmatch("[^;]+") do
			pair = pair:match("^%s*(.-)%s*$") -- trim
			local eq = find(pair, "=", 1, true)
			if eq then
				local name = sub(pair, 1, eq - 1)
				local val = sub(pair, eq + 1)
				cookies[name] = val
			end
		end
		req.cookies = cookies

		-- Add set_cookie method to response
		--: (web_response, string, string, (web_cookie_opts | nil)) -> web_response
		function res:set_cookie(name, value, opts)
			opts = opts or {}
			local parts = { name .. "=" .. value }
			if opts.path then parts[#parts + 1] = "Path=" .. (opts.path --[[:! string]]) end
			if opts.domain then parts[#parts + 1] = "Domain=" .. (opts.domain --[[:! string]]) end
			if opts.maxAge then parts[#parts + 1] = "Max-Age=" .. tostring(opts.maxAge) end
			if opts.httpOnly then parts[#parts + 1] = "HttpOnly" end
			if opts.secure then parts[#parts + 1] = "Secure" end
			if opts.sameSite then parts[#parts + 1] = "SameSite=" .. (opts.sameSite --[[:! string]]) end
			local cookie_str = concat(parts, "; ")

			-- Append to Set-Cookie (can have multiple)
			if not self.headers["Set-Cookie"] then
				self.headers["Set-Cookie"] = { cookie_str }
			else
				self.headers["Set-Cookie"][#self.headers["Set-Cookie"] + 1] = cookie_str
			end
			return self
		end

		next()
	end
	return mw
end

-- ── Built-in middleware: CSRF ────────────────────────────────────────────────

--: (web_csrf_opts) -> web_middleware
function M.csrf(opts)
	local secret = opts.secret or error("web.csrf requires opts.secret")

	-- Simple token generation: secret .. ":" .. session_id-like value
	-- In real usage, this would use HMAC. For now, concatenation + comparison.
	local function make_token(session_key)
		return secret .. ":" .. (session_key or "default")
	end

	local function verify_token(token, session_key)
		local expected = make_token(session_key)
		-- Constant-time comparison (best effort in Lua)
		if #token ~= #expected then return false end
		local diff = 0
		for i = 1, #token do
			diff = diff + (string.byte(token, i) == string.byte(expected, i) and 0 or 1)
		end
		return diff == 0
	end

	return (function(req, res, next)
		local method = req.method
		local cookies = req.cookies or ({} --[[:! { [string]: string }]])
		local headers = req.headers or ({} --[[:! { [string]: unknown }]])
		local session_key = cookies["session"] or "default"
		local token = make_token(session_key)

		-- For safe methods, provide the token
		if method == "GET" or method == "HEAD" or method == "OPTIONS" then
			res.csrf_token = token
			next()
			return
		end

		-- For unsafe methods, validate the token
		local req_token = headers["x-csrf-token"] or headers["X-CSRF-Token"]
		if not req_token and type(req.body) == "table" then
			req_token = (req.body --[[:! { _csrf: string } ]])._csrf
		end

		if not req_token or not verify_token(req_token --[[:! string]], session_key) then
			res.status = 403
			res.body = "Forbidden: invalid CSRF token"
			return
		end

		res.csrf_token = token
		next()
	end) --[[:! web_middleware]]
end

-- ── Exports ──────────────────────────────────────────────────────────────────

M.parse_query = parse_query
M.split_path = split_path
M.content_type_for = content_type_for

return M
