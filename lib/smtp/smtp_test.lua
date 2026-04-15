if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local smtp = require("lib.smtp")
local T = require("lib.test.assert")

-- Default time_fn for tests
local test_time_fn = function()
  return { year = 2025, month = 1, day = 15, hour = 10, min = 30, sec = 0, wday = 4 }
end

-- Wrap build_message to inject time_fn for tests
local _build_message = smtp.build_message
smtp.build_message = function(msg)
  if not msg.time_fn then msg.time_fn = test_time_fn end
  return _build_message(msg)
end

-- ---------------------------------------------------------------------------
-- Mock transport helper
-- ---------------------------------------------------------------------------

local function make_transport(server_responses)
	local i = 0
	local sent = {}
	return {
		send = function(self, data) sent[#sent + 1] = data end,
		recv = function(self)
			i = i + 1
			return server_responses[i]
		end,
		sent = sent,
	}
end

-- ---------------------------------------------------------------------------
-- parse_response
-- ---------------------------------------------------------------------------

T.describe("parse_response", function()
	T.it("250 OK", function()
		local code, text = smtp.parse_response("250 OK")
		T.eq(code, 250)
		T.eq(text, "OK")
	end)

	T.it("354 start mail input", function()
		local code, text = smtp.parse_response("354 Start mail input; end with <CRLF>.<CRLF>")
		T.eq(code, 354)
		T.eq(text, "Start mail input; end with <CRLF>.<CRLF>")
	end)

	T.it("550 error", function()
		local code, text = smtp.parse_response("550 Requested action not taken")
		T.eq(code, 550)
		T.eq(text, "Requested action not taken")
	end)

	T.it("221 goodbye", function()
		local code, text = smtp.parse_response("221 Bye")
		T.eq(code, 221)
		T.eq(text, "Bye")
	end)

	T.it("nil input returns error", function()
		local code, err = smtp.parse_response(nil)
		T.eq(code, nil)
		T.ok(err ~= nil)
	end)

	T.it("invalid format returns error", function()
		local code, err = smtp.parse_response("hello world")
		T.eq(code, nil)
		T.ok(err ~= nil)
	end)
end)

-- ---------------------------------------------------------------------------
-- read_response (multi-line)
-- ---------------------------------------------------------------------------

T.describe("read_response", function()
	T.it("single line response", function()
		local t = make_transport({"250 OK"})
		local code, lines = smtp.read_response(t)
		T.eq(code, 250)
		T.eq(#lines, 1)
		T.eq(lines[1], "OK")
	end)

	T.it("multi-line EHLO response", function()
		local t = make_transport({
			"250-smtp.example.com Hello",
			"250-STARTTLS",
			"250-AUTH PLAIN LOGIN",
			"250 SIZE 10240000",
		})
		local code, lines = smtp.read_response(t)
		T.eq(code, 250)
		T.eq(#lines, 4)
		T.eq(lines[1], "smtp.example.com Hello")
		T.eq(lines[2], "STARTTLS")
		T.eq(lines[3], "AUTH PLAIN LOGIN")
		T.eq(lines[4], "SIZE 10240000")
	end)

	T.it("connection closed mid-response returns error", function()
		local t = make_transport({})
		local code, err = smtp.read_response(t)
		T.eq(code, nil)
		T.ok(err ~= nil)
	end)
end)

-- ---------------------------------------------------------------------------
-- validate_address
-- ---------------------------------------------------------------------------

T.describe("validate_address", function()
	T.it("valid simple address", function()
		T.ok(smtp.validate_address("user@domain.com"))
	end)

	T.it("valid with subdomain", function()
		T.ok(smtp.validate_address("user@mail.example.co.uk"))
	end)

	T.it("valid with plus tag", function()
		T.ok(smtp.validate_address("user+tag@domain.com"))
	end)

	T.it("missing @", function()
		T.ok(not smtp.validate_address("notanemail"))
	end)

	T.it("missing domain dot", function()
		T.ok(not smtp.validate_address("user@nodot"))
	end)

	T.it("empty string", function()
		T.ok(not smtp.validate_address(""))
	end)

	T.it("multiple @", function()
		T.ok(not smtp.validate_address("a@b@c.com"))
	end)

	T.it("leading dot in domain", function()
		T.ok(not smtp.validate_address("user@.domain.com"))
	end)

	T.it("trailing dot in domain", function()
		T.ok(not smtp.validate_address("user@domain.com."))
	end)

	T.it("consecutive dots in domain", function()
		T.ok(not smtp.validate_address("user@domain..com"))
	end)

	T.it("non-string input", function()
		T.ok(not smtp.validate_address(42))
	end)
end)

-- ---------------------------------------------------------------------------
-- parse_address / format_address
-- ---------------------------------------------------------------------------

T.describe("parse_address", function()
	T.it("name and angle-bracket address", function()
		local a = smtp.parse_address("John Doe <john@example.com>")
		T.ok(a ~= nil)
		T.eq(a.name, "John Doe")
		T.eq(a.addr, "john@example.com")
	end)

	T.it("quoted name", function()
		local a = smtp.parse_address('"Doe, John" <john@example.com>')
		T.ok(a ~= nil)
		T.eq(a.name, "Doe, John")
		T.eq(a.addr, "john@example.com")
	end)

	T.it("bare address", function()
		local a = smtp.parse_address("user@example.com")
		T.ok(a ~= nil)
		T.eq(a.addr, "user@example.com")
		T.eq(a.name, "")
	end)

	T.it("whitespace trimmed", function()
		local a = smtp.parse_address("  user@example.com  ")
		T.ok(a ~= nil)
		T.eq(a.addr, "user@example.com")
	end)
end)

T.describe("format_address", function()
	T.it("name and addr", function()
		local s = smtp.format_address({name = "John Doe", addr = "john@example.com"})
		T.eq(s, "John Doe <john@example.com>")
	end)

	T.it("bare addr (empty name)", function()
		local s = smtp.format_address({name = "", addr = "john@example.com"})
		T.eq(s, "john@example.com")
	end)

	T.it("name with special chars is quoted", function()
		local s = smtp.format_address({name = "Doe, John", addr = "john@example.com"})
		T.eq(s, '"Doe, John" <john@example.com>')
	end)
end)

T.describe("parse_address / format_address round-trip", function()
	T.it("round-trip name+addr", function()
		local original = "John Doe <john@example.com>"
		local parsed = smtp.parse_address(original)
		T.ok(parsed ~= nil)
		local formatted = smtp.format_address(parsed)
		T.eq(formatted, original)
	end)

	T.it("round-trip bare addr", function()
		local original = "user@example.com"
		local parsed = smtp.parse_address(original)
		T.ok(parsed ~= nil)
		local formatted = smtp.format_address(parsed)
		T.eq(formatted, original)
	end)
end)

-- ---------------------------------------------------------------------------
-- build_message
-- ---------------------------------------------------------------------------

T.describe("build_message", function()
	T.it("basic from/to/subject/body", function()
		local raw = smtp.build_message({
			from = "sender@example.com",
			to = {"recipient@example.com"},
			subject = "Hello",
			body = "Test body\r\n",
		})
		T.ok(raw:find("From: sender@example.com", 1, true) ~= nil)
		T.ok(raw:find("To: recipient@example.com", 1, true) ~= nil)
		T.ok(raw:find("Subject: Hello", 1, true) ~= nil)
		T.ok(raw:find("MIME-Version: 1.0", 1, true) ~= nil)
		T.ok(raw:find("Content-Type: text/plain", 1, true) ~= nil)
		T.ok(raw:find("Content-Transfer-Encoding: quoted-printable", 1, true) ~= nil)
	end)

	T.it("includes Date header", function()
		local raw = smtp.build_message({
			from = "a@b.com",
			to = {"c@d.com"},
			subject = "X",
			body = "",
		})
		T.ok(raw:find("Date:", 1, true) ~= nil)
	end)

	T.it("multiple To recipients", function()
		local raw = smtp.build_message({
			from = "a@b.com",
			to = {"x@y.com", "z@w.com"},
			subject = "Multi",
			body = "hi",
		})
		T.ok(raw:find("To: x@y.com, z@w.com", 1, true) ~= nil)
	end)

	T.it("Cc header included", function()
		local raw = smtp.build_message({
			from = "a@b.com",
			to = {"x@y.com"},
			cc = {"cc@example.com"},
			subject = "CC test",
			body = "body",
		})
		T.ok(raw:find("Cc: cc@example.com", 1, true) ~= nil)
	end)

	T.it("custom headers", function()
		local raw = smtp.build_message({
			from = "a@b.com",
			to = {"x@y.com"},
			subject = "Custom",
			body = "body",
			headers = {["X-Custom"] = "myvalue"},
		})
		T.ok(raw:find("X-Custom: myvalue", 1, true) ~= nil)
	end)

	T.it("multipart/alternative for html+text", function()
		local raw = smtp.build_message({
			from = "a@b.com",
			to = {"x@y.com"},
			subject = "HTML",
			body = "Plain text",
			html = "<p>HTML version</p>",
			seed = 42,
		})
		T.ok(raw:find("multipart/alternative", 1, true) ~= nil)
		T.ok(raw:find("boundary=", 1, true) ~= nil)
		T.ok(raw:find("text/plain", 1, true) ~= nil)
		T.ok(raw:find("text/html", 1, true) ~= nil)
	end)

	T.it("body is quoted-printable encoded", function()
		-- non-ASCII byte should be encoded
		local raw = smtp.build_message({
			from = "a@b.com",
			to = {"x@y.com"},
			subject = "QP",
			body = "caf\xc3\xa9",  -- "café" in UTF-8
		})
		T.ok(raw:find("=C3=A9", 1, true) ~= nil or raw:find("=C3", 1, true) ~= nil)
	end)
end)

-- ---------------------------------------------------------------------------
-- Session: ehlo
-- ---------------------------------------------------------------------------

T.describe("session:ehlo", function()
	T.it("parses extensions from multi-line EHLO response", function()
		local t = make_transport({
			"250-smtp.example.com Hello",
			"250-STARTTLS",
			"250-AUTH PLAIN LOGIN",
			"250 SIZE 10240000",
		})
		local session = smtp.session(t)
		local result = session:ehlo("myhost.local")
		T.ok(result ~= nil)
		T.ok(result.ok)
		T.eq(#result.extensions, 3)
		T.eq(result.extensions[1], "STARTTLS")
		T.eq(result.extensions[2], "AUTH PLAIN LOGIN")
		T.eq(result.extensions[3], "SIZE 10240000")
		-- check the EHLO command was sent
		T.eq(t.sent[1], "EHLO myhost.local\r\n")
	end)

	T.it("returns error on 5xx response", function()
		local t = make_transport({"500 Error"})
		local session = smtp.session(t)
		local result = session:ehlo("myhost")
		T.ok(result ~= nil)
		T.ok(not result.ok)
		T.ok(result.err ~= nil)
	end)
end)

-- ---------------------------------------------------------------------------
-- Session: mail_from / rcpt_to / data / quit
-- ---------------------------------------------------------------------------

T.describe("session:mail_from", function()
	T.it("sends MAIL FROM and returns ok on 250", function()
		local t = make_transport({"250 OK"})
		local session = smtp.session(t)
		local result = session:mail_from("sender@example.com")
		T.ok(result.ok)
		T.eq(t.sent[1], "MAIL FROM:<sender@example.com>\r\n")
	end)

	T.it("returns error on 5xx", function()
		local t = make_transport({"550 Rejected"})
		local session = smtp.session(t)
		local result = session:mail_from("bad@example.com")
		T.ok(not result.ok)
		T.ok(result.err ~= nil)
	end)
end)

T.describe("session:rcpt_to", function()
	T.it("sends RCPT TO and returns ok on 250", function()
		local t = make_transport({"250 OK"})
		local session = smtp.session(t)
		local result = session:rcpt_to("recipient@example.com")
		T.ok(result.ok)
		T.eq(t.sent[1], "RCPT TO:<recipient@example.com>\r\n")
	end)

	T.it("accepts 251 forwarded", function()
		local t = make_transport({"251 User not local; will forward"})
		local session = smtp.session(t)
		local result = session:rcpt_to("someone@example.com")
		T.ok(result.ok)
	end)

	T.it("returns error on 550", function()
		local t = make_transport({"550 No such user"})
		local session = smtp.session(t)
		local result = session:rcpt_to("nobody@example.com")
		T.ok(not result.ok)
		T.ok(result.err:find("nobody@example.com"))
	end)
end)

T.describe("session:data", function()
	T.it("sends DATA, message, and terminator", function()
		local t = make_transport({
			"354 Start mail input",
			"250 OK",
		})
		local session = smtp.session(t)
		local result = session:data("From: a@b.com\r\n\r\nHello\r\n")
		T.ok(result.ok)
		T.eq(t.sent[1], "DATA\r\n")
		-- second sent should contain the message and terminator
		T.ok(t.sent[2]:find("%.\r\n$") ~= nil)
	end)

	T.it("returns error if server rejects DATA", function()
		local t = make_transport({"554 Transaction failed"})
		local session = smtp.session(t)
		local result = session:data("message")
		T.ok(not result.ok)
	end)

	T.it("dot-stuffs lines starting with dot", function()
		local t = make_transport({
			"354 Start mail input",
			"250 OK",
		})
		local session = smtp.session(t)
		session:data("From: a@b.com\r\n\r\n.dotline\r\n")
		-- the sent message body should have ".." for the dot-stuffed line
		T.ok(t.sent[2]:find("\r\n..", 1, true) ~= nil)
	end)
end)

T.describe("session:quit", function()
	T.it("sends QUIT command", function()
		local t = make_transport({"221 Bye"})
		local session = smtp.session(t)
		session:quit()
		T.eq(t.sent[1], "QUIT\r\n")
	end)
end)

-- ---------------------------------------------------------------------------
-- Session: auth_plain / auth_login
-- ---------------------------------------------------------------------------

T.describe("session:auth_plain", function()
	T.it("sends AUTH PLAIN with base64 credentials and returns ok on 235", function()
		local t = make_transport({"235 Authentication successful"})
		local session = smtp.session(t)
		local result = session:auth_plain("user@example.com", "secret")
		T.ok(result.ok)
		T.ok(t.sent[1]:find("^AUTH PLAIN "))
	end)

	T.it("returns error on 535", function()
		local t = make_transport({"535 Authentication failed"})
		local session = smtp.session(t)
		local result = session:auth_plain("user", "wrongpass")
		T.ok(not result.ok)
		T.ok(result.err ~= nil)
	end)
end)

T.describe("session:auth_login", function()
	T.it("two-step challenge/response returns ok on success", function()
		local t = make_transport({
			"334 VXNlcm5hbWU6",  -- "Username:" in base64
			"334 UGFzc3dvcmQ6",  -- "Password:" in base64
			"235 Authentication successful",
		})
		local session = smtp.session(t)
		local result = session:auth_login("user", "pass")
		T.ok(result.ok)
		T.eq(t.sent[1], "AUTH LOGIN\r\n")
		-- second sent is base64(user)
		T.eq(t.sent[2], smtp.base64_encode("user") .. "\r\n")
		-- third sent is base64(pass)
		T.eq(t.sent[3], smtp.base64_encode("pass") .. "\r\n")
	end)

	T.it("returns error if initial response is not 334", function()
		local t = make_transport({"500 Not supported"})
		local session = smtp.session(t)
		local result = session:auth_login("user", "pass")
		T.ok(not result.ok)
	end)
end)

-- ---------------------------------------------------------------------------
-- smtp.send: full conversation with mock transport
-- ---------------------------------------------------------------------------

T.describe("smtp.send", function()
	T.it("full conversation: ehlo, mail_from, rcpt_to, data, quit", function()
		local t = make_transport({
			-- EHLO response
			"250-smtp.example.com Hello",
			"250 PIPELINING",
			-- MAIL FROM
			"250 OK",
			-- RCPT TO
			"250 OK",
			-- DATA
			"354 Start mail input",
			"250 OK: queued",
			-- QUIT
			"221 Bye",
		})
		local msg = {
			from = "sender@example.com",
			to = {"recipient@example.com"},
			subject = "Test",
			body = "Hello world\r\n",
		}
		local ok, err = smtp.send(t, msg, {ehlo_host = "myhost"})
		T.ok(ok == true, "send should succeed, got err: " .. tostring(err))
		T.eq(t.sent[1], "EHLO myhost\r\n")
		T.eq(t.sent[2], "MAIL FROM:<sender@example.com>\r\n")
		T.eq(t.sent[3], "RCPT TO:<recipient@example.com>\r\n")
		T.eq(t.sent[4], "DATA\r\n")
		-- sent[5] is the message body + terminator
		T.ok(t.sent[5]:find("%.\r\n$") ~= nil)
		T.eq(t.sent[6], "QUIT\r\n")
	end)

	T.it("with AUTH PLAIN", function()
		local t = make_transport({
			"250-smtp.example.com Hello",
			"250 AUTH PLAIN",
			"235 OK",
			"250 OK",
			"250 OK",
			"354 Start mail input",
			"250 OK",
			"221 Bye",
		})
		local msg = {
			from = "u@example.com",
			to = {"r@example.com"},
			subject = "Auth test",
			body = "hi",
		}
		local ok, err = smtp.send(t, msg, {
			ehlo_host = "localhost",
			auth = {user = "u@example.com", password = "secret", method = "plain"},
		})
		T.ok(ok == true, "auth send should succeed, got err: " .. tostring(err))
		T.ok(t.sent[2]:find("^AUTH PLAIN "))
	end)

	T.it("returns error when server rejects MAIL FROM", function()
		local t = make_transport({
			"250-mx.example.com",
			"250 OK",
			"550 Rejected",
		})
		local msg = {
			from = "bad@example.com",
			to = {"r@example.com"},
			subject = "X",
			body = "x",
		}
		local ok, err = smtp.send(t, msg)
		T.eq(ok, nil)
		T.ok(err ~= nil)
	end)

	T.it("sends to multiple recipients (to + cc + bcc)", function()
		local t = make_transport({
			"250 smtp.example.com",
			"250 OK",  -- MAIL FROM
			"250 OK",  -- RCPT TO (to)
			"250 OK",  -- RCPT TO (cc)
			"250 OK",  -- RCPT TO (bcc)
			"354 Start mail input",
			"250 OK",
			"221 Bye",
		})
		local msg = {
			from = "a@b.com",
			to = {"to@b.com"},
			cc = {"cc@b.com"},
			bcc = {"bcc@b.com"},
			subject = "Multi rcpt",
			body = "body",
		}
		local ok, err = smtp.send(t, msg)
		T.ok(ok == true, tostring(err))
		T.eq(t.sent[3], "RCPT TO:<to@b.com>\r\n")
		T.eq(t.sent[4], "RCPT TO:<cc@b.com>\r\n")
		T.eq(t.sent[5], "RCPT TO:<bcc@b.com>\r\n")
	end)
end)

-- ---------------------------------------------------------------------------
-- base64 encode/decode
-- ---------------------------------------------------------------------------

T.describe("base64", function()
	T.it("encode empty string", function()
		T.eq(smtp.base64_encode(""), "")
	end)

	T.it("encode 'Man'", function()
		T.eq(smtp.base64_encode("Man"), "TWFu")
	end)

	T.it("encode 'Ma'", function()
		T.eq(smtp.base64_encode("Ma"), "TWE=")
	end)

	T.it("encode 'M'", function()
		T.eq(smtp.base64_encode("M"), "TQ==")
	end)

	T.it("encode null-prefixed auth string", function()
		-- \0user\0pass
		local s = "\0user\0pass"
		local encoded = smtp.base64_encode(s)
		T.ok(#encoded > 0)
		T.eq(smtp.base64_decode(encoded), s)
	end)

	T.it("round-trip various strings", function()
		local cases = {"hello", "hello world", "abc123!@#", "longer test string with spaces"}
		for _, c in ipairs(cases) do
			T.eq(smtp.base64_decode(smtp.base64_encode(c)), c)
		end
	end)
end)
