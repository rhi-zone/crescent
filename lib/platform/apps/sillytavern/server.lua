-- lib/platform/apps/sillytavern/server.lua
-- SillyTavern source adapter — exposes GET /discover for the library's
-- per-source section model.
--
-- Reads ~/SillyTavern/public/characters/ in place; no import or conversion.
-- Card metadata (name, description, tags) is read from CCv2 iTXt chunks and
-- cached in caps.meta_cache (SQLite) by filename. Cache is populated lazily:
-- on each /discover call we read metadata for any uncached files in the
-- requested page. Cache persists across daemon restarts; no auto-invalidation
-- (cards edited in ST won't update until cache is cleared or the entry is
-- explicitly dropped). This trades freshness for the perf win of not scanning
-- all PNGs on every request.
--
-- Discovery protocol (GET /discover):
--   Query params: q (substring search on cached name, falls back to filename),
--                 limit (default 200, max 500), offset (default 0)
--   Response: { source_name, total, limit, offset, entries: [entry] }
--   entry: { id, name, description, tags, thumb_url }
--
-- Caps:
--   caps.characters — readonly fs (root = ~/SillyTavern/public/characters)
--   caps.meta_cache — writable SQLite for metadata caching (optional)

if package and not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json")
local card_mod = require("lib.formats.ccv2.card")

local M = {}

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS card_meta (
  filename    TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  description TEXT,
  tags_json   TEXT,
  cached_at   INTEGER NOT NULL
);
]]

-- ── Query string parser ────────────────────────────────────────────────────

--: (string | nil) -> { [string]: string }
local function parse_query(qs)
	local params = {} --: { [string]: string }
	if not qs or qs == "" then return params end
	for kv in qs:gmatch("[^&]+") do
		local k, v = kv:match("^([^=]+)=?(.*)")
		if k then
			v = v:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
			v = v:gsub("+", " ")
			params[k] = v
		end
	end
	return params
end

-- ── Helpers ────────────────────────────────────────────────────────────────

--: (string) -> string
local function name_from_file(filename)
	return filename:match("^(.+)%.[^.]+$") or filename
end

--: (string, string | nil) -> boolean
local function matches(name, q)
	if not q or q == "" then return true end
	return name:lower():find(q:lower(), 1, true) ~= nil
end

--: (http_res, number, string) -> nil
local function plain(res, status, body)
	res.status = status
	res.headers["Content-Type"] = { "text/plain; charset=utf-8" }
	res.body = body
end

--: (http_res, unknown) -> true
local function json_ok(res, data)
	res.status = 200
	res.headers["Content-Type"] = { "application/json" }
	res.body = json.encode(data)
	return true
end

-- ── Metadata cache ─────────────────────────────────────────────────────────

-- Ensure the schema exists. Returns the db on success, nil on failure.
local function init_cache(db)
	if not db then return nil end
	local ok = db.execute(db, SCHEMA)
	if not ok then return nil end
	return db
end

-- Look up cached metadata for a batch of filenames.
-- Returns { [filename]: { name, description, tags } }.
local function cache_lookup(db, filenames)
	if not db or #filenames == 0 then return {} end
	local result = {}
	for i = 1, #filenames do
		local f = filenames[i]
		local ok, iter = pcall(db.query, db,
			"SELECT name, description, tags_json FROM card_meta WHERE filename = ?", f)
		if ok and iter then
			local name, desc, tags_json = iter()
			if name then
				result[f] = {
					name        = name,
					description = desc,
					tags        = json.decode(tags_json) or {},
				}
			end
		end
	end
	return result
end

-- Read metadata from a PNG file. Returns { name, description, tags } or nil.
local function read_card_meta(fs, filename)
	local bytes, err = fs.read(filename)
	if not bytes then return nil end
	local data, cerr = card_mod.from_png(bytes)
	if not data then return nil end
	return {
		name        = data.name or name_from_file(filename),
		description = data.description,
		tags        = data.tags or {},
	}
end

-- Populate cache for any filenames not yet present.
-- Returns the enriched { [filename]: meta } map (hit + newly read).
local function ensure_cached(db, fs, filenames)
	local cached = cache_lookup(db, filenames)
	local now = os.time()
	for i = 1, #filenames do
		local f = filenames[i]
		if not cached[f] then
			local meta = read_card_meta(fs, f)
			if meta and db then
				pcall(db.execute, db,
					"INSERT OR REPLACE INTO card_meta (filename, name, description, tags_json, cached_at) VALUES (?, ?, ?, ?, ?)",
					f, meta.name, meta.description or "", json.encode(meta.tags), now)
			end
			cached[f] = meta or { name = name_from_file(f), description = nil, tags = {} }
		end
	end
	return cached
end

-- ── Handler ────────────────────────────────────────────────────────────────

function M.create(caps)
	local fs = caps.characters
	local db = init_cache(caps.meta_cache)

	--: (http_req, http_res) -> nil
	local function handler(req, res)
		local path   = req.path   or "/"
		local method = req.method or "GET"

		if method ~= "GET" then
			plain(res, 405, "method not allowed")
			return
		end

		if not path:find("^/discover") then
			plain(res, 404, "not found")
			return
		end

		local qs = req.query or path:match("%?(.+)$")
		local params = parse_query(qs)
		local q       = params.q
		local limit   = math.max(1, math.min(500, tonumber(params.limit)  or 200))
		local offset  = math.max(0,               tonumber(params.offset) or 0)

		-- List the characters directory.
		local files, err = fs.list(".")
		if not files then
			json_ok(res, {
				source_name = "SillyTavern",
				total = 0, limit = limit, offset = offset, entries = {},
				error = "characters directory unavailable: " .. tostring(err),
			})
			return
		end

		-- Filter to image files; derive initial name from filename for list/sort.
		local candidates = {} --: { [integer]: { id: string, sort_key: string } }
		for i = 1, #files do
			local f = files[i]
			local ext = f:lower():match("%.([^.]+)$")
			if ext == "png" or ext == "webp" or ext == "jpeg" or ext == "jpg" then
				candidates[#candidates + 1] = { id = f, sort_key = name_from_file(f):lower() }
			end
		end

		-- Sort alphabetically by derived name for stable pagination.
		table.sort(candidates, function(a, b) return a.sort_key < b.sort_key end)

		-- Pre-filter by query on the filename-derived name (fast, no file I/O).
		-- The cached name is used if available but we can't guarantee all files are
		-- cached at filter time. Full-metadata search requires a full cache scan,
		-- which is a future optimisation; for now, filename match is the search key.
		local matched = {}
		for i = 1, #candidates do
			if matches(candidates[i].sort_key, q) then
				matched[#matched + 1] = candidates[i].id
			end
		end

		local total = #matched

		-- Slice the page.
		local page_files = {}
		local stop = math.min(offset + limit, total)
		for i = offset + 1, stop do
			page_files[#page_files + 1] = matched[i]
		end

		-- Populate metadata cache for this page (reads only uncached PNGs).
		local meta = ensure_cached(db, fs, page_files)

		-- Build the entries array.
		local entries = {}
		for i = 1, #page_files do
			local f = page_files[i]
			local m = meta[f] or { name = name_from_file(f), description = nil, tags = {} }
			entries[#entries + 1] = {
				id          = f,
				name        = m.name,
				description = m.description,
				tags        = m.tags,
				thumb_url   = nil,
			}
		end

		json_ok(res, {
			source_name = "SillyTavern",
			total   = total,
			limit   = limit,
			offset  = offset,
			entries = entries,
		})
	end

	return { handler = handler }
end

-- Expose for testing.
M._parse_query    = parse_query
M._name_from_file = name_from_file
M._matches        = matches
M._init_cache     = init_cache
M._ensure_cached  = ensure_cached

return M
