-- lib/openapi/init.lua
-- OpenAPI 3.x spec parser with request validation and typed route generation.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json") --[[:! { decode: (string) -> (unknown, string | nil), encode: (unknown) -> string, null: unknown }]]

local M = {}

--:: openapi_doc = { openapi: string, info: { [string]: unknown }, paths?: { [string]: { [string]: unknown } }, components?: { [string]: unknown }, ... }
--:: openapi_schema = { type?: string, allOf?: openapi_schema[], anyOf?: openapi_schema[], oneOf?: openapi_schema[], enum?: unknown[], minLength?: integer, maxLength?: integer, pattern?: string, minimum?: number, maximum?: number, required?: string[], properties?: { [string]: openapi_schema }, additionalProperties?: boolean, items?: openapi_schema, minItems?: integer, maxItems?: integer, ... }
--:: openapi_error = { path: string, message: string }
--:: openapi_operation = { method: string, path: string, operationId: string | nil, parameters: { [integer]: unknown } | nil, requestBody: { [string]: unknown } | nil, responses: { [string]: unknown } | nil, summary: string | nil, description: string | nil, tags: string[] | nil }
--:: openapi_spec = { _doc: openapi_doc, operation: (openapi_spec, string) -> openapi_operation | nil, operations: (openapi_spec) -> Arr<openapi_operation>, paths: (openapi_spec) -> { [integer]: string }, validate_request: (openapi_spec, openapi_request) -> (boolean | nil, Arr<openapi_error> | nil), validate_response: (openapi_spec, string, integer, openapi_response) -> (boolean | nil, Arr<openapi_error> | nil), mount: (openapi_spec, unknown, openapi_handlers) -> nil, router: (openapi_spec, openapi_handlers) -> unknown, ... }
--:: openapi_request = { method?: string, path?: string, headers?: { [string]: string }, query?: { [string]: string }, body?: unknown, ... }
--:: openapi_response = { headers?: { [string]: string }, body?: unknown, ... }
--:: openapi_handlers = { [string]: (req: openapi_request, res: openapi_response) -> nil }

local type_of = type
local pairs = pairs
local ipairs = ipairs
local tonumber = tonumber
local tostring = tostring
local concat = table.concat
local insert = table.insert
local find = string.find
local sub = string.sub
local match = string.match
local lower = string.lower
local floor = math.floor

-- ── $ref resolution ─────────────────────────────────────────────────────────

-- Resolve a JSON Pointer path (e.g. "#/components/schemas/User") against root.
--: (openapi_doc, string) -> unknown | nil
local function resolve_pointer(root, ref)
	if sub(ref, 1, 2) ~= "#/" then return nil end
	local node = root --[[: unknown]]
	local pos = 3
	local len = #ref
	while pos <= len do
		local slash = find(ref, "/", pos, true)
		local seg = sub(ref, pos, slash and slash - 1 or len)
		-- JSON Pointer escapes: ~1 -> /, ~0 -> ~
		seg = seg:gsub("~1", "/"):gsub("~0", "~")
		pos = slash and slash + 1 or len + 1
		if type_of(node) ~= "table" then return nil end
		node = (node --[[:! { [string]: unknown }]])[seg]
		if node == nil then return nil end
	end
	return node
end

-- Walk the spec tree and resolve all $ref references in-place.
-- Uses a visited set to handle circular references.
--: (openapi_doc, { [unknown]: unknown }, ({ [unknown]: boolean } | nil)) -> ()
local function resolve_refs(root, node, visited)
	if type_of(node) ~= "table" then return end
	if not visited then visited = {} end
	if visited[node] then return end
	visited[node] = true
	-- Check if this node is a $ref
	-- We don't resolve the node itself (caller handles that), but we resolve
	-- all children that are $ref objects.
	for k, v in pairs(node) do
		if type_of(v) == "table" then
			local vt = v --[[:! { [string]: unknown }]]
			if type_of(vt["$ref"]) == "string" then
				local ref_str = vt["$ref"] --[[:! string]]
				local target = resolve_pointer(root, ref_str)
				if target then
					node[k] = target
					-- Continue resolving the target
					resolve_refs(root, --[[:! { [unknown]: unknown }]] target, visited)
				end
			else
				resolve_refs(root, --[[:! { [unknown]: unknown }]] v, visited)
			end
		end
	end
end

-- ── JSON Schema validation ──────────────────────────────────────────────────

--: (unknown, openapi_schema, (string | nil)) -> (boolean | nil, Arr<openapi_error> | nil)
function M.validate_schema(value, schema, path)
	path = path or ""
	local errors = {} --[[:! Arr<openapi_error>]]

	--: (string, string) -> ()
	local function add_err(p, msg)
		errors[#errors + 1] = { path = p, message = msg }
	end

	--: (unknown, openapi_schema, string) -> ()
	local function validate(val, sch, p)
		if type_of(sch) ~= "table" then return end

		-- allOf: all must match
		if sch.allOf then
			for i = 1, #sch.allOf do
				local ok, errs = M.validate_schema(val, sch.allOf[i], p)
				if not ok then
					for _, e in ipairs(errs) do
						errors[#errors + 1] = e
					end
				end
			end
		end

		-- anyOf: at least one must match
		if sch.anyOf then
			local any_ok = false
			for i = 1, #sch.anyOf do
				local ok = M.validate_schema(val, sch.anyOf[i], p)
				if ok then any_ok = true; break end
			end
			if not any_ok then
				add_err(p, "value does not match any of the anyOf schemas")
			end
		end

		-- oneOf: exactly one must match
		if sch.oneOf then
			local count = 0
			for i = 1, #sch.oneOf do
				local ok = M.validate_schema(val, sch.oneOf[i], p)
				if ok then count = count + 1 end
			end
			if count ~= 1 then
				add_err(p, "value must match exactly one oneOf schema, matched " .. count)
			end
		end

		-- type check
		if sch.type then
			local st = sch.type
			local vt = type_of(val)
			local ok = false
			if st == "string" then
				ok = vt == "string"
			elseif st == "number" then
				ok = vt == "number"
			elseif st == "integer" then
				ok = (vt == "number" and val == floor(--[[:! number]] val)) == true
			elseif st == "boolean" then
				ok = vt == "boolean"
			elseif st == "array" then
				local tval = --[[:! { [integer]: unknown }]] val
				ok = (vt == "table" and (#tval > 0 or next(tval) == nil)) == true
			elseif st == "object" then
				ok = vt == "table"
			elseif st == "null" then
				ok = val == nil or val == json.null
			end
			if not ok then
				add_err(p, "expected type " .. st .. ", got " .. vt)
				return -- type mismatch, skip further validation
			end
		end

		-- enum
		if sch.enum then
			local found = false
			for _, ev in ipairs(sch.enum) do
				if val == ev then found = true; break end
			end
			if not found then
				add_err(p, "value not in enum")
			end
		end

		-- string constraints
		if type_of(val) == "string" then
			local sval = --[[:! string]] val
			if sch.minLength and #sval < sch.minLength then
				add_err(p, "string length " .. #sval .. " is less than minLength " .. sch.minLength)
			end
			if sch.maxLength and #sval > sch.maxLength then
				add_err(p, "string length " .. #sval .. " exceeds maxLength " .. sch.maxLength)
			end
			if sch.pattern then
				if not sval:find(sch.pattern) then
					add_err(p, "string does not match pattern")
				end
			end
		end

		-- numeric constraints
		if type_of(val) == "number" then
			local nval = --[[:! number]] val
			if sch.minimum and nval < sch.minimum then
				add_err(p, "value " .. nval .. " is less than minimum " .. sch.minimum)
			end
			if sch.maximum and nval > sch.maximum then
				add_err(p, "value " .. nval .. " exceeds maximum " .. sch.maximum)
			end
		end

		-- object constraints
		if type_of(val) == "table" and sch.type == "object" then
			local tval = --[[:! { [string]: unknown }]] val
			-- required
			if sch.required then
				for _, rname in ipairs(sch.required) do
					if tval[rname] == nil then
						add_err(p .. "/" .. rname, "required field missing")
					end
				end
			end
			-- properties
			if sch.properties then
				for pname, pschema in pairs(sch.properties) do
					if tval[pname] ~= nil then
						validate(tval[pname], pschema, p .. "/" .. pname)
					end
				end
			end
			-- additionalProperties
			if sch.additionalProperties == false and sch.properties then
				for k in pairs(tval) do
					if type_of(k) == "string" and not sch.properties[k] then
						add_err(p .. "/" .. k, "additional property not allowed")
					end
				end
			end
		end

		-- array constraints
		if type_of(val) == "table" and sch.type == "array" then
			local aval = --[[:! { [integer]: unknown }]] val
			if sch.items then
				for i = 1, #aval do
					validate(aval[i], sch.items, p .. "/" .. (i - 1))
				end
			end
			if sch.minItems and #aval < sch.minItems then
				add_err(p, "array has " .. #aval .. " items, minimum is " .. sch.minItems)
			end
			if sch.maxItems and #aval > sch.maxItems then
				add_err(p, "array has " .. #aval .. " items, maximum is " .. sch.maxItems)
			end
		end
	end

	validate(value, schema, path)

	if #errors > 0 then
		return nil, errors
	end
	return true, nil
end

-- ── Spec object ─────────────────────────────────────────────────────────────

local Spec = {}
Spec.__index = Spec

-- Convert OpenAPI path template to a Lua pattern and extract param names.
-- /users/{id}/posts -> "^/users/([^/]+)/posts$", {"id"}
--: (string) -> (string, string[])
local function path_to_pattern(path)
	local parts = {}
	local params = {}
	local pos = 1
	local len = #path
	while pos <= len do
		local open = find(path, "{", pos, true)
		if open then
			-- literal before the {
			if open > pos then
				parts[#parts + 1] = sub(path, pos, open - 1):gsub("([%.%+%-%*%?%[%]%^%$%(%)%%])", "%%%1")
			end
			local close = find(path, "}", open + 1, true)
			if not close then break end
			local pname = sub(path, open + 1, close - 1)
			params[#params + 1] = pname
			parts[#parts + 1] = "([^/]+)"
			pos = close + 1
		else
			parts[#parts + 1] = sub(path, pos):gsub("([%.%+%-%*%?%[%]%^%$%(%)%%])", "%%%1")
			break
		end
	end
	return "^" .. concat(parts) .. "$", params
end

-- Convert OpenAPI path template to lib/web route path.
-- /users/{id} -> /users/:id
--: (string) -> string
local function openapi_path_to_web_path(path)
	local result, _ = path:gsub("{([^}]+)}", ":%1")
	return result
end

--: (openapi_spec) -> string[]
function Spec:paths()
	local result = {} --[[:! { [integer]: string }]]
	if self._doc.paths then
		local paths_doc = self._doc.paths --[[:! { [string]: { [string]: unknown } }]]
		for p in pairs(paths_doc) do
			result[#result + 1] = p
		end
	end
	return result
end

local HTTP_METHODS = { get = true, put = true, post = true, delete = true, patch = true, options = true, head = true, trace = true }

--: (openapi_spec) -> openapi_operation[]
function Spec:operations()
	local result = {} --[[:! Arr<openapi_operation>]]
	if not self._doc.paths then return result end
	local ops_paths = self._doc.paths --[[:! { [string]: { [string]: unknown } }]]
	for path, path_item in pairs(ops_paths) do
		for method, op in pairs(path_item) do
			if HTTP_METHODS[method] and type_of(op) == "table" then
				local top = --[[:! { [string]: unknown }]] op
				result[#result + 1] = {
					method = method --[[:! string]],
					path = path --[[:! string]],
					operationId = --[[:! string | nil]] top.operationId,
					parameters = --[[:! { [integer]: unknown } | nil]] top.parameters,
					requestBody = --[[:! { [string]: unknown } | nil]] top.requestBody,
					responses = --[[:! { [string]: unknown } | nil]] top.responses,
					summary = --[[:! string | nil]] top.summary,
					description = --[[:! string | nil]] top.description,
					tags = --[[:! Arr<string> | nil]] top.tags,
				}
			end
		end
	end
	return result
end

--: (openapi_spec, string) -> openapi_operation | nil
function Spec:operation(operation_id)
	if not self._doc.paths then return nil end
	local op_paths = self._doc.paths --[[:! { [string]: { [string]: unknown } }]]
	for path, path_item in pairs(op_paths) do
		for method, op in pairs(path_item) do
			local top = --[[:! { [string]: unknown }]] op
			if HTTP_METHODS[method] and type_of(op) == "table" and top.operationId == operation_id then
				return {
					method = method --[[:! string]],
					path = path --[[:! string]],
					operationId = --[[:! string | nil]] top.operationId,
					parameters = --[[:! { [integer]: unknown } | nil]] top.parameters,
					requestBody = --[[:! { [string]: unknown } | nil]] top.requestBody,
					responses = --[[:! { [string]: unknown } | nil]] top.responses,
					summary = --[[:! string | nil]] top.summary,
					description = --[[:! string | nil]] top.description,
					tags = --[[:! Arr<string> | nil]] top.tags,
				}
			end
		end
	end
	return nil
end

-- ── Request validation ──────────────────────────────────────────────────────

--: (openapi_spec, openapi_request) -> (boolean | nil, Arr<openapi_error> | nil)
function Spec:validate_request(req)
	local errors = {} --[[:! Arr<openapi_error>]]
	local method = lower(req.method or "get")
	local req_path = req.path or "/"

	if not self._doc.paths then
		errors[#errors + 1] = { path = "", message = "spec has no paths" }
		return nil, errors
	end

	-- Find matching path
	local matched_path_item, matched_params, matched_path_template
	local doc_paths = self._doc.paths --[[:! { [string]: { [string]: unknown } }]]
	for path_template, path_item in pairs(doc_paths) do
		local pattern, param_names = path_to_pattern(path_template)
		local captures = { match(req_path, pattern) }
		if #captures > 0 or req_path:find(pattern) then
			matched_path_item = path_item
			matched_path_template = path_template
			matched_params = {}
			for i, name in ipairs(param_names) do
				matched_params[name] = captures[i]
			end
			break
		end
	end

	-- Also handle exact match (no params)
	if not matched_path_item and doc_paths[req_path] then
		matched_path_item = doc_paths[req_path]
		matched_path_template = req_path
		matched_params = {}
	end

	if not matched_path_item then
		errors[#errors + 1] = { path = "", message = "path not found: " .. req_path }
		return nil, errors
	end

	-- Check method
	local op_raw = matched_path_item[method]
	if not op_raw then
		errors[#errors + 1] = { path = "", message = "method not allowed: " .. method:upper() }
		return nil, errors
	end
	local op = op_raw --[[:! { [string]: unknown }]]

	-- Validate parameters
	if op.parameters then
		for _, param_unk in ipairs(op.parameters --[[:! { [integer]: unknown }]]) do
			local param = param_unk --[[:! { [string]: unknown }]]
			local loc = param["in"] --[[:! string | nil]]
			local name = param.name --[[:! string | nil]]
			local required = param.required --[[:! boolean | nil]]
			local val
			if loc == "query" then
				val = req.query and req.query[name --[[:! string]]]
			elseif loc == "header" then
				val = req.headers and (req.headers[name --[[:! string]]] or req.headers[lower(name --[[:! string]])])
			elseif loc == "path" then
				val = matched_params and matched_params[name --[[:! string]]]
			end
			if required and (val == nil or val == "") then
				errors[#errors + 1] = { path = "/" .. (loc or "") .. "/" .. (name or ""), message = "required " .. (loc or "") .. " parameter missing: " .. (name or "") }
			end
			-- Basic type coercion check for query/path params (they arrive as strings)
			local param_schema = param.schema --[[:! { type?: string } | nil]]
			if val and param_schema and param_schema.type then
				local st = param_schema.type or ""
				if st == "integer" or st == "number" then
					local n = tonumber(val --[[:! string]])
					if not n then
						errors[#errors + 1] = { path = "/" .. (loc or "") .. "/" .. (name or ""), message = (loc or "") .. " parameter '" .. (name or "") .. "' must be " .. st }
					elseif st == "integer" and (n --[[:! number]]) ~= floor(n --[[:! number]]) then
						errors[#errors + 1] = { path = "/" .. (loc or "") .. "/" .. (name or ""), message = (loc or "") .. " parameter '" .. (name or "") .. "' must be integer" }
					end
				end
			end
		end
	end

	-- Validate request body
	if op.requestBody then
		local rb = op.requestBody --[[:! { [string]: unknown }]]
		local rb_required = rb.required --[[:! boolean | nil]]
		local rb_content = rb.content --[[:! { [string]: unknown } | nil]]
		local ct = req.headers and (req.headers["content-type"] or req.headers["Content-Type"]) or ""
		if rb_required and (not req.body or req.body == "") then
			errors[#errors + 1] = { path = "/body", message = "request body is required" }
		elseif req.body and req.body ~= "" and rb_content then
			-- Find matching content type
			local media_type
			for mt in pairs(rb_content) do
				if find(ct, mt, 1, true) or find(mt, ct, 1, true) or mt == "*/*" then
					media_type = rb_content[mt]
					break
				end
			end
			if not media_type then
				-- Try application/json as default
				media_type = rb_content["application/json"]
			end
			local media_type_tbl = media_type --[[:! { [string]: unknown } | nil]]
			if media_type_tbl and media_type_tbl.schema then
				local body_val, parse_err = json.decode(req.body --[[:! string]])
				if not body_val and parse_err then
					errors[#errors + 1] = { path = "/body", message = "invalid JSON body: " .. tostring(parse_err) }
				elseif body_val then
					local ok, schema_errs = M.validate_schema(body_val, media_type_tbl.schema --[[:! openapi_schema]], "/body")
					if not ok then
						for _, e in ipairs(schema_errs) do
							errors[#errors + 1] = e
						end
					end
				end
			end
		end
	end

	if #errors > 0 then
		return nil, errors
	end
	return true, nil
end

-- ── Response validation ─────────────────────────────────────────────────────

--: (openapi_spec, string, integer, openapi_response) -> (boolean | nil, Arr<openapi_error> | nil)
function Spec:validate_response(operation_id, status_code, resp)
	local errors = {} --[[:! Arr<openapi_error>]]
	local op = self:operation(operation_id)
	if not op then
		errors[#errors + 1] = { path = "", message = "operation not found: " .. operation_id }
		return nil, errors
	end

	local status_str = tostring(status_code)
	local op_responses = op.responses --[[:! { [string]: unknown } | nil]]
	local resp_spec_key = op_responses and op_responses[status_str]
	local resp_spec_default = (not resp_spec_key and op_responses) and op_responses["default"]
	local resp_spec = resp_spec_key or resp_spec_default
	if not resp_spec then
		errors[#errors + 1] = { path = "", message = "no response spec for status " .. status_str }
		return nil, errors
	end
	local resp_spec_tbl = resp_spec --[[:! { [string]: unknown }]]

	-- Validate response body
	if resp_spec_tbl.content and resp.body then
		local ct = resp.headers and (resp.headers["content-type"] or resp.headers["Content-Type"]) or "application/json"
		local resp_content = resp_spec_tbl.content --[[:! { [string]: unknown }]]
		local media_type
		for mt in pairs(resp_content) do
			if find(ct, mt, 1, true) or find(mt, ct, 1, true) then
				media_type = resp_content[mt]
				break
			end
		end
		local media_type_tbl = media_type --[[:! { [string]: unknown } | nil]]
		if media_type_tbl and media_type_tbl.schema then
			local body_val, parse_err = json.decode(resp.body --[[:! string]])
			if not body_val and parse_err then
				errors[#errors + 1] = { path = "/body", message = "invalid JSON body: " .. tostring(parse_err) }
			elseif body_val then
				local ok, schema_errs = M.validate_schema(body_val, media_type_tbl.schema --[[:! openapi_schema]], "/body")
				if not ok then
					for _, e in ipairs(schema_errs) do
						errors[#errors + 1] = e
					end
				end
			end
		end
	end

	if #errors > 0 then
		return nil, errors
	end
	return true, nil
end

-- ── Route generation ────────────────────────────────────────────────────────

-- Returns a table mapping method -> web_path -> handler for use with lib/web.
--: (openapi_spec, openapi_handlers) -> unknown
function Spec:router(handlers)
	local web = require("lib.web")
	local app = web.app()
	self:mount(app, handlers)
	return app
end

-- Mount all OpenAPI operations onto an existing web app.
--: (openapi_spec, unknown, openapi_handlers) -> ()
function Spec:mount(app, handlers)
	if not self._doc.paths then return end
	local spec = self
	local mount_paths = self._doc.paths --[[:! { [string]: { [string]: unknown } }]]
	for path_template, path_item in pairs(mount_paths) do
		local web_path = openapi_path_to_web_path(path_template)
		for method, op in pairs(path_item) do
			local op_tbl = op --[[:! { [string]: unknown }]]
			if HTTP_METHODS[method] and type_of(op) == "table" and op_tbl.operationId then
				local op_id = op_tbl.operationId --[[:! string]]
				local handler = handlers[op_id]
				if handler then
					local app_tbl = app --[[:! { [string]: unknown }]]
					local register_unk = app_tbl[method]
					if register_unk then
						local register = register_unk --[[:! (unknown, string, unknown) -> nil]]
						register(app_tbl --[[:! unknown]], web_path, function(req, res)
							-- Validate request
							local ok, errs = spec:validate_request({
								method = req.method or method:upper(),
								path = req.path or path_template,
								headers = req.headers or {},
								query = req.query or {},
								body = req.body,
							})
							if not ok then
								res.status = 400
								res.headers["Content-Type"] = { "application/json" }
								res.body = json.encode({ errors = errs })
								return
							end
							handler(req, res)
						end)
					end
				end
			end
		end
	end
end

-- ── Parsing ─────────────────────────────────────────────────────────────────

--: (openapi_doc) -> (openapi_spec | nil, string | nil)
function M.parse_table(doc)
	if type_of(doc) ~= "table" then
		return nil, "expected table, got " .. type_of(doc)
	end
	if not doc.openapi then
		return nil, "missing required field: openapi"
	end
	if not doc.info then
		return nil, "missing required field: info"
	end
	-- Resolve $ref references
	resolve_refs(doc, doc)
	return setmetatable({ _doc = doc }, Spec) --[[:! openapi_spec]], nil
end

--: (string) -> (openapi_spec | nil, string | nil)
function M.parse(json_string)
	if type_of(json_string) ~= "string" then
		return nil, "expected string, got " .. type_of(json_string)
	end
	local doc, err = json.decode(json_string)
	if not doc then
		return nil, "JSON parse error: " .. tostring(err)
	end
	return M.parse_table(doc --[[:! openapi_doc]])
end

return M
