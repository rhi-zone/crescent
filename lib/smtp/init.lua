if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- RFC 5321 SMTP client with injectable transport
-- Transport: { send(self, str), recv(self) -> string }
-- recv() returns one line at a time (without trailing CRLF)

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Response parsing
-- ---------------------------------------------------------------------------

-- Parse a single SMTP response line.
-- Returns code (integer), text (string), more (boolean)
-- more=true means this is a continuation line (code-text, dash separator)
-- Returns nil, errmsg on parse failure.
M.parse_response_line = function(line)
	if not line then return nil, "smtp: nil response line" end
	local code_str, sep, text = line:match("^(%d%d%d)([ %-])(.*)")
	if not code_str then return nil, "smtp: invalid response line: " .. tostring(line) end
	local code = tonumber(code_str)
	local more = (sep == "-")
	return code, text, more
end

-- Read a full (possibly multi-line) SMTP response from transport.
-- Returns code (integer), lines (table of strings), or nil, errmsg.
M.read_response = function(transport)
	local lines = {}
	local code
	while true do
		local line = transport:recv()
		if not line then return nil, "smtp: connection closed while reading response" end
		local c, text, more = M.parse_response_line(line)
		if not c then return nil, text end
		if code and c ~= code then
			return nil, "smtp: mismatched response codes in multi-line response"
		end
		code = c
		lines[#lines + 1] = text
		if not more then break end
	end
	return code, lines
end

-- Convenience: read response, return {ok, code, text} or nil, errmsg.
-- ok=true for 2xx codes.
local function read_reply(transport)
	local code, lines = M.read_response(transport)
	if not code then return nil, lines end
	local co = (code --[[: any]]) --[[:! integer]]
	local lns = (lines --[[: any]]) --[[:! { [integer]: string }]]
	local text = table.concat(lns, "\n")
	return { ok = co >= 200 and co < 300, code = co, text = text, lines = lns }
end

-- parse_response: parse the first line of a response string (for external use)
-- Returns code (integer), text (string) or nil, errmsg
M.parse_response = function(line)
	local code, text = M.parse_response_line(line)
	if not code then return nil, text end
	return code, text
end

-- ---------------------------------------------------------------------------
-- Address utilities
-- ---------------------------------------------------------------------------

-- Validate an email address (basic RFC 5321 check)
M.validate_address = function(addr)
	if type(addr) ~= "string" then return false end
	-- local-part@domain; both non-empty, domain has at least one dot
	local local_part, domain = addr:match("^([^@]+)@([^@]+)$")
	if not local_part or not domain then return false end
	local lp = local_part --[[:! string]]
	local dom = domain --[[:! string]]
	if #lp == 0 or #dom == 0 then return false end
	-- domain must contain at least one dot and no consecutive dots
	if not dom:find("%.") then return false end
	if dom:find("%.%.") then return false end
	-- no leading/trailing dots in domain
	if dom:sub(1,1) == "." or dom:sub(-1) == "." then return false end
	return true
end

-- Parse "Display Name <user@domain>" or "user@domain"
-- Returns {name, addr} or nil, errmsg
M.parse_address = function(s)
	if type(s) ~= "string" then return nil, "smtp: address must be a string" end
	-- Try "Name <addr>" form
	local name, addr = s:match("^%s*(.-)%s*<([^>]+)>%s*$")
	if addr then
		-- strip quotes from name if present
		name = name:gsub('^"(.*)"$', "%1")
		return { name = name, addr = addr }
	end
	-- bare address
	local bare = s:match("^%s*([^%s]+)%s*$")
	if bare then
		return { name = "", addr = bare }
	end
	return nil, "smtp: cannot parse address: " .. s
end

-- Format {name, addr} as an RFC 2822 address string
--: ({ name: string | nil, addr: string | nil } | nil) -> (string | nil, string | nil)
M.format_address = function(t)
	if not t or not t.addr then return nil, "smtp: format_address: missing addr" end
	if t.name and t.name ~= "" then
		-- quote name if it contains special chars
		local name = t.name --[[:! string]]
		if name:find('[",;:<>@%(%)%[%]\\]') then
			local escaped = name:gsub('"', '\\"')
			name = '"' .. escaped .. '"'
		end
		return name .. " <" .. t.addr .. ">"
	end
	return t.addr
end

-- ---------------------------------------------------------------------------
-- Message building (RFC 2822)
-- ---------------------------------------------------------------------------

local BOUNDARY_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

--: (integer) -> string
local function make_boundary(seed)
	if not seed then error("smtp: seed is required for boundary generation") end
	math.randomseed(seed)
	local t = {}
	for i = 1, 24 do
		local idx = math.random(1, #BOUNDARY_CHARS) --[[:! integer]]
		t[i] = BOUNDARY_CHARS:sub(idx, idx)
	end
	return "----=_Part_" .. table.concat(t)
end

-- Format a list of addresses (strings or {name,addr} tables) for a header
local function format_addr_list(list)
	local parts = {}
	for _, a in ipairs(list) do
		if type(a) == "string" then
			parts[#parts + 1] = a
		else
			parts[#parts + 1] = M.format_address(a)
		end
	end
	return table.concat(parts, ", ")
end

-- RFC 2822 date format
--: ((() -> { wday: integer, day: integer, month: integer, year: integer, hour: integer, min: integer, sec: integer })) -> string
local function rfc2822_date(time_fn)
	local days = {"Sun","Mon","Tue","Wed","Thu","Fri","Sat"}
	local months = {"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"}
	local t = time_fn()
	return string.format("%s, %02d %s %04d %02d:%02d:%02d +0000",
		days[t.wday], t.day, months[t.month], t.year, t.hour, t.min, t.sec)
end

-- Encode a string as quoted-printable (RFC 2045)
-- Handles line folding at 76 chars
--: (string) -> string
local function quoted_printable_encode(s)
	local out = {}
	local line = {}
	local line_len = 0

	local function flush_line(soft)
		if soft then
			out[#out + 1] = table.concat(line) .. "=\r\n"
		else
			out[#out + 1] = table.concat(line) .. "\r\n"
		end
		line = {}
		line_len = 0
	end

	local i = 1
	while i <= #s do
		local c_raw = s:byte(i)
		local c = (c_raw or 0) --[[:! integer]]
		--: string | nil
		local encoded
		if c == 13 and s:byte(i+1) == 10 then
			-- CRLF: flush current line as-is
			flush_line(false)
			i = i + 2
		elseif c == 10 then
			flush_line(false)
			i = i + 1
		elseif (c >= 33 and c <= 126 and c ~= 61) or (c == 9 or c == 32) then
			encoded = string.char(c)
		else
			encoded = string.format("=%02X", c)
		end
		if encoded then
			if line_len + #encoded > 75 then
				flush_line(true)
			end
			line[#line + 1] = encoded
			line_len = line_len + #encoded
			i = i + 1
		end
	end
	if #line > 0 then
		out[#out + 1] = table.concat(line) .. "\r\n"
	end
	return table.concat(out)
end

-- Build a MIME text/plain part
local function build_text_part(body)
	local lines = {
		"Content-Type: text/plain; charset=UTF-8",
		"Content-Transfer-Encoding: quoted-printable",
		"",
		quoted_printable_encode(body),
	}
	return table.concat(lines, "\r\n")
end

-- Build a MIME text/html part
local function build_html_part(html)
	local lines = {
		"Content-Type: text/html; charset=UTF-8",
		"Content-Transfer-Encoding: quoted-printable",
		"",
		quoted_printable_encode(html),
	}
	return table.concat(lines, "\r\n")
end

-- Build an RFC 2822 message from a message table.
-- msg fields:
--   from (string), to (list), subject (string), body (string)
--   cc (list, optional), bcc (list, optional)
--   headers (table, optional) — additional headers
--   html (string, optional) — triggers multipart/alternative
--   seed (integer) — required when html is set (for boundary generation)
--   time_fn () -> date_table — required; returns os.date("*t")-compatible table
-- Returns the raw message string.
--: ({ from: string | nil, to: { [integer]: unknown } | nil, subject: string | nil, body: string | nil, cc: { [integer]: unknown } | nil, headers: { [string]: string } | nil, text: string | nil, html: string | nil, seed: integer | nil, time_fn: (() -> { wday: integer, day: integer, month: integer, year: integer, hour: integer, min: integer, sec: integer }) | nil }) -> string
M.build_message = function(msg)
	local parts = {}

	-- Required headers
	local from = msg.from or ""
	local to_list = msg.to or {}
	local subject = msg.subject or ""

	parts[#parts + 1] = "From: " .. from
	parts[#parts + 1] = "To: " .. format_addr_list(to_list)
	if msg.cc and #msg.cc > 0 then
		parts[#parts + 1] = "Cc: " .. format_addr_list(msg.cc)
	end
	parts[#parts + 1] = "Subject: " .. subject
	if msg.time_fn then
		parts[#parts + 1] = "Date: " .. rfc2822_date(msg.time_fn)
	end
	parts[#parts + 1] = "MIME-Version: 1.0"

	-- Extra headers
	if msg.headers then
		for k, v in pairs(msg.headers) do
			parts[#parts + 1] = k .. ": " .. v
		end
	end

	local body = msg.body or ""

	if msg.html then
		-- multipart/alternative
		local boundary = make_boundary(msg.seed or 0)
		parts[#parts + 1] = 'Content-Type: multipart/alternative; boundary="' .. boundary .. '"'
		parts[#parts + 1] = ""  -- end of headers
		parts[#parts + 1] = "--" .. boundary
		parts[#parts + 1] = build_text_part(body)
		parts[#parts + 1] = "--" .. boundary
		parts[#parts + 1] = build_html_part(msg.html)
		parts[#parts + 1] = "--" .. boundary .. "--"
		parts[#parts + 1] = ""
	else
		parts[#parts + 1] = "Content-Type: text/plain; charset=UTF-8"
		parts[#parts + 1] = "Content-Transfer-Encoding: quoted-printable"
		parts[#parts + 1] = ""  -- end of headers
		parts[#parts + 1] = quoted_printable_encode(body)
	end

	return table.concat(parts, "\r\n")
end

-- ---------------------------------------------------------------------------
-- Session state machine
-- ---------------------------------------------------------------------------

--:: SmtpTransport = { send: (SmtpTransport, string) -> unknown, recv: (SmtpTransport) -> string | nil, ... }
--:: SmtpSession = { transport: SmtpTransport, ... }

local Session = {}
Session.__index = Session

-- Create a new SMTP session over the given transport.
-- The transport must have already received the server greeting (220 ...).
M.session = function(transport)
	return setmetatable({ transport = transport }, Session)
end

-- Send a raw command line (CRLF appended automatically)
--: (SmtpSession, string) -> unknown
function Session:command(cmd)
	local s = self --[[:! SmtpSession]]
	return s.transport:send(cmd .. "\r\n")
end

-- Send EHLO and parse the extension list.
-- Returns {ok=true, extensions={...}} or {ok=false, err="..."}
function Session:ehlo(hostname)
	local s = self --[[:! SmtpSession]]
	hostname = hostname or "localhost"
	s:command("EHLO " .. hostname)
	local code, lines = M.read_response(s.transport)
	if not code then return nil, lines end
	local lns = (lines --[[: any]]) --[[:! { [integer]: string }]]
	if code ~= 250 then
		return { ok = false, err = "EHLO failed: " .. table.concat(lns, " ") }
	end
	-- First line is the greeting; rest are capabilities
	local extensions = {}
	for i = 2, #lns do
		extensions[#extensions + 1] = lns[i]
	end
	return { ok = true, extensions = extensions }
end

-- AUTH PLAIN: sends credentials in base64
function Session:auth_plain(user, password)
	-- PLAIN: "\0user\0password" base64-encoded
	local credentials = "\0" .. user .. "\0" .. password
	-- base64 encode
	local b64 = M.base64_encode(credentials)
	self:command("AUTH PLAIN " .. b64)
	local code, lines = M.read_response(self.transport)
	if not code then return nil, lines end
	if code ~= 235 then
		return { ok = false, err = "AUTH PLAIN failed: " .. (lines and lines[1] or "") }
	end
	return { ok = true }
end

-- AUTH LOGIN: two-step challenge/response
function Session:auth_login(user, password)
	self:command("AUTH LOGIN")
	local code, lines = M.read_response(self.transport)
	if not code then return nil, lines end
	if code ~= 334 then
		return { ok = false, err = "AUTH LOGIN: unexpected response: " .. (lines and lines[1] or "") }
	end
	-- send username
	self:command(M.base64_encode(user))
	code, lines = M.read_response(self.transport)
	if not code then return nil, lines end
	if code ~= 334 then
		return { ok = false, err = "AUTH LOGIN: username not accepted: " .. (lines and lines[1] or "") }
	end
	-- send password
	self:command(M.base64_encode(password))
	code, lines = M.read_response(self.transport)
	if not code then return nil, lines end
	if code ~= 235 then
		return { ok = false, err = "AUTH LOGIN failed: " .. (lines and lines[1] or "") }
	end
	return { ok = true }
end

-- MAIL FROM command
function Session:mail_from(addr)
	self:command("MAIL FROM:<" .. addr .. ">")
	local code, lines = M.read_response(self.transport)
	if not code then return nil, lines end
	if code ~= 250 then
		return { ok = false, err = "MAIL FROM failed: " .. (lines and lines[1] or "") }
	end
	return { ok = true }
end

-- RCPT TO command
function Session:rcpt_to(addr)
	self:command("RCPT TO:<" .. addr .. ">")
	local code, lines = M.read_response(self.transport)
	if not code then return nil, lines end
	if code ~= 250 and code ~= 251 then
		return { ok = false, err = "RCPT TO failed (" .. addr .. "): " .. (lines and lines[1] or "") }
	end
	return { ok = true }
end

-- DATA command: send raw message body
-- raw_message should already be a properly formatted RFC 2822 message.
-- Lines starting with "." are dot-stuffed automatically.
function Session:data(raw_message)
	self:command("DATA")
	local code, lines = M.read_response(self.transport)
	if not code then return nil, lines end
	if code ~= 354 then
		return { ok = false, err = "DATA not accepted: " .. (lines and lines[1] or "") }
	end
	-- Dot-stuff: any line starting with "." gets an extra "." prepended
	local stuffed = raw_message:gsub("\r\n%.", "\r\n..")
	-- Ensure message ends with CRLF before terminator
	if not stuffed:match("\r\n$") then
		stuffed = stuffed .. "\r\n"
	end
	self.transport:send(stuffed .. ".\r\n")
	code, lines = M.read_response(self.transport)
	if not code then return nil, lines end
	if code ~= 250 then
		return { ok = false, err = "DATA delivery failed: " .. (lines and lines[1] or "") }
	end
	return { ok = true }
end

-- QUIT command
function Session:quit()
	self:command("QUIT")
	-- read the 221 goodbye (best effort)
	M.read_response(self.transport)
end

-- RSET command (reset mail transaction)
function Session:rset()
	self:command("RSET")
	local code, lines = M.read_response(self.transport)
	if not code then return nil, lines end
	if code ~= 250 then
		return { ok = false, err = "RSET failed: " .. (lines and lines[1] or "") }
	end
	return { ok = true }
end

-- NOOP command
function Session:noop()
	self:command("NOOP")
	local code, lines = M.read_response(self.transport)
	if not code then return nil, lines end
	return { ok = code == 250, code = code, text = lines and lines[1] or "" }
end

-- ---------------------------------------------------------------------------
-- High-level send
-- ---------------------------------------------------------------------------

-- smtp.send(transport, msg, opts?) — drives the full SMTP conversation.
-- Expects transport to have already received the initial 220 greeting.
-- opts: { ehlo_host="localhost", auth={user, password, method="plain"|"login"} }
-- Returns true on success, or nil, errmsg on failure.
M.send = function(transport, msg, opts)
	opts = opts or {}
	local session = M.session(transport)

	-- EHLO
	local ehlo_host = opts.ehlo_host or "localhost"
	local result, err = session:ehlo(ehlo_host)
	if not result then return nil, err end
	if not result.ok then return nil, result.err end

	-- AUTH (optional)
	if opts.auth then
		local auth = opts.auth
		local method = auth.method or "plain"
		local auth_result
		if method == "login" then
			auth_result, err = session:auth_login(auth.user, auth.password)
		else
			auth_result, err = session:auth_plain(auth.user, auth.password)
		end
		if not auth_result then return nil, err end
		if not auth_result.ok then return nil, auth_result.err end
	end

	-- MAIL FROM
	local from_addr = msg.from
	if type(from_addr) == "table" then from_addr = from_addr.addr end
	local mail_result
	mail_result, err = session:mail_from(from_addr)
	if not mail_result then return nil, err end
	if not mail_result.ok then return nil, mail_result.err end

	-- RCPT TO for all recipients (to + cc + bcc)
	local all_rcpt = {}
	for _, a in ipairs(msg.to or {}) do all_rcpt[#all_rcpt + 1] = a end
	for _, a in ipairs(msg.cc or {}) do all_rcpt[#all_rcpt + 1] = a end
	for _, a in ipairs(msg.bcc or {}) do all_rcpt[#all_rcpt + 1] = a end

	for _, rcpt in ipairs(all_rcpt) do
		local addr = rcpt
		if type(addr) == "table" then addr = addr.addr end
		local rcpt_result
		rcpt_result, err = session:rcpt_to(addr)
		if not rcpt_result then return nil, err end
		if not rcpt_result.ok then return nil, rcpt_result.err end
	end

	-- DATA
	local raw = M.build_message(msg)
	local data_result
	data_result, err = session:data(raw)
	if not data_result then return nil, err end
	if not data_result.ok then return nil, data_result.err end

	session:quit()
	return true
end

-- ---------------------------------------------------------------------------
-- Base64 encoding (RFC 4648, no line wrapping)
-- ---------------------------------------------------------------------------

local b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

M.base64_encode = function(s)
	local out = {}
	local len = #s
	local i = 1
	while i <= len do
		local b0 = s:byte(i)
		local b1 = s:byte(i + 1) or 0
		local b2 = s:byte(i + 2) or 0
		local n = b0 * 65536 + b1 * 256 + b2
		out[#out + 1] = b64_chars:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
		out[#out + 1] = b64_chars:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
		if i + 1 <= len then
			out[#out + 1] = b64_chars:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)
		else
			out[#out + 1] = "="
		end
		if i + 2 <= len then
			out[#out + 1] = b64_chars:sub(n % 64 + 1, n % 64 + 1)
		else
			out[#out + 1] = "="
		end
		i = i + 3
	end
	return table.concat(out)
end

M.base64_decode = function(s)
	local decode = {}
	for i = 1, #b64_chars do
		decode[b64_chars:sub(i,i)] = i - 1
	end
	local out = {}
	local i = 1
	while i <= #s do
		local c0 = decode[s:sub(i, i)] or 0
		local c1 = decode[s:sub(i+1, i+1)] or 0
		local c2 = decode[s:sub(i+2, i+2)]
		local c3 = decode[s:sub(i+3, i+3)]
		local b0 = c0 * 4 + math.floor(c1 / 16)
		out[#out + 1] = string.char(b0)
		if c2 ~= nil then
			local b1 = (c1 % 16) * 16 + math.floor(c2 / 4)
			out[#out + 1] = string.char(b1)
		end
		if c3 ~= nil then
			local b2 = (c2 % 4) * 64 + c3
			out[#out + 1] = string.char(b2)
		end
		i = i + 4
	end
	return table.concat(out)
end

return M
