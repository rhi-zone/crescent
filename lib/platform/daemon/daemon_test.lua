-- lib/platform/daemon/daemon_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local daemon = require("lib.platform.daemon")
local index = require("lib.platform.index")

-- ── Fakes ──────────────────────────────────────────────────────────────────
-- Injected time + RNG so tests are deterministic. random_bytes_fn returns a
-- rotating sequence so successive mints differ (otherwise all sessions would
-- collide to a single sid and "second request keeps the cookie" would be
-- indistinguishable from "second mint returned the same sid").

local function make_time_fn(start)
	local t = { now = start or 1000 }
	local fn = function()
		local v = t.now
		t.now = t.now + 1
		return v
	end
	return fn, t
end

local function make_random_fn(seed)
	local s = { v = seed or 0 }
	return function(n)
		local out = {}
		for i = 1, n do
			s.v = (s.v + 1) % 256
			out[i] = s.v
		end
		return out
	end
end

local function make_req(method, path, host, cookie)
	local headers = { host = { host } }
	if cookie then headers.cookie = { cookie } end
	return { method = method, path = path, headers = headers }
end

local function make_res()
	return { status = nil, headers = {}, body = nil }
end

-- Minimal index DB with one entry so the library app handler has something
-- non-trivial to work with. Uses :memory: so no filesystem churn.
local function make_index_db()
	local idx = index.open(":memory:")
	idx:install("/apps/alice.png", {
		name = "Alice",
		meta = { description = "test", tags = { "test" } },
	}, 1000)
	return idx, idx._db
end

local function make_daemon(opts)
	opts = opts or {}
	opts.host = opts.host or "localhost:7777"
	if not opts.time_fn then opts.time_fn = make_time_fn(1000) end
	if not opts.random_bytes_fn then opts.random_bytes_fn = make_random_fn(0) end
	return daemon.make(opts)
end

-- ── Host classification ────────────────────────────────────────────────────

T.describe("daemon.classify_host", function()
	T.it("recognises the daemon host", function()
		local c = daemon.classify_host("localhost:7777", "localhost:7777", {})
		T.eq(c.kind, "daemon")
	end)

	T.it("is case-insensitive on the host", function()
		local c = daemon.classify_host("LOCALHOST:7777", "localhost:7777", {})
		T.eq(c.kind, "daemon")
	end)

	T.it("recognises app-<id>.<host> subdomains", function()
		local c = daemon.classify_host("app-alice.localhost:7777", "localhost:7777", {})
		T.eq(c.kind, "app")
		T.eq(c.id, "alice")
	end)

	T.it("accepts app-<id> on same hostname with different port", function()
		-- Cookies ignore port; we pivot on the hostname part. See daemon-design.md.
		local c = daemon.classify_host("app-bob.localhost:9999", "localhost:7777", {})
		T.eq(c.kind, "app")
		T.eq(c.id, "bob")
	end)

	T.it("maps loopback IP via the registered ip→id table", function()
		local c = daemon.classify_host("127.0.0.5:7777", "localhost:7777", { ["127.0.0.5"] = "5" })
		T.eq(c.kind, "app")
		T.eq(c.id, "5")
		T.eq(c.loopback, true)
	end)

	T.it("returns unknown for unregistered loopback IPs", function()
		local c = daemon.classify_host("127.0.0.99:7777", "localhost:7777", {})
		T.eq(c.kind, "unknown")
	end)

	T.it("returns unknown for unrelated hosts", function()
		local c = daemon.classify_host("evil.example.com", "localhost:7777", {})
		T.eq(c.kind, "unknown")
	end)

	T.it("returns unknown for empty host", function()
		local c = daemon.classify_host("", "localhost:7777", {})
		T.eq(c.kind, "unknown")
	end)
end)

-- ── Host-based routing ─────────────────────────────────────────────────────

T.describe("Host-based origin routing", function()
	T.it("daemon host hits the library app", function()
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		local req = make_req("GET", "/", "localhost:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 200)
		-- Library app serves index.html at "/"; its body is the HTML page.
		T.ok(res.body and res.body:find("<!DOCTYPE html>"), "expected library HTML")
		idx:close()
	end)

	T.it("app-<id>.host hits the stub app handler", function()
		local d = make_daemon()
		local req = make_req("GET", "/", "app-alice.localhost:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 200)
		T.ok(res.body and res.body:find("alice"), "expected stub body to mention app id")
		T.ok(res.body:find("VM host pending"), "expected stub seam message")
	end)

	T.it("loopback IP maps to the registered app id", function()
		local d = make_daemon()
		local ip = d.register_app("5")
		T.eq(ip, "127.0.0.2")  -- first registration starts at .2
		-- Force a specific mapping by registering until we reach 127.0.0.5.
		d.register_app("b")
		d.register_app("c")
		d.register_app("d")  -- now next is 127.0.0.6; so we need id for 127.0.0.5
		-- Rebuild: re-check via direct table lookup (classify_host reads the table).
		-- Verify "5" still maps to 127.0.0.2 (its original assignment).
		T.eq(d.loopback_id_to_ip["5"], "127.0.0.2")

		-- A request to 127.0.0.2:<port> should classify as app "5".
		local req = make_req("GET", "/", "127.0.0.2:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 200)
		T.ok(res.body:find("app 5"), "expected stub to identify app 5")
	end)

	T.it("unknown host returns 404", function()
		local d = make_daemon()
		local req = make_req("GET", "/", "evil.example.com")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 404)
	end)
end)

-- ── Session cookie ─────────────────────────────────────────────────────────

T.describe("__Host-session cookie", function()
	T.it("first request without cookie gets a Set-Cookie header", function()
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		local req = make_req("GET", "/healthz", "localhost:7777")
		local res = make_res()
		d.handle(req, res)
		local sc = res.headers["Set-Cookie"]
		T.ok(sc, "expected Set-Cookie header")
		T.eq(type(sc), "table")
		T.eq(#sc, 1)
		local cookie = sc[1]
		T.ok(cookie:find("^__Host%-session="), "cookie name must be __Host-session: " .. cookie)
		T.ok(cookie:find("HttpOnly", 1, true), "expected HttpOnly")
		T.ok(cookie:find("SameSite=Strict", 1, true), "expected SameSite=Strict")
		T.ok(cookie:find("Path=/", 1, true), "expected Path=/")
		idx:close()
	end)

	T.it("second request with the cookie does NOT re-issue Set-Cookie", function()
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		-- First request: mint.
		local req1 = make_req("GET", "/healthz", "localhost:7777")
		local res1 = make_res()
		d.handle(req1, res1)
		local sid = res1.headers["Set-Cookie"][1]:match("__Host%-session=([^;]+)")
		T.ok(sid, "expected sid in cookie")

		-- Second request: present the cookie.
		local req2 = make_req("GET", "/healthz", "localhost:7777", "__Host-session=" .. sid)
		local res2 = make_res()
		d.handle(req2, res2)
		T.eq(res2.headers["Set-Cookie"], nil, "expected no Set-Cookie on second request")
		-- Session's last_seen should have advanced.
		T.ok(d.sessions[sid], "session should still exist")
		idx:close()
	end)

	T.it("unknown session cookie triggers a fresh mint", function()
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		local req = make_req("GET", "/healthz", "localhost:7777", "__Host-session=deadbeef")
		local res = make_res()
		d.handle(req, res)
		local sc = res.headers["Set-Cookie"]
		T.ok(sc, "expected fresh mint on unknown session id")
		local sid = sc[1]:match("__Host%-session=([^;]+)")
		T.ok(sid ~= "deadbeef", "expected a different sid than the bogus one presented")
		idx:close()
	end)

	T.it("app-origin responses do NOT set a session cookie", function()
		local d = make_daemon()
		local req = make_req("GET", "/", "app-alice.localhost:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.headers["Set-Cookie"], nil, "app origin must not set the daemon session cookie")
	end)

	T.it("omits Secure on loopback by default; emits it when opted in", function()
		-- Default (loopback-safe): no Secure.
		local d = make_daemon()
		local req = make_req("GET", "/healthz", "localhost:7777")
		local res = make_res()
		d.handle(req, res)
		local cookie = res.headers["Set-Cookie"][1]
		T.fail(cookie:find("Secure", 1, true), "loopback default should not include Secure")

		-- Opt-in: Secure present. See docs/daemon-design.md — routable
		-- interfaces require TLS and therefore Secure.
		local d2 = make_daemon({ secure_cookie = true })
		local req2 = make_req("GET", "/healthz", "localhost:7777")
		local res2 = make_res()
		d2.handle(req2, res2)
		local cookie2 = res2.headers["Set-Cookie"][1]
		T.ok(cookie2:find("Secure", 1, true), "opt-in should emit Secure")
	end)
end)

-- ── /healthz ───────────────────────────────────────────────────────────────

T.describe("/healthz", function()
	T.it("returns 200 with a short body", function()
		local d = make_daemon()
		local req = make_req("GET", "/healthz", "localhost:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 200)
		T.eq(res.body, "ok")
	end)

	T.it("healthz on app origin is the stub, not the daemon /healthz", function()
		local d = make_daemon()
		local req = make_req("GET", "/healthz", "app-alice.localhost:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 200)
		-- App origin goes through the stub; body must not be "ok".
		T.neq(res.body, "ok")
		T.ok(res.body:find("alice"))
	end)
end)

-- ── Cookie parser ─────────────────────────────────────────────────────────

T.describe("_get_cookie", function()
	T.it("parses a single cookie", function()
		T.eq(daemon._get_cookie({ cookie = { "a=1" } }, "a"), "1")
	end)

	T.it("parses one of several cookies", function()
		T.eq(daemon._get_cookie({ cookie = { "a=1; b=2; c=3" } }, "b"), "2")
	end)

	T.it("returns nil for a missing cookie", function()
		T.eq(daemon._get_cookie({ cookie = { "a=1" } }, "b"), nil)
	end)

	T.it("returns nil when no cookie header is present", function()
		T.eq(daemon._get_cookie({}, "a"), nil)
	end)
end)
