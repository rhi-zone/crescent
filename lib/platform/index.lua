-- lib/platform/index.lua
-- App index database: SQLite-backed index of installed apps.
-- The library app queries this to discover, filter, and search installed apps.
--
-- API:
--   M.open(db_path)                    -> index | nil, err
--   index:install(app_path, manifest)  -> id | nil, err
--   index:uninstall(id)                -> true | nil, err
--   index:get(id)                      -> row | nil
--   index:list(filter?)                -> rows[]
--   index:search(query)                -> rows[]
--   index:close()                      -> true | nil, err
--
-- Row fields: id, name, path, manifest_json, tags_json, installed_at

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local sqlite = require("lib.sqlite")
local json = require("lib.format.json")

local M = {}

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS apps (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	name TEXT NOT NULL,
	path TEXT NOT NULL UNIQUE,
	manifest_json TEXT NOT NULL,
	tags_json TEXT NOT NULL DEFAULT '[]',
	installed_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_apps_name ON apps(name);
CREATE INDEX IF NOT EXISTS idx_apps_path ON apps(path);
]]

local index_mt = { __index = {} }
local I = index_mt.__index

-- ── Open / close ────────────────────────────────────────────────────────────

--: (string) -> table | (nil, string)
function M.open(db_path)
	local db, err = sqlite.open(db_path)
	if not db then return nil, err end
	local ok, serr = db:execute(SCHEMA)
	if not ok then return nil, "index: schema init failed: " .. tostring(serr) end
	return setmetatable({ _db = db }, index_mt)
end

--: () -> true | (nil, string)
function I:close()
	return self._db:close()
end

-- ── Install ─────────────────────────────────────────────────────────────────

-- Install or update an app in the index.
-- If an app with the same path exists, it is replaced.
--: (string, table, number) -> number | (nil, string)
function I:install(app_path, manifest, timestamp)
	if not app_path or app_path == "" then
		return nil, "index: app_path is required"
	end
	if type(manifest) ~= "table" then
		return nil, "index: manifest must be a table"
	end
	if not timestamp then
		return nil, "index: timestamp is required"
	end

	local name = manifest.name or app_path:match("([^/]+)%.%w+$") or "unknown"
	local manifest_str = json.encode(manifest)
	local meta = manifest.meta or {}
	local tags = meta.tags or {}
	local tags_str = json.encode(tags)

	-- Upsert: replace on path conflict.
	local ok, err = self._db:execute(
		"INSERT OR REPLACE INTO apps (name, path, manifest_json, tags_json, installed_at) VALUES (?, ?, ?, ?, ?)",
		name, app_path, manifest_str, tags_str, timestamp
	)
	if not ok then return nil, "index: insert failed: " .. tostring(err) end

	-- Return the id of the inserted/replaced row.
	local iter = self._db:query("SELECT last_insert_rowid()")
	if iter then
		local id = iter()
		return id
	end
	return nil, "index: failed to get inserted id"
end

-- ── Uninstall ───────────────────────────────────────────────────────────────

--: (number) -> true | (nil, string)
function I:uninstall(id)
	local ok, err = self._db:execute("DELETE FROM apps WHERE id = ?", id)
	if not ok then return nil, "index: delete failed: " .. tostring(err) end
	return true
end

-- ── Query ───────────────────────────────────────────────────────────────────

-- Parse a row from the query iterator into a table.
--: (number, string, string, string, string, number) -> table
local function row_from_query(id, name, path, manifest_json, tags_json, installed_at)
	return {
		id = id,
		name = name,
		path = path,
		manifest_json = manifest_json,
		manifest = json.decode(manifest_json),
		tags_json = tags_json,
		tags = json.decode(tags_json) or {},
		installed_at = installed_at,
	}
end

-- Get a single app by id.
--: (number) -> table | nil
function I:get(id)
	local iter, err = self._db:query(
		"SELECT id, name, path, manifest_json, tags_json, installed_at FROM apps WHERE id = ?", id
	)
	if not iter then return nil end
	local rid, rname, rpath, rmanifest, rtags, rat = iter()
	if not rid then return nil end
	return row_from_query(rid, rname, rpath, rmanifest, rtags, rat)
end

-- List all apps, optionally filtered by tag.
--: (table?) -> table[]
function I:list(filter)
	local sql = "SELECT id, name, path, manifest_json, tags_json, installed_at FROM apps"
	local args = {}

	if filter and filter.tag then
		-- json_each over tags_json to find matching tag.
		sql = sql .. " WHERE EXISTS (SELECT 1 FROM json_each(apps.tags_json) WHERE json_each.value = ?)"
		args[1] = filter.tag
	end

	sql = sql .. " ORDER BY name ASC"

	local iter, err = self._db:query(sql, unpack(args))
	if not iter then return {} end

	local results = {}
	while true do
		local id, name, path, manifest_json, tags_json, installed_at = iter()
		if not id then break end
		results[#results + 1] = row_from_query(id, name, path, manifest_json, tags_json, installed_at)
	end
	return results
end

-- Full-text search on name (LIKE match).
--: (string) -> table[]
function I:search(query)
	local iter, err = self._db:query(
		"SELECT id, name, path, manifest_json, tags_json, installed_at FROM apps WHERE name LIKE ? ORDER BY name ASC",
		"%" .. query .. "%"
	)
	if not iter then return {} end

	local results = {}
	while true do
		local id, name, path, manifest_json, tags_json, installed_at = iter()
		if not id then break end
		results[#results + 1] = row_from_query(id, name, path, manifest_json, tags_json, installed_at)
	end
	return results
end

return M
