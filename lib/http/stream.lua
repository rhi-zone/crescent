--- HTTP streaming response reader.
-- RFC 9112 §6 — Message body transfer
-- Transport-agnostic: wraps a recv_fn() closure that returns bytes.
-- Works with raw sockets, TLS sockets, or test mocks.

local math2 = require("lib.math")

local mod = {}

--:: http_stream = { _recv: () -> string | nil, _buf: string, _pos: integer, _headers: { [string]: string[] } | nil, _status: integer | nil, _status_text: string | nil, _version: string | nil, _eof: boolean, read_headers: (self: http_stream) -> ({ [string]: string[] } | nil, string | nil), status: (self: http_stream) -> integer | nil, read_body: (self: http_stream) -> (string | nil, string | nil), chunks: (self: http_stream) -> () -> string | nil, events: (self: http_stream) -> () -> { event: string | nil, data: string, id: string | nil } | nil }

local mt = { __index = {} }

mod.new = function(recv_fn)
	return setmetatable({
		_recv = recv_fn,
		_buf = "",
		_pos = 1,
		_eof = false,
	}, mt)
end

--- Number of unread bytes currently in the buffer.
--: (http_stream) -> integer
local function buf_len(self)
	local self_ = self --[[:! http_stream]]
	return #self_._buf - self_._pos + 1
end

--- Compact the buffer when the consumed prefix is larger than the remaining data.
-- Avoids unbounded memory growth from accumulated prefixes.
--: (http_stream) -> nil
local function maybe_compact(self)
	local self_ = self --[[:! http_stream]]
	if self_._pos > 1 and self_._pos > (#self_._buf / 2) then
		self_._buf = self_._buf:sub(self_._pos)
		self_._pos = 1
	end
end

--- Fill buffer until it contains pattern or EOF.
-- NOTE: annotations work around typechecker limitation — narrowing doesn't
-- apply to locals assigned from function call returns (TAG_VAR not yet resolved
-- at narrowing time). See TODO.md.
--: (http_stream, string) -> integer | nil
local function fill_until(self, pattern)
	while true do
		local pos = self._buf:find(pattern, self._pos, true)
		if pos then return pos end
		if self._eof then return nil end
		--: string | nil
		local recv_result = self._recv()
		if not recv_result then
			self._eof = true
			return nil
		end
		-- Compact before appending to keep _buf small.
		maybe_compact(self)
		self._buf = self._buf .. recv_result
	end
end

--- Read and parse HTTP response status line + headers.
-- RFC 9112 §5 — Field lines
function mt.__index:read_headers()
	local self_ = self --[[:! http_stream]]
	if self_._headers then return self_._headers end
	--: integer | nil
	local pos = fill_until(self_, "\r\n\r\n")
	if not pos then return nil, "incomplete headers" end

	local head = self_._buf:sub(self_._pos, pos - 1)
	self_._pos = pos + 4
	maybe_compact(self_)

	-- parse status line
	local version_raw, status_raw, status_text = head:match("^([^ ]+) ([^ ]+) ([^\r]*)")
	if not version_raw then return nil, "invalid status line" end

	self_._version = version_raw
	self_._status = math2.tointeger(status_raw) or 0
	self_._status_text = status_text

	-- parse headers
	local headers = {} --: { [string]: string[] }
	local first_crlf = head:find("\r\n", 1, true)
	local header_block = first_crlf and head:sub(first_crlf + 2) or ""
	for line in (header_block .. "\r\n"):gmatch("(.-)\r\n") do
		if #line > 0 then
			local k, v = line:match("^(.-):%s*(.*)")
			if k then
				k = k:lower()
				local arr = headers[k]
				if not arr then arr = {}; headers[k] = arr end
				table.insert(arr, v)
			end
		end
	end

	self_._headers = headers
	return headers
end

--- Return parsed status code.
function mt.__index:status()
	local self_ = self --[[:! http_stream]]
	return self_._status
end

--- Read full body using Content-Length.
-- RFC 9112 §6.3 / RFC 9110 §8.6 — Body length from Content-Length
function mt.__index:read_body()
	local self_ = self --[[:! http_stream]]
	local headers, err = self_:read_headers()
	if not headers then return nil, err end

	local cl = headers["content-length"]
	if cl then
		local len = math2.tointeger(cl[1]) or 0
		if not len or len == 0 then return nil, "invalid content-length" end
		-- fill buffer until we have enough
		while buf_len(self_) < len and not self_._eof do
			--: string | nil
			local chunk = self_._recv()
			if not chunk then self_._eof = true; break end
			maybe_compact(self_)
			self_._buf = self_._buf .. chunk
		end
		local body = self_._buf:sub(self_._pos, self_._pos + len - 1)
		self_._pos = self_._pos + len
		maybe_compact(self_)
		return body
	end

	-- no content-length: read until EOF
	while not self_._eof do
		--: string | nil
		local chunk = self_._recv()
		if not chunk then self_._eof = true; break end
		maybe_compact(self_)
		self_._buf = self_._buf .. chunk
	end
	local body = self_._buf:sub(self_._pos)
	self_._buf = ""
	self_._pos = 1
	return body
end

--- Iterator for chunked transfer encoding.
-- RFC 9112 §6.1 — Chunked transfer coding
-- Yields decoded chunk data (not hex lengths or trailers).
function mt.__index:chunks()
	local self_ = self --[[:! http_stream]]
	local headers, err = self_:read_headers()
	if not headers then return function() return nil end end
	local done = false

	return function()
		if done then return nil end
		-- read chunk size line
		--: integer | nil
		local pos = fill_until(self_, "\r\n")
		if not pos then done = true; return nil end

		local size_line = self_._buf:sub(self_._pos, pos - 1)
		self_._pos = pos + 2
		maybe_compact(self_)

		-- strip chunk extensions
		local hex = size_line:match("^([0-9a-fA-F]+)")
		if not hex then done = true; return nil end

		local size = (math2.tointeger(tonumber(hex, 16)) or 0)
		if not size or size == 0 then done = true; return nil end

		-- read chunk data + trailing \r\n
		local need = size + 2
		while buf_len(self_) < need and not self_._eof do
			--: string | nil
			local chunk = self_._recv()
			if not chunk then self_._eof = true; break end
			maybe_compact(self_)
			self_._buf = self_._buf .. chunk
		end

		local data = self_._buf:sub(self_._pos, self_._pos + size - 1)
		self_._pos = self_._pos + size + 2 -- skip data + \r\n
		maybe_compact(self_)
		return data
	end
end

--- Iterator for Server-Sent Events.
-- Yields tables: { event: string?, data: string, id: string? }
function mt.__index:events()
	local self_ = self --[[:! http_stream]]
	local headers, err = self_:read_headers()
	if not headers then return function() return nil end end

	-- SSE state
	local event_type = nil
	local data_parts = {}
	local event_id = nil

	return function()
		while true do
			-- try to find next line
			--: integer | nil
			local pos = fill_until(self_, "\n")
			if not pos then
				-- EOF: flush pending event
				if #data_parts > 0 then
					local ev = { event = event_type, data = table.concat(data_parts, "\n"), id = event_id }
					data_parts = {}
					event_type = nil
					event_id = nil
					return ev
				end
				return nil
			end

			-- extract line (handle \r\n and \n)
			local line_raw = self_._buf:sub(self_._pos, pos - 1)
			local line = (line_raw:sub(-1) == "\r") and line_raw:sub(1, -2) or line_raw --: string
			self_._pos = pos + 1
			maybe_compact(self_)

			if line == "" then
				-- dispatch event
				if #data_parts > 0 then
					local ev = { event = event_type, data = table.concat(data_parts, "\n"), id = event_id }
					data_parts = {}
					event_type = nil
					event_id = nil
					return ev
				end
			elseif line:sub(1, 1) == ":" then
				-- comment, skip
			else
				local field, value = line:match("^([^:]+):%s?(.*)")
				if not field then
					field = line
					value = ""
				end
				if field == "data" then
					data_parts[#data_parts + 1] = value
				elseif field == "event" then
					event_type = value
				elseif field == "id" then
					event_id = value
				end
				-- ignore retry and unknown fields
			end
		end
	end
end

return mod
