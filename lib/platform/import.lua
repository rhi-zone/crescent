-- lib/platform/import.lua
-- App import: bundle a card PNG with the card app runtime and install it.
--
-- The card PNG already has a `chara` tEXt chunk (base64 JSON, CCv2 format).
-- Import adds:
--   - `lua` iTXt chunk: base64(gzip(tar)) containing the card app runtime
--   - `lua-manifest` iTXt chunk: raw JSON manifest with card metadata in meta
-- The original image data and chara chunk are untouched.
--
-- API:
--   M.import_card(opts)  -> app_path, manifest | nil, err
--
-- opts:
--   png_bytes: string        — raw PNG bytes of the card
--   runtime_files: table[]   — { name, data }[] of card app runtime files
--   runtime_manifest: table  — base manifest from runtime (has entry, caps, etc.)
--   apps_dir: string         — directory to install to (e.g. ~/.crescent/apps)
--   index: table             — index database (from lib/platform/index)
--   timestamp: number        — unix timestamp for install
--   write_fn: (path, data) -> true | nil, err  — file writer

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local png = require("lib.png")
local tar = require("lib.tar")
local compress = require("lib.compress")
local base64 = require("lib.base64")
local json_mod = require("lib.format.json")

local M = {}

-- ── Card metadata extraction ────────────────────────────────────────────────

-- Extract metadata from a CCv2 chara tEXt chunk.
--: (string) -> table | nil, string
local function extract_card_meta(png_bytes)
	local chunks, err = png.read(png_bytes)
	if not chunks then return nil, "import: PNG parse failed: " .. tostring(err) end

	local raw = png.get_text(chunks, "chara")
	if not raw then return nil, "import: PNG has no 'chara' tEXt chunk" end

	local decoded, b64err = base64.decode(raw)
	if not decoded then return nil, "import: chara base64 decode failed: " .. tostring(b64err) end

	local ok, card = pcall(json_mod.decode, decoded)
	if not ok or type(card) ~= "table" then return nil, "import: chara JSON parse failed" end

	-- CCv2 wraps data under .data; some formats use top-level.
	local data = card.data or card

	local meta = {
		name = data.name or nil,
		description = (data.description or ""):sub(1, 500),  -- truncate for index
		tags = {},
	}

	-- Merge card tags if present.
	if type(data.tags) == "table" then
		for _, t in ipairs(data.tags) do
			meta.tags[#meta.tags + 1] = t
		end
	end

	return meta, chunks
end

-- ── Bundle ──────────────────────────────────────────────────────────────────

-- Build a tarball from runtime files + manifest, gzip, base64.
--: (table[], table) -> string | nil, string
local function bundle_runtime(runtime_files, manifest)
	-- Add manifest.json to the tarball entries.
	local entries = {}
	entries[#entries + 1] = {
		name = "manifest.json",
		data = json_mod.encode(manifest),
	}
	for _, f in ipairs(runtime_files) do
		entries[#entries + 1] = { name = f.name, data = f.data }
	end

	local tardata, terr = tar.write(entries)
	if not tardata then return nil, "import: tar write failed: " .. tostring(terr) end

	local gz, cerr = compress.deflate(tardata, { format = "gzip" })
	if not gz then return nil, "import: gzip compress failed: " .. tostring(cerr) end

	return base64.encode(gz)
end

-- ── Import ──────────────────────────────────────────────────────────────────

--: (table) -> string, table | nil, string
function M.import_card(opts)
	if not opts then return nil, "import: opts required" end
	if not opts.png_bytes then return nil, "import: png_bytes required" end
	if not opts.runtime_files then return nil, "import: runtime_files required" end
	if not opts.runtime_manifest then return nil, "import: runtime_manifest required" end
	if not opts.apps_dir then return nil, "import: apps_dir required" end
	if not opts.write_fn then return nil, "import: write_fn required" end
	if not opts.timestamp then return nil, "import: timestamp required" end

	-- 1. Extract card metadata from chara chunk.
	local card_meta, chunks_or_err = extract_card_meta(opts.png_bytes)
	if not card_meta then return nil, chunks_or_err end
	local chunks = chunks_or_err

	-- 2. Build manifest: merge runtime manifest + card metadata.
	local manifest = {}
	for k, v in pairs(opts.runtime_manifest) do
		manifest[k] = v
	end
	manifest.name = card_meta.name or manifest.name or "Unknown Card"

	-- Build meta: keep runtime tags, add card-specific tags and metadata.
	local runtime_meta = manifest.meta or {}
	local runtime_tags = runtime_meta.tags or {}
	local all_tags = {}
	local seen = {}
	for _, t in ipairs(runtime_tags) do
		if not seen[t] then
			all_tags[#all_tags + 1] = t
			seen[t] = true
		end
	end
	for _, t in ipairs(card_meta.tags) do
		if not seen[t] then
			all_tags[#all_tags + 1] = t
			seen[t] = true
		end
	end
	manifest.meta = {
		tags = all_tags,
		name = card_meta.name,
		description = card_meta.description,
	}

	-- 3. Bundle runtime files into tarball.
	local lua_data, berr = bundle_runtime(opts.runtime_files, manifest)
	if not lua_data then return nil, berr end

	-- 4. Add iTXt chunks to the PNG.
	local manifest_json = json_mod.encode(manifest)
	chunks = png.set_itxt(chunks, "lua", lua_data)
	chunks = png.set_itxt(chunks, "lua-manifest", manifest_json)

	-- 5. Write the app PNG.
	local out_bytes = png.write(chunks)
	-- Sanitize filename from card name.
	local safe_name = (card_meta.name or "card"):gsub("[^%w._-]", "_"):sub(1, 100)
	local app_filename = safe_name .. ".png"
	local app_path = opts.apps_dir .. "/" .. app_filename

	local ok, werr = opts.write_fn(app_path, out_bytes)
	if not ok then return nil, "import: write failed: " .. tostring(werr) end

	-- 6. Index the app.
	if opts.index then
		local id, ierr = opts.index:install(app_path, manifest, opts.timestamp)
		if not id then return nil, "import: index failed: " .. tostring(ierr) end
	end

	return app_path, manifest
end

-- ── Utility: extract_card_meta (exposed for testing) ────────────────────────

M._extract_card_meta = extract_card_meta

return M
