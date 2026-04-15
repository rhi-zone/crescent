if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local email = require("lib.email")
local base64 = require("lib.encode.base64")
local T = require("lib.test.assert")

T.describe("email.message composition", function()
	T.it("simple text message has valid headers", function()
		local msg = email.message({ time_fn = os.time,
			from = "alice@example.com",
			to = {"bob@example.com"},
			subject = "Hello",
			text = "Plain text body",
		})
		local raw = msg:to_string()
		T.ok(raw ~= nil)
		T.ok(raw:find("From: alice@example.com", 1, true) ~= nil)
		T.ok(raw:find("To: bob@example.com", 1, true) ~= nil)
		T.ok(raw:find("Subject: Hello", 1, true) ~= nil)
		T.ok(raw:find("text/plain", 1, true) ~= nil)
	end)

	T.it("has Date, From, To, Subject, MIME-Version headers", function()
		local msg = email.message({ time_fn = os.time,
			from = "alice@example.com",
			to = {"bob@example.com"},
			subject = "Test",
			text = "body",
		})
		local raw = msg:to_string()
		T.ok(raw:find("Date: ", 1, true) ~= nil)
		T.ok(raw:find("From: ", 1, true) ~= nil)
		T.ok(raw:find("To: ", 1, true) ~= nil)
		T.ok(raw:find("Subject: ", 1, true) ~= nil)
		T.ok(raw:find("MIME%-Version: 1%.0") ~= nil)
	end)

	T.it("Message-ID is generated and unique", function()
		local msg1 = email.message({ time_fn = os.time, from = "a@b.com", to = {"c@d.com"}, subject = "1", text = "x" })
		local msg2 = email.message({ time_fn = os.time, from = "a@b.com", to = {"c@d.com"}, subject = "2", text = "y" })
		local raw1 = msg1:to_string()
		local raw2 = msg2:to_string()
		local id1 = raw1:match("Message%-ID: (<[^>]+>)")
		local id2 = raw2:match("Message%-ID: (<[^>]+>)")
		T.ok(id1 ~= nil)
		T.ok(id2 ~= nil)
		T.ok(id1 ~= id2)
	end)

	T.it("HTML message has text/html content type", function()
		local msg = email.message({ time_fn = os.time,
			from = "a@b.com",
			to = {"c@d.com"},
			subject = "HTML",
			html = "<h1>Hello</h1>",
		})
		local raw = msg:to_string()
		T.ok(raw:find("text/html", 1, true) ~= nil)
	end)

	T.it("text + html produces multipart/alternative", function()
		local msg = email.message({ time_fn = os.time,
			from = "a@b.com",
			to = {"c@d.com"},
			subject = "Both",
			text = "Plain",
			html = "<p>Rich</p>",
		})
		local raw = msg:to_string()
		T.ok(raw:find("multipart/alternative", 1, true) ~= nil)
		T.ok(raw:find("text/plain", 1, true) ~= nil)
		T.ok(raw:find("text/html", 1, true) ~= nil)
	end)

	T.it("attachment produces multipart/mixed with base64", function()
		local msg = email.message({ time_fn = os.time,
			from = "a@b.com",
			to = {"c@d.com"},
			subject = "Att",
			text = "See attached",
		})
		msg:attach({
			filename = "report.pdf",
			content_type = "application/pdf",
			data = "fake pdf content",
		})
		local raw = msg:to_string()
		T.ok(raw:find("multipart/mixed", 1, true) ~= nil)
		T.ok(raw:find("application/pdf", 1, true) ~= nil)
		T.ok(raw:find('filename="report.pdf"', 1, true) ~= nil)
		T.ok(raw:find("Content%-Transfer%-Encoding: base64") ~= nil)
		-- Verify base64 content is present
		T.ok(raw:find(base64.encode("fake pdf content"), 1, true) ~= nil)
	end)

	T.it("inline attachment with Content-ID", function()
		local msg = email.message({ time_fn = os.time,
			from = "a@b.com",
			to = {"c@d.com"},
			subject = "Inline",
			html = '<img src="cid:img1">',
		})
		msg:attach({
			filename = "image.png",
			content_type = "image/png",
			data = "fake png data",
			inline = true,
			cid = "img1",
		})
		local raw = msg:to_string()
		T.ok(raw:find("multipart/related", 1, true) ~= nil)
		T.ok(raw:find("Content%-ID: <img1>") ~= nil)
		T.ok(raw:find("Content%-Disposition: inline") ~= nil)
	end)

	T.it("multiple recipients in To and Cc", function()
		local msg = email.message({ time_fn = os.time,
			from = "a@b.com",
			to = {"bob@b.com", "carol@c.com"},
			cc = {"dave@d.com", "eve@e.com"},
			subject = "Multi",
			text = "hi all",
		})
		local raw = msg:to_string()
		T.ok(raw:find("To: bob@b.com, carol@c.com", 1, true) ~= nil)
		T.ok(raw:find("Cc: dave@d.com, eve@e.com", 1, true) ~= nil)
	end)

	T.it("subject with non-ASCII uses encoded-word", function()
		local msg = email.message({ time_fn = os.time,
			from = "a@b.com",
			to = {"c@d.com"},
			subject = "Héllo Wörld",
			text = "body",
		})
		local raw = msg:to_string()
		T.ok(raw:find("=?UTF%-8?B?", 1, false) ~= nil)
		-- Should not contain raw non-ASCII in Subject line
		local subject_line = raw:match("Subject: ([^\r\n]+)")
		T.ok(subject_line:find("=?UTF%-8?B?") ~= nil)
	end)

	T.it("custom headers included", function()
		local msg = email.message({ time_fn = os.time,
			from = "a@b.com",
			to = {"c@d.com"},
			subject = "Custom",
			text = "body",
			headers = { ["X-Custom"] = "myvalue", ["X-Priority"] = "1" },
		})
		local raw = msg:to_string()
		T.ok(raw:find("X-Custom: myvalue", 1, true) ~= nil)
		T.ok(raw:find("X-Priority: 1", 1, true) ~= nil)
	end)

	T.it("Reply-To header", function()
		local msg = email.message({ time_fn = os.time,
			from = "a@b.com",
			to = {"c@d.com"},
			subject = "Reply",
			text = "body",
			reply_to = "reply@b.com",
		})
		local raw = msg:to_string()
		T.ok(raw:find("Reply-To: reply@b.com", 1, true) ~= nil)
	end)

	T.it("quoted-printable encoding", function()
		-- Test long lines and special characters
		local long = string.rep("A", 100)
		local msg = email.message({ time_fn = os.time,
			from = "a@b.com",
			to = {"c@d.com"},
			subject = "QP",
			text = long .. "\n= sign here",
		})
		local raw = msg:to_string()
		-- The = should be encoded as =3D
		T.ok(raw:find("=3D", 1, true) ~= nil)
		-- Long line should be wrapped with soft line break
		T.ok(raw:find("=\r\n", 1, true) ~= nil)
	end)

	T.it("empty body produces valid message", function()
		local msg = email.message({ time_fn = os.time,
			from = "a@b.com",
			to = {"c@d.com"},
			subject = "Empty",
		})
		local raw = msg:to_string()
		T.ok(raw ~= nil)
		T.ok(raw:find("From: a@b.com", 1, true) ~= nil)
		T.ok(raw:find("text/plain", 1, true) ~= nil)
	end)

	T.it("BCC not included in headers", function()
		local msg = email.message({ time_fn = os.time,
			from = "a@b.com",
			to = {"bob@b.com"},
			bcc = {"secret@b.com"},
			subject = "BCC test",
			text = "body",
		})
		local raw = msg:to_string()
		T.ok(raw:find("Bcc:", 1, true) == nil)
		T.ok(raw:find("bcc:", 1, true) == nil)
		T.ok(raw:find("secret@b.com", 1, true) == nil)
	end)
end)

T.describe("email.parse", function()
	T.it("round-trip: compose -> to_string -> parse recovers fields", function()
		local msg = email.message({ time_fn = os.time,
			from = "alice@example.com",
			to = {"bob@example.com"},
			subject = "Round Trip",
			text = "Hello, world!",
		})
		local raw = msg:to_string()
		local parsed, err = email.parse(raw)
		T.ok(parsed ~= nil, err)
		T.eq(parsed.from, "alice@example.com")
		T.eq(parsed.to[1], "bob@example.com")
		T.eq(parsed.subject, "Round Trip")
		T.ok(parsed.text:find("Hello, world!", 1, true) ~= nil)
	end)

	T.it("parse multipart: recovers text and html parts", function()
		local msg = email.message({ time_fn = os.time,
			from = "a@b.com",
			to = {"c@d.com"},
			subject = "Multi",
			text = "Plain version",
			html = "<p>Rich version</p>",
		})
		local raw = msg:to_string()
		local parsed, err = email.parse(raw)
		T.ok(parsed ~= nil, err)
		T.ok(parsed.text:find("Plain version", 1, true) ~= nil)
		T.ok(parsed.html:find("Rich version", 1, true) ~= nil)
	end)

	T.it("parse attachment: recovers filename and data", function()
		local msg = email.message({ time_fn = os.time,
			from = "a@b.com",
			to = {"c@d.com"},
			subject = "Att",
			text = "See attached",
		})
		msg:attach({
			filename = "test.txt",
			content_type = "text/plain",
			data = "attachment content here",
		})
		local raw = msg:to_string()
		local parsed, err = email.parse(raw)
		T.ok(parsed ~= nil, err)
		T.eq(#parsed.attachments, 1)
		T.eq(parsed.attachments[1].filename, "test.txt")
		T.eq(parsed.attachments[1].data, "attachment content here")
	end)
end)

T.describe("SMTP client", function()
	T.it("connect, ehlo, auth, send, quit — verify protocol flow", function()
		local transport = email.mock_transport({
			"220 smtp.example.com ESMTP\r\n",
			"250-smtp.example.com\r\n250-SIZE 52428800\r\n250 AUTH LOGIN PLAIN\r\n",
			"235 2.7.0 Authentication successful\r\n",
			"250 2.1.0 OK\r\n",    -- MAIL FROM
			"250 2.1.5 OK\r\n",    -- RCPT TO
			"354 Start mail input\r\n",  -- DATA
			"250 2.0.0 OK\r\n",    -- message accepted
			"221 2.0.0 Bye\r\n",   -- QUIT
		})
		local smtp, err = email.smtp_connect({ host = "smtp.example.com", port = 587, transport = transport })
		T.ok(smtp ~= nil, err)

		local ok
		ok, err = smtp:ehlo("mydomain.com")
		T.ok(ok, err)

		ok, err = smtp:auth("PLAIN", "user", "pass")
		T.ok(ok, err)

		local msg = email.message({ time_fn = os.time,
			from = "user@example.com",
			to = {"dest@example.com"},
			subject = "Test",
			text = "Hello",
		})
		ok, err = smtp:send(msg)
		T.ok(ok, err)

		ok, err = smtp:quit()
		T.ok(ok, err)

		-- Verify EHLO was sent
		T.ok(transport.sent[1]:find("EHLO mydomain.com", 1, true) ~= nil)
	end)

	T.it("AUTH LOGIN sends base64 username and password", function()
		local transport = email.mock_transport({
			"220 ready\r\n",
			"250 OK\r\n",         -- EHLO
			"334 VXNlcm5hbWU6\r\n",  -- AUTH LOGIN -> "Username:"
			"334 UGFzc3dvcmQ6\r\n",  -- username -> "Password:"
			"235 OK\r\n",            -- password -> success
		})
		local smtp = email.smtp_connect({ host = "h", port = 25, transport = transport })
		smtp:ehlo("test")
		local ok, err = smtp:auth("LOGIN", "myuser", "mypass")
		T.ok(ok, err)

		-- sent[1]=EHLO, sent[2]=AUTH LOGIN, sent[3]=base64(user), sent[4]=base64(pass)
		T.ok(transport.sent[3]:find(base64.encode("myuser"), 1, true) ~= nil)
		T.ok(transport.sent[4]:find(base64.encode("mypass"), 1, true) ~= nil)
	end)

	T.it("SMTP send: MAIL FROM, RCPT TO, DATA sequence", function()
		local transport = email.mock_transport({
			"220 ready\r\n",
			"250 OK\r\n",           -- EHLO
			"250 OK\r\n",           -- MAIL FROM
			"250 OK\r\n",           -- RCPT TO bob
			"250 OK\r\n",           -- RCPT TO carol
			"354 go ahead\r\n",     -- DATA
			"250 OK\r\n",           -- message
		})
		local smtp = email.smtp_connect({ host = "h", port = 25, transport = transport })
		smtp:ehlo("test")

		local msg = email.message({ time_fn = os.time,
			from = "alice@a.com",
			to = {"bob@b.com", "carol@c.com"},
			subject = "Test",
			text = "body",
		})
		local ok, err = smtp:send(msg)
		T.ok(ok, err)

		-- sent[1] = EHLO, sent[2] = MAIL FROM, sent[3] = RCPT TO bob, sent[4] = RCPT TO carol
		T.ok(transport.sent[2]:find("MAIL FROM:<alice@a.com>", 1, true) ~= nil)
		T.ok(transport.sent[3]:find("RCPT TO:<bob@b.com>", 1, true) ~= nil)
		T.ok(transport.sent[4]:find("RCPT TO:<carol@c.com>", 1, true) ~= nil)
		T.ok(transport.sent[5]:find("DATA", 1, true) ~= nil)
	end)

	T.it("SMTP error: rejected recipient returns nil, errmsg", function()
		local transport = email.mock_transport({
			"220 ready\r\n",
			"250 OK\r\n",           -- EHLO
			"250 OK\r\n",           -- MAIL FROM
			"550 5.1.1 User unknown\r\n",  -- RCPT TO rejected
		})
		local smtp = email.smtp_connect({ host = "h", port = 25, transport = transport })
		smtp:ehlo("test")

		local ok, err = smtp:send_raw({
			from = "a@a.com",
			to = {"unknown@b.com"},
			data = "Subject: test\r\n\r\nbody",
		})
		T.ok(ok == nil)
		T.ok(err:find("rejected", 1, true) ~= nil)
	end)

	T.it("BCC recipients used in RCPT TO but not in headers", function()
		local transport = email.mock_transport({
			"220 ready\r\n",
			"250 OK\r\n",           -- EHLO
			"250 OK\r\n",           -- MAIL FROM
			"250 OK\r\n",           -- RCPT TO bob
			"250 OK\r\n",           -- RCPT TO secret (BCC)
			"354 go ahead\r\n",     -- DATA
			"250 OK\r\n",           -- message
		})
		local smtp = email.smtp_connect({ host = "h", port = 25, transport = transport })
		smtp:ehlo("test")

		local msg = email.message({ time_fn = os.time,
			from = "alice@a.com",
			to = {"bob@b.com"},
			bcc = {"secret@s.com"},
			subject = "BCC",
			text = "body",
		})
		local ok, err = smtp:send(msg)
		T.ok(ok, err)

		-- RCPT TO should include BCC recipient
		T.ok(transport.sent[4]:find("RCPT TO:<secret@s.com>", 1, true) ~= nil)

		-- But the message data should NOT contain secret@s.com
		local data_sent = transport.sent[6] -- the actual message data
		T.ok(data_sent:find("secret@s.com", 1, true) == nil)
	end)
end)
