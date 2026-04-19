-- lib/platform/policy/policy_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local policy = require("lib.platform.policy")
local json = require("lib.format.json")

-- ── Helpers ────────────────────────────────────────────────────────────────

-- Build a read_fn backed by an in-memory table of path→content.
local function make_read_fn(files)
	return function(path)
		return files[path]
	end
end

local SAMPLE_POLICY = json.encode({
	cap_policy = {
		fs          = { state = "denied" },
		http_client = { state = "allowed", hosts = { "api.openai.com", "api.anthropic.com" } },
		kv          = { state = "allowed", max_size_mb = 100 },
		net         = { state = "allowed" },
	},
})

-- ── load ───────────────────────────────────────────────────────────────────

T.describe("policy.load", function()
	T.it("load(nil) returns allow-all policy", function()
		local pol, err = policy.load(nil)
		T.ok(pol, "expected policy object, got err: " .. tostring(err))
		T.ok(not err)
		T.eq(pol:check_cap("fs"), "allowed")
		T.eq(pol:check_cap("http_client"), "allowed")
		T.eq(pol:check_cap("kv"), "allowed")
	end)

	T.it("load(nonexistent path) returns allow-all (not an error)", function()
		local read_fn = make_read_fn({})
		local pol, err = policy.load("/nonexistent/policy.json", { read_fn = read_fn })
		T.ok(pol, "expected policy object")
		T.ok(not err)
		T.eq(pol:check_cap("kv"), "allowed")
	end)

	T.it("load(valid path) parses policy correctly", function()
		local read_fn = make_read_fn({ ["/etc/policy.json"] = SAMPLE_POLICY })
		local pol, err = policy.load("/etc/policy.json", { read_fn = read_fn })
		T.ok(pol, "expected policy object, got err: " .. tostring(err))
		T.ok(not err)
	end)
end)

-- ── check_cap ──────────────────────────────────────────────────────────────

T.describe("policy:check_cap", function()
	local function make_pol()
		local read_fn = make_read_fn({ ["/p.json"] = SAMPLE_POLICY })
		return policy.load("/p.json", { read_fn = read_fn })
	end

	T.it("returns 'denied' for fs: denied cap", function()
		local pol = make_pol()
		T.eq(pol:check_cap("fs"), "denied")
	end)

	T.it("returns 'restricted' for http_client with hosts restriction", function()
		local pol = make_pol()
		T.eq(pol:check_cap("http_client"), "restricted")
	end)

	T.it("returns 'restricted' for kv with max_size_mb restriction", function()
		local pol = make_pol()
		T.eq(pol:check_cap("kv"), "restricted")
	end)

	T.it("returns 'allowed' for net: allowed with no extra restrictions", function()
		local pol = make_pol()
		T.eq(pol:check_cap("net"), "allowed")
	end)

	T.it("returns 'allowed' for unknown cap on allow-all policy", function()
		local pol = policy.load(nil)
		T.eq(pol:check_cap("kv"), "allowed")
	end)

	T.it("returns 'allowed' for cap not mentioned in policy", function()
		local pol = make_pol()
		T.eq(pol:check_cap("time"), "allowed")
	end)
end)

-- ── check_cap_decl ─────────────────────────────────────────────────────────

T.describe("policy:check_cap_decl", function()
	local function make_pol()
		local read_fn = make_read_fn({ ["/p.json"] = SAMPLE_POLICY })
		return policy.load("/p.json", { read_fn = read_fn })
	end

	T.it("denied cap returns nil + reason", function()
		local pol = make_pol()
		local ok, reason = pol:check_cap_decl("fs", {})
		T.ok(not ok)
		T.ok(type(reason) == "string" and #reason > 0, "expected reason string")
		T.eq(reason, "blocked by admin policy")
	end)

	T.it("http_client with allowed host returns true", function()
		local pol = make_pol()
		local ok, reason = pol:check_cap_decl("http_client", { host = "api.openai.com" })
		T.ok(ok == true, "expected true, got: " .. tostring(reason))
	end)

	T.it("http_client with disallowed host returns nil + reason", function()
		local pol = make_pol()
		local ok, reason = pol:check_cap_decl("http_client", { host = "evil.example" })
		T.ok(not ok)
		T.eq(reason, "host not in admin policy allowlist")
	end)

	T.it("http_client with another allowed host returns true", function()
		local pol = make_pol()
		local ok, reason = pol:check_cap_decl("http_client", { host = "api.anthropic.com" })
		T.ok(ok == true, "expected true, got: " .. tostring(reason))
	end)

	T.it("kv within size limit returns true", function()
		local pol = make_pol()
		local ok, reason = pol:check_cap_decl("kv", { max_size_mb = 50 })
		T.ok(ok == true, "expected true, got: " .. tostring(reason))
	end)

	T.it("kv exactly at size limit returns true", function()
		local pol = make_pol()
		local ok, reason = pol:check_cap_decl("kv", { max_size_mb = 100 })
		T.ok(ok == true, "expected true, got: " .. tostring(reason))
	end)

	T.it("kv exceeding size limit returns nil + reason", function()
		local pol = make_pol()
		local ok, reason = pol:check_cap_decl("kv", { max_size_mb = 200 })
		T.ok(not ok)
		T.eq(reason, "exceeds admin policy storage limit")
	end)

	T.it("kv without max_size_mb in decl is allowed regardless", function()
		local pol = make_pol()
		local ok, reason = pol:check_cap_decl("kv", {})
		T.ok(ok == true, "expected true, got: " .. tostring(reason))
	end)

	T.it("allow-all policy passes any cap decl", function()
		local pol = policy.load(nil)
		local ok = pol:check_cap_decl("fs", {})
		T.ok(ok == true)
	end)

	T.it("denied cap with non-table decl returns nil + reason", function()
		local pol = make_pol()
		local ok, reason = pol:check_cap_decl("fs", true)
		T.ok(not ok)
		T.eq(reason, "blocked by admin policy")
	end)
end)

-- ── reload ─────────────────────────────────────────────────────────────────

T.describe("policy:reload", function()
	T.it("reload picks up changed file contents", function()
		-- Start with a policy that denies fs.
		local files = { ["/p.json"] = SAMPLE_POLICY }
		local read_fn = make_read_fn(files)
		local pol = policy.load("/p.json", { read_fn = read_fn })
		T.eq(pol:check_cap("fs"), "denied")

		-- Now update the in-memory "file" to allow fs.
		files["/p.json"] = json.encode({ cap_policy = { fs = { state = "allowed" } } })
		local ok, err = pol:reload()
		T.ok(ok, "reload failed: " .. tostring(err))
		T.eq(pol:check_cap("fs"), "allowed")
	end)

	T.it("reload with nil path resets to allow-all", function()
		local pol = policy.load(nil)
		local ok = pol:reload()
		T.ok(ok == true)
		T.eq(pol:check_cap("fs"), "allowed")
	end)

	T.it("reload when file disappears resets to allow-all", function()
		local files = { ["/p.json"] = SAMPLE_POLICY }
		local read_fn = make_read_fn(files)
		local pol = policy.load("/p.json", { read_fn = read_fn })
		T.eq(pol:check_cap("fs"), "denied")

		-- Remove the file.
		files["/p.json"] = nil
		local ok, err = pol:reload()
		T.ok(ok, "reload failed: " .. tostring(err))
		T.eq(pol:check_cap("fs"), "allowed")
	end)
end)

-- ── Daemon integration ─────────────────────────────────────────────────────
-- Tests that the daemon rejects apps with denied caps at load time and
-- allows apps with permitted caps.

T.describe("daemon + admin policy", function()
	local daemon = require("lib.platform.daemon")
	local index = require("lib.platform.index")

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

	-- Make an index with one app that declares the given caps.
	local function make_index_with_caps(caps)
		local idx = index.open(":memory:")
		idx:install("/apps/alice.png", {
			name = "Alice",
			caps = caps,
			meta = { description = "test app", tags = {} },
		}, 1000)
		return idx
	end

	-- Make a daemon with policy_path wired, and an index with given caps.
	-- Policy is supplied via read_fn to avoid touching the filesystem.
	local function make_daemon_with_policy(cap_policy_tbl, caps_in_manifest)
		local idx = make_index_with_caps(caps_in_manifest)
		-- The app id is 1 (first installed).
		local policy_content = json.encode({ cap_policy = cap_policy_tbl })
		local files = { ["/admin/policy.json"] = policy_content }
		local read_fn = make_read_fn(files)

		-- policy.load is called in the test directly; we wire it into the daemon
		-- via a custom app_loader that checks policy. In the real daemon this is
		-- wired at make() time — here we simulate it with a loader that applies
		-- policy before returning the handler.
		local pol = policy.load("/admin/policy.json", { read_fn = read_fn })

		local load_err --: string | nil
		local function loader(app_id)
			local iapp_id = tonumber(app_id)
			local row = iapp_id and idx:get(iapp_id)
			if not row then return nil, "app not found" end
			local manifest = row.manifest or {}
			-- Collect cap decls from manifest.
			local cap_decls = {}
			if type(manifest.caps) == "table" then
				for k, v in pairs(manifest.caps) do cap_decls[k] = v end
			end
			for cname, decl in pairs(cap_decls) do
				local ok_pol, reason = pol:check_cap_decl(cname, decl)
				if not ok_pol then
					load_err = reason
					return nil, "blocked by admin policy: " .. cname .. ": " .. tostring(reason)
				end
			end
			-- Return a trivial handler.
			return function(req, res)
				res.status = 200
				res.headers["Content-Type"] = { "text/plain" }
				res.body = "hello from " .. app_id
			end
		end

		local d = daemon.make({
			host             = "localhost:7777",
			time_fn          = make_time_fn(1000),
			random_bytes_fn  = make_random_fn(0),
			index_obj        = idx,
			app_loader       = loader,
		})
		return d, idx, pol, function() return load_err end
	end

	T.it("app with denied cap fails to load with policy error", function()
		local d, idx, pol, get_load_err = make_daemon_with_policy(
			{ fs = { state = "denied" } },
			{ fs = { type = "fs", required = true } }
		)

		-- First: grant the cap so we don't get redirected to grant page.
		idx:set_grant(1, "fs", true)

		-- Hit the app origin — should trigger loader which checks policy.
		local req = make_req("GET", "/", "app-1.localhost:7777")
		local res = make_res()
		d.handle(req, res)
		-- Expect 500 from blocked load.
		T.eq(res.status, 500)
		T.ok(res.body and res.body:find("admin policy"), "expected admin policy in error body, got: " .. tostring(res.body))
	end)

	T.it("app with allowed cap loads successfully", function()
		local d, idx, pol, get_load_err = make_daemon_with_policy(
			{ net = { state = "allowed" } },
			{ net = { type = "net", required = true } }
		)

		-- Grant the cap.
		idx:set_grant(1, "net", true)

		local req = make_req("GET", "/", "app-1.localhost:7777")
		local res = make_res()
		d.handle(req, res)
		T.eq(res.status, 200)
		T.eq(res.body, "hello from 1")
	end)
end)
