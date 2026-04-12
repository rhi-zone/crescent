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

return M
