-- HTTP/1.1 wire format codec
-- RFC 9112 — HTTP/1.1 Message Syntax
-- RFC 9110 — HTTP Semantics

local urlencode_to_string = require("lib.encode.urlencode").urlencode_to_string
local status_names = require("lib.http.status").status_names

local mod = {}

local byte = string.byte
local sub = string.sub
local find = string.find
local lower = string.lower
local concat = table.concat

-- RFC 9110 §9.1 — Methods
--: { [string]: string }
mod.method = {
	GET = "GET", HEAD = "HEAD", POST = "POST", PUT = "PUT",
	DELETE = "DELETE", CONNECT = "CONNECT", OPTIONS = "OPTIONS",
	TRACE = "TRACE", PATCH = "PATCH",
}

-- RFC 9112 §5 / RFC 9110 §5.5 — Parse field lines from header block.
-- Handles obs-fold (§5.6 obsolete line folding) and OWS trimming.
--: (string) -> { [string]: string[] }
local function parse_headers(block)
	local headers = {}
	local pos = 1
	local len = #block
	while pos <= len do
		-- find end of this line
		local crlf = find(block, "\r\n", pos, true)
		if not crlf then break end
		local line = sub(block, pos, crlf - 1)
		pos = crlf + 2
		-- RFC 9112 §5.6 — obs-fold: line starting with SP or HTAB continues previous
		while pos <= len do
			local c = byte(block, pos)
			if c == 0x20 or c == 0x09 then -- SP or HTAB
				local next_crlf = find(block, "\r\n", pos, true)
				if not next_crlf then next_crlf = len + 1 end
				-- replace obs-fold with single SP
				line = line .. " " .. sub(block, pos + 1, next_crlf - 1)
				pos = next_crlf + 2
			else
				break
			end
		end
		-- RFC 9110 §5.1 — field-name: case-insensitive
		local colon = find(line, ":", 1, true)
		if colon then
			local name = lower(sub(line, 1, colon - 1))
			-- RFC 9110 §5.5 — trim OWS (optional whitespace) from field value
			local val_start = colon + 1
			local val_end = #line
			while val_start <= val_end and (byte(line, val_start) == 0x20 or byte(line, val_start) == 0x09) do
				val_start = val_start + 1
			end
			while val_end >= val_start and (byte(line, val_end) == 0x20 or byte(line, val_end) == 0x09) do
				val_end = val_end - 1
			end
			local value = sub(line, val_start, val_end)
			local arr = headers[name]
			if not arr then arr = {}; headers[name] = arr end
			arr[#arr + 1] = value
		end
	end
	return headers
end

-- RFC 9112 §2.1 — find CRLFCRLF separator, return (head_end_pos, body_start_pos)
--: (string, integer) -> integer?, integer?
local function find_head_end(s, i)
	local pos = find(s, "\r\n\r\n", i, true)
	if not pos then return nil, nil end
	return pos, pos + 4
end

-- RFC 9112 §3 — Parse request from wire bytes.
-- Returns: request table, next position, or nil + nil + error string.
--:: http_request = { method: string, target: string, version: string, headers: { [string]: string[] }, body: string? }
--: (string, integer?) -> http_request?, integer?, string?
mod.parse_request = function(s, i)
	i = i or 1
	-- RFC 9112 §2.1 — message = start-line CRLF *( field-line CRLF ) CRLF [ message-body ]
	local head_end, body_start = find_head_end(s, i)
	if not head_end then return nil, nil, "incomplete message" end
	-- RFC 9112 §3 — request-line = method SP request-target SP HTTP-version
	local line_end = find(s, "\r\n", i, true)
	if not line_end then return nil, nil, "incomplete request line" end
	local request_line = sub(s, i, line_end - 1)
	local sp1 = find(request_line, " ", 1, true)
	if not sp1 then return nil, nil, "malformed request line" end
	local sp2 = find(request_line, " ", sp1 + 1, true)
	if not sp2 then return nil, nil, "malformed request line" end
	local method = sub(request_line, 1, sp1 - 1)
	local target = sub(request_line, sp1 + 1, sp2 - 1)
	local version = sub(request_line, sp2 + 1)
	-- RFC 9112 §5 — field lines
	local header_block = sub(s, line_end + 2, head_end - 1)
	local headers = parse_headers(header_block .. "\r\n")
	-- RFC 9112 §6.3 / RFC 9110 §8.6 — body length from Content-Length
	local body = sub(s, body_start)
	local cl = headers["content-length"]
	if cl then
		local len = tonumber(cl[1])
		if len then body = sub(s, body_start, body_start + len - 1) end
	end
	return {
		method = method, target = target, version = version,
		headers = headers, body = #body > 0 and body or nil,
	}, body_start + #body
end

-- RFC 9112 §4 — Parse response from wire bytes.
-- Returns: response table, next position, or nil + nil + error string.
--:: http_response = { status: integer, reason: string, version: string, headers: { [string]: string[] }, body: string? }
--: (string, integer?) -> http_response?, integer?, string?
mod.parse_response = function(s, i)
	i = i or 1
	local head_end, body_start = find_head_end(s, i)
	if not head_end then return nil, nil, "incomplete message" end
	-- RFC 9112 §4 — status-line = HTTP-version SP status-code SP [ reason-phrase ]
	local line_end = find(s, "\r\n", i, true)
	if not line_end then return nil, nil, "incomplete status line" end
	local status_line = sub(s, i, line_end - 1)
	local sp1 = find(status_line, " ", 1, true)
	if not sp1 then return nil, nil, "malformed status line" end
	local version = sub(status_line, 1, sp1 - 1)
	local sp2 = find(status_line, " ", sp1 + 1, true)
	local status_str, reason
	if sp2 then
		status_str = sub(status_line, sp1 + 1, sp2 - 1)
		reason = sub(status_line, sp2 + 1)
	else
		status_str = sub(status_line, sp1 + 1)
		reason = ""
	end
	local status = tonumber(status_str)
	if not status then return nil, nil, "invalid status code" end
	-- headers
	local header_block = sub(s, line_end + 2, head_end - 1)
	local headers = parse_headers(header_block .. "\r\n")
	-- body
	local body = sub(s, body_start)
	local cl = headers["content-length"]
	if cl then
		local len = tonumber(cl[1])
		if len then body = sub(s, body_start, body_start + len - 1) end
	end
	return {
		status = status, reason = reason, version = version,
		headers = headers, body = #body > 0 and body or nil,
	}, body_start + #body
end

-- RFC 9112 §3 — Serialize request to wire bytes.
--: (http_request) -> string
mod.serialize_request = function(req)
	local parts = {}
	-- request-line
	parts[1] = (req.method or "GET") .. " " .. (req.target or "/") .. " " .. (req.version or "HTTP/1.1") .. "\r\n"
	-- field lines
	for name, values in pairs(req.headers or {}) do
		if type(values) == "table" then
			for j = 1, #values do
				parts[#parts + 1] = name .. ": " .. values[j] .. "\r\n"
			end
		else
			parts[#parts + 1] = name .. ": " .. values .. "\r\n"
		end
	end
	parts[#parts + 1] = "\r\n"
	if req.body then parts[#parts + 1] = req.body end
	return concat(parts)
end

-- RFC 9112 §4 — Serialize response to wire bytes.
--: (http_response) -> string
mod.serialize_response = function(res)
	local parts = {}
	local status = res.status or 200
	local reason = res.reason or status_names[status] or "Unknown"
	local version = res.version or "HTTP/1.1"
	-- status-line
	parts[1] = version .. " " .. status .. " " .. reason .. "\r\n"
	-- RFC 9110 §8.6 — Content-Length
	local body = res.body or ""
	local has_cl = false
	for name, values in pairs(res.headers or {}) do
		if type(values) == "table" then
			for j = 1, #values do
				parts[#parts + 1] = name .. ": " .. values[j] .. "\r\n"
			end
		else
			parts[#parts + 1] = name .. ": " .. values .. "\r\n"
		end
		if lower(name) == "content-length" then has_cl = true end
	end
	if not has_cl then
		parts[#parts + 1] = "content-length: " .. #body .. "\r\n"
	end
	parts[#parts + 1] = "\r\n"
	parts[#parts + 1] = body
	return concat(parts)
end

-- Backward-compatible: parse request and add legacy .path, .params, .version fields.
--: (string, integer?) -> http_request?, integer?, string?
mod.string_to_http_request = function(s, i)
	local req, pos, err = mod.parse_request(s, i)
	if not req then return nil, err end
	-- Old API: .path = path without query string, .params = decoded query params, .version = number
	local target = req.target or "/"
	local path = target
	local params = {}
	local qmark = find(target, "?", 1, true)
	if qmark then
		path = sub(target, 1, qmark - 1)
		local params_str = sub(target, qmark + 1)
		for k, v in params_str:gmatch("([^=&]*)=?([^&]*)&?") do
			params[urlencode_to_string(k)] = urlencode_to_string(v)
		end
	end
	req.path = path
	req.params = params
	-- Old API: version was a number (e.g. 1.1)
	local ver_num = tonumber(req.version:match("HTTP/([0-9.]+)"))
	if ver_num then req.version = ver_num end
	return req, pos
end

-- Backward-compatible: parse client response, adds .status_text alias for .reason.
--: (string, integer?) -> http_response?, integer?
mod.string_to_http_client_response = function(s, i)
	local res, pos, err = mod.parse_response(s, i)
	if not res then return nil end
	-- Old API: .status_text instead of .reason, .version was a number
	res.status_text = res.reason
	local ver_num = tonumber(res.version:match("HTTP/([0-9.]+)"))
	if ver_num then res.version = ver_num end
	return res, pos
end

-- Backward-compatible: serialize response. Old API used title-case headers and status_text.
--: (http_response) -> string
mod.http_response_to_string = function(res)
	res.body = res.body or ""
	local parts = {}
	-- Old API: status_text, or fall back to status_names
	local status = res.status or 200
	local reason = res.status_text or res.reason or status_names[status] or status_names[200]
	parts[#parts + 1] = "HTTP/1.1 " .. status .. " " .. reason .. "\r\n"
	local res_headers = {}
	for k, v in pairs(res.headers or {}) do
		-- Old API normalised to Title-Case; preserve that behaviour
		local title = k:gsub("^%l", string.upper):gsub("-%l", string.upper)
		res_headers[title] = v
	end
	-- Content-Type first (old behaviour)
	if res_headers["Content-Type"] ~= nil then
		local ct = res_headers["Content-Type"]
		parts[#parts + 1] = "Content-Type: " .. (type(ct) == "table" and ct[1] or ct) .. "\r\n"
		res_headers["Content-Type"] = nil
	end
	-- Content-Length (use provided or compute from body)
	local cl = res_headers["Content-Length"]
	parts[#parts + 1] = "Content-Length: " .. (cl and (type(cl) == "table" and cl[1] or cl) or #res.body) .. "\r\n"
	res_headers["Content-Length"] = nil
	-- remaining headers
	for k, v in pairs(res_headers) do
		if type(v) == "table" then
			for j = 1, #v do
				parts[#parts + 1] = k .. ": " .. v[j] .. "\r\n"
			end
		else
			parts[#parts + 1] = k .. ": " .. v .. "\r\n"
		end
	end
	parts[#parts + 1] = "\r\n"
	parts[#parts + 1] = res.body
	return concat(parts)
end

-- Backward-compatible: serialize client request. Old API used .path, .host at top level.
--: ({ method: string?, path: string?, host: string, headers: { [string]: string[] }?, body: string? }) -> string
mod.http_client_request_to_string = function(req)
	local parts = {}
	parts[#parts + 1] = (req.method or "GET") .. " " .. (req.path or "/") .. " HTTP/1.1\r\nHost: " .. req.host .. "\r\n"
	for k, v_ in pairs(req.headers or {}) do
		if type(v_) == "table" then
			for _, v in ipairs(v_) do parts[#parts + 1] = k .. ": " .. v .. "\r\n" end
		else
			parts[#parts + 1] = k .. ": " .. v_ .. "\r\n"
		end
	end
	parts[#parts + 1] = "\r\n"
	parts[#parts + 1] = req.body or ""
	return concat(parts)
end

return mod
