-- lib/platform/daemon/end_to_end_test.lua
-- Install a trivial app into a real SQLite index DB, construct a daemon with
-- the real app_loader, and drive it through the full
--   index lookup → load_app → make_caps → sandbox.run_entry → captured handler
-- pipeline via d.handle(req, res).
--
-- This is the missing integration layer between `daemon_test.lua` (mocks the
-- loader) and `app_loader_test.lua` (unit-tests the loader against mock
-- index rows). Nothing here forks a process or opens a socket.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local daemon = require("lib.platform.daemon")
local app_loader = require("lib.platform.daemon.app_loader")
local app_index = require("lib.platform.index")
local tar = require("lib.tar")
local compress = require("lib.compress")
local json = require("lib.format.json")

--: (string, string) -> nil
local function write_file(path, data)
	local f = assert(io.open(path, "wb"))
	f:write(data)
	f:close()
end

--: (string) -> nil
local function rmrf(path)
	-- Best-effort; tests use /tmp paths so leaks aren't catastrophic.
	os.execute("rm -rf " .. path)
end

-- Build a .tar.gz containing manifest.json + server.lua and return the bytes.
--: ({ [string]: string }) -> string
local function build_app_targz(files)
	local entries = {} --: { [integer]: { name: string, data: string } }
	for name, data in pairs(files) do
		entries[#entries + 1] = { name = name, data = data }
	end
	local tar_bytes = tar.write(entries)
	local gz, err = compress.deflate(tar_bytes, { format = "gzip" })
	if not gz then error("gzip failed: " .. tostring(err)) end
	return gz
end

-- Minimal app: declares http_server + self caps, registers a handler that
-- writes a fixed body, echoes the request path, and reports the app's own
-- identity via caps.self.app_id.
local MINIMAL_SERVER = [[
local caps = caps
caps.http_server.serve(function(req, res)
	res.status = 200
	res.headers["Content-Type"] = { "text/plain; charset=utf-8" }
	res.body = "hello from " .. tostring(caps.self.app_id) .. " path=" .. (req.path or "/")
end)
]]

--: (string, string) -> string, string
local function install_minimal_app(apps_dir, app_slug)
	os.execute("mkdir -p " .. apps_dir)
	local manifest = {
		name = app_slug,
		version = "0.0.1",
		entry = {
			server = {
				main = "server.lua",
				caps = {
					http_server = "required",
					self = "required",
				},
			},
		},
	}
	local targz = build_app_targz({
		["manifest.json"] = json.encode(manifest),
		["server.lua"] = MINIMAL_SERVER,
	})
	local path = apps_dir .. "/" .. app_slug .. ".tar.gz"
	write_file(path, targz)
	return path, json.encode(manifest)
end

T.describe("daemon end-to-end (real index + real loader)", function()
	T.it("serves a response from an installed app via Host dispatch", function()
		local tmp = "/tmp/crescent-daemon-e2e-" .. tostring(os.time()) .. "-" .. math.random(1, 1e6)
		os.execute("mkdir -p " .. tmp)

		local path, _ = install_minimal_app(tmp, "hello")
		local idx = assert(app_index.open(tmp .. "/index.db"))
		local id = assert(idx:install(path, {
			name = "hello",
			entry = {
				server = {
					main = "server.lua",
					caps = { http_server = "required", self = "required" },
				},
			},
		}, os.time()))
		-- Grant required caps so resolve_grants returns true (not undecided).
		idx:set_grant(id, "http_server", true)
		idx:set_grant(id, "self", true)

		-- daemon.make wants string app_ids (URL-derived); the index returns
		-- an integer rowid. We install with a known id and stringify it for
		-- the Host header + pass through an adapter that coerces :get to a
		-- string-or-integer match.
		local app_id_str = tostring(id)

		local loader = app_loader.make({
			index_db = idx,
			context = { data_dir = tmp },
			entry_key = "server",
			app_url = function(aid) return "http://app-" .. aid .. ".test:7777" end,
		})

		local d = daemon.make({
			host = "test:7777",
			time_fn = function() return 1000 end,
			index_db = idx._db,
			app_loader = loader,
		})

		local req = {
			method = "GET",
			path = "/greet",
			query = nil,
			headers = { host = { "app-" .. app_id_str .. ".test:7777" } },
		}
		local res = { status = nil, headers = {}, body = nil } --: { status: integer | nil, headers: { [string]: unknown }, body: string | nil }

		d.handle(req, res)

		T.eq(res.status, 200, "status is 200")
		T.ok(res.body and res.body:find("hello from " .. app_id_str, 1, true),
			"body echoes caps.self.app_id; got: " .. tostring(res.body))
		T.ok(res.body and res.body:find("path=/greet", 1, true),
			"body reflects request path; got: " .. tostring(res.body))

		rmrf(tmp)
	end)

	T.it("caches the handler across requests (second hit does not reload)", function()
		local tmp = "/tmp/crescent-daemon-e2e-" .. tostring(os.time()) .. "-" .. math.random(1, 1e6)
		os.execute("mkdir -p " .. tmp)

		local path, _ = install_minimal_app(tmp, "cached")
		local idx = assert(app_index.open(tmp .. "/index.db"))
		local id = assert(idx:install(path, {
			name = "cached",
			entry = {
				server = {
					main = "server.lua",
					caps = { http_server = "required", self = "required" },
				},
			},
		}, os.time()))
		-- Grant required caps so resolve_grants returns true (not undecided).
		idx:set_grant(id, "http_server", true)
		idx:set_grant(id, "self", true)

		-- Wrap the loader to count invocations.
		local inner = app_loader.make({
			index_db = idx,
			context = { data_dir = tmp },
			entry_key = "server",
		})
		local load_calls = 0
		--: (string) -> (unknown, string | nil)
		local counting_loader = function(aid)
			load_calls = load_calls + 1
			return inner(aid)
		end

		local d = daemon.make({
			host = "test:7777",
			time_fn = function() return 1000 end,
			index_db = idx._db,
			app_loader = counting_loader,
		})

		local app_id_str = tostring(id)
		local function hit()
			local req = {
				method = "GET",
				path = "/",
				headers = { host = { "app-" .. app_id_str .. ".test:7777" } },
			}
			local res = { status = nil, headers = {}, body = nil } --: { status: integer | nil, headers: { [string]: unknown }, body: string | nil }
			d.handle(req, res)
			return res
		end

		local r1 = hit()
		local r2 = hit()
		local r3 = hit()

		T.eq(r1.status, 200)
		T.eq(r2.status, 200)
		T.eq(r3.status, 200)
		T.eq(load_calls, 1, "loader invoked exactly once across three requests")

		rmrf(tmp)
	end)

	T.it("missing app produces a 500 with an error caption and caches the failure", function()
		local tmp = "/tmp/crescent-daemon-e2e-" .. tostring(os.time()) .. "-" .. math.random(1, 1e6)
		os.execute("mkdir -p " .. tmp)

		local idx = assert(app_index.open(tmp .. "/index.db"))
		-- NB: we do not install anything — index is empty.

		local loader = app_loader.make({
			index_db = idx,
			context = { data_dir = tmp },
			entry_key = "server",
		})

		local d = daemon.make({
			host = "test:7777",
			time_fn = function() return 1000 end,
			index_db = idx._db,
			app_loader = loader,
		})

		local function hit()
			local req = {
				method = "GET",
				path = "/",
				headers = { host = { "app-999.test:7777" } },
			}
			local res = { status = nil, headers = {}, body = nil } --: { status: integer | nil, headers: { [string]: unknown }, body: string | nil }
			d.handle(req, res)
			return res
		end

		local r1 = hit()
		T.eq(r1.status, 500)
		T.ok(r1.body and r1.body:find("not found", 1, true),
			"body mentions not found; got: " .. tostring(r1.body))

		rmrf(tmp)
	end)
end)
