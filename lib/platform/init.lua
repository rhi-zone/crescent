-- lib/platform/init.lua
-- Platform runner: load a Lua app and run a sandboxed entrypoint.
--
-- An app is a gzipped tar archive containing manifest.json + Lua files.
-- It may be distributed as a raw .tar.gz or embedded in an image file
-- (PNG iTXt "lua" chunk: base64(gzip(tar))).
--
-- API:
--   platform.load_app(path)                           -> app | nil, err
--   platform.run_entry(app, entry_key, env, opts?)    -> ok, result | err
--   platform.load_and_run_entry(path, entry_key, env, opts?) -> ok, result | err
-- app fields:
--   app.path     : string
--   app.chunks   : png chunk array | nil  (nil for raw .tar.gz)
--   app.entries  : TarEntry[]             (all files in the tarball)
--   app.manifest : table                  (parsed manifest.json: name, version, entry)
--
-- Typical usage:
--   local platform = require("lib.platform")
--   local sandbox  = require("lib.sandbox")
--   local app = platform.load_app("myapp.png")
--   -- construct caps from manifest, then:
--   local env = sandbox.env(sandbox.stdlib, { globals = { caps = caps } })
--   local ok, result = platform.run_entry(app, "server", env)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local png      = require("lib.png")
local sandbox  = require("lib.sandbox")
local base64   = require("lib.base64")
local compress = require("lib.compress")
local tar      = require("lib.tar")
local json     = require("lib.json")

local M = {}

-- iTXt helpers now live in lib/png. Alias for local use.
local get_itxt = png.get_itxt

-- unpack_tarball(tardata) -> entries | nil, err
local function unpack_tarball(tardata)
	return tar.read(tardata)
end

--:: TarEntry = { name: string, mode: number, size: number, mtime: number, data: string, typeflag: string }
--:: AppRecord = { path: string, chunks: unknown, entries: { [number]: TarEntry }, manifest: unknown }
-- load_tarball_from_png(path, bytes) -> entries, chunks | nil, err
--: (string, string) -> ({ [number]: TarEntry } | nil, unknown | nil)
local function load_tarball_from_png(path, bytes)
	local chunks, perr = png.read(bytes)
	if not chunks then return nil, "platform: PNG parse failed: " .. tostring(perr) end

	local raw = get_itxt(chunks, "lua")
	if not raw then return nil, "platform: PNG has no 'lua' iTXt chunk" end

	local gz, berr = base64.decode(raw)
	if not gz then return nil, "platform: base64 decode failed: " .. tostring(berr) end

	local tardata, cerr = compress.inflate(gz, { format = "gzip" })
	if not tardata then return nil, "platform: gzip decompress failed: " .. tostring(cerr) end

	local entries, terr = unpack_tarball(tardata)
	if not entries then return nil, "platform: tar unpack failed: " .. tostring(terr) end

	return entries, chunks
end

-- load_tarball_from_targz(bytes) -> entries | nil, err
--: (string) -> ({ [number]: TarEntry } | nil, string | nil)
local function load_tarball_from_targz(bytes)
	local tardata, cerr = compress.inflate(bytes, { format = "gzip" })
	if not tardata then return nil, "platform: gzip decompress failed: " .. tostring(cerr) end
	return unpack_tarball(tardata)
end

-- load_app(path) -> app | nil, err
-- Loads an app from a .png (iTXt "lua" chunk) or .tar.gz (raw tarball).
--: (string) -> (AppRecord | nil, string | nil)
function M.load_app(path)
	local f_maybe, err = io.open(path, "rb")
	if not f_maybe then
		return nil, "platform: cannot open " .. tostring(path) .. ": " .. tostring(err)
	end
	local f = f_maybe or error("unreachable")
	local bytes_m = f:read("*a")
	f:close()
	local bytes = bytes_m or error("platform: could not read file: " .. tostring(path))

	local entries_nn, chunks
	do
		if path:match("%.png$") or path:match("%.jpg$") or path:match("%.jpeg$") or path:match("%.webp$") then
			local e, c = load_tarball_from_png(path, bytes)
			if not e then return nil, c end  -- c holds err here on failure
			entries_nn, chunks = e or error("unreachable"), c
		else
			local e, lerr = load_tarball_from_targz(bytes)
			if not e then return nil, lerr end
			entries_nn = e or error("unreachable")
		end
	end

	local manifest_src_m = tar.get(entries_nn, "manifest.json")
	if not manifest_src_m then return nil, "platform: tarball has no manifest.json" end
	local manifest_src = manifest_src_m or error("unreachable")

	local manifest, jerr = json.decode(manifest_src)
	if not manifest then return nil, "platform: manifest.json parse failed: " .. tostring(jerr) end

	return {
		path     = path,
		chunks   = chunks,  -- nil for raw .tar.gz
		entries  = entries_nn,
		manifest = manifest,
	}
end

-- make_tar_loader(entries) -> function
-- Returns a package.loaders-compatible function that resolves require() against
-- the tarball entries. Returns a loader function on success, or an error string
-- (Lua loader convention) on miss.
local function make_tar_loader(entries)
	return function(modname)
		local relpath = modname:gsub("%.", "/")
		local candidates = { --: { [number]: string }
			relpath .. ".lua",
			relpath .. "/init.lua",
		}
		for _, candidate in ipairs(candidates) do
			local src_m = tar.get(entries, candidate)
			if src_m then
				local src = src_m or error("unreachable")
				local chunk, lerr = load(src, "@" .. candidate, "t")
				if not chunk then
					return nil, "platform: error loading '" .. candidate .. "': " .. tostring(lerr)
				end
				return chunk
			end
		end
		return "\n\tno entry '" .. candidates[1] .. "' or '" .. candidates[2] .. "' in app tarball"
	end
end

-- validate_caps(manifest, entry_key, env) -> true | nil, err
-- Checks that env contains all required caps declared in the manifest.
-- env is the flat sandbox environment table (sandbox.env merges globals directly).
-- Top-level caps use the shorthand { cap_name = "required" | "optional" }.
-- Per-entrypoint caps use { cap_name = { type = string, required = bool } }.
-- Returns nil, errmsg if any required cap is absent from env.
local function validate_caps(manifest, entry_key, env)
	local globals = env or {}
	-- Caps may be nested under a "caps" table (new style) or top-level (old style)
	local cap_lookup = globals.caps or globals

	-- Top-level caps: { cap_name = "required" | "optional" }
	local top_caps = manifest and manifest.caps
	if top_caps then
		for cap_name, cap_spec in pairs(top_caps) do
			local is_required = cap_spec == "required" or cap_spec == true
			if is_required and cap_lookup[cap_name] == nil then
				return nil, "missing required cap: " .. tostring(cap_name) .. " (type: " .. tostring(cap_name) .. ")"
			end
		end
	end

	-- Per-entrypoint caps: { cap_name = { type = string, required = bool } }
	local entry_map = manifest and manifest.entry
	local entry_def = entry_map and entry_map[entry_key]
	local entry_caps = type(entry_def) == "table" and entry_def.caps
	if entry_caps then
		for cap_name, cap_spec in pairs(entry_caps) do
			local cap_type = type(cap_spec) == "table" and cap_spec.type or tostring(cap_name)
			local is_required = type(cap_spec) == "table" and cap_spec.required ~= false or cap_spec == "required" or cap_spec == true
			if is_required and cap_lookup[cap_name] == nil then
				return nil, "missing required cap: " .. tostring(cap_name) .. " (type: " .. tostring(cap_type) .. ")"
			end
		end
	end

	return true
end

-- run_entry(app, entry_key, env, opts?) -> ok, result | err
-- Looks up entry_key in app.manifest.entry, finds the file in app.entries,
-- injects a tar-backed require loader into env, and runs the entrypoint.
--: (AppRecord, string, { [string]: unknown, ... }, unknown) -> unknown
function M.run_entry(app, entry_key, env, opts)
	local entry_map = app.manifest and app.manifest.entry
	if not entry_map then
		return false, "platform: manifest has no 'entry' table"
	end
	local entry_def = entry_map[entry_key]
	if not entry_def then
		return false, "platform: no entry '" .. tostring(entry_key) .. "' in manifest"
	end
	-- entry_def may be a string (path) or a table {main=path, caps={...}}
	local entry_path = type(entry_def) == "table" and entry_def.main or entry_def
	if not entry_path then
		return false, "platform: entry '" .. tostring(entry_key) .. "' has no 'main' field"
	end

	local caps_ok, caps_err = validate_caps(app.manifest, entry_key, env)
	if not caps_ok then
		return false, caps_err
	end

	local src_m = tar.get(app.entries, entry_path)
	if not src_m then
		return false, "platform: entry file '" .. tostring(entry_path) .. "' not found in tarball"
	end
	local src = src_m or error("unreachable")

	opts = opts or {}
	opts.name = opts.name or ("@" .. tostring(entry_path))

	local tar_loader = make_tar_loader(app.entries)
	local base_require = env.require
	local function app_require(modname)
		local loader_or_err, detail = tar_loader(modname)
		if type(loader_or_err) == "function" then
			return loader_or_err()
		end
		if base_require then
			return base_require(modname)
		end
		error("platform: module '" .. tostring(modname) .. "' not found in app tarball", 2)
	end

	local app_env = {}
	for k, v in pairs(env) do app_env[k] = v end
	app_env.require = app_require

	return sandbox.run(src, app_env, opts)
end

-- load_and_run_entry(path, entry_key, env, opts?) -> ok, result | err
-- Convenience: load_app + run_entry in one call.
function M.load_and_run_entry(path, entry_key, env, opts)
	local app_m, err = M.load_app(path)
	if not app_m then return false, err end
	local app = app_m or error("unreachable")
	return M.run_entry(app, entry_key, env, opts)
end

-- caps: lazy proxy for capability factory sub-modules.
M.caps = setmetatable({}, {
	__index = function(t, k)
		local ok, mod = pcall(require, "lib.platform.caps." .. k)
		if ok then t[k] = mod; return mod end
		return nil
	end,
})

-- ── Cap type → factory mapping ───────────────────────────────────────────────

-- Each entry: { module = "lib.platform.caps.X", factory = "X_cap", args_fn }
-- args_fn(declaration, app, context, data_path) -> args for factory, or nil, err
local CAP_FACTORIES = {
	self = {
		mod = "lib.platform.caps.self",
		build = function(decl, app, context)
			return require("lib.platform.caps.self").self_cap(app, { app_id = context and context.app_id })
		end,
	},
	http_server = {
		mod = "lib.platform.caps.http_server",
		build = function(decl)
			return require("lib.platform.caps.http_server").http_server_cap({
					port = decl.port or 0, host = nil, daemon = nil, url = nil, on_serve = nil,
				})
		end,
	},
	http_client = {
		mod = "lib.platform.caps.http_client",
		build = function(decl)
			return require("lib.platform.caps.http_client").http_client_cap({ host = decl.host })
		end,
	},
	kv = {
		mod = "lib.platform.caps.kv",
		build = function(decl, app, context, data_path)
			return require("lib.platform.caps.kv").kv_cap(data_path)
		end,
	},
	db = {
		mod = "lib.platform.caps.db",
		build = function(decl, app, context, data_path)
			return require("lib.platform.caps.db").db_cap(data_path, {
				readonly = decl.readonly,
			})
		end,
	},
	shared_db = {
		mod = "lib.platform.caps.shared_db",
		build = function(decl, app, context, data_path)
			return require("lib.platform.caps.shared_db").shared_db_cap(
				data_path, context.app_id, decl.tables or {}, {
					readonly = decl.readonly,
				})
		end,
	},
	time = {
		mod = "lib.platform.caps.time",
		build = function() return require("lib.platform.caps.time").time_cap() end,
	},
}

-- ── Scope resolution ─────────────────────────────────────────────────────────

-- resolve_data_path(cap_name, scope, context) -> string
-- Builds a backing-store path from scope dimensions and context.
-- scope: array of dimension names (default {"user", "app"})
-- context: {user_id, app_id, data_dir}
local function resolve_data_path(cap_name, scope, context)
	local base = context.data_dir or "./data"
	scope = scope or { "user", "app" }
	local dimension_values = {
		user = context.user_id,
		app  = context.app_id,
	}
	local parts = { base }
	for i = 1, #scope do
		local dim = scope[i]
		local val = dimension_values[dim]
		if val then
			parts[#parts + 1] = val
		end
	end
	parts[#parts + 1] = cap_name .. ".db"
	return table.concat(parts, "/")
end
M._resolve_data_path = resolve_data_path  -- exposed for testing

-- ── make_caps ────────────────────────────────────────────────────────────────

-- make_caps(app, cap_declarations, operator_grants, context, factory_overrides?)
--   -> caps_table, revoke_fns_table
--   or nil, err
--
-- cap_declarations:  { cap_name = { type=string, required=bool, ...}, ... }
-- operator_grants:   { cap_name = true, ... }
-- context:           { user_id=string, app_id=string, data_dir=string }
-- factory_overrides: { cap_type = { build = fn(decl, app, context, data_path) -> cap, revoke_or_err }, ... }
--                    Lets callers (e.g. the daemon) supply alternate factories for
--                    specific cap types — typically http_server in daemon mode —
--                    without duplicating the rest of cap construction.
function M.make_caps(app, cap_declarations, operator_grants, context, factory_overrides)
	context = context or {}
	operator_grants = operator_grants or {}
	local caps = {}
	local revoke_fns = {}

	for name, decl in pairs(cap_declarations) do
		local cap_type = decl.type or name
		local required = decl.required ~= false  -- default true

		if not operator_grants[name] then
			if required then
				return nil, "platform: required cap '" .. name .. "' not granted by operator"
			end
			-- optional and not granted: skip
		else
			local factory = (factory_overrides and factory_overrides[cap_type]) or CAP_FACTORIES[cap_type]
			if not factory then
				if required then
					return nil, "platform: unknown cap type '" .. cap_type .. "' for cap '" .. name .. "'"
				end
				-- unknown optional cap type: skip
			else
				-- Resolve data path for storage caps
				local data_path
				if cap_type == "kv" or cap_type == "db" or cap_type == "shared_db" then
					data_path = resolve_data_path(name, decl.scope, context)
				end

				local cap, revoke_or_err = factory.build(decl, app, context, data_path)
				if not cap then
					return nil, "platform: failed to build cap '" .. name .. "': " .. tostring(revoke_or_err)
				end
				caps[name] = cap
				if type(revoke_or_err) == "function" then
					revoke_fns[name] = revoke_or_err
				end
			end
		end
	end

	return caps, revoke_fns
end

-- ── validate_caps ────────────────────────────────────────────────────────────

-- validate_caps(cap_declarations) -> true | nil, err
-- Checks that all declared caps have a known type and valid structure.
function M.validate_caps(cap_declarations)
	if type(cap_declarations) ~= "table" then
		return nil, "platform: caps must be a table"
	end
	for name, decl in pairs(cap_declarations) do
		if type(decl) ~= "table" then
			return nil, "platform: cap '" .. tostring(name) .. "' must be a table"
		end
		local cap_type = decl.type or name
		if not CAP_FACTORIES[cap_type] then
			return nil, "platform: unknown cap type '" .. tostring(cap_type) .. "' for cap '" .. tostring(name) .. "'"
		end
	end
	return true
end

-- ── run_app ──────────────────────────────────────────────────────────────────

-- run_app(path, entry_key, opts?) -> ok, result, revoke_fns | false, err
-- High-level convenience: load app, construct caps from manifest, run entry.
--
-- opts.context       : {user_id, app_id, data_dir}
-- opts.grants        : {cap_name=true, ...} — if nil, auto-grants everything
-- opts.sandbox_opts  : passed through to sandbox.run (budget, etc.)
function M.run_app(path, entry_key, opts)
	opts = opts or {}
	local context = opts.context or {}

	-- Load app
	local app_m, err = M.load_app(path)
	if not app_m then return false, err end
	local app = app_m or error("unreachable")

	-- Merge top-level and per-entry cap declarations
	local manifest = app.manifest
	local cap_declarations = {}

	-- Top-level caps
	if manifest and manifest.caps then
		for name, decl in pairs(manifest.caps) do
			cap_declarations[name] = decl
		end
	end

	-- Per-entry caps (override/merge with top-level)
	local entry_map = manifest and manifest.entry or {}
	local entry_def = entry_map[entry_key]
	if type(entry_def) == "table" and entry_def.caps then
		for name, decl in pairs(entry_def.caps) do
			cap_declarations[name] = decl
		end
	end

	-- Default context fields from manifest
	if not context.app_id then
		context.app_id = manifest and manifest.name or "unknown"
	end
	if not context.user_id then
		context.user_id = "default"
	end

	-- Operator grants: auto-grant everything if not specified
	local grants = opts.grants
	if not grants then
		grants = {}
		for name in pairs(cap_declarations) do
			grants[name] = true
		end
	end

	-- Construct caps
	local caps, revoke_fns
	if next(cap_declarations) then
		caps, revoke_fns = M.make_caps(app, cap_declarations, grants, context)
		if not caps then return false, revoke_fns end  -- revoke_fns is err string here
	else
		caps = {}
		revoke_fns = {}
	end

	-- Build sandbox env: stdlib + caps nested under "caps" global
	local cap_bundle = { globals = { caps = caps }, modules = {} }
	local env = sandbox.env(sandbox.stdlib, cap_bundle)

	-- Run
	local ok, result = M.run_entry(app, entry_key, env, opts.sandbox_opts)
	return ok, result, revoke_fns
end

return M
