if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local web = require("lib.web")
local json = require("lib.format.json")
local T = require("lib.test.assert")

-- Helper to make a request table
local function req(method, path, opts)
	opts = opts or {}
	return {
		method = method,
		path = path,
		headers = opts.headers or {},
		body = opts.body or "",
	}
end

T.describe("web.app routing", function()
	T.it("basic GET route returns response", function()
		local app = web.app()
		app:get("/hello", function(rq, rs)
			rs.body = "Hello, World!"
		end)
		local res = app:handle(req("GET", "/hello"))
		T.eq(res.status, 200)
		T.eq(res.body, "Hello, World!")
	end)

	T.it("route params: GET /users/:id extracts params", function()
		local app = web.app()
		app:get("/users/:id", function(rq, rs)
			rs.body = "user:" .. rq.params.id
		end)
		local res = app:handle(req("GET", "/users/42"))
		T.eq(res.status, 200)
		T.eq(res.body, "user:42")
	end)

	T.it("POST route with body", function()
		local app = web.app()
		app:post("/submit", function(rq, rs)
			rs.body = "got:" .. tostring(rq.body)
		end)
		local res = app:handle(req("POST", "/submit", { body = "data" }))
		T.eq(res.status, 200)
		T.eq(res.body, "got:data")
	end)

	T.it("404 for unmatched route", function()
		local app = web.app()
		app:get("/hello", function(rq, rs)
			rs.body = "hi"
		end)
		local res = app:handle(req("GET", "/nope"))
		T.eq(res.status, 404)
		T.eq(res.body, "Not Found")
	end)

	T.it("404 for wrong method", function()
		local app = web.app()
		app:get("/hello", function(rq, rs)
			rs.body = "hi"
		end)
		local res = app:handle(req("POST", "/hello"))
		T.eq(res.status, 404)
	end)

	T.it("route priority: exact match over param match", function()
		local app = web.app()
		app:get("/users/:id", function(rq, rs)
			rs.body = "param:" .. rq.params.id
		end)
		app:get("/users/me", function(rq, rs)
			rs.body = "exact:me"
		end)
		local res = app:handle(req("GET", "/users/me"))
		T.eq(res.body, "exact:me")
	end)
end)

T.describe("web.app middleware", function()
	T.it("middleware runs in order", function()
		local app = web.app()
		local order = {}
		app:use(function(rq, rs, next)
			order[#order + 1] = "first"
			next()
		end)
		app:use(function(rq, rs, next)
			order[#order + 1] = "second"
			next()
		end)
		app:get("/test", function(rq, rs)
			rs.body = "ok"
		end)
		local res = app:handle(req("GET", "/test"))
		T.eq(order[1], "first")
		T.eq(order[2], "second")
		T.eq(res.body, "ok")
	end)

	T.it("middleware can short-circuit (not call next)", function()
		local app = web.app()
		app:use(function(rq, rs, next)
			rs.status = 401
			rs.body = "Unauthorized"
			-- deliberately not calling next()
		end)
		app:get("/secret", function(rq, rs)
			rs.body = "should not reach"
		end)
		local res = app:handle(req("GET", "/secret"))
		T.eq(res.status, 401)
		T.eq(res.body, "Unauthorized")
	end)

	T.it("multiple middleware compose", function()
		local app = web.app()
		app:use(function(rq, rs, next)
			rs.headers["X-First"] = { "1" }
			next()
		end)
		app:use(function(rq, rs, next)
			rs.headers["X-Second"] = { "2" }
			next()
		end)
		app:get("/test", function(rq, rs)
			rs.body = "ok"
		end)
		local res = app:handle(req("GET", "/test"))
		T.eq(res.headers["X-First"][1], "1")
		T.eq(res.headers["X-Second"][1], "2")
	end)
end)

T.describe("query string parsing", function()
	T.it("parses query string from path", function()
		local app = web.app()
		app:get("/search", function(rq, rs)
			rs.body = rq.query.q .. ":" .. rq.query.page
		end)
		local res = app:handle(req("GET", "/search?q=foo&page=2"))
		T.eq(res.body, "foo:2")
	end)
end)

T.describe("route groups", function()
	T.it("group prefixes paths", function()
		local app = web.app()
		local api = app:group("/api/v1")
		api:get("/users", function(rq, rs)
			rs.body = "users_list"
		end)
		api:post("/users", function(rq, rs)
			rs.body = "user_created"
		end)
		local res = app:handle(req("GET", "/api/v1/users"))
		T.eq(res.status, 200)
		T.eq(res.body, "users_list")

		local res2 = app:handle(req("POST", "/api/v1/users"))
		T.eq(res2.status, 200)
		T.eq(res2.body, "user_created")
	end)
end)

T.describe("json_body middleware", function()
	T.it("parses JSON request body", function()
		local app = web.app()
		app:use(web.json_body())
		app:post("/data", function(rq, rs)
			rs:json({ name = rq.body.name, age = rq.body.age })
		end)
		local body = json.encode({ name = "Alice", age = 30 })
		local res = app:handle(req("POST", "/data", {
			headers = { ["content-type"] = "application/json" },
			body = body,
		}))
		T.eq(res.status, 200)
		T.eq(res.headers["Content-Type"][1], "application/json")
		local decoded = json.decode(res.body)
		T.eq(decoded.name, "Alice")
		T.eq(decoded.age, 30)
	end)
end)

T.describe("cookies middleware", function()
	T.it("parses Cookie header", function()
		local app = web.app()
		app:use(web.cookies())
		app:get("/test", function(rq, rs)
			rs.body = rq.cookies.session .. ":" .. rq.cookies.theme
		end)
		local res = app:handle(req("GET", "/test", {
			headers = { ["cookie"] = "session=abc123; theme=dark" },
		}))
		T.eq(res.body, "abc123:dark")
	end)

	T.it("set_cookie adds Set-Cookie header", function()
		local app = web.app()
		app:use(web.cookies())
		app:get("/login", function(rq, rs)
			rs:set_cookie("session", "xyz", {
				path = "/",
				httpOnly = true,
				secure = true,
				sameSite = "Strict",
			})
			rs.body = "ok"
		end)
		local res = app:handle(req("GET", "/login"))
		T.eq(res.status, 200)
		local sc = res.headers["Set-Cookie"]
		T.ok(sc ~= nil)
		local sc1 = sc[1]
		T.ok(sc1:find("session=xyz", 1, true) ~= nil)
		T.ok(sc1:find("Path=/", 1, true) ~= nil)
		T.ok(sc1:find("HttpOnly", 1, true) ~= nil)
		T.ok(sc1:find("Secure", 1, true) ~= nil)
		T.ok(sc1:find("SameSite=Strict", 1, true) ~= nil)
	end)
end)

T.describe("cors middleware", function()
	T.it("sets CORS headers on normal requests", function()
		local app = web.app()
		app:use(web.cors({ origins = { "*" }, methods = { "GET", "POST" } }))
		app:get("/test", function(rq, rs)
			rs.body = "ok"
		end)
		local res = app:handle(req("GET", "/test"))
		T.eq(res.headers["Access-Control-Allow-Origin"][1], "*")
		T.eq(res.headers["Access-Control-Allow-Methods"][1], "GET, POST")
		T.eq(res.body, "ok")
	end)

	T.it("handles OPTIONS preflight", function()
		local app = web.app()
		app:use(web.cors({ origins = { "*" } }))
		local res = app:handle(req("OPTIONS", "/test"))
		T.eq(res.status, 204)
		T.eq(res.body, "")
		T.ok(res.headers["Access-Control-Allow-Origin"] ~= nil)
		T.ok(res.headers["Access-Control-Max-Age"] ~= nil)
	end)
end)

T.describe("response helpers", function()
	T.it("res:json() sets content-type and encodes body", function()
		local app = web.app()
		app:get("/data", function(rq, rs)
			rs:json({ x = 1 })
		end)
		local res = app:handle(req("GET", "/data"))
		T.eq(res.headers["Content-Type"][1], "application/json")
		local decoded = json.decode(res.body)
		T.eq(decoded.x, 1)
	end)

	T.it("res:html() sets content-type", function()
		local app = web.app()
		app:get("/page", function(rq, rs)
			rs:html("<h1>Hi</h1>")
		end)
		local res = app:handle(req("GET", "/page"))
		T.eq(res.headers["Content-Type"][1], "text/html")
		T.eq(res.body, "<h1>Hi</h1>")
	end)

	T.it("res:redirect() sets Location and status", function()
		local app = web.app()
		app:get("/old", function(rq, rs)
			rs:redirect("/new", 301)
		end)
		local res = app:handle(req("GET", "/old"))
		T.eq(res.status, 301)
		T.eq(res.headers["Location"][1], "/new")
	end)
end)

T.describe("static file middleware", function()
	T.it("serves a file from disk", function()
		-- Create a temp file
		local tmp_dir = os.tmpname()
		os.remove(tmp_dir)
		os.execute("mkdir -p " .. tmp_dir)
		local f = io.open(tmp_dir .. "/test.txt", "w")
		f:write("hello static")
		f:close()

		local app = web.app()
		app:use(web.static("/public", tmp_dir, function(path)
			local f = io.open(path, "rb")
			if not f then return nil end
			local contents = f:read("*a")
			f:close()
			return contents
		end))
		app:get("/fallback", function(rq, rs)
			rs.body = "fallback"
		end)

		local res = app:handle(req("GET", "/public/test.txt"))
		T.eq(res.status, 200)
		T.eq(res.body, "hello static")
		T.eq(res.headers["Content-Type"][1], "text/plain")

		-- Non-existent file falls through
		local res2 = app:handle(req("GET", "/public/nope.txt"))
		T.eq(res2.status, 404)

		-- Cleanup
		os.remove(tmp_dir .. "/test.txt")
		os.remove(tmp_dir)
	end)
end)

T.describe("csrf middleware", function()
	T.it("provides token on GET, rejects POST without token", function()
		local app = web.app()
		app:use(web.cookies())
		app:use(web.csrf({ secret = "s3cret" }))
		app:get("/form", function(rq, rs) rs.body = "ok" end)
		app:post("/form", function(rq, rs) rs.body = "submitted" end)

		-- GET sets csrf_token
		local res_get = app:handle(req("GET", "/form"))
		T.eq(res_get.status, 200)
		T.ok(res_get.csrf_token ~= nil)

		-- POST without token → 403
		local res_bad = app:handle(req("POST", "/form"))
		T.eq(res_bad.status, 403)

		-- POST with correct token → 200
		local token = res_get.csrf_token
		local res_ok = app:handle(req("POST", "/form", {
			headers = { ["x-csrf-token"] = token },
		}))
		T.eq(res_ok.status, 200)
		T.eq(res_ok.body, "submitted")
	end)
end)
