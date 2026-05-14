-- lib/platform/caps/create_instance.lua
-- create_instance_cap(app_info, opts) -> cap_table, revoke_fn
--
-- Lets a sandboxed app spawn a new instance of itself by handing the platform
-- a bytes payload (e.g. a card PNG) along with the calling app's own runtime
-- (lua iTXt chunk + manifest, extracted from its installed tarball) and
-- delegating to the existing import pipeline. The new instance gets installed
-- under apps_dir and indexed; the cap returns (app_id, launch_url).
--
-- Why this is a platform cap rather than app code: import requires write_fn,
-- apps_dir, the index handle, and a clock — all things the daemon owns. The
-- alternative is a cross-origin HTTP roundtrip from app subdomain to daemon
-- (different origin, blocked by SameSite cookies) — which is why this cap
-- exists in the first place.
--
-- Format-agnosticism: the cap does NOT inspect `bytes`. It just calls
-- import_card with bytes + the runtime extracted from the calling app. CCv2
-- fits because its PNGs already carry a `chara` chunk that import_card reads
-- for metadata. Future formats may need their own variants, but anything whose
-- distributed file already contains the metadata import_card expects works as
-- a drop-in.
--
-- Capability API:
--   cap.create(bytes) -> (app_id, launch_url) | (nil, err)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local png      = require("lib.png")
local tar      = require("lib.tar")
local base64   = require("lib.base64")
local compress = require("lib.compress")
local json_mod = require("lib.format.json")

local M = {}

--:: CreateInstanceImportOpts = { png_bytes: string, runtime_files: { [integer]: { name: string, data: string } }, runtime_manifest: unknown, apps_dir: string, write_fn: (string, string) -> (true | nil, string | nil), index: unknown, timestamp: integer }

-- extract_runtime(app_path) -> (runtime_files, runtime_manifest) | (nil, err)
--
-- Reads the calling app's installed file (PNG/JPEG/WebP or raw .tar.gz),
-- unpacks the embedded tarball, and returns:
--   - runtime_files: { name, data }[] for every regular file in the tarball
--     EXCEPT manifest.json (import_card adds its own manifest at the top of
--     the tarball it builds; the entry list it merges with new card metadata
--     comes from runtime_manifest).
--   - runtime_manifest: the parsed manifest table read from manifest.json
--
-- This is the reverse of import.lua's bundle_runtime. The fast path (lua-manifest
-- iTXt chunk) is intentionally NOT used here — we need the in-tarball files
-- anyway, so we always go through the full tarball decode.
--: (string) -> ({ [integer]: { name: string, data: string } } | nil, unknown | nil)
local function extract_runtime(app_path)
	local f, ferr = io.open(app_path, "rb")
	if not f then return nil, "extract_runtime: open failed: " .. tostring(ferr) end
	local bytes = f:read("*a")
	f:close()
	if not bytes then return nil, "extract_runtime: read failed" end

	local tardata --: string | nil
	local magic4 = bytes:sub(1, 4)
	if magic4 == "\x89PNG" then
		local chunks, perr = png.read(bytes)
		if not chunks then return nil, "extract_runtime: PNG parse: " .. tostring(perr) end
		local lua_b64 = png.get_itxt(chunks --[[:! { [integer]: { type: string, data: string, ... } }]], "lua")
		if not lua_b64 then return nil, "extract_runtime: PNG has no 'lua' iTXt chunk" end
		local gz, b64err = base64.decode(lua_b64)
		if not gz then return nil, "extract_runtime: base64 decode: " .. tostring(b64err) end
		local td, cerr = compress.inflate(gz, { format = "gzip" })
		if not td then return nil, "extract_runtime: gzip inflate: " .. tostring(cerr) end
		tardata = td
	elseif bytes:sub(1, 2) == "\x1f\x8b" then
		-- Raw .tar.gz on disk.
		local td, cerr = compress.inflate(bytes, { format = "gzip" })
		if not td then return nil, "extract_runtime: gzip inflate: " .. tostring(cerr) end
		tardata = td
	else
		return nil, "extract_runtime: unrecognized app file format"
	end

	local entries, terr = tar.read(tardata)
	if not entries then return nil, "extract_runtime: tar read: " .. tostring(terr) end

	local manifest_src --: string | nil
	local runtime_files = {} --: { [integer]: { name: string, data: string } }
	for i = 1, #entries do
		local e = entries[i]
		local name = e.name
		-- Skip directories (typeflag "5") and any non-regular entries.
		if e.typeflag == nil or e.typeflag == "" or e.typeflag == "0" then
			if name == "manifest.json" then
				manifest_src = e.data
			else
				runtime_files[#runtime_files + 1] = { name = name, data = e.data }
			end
		end
	end

	if not manifest_src then return nil, "extract_runtime: tarball has no manifest.json" end

	local manifest_raw, jerr = json_mod.decode(manifest_src)
	if not manifest_raw then return nil, "extract_runtime: manifest.json parse: " .. tostring(jerr) end

	return runtime_files, manifest_raw
end

M._extract_runtime = extract_runtime

-- create_instance_cap(app_info, opts) -> cap_table, revoke_fn
--
-- app_info: { path: string }   — calling app's installed file path
-- opts: {
--   apps_dir   : string,
--   write_fn   : (path, data) -> (true | nil, err),
--   index_obj  : index handle (must support :list() and be the same one passed
--                to import_card so the install gets indexed),
--   time_fn    : () -> integer,
--   audit_log? : { append: (self, event, data) -> ... },
-- }
--:: CreateInstanceIndex = { list: (unknown) -> { [integer]: { id: integer, path: string, ... } }, install: (unknown, string, unknown, integer) -> (integer | nil, string), ... }
--:: CreateInstanceCapOpts = { apps_dir: string, write_fn: (string, string) -> (true | nil, string | nil), index_obj: CreateInstanceIndex, time_fn: () -> integer, audit_log: { append: (unknown, string, unknown) -> unknown } | nil, ... }
--:: CreateInstanceCapTable = { _type: "create_instance", create: (string) -> (integer | nil, string), _set_import_card: ((unknown) -> nil) | nil }
--: ({ path: string, ... }, CreateInstanceCapOpts) -> (CreateInstanceCapTable, () -> nil)
function M.create_instance_cap(app_info, opts)
	local revoked = false

	if not app_info or not app_info.path then
		error("create_instance_cap: app_info.path is required")
	end
	if not opts or not opts.apps_dir or not opts.write_fn or not opts.index_obj or not opts.time_fn then
		error("create_instance_cap: opts.apps_dir, write_fn, index_obj, time_fn all required")
	end

	-- Resolved at cap-construction time (the path is the installed app file).
	local app_path = app_info.path
	local apps_dir = opts.apps_dir
	local write_fn = opts.write_fn
	local index_obj = opts.index_obj
	local time_fn = opts.time_fn
	local audit_log = opts.audit_log

	-- import_card is loaded lazily so unit tests can inject a fake via _set_import_card.
	local import_card_fn --: unknown

	local cap = {
		_type = "create_instance",

		--: (string) -> (integer | nil, string)
		create = function(bytes)
			if revoked then return nil, "capability revoked" end
			if type(bytes) ~= "string" or #bytes < 4 then
				return nil, "create_instance.create: bytes required"
			end

			local runtime_files, runtime_manifest = extract_runtime(app_path)
			if not runtime_files then
				return nil, "create_instance.create: " .. tostring(runtime_manifest)
			end

			if not import_card_fn then
				import_card_fn = (require("lib.platform.import")).import_card
			end

			local ic = import_card_fn --[[:! (CreateInstanceImportOpts) -> (string | nil, unknown)]]
			local new_path, manifest_or_err = ic({
				png_bytes        = bytes,
				runtime_files    = runtime_files,
				runtime_manifest = runtime_manifest,
				apps_dir         = apps_dir,
				write_fn         = write_fn,
				index            = index_obj,
				timestamp        = time_fn(),
			})
			if not new_path then
				return nil, "create_instance.create: " .. tostring(manifest_or_err)
			end

			-- Locate the new app's id by path.
			local new_app_id
			local rows = index_obj:list()
			for i = 1, #rows do
				if rows[i].path == new_path then
					new_app_id = rows[i].id
					break
				end
			end
			if not new_app_id then
				return nil, "create_instance.create: imported but not indexed"
			end

			if audit_log then
				audit_log:append("app_install", {
					app_id  = tostring(new_app_id),
					name    = new_path,
					via_cap = "create_instance",
				})
			end

			return new_app_id, "/launch/" .. tostring(new_app_id)
		end,
	}

	local function revoke() revoked = true end

	-- Test seam: inject a fake import_card.
	--: (unknown) -> nil
	cap._set_import_card = function(fn) import_card_fn = fn end

	return cap, revoke
end

function M.risk(_decl)
	return {
		severity = "medium",
		text = "Installs a new app instance using the calling app's own runtime. The new instance becomes a separate sandboxed app with its own grants.",
	}
end

return M
