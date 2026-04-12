-- lib/platform/init.lua
-- Platform runner: load a card (PNG file), extract its script chunk, run sandboxed.
--
-- A "card" is a PNG file with:
--   "script" tEXt chunk — Lua code to run (required)
--   "data"   tEXt chunk — structured content the script reads via caps.png (optional)
--   any other tEXt/zTXt chunks the script declares it needs
--
-- A "self-contained app" is a PNG file with:
--   "lua" iTXt chunk — base64(gzip(tar)) containing manifest.json + Lua files
--
-- API:
--   platform.load_card(path)                          -> card | nil, err
--   platform.run_card(card, env, opts?)               -> ok, result | err
--   platform.load_and_run(path, env, opts?)           -> ok, result | err
--   platform.load_app(path)                           -> app | nil, err
--   platform.run_entry(app, entry_key, env, opts?)    -> ok, result | err
--   platform.load_and_run_entry(path, entry_key, env, opts?) -> ok, result | err
--   platform.caps.png                 -> require("lib.platform.caps.png")
--   platform.caps.llm                 -> require("lib.platform.caps.llm")
--   platform.caps.render              -> require("lib.platform.caps.render")
--   platform.caps.fs                  -> require("lib.platform.caps.fs")
--
-- card fields:
--   card.path   : string
--   card.chunks : png chunk array  (pass to png_cap if the script needs chunk access)
--   card.script : string           (the Lua source from "script" tEXt chunk)
--   card.data   : string | nil     (from "data" tEXt chunk, if present)
--
-- app fields:
--   app.path     : string
--   app.chunks   : png chunk array
--   app.entries  : TarEntry[]      (all files in the tarball)
--   app.manifest : table           (parsed manifest.json: name, version, entry)
--
-- Typical usage:
--   local platform = require("lib.platform")
--   local sandbox  = require("lib.sandbox")
--   local render   = require("lib.platform.caps.render")
--   local llm_mod  = require("lib.platform.caps.llm")
--
--   local session, get_output = render.collect_session()
--   local env = sandbox.env(
--     sandbox.stdlib,
--     { globals = {
--       llm    = llm_mod.llm_cap({ endpoint = "http://localhost:8000", model = "gemma3" }),
--       render = render.render_cap(session),
--       png    = require("lib.platform.caps.png").png_cap(path, { allow = {"chara","crescent"} }),
--     }}
--   )
--   local ok, result = platform.load_and_run("card.png", env)

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
				-- compression_flag at sep+1, compression_method at sep+2
				-- language_tag starts at sep+3, ends at next NUL
				-- translated_keyword ends at next NUL after that
				-- text starts after the second NUL past sep+2
				local compression_flag = data:byte(sep + 1)
				if compression_flag ~= 0 then
					return nil  -- compressed iTXt not supported here
				end
				-- skip: sep+1 (flag) + sep+2 (method) + language_tag\0 + translated_keyword\0
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

-- load_card(path) -> card | nil, err
-- Reads a PNG file and extracts the script (required) and data (optional) chunks.
function M.load_card(path)
	local f, err = io.open(path, "rb")
	if not f then return nil, "platform: cannot open " .. tostring(path) .. ": " .. tostring(err) end
	local bytes = f:read("*a")
	f:close()

	local chunks, perr = png.read(bytes)
	if not chunks then return nil, "platform: PNG parse failed: " .. tostring(perr) end

	local script = png.get_text(chunks, "script")
	if not script then return nil, "platform: card has no 'script' tEXt chunk" end

	return {
		path   = path,
		chunks = chunks,
		script = script,
		data   = png.get_text(chunks, "data"),
	}
end

-- run_card(card, env, opts?) -> ok, result | err
-- Runs card.script inside the given sandbox environment.
-- opts.budget: instruction limit (via debug.sethook)
-- opts.name  : chunk name in error messages (default "@<path>")
function M.run_card(card, env, opts)
	opts = opts or {}
	opts.name = opts.name or ("@" .. tostring(card.path))
	return sandbox.run(card.script, env, opts)
end

-- load_and_run(path, env, opts?) -> ok, result | err
-- Convenience: load_card + run_card in one call.
function M.load_and_run(path, env, opts)
	local card, err = M.load_card(path)
	if not card then return false, err end
	-- FIXME: typechecker: does not narrow `card` to non-nil in function call
	-- arguments even after `if not card then return end`. Use direct field access
	-- to bypass the nil branch instead of delegating to run_card.
	opts = opts or {}
	opts.name = opts.name or ("@" .. tostring(card.path))
	return sandbox.run(card.script, env, opts)
end

-- ── App API (self-contained tar-based cards) ──────────────────────────────────

-- load_app(path) -> app | nil, err
-- Reads a PNG, extracts the "lua" iTXt chunk (base64 gzip tar),
-- unpacks the tarball, parses manifest.json, and returns an app table.
function M.load_app(path)
	local f, err = io.open(path, "rb")
	if not f then return nil, "platform: cannot open " .. tostring(path) .. ": " .. tostring(err) end
	local bytes = f:read("*a")
	f:close()

	local chunks, perr = png.read(bytes)
	if not chunks then return nil, "platform: PNG parse failed: " .. tostring(perr) end

	local raw = get_itxt(chunks, "lua")
	if not raw then return nil, "platform: card has no 'lua' iTXt chunk" end

	local gz, berr = base64.decode(raw)
	if not gz then return nil, "platform: base64 decode failed: " .. tostring(berr) end

	local tardata, cerr = compress.inflate(gz, { format = "gzip" })
	if not tardata then return nil, "platform: gzip decompress failed: " .. tostring(cerr) end

	local entries, terr = tar.read(tardata)
	if not entries then return nil, "platform: tar unpack failed: " .. tostring(terr) end

	local manifest_src = tar.get(entries, "manifest.json")
	if not manifest_src then return nil, "platform: tarball has no manifest.json" end

	local manifest, jerr = json.decode(manifest_src)
	if not manifest then return nil, "platform: manifest.json parse failed: " .. tostring(jerr) end

	return {
		path     = path,
		chunks   = chunks,
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
		-- Convert "foo.bar.baz" -> "foo/bar/baz.lua" and "foo/bar/baz/init.lua"
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
	local entry_path = entry_map[entry_key]
	if not entry_path then
		return false, "platform: no entry '" .. tostring(entry_key) .. "' in manifest"
	end

	local src = tar.get(app.entries, entry_path)
	if not src then
		return false, "platform: entry file '" .. tostring(entry_path) .. "' not found in tarball"
	end

	-- Inject tar-backed loader into env at index 2 (before file loaders).
	-- We extend env with a custom package table that routes require through the tarball.
	opts = opts or {}
	opts.name = opts.name or ("@" .. tostring(entry_path))

	-- Build an env copy with a tarball-aware require replacing the sandbox require.
	-- The tarball loader is injected first; if it misses it falls through to the
	-- existing sandbox require (which enforces the module allowlist).
	local tar_loader = make_tar_loader(app.entries)
	local base_require = env.require  -- sandbox's whitelist require (may be nil)
	local function app_require(modname)
		local loader_or_err, detail = tar_loader(modname)
		if type(loader_or_err) == "function" then
			return loader_or_err()
		end
		-- miss: fall through to sandbox require if available
		if base_require then
			return base_require(modname)
		end
		error("platform: module '" .. tostring(modname) .. "' not found in app tarball", 2)
	end

	-- Shallow-copy env so we don't mutate the caller's table.
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

-- caps: lazy proxy for the four capability factory sub-modules.
-- platform.caps.png  → lib/platform/caps/png.lua
-- platform.caps.llm  → lib/platform/caps/llm.lua
-- platform.caps.render → lib/platform/caps/render.lua
-- platform.caps.fs   → lib/platform/caps/fs.lua
M.caps = setmetatable({}, {
	__index = function (t, k)
		local ok, mod = pcall(require, "lib.platform.caps." .. k)
		if ok then t[k] = mod; return mod end
		return nil
	end,
})

return M
