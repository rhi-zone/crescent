-- lib/platform/index.lua
-- App index database: SQLite-backed index of installed apps.
-- The library app queries this to discover, filter, and search installed apps.
--
-- API:
--   M.open(db_path)                              -> index | nil, err
--   index:install(app_path, manifest)            -> id | nil, err
--   index:uninstall(id)                          -> true | nil, err
--   index:get(id)                                -> row | nil
--   index:list(filter?)                          -> rows[]
--   index:search(query)                          -> rows[]
--   index:get_cap_config(app_id, cap_name)       -> { [string]: unknown }
--   index:set_cap_config(app_id, cap_name, tbl)  -> true | nil, err
--   index:reset_cap_config(app_id, cap_name)     -> true | nil, err
--   index:get_grants(app_id)                     -> { [string]: boolean }
--   index:set_grant(app_id, cap_name, granted)   -> true | nil, err
--   index:clear_grants(app_id)                   -> true | nil, err
--   index:close()                                -> true | nil, err
--
-- Row fields: id, name, path, manifest_json, tags_json, installed_at

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local sqlite = require("lib.sqlite")
local json = require("lib.format.json")

local M = {}

-- Schema notes:
--  * `apps` holds one row per installed app. `tags_json` is kept for
--    round-tripping the raw manifest shape to callers; `app_tags` is the
--    source of truth for tag-based queries (indexed both ways).
--  * `tags` is a tag registry — one row per distinct tag name. Junk never
--    accumulates: uninstalling the last app with a given tag leaves the row
--    behind (cheap), but it'll be reused next time the same tag appears.
--  * `app_tags` is the join that makes "filter by tag" and "folder view"
--    (`GROUP BY tag_id`) trivial and fast — instead of scanning json_each
--    over every app's tag blob (ST's tag_map failure mode).
--  * `apps_fts` is a trigram FTS5 virtual table. Trigram gives us
--    case-insensitive substring search ("ali" finds "Alice") at sub-1ms over
--    tens of thousands of rows. Uses default (self-owned) content storage so
--    that plain DELETE works — contentless FTS5 tables (`content=''`) don't
--    support DELETE without the `contentless_delete=1` option (SQLite 3.43+),
--    which we don't rely on for portability. Kept in sync explicitly from
--    install/uninstall; no triggers since writes already go through one
--    code path.
--  * `app_cap_config` stores operator overrides for cap fields, keyed by
--    (app_id, cap_name). `overrides_json` is a flat JSON object merged over
--    the manifest cap declaration at cap construction time. Deleted with the
--    app row via explicit DELETE in uninstall (not FK cascade — SQLite FK
--    enforcement requires PRAGMA foreign_keys = ON per connection).
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

CREATE TABLE IF NOT EXISTS tags (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	name TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS app_tags (
	app_id INTEGER NOT NULL,
	tag_id INTEGER NOT NULL,
	PRIMARY KEY (app_id, tag_id)
);
CREATE INDEX IF NOT EXISTS idx_app_tags_tag_app ON app_tags(tag_id, app_id);

CREATE VIRTUAL TABLE IF NOT EXISTS apps_fts USING fts5(
	name, description, path, tokenize='trigram'
);

CREATE TABLE IF NOT EXISTS app_cap_config (
	app_id       INTEGER NOT NULL,
	cap_name     TEXT    NOT NULL,
	overrides_json TEXT  NOT NULL DEFAULT '{}',
	PRIMARY KEY (app_id, cap_name)
);

CREATE TABLE IF NOT EXISTS app_grants (
	app_id   INTEGER NOT NULL,
	cap_name TEXT    NOT NULL,
	granted  INTEGER NOT NULL,
	PRIMARY KEY (app_id, cap_name)
);
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

-- Look up an app's id by path, or nil if not installed.
--: (string) -> number | nil
local function id_for_path(db, app_path)
	local iter = db:query("SELECT id FROM apps WHERE path = ?", app_path)
	if not iter then return nil end
	return iter()
end

-- Sync the `app_tags` rows for an app against a fresh tag list. Cheap even
-- at large tag counts — the heavy lifting is the indexed DELETE + per-tag
-- INSERT OR IGNORE into the registry.
--: (unknown, number, { [integer]: string }) -> nil
local function sync_app_tags(db, app_id, tag_names)
	db:execute("DELETE FROM app_tags WHERE app_id = ?", app_id)
	for i = 1, #tag_names do
		local tname = tag_names[i]
		if type(tname) == "string" and tname ~= "" then
			db:execute("INSERT OR IGNORE INTO tags (name) VALUES (?)", tname)
			db:execute(
				"INSERT OR IGNORE INTO app_tags (app_id, tag_id) " ..
				"SELECT ?, id FROM tags WHERE name = ?", app_id, tname)
		end
	end
end

-- Sync the FTS5 row for an app. `content=''` FTS tables support DELETE by
-- rowid, so we delete-then-insert unconditionally for simplicity.
--: (unknown, number, string, string, string) -> nil
local function sync_apps_fts(db, app_id, name, description, app_path)
	db:execute("DELETE FROM apps_fts WHERE rowid = ?", app_id)
	db:execute(
		"INSERT INTO apps_fts (rowid, name, description, path) VALUES (?, ?, ?, ?)",
		app_id, name, description, app_path)
end

-- Install or update an app in the index.
-- If an app with the same path exists, its row is updated in place (id
-- preserved) so derived tables (app_tags, apps_fts) stay consistent. New
-- apps get a fresh id via INSERT.
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
	local description = meta.description or ""
	local tags_str = json.encode(tags)

	local db = self._db
	local existing_id = id_for_path(db, app_path)
	local app_id

	if existing_id then
		local ok, err = db:execute(
			"UPDATE apps SET name = ?, manifest_json = ?, tags_json = ?, installed_at = ? WHERE id = ?",
			name, manifest_str, tags_str, timestamp, existing_id
		)
		if not ok then return nil, "index: update failed: " .. tostring(err) end
		app_id = existing_id
	else
		local ok, err = db:execute(
			"INSERT INTO apps (name, path, manifest_json, tags_json, installed_at) VALUES (?, ?, ?, ?, ?)",
			name, app_path, manifest_str, tags_str, timestamp
		)
		if not ok then return nil, "index: insert failed: " .. tostring(err) end
		local iter = db:query("SELECT last_insert_rowid()")
		if not iter then return nil, "index: failed to get inserted id" end
		app_id = iter()
	end

	sync_app_tags(db, app_id, tags)
	sync_apps_fts(db, app_id, name, description, app_path)

	return app_id
end

-- ── Uninstall ───────────────────────────────────────────────────────────────

--: (number) -> true | (nil, string)
function I:uninstall(id)
	local db = self._db
	db:execute("DELETE FROM app_tags WHERE app_id = ?", id)
	db:execute("DELETE FROM apps_fts WHERE rowid = ?", id)
	db:execute("DELETE FROM app_cap_config WHERE app_id = ?", id)
	db:execute("DELETE FROM app_grants WHERE app_id = ?", id)
	local ok, err = db:execute("DELETE FROM apps WHERE id = ?", id)
	if not ok then return nil, "index: delete failed: " .. tostring(err) end
	return true
end

-- ── Cap config ──────────────────────────────────────────────────────────────

-- Return stored overrides for (app_id, cap_name) as a Lua table.
-- Returns an empty table if no overrides have been set.
--: (number, string) -> { [string]: unknown }
function I:get_cap_config(app_id, cap_name)
	local iter = self._db:query(
		"SELECT overrides_json FROM app_cap_config WHERE app_id = ? AND cap_name = ?",
		app_id, cap_name)
	if not iter then return {} end
	local raw = iter()
	if not raw then return {} end
	return json.decode(raw) or {}
end

-- Persist overrides for (app_id, cap_name). `overrides` must be a table;
-- its values are shallow-merged over manifest defaults at cap construction.
--: (number, string, { [string]: unknown }) -> true | (nil, string)
function I:set_cap_config(app_id, cap_name, overrides)
	if type(overrides) ~= "table" then
		return nil, "index: overrides must be a table"
	end
	local encoded = json.encode(overrides)
	local ok, err = self._db:execute(
		"INSERT OR REPLACE INTO app_cap_config (app_id, cap_name, overrides_json) VALUES (?, ?, ?)",
		app_id, cap_name, encoded)
	if not ok then return nil, "index: set_cap_config failed: " .. tostring(err) end
	return true
end

-- Remove all overrides for (app_id, cap_name), reverting to manifest defaults.
--: (number, string) -> true | (nil, string)
function I:reset_cap_config(app_id, cap_name)
	local ok, err = self._db:execute(
		"DELETE FROM app_cap_config WHERE app_id = ? AND cap_name = ?",
		app_id, cap_name)
	if not ok then return nil, "index: reset_cap_config failed: " .. tostring(err) end
	return true
end

-- ── Grants ─────────────────────────────────────────────────────────────────

-- Return stored grant decisions for app_id.
-- Only caps with an explicit decision are included; undecided caps are absent.
--: (number) -> { [string]: boolean }
function I:get_grants(app_id)
	local iter = self._db:query(
		"SELECT cap_name, granted FROM app_grants WHERE app_id = ?", app_id)
	if not iter then return {} end
	local result = {}
	while true do
		local cap_name, granted = iter()
		if not cap_name then break end
		result[cap_name] = granted ~= 0
	end
	return result
end

-- Persist a grant decision for (app_id, cap_name).
--: (number, string, boolean) -> true | (nil, string)
function I:set_grant(app_id, cap_name, granted)
	local ok, err = self._db:execute(
		"INSERT OR REPLACE INTO app_grants (app_id, cap_name, granted) VALUES (?, ?, ?)",
		app_id, cap_name, granted and 1 or 0)
	if not ok then return nil, "index: set_grant failed: " .. tostring(err) end
	return true
end

-- Remove all grant decisions for app_id (operator must re-grant on next launch).
--: (number) -> true | (nil, string)
function I:clear_grants(app_id)
	local ok, err = self._db:execute(
		"DELETE FROM app_grants WHERE app_id = ?", app_id)
	if not ok then return nil, "index: clear_grants failed: " .. tostring(err) end
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

-- Double-quote an FTS5 MATCH phrase so special characters (spaces, punctuation,
-- ranking operators) are treated as literal trigrams by the trigram tokenizer.
-- `"` inside the phrase must be doubled per the FTS5 grammar.
--: (string) -> string
local function fts_phrase(q)
	return '"' .. q:gsub('"', '""') .. '"'
end

local COLS = "a.id, a.name, a.path, a.manifest_json, a.tags_json, a.installed_at"

-- List all apps, optionally filtered by tag. Tag filter uses the app_tags
-- join, not json_each — O(matches) via idx_app_tags_tag_app.
--: ((table | nil)) -> table[]
function I:list(filter)
	local sql, args
	if filter and filter.tag then
		sql = "SELECT " .. COLS .. " FROM apps a " ..
			"JOIN app_tags at ON at.app_id = a.id " ..
			"JOIN tags t ON t.id = at.tag_id " ..
			"WHERE t.name = ? ORDER BY a.name ASC"
		args = { filter.tag }
	else
		sql = "SELECT " .. COLS .. " FROM apps a ORDER BY a.name ASC"
		args = {}
	end

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

-- Full-text search via apps_fts (trigram tokenizer). Case-insensitive
-- substring match on name, description, and path.
--: (string) -> table[]
function I:search(query)
	-- FTS match is pushed into a subquery so SQLite evaluates it once —
	-- joining apps_fts directly lets the planner pick a per-row MATCH,
	-- which is ~100x slower at 20k rows (see docs/perf/library_index.lua).
	local iter, err = self._db:query(
		"SELECT " .. COLS .. " FROM apps a " ..
		"WHERE a.id IN (SELECT rowid FROM apps_fts WHERE apps_fts MATCH ?) " ..
		"ORDER BY a.name ASC",
		fts_phrase(query)
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
