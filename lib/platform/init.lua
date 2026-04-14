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
--   platform.caps.png                 -> require("lib.platform.caps.png")
--   platform.caps.llm                 -> require("lib.platform.caps.llm")
--   platform.caps.render              -> require("lib.platform.caps.render")
--   platform.caps.fs                  -> require("lib.platform.caps.fs")
--
-- app fields:
--   app.path     : string
--   app.chunks   : png chunk array | nil  (nil for raw .tar.gz)
--   app.entries  : TarEntry[]             (all files in the tarball)
--   app.manifest : table                  (parsed manifest.json: name, version, entry)
--
-- Typical usage:
--   local platform = require("lib.platform")
--   local sandbox  = require("lib.sandbox")
--   local llm_mod  = require("lib.platform.caps.llm")
--
--   local env = sandbox.env(sandbox.stdlib, { globals = {
--     llm = llm_mod.llm_cap({ endpoint = "http://localhost:8000", model = "gemma3" }),
--   }})
--   local ok, result = platform.load_and_run_entry("myapp.png", "dom", env)

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

-- ── iTXt helpers ─────────────────────────────────────────────────────────────
-- iTXt data layout (PNG spec section 11.3.4.3):
--   keyword\0 compression_flag(1) compression_method(1) language_tag\0 translated_keyword\0 text
-- compression_flag: 0 = uncompressed, 1 = compressed (method 0 = zlib)
-- The "lua" chunk stores base64(gzip(tar)) as uncompressed UTF-8 text.

-- get_itxt(chunks, keyword) -> string | nil
-- Returns the text value of the first iTXt chunk with the given keyword.
-- Only handles uncompressed iTXt (compression_flag == 0).
local function get_itxt(chunks, keyword)
	for _, chunk in ipairs(chunks) do
		if chunk.type == "iTXt" then
			local data = chunk.data
			local sep = data:find("\0", 1, true)
			if sep and data:sub(1, sep - 1) == keyword then
				local compression_flag = data:byte(sep + 1)
				if compression_flag ~= 0 then
					return nil  -- compressed iTXt not supported here
				end
				local pos = sep + 3  -- start of language_tag
				local lang_end = data:find("\0", pos, true)
				if not lang_end then return nil end
				local tkey_end = data:find("\0", lang_end + 1, true)
				if not tkey_end then return nil end
				return data:sub(tkey_end + 1)
			end
		end
	end
	return nil
end

-- unpack_tarball(tardata) -> entries | nil, err
local function unpack_tarball(tardata)
	return tar.read(tardata)
end

-- load_tarball_from_png(path, bytes) -> entries, chunks | nil, err
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

-- load_tarball_from_targz(path, bytes) -> entries | nil, err
local function load_tarball_from_targz(bytes)
	local tardata, cerr = compress.inflate(bytes, { format = "gzip" })
	if not tardata then return nil, "platform: gzip decompress failed: " .. tostring(cerr) end
	return unpack_tarball(tardata)
end

-- load_app(path) -> app | nil, err
-- Loads an app from a .png (iTXt "lua" chunk) or .tar.gz (raw tarball).
function M.load_app(path)
	local f, err = io.open(path, "rb")
	if not f then return nil, "platform: cannot open " .. tostring(path) .. ": " .. tostring(err) end
	local bytes = f:read("*a")
	f:close()

	local entries, chunks, lerr
	if path:match("%.png$") or path:match("%.jpg$") or path:match("%.jpeg$") or path:match("%.webp$") then
		entries, chunks = load_tarball_from_png(path, bytes)
		if not entries then return nil, chunks end  -- chunks holds err here on failure
	else
		entries, lerr = load_tarball_from_targz(bytes)
		if not entries then return nil, lerr end
	end

	local manifest_src = tar.get(entries, "manifest.json")
	if not manifest_src then return nil, "platform: tarball has no manifest.json" end

	local manifest, jerr = json.decode(manifest_src)
	if not manifest then return nil, "platform: manifest.json parse failed: " .. tostring(jerr) end

	return {
		path     = path,
		chunks   = chunks,  -- nil for raw .tar.gz
		entries  = entries,
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
		local candidates = {
			relpath .. ".lua",
			relpath .. "/init.lua",
		}
		for _, candidate in ipairs(candidates) do
			local src = tar.get(entries, candidate)
			if src then
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

-- run_entry(app, entry_key, env, opts?) -> ok, result | err
-- Looks up entry_key in app.manifest.entry, finds the file in app.entries,
-- injects a tar-backed require loader into env, and runs the entrypoint.
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

	local src = tar.get(app.entries, entry_path)
	if not src then
		return false, "platform: entry file '" .. tostring(entry_path) .. "' not found in tarball"
	end

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
	local app, err = M.load_app(path)
	if not app then return false, err end
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
		build = function(decl, app) return require("lib.platform.caps.self").self_cap(app) end,
	},
	http_server = {
		mod = "lib.platform.caps.http_server",
		build = function(decl)
			return require("lib.platform.caps.http_server").http_server_cap({ port = decl.port or 0 })
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
		mod = "lib.platform.caps.kv",  -- fallback to kv until db.lua exists
		build = function(decl, app, context, data_path)
			-- Use dedicated db cap if it exists, otherwise fall back to kv
			local ok, db_mod = pcall(require, "lib.platform.caps.db")
			if ok and db_mod.db_cap then
				return db_mod.db_cap(data_path)
			end
			return require("lib.platform.caps.kv").kv_cap(data_path)
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

-- make_caps(app, cap_declarations, operator_grants, context)
--   -> caps_table, revoke_fns_table
--   or nil, err
--
-- cap_declarations: { cap_name = { type=string, required=bool, ...}, ... }
-- operator_grants:  { cap_name = true, ... }
-- context:          { user_id=string, app_id=string, data_dir=string }
function M.make_caps(app, cap_declarations, operator_grants, context)
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
			local factory = CAP_FACTORIES[cap_type]
			if not factory then
				if required then
					return nil, "platform: unknown cap type '" .. cap_type .. "' for cap '" .. name .. "'"
				end
				-- unknown optional cap type: skip
			else
				-- Resolve data path for storage caps
				local data_path
				if cap_type == "kv" or cap_type == "db" then
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
	local app, err = M.load_app(path)
	if not app then return false, err end

	-- Merge top-level and per-entry cap declarations
	local manifest = app.manifest or {}
	local cap_declarations = {}

	-- Top-level caps
	if manifest.caps then
		for name, decl in pairs(manifest.caps) do
			cap_declarations[name] = decl
		end
	end

	-- Per-entry caps (override/merge with top-level)
	local entry_map = manifest.entry or {}
	local entry_def = entry_map[entry_key]
	if type(entry_def) == "table" and entry_def.caps then
		for name, decl in pairs(entry_def.caps) do
			cap_declarations[name] = decl
		end
	end

	-- Default context fields from manifest
	if not context.app_id then
		context.app_id = manifest.name or "unknown"
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

	-- Build sandbox env: stdlib + caps as globals
	local cap_bundle = { globals = caps, modules = {} }
	local env = sandbox.env(sandbox.stdlib, cap_bundle)

	-- Run
	local ok, result = M.run_entry(app, entry_key, env, opts.sandbox_opts)
	return ok, result, revoke_fns
end

return M
