-- lib/platform/server_test.lua
-- Tests for lib/platform/server (HTTP request handling — no networking).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local server = require("lib.platform.server")

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

	T.it("GET /api/anything returns 404 (stub)", function()
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
