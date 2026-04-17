-- lib/platform/daemon/daemon_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local daemon = require("lib.platform.daemon")
local index = require("lib.platform.index")
local png = require("lib.png")
local base64 = require("lib.base64")
local json_mod = require("lib.format.json")
local compress = require("lib.compress")
local has_deflate = compress._tier == "system-zlib"

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

	T.it("stale daemon session cookie at top-level triggers a fresh mint", function()
		-- Mirror of /launch's stale-check, but at the non-launch dispatch: a
		-- 24h-idle cookie is dropped and a new session minted. The new sid
		-- must differ from the stale one, and the stale entry must be gone.
		local idx, db = make_index_db()
		local tfn, tref = make_time_fn(1000)
		local d = make_daemon({ index_db = db, time_fn = tfn })
		-- Prime inline (prime_session is defined later in the file).
		local prime_req = make_req("GET", "/healthz", "localhost:7777")
		local prime_res = make_res()
		d.handle(prime_req, prime_res)
		local sid = prime_res.headers["Set-Cookie"][1]:match("__Host%-session=([^;]+)")
		T.ok(d.sessions[sid], "precondition: session minted")

		tref.now = tref.now + 90000 -- > 86400s (24h)

		local req = make_req("GET", "/healthz", "localhost:7777", "__Host-session=" .. sid)
		local res = make_res()
		d.handle(req, res)
		local sc = res.headers["Set-Cookie"]
		T.ok(sc, "expected a fresh Set-Cookie for the re-minted session")
		local new_sid = sc[1]:match("__Host%-session=([^;]+)")
		T.ok(new_sid and new_sid ~= sid, "new sid must differ from the stale one")
		T.eq(d.sessions[sid], nil, "stale session must be dropped")
		T.ok(d.sessions[new_sid], "new session must be present")

		idx:close()
	end)

	T.it("default random_bytes_fn mints non-trivial session ids", function()
		-- Without an injected RNG, the daemon picks up lib/rand (getrandom(2)
		-- or /dev/urandom) and falls back to math.random only if neither is
		-- available. Either way, 32 hex chars must be produced and a pair of
		-- mints must differ. The assertion is deliberately weak — we're not
		-- testing entropy, just that the default path yields a session id at
		-- all and that two calls don't collide.
		local idx, db = make_index_db()
		-- Note: NOT passing random_bytes_fn. make_daemon would supply a
		-- deterministic one; go via daemon.make directly.
		local d = daemon.make({ host = "localhost:7777", index_db = db, time_fn = function() return 1000 end })

		local r1 = make_res(); d.handle(make_req("GET", "/healthz", "localhost:7777"), r1)
		local r2 = make_res(); d.handle(make_req("GET", "/healthz", "localhost:7777"), r2)
		local sid1 = r1.headers["Set-Cookie"][1]:match("__Host%-session=([^;]+)")
		local sid2 = r2.headers["Set-Cookie"][1]:match("__Host%-session=([^;]+)")
		T.ok(sid1 and #sid1 == 32, "sid1 must be 32 hex chars: " .. tostring(sid1))
		T.ok(sid2 and #sid2 == 32, "sid2 must be 32 hex chars")
		T.neq(sid1, sid2, "two mints must produce different ids")
		idx:close()
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

-- ── Launch flow ────────────────────────────────────────────────────────────
-- /launch/:id mints a one-shot token, 303-redirects to the app origin. The
-- app origin consumes the token in its ?__launch query and sets a per-app
-- session cookie scoped to that origin. See docs/daemon-design.md.

-- Helper: do a request that primes a daemon session cookie, then return that
-- sid so the launch-flow tests can present it.
local function prime_session(d)
	local req = make_req("GET", "/healthz", "localhost:7777")
	local res = make_res()
	d.handle(req, res)
	local sc = res.headers["Set-Cookie"]
	if not sc then return nil end
	return sc[1]:match("__Host%-session=([^;]+)")
end

-- Helper: add Sec-Fetch-Dest: document to a request. Emulates real browser
-- top-level navigation so /launch accepts it.
local function with_document_fetch_dest(req)
	req.headers["sec-fetch-dest"] = { "document" }
	return req
end

T.describe("/launch/:id", function()
	T.it("returns 401 without a session cookie AND does not mint one", function()
		-- /launch/* opts out of auto-mint. Direct address-bar paste must fail
		-- cleanly rather than set a cookie that makes the next retry work.
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		local req = with_document_fetch_dest(make_req("GET", "/launch/1", "localhost:7777"))
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 401)
		T.eq(res.headers["Set-Cookie"], nil, "401 on /launch must not carry Set-Cookie")
		idx:close()
	end)

	T.it("returns 401 when the presented cookie is unknown AND does not re-mint", function()
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		local req = with_document_fetch_dest(
			make_req("GET", "/launch/1", "localhost:7777", "__Host-session=deadbeef"))
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 401)
		T.eq(res.headers["Set-Cookie"], nil, "401 on /launch must not carry Set-Cookie")
		idx:close()
	end)

	T.it("returns 404 for an unknown app id with a valid session", function()
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		local sid = prime_session(d)
		local req = with_document_fetch_dest(
			make_req("GET", "/launch/9999", "localhost:7777", "__Host-session=" .. sid))
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 404)
		idx:close()
	end)

	T.it("rejects non-document Sec-Fetch-Dest with 400", function()
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		local sid = prime_session(d)
		local req = make_req("GET", "/launch/1", "localhost:7777", "__Host-session=" .. sid)
		req.headers["sec-fetch-dest"] = { "image" }
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 400)
		idx:close()
	end)

	T.it("303-redirects to app origin on valid session + existing app id", function()
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		local sid = prime_session(d)
		local req = with_document_fetch_dest(
			make_req("GET", "/launch/1", "localhost:7777", "__Host-session=" .. sid))
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 303)
		local loc_arr = res.headers["Location"]
		T.ok(loc_arr, "expected Location header")
		local loc = loc_arr[1]
		T.ok(loc:find("^http://app%-1%.localhost:7777/"), "expected subdomain origin: " .. loc)
		local tok = loc:match("%?__launch=([%x]+)$")
		T.ok(tok and #tok == 32, "expected 32-hex launch token in query: " .. tostring(loc))
		-- Token is in the launch_tokens map bound to the session.
		local rec = d.launch_tokens[tok]
		T.ok(rec, "launch_tokens[tok] must exist")
		T.eq(rec.app_id, "1")
		T.eq(rec.session_id, sid)
		-- Referrer-Policy: no-referrer on the mint response keeps the token
		-- out of the Referer header if the app's first paint fetches third
		-- party resources.
		T.eq(res.headers["Referrer-Policy"][1], "no-referrer")
		idx:close()
	end)

	T.it("forwards query params to the app origin redirect", function()
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		local sid = prime_session(d)
		-- Source adapter launch: /launch/1?entry=Alice.png
		local req = with_document_fetch_dest(
			make_req("GET", "/launch/1", "localhost:7777", "__Host-session=" .. sid))
		req.query = "entry=Alice.png"
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 303)
		local loc = res.headers["Location"][1]
		-- Location must contain __launch token AND entry param.
		T.ok(loc:find("__launch=", 1, true), "Location must have __launch token")
		T.ok(loc:find("entry=Alice.png", 1, true), "Location must forward entry= param")
		idx:close()
	end)

	T.it("mint sweeps expired tokens from the launch_tokens map", function()
		local idx, db = make_index_db()
		local tfn, tref = make_time_fn(1000)
		local d = make_daemon({ index_db = db, time_fn = tfn })
		local sid = prime_session(d)

		-- Mint a token, then advance the clock past its 5-minute expiry.
		local lreq1 = with_document_fetch_dest(
			make_req("GET", "/launch/1", "localhost:7777", "__Host-session=" .. sid))
		local lres1 = make_res()
		d.handle(lreq1, lres1)
		local tok1 = lres1.headers["Location"][1]:match("%?__launch=([%x]+)$")
		T.ok(d.launch_tokens[tok1], "first token must exist pre-sweep")

		tref.now = tref.now + 400 -- past the 300s expiry

		-- Second mint: the sweep should evict tok1 even though we never
		-- attempted to consume it.
		local lreq2 = with_document_fetch_dest(
			make_req("GET", "/launch/1", "localhost:7777", "__Host-session=" .. sid))
		local lres2 = make_res()
		d.handle(lreq2, lres2)
		T.eq(d.launch_tokens[tok1], nil, "expired tok1 must be swept at next mint")

		local tok2 = lres2.headers["Location"][1]:match("%?__launch=([%x]+)$")
		T.ok(d.launch_tokens[tok2], "new token must still exist")

		idx:close()
	end)

	T.it("rejects a stale daemon session at /launch with 401 and drops it", function()
		-- A session cookie older than SESSION_IDLE_TTL (24h) must be treated
		-- as unauthenticated at /launch — no auto-mint, no carry-over. The
		-- stale record is also dropped from the map so it stops counting
		-- toward memory.
		local idx, db = make_index_db()
		local tfn, tref = make_time_fn(1000)
		local d = make_daemon({ index_db = db, time_fn = tfn })
		local sid = prime_session(d)
		T.ok(d.sessions[sid], "precondition: session exists after prime")

		tref.now = tref.now + 90000 -- > 86400s (24h)

		local req = with_document_fetch_dest(
			make_req("GET", "/launch/1", "localhost:7777", "__Host-session=" .. sid))
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 401, "stale session must 401 at /launch")
		T.eq(d.sessions[sid], nil, "stale session must be swept from the map")

		idx:close()
	end)

	T.it("emits loopback origin when prefer_loopback=true", function()
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db, prefer_loopback = true })
		local sid = prime_session(d)
		local req = with_document_fetch_dest(
			make_req("GET", "/launch/1", "localhost:7777", "__Host-session=" .. sid))
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 303)
		local loc = res.headers["Location"][1]
		T.ok(loc:find("^http://127%.0%.0%.%d+:7777/"), "expected loopback origin: " .. loc)
		-- register_app was called — id "1" is now in the loopback tables.
		T.ok(d.loopback_id_to_ip["1"], "expected app id mapped to a loopback IP")
		idx:close()
	end)
end)

T.describe("launch-token redemption on app origin", function()
	T.it("consumes a valid token and 303s to / with a per-app session cookie", function()
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		local sid = prime_session(d)

		-- Mint a token via /launch.
		local lreq = with_document_fetch_dest(
			make_req("GET", "/launch/1", "localhost:7777", "__Host-session=" .. sid))
		local lres = make_res()
		d.handle(lreq, lres)
		local tok = lres.headers["Location"][1]:match("%?__launch=([%x]+)$")
		T.ok(tok, "expected token from redirect")

		-- Follow the redirect: app origin request with ?__launch=<tok>.
		-- Requests arrive with req.query set (see lib/http/format); our parser
		-- also tolerates the query embedded in req.path.
		local areq = make_req("GET", "/", "app-1.localhost:7777")
		areq.query = "__launch=" .. tok
		local ares = make_res()
		d.handle(areq, ares)

		T.eq(ares.status, 303)
		T.eq(ares.headers["Location"][1], "/")
		local sc = ares.headers["Set-Cookie"]
		T.ok(sc, "expected Set-Cookie on consume")
		local app_cookie = sc[1]
		T.ok(app_cookie:find("^__Host%-app%-session%-1="), "expected per-app cookie: " .. app_cookie)
		T.ok(app_cookie:find("HttpOnly", 1, true), "expected HttpOnly")
		T.ok(app_cookie:find("SameSite=Strict", 1, true), "expected SameSite=Strict")
		T.ok(app_cookie:find("Path=/", 1, true), "expected Path=/")

		-- Token is consumed (deleted) after first use.
		T.eq(d.launch_tokens[tok], nil, "token must be deleted after consume")

		-- Second use of the same token must 403.
		local areq2 = make_req("GET", "/", "app-1.localhost:7777")
		areq2.query = "__launch=" .. tok
		local ares2 = make_res()
		d.handle(areq2, ares2)
		T.eq(ares2.status, 403)

		idx:close()
	end)

	T.it("returns 403 for an expired token (clock injected)", function()
		local idx, db = make_index_db()
		local tfn, tref = make_time_fn(1000)
		local d = make_daemon({ index_db = db, time_fn = tfn })
		local sid = prime_session(d)

		-- Mint a token; note expires_at is now+300.
		local lreq = with_document_fetch_dest(
			make_req("GET", "/launch/1", "localhost:7777", "__Host-session=" .. sid))
		local lres = make_res()
		d.handle(lreq, lres)
		local tok = lres.headers["Location"][1]:match("%?__launch=([%x]+)$")
		T.ok(tok, "expected token")

		-- Jump the clock past expiry. Each time_fn() call bumps +1, so bump
		-- the baseline past the 5-minute window.
		tref.now = tref.now + 400

		local areq = make_req("GET", "/", "app-1.localhost:7777")
		areq.query = "__launch=" .. tok
		local ares = make_res()
		d.handle(areq, ares)
		T.eq(ares.status, 403)
		-- Expired tokens are still consumed — one-shot.
		T.eq(d.launch_tokens[tok], nil, "expired token must be consumed")

		idx:close()
	end)

	T.it("falls through to the stub app handler with no __launch", function()
		local d = make_daemon()
		-- No __launch param, no per-app cookie — goes straight to the stub.
		local req = make_req("GET", "/", "app-alice.localhost:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 200)
		T.ok(res.body:find("alice"), "expected stub to run")
	end)

	T.it("returns 403 when token is for a different app", function()
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		local sid = prime_session(d)

		-- Mint for app 1.
		local lreq = with_document_fetch_dest(
			make_req("GET", "/launch/1", "localhost:7777", "__Host-session=" .. sid))
		local lres = make_res()
		d.handle(lreq, lres)
		local tok = lres.headers["Location"][1]:match("%?__launch=([%x]+)$")

		-- Redeem against app "other" — must 403.
		local areq = make_req("GET", "/", "app-other.localhost:7777")
		areq.query = "__launch=" .. tok
		local ares = make_res()
		d.handle(areq, ares)
		T.eq(ares.status, 403)
		-- Even a cross-app attempt consumes the token (prevents replay).
		T.eq(d.launch_tokens[tok], nil)

		idx:close()
	end)

	T.it("mints distinct tokens across concurrent launches", function()
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		local sid = prime_session(d)

		local function mint()
			local req = with_document_fetch_dest(
				make_req("GET", "/launch/1", "localhost:7777", "__Host-session=" .. sid))
			local res = make_res()
			d.handle(req, res)
			return res.headers["Location"][1]:match("%?__launch=([%x]+)$")
		end

		local t1 = mint()
		local t2 = mint()
		local t3 = mint()
		T.neq(t1, t2)
		T.neq(t2, t3)
		T.neq(t1, t3)
		-- All three live in the launch_tokens map until consumed.
		T.ok(d.launch_tokens[t1])
		T.ok(d.launch_tokens[t2])
		T.ok(d.launch_tokens[t3])

		idx:close()
	end)

	T.it("mint sweeps idle per-app session tokens from the bucket", function()
		-- Per-app sessions have the same 24h idle-TTL as daemon sessions. The
		-- sweep runs at consume-time (when the app bucket is about to receive
		-- a new token). This test: consume a token → the bucket has exactly
		-- one entry. Advance the clock > 24h. Consume another token against
		-- the same app id. The stale entry must be evicted.
		local idx, db = make_index_db()
		local tfn, tref = make_time_fn(1000)
		local d = make_daemon({ index_db = db, time_fn = tfn })
		local sid = prime_session(d)

		-- Mint + consume round 1.
		local lreq1 = with_document_fetch_dest(
			make_req("GET", "/launch/1", "localhost:7777", "__Host-session=" .. sid))
		local lres1 = make_res()
		d.handle(lreq1, lres1)
		local tok1 = lres1.headers["Location"][1]:match("%?__launch=([%x]+)$")
		local areq1 = make_req("GET", "/", "app-1.localhost:7777")
		areq1.query = "__launch=" .. tok1
		d.handle(areq1, make_res())
		local bucket = d.app_sessions["1"]
		T.ok(bucket, "bucket for app 1 must exist after consume")
		local first_keys = {}
		for k in pairs(bucket) do first_keys[#first_keys + 1] = k end
		T.eq(#first_keys, 1, "bucket must hold exactly one entry after first consume")

		tref.now = tref.now + 90000 -- > 86400s (24h)

		-- Re-prime: after 24h the daemon session also expires. A new cookie
		-- is needed to pass /launch auth. This models an operator returning
		-- after a full day of idleness.
		local sid2 = prime_session(d)
		T.ok(sid2 and sid2 ~= sid, "expected a fresh sid after stale cookie")

		-- Mint + consume round 2.
		local lreq2 = with_document_fetch_dest(
			make_req("GET", "/launch/1", "localhost:7777", "__Host-session=" .. sid2))
		local lres2 = make_res()
		d.handle(lreq2, lres2)
		local tok2 = lres2.headers["Location"][1]:match("%?__launch=([%x]+)$")
		local areq2 = make_req("GET", "/", "app-1.localhost:7777")
		areq2.query = "__launch=" .. tok2
		d.handle(areq2, make_res())

		T.eq(bucket[first_keys[1]], nil, "stale per-app entry must be swept at next consume")
		local live = 0
		for _ in pairs(bucket) do live = live + 1 end
		T.eq(live, 1, "only the fresh entry remains")

		idx:close()
	end)
end)

-- ── Adversarial cases ──────────────────────────────────────────────────────
-- These cover attack-shaped inputs, not just happy-path edge cases:
--   (a) URL-bearer token semantic — deliberately not session-bound
--   (b) malformed or absent __launch parameters
--   (c) pathological app ids
--   (d) multiple __Host-session cookies in one Cookie header

T.describe("adversarial: launch-token bearer semantics", function()
	-- Design note: launch tokens are URL-bearer by design. The daemon session
	-- cookie is scoped to the daemon origin and not sent to the app origin,
	-- so the consume handler literally cannot see the caller's daemon
	-- session. See docs/daemon-design.md "v2 launch-flow notes" for the
	-- architectural reasoning and the mitigations (5-min expiry, one-shot,
	-- clean-URL redirect).
	T.it("leaked token can be consumed on app origin without the daemon session cookie", function()
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		local sid = prime_session(d)
		-- Alice mints a launch token for app 1.
		local req = with_document_fetch_dest(
			make_req("GET", "/launch/1", "localhost:7777", "__Host-session=" .. sid))
		local res = make_res()
		d.handle(req, res)
		local token = res.headers["Location"][1]:match("__launch=(%x+)")
		T.ok(token)
		-- Bob consumes it on the app origin with NO daemon session cookie at all.
		local breq = make_req("GET", "/?__launch=" .. token, "app-1.localhost:7777")
		local bres = make_res()
		d.handle(breq, bres)
		T.eq(bres.status, 303, "URL-bearer: any holder of the token can consume")
		T.ok(bres.headers["Set-Cookie"][1]:find("^__Host%-app%-session%-1="))
		idx:close()
	end)
end)

T.describe("adversarial: malformed __launch parameter", function()
	T.it("empty __launch value falls through to stub (treated as missing)", function()
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		local req = make_req("GET", "/?__launch=", "app-1.localhost:7777")
		local res = make_res()
		d.handle(req, res)
		-- Either stub (no consumption attempted) or 403 — but must not 303 with a new cookie.
		T.ok(res.status ~= 303, "empty token must not consume")
		T.eq(res.headers["Set-Cookie"], nil, "empty token must not set a per-app cookie")
		idx:close()
	end)

	T.it("non-hex __launch → 403, one-shot consume still applies if it matched", function()
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		local req = make_req("GET", "/?__launch=not-a-real-token-zzzzz", "app-1.localhost:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 403)
		idx:close()
	end)

	T.it("extremely long __launch (4096 chars) rejects without crashing", function()
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		local long = string.rep("a", 4096)
		local req = make_req("GET", "/?__launch=" .. long, "app-1.localhost:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 403)
		idx:close()
	end)

	T.it("used token is burned even when it belongs to a different app", function()
		local idx, db = make_index_db()
		idx:install("/apps/bob.png", { name = "Bob", meta = {} }, 1001)
		local d = make_daemon({ index_db = db })
		local sid = prime_session(d)
		-- Mint a token for app 1.
		local mreq = with_document_fetch_dest(
			make_req("GET", "/launch/1", "localhost:7777", "__Host-session=" .. sid))
		local mres = make_res()
		d.handle(mreq, mres)
		local token = mres.headers["Location"][1]:match("__launch=(%x+)")
		-- Present it on app 2's origin — wrong app → 403.
		local wreq = make_req("GET", "/?__launch=" .. token, "app-2.localhost:7777")
		local wres = make_res()
		d.handle(wreq, wres)
		T.eq(wres.status, 403)
		-- Replay on correct origin — token was burned.
		local creq = make_req("GET", "/?__launch=" .. token, "app-1.localhost:7777")
		local cres = make_res()
		d.handle(creq, cres)
		T.eq(cres.status, 403, "wrong-app contact burns the token")
		idx:close()
	end)
end)

T.describe("adversarial: pathological /launch/:id inputs", function()
	T.it("/launch/ (empty id) with session does not 303", function()
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		local sid = prime_session(d)
		local req = with_document_fetch_dest(
			make_req("GET", "/launch/", "localhost:7777", "__Host-session=" .. sid))
		local res = make_res()
		d.handle(req, res)
		T.ok(res.status ~= 303, "empty id must not mint a token")
		idx:close()
	end)

	T.it("/launch/.. with session → 404, not a traversal", function()
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		local sid = prime_session(d)
		local req = with_document_fetch_dest(
			make_req("GET", "/launch/..", "localhost:7777", "__Host-session=" .. sid))
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 404, "'..' is just a literal app id that doesn't exist")
		idx:close()
	end)

	T.it("/launch/<1000-char-id> → 404 without crashing", function()
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		local sid = prime_session(d)
		local huge_id = string.rep("x", 1000)
		local req = with_document_fetch_dest(
			make_req("GET", "/launch/" .. huge_id, "localhost:7777", "__Host-session=" .. sid))
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 404)
		idx:close()
	end)
end)

T.describe("adversarial: multiple __Host-session cookies in one header", function()
	T.it("when two __Host-session cookies are present, first-match wins (documented behavior)", function()
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		local sid = prime_session(d)
		-- Present the valid sid first, garbage second. First-match should succeed.
		local req = with_document_fetch_dest(
			make_req("GET", "/launch/1", "localhost:7777",
				"__Host-session=" .. sid .. "; __Host-session=ffff"))
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 303, "first-match is the valid sid")
		idx:close()
	end)

	T.it("garbage first, valid sid second → 401 (first-match picks the wrong cookie)", function()
		-- Documents the hazard of first-match behavior. __Host- prefix makes
		-- this nearly unreachable in practice (browsers refuse to set __Host-
		-- cookies from any scope that doesn't exactly match), but an abusive
		-- non-browser client can send anything.
		local idx, db = make_index_db()
		local d = make_daemon({ index_db = db })
		local sid = prime_session(d)
		local req = with_document_fetch_dest(
			make_req("GET", "/launch/1", "localhost:7777",
				"__Host-session=ffff; __Host-session=" .. sid))
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 401, "first-match selects the garbage sid")
		idx:close()
	end)
end)

T.describe("VM host dispatch via app_loader", function()
	T.it("loader is invoked once per app_id; handler is cached", function()
		local calls = 0
		local d = make_daemon({
			app_loader = function(app_id)
				calls = calls + 1
				return function(req, res)
					res.status = 200
					res.headers["Content-Type"] = { "text/plain" }
					res.body = "hello from " .. app_id
				end
			end,
		})
		local req1 = make_req("GET", "/", "app-foo.localhost:7777")
		local res1 = make_res()
		d.handle(req1, res1)
		T.eq(res1.status, 200)
		T.eq(res1.body, "hello from foo")
		T.eq(calls, 1)

		-- Second request to same app: loader NOT re-invoked.
		local req2 = make_req("GET", "/other", "app-foo.localhost:7777")
		local res2 = make_res()
		d.handle(req2, res2)
		T.eq(res2.status, 200)
		T.eq(res2.body, "hello from foo")
		T.eq(calls, 1)
	end)

	T.it("different app_ids get different handlers", function()
		local d = make_daemon({
			app_loader = function(app_id)
				return function(req, res)
					res.status = 200
					res.body = "app=" .. app_id
				end
			end,
		})
		local ra, resa = make_req("GET", "/", "app-alpha.localhost:7777"), make_res()
		local rb, resb = make_req("GET", "/", "app-beta.localhost:7777"),  make_res()
		d.handle(ra, resa)
		d.handle(rb, resb)
		T.eq(resa.body, "app=alpha")
		T.eq(resb.body, "app=beta")
	end)

	T.it("handler cache is bounded: LRU eviction re-invokes loader", function()
		-- Configure a cache of 2. Hit three distinct app_ids: the first is
		-- least-recently-used when the third is minted and must be evicted.
		-- A subsequent hit on the first app_id re-invokes the loader.
		local calls = {} --: { [string]: integer }
		local d = make_daemon({
			handler_cache_size = 2,
			app_loader = function(app_id)
				calls[app_id] = (calls[app_id] or 0) + 1
				return function(req, res)
					res.status = 200
					res.body = "app=" .. app_id
				end
			end,
		})
		local function hit(id)
			local req = make_req("GET", "/", "app-" .. id .. ".localhost:7777")
			local res = make_res()
			d.handle(req, res)
			return res
		end

		T.eq(hit("a").body, "app=a")
		T.eq(hit("b").body, "app=b")
		T.eq(hit("c").body, "app=c")   -- evicts "a"
		T.eq(calls["a"], 1)
		T.eq(calls["b"], 1)
		T.eq(calls["c"], 1)

		-- "a" was evicted: next hit re-invokes the loader.
		T.eq(hit("a").body, "app=a")
		T.eq(calls["a"], 2, "loader must be re-invoked after LRU eviction")
		-- "b" promoted to MRU on its own hit; "c" still cached. Net: cap=2
		-- holds {a,c}, evicts b on the next distinct mint — sanity-check
		-- the eviction direction.
		T.eq(hit("d").body, "app=d")  -- evicts "b" (LRU)
		T.eq(hit("b").body, "app=b")
		T.eq(calls["b"], 2, "b was evicted in favor of d; loader re-invoked")
	end)

	T.it("loader failure returns 500 with the error message", function()
		local d = make_daemon({
			app_loader = function(app_id)
				return nil, "missing manifest"
			end,
		})
		local req = make_req("GET", "/", "app-broken.localhost:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 500)
		T.ok(res.body:find("missing manifest"), "body should mention the error")
	end)

	T.it("loader error is cached briefly; loader NOT re-invoked inside the TTL", function()
		local calls = 0
		local d = make_daemon({
			app_loader = function(app_id)
				calls = calls + 1
				return nil, "boom"
			end,
		})
		local req1, res1 = make_req("GET", "/", "app-x.localhost:7777"), make_res()
		d.handle(req1, res1)
		T.eq(res1.status, 500)
		T.eq(calls, 1)
		local req2, res2 = make_req("GET", "/", "app-x.localhost:7777"), make_res()
		d.handle(req2, res2)
		T.eq(res2.status, 500)
		T.eq(calls, 1, "loader should not retry inside the TTL window")
	end)

	T.it("load-error cache expires after TTL; loader retried on next request", function()
		local calls = 0
		local tfn, tref = make_time_fn(1000)
		local d = make_daemon({
			time_fn = tfn,
			app_loader = function(app_id)
				calls = calls + 1
				if calls == 1 then return nil, "boom" end
				return function(req, res)
					res.status = 200
					res.body = "recovered"
				end
			end,
		})
		local req1, res1 = make_req("GET", "/", "app-flaky.localhost:7777"), make_res()
		d.handle(req1, res1)
		T.eq(res1.status, 500)

		-- Jump past the 5s TTL (plus slack for intra-handle time_fn calls).
		tref.now = tref.now + 60

		local req2, res2 = make_req("GET", "/", "app-flaky.localhost:7777"), make_res()
		d.handle(req2, res2)
		T.eq(res2.status, 200, "loader must be retried once TTL expires")
		T.eq(res2.body, "recovered")
		T.eq(calls, 2, "loader invoked exactly twice (first boom, then recovery)")
	end)

	T.it("handler setting string headers gets normalized to array form", function()
		local d = make_daemon({
			app_loader = function(app_id)
				return function(req, res)
					res.status = 200
					res.headers["Content-Type"] = "text/plain; charset=utf-8"
					res.body = "ok"
				end
			end,
		})
		local req = make_req("GET", "/", "app-y.localhost:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 200)
		T.eq(type(res.headers["Content-Type"]), "table")
		T.eq(res.headers["Content-Type"][1], "text/plain; charset=utf-8")
	end)

	T.it("app_handler override takes precedence over app_loader", function()
		local loader_calls = 0
		local d = make_daemon({
			app_handler = function(req, res, app_id)
				res.status = 418
				res.body = "override " .. app_id
			end,
			app_loader = function()
				loader_calls = loader_calls + 1
				return function() end
			end,
		})
		local req = make_req("GET", "/", "app-z.localhost:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 418)
		T.eq(res.body, "override z")
		T.eq(loader_calls, 0, "loader not invoked when app_handler is set")
	end)
end)

T.describe("per-request handler dispatch is pcall-wrapped", function()
	-- A throwing handler must produce a clean 500 — never bubble up past the
	-- daemon request loop, and never leak the error message to the client.
	-- See docs/daemon-isolation.md "Crash containment".

	T.it("throwing handler produces a 500 with a fixed body, not the error message", function()
		local d = make_daemon({
			app_handler = function(req, res, app_id) error("boom " .. app_id) end,
		})
		local req = make_req("GET", "/", "app-alice.localhost:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 500)
		T.eq(res.body, "internal server error")
		-- The error string "boom" must NOT appear in the response body —
		-- that's operator-visible only.
		T.fail(res.body:find("boom", 1, true), "client response must not include error text")
	end)

	T.it("on_handler_error callback fires with app_id, err, and a non-nil traceback", function()
		local captured_id, captured_err, captured_tb
		local d = make_daemon({
			app_handler = function(req, res, app_id) error("ouch") end,
			on_handler_error = function(id, err, tb)
				captured_id = id
				captured_err = err
				captured_tb = tb
			end,
		})
		local req = make_req("GET", "/", "app-bob.localhost:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(captured_id, "bob")
		T.ok(captured_err and captured_err:find("ouch", 1, true), "err should contain 'ouch'")
		T.ok(captured_tb and #captured_tb > 0, "expected non-empty traceback")
		T.ok(captured_tb:find("stack traceback", 1, true), "expected traceback string")
	end)

	T.it("successful handler output is unchanged (no wrapping overhead on happy path)", function()
		local d = make_daemon({
			app_handler = function(req, res, app_id)
				res.status = 201
				res.headers["Content-Type"] = { "application/json" }
				res.body = '{"app":"' .. app_id .. '"}'
			end,
		})
		local req = make_req("GET", "/", "app-carol.localhost:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 201)
		T.eq(res.body, '{"app":"carol"}')
		T.eq(res.headers["Content-Type"][1], "application/json")
	end)

	T.it("cached app_loader handler is not evicted on error; next request is also wrapped", function()
		local calls = 0
		local loader_calls = 0
		local d = make_daemon({
			app_loader = function(app_id)
				loader_calls = loader_calls + 1
				return function(req, res)
					calls = calls + 1
					error("always throws on " .. app_id)
				end
			end,
		})
		-- First request: loader runs, handler is cached, then throws.
		local req1 = make_req("GET", "/", "app-dave.localhost:7777")
		local res1 = make_res()
		d.handle(req1, res1)
		T.eq(res1.status, 500)
		T.eq(res1.body, "internal server error")
		T.eq(loader_calls, 1)
		T.eq(calls, 1)

		-- Second request: loader must NOT re-invoke. Cached handler still
		-- throws — and must still produce 500, not bubble.
		local req2 = make_req("GET", "/other", "app-dave.localhost:7777")
		local res2 = make_res()
		d.handle(req2, res2)
		T.eq(res2.status, 500)
		T.eq(res2.body, "internal server error")
		T.eq(loader_calls, 1, "loader must not re-invoke after a throwing handler is cached")
		T.eq(calls, 2, "cached handler is called again on second request")
	end)

	T.it("handler that calls assert(false, ...) also produces a clean 500", function()
		local d = make_daemon({
			app_handler = function(req, res, app_id) assert(false, "assertion failure") end,
		})
		local req = make_req("GET", "/", "app-eve.localhost:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 500)
		T.eq(res.body, "internal server error")
	end)
end)

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

-- ── DELETE /api/apps/:id — uninstall ─────────────────────────────────────────

T.describe("DELETE /api/apps/:id", function()
	-- Build a daemon with an in-memory index + a remove_fn spy.
	local function make_uninstall_daemon(extra)
		local idx = index.open(":memory:")
		local id = idx:install("/apps/alice.png", {
			name = "Alice", meta = { description = "test", tags = { "ai" } },
		}, 1000)
		extra = extra or {}
		local removed = {}
		local remove_fn = extra.remove_fn or function(path)
			removed[#removed + 1] = path
			return true
		end
		local d = daemon.make({
			host          = "localhost:7777",
			time_fn       = make_time_fn(1000),
			random_bytes_fn = make_random_fn(0),
			index_db      = idx._db,
			remove_fn     = remove_fn,
		})
		return d, idx, id, removed
	end

	-- Prime a daemon session cookie, return the sid string.
	local function prime(d)
		local req = make_req("GET", "/healthz", "localhost:7777")
		local res = make_res()
		d.handle(req, res)
		local sc = res.headers["Set-Cookie"]
		if not sc then return nil end
		return sc[1]:match("__Host%-session=([^;]+)")
	end

	T.it("requires an existing session — no cookie → 401", function()
		local d, idx, id = make_uninstall_daemon()
		local req = make_req("DELETE", "/api/apps/" .. id, "localhost:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 401)
		T.ok(idx:get(id), "app must still be in index after rejected uninstall")
		idx:close()
	end)

	T.it("requires an existing session — unknown cookie → 401", function()
		local d, idx, id = make_uninstall_daemon()
		local req = make_req("DELETE", "/api/apps/" .. id, "localhost:7777", "__Host-session=deadbeef")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 401)
		T.ok(idx:get(id), "app must still be in index")
		idx:close()
	end)

	T.it("unknown app id → 404", function()
		local d, idx, id = make_uninstall_daemon()
		local sid = prime(d)
		local req = make_req("DELETE", "/api/apps/99999", "localhost:7777", "__Host-session=" .. sid)
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 404)
		T.ok(idx:get(id), "other apps unaffected")
		idx:close()
	end)

	T.it("non-numeric id → 400", function()
		local d, idx = make_uninstall_daemon()
		local sid = prime(d)
		local req = make_req("DELETE", "/api/apps/notanumber", "localhost:7777", "__Host-session=" .. sid)
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 400)
		idx:close()
	end)

	T.it("valid session + valid id → 200, row gone, file removed", function()
		local d, idx, id, removed = make_uninstall_daemon()
		local sid = prime(d)
		local req = make_req("DELETE", "/api/apps/" .. id, "localhost:7777", "__Host-session=" .. sid)
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 200)
		T.ok(res.body and res.body:find('"ok"'), "expected ok JSON body")
		T.eq(idx:get(id), nil, "row must be gone from index after uninstall")
		T.eq(#removed, 1, "remove_fn must be called once")
		T.eq(removed[1], "/apps/alice.png")
		idx:close()
	end)

	T.it("file removal failure is non-fatal — 200, row still gone", function()
		local errors = {}
		local d, idx, id = make_uninstall_daemon({
			remove_fn = function(_) return nil, "no such file" end,
		})
		-- Wire on_handler_error to capture the logged message.
		-- Re-create daemon to pass on_handler_error + the failing remove_fn.
		local idx2 = index.open(":memory:")
		local id2 = idx2:install("/apps/gone.png", { name = "Gone" }, 1000)
		local d2 = daemon.make({
			host            = "localhost:7777",
			time_fn         = make_time_fn(1000),
			random_bytes_fn = make_random_fn(0),
			index_db        = idx2._db,
			remove_fn       = function(_) return nil, "no such file" end,
			on_handler_error = function(app_id, err, _) errors[#errors + 1] = { app_id, err } end,
		})
		local sid = prime(d2)
		local req = make_req("DELETE", "/api/apps/" .. id2, "localhost:7777", "__Host-session=" .. sid)
		local res = make_res()
		d2.handle(req, res)
		T.eq(res.status, 200)
		T.eq(idx2:get(id2), nil, "index row must be gone even when file removal fails")
		T.eq(#errors, 1, "expected one error logged via on_handler_error")
		T.ok(errors[1][2]:find("no such file", 1, true), "error message must mention the failure")
		idx:close()
		idx2:close()
	end)

	T.it("uninstall clears app_cap_config rows", function()
		local d, idx, id = make_uninstall_daemon()
		-- Store a cap override before uninstalling.
		idx:set_cap_config(id, "characters", { root = "/mnt/x" })
		T.eq(idx:get_cap_config(id, "characters").root, "/mnt/x")

		local sid = prime(d)
		local req = make_req("DELETE", "/api/apps/" .. id, "localhost:7777", "__Host-session=" .. sid)
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 200)

		-- Cap config row must be gone.
		local cfg = idx:get_cap_config(id, "characters")
		T.eq(next(cfg), nil, "app_cap_config must be cleared on uninstall")
		idx:close()
	end)

	T.it("no index_db → 503", function()
		local d = daemon.make({
			host            = "localhost:7777",
			time_fn         = make_time_fn(1000),
			random_bytes_fn = make_random_fn(0),
		})
		local sid = prime(d)
		local req = make_req("DELETE", "/api/apps/1", "localhost:7777", "__Host-session=" .. sid)
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 503)
	end)

	T.it("second DELETE for the same id → 404 (idempotent on the index)", function()
		local d, idx, id = make_uninstall_daemon()
		local sid = prime(d)
		local del = function()
			local req = make_req("DELETE", "/api/apps/" .. id, "localhost:7777", "__Host-session=" .. sid)
			local res = make_res()
			d.handle(req, res)
			return res.status
		end
		T.eq(del(), 200, "first delete must succeed")
		T.eq(del(), 404, "second delete must return 404")
		idx:close()
	end)
end)

-- ── Cap grant UI ────────────────────────────────────────────────────────────

T.describe("GET /apps/:id/grant", function()
	-- Helper: make a daemon + index with one app that has caps declared.
	-- Returns d, idx, app_id (integer).
	local function make_grant_daemon(extra)
		extra = extra or {}
		local idx = index.open(":memory:")
		local app_id = idx:install("/apps/alice.png", {
			name = "Alice",
			meta  = { description = "AI character", tags = {} },
			caps  = {
				characters = { type = "fs", required = true },
				http_client = { type = "http_client", required = false },
			},
		}, 1000)
		local d = daemon.make({
			host            = "localhost:7777",
			time_fn         = make_time_fn(1000),
			random_bytes_fn = make_random_fn(0),
			index_db        = idx._db,
			index_obj       = idx,
		})
		return d, idx, app_id
	end

	local function prime(d)
		local req = make_req("GET", "/healthz", "localhost:7777")
		local res = make_res()
		d.handle(req, res)
		local sc = res.headers["Set-Cookie"]
		if not sc then return nil end
		return sc[1]:match("__Host%-session=([^;]+)")
	end

	T.it("requires an existing session — no cookie → 401", function()
		local d, idx, id = make_grant_daemon()
		local req = make_req("GET", "/apps/" .. id .. "/grant", "localhost:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 401)
		idx:close()
	end)

	T.it("renders an HTML form listing the app's cap names", function()
		local d, idx, id = make_grant_daemon()
		local sid = prime(d)
		local req = make_req("GET", "/apps/" .. id .. "/grant", "localhost:7777",
			"__Host-session=" .. sid)
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 200)
		local ct = res.headers["Content-Type"] and res.headers["Content-Type"][1] or ""
		T.ok(ct:find("text/html", 1, true), "expected HTML content type: " .. ct)
		T.ok(res.body and res.body:find("characters",  1, true), "expected characters cap in body")
		T.ok(res.body:find("http_client", 1, true), "expected http_client cap in body")
		T.ok(res.body:find("Alice",       1, true), "expected app name in body")
		T.ok(res.body:find('<input type=hidden name=csrf', 1, true), "expected CSRF hidden field")
		idx:close()
	end)

	T.it("shows stored grant decisions as pre-selected radio buttons", function()
		local d, idx, id = make_grant_daemon()
		idx:set_grant(id, "characters", true)
		idx:set_grant(id, "http_client", false)
		local sid = prime(d)
		local req = make_req("GET", "/apps/" .. id .. "/grant", "localhost:7777",
			"__Host-session=" .. sid)
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 200)
		-- The form rows include checked attributes. The exact HTML has
		-- 'value=grant checked' for granted caps and 'value=deny checked' for denied.
		T.ok(res.body:find('value=grant checked', 1, true),
			"expected grant radio pre-checked for characters")
		T.ok(res.body:find('value=deny checked', 1, true),
			"expected deny radio pre-checked for http_client")
		idx:close()
	end)

	T.it("returns 404 for a non-existent app id", function()
		local d, idx, id = make_grant_daemon()
		local sid = prime(d)
		local req = make_req("GET", "/apps/9999/grant", "localhost:7777",
			"__Host-session=" .. sid)
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 404)
		idx:close()
	end)

	T.it("sets strict CSP header", function()
		local d, idx, id = make_grant_daemon()
		local sid = prime(d)
		local req = make_req("GET", "/apps/" .. id .. "/grant", "localhost:7777",
			"__Host-session=" .. sid)
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 200)
		local csp = res.headers["Content-Security-Policy"]
		T.ok(csp, "expected CSP header")
		local csp_val = type(csp) == "table" and csp[1] or tostring(csp)
		T.ok(csp_val:find("default-src 'none'", 1, true), "CSP must block all by default")
		idx:close()
	end)
end)

T.describe("POST /apps/:id/grant", function()
	local function make_grant_daemon()
		local idx = index.open(":memory:")
		local app_id = idx:install("/apps/alice.png", {
			name = "Alice",
			meta  = { description = "AI character", tags = {} },
			caps  = {
				characters = { type = "fs", required = true },
			},
		}, 1000)
		local d = daemon.make({
			host            = "localhost:7777",
			time_fn         = make_time_fn(1000),
			random_bytes_fn = make_random_fn(0),
			index_db        = idx._db,
			index_obj       = idx,
		})
		return d, idx, app_id
	end

	-- Prime session, extract sid and csrf token from the GET grant page.
	local function prime_grant(d, idx, app_id)
		local req0 = make_req("GET", "/healthz", "localhost:7777")
		local res0 = make_res()
		d.handle(req0, res0)
		local sid = res0.headers["Set-Cookie"][1]:match("__Host%-session=([^;]+)")

		local req1 = make_req("GET", "/apps/" .. app_id .. "/grant", "localhost:7777",
			"__Host-session=" .. sid)
		local res1 = make_res()
		d.handle(req1, res1)
		local csrf = res1.body and res1.body:match('name=csrf value="([^"]+)"')
		return sid, csrf
	end

	local function post_grant(d, app_id, sid, body)
		local req = make_req("POST", "/apps/" .. app_id .. "/grant", "localhost:7777",
			"__Host-session=" .. sid)
		req.headers["content-type"] = { "application/x-www-form-urlencoded" }
		req.body = body
		local res = make_res()
		d.handle(req, res)
		return res
	end

	T.it("requires session — no cookie → 401", function()
		local d, idx, id = make_grant_daemon()
		local req = make_req("POST", "/apps/" .. id .. "/grant", "localhost:7777")
		req.body = "csrf=x&cap_characters=grant"
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 401)
		idx:close()
	end)

	T.it("rejects missing or wrong CSRF token → 403", function()
		local d, idx, id = make_grant_daemon()
		local sid, csrf = prime_grant(d, idx, id)
		-- Missing CSRF.
		local res1 = post_grant(d, id, sid, "cap_characters=grant")
		T.eq(res1.status, 403)
		-- Wrong CSRF.
		local res2 = post_grant(d, id, sid, "csrf=badtoken&cap_characters=grant")
		T.eq(res2.status, 403)
		idx:close()
	end)

	T.it("stores grant decisions and redirects to app origin", function()
		local d, idx, id = make_grant_daemon()
		local sid, csrf = prime_grant(d, idx, id)
		local res = post_grant(d, id, sid,
			"csrf=" .. csrf .. "&cap_characters=grant")
		T.eq(res.status, 303)
		local loc = res.headers["Location"] and res.headers["Location"][1] or ""
		T.ok(loc:find("app-" .. id .. ".localhost:7777", 1, true),
			"expected redirect to app origin: " .. loc)
		-- Grant decision must be persisted.
		local grants = idx:get_grants(id)
		T.eq(grants["characters"], true)
		idx:close()
	end)

	T.it("stores deny decision", function()
		local d, idx, id = make_grant_daemon()
		local sid, csrf = prime_grant(d, idx, id)
		post_grant(d, id, sid, "csrf=" .. csrf .. "&cap_characters=deny")
		local grants = idx:get_grants(id)
		T.eq(grants["characters"], false)
		idx:close()
	end)

	T.it("invalidates handler cache so next app request re-loads with new grants", function()
		local loader_calls = 0
		local idx = index.open(":memory:")
		local app_id = idx:install("/apps/alice.png", {
			name = "Alice",
			meta  = {},
			caps  = { characters = { type = "fs", required = true } },
		}, 1000)
		-- Pre-store a grant so the grant gate won't redirect.
		idx:set_grant(app_id, "characters", true)
		local d = daemon.make({
			host            = "localhost:7777",
			time_fn         = make_time_fn(1000),
			random_bytes_fn = make_random_fn(0),
			index_db        = idx._db,
			index_obj       = idx,
			app_loader      = function(_id)
				loader_calls = loader_calls + 1
				return function(req, res) res.status = 200; res.body = "ok" end
			end,
		})
		-- First app request → loader called once, handler cached.
		local req1 = make_req("GET", "/", "app-" .. app_id .. ".localhost:7777")
		local res1 = make_res()
		d.handle(req1, res1)
		T.eq(loader_calls, 1)

		-- POST to grant page → must invalidate cache.
		local req0 = make_req("GET", "/healthz", "localhost:7777")
		local res0 = make_res()
		d.handle(req0, res0)
		local sid = res0.headers["Set-Cookie"][1]:match("__Host%-session=([^;]+)")
		local greq = make_req("GET", "/apps/" .. app_id .. "/grant", "localhost:7777",
			"__Host-session=" .. sid)
		local gres = make_res()
		d.handle(greq, gres)
		local csrf = gres.body:match('name=csrf value="([^"]+)"')
		local preq = make_req("POST", "/apps/" .. app_id .. "/grant", "localhost:7777",
			"__Host-session=" .. sid)
		preq.body = "csrf=" .. csrf .. "&cap_characters=grant"
		d.handle(preq, make_res())

		-- Second app request → loader must be called again (cache was invalidated).
		local req2 = make_req("GET", "/", "app-" .. app_id .. ".localhost:7777")
		local res2 = make_res()
		d.handle(req2, res2)
		T.eq(loader_calls, 2, "loader must be re-invoked after grant POST invalidates cache")
		idx:close()
	end)
end)

T.describe("grant dispatch gate", function()
	local function make_grant_daemon(pre_grants)
		local idx = index.open(":memory:")
		local app_id = idx:install("/apps/alice.png", {
			name = "Alice",
			meta  = {},
			caps  = { characters = { type = "fs", required = true } },
		}, 1000)
		if pre_grants then
			for cname, decision in pairs(pre_grants) do
				idx:set_grant(app_id, cname, decision)
			end
		end
		local d = daemon.make({
			host            = "localhost:7777",
			time_fn         = make_time_fn(1000),
			random_bytes_fn = make_random_fn(0),
			index_db        = idx._db,
			index_obj       = idx,
			app_loader      = function(_id)
				return function(req, res)
					res.status = 200
					res.body = "loaded"
				end
			end,
		})
		return d, idx, app_id
	end

	T.it("undecided required cap → 303 redirect to grant page", function()
		local d, idx, id = make_grant_daemon()
		local req = make_req("GET", "/", "app-" .. id .. ".localhost:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 303)
		local loc = res.headers["Location"] and res.headers["Location"][1] or ""
		T.ok(loc:find("/apps/" .. id .. "/grant", 1, true),
			"redirect must point to grant page: " .. loc)
		idx:close()
	end)

	T.it("all required caps decided → app handler loads normally", function()
		local d, idx, id = make_grant_daemon({ characters = true })
		local req = make_req("GET", "/", "app-" .. id .. ".localhost:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 200)
		T.eq(res.body, "loaded")
		idx:close()
	end)

	T.it("denied required cap still passes gate (denial is a decision)", function()
		-- The gate only blocks undecided caps. Denying a cap is a decision —
		-- the app loads (with that cap absent/nil) and may fail at runtime.
		local d, idx, id = make_grant_daemon({ characters = false })
		local req = make_req("GET", "/", "app-" .. id .. ".localhost:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 200, "denied cap is decided — gate must not redirect")
		idx:close()
	end)
end)

-- ── POST /api/import-card ────────────────────────────────────────────────────

-- Build a minimal valid PNG with a chara tEXt chunk. Same helper as in
-- lib/platform/import_test.lua.
local function make_card_png(card_data)
	local card_json = json_mod.encode(card_data)
	local chara_b64 = base64.encode(card_json)
	local chunks = {
		{ type = "IHDR", data = "\0\0\0\1\0\0\0\1\8\2\0\0\0" },
		{ type = "IDAT", data = "\x78\x01\x62\x60\x60\x60\x00\x00\x00\x04\x00\x01" },
		{ type = "tEXt", data = png.build_text("chara", chara_b64) },
		{ type = "IEND", data = "" },
	}
	return png.write(chunks)
end

local RUNTIME_FILES = {
	{ name = "server.lua", data = "return {}" },
}
local RUNTIME_MANIFEST = {
	name = "Character Card v2",
	version = "0.1.0",
	meta = { tags = { "charactercardv2" } },
	default_entry = "server",
	caps  = {},
	entry = { server = { main = "server.lua", caps = {} } },
}

T.describe("POST /api/import-card", function()
	if not has_deflate then
		T.it("skips: system-zlib not available", function() T.skip("system-zlib required for import") end)
		return
	end

	local CARD_PNG = make_card_png({ data = { name = "Alice", description = "Test card", tags = { "ai" } } })

	-- Build a daemon with a fake source whose handler returns CARD_PNG for GET /card/:id.
	local function make_import_daemon(extra)
		extra = extra or {}
		local idx = index.open(":memory:")
		local written = {}
		local write_fn = extra.write_fn or function(path, data)
			written[#written + 1] = { path = path, data = data }
			return true
		end
		local source_handler = extra.source_handler or function(req, res)
			res.status = 200
			res.headers["Content-Type"] = { "image/png" }
			res.body = CARD_PNG
		end
		local d = daemon.make({
			host            = "localhost:7777",
			time_fn         = make_time_fn(1000),
			random_bytes_fn = make_random_fn(0),
			index_db        = idx._db,
			index_obj       = idx,
			apps_dir        = "/tmp/test-apps",
			write_fn        = write_fn,
			runtime_files   = RUNTIME_FILES,
			runtime_manifest = RUNTIME_MANIFEST,
			sources         = {
				{
					id       = "42",
					name     = "SillyTavern",
					discover = function() return { entries = {}, total = 0 } end,
					handler  = source_handler,
				},
			},
		})
		return d, idx, written
	end

	local function prime(d)
		local req = make_req("GET", "/healthz", "localhost:7777")
		local res = make_res()
		d.handle(req, res)
		return res.headers["Set-Cookie"][1]:match("__Host%-session=([^;]+)")
	end

	local function post_import(d, sid, source, entry)
		local req = make_req("POST", "/api/import-card", "localhost:7777",
			"__Host-session=" .. sid)
		req.query = "source=" .. source .. "&entry=" .. entry
		local res = make_res()
		d.handle(req, res)
		return res
	end

	T.it("requires session — no cookie → 401", function()
		local d = make_import_daemon()
		local req = make_req("POST", "/api/import-card", "localhost:7777")
		req.query = "source=42&entry=Alice.png"
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 401)
	end)

	T.it("returns 503 when runtime not configured", function()
		local idx = index.open(":memory:")
		local d = daemon.make({
			host            = "localhost:7777",
			time_fn         = make_time_fn(1000),
			random_bytes_fn = make_random_fn(0),
			index_db        = idx._db,
		})
		local sid = prime(d)
		local res = post_import(d, sid, "42", "Alice.png")
		T.eq(res.status, 503)
		idx:close()
	end)

	T.it("returns 404 for unknown source id", function()
		local d, idx = make_import_daemon()
		local sid = prime(d)
		local res = post_import(d, sid, "99", "Alice.png")
		T.eq(res.status, 404)
		idx:close()
	end)

	T.it("returns 400 when source or entry param is missing", function()
		local d, idx = make_import_daemon()
		local sid = prime(d)
		local req = make_req("POST", "/api/import-card", "localhost:7777",
			"__Host-session=" .. sid)
		req.query = "source=42"  -- missing entry
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 400)
		idx:close()
	end)

	T.it("imports card: write_fn called, app indexed, returns launch_url", function()
		local d, idx, written = make_import_daemon()
		local sid = prime(d)
		local res = post_import(d, sid, "42", "Alice.png")
		T.eq(res.status, 200)
		local body = json_mod.decode(res.body)
		T.ok(body, "expected JSON body")
		T.eq(body.ok, true)
		T.ok(body.launch_url, "expected launch_url in response")
		T.ok(body.launch_url:find("^/launch/"), "launch_url must start with /launch/")
		T.eq(#written, 1, "write_fn must be called once")
		-- The new app must be indexed.
		local apps = idx:list()
		T.eq(#apps, 1, "one app must be indexed after import")
		T.eq(apps[1].name, "Alice")
		idx:close()
	end)

	T.it("returns 502 when source handler returns non-200", function()
		local d, idx = make_import_daemon({
			source_handler = function(req, res)
				res.status = 404
				res.body = "not found"
			end,
		})
		local sid = prime(d)
		local res = post_import(d, sid, "42", "missing.png")
		T.eq(res.status, 502)
		idx:close()
	end)
end)
