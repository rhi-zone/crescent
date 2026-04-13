-- lib/platform/server_test.lua
-- Tests for lib/platform/server (HTTP request handling — no networking).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local server = require("lib.platform.server")
local json   = require("lib.json")

-- ── Mock app ──────────────────────────────────────────────────────────────────

-- Build a minimal app table in-memory.
-- entries is a plain array of { name, data } tables — tar.get only reads .name/.data.
local DOM_SOURCE = [[
-- minimal dom entrypoint
local M = {}
M.title = "hello"
return M
]]

local mock_app = {
	path    = "test.tar.gz",
	chunks  = nil,
	entries = {
		{ name = "manifest.json",    data = '{"name":"test","version":"0.1.0","entry":{"dom":"dom.lua"}}' },
		{ name = "dom.lua",          data = DOM_SOURCE },
		{ name = "static/foo.txt",   data = "hello from foo" },
		{ name = "static/style.css", data = "body { color: red; }" },
	},
	manifest = {
		name    = "test",
		version = "0.1.0",
		entry   = { dom = "dom.lua" },
	},
}

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("platform.server", function()

	T.it("GET / returns HTML with script tag pointing to /app.js", function()
		local srv = server.new(mock_app, {})
		local res = srv:handle({ method = "GET", path = "/" })
		T.eq(res.status, 200)
		T.ok(res.headers["Content-Type"]:find("text/html"), "Content-Type should be text/html")
		T.ok(res.body:find('<script', 1, true), "body should contain <script")
		T.ok(res.body:find('/app.js', 1, true), "body should reference /app.js")
	end)

	T.it("GET /app.js returns JavaScript (non-empty)", function()
		local srv = server.new(mock_app, {})
		local res = srv:handle({ method = "GET", path = "/app.js" })
		T.eq(res.status, 200)
		T.ok(res.headers["Content-Type"]:find("javascript"), "Content-Type should contain javascript")
		T.ok(type(res.body) == "string" and #res.body > 0, "body should be non-empty JS")
	end)

	T.it("GET /app.js second call returns cached (identical) result", function()
		local srv = server.new(mock_app, {})
		local res1 = srv:handle({ method = "GET", path = "/app.js" })
		local res2 = srv:handle({ method = "GET", path = "/app.js" })
		T.eq(res1.status, 200)
		T.eq(res2.status, 200)
		T.eq(res1.body, res2.body, "cached result should be identical string")
	end)

	T.it("GET /static/foo.txt returns file content", function()
		local srv = server.new(mock_app, {})
		local res = srv:handle({ method = "GET", path = "/static/foo.txt" })
		T.eq(res.status, 200)
		T.eq(res.body, "hello from foo")
		T.ok(res.headers["Content-Type"]:find("text/plain"), "Content-Type should be text/plain")
	end)

	T.it("GET /static/style.css returns CSS with correct content-type", function()
		local srv = server.new(mock_app, {})
		local res = srv:handle({ method = "GET", path = "/static/style.css" })
		T.eq(res.status, 200)
		T.eq(res.body, "body { color: red; }")
		T.ok(res.headers["Content-Type"]:find("css"), "Content-Type should be text/css")
	end)

	T.it("GET /static/missing.txt returns 404", function()
		local srv = server.new(mock_app, {})
		local res = srv:handle({ method = "GET", path = "/static/missing.txt" })
		T.eq(res.status, 404)
	end)

	T.it("path traversal in /static/ is rejected with 400", function()
		local srv = server.new(mock_app, {})
		local res = srv:handle({ method = "GET", path = "/static/../manifest.json" })
		T.eq(res.status, 400)
	end)

	T.it("GET /api/anything returns 404", function()
		local srv = server.new(mock_app, {})
		local res = srv:handle({ method = "GET", path = "/api/foo" })
		T.eq(res.status, 404)
	end)

	T.it("unknown route returns 404", function()
		local srv = server.new(mock_app, {})
		local res = srv:handle({ method = "GET", path = "/unknown" })
		T.eq(res.status, 404)
	end)

	T.it("query string is stripped from path before dispatch", function()
		local srv = server.new(mock_app, {})
		local res = srv:handle({ method = "GET", path = "/?foo=bar" })
		T.eq(res.status, 200)
		T.ok(res.body:find("DOCTYPE", 1, true), "should return HTML shell")
	end)

	T.it("invalidate_cache forces re-transpile", function()
		local srv = server.new(mock_app, {})
		local res1 = srv:handle({ method = "GET", path = "/app.js" })
		srv:invalidate_cache()
		-- After invalidation, _js_cache is nil; next call re-transpiles
		T.ok(srv._js_cache == nil, "cache should be nil after invalidation")
		local res2 = srv:handle({ method = "GET", path = "/app.js" })
		T.eq(res2.status, 200)
		T.eq(res1.body, res2.body, "re-transpiled result should be identical")
	end)

end)

-- ── Mock caps for RPC tests ──────────────────────────────────────────────────

local mock_caps = {
	llm = {
		call = function(messages)
			if not messages or #messages == 0 then
				return nil, "empty messages"
			end
			return "Hello from LLM"
		end,
	},
	kv = {
		get = function(key)
			if key == "name" then return "Alice" end
			return nil
		end,
		set = function() end,
	},
}

-- ── RPC endpoint tests ───────────────────────────────────────────────────────

T.describe("platform.server POST /api/cap", function()

	T.it("dispatches a successful cap call", function()
		local srv = server.new(mock_app, mock_caps)
		local res = srv:handle({
			method = "POST",
			path = "/api/cap",
			body = json.encode({ cap = "llm", method = "call", args = { { { role = "user", content = "hi" } } } }),
		})
		T.eq(res.status, 200)
		T.ok(res.headers["Content-Type"]:find("json"), "should be JSON")
		local data = json.decode(res.body)
		T.eq(data.result, "Hello from LLM")
	end)

	T.it("returns error for nil+errmsg cap return", function()
		local srv = server.new(mock_app, mock_caps)
		local res = srv:handle({
			method = "POST",
			path = "/api/cap",
			body = json.encode({ cap = "llm", method = "call", args = { {} } }),
		})
		T.eq(res.status, 200)
		local data = json.decode(res.body)
		T.eq(data.error, "empty messages")
	end)

	T.it("returns 404 for unknown cap", function()
		local srv = server.new(mock_app, mock_caps)
		local res = srv:handle({
			method = "POST",
			path = "/api/cap",
			body = json.encode({ cap = "nosuch", method = "call" }),
		})
		T.eq(res.status, 404)
	end)

	T.it("returns 400 for invalid JSON body", function()
		local srv = server.new(mock_app, mock_caps)
		local res = srv:handle({
			method = "POST",
			path = "/api/cap",
			body = "not json",
		})
		T.eq(res.status, 400)
	end)

end)

-- ── Runtime endpoint tests ───────────────────────────────────────────────────

T.describe("platform.server GET /runtime.js", function()

	T.it("returns JavaScript with cap proxies", function()
		local srv = server.new(mock_app, mock_caps)
		local res = srv:handle({ method = "GET", path = "/runtime.js" })
		T.eq(res.status, 200)
		T.ok(res.headers["Content-Type"]:find("javascript"), "Content-Type should be JS")
		T.ok(res.body:find("export const caps", 1, true) ~= nil, "should export caps")
		T.ok(res.body:find("llm:", 1, true) ~= nil, "should include llm cap")
		T.ok(res.body:find("kv:", 1, true) ~= nil, "should include kv cap")
	end)

	T.it("caches the result", function()
		local srv = server.new(mock_app, mock_caps)
		local res1 = srv:handle({ method = "GET", path = "/runtime.js" })
		local res2 = srv:handle({ method = "GET", path = "/runtime.js" })
		T.eq(res1.body, res2.body, "should return cached result")
	end)

	T.it("invalidate_cache clears runtime cache", function()
		local srv = server.new(mock_app, mock_caps)
		srv:handle({ method = "GET", path = "/runtime.js" })
		T.ok(srv._rt_cache ~= nil, "cache should be set")
		srv:invalidate_cache()
		T.ok(srv._rt_cache == nil, "cache should be nil after invalidation")
	end)

end)

-- ── HTML bootstrap tests ─────────────────────────────────────────────────────

T.describe("platform.server HTML bootstrap", function()

	T.it("references /runtime.js in bootstrap", function()
		local srv = server.new(mock_app, mock_caps)
		local res = srv:handle({ method = "GET", path = "/" })
		T.eq(res.status, 200)
		T.ok(res.body:find("/runtime.js", 1, true) ~= nil, "should reference /runtime.js")
	end)

	T.it("imports caps from runtime and calls init", function()
		local srv = server.new(mock_app, mock_caps)
		local res = srv:handle({ method = "GET", path = "/" })
		T.ok(res.body:find("import", 1, true) ~= nil, "should use import")
		T.ok(res.body:find("caps", 1, true) ~= nil, "should reference caps")
		T.ok(res.body:find("init", 1, true) ~= nil, "should call init")
	end)

end)
