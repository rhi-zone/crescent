-- lib/conversation/init.lua
-- SQLite-backed conversation tree. Vendor this file into your app tarball.
--
-- Conversations are trees: each message has an optional parent. Every node
-- tracks which child was last followed (canonical_child_id), so following
-- that pointer from the root reconstructs the active path. Branching inserts
-- a new child and updates the parent's canonical_child_id. Swiping updates
-- canonical_child_id to an existing sibling without inserting.
--
-- API:
--   local conv = require("conversation")  -- or wherever you vendor it
--
--   local db, err = conv.open(path)
--
--   local session, err = db:create_session(app_id, metadata?)
--   local session, err = db:get_session(id)
--   local sessions, err = db:list_sessions(app_id)       -- DESC by created_at
--
--   local msg, err = db:add_message(session_id, parent_id, role, content, metadata?)
--   local msg, err = db:get_message(id)
--   local children, err = db:get_children(message_id)
--   local path, err = db:get_canonical_path(session_id)  -- root → leaf
--
--   local ok, err = db:swipe_to(message_id)              -- reparent canonical pointer
--   local ok, err = db:delete_session(id)                -- cascades to messages

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local sqlite = require("lib.sqlite")
local json   = require("lib.format.json")

local M = {}

-- ── UUID generation ───────────────────────────────────────────────────────────

math.randomseed(os.time())

local function uuid()
	return string.format(
		"%08x-%04x-4%03x-%04x-%012x",
		math.random(0, 0xffffffff),
		math.random(0, 0xffff),
		math.random(0, 0xfff),
		math.random(0x8000, 0xbfff),
		math.random(0, 0xffffffffffff)
	)
end

-- ── Schema ────────────────────────────────────────────────────────────────────

local SCHEMA = [[
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS sessions (
  id         TEXT PRIMARY KEY,
  app_id     TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  metadata   TEXT
);
CREATE TABLE IF NOT EXISTS messages (
  id                 TEXT PRIMARY KEY,
  session_id         TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  parent_id          TEXT REFERENCES messages(id),
  role               TEXT NOT NULL,
  content            TEXT NOT NULL,
  created_at         INTEGER NOT NULL,
  canonical_child_id TEXT REFERENCES messages(id),
  metadata           TEXT
);
]]

-- ── db handle ─────────────────────────────────────────────────────────────────

-- db_execute: module-level helper to call db:execute().
-- Extracted to avoid open-table narrowing conflicts when self._db is referenced
-- multiple times in the same scope (mirrors the ecs.lua db_last_rowid pattern).
local function db_execute(db, sql, ...)
	return db:execute(sql, ...)
end

local db_mt = {}
db_mt.__index = db_mt

-- encode_metadata: encode a Lua table (or nil) to JSON string or nil.
local function encode_metadata(meta)
	if meta == nil then return nil end
	local s, err = json.encode(meta)
	if not s then return nil, "conversation: json encode metadata: " .. tostring(err) end
	return s
end

-- decode_metadata: decode a JSON string or nil to a Lua value.
local function decode_metadata(s)
	if s == nil then return nil end
	local v, err = json.decode(s)
	if v == nil and err then return nil, "conversation: json decode metadata: " .. tostring(err) end
	return v
end

-- iter_done: returns true if the iterator sentinel "sqlite: done" was received.
local function iter_done(v, err)
	return v == nil and err == "sqlite: done"
end

-- ── Sessions ──────────────────────────────────────────────────────────────────

-- create_session(app_id, metadata?) -> session | nil, err
db_mt.create_session = function(self, app_id, metadata)
	local id = uuid()
	local now = os.time()
	local meta_s, merr = encode_metadata(metadata)
	if merr then return nil, merr end
	local ok, err = self._db:execute(
		"INSERT INTO sessions (id, app_id, created_at, metadata) VALUES (?, ?, ?, ?)",
		id, app_id, now, meta_s
	)
	if not ok then return nil, err end
	return { id = id, app_id = app_id, created_at = now, metadata = metadata }
end

-- get_session(id) -> session | nil, err
db_mt.get_session = function(self, id)
	local iter, err = self._db:query(
		"SELECT id, app_id, created_at, metadata FROM sessions WHERE id = ?",
		id
	)
	if not iter then return nil, err end
	local sid, app_id, created_at, meta_s = iter()
	if sid == nil then return nil, "conversation: session not found: " .. tostring(id) end
	local meta, merr = decode_metadata(meta_s)
	if merr then return nil, merr end
	return { id = sid, app_id = app_id, created_at = created_at, metadata = meta }
end

-- list_sessions(app_id) -> sessions[] | nil, err  (ordered by created_at DESC)
db_mt.list_sessions = function(self, app_id)
	local iter, err = self._db:query(
		"SELECT id, app_id, created_at, metadata FROM sessions WHERE app_id = ? ORDER BY created_at DESC",
		app_id
	)
	if not iter then return nil, err end
	local results = {}
	while true do
		local sid, aid, created_at, meta_s = iter()
		if iter_done(sid, aid) then break end
		if sid == nil then return nil, "conversation: list_sessions query error: " .. tostring(aid) end
		local meta, merr = decode_metadata(meta_s)
		if merr then return nil, merr end
		results[#results + 1] = { id = sid, app_id = aid, created_at = created_at, metadata = meta }
	end
	return results
end

-- delete_session(id) -> true | nil, err  (cascades to messages via FK)
db_mt.delete_session = function(self, id)
	local ok, err = self._db:execute("PRAGMA foreign_keys = ON")
	if not ok then return nil, err end
	ok, err = self._db:execute("DELETE FROM sessions WHERE id = ?", id)
	if not ok then return nil, err end
	return true
end

-- ── Messages ──────────────────────────────────────────────────────────────────

-- add_message(session_id, parent_id, role, content, metadata?) -> msg | nil, err
-- Also updates parent's canonical_child_id to the new message id.
db_mt.add_message = function(self, session_id, parent_id, role, content, metadata)
	local id = uuid()
	local now = os.time()
	local meta_s, merr = encode_metadata(metadata)
	if merr then return nil, merr end
	local ok, err = self._db:execute(
		"INSERT INTO messages (id, session_id, parent_id, role, content, created_at, canonical_child_id, metadata)"
		.. " VALUES (?, ?, ?, ?, ?, ?, NULL, ?)",
		id, session_id, parent_id, role, content, now, meta_s
	)
	if not ok then return nil, err end
	-- Update parent's canonical_child_id if there is a parent.
	if parent_id ~= nil then
		ok, err = self._db:execute(
			"UPDATE messages SET canonical_child_id = ? WHERE id = ?",
			id, parent_id
		)
		if not ok then return nil, err end
	end
	return {
		id = id,
		session_id = session_id,
		parent_id = parent_id,
		role = role,
		content = content,
		created_at = now,
		canonical_child_id = nil,
		metadata = metadata,
	}
end

-- get_message(id) -> msg | nil, err
db_mt.get_message = function(self, id)
	local iter, err = self._db:query(
		"SELECT id, session_id, parent_id, role, content, created_at, canonical_child_id, metadata"
		.. " FROM messages WHERE id = ?",
		id
	)
	if not iter then return nil, err end
	local mid, session_id, parent_id, role, content, created_at, canonical_child_id, meta_s = iter()
	if mid == nil then return nil, "conversation: message not found: " .. tostring(id) end
	local meta, merr = decode_metadata(meta_s)
	if merr then return nil, merr end
	return {
		id = mid,
		session_id = session_id,
		parent_id = parent_id,
		role = role,
		content = content,
		created_at = created_at,
		canonical_child_id = canonical_child_id,
		metadata = meta,
	}
end

-- get_children(message_id) -> msgs[] | nil, err
db_mt.get_children = function(self, message_id)
	local iter, err = self._db:query(
		"SELECT id, session_id, parent_id, role, content, created_at, canonical_child_id, metadata"
		.. " FROM messages WHERE parent_id = ?",
		message_id
	)
	if not iter then return nil, err end
	local results = {}
	while true do
		local mid, session_id, parent_id, role, content, created_at, canonical_child_id, meta_s = iter()
		if iter_done(mid, session_id) then break end
		if mid == nil then return nil, "conversation: get_children query error: " .. tostring(session_id) end
		local meta, merr = decode_metadata(meta_s)
		if merr then return nil, merr end
		results[#results + 1] = {
			id = mid,
			session_id = session_id,
			parent_id = parent_id,
			role = role,
			content = content,
			created_at = created_at,
			canonical_child_id = canonical_child_id,
			metadata = meta,
		}
	end
	return results
end

-- fetch_canon_next: module-level helper.
-- Given a db and a current canonical_child_id (as a string), fetches the
-- next message's scalar fields. Returns 8 values on success, or nil + err.
-- Extracted to module level to avoid open-table narrowing conflicts.
local function fetch_canon_next(db, next_id)
	local iter, err = db:query(
		"SELECT id, session_id, parent_id, role, content, created_at, canonical_child_id, metadata"
		.. " FROM messages WHERE id = ?",
		next_id
	)
	if not iter then return nil, err end
	return iter()
end

-- fetch_msg_parent: fetch parent_id of a message by id.
-- Returns parent_id_string, nil on success or nil, err on failure.
local function fetch_msg_parent(db, message_id)
	local iter, err = db:query(
		"SELECT parent_id FROM messages WHERE id = ?",
		message_id
	)
	if not iter then return nil, err end
	local parent_id, qerr = iter()
	if parent_id == nil and qerr ~= "sqlite: done" then
		return nil, "conversation: message not found: " .. tostring(message_id)
	end
	return parent_id
end

-- get_canonical_path(session_id) -> msgs[] | nil, err
-- Returns the path from the root message to the leaf, following canonical_child_id.
db_mt.get_canonical_path = function(self, session_id)
	local db = self._db
	-- Find root (message with no parent in this session).
	local iter, err = db:query(
		"SELECT id, session_id, parent_id, role, content, created_at, canonical_child_id, metadata"
		.. " FROM messages WHERE session_id = ? AND parent_id IS NULL",
		session_id
	)
	if not iter then return nil, err end
	local cur_id, cur_sid, cur_parent, cur_role, cur_content, cur_ts, cur_canon, cur_meta_s = iter()
	if cur_id == nil then
		-- No messages yet — return empty path.
		return {}
	end
	local path = {}
	-- Walk down canonical_child_id links.
	while cur_id ~= nil do
		local meta, merr = decode_metadata(cur_meta_s)
		if merr then return nil, merr end
		path[#path + 1] = {
			id = cur_id,
			session_id = cur_sid,
			parent_id = cur_parent,
			role = cur_role,
			content = cur_content,
			created_at = cur_ts,
			canonical_child_id = cur_canon,
			metadata = meta,
		}
		if cur_canon == nil then break end
		local nid, nsid, npar, nrole, ncon, nts, ncan, nmeta_s = fetch_canon_next(db, tostring(cur_canon))
		if nid == nil then return nil, "conversation: broken canonical link from " .. tostring(cur_id) end
		cur_id     = nid
		cur_sid    = nsid
		cur_parent = npar
		cur_role   = nrole
		cur_content = ncon
		cur_ts     = nts
		cur_canon  = ncan
		cur_meta_s = nmeta_s
	end
	return path
end

-- swipe_to(message_id) -> true | nil, err
-- Sets message's parent's canonical_child_id to message_id.
db_mt.swipe_to = function(self, message_id)
	local db = self._db
	-- Fetch the parent_id of this message inline (avoids self: narrowing issue).
	local parent_id, ferr = fetch_msg_parent(db, message_id)
	if parent_id == nil then
		-- Distinguish "query error" from "NULL parent_id means no parent".
		-- fetch_msg_parent returns nil,"sqlite: done" when the message is root.
		if ferr and ferr ~= "sqlite: done" then return nil, ferr end
		return nil, "conversation: swipe_to: message has no parent (it is a root)"
	end
	local ok, uerr = db_execute(db,
		"UPDATE messages SET canonical_child_id = ? WHERE id = ?",
		message_id, tostring(parent_id)
	)
	if not ok then return nil, uerr end
	return true
end

-- ── open ──────────────────────────────────────────────────────────────────────

-- open(path) -> db | nil, err
-- Opens (or creates) a SQLite database at path. Creates tables if missing.
M.open = function(path)
	local db, err = sqlite.open(path)
	if not db then return nil, err end
	-- Enable foreign keys and create schema.
	local ok, serr = db:execute(SCHEMA)
	if not ok then return nil, serr end
	return setmetatable({ _db = db }, db_mt)
end

return M
