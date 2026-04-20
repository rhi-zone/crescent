-- lib/platform/service/http.lua
-- HTTP projection for the service layer.
--
-- http.create(caps, methods, descriptors) -> { handler }
--
-- Builds an HTTP route table from a methods table at creation time.
-- Each method is mapped to an HTTP route via naming conventions
-- (or explicit descriptor overrides), then dispatched by the handler.
--
-- Route conventions:
--   get_*, fetch_*, read_*, list_*, find_*, search_* → GET
--   create_*, add_*, new_*                           → POST
--   update_*, set_*, edit_*                          → PATCH
--   delete_*, remove_*                               → DELETE
--   (fallback)                                       → POST
--
-- Path conventions:
--   Strip verb prefix. Underscores → slashes (resource path segments).
--   Params ending in _id → path segments (:param_id).
--   Other params:
--     GET  → query string
--     POST/PATCH/DELETE → JSON body
--
-- Usage:
--   local http = require("lib.platform.service.http")
--   local srv   = http.create(caps, methods, descriptors)
--   -- srv.handler is a function(req, res) compatible with the platform cap

if package and not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json")

local M = {}

-- ── Naming convention helpers ──────────────────────────────────────────────

-- Verb prefixes, ordered so longer prefixes are tried first to avoid
-- "search" matching "set" when it shouldn't (search_ vs set_).
local GET_PREFIXES    = { "search_", "fetch_", "find_", "read_", "list_", "get_" }
local POST_PREFIXES   = { "create_", "add_", "new_" }
local PATCH_PREFIXES  = { "update_", "edit_", "set_" }
local DELETE_PREFIXES = { "delete_", "remove_" }

-- infer_http_method(name) -> "GET"|"POST"|"PATCH"|"DELETE"
--: (string) -> string
local function infer_http_method(name)
	for _, p in ipairs(GET_PREFIXES) do
		if name:sub(1, #p) == p then return "GET" end
	end
	for _, p in ipairs(POST_PREFIXES) do
		if name:sub(1, #p) == p then return "POST" end
	end
	for _, p in ipairs(PATCH_PREFIXES) do
		if name:sub(1, #p) == p then return "PATCH" end
	end
	for _, p in ipairs(DELETE_PREFIXES) do
		if name:sub(1, #p) == p then return "DELETE" end
	end
	return "POST"
end

local ALL_PREFIXES = {}
for _, p in ipairs(GET_PREFIXES)    do ALL_PREFIXES[#ALL_PREFIXES + 1] = p end
for _, p in ipairs(POST_PREFIXES)   do ALL_PREFIXES[#ALL_PREFIXES + 1] = p end
for _, p in ipairs(PATCH_PREFIXES)  do ALL_PREFIXES[#ALL_PREFIXES + 1] = p end
for _, p in ipairs(DELETE_PREFIXES) do ALL_PREFIXES[#ALL_PREFIXES + 1] = p end

-- strip_verb(name) -> resource (verb prefix removed, remainder kept)
--: (string) -> string
local function strip_verb(name)
	for _, p in ipairs(ALL_PREFIXES) do
		if name:sub(1, #p) == p then return name:sub(#p + 1) end
	end
	return name
end

-- is_id_param(param_name) -> boolean
--: (string) -> boolean
local function is_id_param(param_name)
	return param_name:sub(-3) == "_id" or param_name == "id"
end

-- param_names_of(fn) -> { string, ... }
-- Introspect a function's parameter names via debug.getinfo.
-- Returns an empty table when not available (non-LuaJIT / no debug info).
-- NOTE: this only works when the function was compiled with debug info.
-- The first parameter is always "caps" by convention and is skipped.
--: (unknown) -> { [integer]: string }
local function param_names_of(fn)
	local info = debug.getinfo(fn, "u")
	if not info then return {} end
	local nparams = info.nparams or 0
	local params = {}
	-- parameters are locals 1..nparams; local 1 is "caps", skip it
	for i = 2, nparams do
		local name = debug.getlocal(fn, i)
		if name then
			params[#params + 1] = name
		end
	end
	return params
end

-- infer_path(method_name, http_method, param_names)
--   -> path_pattern, id_params_in_path
-- path_pattern uses :name for path params.
-- id_params_in_path is { string, ... } — param names embedded in the path.
--: (string, string, { [integer]: string }) -> string, { [integer]: string }
local function infer_path(method_name, http_method, param_names)
	local resource = strip_verb(method_name)
	-- Replace underscores → hyphens in the resource segment.
	-- (The resource after stripping is typically a single word or compound.)
	local resource_seg = resource:gsub("_", "-")

	-- Collect id params to embed as path segments.
	local path_parts  = { "/" .. resource_seg }
	local id_in_path  = {}

	for _, pname in ipairs(param_names) do
		if is_id_param(pname) then
			path_parts[#path_parts + 1] = "/:" .. pname
			id_in_path[#id_in_path + 1] = pname
		end
	end

	return table.concat(path_parts), id_in_path
end

-- ── Query-string parser ────────────────────────────────────────────────────

--: (string | nil) -> { [string]: string }
local function parse_query(qs)
	local params = {} --: { [string]: string }
	if not qs or qs == "" then return params end
	for kv in qs:gmatch("[^&]+") do
		local k, v = kv:match("^([^=]+)=?(.*)")
		if k then
			v = v:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
			v = v:gsub("+", " ")
			params[k] = v
		end
	end
	return params
end

-- ── Route matching ─────────────────────────────────────────────────────────

-- match_path(pattern, path) -> captures | nil
-- pattern: "/resource/:id/sub/:other_id"
-- path:    "/resource/42/sub/7"
-- returns: { id = "42", other_id = "7" } or nil on no match
--: (string, string) -> { [string]: string } | nil
local function match_path(pattern, path)
	-- Build a Lua pattern from the route pattern.
	-- 1. Replace :param placeholders with capture groups first (before escaping).
	-- 2. Escape remaining Lua magic characters in the non-capture parts.
	-- 3. Anchor with ^ and $.
	local param_names = {}

	-- Split pattern into literal segments and :param tokens, then rebuild
	-- as a Lua pattern with captures.
	local parts = {}
	local pos = 1
	local n = #pattern
	while pos <= n do
		-- Find next :param
		local s, e, name = pattern:find(":([%w_]+)", pos)
		if not s then
			-- Escape the rest as literal.
			parts[#parts + 1] = pattern:sub(pos):gsub("([%.%+%*%?%[%]%(%)%^%$%%])", "%%%1")
			break
		end
		-- Escape the literal part before this token.
		if s > pos then
			parts[#parts + 1] = pattern:sub(pos, s - 1):gsub("([%.%+%*%?%[%]%(%)%^%$%%])", "%%%1")
		end
		param_names[#param_names + 1] = name
		parts[#parts + 1] = "([^/]+)"
		pos = e + 1
	end

	local lua_pat = "^" .. table.concat(parts) .. "$"

	-- Match
	local captures = { path:match(lua_pat) }
	if #param_names == 0 then
		-- Exact match: path:match returns the whole string on success.
		if not path:match(lua_pat) then return nil end
		return {}
	end
	if not captures[1] then return nil end
	local result = {}
	for i, name in ipairs(param_names) do
		result[name] = captures[i]
	end
	return result
end

-- ── Response helpers ───────────────────────────────────────────────────────

local CONTENT_JSON = "application/json"

local function json_ok(res, data)
	res.status = 200
	res.headers["Content-Type"] = { CONTENT_JSON }
	res.body = json.encode(data)
end

local function json_err(res, status, msg)
	res.status = status
	res.headers["Content-Type"] = { CONTENT_JSON }
	res.body = json.encode({ error = msg })
end

-- ── Route table builder ────────────────────────────────────────────────────

-- Each route entry:
-- { method, pattern, param_names, id_in_path, fn_name, fn }

--: (unknown, { [string]: unknown }, { [string]: unknown } | nil) -> { [integer]: unknown }
local function build_routes(caps, methods, descriptors)
	descriptors = descriptors or {}
	local routes = {}

	for fn_name, fn in pairs(methods) do
		local desc = descriptors[fn_name] or {}
		local http_method
		local path_pattern
		local param_names = param_names_of(fn)

		if desc.method then
			http_method = desc.method:upper()
		else
			http_method = infer_http_method(fn_name)
		end

		if desc.path then
			path_pattern = desc.path
			-- Extract param names from the explicit path (:name segments).
			local id_in_path = {}
			for name in path_pattern:gmatch(":([%w_]+)") do
				id_in_path[#id_in_path + 1] = name
			end
			routes[#routes + 1] = {
				method       = http_method,
				pattern      = path_pattern,
				param_names  = param_names,
				id_in_path   = id_in_path,
				fn_name      = fn_name,
				fn           = fn,
				help         = desc.help,
			}
		else
			local pat, id_in_path = infer_path(fn_name, http_method, param_names)
			routes[#routes + 1] = {
				method       = http_method,
				pattern      = pat,
				param_names  = param_names,
				id_in_path   = id_in_path,
				fn_name      = fn_name,
				fn           = fn,
				help         = desc.help,
			}
		end
	end

	return routes
end

-- ── Handler ────────────────────────────────────────────────────────────────

--: (unknown, { [string]: unknown }, { [string]: unknown } | nil) -> { handler: unknown }
function M.create(caps, methods, descriptors)
	local routes = build_routes(caps, methods, descriptors)

	local function handler(req, res)
		res.headers = res.headers or {}
		local req_method = (req.method or "GET"):upper()
		local req_path   = req.path or "/"

		for _, route in ipairs(routes) do
			if route.method == req_method then
				local path_caps = match_path(route.pattern, req_path)
				if path_caps then
					-- Build the ordered argument list.
					-- param_names is in declaration order (caps already excluded).
					-- id params come from path; other params from query or body.
					local body_params = {}
					if req_method == "GET" then
						local qs = req.query or req_path:match("%?(.+)$")
						body_params = parse_query(qs)
					elseif req.body and req.body ~= "" then
						local decoded, err = json.decode(req.body)
						if not decoded then
							json_err(res, 400, "invalid JSON body: " .. tostring(err))
							return true
						end
						if type(decoded) == "table" then
							body_params = decoded
						end
					end

					local call_args = { caps }
					for _, pname in ipairs(route.param_names) do
						if path_caps[pname] then
							call_args[#call_args + 1] = path_caps[pname]
						else
							call_args[#call_args + 1] = body_params[pname]
						end
					end

					local ok, result, err = pcall(function()
						return route.fn(unpack(call_args))
					end)

					if not ok then
						-- result holds the error message from pcall
						json_err(res, 500, tostring(result))
						return true
					end

					if result == nil and err ~= nil then
						-- (nil, errmsg) convention
						json_err(res, 400, tostring(err))
						return true
					end

					json_ok(res, result)
					return true
				end
			end
		end

		-- No route matched.
		json_err(res, 404, "not found: " .. req_method .. " " .. req_path)
		return true
	end

	return { handler = handler, _routes = routes }
end

-- Exposed for testing.
M._infer_http_method = infer_http_method
M._infer_path        = infer_path
M._strip_verb        = strip_verb
M._match_path        = match_path
M._parse_query       = parse_query
M._param_names_of    = param_names_of

return M
