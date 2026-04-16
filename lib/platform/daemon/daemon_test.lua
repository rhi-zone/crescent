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
