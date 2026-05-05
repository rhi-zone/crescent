-- lib/email/init.lua
-- Email composition (RFC 5322 / MIME) and SMTP client (RFC 5321).
--
-- Usage:
--   local email = require("lib.email")
--   local msg = email.message({ from = "a@b.com", to = {"c@d.com"}, subject = "Hi", text = "Hello" })
--   local raw = msg:to_string()
--
--   local smtp = email.smtp_connect({ host = "smtp.example.com", port = 587, transport = t })
--   smtp:ehlo("mydomain.com")
--   smtp:auth("LOGIN", "user", "pass")
--   smtp:send(msg)
--   smtp:quit()

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local base64 = require("lib.encode.base64")

local M = {}

-- ── Utilities ────────────────────────────────────────────────────────────

local function random_hex(n)
	local t = {}
	for i = 1, n do
		t[i] = string.format("%02x", math.random(0, 255))
	end
	return table.concat(t)
end

--: () -> string
local function generate_boundary()
	return "----=_Part_" .. random_hex(16)
end

--: (string, () -> number) -> string
local function generate_message_id(from, time_fn)
	local domain = from:match("@(.+)") or "localhost"
	return "<" .. time_fn() .. "." .. random_hex(8) .. "@" .. domain .. ">"
end

-- RFC 2822 date format: "Thu, 01 Jan 2009 00:00:00 +0000"
-- Pure-Lua UTC decomposition (no os.date dependency).
local DAY_NAMES = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTH_NAMES = {
	"Jan", "Feb", "Mar", "Apr", "May", "Jun",
	"Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
}

-- Howard Hinnant civil_from_days: days since epoch -> (year, month, day)
--: (number) -> (number, number, number)
local function civil_from_days(z)
	z = z + 719468
	local era = math.floor(z / 146097)
	local doe = z - era * 146097
	local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
	local mp = math.floor((5 * doy + 2) / 153)
	local d = doy - math.floor((153 * mp + 2) / 5) + 1
	local m = mp + (mp < 10 and 3 or -9)
	if m <= 2 then y = y + 1 end
	return y, m, d
end

--: (() -> number) -> string
local function rfc2822_date(time_fn)
	local ts = math.floor(time_fn())
	local days = math.floor(ts / 86400)
	local rem = ts - days * 86400
	local hour = math.floor(rem / 3600)
	rem = rem - hour * 3600
	local min = math.floor(rem / 60)
	local sec = rem - min * 60
	local y, mo, d = civil_from_days(days)
	-- Day of week: epoch (1970-01-01) is Thursday (4). (days+4)%7: 0=Sun..6=Sat
	local wday = (days + 4) % 7 + 1 -- 1-indexed for DAY_NAMES
	return string.format("%s, %02d %s %04d %02d:%02d:%02d +0000",
		DAY_NAMES[wday], d, MONTH_NAMES[mo], y, hour, min, sec)
end

-- ── Quoted-Printable ─────────────────────────────────────────────────────

--: (string | nil) -> string
local function qp_encode(str)
	if not str then return "" end
	-- Replace non-printable and = with =XX, wrap at 76 chars
	local lines = {}
	local line = {}
	local col = 0

	local i = 1
	local n = #str
	while i <= n do
		local b = str:byte(i) or 0
		-- Pass through CRLF as-is
		if b == 13 and i < n and str:byte(i + 1) == 10 then
			lines[#lines + 1] = table.concat(line)
			line = {}
			col = 0
			i = i + 2
		elseif b == 10 then
			lines[#lines + 1] = table.concat(line)
			line = {}
			col = 0
			i = i + 1
		elseif b == 9 or (b >= 33 and b <= 126 and b ~= 61) then
			-- Printable (except =) and tab pass through
			if col + 1 > 75 then
				line[#line + 1] = "=\r\n"
				lines[#lines + 1] = table.concat(line)
				line = {}
				col = 0
			end
			line[#line + 1] = string.char(b)
			col = col + 1
			i = i + 1
		else
			local encoded = string.format("=%02X", b)
			if col + 3 > 75 then
				line[#line + 1] = "=\r\n"
				lines[#lines + 1] = table.concat(line)
				line = {}
				col = 0
			end
			line[#line + 1] = encoded
			col = col + 3
			i = i + 1
		end
	end
	lines[#lines + 1] = table.concat(line)
	return table.concat(lines, "\r\n")
end

-- Decode quoted-printable
--: (string) -> string
local function qp_decode(str)
	-- Unfold soft line breaks
	local s, _ = str:gsub("=\r\n", "")
	s = s:gsub("=\n", "")
	-- Decode =XX sequences
	local result, _ = s:gsub("=(%x%x)", function(hex)
		local cp = tonumber(hex, 16)
		if not cp then return "" end
		return string.char(cp)
	end)
	return result
end

-- ── RFC 2047 Encoded-Word ────────────────────────────────────────────────

-- Check if string has non-ASCII characters
--: (string) -> boolean
local function has_non_ascii(str)
	for i = 1, #str do
		local b = str:sub(i, i):byte() or 0
		if b > 127 then return true end
	end
	return false
end

-- Encode a header value as RFC 2047 encoded-word if needed
--: (string) -> string
local function encode_header_value(str)
	if not has_non_ascii(str) then return str end
	return "=?UTF-8?B?" .. (base64.encode(str) --[[:! string]]) .. "?="
end

-- Decode RFC 2047 encoded-word
--: (string) -> string
local function decode_header_value(str)
	local result = str:gsub("=?([^?]+)?([BbQq])?([^?]*)?=", function(charset, encoding, data)
		if not encoding or not data then return str end
		encoding = encoding:upper()
		if encoding == "B" then
			return (base64.decode(data) --[[:! string | nil]]) or data
		elseif encoding == "Q" then
			-- Q encoding: _ = space, =XX = hex
			local decoded = data:gsub("_", " ")
			decoded = decoded:gsub("=(%x%x)", function(hex)
				local cp = tonumber(hex, 16)
				if not cp then return "" end
				return string.char(cp)
			end)
			return decoded
		end
		return data
	end)
	return result
end

-- ── Base64 line wrapping ─────────────────────────────────────────────────

--: (string) -> string
local function base64_encode_wrapped(data)
	local encoded = base64.encode(data) --[[:! string]]
	local lines = {}
	for i = 1, #encoded, 76 do
		lines[#lines + 1] = encoded:sub(i, i + 75)
	end
	return table.concat(lines, "\r\n")
end

-- ── Message Object ───────────────────────────────────────────────────────

--:: Attachment = { filename: string, content_type: string, data: string, inline: boolean | nil, cid: string | nil }
--:: MessageObj = { from: string, to: { [integer]: string }, cc: { [integer]: string }, bcc: { [integer]: string }, subject: string, text: string | nil, html: string | nil, headers: { [string]: string }, reply_to: string | nil, attachments: { [integer]: Attachment }, _time_fn: () -> number }

local Message = {}
Message.__index = Message

--: ({ from: string, to: { [integer]: string } | nil, cc: { [integer]: string } | nil, bcc: { [integer]: string } | nil, subject: string | nil, text: string | nil, html: string | nil, headers: { [string]: string } | nil, reply_to: string | nil, time_fn: () -> number }) -> MessageObj
function M.message(opts)
	assert(opts and opts.time_fn, "message requires opts.time_fn")
	local msg = setmetatable({
		from = opts.from,
		to = opts.to or {},
		cc = opts.cc or {},
		bcc = opts.bcc or {},
		subject = opts.subject or "",
		text = opts.text,
		html = opts.html,
		headers = opts.headers or {},
		reply_to = opts.reply_to,
		attachments = {},
		_time_fn = opts.time_fn,
	}, Message)
	return msg
end

-- Add an attachment
--: (MessageObj, Attachment) -> nil
function Message:attach(att)
	self.attachments[#self.attachments + 1] = {
		filename = att.filename,
		content_type = att.content_type,
		data = att.data,
		inline = att.inline or false,
		cid = att.cid,
	}
end

-- Format an address list for headers
--: ({ [integer]: string }) -> string
local function format_addr_list(addrs)
	return table.concat(addrs, ", ")
end

-- Build the MIME body
--: (MessageObj) -> string
local function build_body(msg)
	local has_text = msg.text ~= nil
	local has_html = msg.html ~= nil
	local has_attachments = #msg.attachments > 0
	local has_inline = false
	local has_regular = false
	for _, att in ipairs(msg.attachments) do
		if att.inline then
			has_inline = true
		else
			has_regular = true
		end
	end

	-- No body at all
	if not has_text and not has_html and not has_attachments then
		return "Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 7bit\r\n\r\n"
	end

	-- Single text part, no attachments
	if has_text and not has_html and not has_attachments then
		return "Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
			.. qp_encode(msg.text)
	end

	-- Single html part, no attachments
	if has_html and not has_text and not has_attachments then
		return "Content-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
			.. qp_encode(msg.html)
	end

	local parts = {}

	-- Build the text/html content part
	local content_part
	if has_text and has_html then
		local alt_boundary = generate_boundary()
		local alt_parts = {}
		alt_parts[#alt_parts + 1] = "Content-Type: multipart/alternative;\r\n boundary=\"" .. alt_boundary .. "\"\r\n"
		alt_parts[#alt_parts + 1] = "\r\n--" .. alt_boundary .. "\r\n"
		alt_parts[#alt_parts + 1] = "Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
		alt_parts[#alt_parts + 1] = qp_encode(msg.text)
		alt_parts[#alt_parts + 1] = "\r\n--" .. alt_boundary .. "\r\n"
		-- If inline attachments, wrap html in multipart/related
		if has_inline then
			local rel_boundary = generate_boundary()
			alt_parts[#alt_parts + 1] = "Content-Type: multipart/related;\r\n boundary=\"" .. rel_boundary .. "\"\r\n"
			alt_parts[#alt_parts + 1] = "\r\n--" .. rel_boundary .. "\r\n"
			alt_parts[#alt_parts + 1] = "Content-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
			alt_parts[#alt_parts + 1] = qp_encode(msg.html)
			for _, att in ipairs(msg.attachments) do
				if att.inline then
					alt_parts[#alt_parts + 1] = "\r\n--" .. rel_boundary .. "\r\n"
					alt_parts[#alt_parts + 1] = "Content-Type: " .. att.content_type .. "\r\n"
					alt_parts[#alt_parts + 1] = "Content-Transfer-Encoding: base64\r\n"
					alt_parts[#alt_parts + 1] = "Content-Disposition: inline; filename=\"" .. att.filename .. "\"\r\n"
					if att.cid then
						alt_parts[#alt_parts + 1] = "Content-ID: <" .. att.cid .. ">\r\n"
					end
					alt_parts[#alt_parts + 1] = "\r\n" .. base64_encode_wrapped(att.data)
				end
			end
			alt_parts[#alt_parts + 1] = "\r\n--" .. rel_boundary .. "--\r\n"
		else
			alt_parts[#alt_parts + 1] = "Content-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
			alt_parts[#alt_parts + 1] = qp_encode(msg.html)
		end
		alt_parts[#alt_parts + 1] = "\r\n--" .. alt_boundary .. "--\r\n"
		content_part = table.concat(alt_parts)
	elseif has_text then
		content_part = "Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
			.. qp_encode(msg.text)
	elseif has_html then
		if has_inline then
			local rel_boundary = generate_boundary()
			local rel_parts = {}
			rel_parts[#rel_parts + 1] = "Content-Type: multipart/related;\r\n boundary=\"" .. rel_boundary .. "\"\r\n"
			rel_parts[#rel_parts + 1] = "\r\n--" .. rel_boundary .. "\r\n"
			rel_parts[#rel_parts + 1] = "Content-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
			rel_parts[#rel_parts + 1] = qp_encode(msg.html)
			for _, att in ipairs(msg.attachments) do
				if att.inline then
					rel_parts[#rel_parts + 1] = "\r\n--" .. rel_boundary .. "\r\n"
					rel_parts[#rel_parts + 1] = "Content-Type: " .. att.content_type .. "\r\n"
					rel_parts[#rel_parts + 1] = "Content-Transfer-Encoding: base64\r\n"
					rel_parts[#rel_parts + 1] = "Content-Disposition: inline; filename=\"" .. att.filename .. "\"\r\n"
					if att.cid then
						rel_parts[#rel_parts + 1] = "Content-ID: <" .. att.cid .. ">\r\n"
					end
					rel_parts[#rel_parts + 1] = "\r\n" .. base64_encode_wrapped(att.data)
				end
			end
			rel_parts[#rel_parts + 1] = "\r\n--" .. rel_boundary .. "--\r\n"
			content_part = table.concat(rel_parts)
		else
			content_part = "Content-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
				.. qp_encode(msg.html)
		end
	end

	-- If regular (non-inline) attachments exist, wrap in multipart/mixed
	if has_regular or (has_attachments and not has_inline) then
		local mixed_boundary = generate_boundary()
		parts[#parts + 1] = "Content-Type: multipart/mixed;\r\n boundary=\"" .. mixed_boundary .. "\"\r\n"
		parts[#parts + 1] = "\r\n--" .. mixed_boundary .. "\r\n"
		parts[#parts + 1] = content_part
		for _, att in ipairs(msg.attachments) do
			if not att.inline then
				parts[#parts + 1] = "\r\n--" .. mixed_boundary .. "\r\n"
				parts[#parts + 1] = "Content-Type: " .. att.content_type .. "\r\n"
				parts[#parts + 1] = "Content-Transfer-Encoding: base64\r\n"
				parts[#parts + 1] = "Content-Disposition: attachment; filename=\"" .. att.filename .. "\"\r\n"
				parts[#parts + 1] = "\r\n" .. base64_encode_wrapped(att.data)
			end
		end
		parts[#parts + 1] = "\r\n--" .. mixed_boundary .. "--\r\n"
		return table.concat(parts)
	end

	-- Inline-only attachments with no regular attachments — content_part already has them
	return content_part
end

-- Serialize message to RFC 5322 string
--: (MessageObj) -> (string | nil, string | nil)
function Message:to_string()
	local headers = {}
	-- Required headers
	headers[#headers + 1] = "From: " .. self.from
	if #self.to > 0 then
		headers[#headers + 1] = "To: " .. format_addr_list(self.to)
	end
	if #self.cc > 0 then
		headers[#headers + 1] = "Cc: " .. format_addr_list(self.cc)
	end
	-- BCC intentionally omitted from headers
	headers[#headers + 1] = "Subject: " .. encode_header_value(self.subject)
	headers[#headers + 1] = "Date: " .. rfc2822_date(self._time_fn)
	headers[#headers + 1] = "Message-ID: " .. generate_message_id(self.from, self._time_fn)
	headers[#headers + 1] = "MIME-Version: 1.0"
	if self.reply_to then
		headers[#headers + 1] = "Reply-To: " .. self.reply_to
	end
	-- Custom headers
	for name, value in pairs(self.headers) do
		headers[#headers + 1] = name .. ": " .. value
	end

	local body = build_body(self)
	return table.concat(headers, "\r\n") .. "\r\n" .. body, nil
end

-- ── Email Parsing ────────────────────────────────────────────────────────

-- Parse headers from raw text, returns headers table and body start position
--: (string) -> ({ [string]: string }, integer)
local function parse_headers(raw)
	local headers = {}
	local pos = 1
	local last_name = nil

	while pos <= #raw do
		-- Find end of line
		local nl = raw:find("\r\n", pos, true) or raw:find("\n", pos, true)
		if not nl then break end
		local nl_i = nl --[[:! integer]]

		local crlf = raw:byte(nl_i) == 13
		local line = raw:sub(pos, nl_i - 1)
		local next_pos = crlf and nl_i + 2 or nl_i + 1

		-- Empty line = end of headers
		if line == "" then
			return headers, next_pos
		end

		-- Continuation line (starts with space or tab)
		if line:byte(1) == 32 or line:byte(1) == 9 then
			if last_name then
				headers[last_name] = headers[last_name] .. " " .. line:match("^%s*(.*)")
			end
		else
			local name, value = line:match("^([^:]+):%s*(.*)")
			if name then
				name = name:lower()
				last_name = name
				headers[name] = value
			end
		end
		pos = next_pos
	end
	return headers, pos
end

-- Parse a MIME boundary from Content-Type header
--: (string) -> string | nil
local function parse_boundary(content_type)
	return content_type:match('boundary="([^"]+)"') or content_type:match("boundary=([^;%s]+)")
end

-- Parse MIME parts recursively
--: (string, string) -> { { headers: { [string]: string }, body: string } }
local function parse_mime_parts(body, boundary)
	local parts = {}
	local delim = "--" .. boundary
	local end_delim = delim .. "--"

	-- Find first delimiter
	local pos = body:find(delim, 1, true)
	if not pos then return parts end

	-- Skip past first delimiter line
	local nl = body:find("\r\n", pos, true) or body:find("\n", pos, true)
	if not nl then return parts end
	local nl_i = nl --[[:! integer]]
	pos = body:byte(nl_i) == 13 and nl_i + 2 or nl_i + 1

	while pos <= #body do
		-- Find next delimiter
		local next_delim = body:find(delim, pos, true)
		if not next_delim then break end

		local part_data = body:sub(pos, next_delim - 1)
		-- Remove trailing CRLF before delimiter
		if part_data:sub(-2) == "\r\n" then
			part_data = part_data:sub(1, -3)
		elseif part_data:sub(-1) == "\n" then
			part_data = part_data:sub(1, -2)
		end

		local part_headers, body_start = parse_headers(part_data)
		local part_body = part_data:sub(body_start)
		parts[#parts + 1] = {
			headers = part_headers,
			body = part_body,
		}

		-- Check if this was the end delimiter
		local after_delim = body:sub(next_delim + #delim, next_delim + #delim + 1)
		if after_delim == "--" then break end

		-- Skip past delimiter line
		nl = body:find("\r\n", next_delim, true) or body:find("\n", next_delim, true)
		if not nl then break end
		local nl2 = nl --[[:! integer]]
		pos = body:byte(nl2) == 13 and nl2 + 2 or nl2 + 1
	end

	return parts
end

-- Decode a body part based on content-transfer-encoding
--: (string, string | nil) -> string
local function decode_body(body, encoding)
	if not encoding then return body end
	encoding = encoding:lower()
	if encoding == "quoted-printable" then
		return qp_decode(body)
	elseif encoding == "base64" then
		return base64.decode(body) or body
	end
	return body
end

-- Extract message data from parsed MIME structure
--: (any, { { headers: { [string]: string }, body: string } }) -> nil
local function extract_parts(msg, parts)
	for _, part in ipairs(parts) do
		local ct = part.headers["content-type"] or "text/plain"
		local cte = part.headers["content-transfer-encoding"]
		local cd = part.headers["content-disposition"] or ""

		-- Recurse into nested multipart
		if ct:find("multipart/", 1, true) then
			local boundary = parse_boundary(ct)
			if boundary then
				extract_parts(msg, parse_mime_parts(part.body, boundary))
			end
		elseif cd:find("attachment", 1, true) or cd:find("inline", 1, true) then
			local filename = cd:match('filename="([^"]+)"') or cd:match("filename=([^;%s]+)") or "unnamed"
			local is_inline = cd:find("inline", 1, true) ~= nil
			local cid = part.headers["content-id"]
			if cid then
				cid = cid:match("^<?(.-)>?$")
			end
			msg.attachments[#msg.attachments + 1] = {
				filename = filename,
				content_type = ct:match("^([^;]+)"),
				data = decode_body(part.body, cte),
				inline = is_inline,
				cid = cid,
			}
		elseif ct:find("text/plain", 1, true) then
			msg.text = decode_body(part.body, cte)
		elseif ct:find("text/html", 1, true) then
			msg.html = decode_body(part.body, cte)
		end
	end
end

-- Parse an email from a raw RFC 5322 string
--: (string) -> (any | nil, string | nil)
function M.parse(raw)
	if type(raw) ~= "string" or #raw == 0 then
		return nil, "empty input"
	end

	local headers, body_start = parse_headers(raw)
	local body = raw:sub(body_start)

	local msg = {
		from = headers["from"],
		to = {},
		cc = {},
		bcc = {},
		subject = headers["subject"] and decode_header_value(headers["subject"]) or "",
		text = nil,
		html = nil,
		headers = {},
		reply_to = headers["reply-to"],
		attachments = {},
	}

	-- Parse address lists
	if headers["to"] then
		for addr in headers["to"]:gmatch("[^,]+") do
			msg.to[#msg.to + 1] = addr:match("^%s*(.-)%s*$")
		end
	end
	if headers["cc"] then
		for addr in headers["cc"]:gmatch("[^,]+") do
			msg.cc[#msg.cc + 1] = addr:match("^%s*(.-)%s*$")
		end
	end

	-- Collect non-standard headers
	for name, value in pairs(headers) do
		if name ~= "from" and name ~= "to" and name ~= "cc" and name ~= "subject"
			and name ~= "date" and name ~= "message-id" and name ~= "mime-version"
			and name ~= "content-type" and name ~= "content-transfer-encoding"
			and name ~= "reply-to" then
			msg.headers[name] = value
		end
	end

	local ct = headers["content-type"] or "text/plain"
	local cte = headers["content-transfer-encoding"]

	if ct:find("multipart/", 1, true) then
		local boundary = parse_boundary(ct)
		if boundary then
			local parts = parse_mime_parts(body, boundary)
			extract_parts(msg, parts)
		else
			return nil, "multipart message with no boundary"
		end
	elseif ct:find("text/html", 1, true) then
		msg.html = decode_body(body, cte)
	else
		msg.text = decode_body(body, cte)
	end

	return setmetatable(msg, Message), nil
end

-- ── SMTP Client ──────────────────────────────────────────────────────────

local SMTP = {}
SMTP.__index = SMTP

-- Read an SMTP response line (or multiline).
-- Returns status code and full response text.
--: (any) -> (integer | nil, string | nil)
local function smtp_read_response(transport)
	local lines = {}
	while true do
		local line, err = transport:recv()
		if not line then
			return nil, err or "connection closed"
		end
		-- Strip trailing CRLF
		line = line:gsub("\r?\n$", "")
		lines[#lines + 1] = line
		-- SMTP multiline: "250-..." continues, "250 ..." is final
		local code = tonumber(line:sub(1, 3))
		if not code then
			return nil, "invalid SMTP response: " .. line
		end
		if line:byte(4) ~= 45 then -- not '-'
			return code, table.concat(lines, "\n")
		end
	end
end

-- Connect to SMTP server
--: ({ host: string, port: integer, transport: unknown }) -> (any | nil, string | nil)
function M.smtp_connect(opts)
	if not opts.transport then
		return nil, "transport required"
	end

	local smtp = setmetatable({
		_transport = opts.transport,
		_capabilities = {},
	}, SMTP)

	-- Read server greeting
	local code, resp = smtp_read_response(--[[:! { recv: any, send: any }]] opts.transport)
	if not code then return nil, resp end
	if code ~= 220 then
		return nil, "unexpected greeting: " .. (resp or "")
	end

	return smtp, nil
end

-- Send EHLO
--: (string) -> (boolean | nil, string | nil)
function SMTP:ehlo(domain)
	self._transport:send("EHLO " .. domain .. "\r\n")
	local code, resp = smtp_read_response(self._transport)
	if not code then return nil, resp end
	if code ~= 250 then
		return nil, "EHLO failed: " .. (resp or "")
	end
	-- Parse capabilities from multiline response
	self._capabilities = {}
	for line in resp:gmatch("[^\n]+") do
		local cap = line:sub(5) -- skip "250 " or "250-"
		self._capabilities[#self._capabilities + 1] = cap
	end
	return true, nil
end

-- Send STARTTLS
--: (unknown) -> (boolean | nil, string | nil)
function SMTP:starttls(tls_context)
	self._transport:send("STARTTLS\r\n")
	local code, resp = smtp_read_response(self._transport)
	if not code then return nil, resp end
	if code ~= 220 then
		return nil, "STARTTLS failed: " .. (resp or "")
	end
	-- Upgrade transport to TLS if supported
	if self._transport.upgrade_tls then
		local ok, err = self._transport:upgrade_tls(tls_context)
		if not ok then return nil, err end
	end
	return true, nil
end

-- Authenticate
--: (string, string, string) -> (boolean | nil, string | nil)
function SMTP:auth(method, username, password)
	method = method:upper()
	if method == "PLAIN" then
		local credentials = base64.encode("\0" .. username .. "\0" .. password)
		self._transport:send("AUTH PLAIN " .. credentials .. "\r\n")
		local code, resp = smtp_read_response(self._transport)
		if not code then return nil, resp end
		if code ~= 235 then
			return nil, "AUTH PLAIN failed: " .. (resp or "")
		end
		return true, nil
	elseif method == "LOGIN" then
		self._transport:send("AUTH LOGIN\r\n")
		local code, resp = smtp_read_response(self._transport)
		if not code then return nil, resp end
		if code ~= 334 then
			return nil, "AUTH LOGIN failed: " .. (resp or "")
		end
		self._transport:send(base64.encode(username) .. "\r\n")
		code, resp = smtp_read_response(self._transport)
		if not code then return nil, resp end
		if code ~= 334 then
			return nil, "AUTH LOGIN username rejected: " .. (resp or "")
		end
		self._transport:send(base64.encode(password) .. "\r\n")
		code, resp = smtp_read_response(self._transport)
		if not code then return nil, resp end
		if code ~= 235 then
			return nil, "AUTH LOGIN failed: " .. (resp or "")
		end
		return true, nil
	else
		return nil, "unsupported auth method: " .. method
	end
end

-- Send a message
--: (any) -> (boolean | nil, string | nil)
function SMTP:send(msg)
	local raw, err = msg:to_string()
	if not raw then return nil, err end
	return self:send_raw({
		from = msg.from,
		to = msg.to,
		cc = msg.cc,
		bcc = msg.bcc,
		data = raw,
	})
end

-- Send raw email data
--: ({ from: string, to: { string } | nil, cc: { string } | nil, bcc: { string } | nil, data: string }) -> (boolean | nil, string | nil)
function SMTP:send_raw(opts)
	-- MAIL FROM
	self._transport:send("MAIL FROM:<" .. opts.from .. ">\r\n")
	local code, resp = smtp_read_response(self._transport)
	if not code then return nil, resp end
	if code ~= 250 then
		return nil, "MAIL FROM rejected: " .. (resp or "")
	end

	-- RCPT TO for all recipients
	local all_rcpts = {}
	if opts.to then
		for _, addr in ipairs(opts.to) do all_rcpts[#all_rcpts + 1] = addr end
	end
	if opts.cc then
		for _, addr in ipairs(opts.cc) do all_rcpts[#all_rcpts + 1] = addr end
	end
	if opts.bcc then
		for _, addr in ipairs(opts.bcc) do all_rcpts[#all_rcpts + 1] = addr end
	end

	for _, addr in ipairs(all_rcpts) do
		self._transport:send("RCPT TO:<" .. addr .. ">\r\n")
		code, resp = smtp_read_response(self._transport)
		if not code then return nil, resp end
		if code ~= 250 then
			return nil, "RCPT TO <" .. addr .. "> rejected: " .. (resp or "")
		end
	end

	-- DATA
	self._transport:send("DATA\r\n")
	code, resp = smtp_read_response(self._transport)
	if not code then return nil, resp end
	if code ~= 354 then
		return nil, "DATA rejected: " .. (resp or "")
	end

	-- Send message data with dot-stuffing
	local data = opts.data
	-- Ensure CRLF line endings
	if not data:find("\r\n", 1, true) then
		data = data:gsub("\n", "\r\n")
	end
	-- Dot-stuffing: lines starting with . get an extra .
	data = data:gsub("\r\n%.", "\r\n..")
	self._transport:send(data .. "\r\n.\r\n")

	code, resp = smtp_read_response(self._transport)
	if not code then return nil, resp end
	if code ~= 250 then
		return nil, "DATA content rejected: " .. (resp or "")
	end

	return true, nil
end

-- Quit
--: () -> (boolean | nil, string | nil)
function SMTP:quit()
	self._transport:send("QUIT\r\n")
	local code, resp = smtp_read_response(self._transport)
	if not code then return nil, resp end
	if code ~= 221 then
		return nil, "QUIT failed: " .. (resp or "")
	end
	self._transport:close()
	return true, nil
end

-- ── Mock Transport ───────────────────────────────────────────────────────

-- Create a mock transport for testing.
-- responses: array of strings the server will send (one per recv() call)
-- Returns: transport object with :send(), :recv(), :close() and .sent (array of sent strings)
--: ({ string }) -> ({ send: (any, string) -> nil, recv: (any) -> (string | nil, string | nil), close: (any) -> nil, sent: { string } })
function M.mock_transport(responses)
	-- Split multiline responses into individual lines for realistic socket behavior.
	local lines = {}
	for _, resp in ipairs(responses or {}) do
		local pos = 1
		while pos <= #resp do
			local nl = resp:find("\r\n", pos, true) or resp:find("\n", pos, true)
			if nl then
				local crlf = resp:byte(nl) == 13
				local line = resp:sub(pos, crlf and nl + 1 or nl)
				lines[#lines + 1] = line
				pos = crlf and nl + 2 or nl + 1
			else
				lines[#lines + 1] = resp:sub(pos)
				break
			end
		end
	end
	local t = {
		sent = {},
		_lines = lines,
		_pos = 1,
		_closed = false,
	}
	function t:send(data)
		self.sent[#self.sent + 1] = data
	end
	function t:recv()
		if self._closed then return nil, "closed" end
		if self._pos > #self._lines then return nil, "no more responses" end
		local line = self._lines[self._pos]
		self._pos = self._pos + 1
		return line, nil
	end
	function t:close()
		self._closed = true
	end
	return t
end

return M
