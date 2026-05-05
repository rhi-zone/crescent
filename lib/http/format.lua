-- HTTP/1.1 wire format codec
-- RFC 9112 — HTTP/1.1 Message Syntax
-- RFC 9110 — HTTP Semantics

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
	--: { [string]: { [integer]: string } }
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
				local nc = next_crlf --[[:! integer]]
				-- replace obs-fold with single SP
				line = line .. " " .. sub(block, pos + 1, nc - 1)
				pos = nc + 2
			else
				break
			end
		end
		-- RFC 9110 §5.1 — field-name: case-insensitive
		local colon = find(line, ":", 1, true)
		if colon then
			local ci = colon --[[:! integer]]
				local name = lower(sub(line, 1, ci - 1))
			-- RFC 9110 §5.5 — trim OWS (optional whitespace) from field value
			local val_start = ci + 1
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

-- RFC 9112 §2.1 — find CRLFCRLF separator, return position of \r\n\r\n or nil.
-- Caller derives body_start as head_end + 4.
--: (string, integer) -> integer | nil
local function find_head_end(s, i)
	local pos = find(s, "\r\n\r\n", i, true)
	return pos
end

-- RFC 9112 §3 — Parse request from wire bytes.
-- Returns: request table, next position, or nil + nil + error string.
--:: http_request = { method: string, target: string, version: string, headers: { [string]: string[] }, body: string | nil }
--: (string, integer | nil) -> (http_request | nil, integer | nil, string | nil)
mod.parse_request = function(s, i)
	i = i or 1
	-- RFC 9112 §2.1 — message = start-line CRLF *( field-line CRLF ) CRLF [ message-body ]
	local head_end = find_head_end(s, i)
	if not head_end then return nil, nil, "incomplete message" end
	local body_start = head_end + 4
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
		if len then body = sub(s, body_start, body_start + (len --[[:! integer]]) - 1) end
	end
	return {
		method = method, target = target, version = version,
		headers = headers, body = #body > 0 and body or nil,
	}, body_start + #body
end

-- RFC 9112 §4 — Parse response from wire bytes.
-- Returns: response table, next position, or nil + nil + error string.
--:: http_response = { status: integer, reason: string, version: string, headers: { [string]: string[] }, body: string | nil }
--: (string, integer | nil) -> (http_response | nil, integer | nil, string | nil)
mod.parse_response = function(s, i)
	i = i or 1
	local head_end = find_head_end(s, i)
	if not head_end then return nil, nil, "incomplete message" end
	local body_start = head_end + 4
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
	-- RFC 9112 §4 — status-code is exactly 3 decimal digits
	if #status_str ~= 3 then return nil, nil, "invalid status code" end
	local b1 = byte(status_str, 1) or 0
	local b2 = byte(status_str, 2) or 0
	local b3 = byte(status_str, 3) or 0
	if b1 < 48 or b1 > 57 or b2 < 48 or b2 > 57 or b3 < 48 or b3 > 57 then
		return nil, nil, "invalid status code"
	end
	local status = (b1 - 48) * 100 + (b2 - 48) * 10 + (b3 - 48)
	-- headers
	local header_block = sub(s, line_end + 2, head_end - 1)
	local headers = parse_headers(header_block .. "\r\n")
	-- body
	local body = sub(s, body_start)
	local cl = headers["content-length"]
	if cl then
		local len = tonumber(cl[1])
		if len then body = sub(s, body_start, body_start + (len --[[:! integer]]) - 1) end
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
		for j = 1, #values do
			parts[#parts + 1] = name .. ": " .. values[j] .. "\r\n"
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
		for j = 1, #values do
			parts[#parts + 1] = name .. ": " .. values[j] .. "\r\n"
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

return mod
