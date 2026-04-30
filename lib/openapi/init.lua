-- lib/openapi/init.lua
-- OpenAPI 3.x spec parser with request validation and typed route generation.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json")

local M = {}

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
--: (table, string) -> unknown | nil
local function resolve_pointer(root, ref)
	if sub(ref, 1, 2) ~= "#/" then return nil end
	local node = root
	local pos = 3
	local len = #ref
	while pos <= len do
		local slash = find(ref, "/", pos, true)
		local seg = sub(ref, pos, slash and slash - 1 or len)
		-- JSON Pointer escapes: ~1 -> /, ~0 -> ~
		seg = seg:gsub("~1", "/"):gsub("~0", "~")
		pos = slash and slash + 1 or len + 1
		if type_of(node) ~= "table" then return nil end
		node = node[seg]
		if node == nil then return nil end
	end
	return node
end

-- Walk the spec tree and resolve all $ref references in-place.
-- Uses a visited set to handle circular references.
--: (table, table, (table | nil)) -> ()
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
			if type_of(v["$ref"]) == "string" then
				local target = resolve_pointer(root, v["$ref"])
				if target then
					node[k] = target
					-- Continue resolving the target
					resolve_refs(root, --[[:! table]] target, visited)
				end
			else
				resolve_refs(root, --[[:! table]] v, visited)
			end
		end
	end
end

-- ── JSON Schema validation ──────────────────────────────────────────────────

--: (unknown, table, (string | nil)) -> (true, nil) | (nil, table)
function M.validate_schema(value, schema, path)
	path = path or ""
	local errors = {}

	local function add_err(p, msg)
		errors[#errors + 1] = { path = p, message = msg }
	end

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
				ok = vt == "number" and val == floor(val)
			elseif st == "boolean" then
				ok = vt == "boolean"
			elseif st == "array" then
				ok = vt == "table" and (#val > 0 or next(val) == nil)
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
			if sch.minLength and #val < sch.minLength then
				add_err(p, "string length " .. #val .. " is less than minLength " .. sch.minLength)
			end
			if sch.maxLength and #val > sch.maxLength then
				add_err(p, "string length " .. #val .. " exceeds maxLength " .. sch.maxLength)
			end
			if sch.pattern then
				if not val:find(sch.pattern) then
					add_err(p, "string does not match pattern")
				end
			end
		end

		-- numeric constraints
		if type_of(val) == "number" then
			if sch.minimum and val < sch.minimum then
				add_err(p, "value " .. val .. " is less than minimum " .. sch.minimum)
			end
			if sch.maximum and val > sch.maximum then
				add_err(p, "value " .. val .. " exceeds maximum " .. sch.maximum)
			end
		end

		-- object constraints
		if type_of(val) == "table" and sch.type == "object" then
			-- required
			if sch.required then
				for _, rname in ipairs(sch.required) do
					if val[rname] == nil then
						add_err(p .. "/" .. rname, "required field missing")
					end
				end
			end
			-- properties
			if sch.properties then
				for pname, pschema in pairs(sch.properties) do
					if val[pname] ~= nil then
						validate(val[pname], pschema, p .. "/" .. pname)
					end
				end
			end
			-- additionalProperties
			if sch.additionalProperties == false and sch.properties then
				for k in pairs(val) do
					if type_of(k) == "string" and not sch.properties[k] then
						add_err(p .. "/" .. k, "additional property not allowed")
					end
				end
			end
		end

		-- array constraints
		if type_of(val) == "table" and sch.type == "array" then
			if sch.items then
				for i = 1, #val do
					validate(val[i], sch.items, p .. "/" .. (i - 1))
				end
			end
			if sch.minItems and #val < sch.minItems then
				add_err(p, "array has " .. #val .. " items, minimum is " .. sch.minItems)
			end
			if sch.maxItems and #val > sch.maxItems then
				add_err(p, "array has " .. #val .. " items, maximum is " .. sch.maxItems)
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
	return (path:gsub("{([^}]+)}", ":%1"))
end

--: (table) -> string[]
function Spec:paths()
	local result = {}
	if self._doc.paths then
		for p in pairs(self._doc.paths) do
			result[#result + 1] = p
		end
	end
	return result
end

local HTTP_METHODS = { get = true, put = true, post = true, delete = true, patch = true, options = true, head = true, trace = true }

--: (table) -> table[]
function Spec:operations()
	local result = {}
	if not self._doc.paths then return result end
	for path, path_item in pairs(self._doc.paths) do
		for method, op in pairs(path_item) do
			if HTTP_METHODS[method] and type_of(op) == "table" then
				result[#result + 1] = {
					method = method,
					path = path,
					operationId = op.operationId,
					parameters = op.parameters,
					requestBody = op.requestBody,
					responses = op.responses,
					summary = op.summary,
					description = op.description,
					tags = op.tags,
				}
			end
		end
	end
	return result
end

--: (table, string) -> table | nil
function Spec:operation(operation_id)
	if not self._doc.paths then return nil end
	for path, path_item in pairs(self._doc.paths) do
		for method, op in pairs(path_item) do
			if HTTP_METHODS[method] and type_of(op) == "table" and op.operationId == operation_id then
				return {
					method = method,
					path = path,
					operationId = op.operationId,
					parameters = op.parameters,
					requestBody = op.requestBody,
					responses = op.responses,
					summary = op.summary,
					description = op.description,
					tags = op.tags,
				}
			end
		end
	end
	return nil
end

-- ── Request validation ──────────────────────────────────────────────────────

--: (table, table) -> (true, nil) | (nil, table)
function Spec:validate_request(req)
	local errors = {}
	local method = lower(req.method or "get")
	local req_path = req.path or "/"

	if not self._doc.paths then
		errors[#errors + 1] = { path = "", message = "spec has no paths" }
		return nil, errors
	end

	-- Find matching path
	local matched_path_item, matched_params, matched_path_template
	for path_template, path_item in pairs(self._doc.paths) do
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
	if not matched_path_item and self._doc.paths[req_path] then
		matched_path_item = self._doc.paths[req_path]
		matched_path_template = req_path
		matched_params = {}
	end

	if not matched_path_item then
		errors[#errors + 1] = { path = "", message = "path not found: " .. req_path }
		return nil, errors
	end

	-- Check method
	local op = matched_path_item[method]
	if not op then
		errors[#errors + 1] = { path = "", message = "method not allowed: " .. method:upper() }
		return nil, errors
	end

	-- Validate parameters
	if op.parameters then
		for _, param in ipairs(op.parameters) do
			local loc = param["in"]
			local name = param.name
			local required = param.required
			local val
			if loc == "query" then
				val = req.query and req.query[name]
			elseif loc == "header" then
				val = req.headers and (req.headers[name] or req.headers[lower(name)])
			elseif loc == "path" then
				val = matched_params and matched_params[name]
			end
			if required and (val == nil or val == "") then
				errors[#errors + 1] = { path = "/" .. loc .. "/" .. name, message = "required " .. loc .. " parameter missing: " .. name }
			end
			-- Basic type coercion check for query/path params (they arrive as strings)
			if val and param.schema and param.schema.type then
				local st = param.schema.type
				if st == "integer" or st == "number" then
					local n = tonumber(val)
					if not n then
						errors[#errors + 1] = { path = "/" .. loc .. "/" .. name, message = loc .. " parameter '" .. name .. "' must be " .. st }
					elseif st == "integer" and n ~= floor(n) then
						errors[#errors + 1] = { path = "/" .. loc .. "/" .. name, message = loc .. " parameter '" .. name .. "' must be integer" }
					end
				end
			end
		end
	end

	-- Validate request body
	if op.requestBody then
		local rb = op.requestBody
		local ct = req.headers and (req.headers["content-type"] or req.headers["Content-Type"]) or ""
		if rb.required and (not req.body or req.body == "") then
			errors[#errors + 1] = { path = "/body", message = "request body is required" }
		elseif req.body and req.body ~= "" and rb.content then
			-- Find matching content type
			local media_type
			for mt in pairs(rb.content) do
				if find(ct, mt, 1, true) or find(mt, ct, 1, true) or mt == "*/*" then
					media_type = rb.content[mt]
					break
				end
			end
			if not media_type then
				-- Try application/json as default
				media_type = rb.content["application/json"]
			end
			if media_type and media_type.schema then
				local body_val, parse_err = json.decode(req.body)
				if not body_val and parse_err then
					errors[#errors + 1] = { path = "/body", message = "invalid JSON body: " .. tostring(parse_err) }
				elseif body_val then
					local ok, schema_errs = M.validate_schema(body_val, media_type.schema, "/body")
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

--: (table, string, integer, table) -> (true, nil) | (nil, table)
function Spec:validate_response(operation_id, status_code, resp)
	local errors = {}
	local op = self:operation(operation_id)
	if not op then
		errors[#errors + 1] = { path = "", message = "operation not found: " .. operation_id }
		return nil, errors
	end

	local status_str = tostring(status_code)
	local resp_spec = op.responses and (op.responses[status_str] or op.responses[status_code])
	if not resp_spec then
		-- Try default
		resp_spec = op.responses and op.responses["default"]
	end
	if not resp_spec then
		errors[#errors + 1] = { path = "", message = "no response spec for status " .. status_str }
		return nil, errors
	end

	-- Validate response body
	if resp_spec.content and resp.body then
		local ct = resp.headers and (resp.headers["content-type"] or resp.headers["Content-Type"]) or "application/json"
		local media_type
		for mt in pairs(resp_spec.content) do
			if find(ct, mt, 1, true) or find(mt, ct, 1, true) then
				media_type = resp_spec.content[mt]
				break
			end
		end
		if media_type and media_type.schema then
			local body_val, parse_err = json.decode(resp.body)
			if not body_val and parse_err then
				errors[#errors + 1] = { path = "/body", message = "invalid JSON body: " .. tostring(parse_err) }
			elseif body_val then
				local ok, schema_errs = M.validate_schema(body_val, media_type.schema, "/body")
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
--: (table, table) -> table
function Spec:router(handlers)
	local web = require("lib.web")
	local app = web.app()
	self:mount(app, handlers)
	return app
end

-- Mount all OpenAPI operations onto an existing web app.
--: (table, table, table) -> ()
function Spec:mount(app, handlers)
	if not self._doc.paths then return end
	local spec = self
	for path_template, path_item in pairs(self._doc.paths) do
		local web_path = openapi_path_to_web_path(path_template)
		for method, op in pairs(path_item) do
			if HTTP_METHODS[method] and type_of(op) == "table" and op.operationId then
				local handler = handlers[op.operationId]
				if handler then
					local register = app[method]
					if register then
						register(app, web_path, function(req, res)
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

--: (table) -> (table, nil) | (nil, string)
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
	return setmetatable({ _doc = doc }, Spec), nil
end

--: (string) -> (table, nil) | (nil, string)
function M.parse(json_string)
	if type_of(json_string) ~= "string" then
		return nil, "expected string, got " .. type_of(json_string)
	end
	local doc, err = json.decode(json_string)
	if not doc then
		return nil, "JSON parse error: " .. tostring(err)
	end
	return M.parse_table(doc)
end

return M
