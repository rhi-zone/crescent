-- lib/platform/apps/system_dashboard/server.lua
-- System Dashboard HTTP BFF.
--
-- M.create(caps, opts) -> { handler }
--
-- Routes:
--   GET /                 -> static/index.html
--   GET /static/<path>    -> tarball static file
--   GET /api/search?q=<q> -> JSON alias results (limit 20)
--   GET /api/packs        -> JSON pack metadata

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json   = require("lib.format.json") --: any
local search = require("lib.platform.apps.system_dashboard.search")
local packs  = require("lib.platform.apps.system_dashboard.packs")

local M = {}

local MIME = {
	html = "text/html; charset=utf-8",
	js   = "application/javascript; charset=utf-8",
	css  = "text/css; charset=utf-8",
	json = "application/json",
	png  = "image/png",
	ico  = "image/x-icon",
	svg  = "image/svg+xml",
}

--: (string) -> string
local function ext_of(path)
	return path:match("%.([^./]+)$") or ""
end

-- Percent-decode a single hex escape like "2F" -> "/".
local pct_decode = function(h) --: (string) -> string
	return string.char(tonumber(h, 16) or 0x3F)
end

-- Parse ?key=value&... from a query string.
--: (string) -> { [string]: string }
local function parse_qs(qs)
	local params = {} --: { [string]: string }
	if qs == "" then return params end
	for kv in qs:gmatch("[^&]+") do
		local k, v = kv:match("^([^=]+)=?(.*)")
		if k and v then
			local v1 = (v:gsub("%%(%x%x)", pct_decode))
			local v2 = (v1:gsub("+", " "))
			params[k] = v2
		end
	end
	return params
end

-- Serve a static file from the tarball via caps.self.entry.
--: (any, any, any) -> boolean | nil
local function serve_static(self_cap, req, res)
	if not self_cap then return nil end
	local req_path = tostring(req.path or "/")
	local tarball_path
	if req_path == "/" then
		tarball_path = "static/index.html"
	elseif req_path:sub(1, 8) == "/static/" then
		tarball_path = "static" .. req_path:sub(8)
	else
		return nil
	end
	local content = self_cap.entry(tarball_path)
	if not content then return nil end
	local ext = ext_of(tarball_path)
	res.status = 200
	res.headers["Content-Type"] = MIME[ext] or "application/octet-stream"
	res.body = content
	return true
end

-- Handle API routes.
--: (any, any, any) -> boolean | nil
local function handle_api(state, req, res)
	local path   = tostring(req.path or "/")
	local method = tostring(req.method or "GET"):upper()

	if method ~= "GET" then return nil end

	if path == "/api/packs" or path:sub(1, 11) == "/api/packs?" then
		res.status = 200
		res.headers["Content-Type"] = MIME.json
		res.body = json.encode(state.pack_meta)
		return true
	end

	if path == "/api/search" or path:sub(1, 12) == "/api/search?" then
		local raw_qs = req.query
		local qs --: { [string]: string }
		if type(raw_qs) == "table" then
			qs = raw_qs
		else
			local qpart = path:match("^[^?]*%??(.*)")
			qs = parse_qs(qpart or "")
		end
		local q = qs.q or ""
		local results
		if q == "" then
			results = {}
			local aliases = state.aliases
			for i = 1, math.min(20, #aliases) do
				local a = aliases[i]
				local r = {}
				for k, v in pairs(a) do r[k] = v end
				r.score = 0
				results[#results + 1] = r
			end
		else
			results = search.search(state.aliases, q, 20)
		end
		res.status = 200
		res.headers["Content-Type"] = MIME.json
		res.body = json.encode(results)
		return true
	end

	return nil
end

function M.create(caps, opts)
	local caps_t    = caps  --: any
	local self_cap  = caps_t and caps_t.self
	local user_packs = caps_t and caps_t.user_packs
	local stdout_cap = caps_t and caps_t.stdout

	local no_self = {
		entries = function() return {} end,
		entry   = function() return nil end,
	}
	local effective_self = self_cap or no_self

	local builtin_aliases, builtin_meta = packs.load_builtin(effective_self)
	local user_aliases,    user_meta    = packs.load_user(user_packs)
	local merged = packs.merge(builtin_aliases, user_aliases)

	local all_meta = {}
	for _, m in ipairs(builtin_meta) do all_meta[#all_meta + 1] = m end
	for _, m in ipairs(user_meta)    do all_meta[#all_meta + 1] = m end

	if stdout_cap then
		stdout_cap.write("system_dashboard: loaded " .. #merged
			.. " aliases from " .. #all_meta .. " packs\n")
	end

	local state = {
		aliases   = merged,
		pack_meta = all_meta,
	}

	local function handler(req, res)
		res.headers = res.headers or {}
		if handle_api(state, req, res) then return true end
		if serve_static(self_cap, req, res) then return true end
		res.status = 404
		res.headers["Content-Type"] = "text/plain; charset=utf-8"
		res.body = "not found"
		return true
	end

	return { handler = handler }
end

return M
