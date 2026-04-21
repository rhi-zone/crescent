-- lib/platform/service/service_test.lua
-- Tests for the service layer (HTTP and CLI projections).

if package and not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local json = require("lib.format.json")
local http = require("lib.platform.service.http")
local cli  = require("lib.platform.service.cli")
local svc  = require("lib.platform.service")

-- ── Shared fixture ─────────────────────────────────────────────────────────

local caps = { db = "mock" }

-- Simple in-memory methods for testing.
local sessions = { "s1", "s2" }
local cards = { name = "Alice", role = "admin" }

local methods = {
	chat = function(c, session_id, content)
		return { ok = true, session_id = session_id, echo = content }
	end,
	list_sessions = function(c)
		return sessions
	end,
	get_card = function(c, field)
		return cards[field]
	end,
	set_card = function(c, field, value)
		cards[field] = value
		return { ok = true }
	end,
	delete_session = function(c, session_id)
		return { deleted = session_id }
	end,
}

local descriptors = {
	chat = { method = "POST", path = "/api/message", help = "Send a message" },
	get_card = { help = "Get a card field" },
}

-- ── HTTP helpers ───────────────────────────────────────────────────────────

local function make_req(method, path, body, query)
	return { method = method, path = path, body = body, query = query, headers = {} }
end

local function make_res()
	return { status = 200, headers = {}, body = nil }
end

local function call_handler(handler, method, path, body, query)
	local req = make_req(method, path, body, query)
	local res = make_res()
	handler(req, res)
	return res
end

local function decode_body(res)
	return json.decode(res.body)
end

-- ── Naming convention tests ────────────────────────────────────────────────

T.describe("http._infer_http_method", function()
	T.it("maps get_* to GET", function()
		T.eq(http._infer_http_method("get_card"), "GET")
		T.eq(http._infer_http_method("list_sessions"), "GET")
		T.eq(http._infer_http_method("fetch_data"), "GET")
		T.eq(http._infer_http_method("find_user"), "GET")
		T.eq(http._infer_http_method("search_items"), "GET")
		T.eq(http._infer_http_method("read_file"), "GET")
	end)
	T.it("maps create_*/add_* to POST", function()
		T.eq(http._infer_http_method("create_user"), "POST")
		T.eq(http._infer_http_method("add_item"), "POST")
		T.eq(http._infer_http_method("new_session"), "POST")
	end)
	T.it("maps update_*/set_*/edit_* to PATCH", function()
		T.eq(http._infer_http_method("update_user"), "PATCH")
		T.eq(http._infer_http_method("set_card"), "PATCH")
		T.eq(http._infer_http_method("edit_name"), "PATCH")
	end)
	T.it("maps delete_*/remove_* to DELETE", function()
		T.eq(http._infer_http_method("delete_session"), "DELETE")
		T.eq(http._infer_http_method("remove_entry"), "DELETE")
	end)
	T.it("falls back to POST for unknown prefix", function()
		T.eq(http._infer_http_method("chat"), "POST")
		T.eq(http._infer_http_method("run_job"), "POST")
	end)
end)

T.describe("http._strip_verb", function()
	T.it("strips verb prefix", function()
		T.eq(http._strip_verb("get_card"), "card")
		T.eq(http._strip_verb("list_sessions"), "sessions")
		T.eq(http._strip_verb("delete_session"), "session")
		T.eq(http._strip_verb("set_card"), "card")
		T.eq(http._strip_verb("chat"), "chat")
	end)
end)

T.describe("http._match_path", function()
	T.it("matches exact paths", function()
		local caps = http._match_path("/sessions", "/sessions")
		T.ok(caps ~= nil)
	end)
	T.it("captures path parameters", function()
		local caps = http._match_path("/session/:session_id", "/session/abc123")
		T.ok(caps ~= nil)
		T.eq(caps.session_id, "abc123")
	end)
	T.it("fails on mismatched paths", function()
		T.eq(http._match_path("/sessions", "/other"), nil)
	end)
	T.it("captures multiple path parameters", function()
		local caps = http._match_path("/a/:a_id/b/:b_id", "/a/1/b/2")
		T.ok(caps ~= nil)
		T.eq(caps.a_id, "1")
		T.eq(caps.b_id, "2")
	end)
end)

T.describe("http._infer_path", function()
	T.it("infers collection path for list_*", function()
		local pat, id = http._infer_path("list_sessions", "GET", {})
		T.eq(pat, "/sessions")
		T.eq(#id, 0)
	end)
	T.it("embeds _id params as path segments", function()
		local pat, id = http._infer_path("delete_session", "DELETE", { "session_id" })
		T.ok(pat:find(":session_id") ~= nil)
		T.eq(id[1], "session_id")
	end)
	T.it("does not embed non-id params in path", function()
		local pat, id = http._infer_path("get_card", "GET", { "field" })
		T.ok(pat:find(":field") == nil)
		T.eq(#id, 0)
	end)
end)

-- ── HTTP projection tests ──────────────────────────────────────────────────

T.describe("http.create — descriptor overrides", function()
	local srv = http.create(caps, methods, descriptors)

	T.it("routes descriptor path POST /api/message → chat", function()
		local res = call_handler(srv.handler, "POST", "/api/message",
			json.encode({ session_id = "s1", content = "hello" }))
		T.eq(res.status, 200)
		local body = decode_body(res)
		T.ok(body ~= nil)
		T.eq(body.ok, true)
		T.eq(body.echo, "hello")
	end)
end)

T.describe("http.create — convention routing", function()
	local srv = http.create(caps, methods, descriptors)

	T.it("GET /sessions → list_sessions", function()
		local res = call_handler(srv.handler, "GET", "/sessions")
		T.eq(res.status, 200)
		local body = decode_body(res)
		T.ok(type(body) == "table")
	end)

	T.it("DELETE /session/:session_id → delete_session", function()
		local res = call_handler(srv.handler, "DELETE", "/session/s1")
		T.eq(res.status, 200)
		local body = decode_body(res)
		T.eq(body.deleted, "s1")
	end)

	T.it("PATCH /card → set_card with JSON body", function()
		-- set_card(caps, field, value)
		local res = call_handler(srv.handler, "PATCH", "/card",
			json.encode({ field = "role", value = "user" }))
		T.eq(res.status, 200)
		local body = decode_body(res)
		T.eq(body.ok, true)
	end)

	T.it("GET /card → get_card with query param", function()
		local res = call_handler(srv.handler, "GET", "/card", nil, "field=name")
		T.eq(res.status, 200)
		-- get_card returns a string (the field value)
		local body = decode_body(res)
		T.ok(body ~= nil)
	end)

	T.it("returns nil for unknown route (composition-friendly)", function()
		local req = make_req("GET", "/does-not-exist")
		local res = make_res()
		local handled = srv.handler(req, res)
		T.eq(handled, nil)
	end)
end)

T.describe("http.create — error handling", function()
	local err_methods = {
		get_thing = function(c, thing_id)
			return nil, "not found"
		end,
		crash = function(c)
			error("unexpected boom")
		end,
	}
	local srv = http.create(caps, err_methods, {})

	T.it("(nil, errmsg) → 400 with error body", function()
		local res = call_handler(srv.handler, "GET", "/thing/x")
		T.eq(res.status, 400)
		local body = decode_body(res)
		T.ok(body.error ~= nil)
	end)

	T.it("exception → 500 with error body", function()
		local res = call_handler(srv.handler, "POST", "/crash")
		T.eq(res.status, 500)
		local body = decode_body(res)
		T.ok(body.error ~= nil)
	end)
end)

-- ── CLI naming convention tests ────────────────────────────────────────────

T.describe("cli._subcommand_name", function()
	T.it("converts underscores to hyphens", function()
		T.eq(cli._subcommand_name("list_sessions"), "list-sessions")
		T.eq(cli._subcommand_name("get_card"), "get-card")
		T.eq(cli._subcommand_name("chat"), "chat")
		T.eq(cli._subcommand_name("delete_session"), "delete-session")
	end)
end)

-- ── CLI projection tests ───────────────────────────────────────────────────

-- Helper: capture CLI output into a string.
local function capture_cli(srv, args)
	local out_lines = {}
	local err_lines = {}
	local mock_out = {
		write = function(self, s) out_lines[#out_lines + 1] = s end,
	}
	local mock_err = {
		write = function(self, s) err_lines[#err_lines + 1] = s end,
	}
	srv.cli(args, { stdout = mock_out, stderr = mock_err })
	return table.concat(out_lines), table.concat(err_lines)
end

T.describe("cli.create — subcommand dispatch", function()
	local srv = cli.create(caps, methods, descriptors)

	T.it("dispatches list-sessions", function()
		local out, err = capture_cli(srv, { "list-sessions" })
		-- Should print "s1" and "s2"
		T.ok(out:find("s1") ~= nil, "output should contain s1")
		T.ok(out:find("s2") ~= nil, "output should contain s2")
		T.eq(err, "")
	end)

	T.it("dispatches chat with positional args", function()
		local out, err = capture_cli(srv, { "chat", "sess42", "hello world" })
		-- chat returns a table; pretty_print will render it
		T.ok(out ~= nil)
		T.eq(err, "")
	end)

	T.it("dispatches delete-session with session_id arg", function()
		local out, err = capture_cli(srv, { "delete-session", "s1" })
		T.ok(out:find("s1") ~= nil)
		T.eq(err, "")
	end)

	T.it("--json flag outputs valid JSON", function()
		local out, err = capture_cli(srv, { "list-sessions", "--json" })
		local decoded = json.decode(out:match("[^\n]+"))
		T.ok(decoded ~= nil)
		T.eq(err, "")
	end)

	T.it("--help prints subcommand list", function()
		local out, err = capture_cli(srv, { "--help" })
		T.ok(out:find("subcommands") ~= nil)
	end)

	T.it("--help on subcommand prints usage", function()
		local out, err = capture_cli(srv, { "get-card", "--help" })
		T.ok(out:find("usage") ~= nil)
	end)

	T.it("unknown subcommand writes error to stderr", function()
		local out, err = capture_cli(srv, { "does-not-exist" })
		T.ok(err:find("unknown subcommand") ~= nil)
	end)
end)

T.describe("cli._pretty_print — nested tables", function()
	local function capture_pretty(value)
		local lines = {}
		local mock = { write = function(self, s) lines[#lines + 1] = s end }
		cli._pretty_print(value, mock)
		return table.concat(lines)
	end

	T.it("map with array value serializes inline", function()
		local out = capture_pretty({ providers = { "github", "gitlab" } })
		T.ok(out:find("providers=") ~= nil, "output should have providers key")
		T.ok(out:find("github") ~= nil, "output should contain github")
		T.ok(out:find("gitlab") ~= nil, "output should contain gitlab")
		T.ok(not out:find("table: "), "output should not contain raw table address")
	end)

	T.it("array of maps serializes each row inline", function()
		local out = capture_pretty({ { name = "Alice" }, { name = "Bob" } })
		T.ok(out:find("Alice") ~= nil)
		T.ok(out:find("Bob") ~= nil)
		T.ok(not out:find("table: "), "output should not contain raw table address")
	end)

	T.it("map with nested map serializes inline", function()
		local out = capture_pretty({ meta = { version = "1" } })
		T.ok(out:find("meta=") ~= nil)
		T.ok(out:find("version") ~= nil)
		T.ok(not out:find("table: "), "output should not contain raw table address")
	end)

	T.it("serialize_value: array -> bracket notation", function()
		T.eq(cli._serialize_value({ "a", "b" }), "[a, b]")
	end)

	T.it("serialize_value: nested map", function()
		-- key order is not deterministic, so just check no raw address
		local s = cli._serialize_value({ x = 1 })
		T.ok(s:find("x=1") ~= nil)
		T.ok(not s:find("table: "))
	end)
end)

T.describe("cli.create — error handling", function()
	local err_methods = {
		get_thing = function(c, thing_id)
			return nil, "thing not found"
		end,
		crash = function(c)
			error("boom")
		end,
	}
	local srv = cli.create(caps, err_methods, {})

	T.it("(nil, errmsg) writes error to stderr", function()
		local out, err = capture_cli(srv, { "get-thing", "x" })
		T.ok(err:find("thing not found") ~= nil)
	end)

	T.it("exception writes error to stderr", function()
		local out, err = capture_cli(srv, { "crash" })
		T.ok(err:find("boom") ~= nil)
	end)
end)

-- ── Combined create ────────────────────────────────────────────────────────

T.describe("service.create", function()
	T.it("returns both handler and cli", function()
		local s = svc.create(caps, methods, descriptors)
		T.ok(type(s.handler) == "function")
		T.ok(type(s.cli) == "function")
	end)

	T.it("handler works after combined create", function()
		local s = svc.create(caps, methods, descriptors)
		local res = call_handler(s.handler, "GET", "/sessions")
		T.eq(res.status, 200)
	end)

	T.it("cli works after combined create", function()
		local s = svc.create(caps, methods, descriptors)
		local out, err = capture_cli(s, { "list-sessions" })
		T.ok(out:find("s1") ~= nil)
	end)
end)
