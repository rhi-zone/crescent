-- lib/platform/apps/terminal_mux/terminal_mux_test.lua
-- Tests for the terminal multiplexer wire protocol and session logic.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local vt = require("lib.vt")

local describe, it = T.describe, T.it
local eq, ok = T.eq, T.ok

-- ── Inline copies of protocol helpers ─────────────────────────────────────────
-- These mirror the implementations in server.lua. The server runs in a sandbox
-- so we cannot require it directly; instead we duplicate the pure functions
-- and verify their behaviour here.

local byte = string.byte
local format = string.format

--: (string) -> string
local function json_escape(s)
	--: string
	local result = s:gsub('[%z\1-\31\\"]', function(c)
		--: string
		local ch = c
		if ch == '"' then return '\\"'
		elseif ch == '\\' then return '\\\\'
		elseif ch == '\n' then return '\\n'
		elseif ch == '\r' then return '\\r'
		elseif ch == '\t' then return '\\t'
		else return format('\\u%04x', byte(ch)) end
	end)
	return result
end

-- Encode specific control message types — mirrors server.lua's split encoders.
--: ({ type: "session", id: string, rows: integer, cols: integer }) -> string
local function encode_session(m)
	return '{"type":"session","id":"' .. json_escape(m.id) .. '"'
		.. ',"rows":' .. format("%d", m.rows)
		.. ',"cols":' .. format("%d", m.cols) .. '}'
end

--: ({ type: "snapshot", data: string }) -> string
local function encode_snapshot(m)
	return '{"type":"snapshot","data":"' .. json_escape(m.data) .. '"}'
end

--: ({ type: "error", message: string }) -> string
local function encode_error(m)
	return '{"type":"error","message":"' .. json_escape(m.message) .. '"}'
end

--: () -> string
local function encode_closed()
	return '{"type":"closed"}'
end


--:: TestCtrlResize = { type: "resize", rows: integer, cols: integer }
--:: TestCtrlAttach = { type: "attach", session: string }
--:: TestCtrlMsg = TestCtrlResize | TestCtrlAttach

--: (string) -> (TestCtrlMsg | nil, string | nil)
local function decode_control(s)
	local msg_type = s:match('"type"%s*:%s*"([^"]+)"')
	if not msg_type then return nil, "missing type field" end
	if msg_type == "resize" then
		local rows_n = tonumber(s:match('"rows"%s*:%s*(%d+)'))
		local cols_n = tonumber(s:match('"cols"%s*:%s*(%d+)'))
		if not rows_n or not cols_n then return nil, "resize: missing rows/cols" end
		--: TestCtrlResize
		local result = { type = "resize", rows = math.floor(rows_n), cols = math.floor(cols_n) }
		return result
	elseif msg_type == "attach" then
		local session_id = s:match('"session"%s*:%s*"([^"]*)"')
		if not session_id then return nil, "attach: missing session" end
		--: TestCtrlAttach
		local result = { type = "attach", session = session_id }
		return result
	end
	return nil, "unknown control type: " .. msg_type
end

--: (string | nil, string) -> string | nil
local function query_param(qs, key)
	if not qs then return nil end
	local pattern = "[?&]?" .. key .. "=([^&]*)"
	return qs:match(pattern)
end

-- ═══════════════════════════════════════════════════════════════════════════════

describe("encode_session", function()
	it("encodes session message", function()
		local json = encode_session({ type = "session", id = "42", rows = 24, cols = 80 })
		eq(json, '{"type":"session","id":"42","rows":24,"cols":80}')
	end)

	it("escapes special characters in id", function()
		local json = encode_session({ type = "session", id = 'a"b\\c', rows = 1, cols = 1 })
		eq(json, '{"type":"session","id":"a\\"b\\\\c","rows":1,"cols":1}')
	end)
end)

describe("encode_snapshot", function()
	it("encodes snapshot with ANSI escapes", function()
		local data = "\27[0m\27[1;1Hhello"
		local json = encode_snapshot({ type = "snapshot", data = data })
		eq(json, '{"type":"snapshot","data":"\\u001b[0m\\u001b[1;1Hhello"}')
	end)
end)

describe("encode_error", function()
	it("encodes error message", function()
		local json = encode_error({ type = "error", message = "session not found" })
		eq(json, '{"type":"error","message":"session not found"}')
	end)
end)

describe("encode_closed", function()
	it("encodes closed message", function()
		local json = encode_closed()
		eq(json, '{"type":"closed"}')
	end)
end)

describe("decode_control", function()
	it("decodes resize", function()
		local msg = decode_control('{"type":"resize","rows":30,"cols":120}')
		eq(msg.type, "resize")
		eq(msg.rows, 30)
		eq(msg.cols, 120)
	end)

	it("decodes attach", function()
		local msg = decode_control('{"type":"attach","session":"42"}')
		eq(msg.type, "attach")
		eq(msg.session, "42")
	end)

	it("returns nil for missing type", function()
		local msg, err = decode_control('{"rows":30}')
		eq(msg, nil)
		ok(err and err:find("missing type"), "expected missing type error")
	end)

	it("returns nil for resize missing cols", function()
		local msg, err = decode_control('{"type":"resize","rows":30}')
		eq(msg, nil)
		ok(err and err:find("rows/cols"), "expected rows/cols error")
	end)

	it("returns nil for unknown type", function()
		local msg, err = decode_control('{"type":"ping"}')
		eq(msg, nil)
		ok(err and err:find("unknown"), "expected unknown type error")
	end)

	it("returns nil for attach missing session", function()
		local msg, err = decode_control('{"type":"attach"}')
		eq(msg, nil)
		ok(err and err:find("session"), "expected missing session error")
	end)
end)

describe("query_param", function()
	it("extracts single param", function()
		eq(query_param("session=42", "session"), "42")
	end)

	it("extracts from multiple params", function()
		eq(query_param("foo=1&session=42&bar=3", "session"), "42")
	end)

	it("returns nil for missing param", function()
		eq(query_param("foo=1", "session"), nil)
	end)

	it("returns nil for nil query string", function()
		eq(query_param(nil, "session"), nil)
	end)

	it("handles leading question mark", function()
		eq(query_param("?session=42", "session"), "42")
	end)
end)

describe("json_escape", function()
	it("escapes control characters", function()
		eq(json_escape("\0\1\2\x1b"), "\\u0000\\u0001\\u0002\\u001b")
	end)

	it("escapes quotes and backslashes", function()
		eq(json_escape('he said "hello\\world"'), 'he said \\"hello\\\\world\\"')
	end)

	it("escapes newlines and tabs", function()
		eq(json_escape("line1\nline2\tindented\r"), "line1\\nline2\\tindented\\r")
	end)

	it("leaves plain ASCII unchanged", function()
		eq(json_escape("hello world 123"), "hello world 123")
	end)
end)

describe("wire protocol type bytes", function()
	it("0x00 is data prefix", function()
		local frame = "\0hello"
		eq(string.byte(frame, 1), 0x00)
		eq(frame:sub(2), "hello")
	end)

	it("0x01 is control prefix", function()
		local json = '{"type":"resize","rows":24,"cols":80}'
		local frame = "\1" .. json
		eq(string.byte(frame, 1), 0x01)
		local ctrl = decode_control(frame:sub(2))
		eq(ctrl.type, "resize")
		eq(ctrl.rows, 24)
		eq(ctrl.cols, 80)
	end)
end)

describe("VT snapshot integration", function()
	it("produces non-empty snapshot that encodes without error", function()
		local term = vt.new(40, 5)
		term:feed("hello world")
		local snapshot = term:snapshot()
		ok(type(snapshot) == "string" and #snapshot > 0, "snapshot is non-empty string")
		local json = encode_snapshot({ type = "snapshot", data = snapshot })
		ok(json:find('"type":"snapshot"', 1, true), "contains type field")
	end)

	it("snapshot preserves cursor position", function()
		local term = vt.new(80, 24)
		term:feed("line1\r\nline2\r\n")
		local row, col = term:cursor()
		eq(row, 3)
		eq(col, 1)
		local snapshot = term:snapshot()
		ok(snapshot:find("\27[3;1H", 1, true), "snapshot contains cursor position")
	end)

	it("resize updates dimensions", function()
		local term = vt.new(80, 24)
		term:resize(40, 120)
		local rows, cols = term:size()
		eq(rows, 40)
		eq(cols, 120)
	end)
end)

describe("mock session lifecycle", function()
	it("PTY reader feeds VT and marks dead on eof", function()
		local read_queue = { "hello", "world" }
		local read_idx = 0
		local mock_pty = {
			pid = 123,
			--: () -> (string | nil, string | nil)
			read = function()
				read_idx = read_idx + 1
				if read_queue[read_idx] then return read_queue[read_idx] end
				return nil, "eof"
			end,
			--: (string) -> integer
			write = function(data) return #data end,
			--: () -> true
			resize = function() return true end,
			--: () -> true
			close = function() return true end,
		}

		local vt_term = vt.new(80, 24)
		local session = { dead = false }

		-- Simulate the reader task synchronously.
		while true do
			local data, _ = mock_pty.read()
			if not data then
				session.dead = true
				break
			end
			vt_term:feed(data)
		end

		local c1 = vt_term:cell(1, 1)
		eq(c1.char, "h")
		local c5 = vt_term:cell(1, 5)
		eq(c5.char, "o")
		local c6 = vt_term:cell(1, 6)
		eq(c6.char, "w")
		eq(session.dead, true)
	end)

	it("data message forwards keystrokes to PTY", function()
		local written = {}
		local mock_pty = {
			--: (string) -> integer
			write = function(data) written[#written + 1] = data; return #data end,
		}

		local payload = "\0ls -la\r"
		if string.byte(payload, 1) == 0x00 then
			local input = payload:sub(2)
			if #input > 0 then mock_pty.write(input) end
		end

		eq(#written, 1)
		eq(written[1], "ls -la\r")
	end)

	it("resize control updates PTY and VT", function()
		local resized = {}
		local mock_pty = {
			--: (integer, integer) -> true
			resize = function(r, c)
				resized.rows = r
				resized.cols = c
				return true
			end,
		}

		local vt_term = vt.new(80, 24)
		local session = {
			pty = mock_pty,
			vt_term = vt_term,
			rows = 24,
			cols = 80,
			dead = false,
		}

		local ctrl = decode_control('{"type":"resize","rows":40,"cols":120}')
		if ctrl and ctrl.type == "resize" then
			local new_rows = ctrl.rows
			local new_cols = ctrl.cols
			if new_rows > 0 and new_cols > 0 and not session.dead then
				session.rows = new_rows
				session.cols = new_cols
				session.pty.resize(new_rows, new_cols)
				session.vt_term:resize(new_rows, new_cols)
			end
		end

		eq(resized.rows, 40)
		eq(resized.cols, 120)
		local rows, cols = vt_term:size()
		eq(rows, 40)
		eq(cols, 120)
		eq(session.rows, 40)
		eq(session.cols, 120)
	end)
end)
