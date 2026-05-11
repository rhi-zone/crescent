-- lib/platform/daemon/app_loader.lua
-- Real per-app loader for the daemon VM host.
--
-- make(opts) -> app_loader_fn
--   Returns a function (app_id) -> (handler, err) suitable for
--   daemon.make({ app_loader = ... }).
--
-- opts: {
--   index_db : index table with :get(app_id) returning { path, manifest, ... }
--   context  : { user_id, data_dir } — merged into per-call context with app_id
--   entry_key: string (default "server") — which manifest entry to run
--   app_url  : (app_id) -> string — URL advertised via caps.http_server.url
-- }
--
-- Flow per app_id:
--   1. index_db:get(app_id) → row with .path
--   2. platform.load_app(path) → app
--   3. Build factory override for http_server in daemon mode; the app's call to
--      caps.http_server.serve(handler) feeds `handler` back via on_serve.
--   4. make_caps(app, entry caps, auto-grant, context, overrides) → caps
--   5. sandbox.env(sandbox.stdlib, { globals = { caps = caps }, modules = {} })
--   6. platform.run_entry(app, entry_key, env) — app registers its handler
--   7. Return the captured handler.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local platform     = require("lib.platform")
local sandbox      = require("lib.sandbox")
local http_srv_cap = require("lib.platform.caps.http_server")

local M = {}

--:: loader_opts = {
--::   index_db: unknown,
--::   context: { user_id: string | nil, data_dir: string | nil } | nil,
--::   entry_key: string | nil,
--::   app_url: ((string) -> string) | nil,
--:: }

-- Build the http_server factory override that captures the app's handler.
-- Returns (override_table, get_handler_fn). get_handler_fn() returns whatever
-- the app registered via cap.serve(), or nil if it never called serve.
--: (string, ((string) -> string) | nil) -> (unknown, () -> unknown)
local function make_http_server_override(app_id, app_url)
	local captured --: unknown
	local override = {
		build = function(_decl)
			return http_srv_cap.http_server_cap({
				daemon = true,
				url = (app_url and app_url(app_id)) or "",
				on_serve = function(h) captured = h end,
			})
		end,
	}
	return override, function() return captured end
end

-- Extract the cap declarations for a specific entry from a manifest.
-- Merges top-level manifest.caps with per-entry entry.caps (entry wins).
--: (unknown, string) -> { [string]: unknown }
local function collect_entry_caps(manifest, entry_key)
	local caps = {}
	local manifest_ = manifest --[[:! { caps: unknown, entry: unknown, entries: unknown, ... }]]
	if type(manifest_.caps) == "table" then
		for k, v in pairs(manifest_.caps) do caps[k] = v end
	end
	local entries = manifest_.entry or manifest_.entries
	if type(entries) == "table" then
		local entry = entries[entry_key]
		if type(entry) == "table" and type(entry.caps) == "table" then
			for k, v in pairs(entry.caps) do caps[k] = v end
		end
	end
	-- Normalise shorthand ("required"/"optional") into full decls.
	for k, v in pairs(caps) do
		if type(v) == "string" then
			caps[k] = { type = k, required = (v == "required") }
		elseif type(v) == "table" and not v.type then
			v.type = k
		end
	end
	return caps
end

-- Auto-grant every declared cap. Used when the index_db has no get_grants
-- method (test stubs that pass a raw db handle). Never used in production
-- where the full index wrapper is always passed.
--: ({ [string]: unknown }) -> { [string]: boolean }
local function auto_grants(cap_decls)
	local grants = {}
	for name in pairs(cap_decls) do grants[name] = true end
	return grants
end

-- Resolve grants from the index DB. Returns nil for caps with no stored
-- decision (undecided) — the daemon dispatch gate must block undecided
-- required caps before app_loader is called. Falls back to auto_grants only
-- when index_db lacks get_grants (test stubs with a raw db handle).
--: (unknown, string, { [string]: unknown }) -> { [string]: boolean | nil }
local function resolve_grants(index_db, app_id, cap_decls)
	local index_db_ = index_db --[[:! { get_grants: ((...unknown) -> unknown) | nil, ... } | nil]]
	if not index_db_ or not index_db_.get_grants then
		-- Raw db handle (no grant API) — auto-grant for test-stub compat.
		return auto_grants(cap_decls)
	end
	local stored = index_db_:get_grants(tonumber(app_id) or 0)
	local grants = {}
	for name in pairs(cap_decls) do
		grants[name] = stored[name]  -- nil = undecided; false = denied
	end
	return grants
end

--: (loader_opts) -> (string) -> (unknown, string | nil)
function M.make(opts)
	local index_db = opts.index_db
	local ctx_base = opts.context or {}
	local entry_key = opts.entry_key or "server"
	local app_url = opts.app_url

	--: (string) -> (unknown, string | nil)
	return function(app_id)
		if not index_db then
			return nil, "daemon/app_loader: no index_db"
		end
		local idx = index_db --[[:! { get: (unknown, string) -> { path: string, ... } | nil, get_cap_config: ((unknown, string, string) -> { [string]: unknown }) | nil, get_grants: ((unknown, integer) -> { [string]: boolean | nil }) | nil, ... }]]
		local row = idx:get(app_id)
		if not row then
			return nil, "app not found: " .. tostring(app_id)
		end
		local app_opt, err = platform.load_app(row.path)
		if not app_opt then
			return nil, "load_app failed: " .. tostring(err)
		end
		local app = app_opt --[[: unknown]]

		local cap_decls = collect_entry_caps(app.manifest, entry_key)
		-- Merge operator-supplied overrides into each cap declaration.
		if idx.get_cap_config then
			for name, decl in pairs(cap_decls) do
				local overrides = (idx.get_cap_config --[[:! (unknown, string, string) -> { [string]: unknown }]])(idx, app_id, name)
				for k, v in pairs(overrides) do (decl --[[:! { [string]: unknown }]])[k] = v end
			end
		end
		local grants = resolve_grants(idx, app_id, cap_decls)
		local context   = {
			user_id  = ctx_base.user_id,
			app_id   = app_id,
			data_dir = ctx_base.data_dir,
		}

		local override, get_captured = make_http_server_override(app_id, app_url)
		local caps, caps_err = platform.make_caps(app, cap_decls, grants, context, {
			http_server = override,
		})
		if not caps then
			return nil, "make_caps failed: " .. tostring(caps_err)
		end

		local env = sandbox.env(sandbox.stdlib, { globals = { caps = caps }, modules = {} })
		local ok, run_err = platform.run_entry(app, entry_key, env)
		if not ok then
			return nil, "run_entry failed: " .. tostring(run_err)
		end
		local handler = get_captured()
		if not handler then
			return nil, "app did not register an http_server handler"
		end
		return handler
	end
end

M._make_http_server_override = make_http_server_override
M._collect_entry_caps = collect_entry_caps
M._auto_grants = auto_grants

return M
