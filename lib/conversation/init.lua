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
--   local db, err = conv.open(path, time_fn)  -- time_fn: () -> integer (unix ts)
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
local json_any = json --[[: any]]
--: { encode: (unknown) -> (string | nil, string | nil), decode: (string) -> (unknown, string | nil) }
local json_ = json_any

local M = {}

-- ── UUID generation ───────────────────────────────────────────────────────────

local function uuid()
	return string.format(
		"%08x-%04x-4%03x-%04x-%012x",
		math.random(0, math.floor(0xffffffff)),
		math.random(0, math.floor(0xffff)),
		math.random(0, math.floor(0xfff)),
		math.random(math.floor(0x8000), math.floor(0xbfff)),
		math.random(0, math.floor(0xffffffffffff))
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

--:: Db = { _db: any, _time_fn: () -> integer, create_session: (Db, string, unknown) -> (unknown, string | nil), get_session: (Db, string) -> (unknown, string | nil), list_sessions: (Db, string) -> (unknown, string | nil), delete_session: (Db, string) -> (boolean | nil, string | nil), add_message: (Db, string, string | nil, string, string, unknown) -> (unknown, string | nil), get_message: (Db, string) -> (unknown, string | nil), get_children: (Db, string) -> (unknown, string | nil), get_canonical_path: (Db, string) -> (unknown, string | nil), swipe_to: (Db, string) -> (boolean | nil, string | nil), update_message: (Db, string, { [string]: unknown }) -> (unknown, string | nil), delete_subtree: (Db, string) -> (unknown, string | nil), get_roots: (Db, string) -> (unknown, string | nil), get_root_children: (Db, string) -> (unknown, string | nil) }
local db_mt = {}
db_mt.__index = db_mt

-- encode_metadata: encode a Lua table (or nil) to JSON string or nil.
local function encode_metadata(meta)
	if meta == nil then return nil end
	local s, err = json_.encode(meta)
	if not s then return nil, "conversation: json encode metadata: " .. tostring(err) end
	return s
end

-- decode_metadata: decode a JSON string or nil to a Lua value.
local function decode_metadata(s)
	if s == nil then return nil end
	local v, err = json_.decode(tostring(s))
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
	local self_ = self --[[:! Db]]
	local id = uuid()
	local now = self_._time_fn()
	local meta_s, merr = encode_metadata(metadata)
	if merr then return nil, merr end
	local db_ = self_._db
	local ok, err = db_:execute(
		"INSERT INTO sessions (id, app_id, created_at, metadata) VALUES (?, ?, ?, ?)",
		id, app_id, now, meta_s
	)
	if not ok then return nil, err end
	return { id = id, app_id = app_id, created_at = now, metadata = metadata }
end

-- get_session(id) -> session | nil, err
db_mt.get_session = function(self, id)
	local self_ = self --[[:! Db]]
	local iter, err = self_._db:query(
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
	local self_ = self --[[:! Db]]
	local iter, err = self_._db:query(
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
	local self_ = self --[[:! Db]]
	local ok, err = self_._db:execute("PRAGMA foreign_keys = ON")
	if not ok then return nil, err end
	ok, err = self_._db:execute("DELETE FROM sessions WHERE id = ?", id)
	if not ok then return nil, err end
	return true
end

-- ── Messages ──────────────────────────────────────────────────────────────────

-- add_message(session_id, parent_id, role, content, metadata?) -> msg | nil, err
-- Also updates parent's canonical_child_id to the new message id.
db_mt.add_message = function(self, session_id, parent_id, role, content, metadata)
	local self_ = self --[[:! Db]]
	local id = uuid()
	local now = self_._time_fn()
	local meta_s, merr = encode_metadata(metadata)
	if merr then return nil, merr end
	local ok, err = self_._db:execute(
		"INSERT INTO messages (id, session_id, parent_id, role, content, created_at, canonical_child_id, metadata)"
		.. " VALUES (?, ?, ?, ?, ?, ?, NULL, ?)",
		id, session_id, parent_id, role, content, now, meta_s
	)
	if not ok then return nil, err end
	-- Update parent's canonical_child_id if there is a parent.
	if parent_id ~= nil then
		ok, err = self_._db:execute(
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
	local self_ = self --[[:! Db]]
	local iter, err = self_._db:query(
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
	local self_ = self --[[:! Db]]
	local iter, err = self_._db:query(
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
	local self_ = self --[[:! Db]]
	local db = self_._db
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
	local self_ = self --[[:! Db]]
	local db = self_._db
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

-- update_message(id, fields) -> msg | nil, err
-- Updates mutable fields: content, metadata, canonical_child_id.
-- Only updates fields present in the table.
db_mt.update_message = function(self, id, fields)
	local self_ = self --[[:! Db]]
	local db = self_._db
	-- Validate existence.
	local existing, err = self_:get_message(id)
	if not existing then return nil, err end
	local sets = {}
	local vals = {}
	if fields.content ~= nil then
		sets[#sets + 1] = "content = ?"
		vals[#vals + 1] = fields.content
	end
	if fields.metadata ~= nil then
		local meta_s, merr = encode_metadata(fields.metadata)
		if merr then return nil, merr end
		sets[#sets + 1] = "metadata = ?"
		vals[#vals + 1] = meta_s
	end
	if fields.canonical_child_id ~= nil then
		sets[#sets + 1] = "canonical_child_id = ?"
		vals[#vals + 1] = fields.canonical_child_id
	end
	if #sets == 0 then
		return existing
	end
	vals[#vals + 1] = id
	local ok, uerr = db:execute(
		"UPDATE messages SET " .. table.concat(sets, ", ") .. " WHERE id = ?",
		unpack(vals)
	)
	if not ok then return nil, uerr end
	return self_:get_message(id)
end

-- delete_subtree(message_id) -> {deleted=N} | nil, err
-- Deletes a message and all its descendants via recursive CTE.
-- Updates parent's canonical_child_id after deletion.
db_mt.delete_subtree = function(self, message_id)
	local self_ = self --[[:! Db]]
	local db = self_._db
	-- Validate existence and get parent_id.
	local msg, err = self_:get_message(message_id)
	if not msg then return nil, err end
	local msg_ = msg --[[:! { parent_id: unknown, ... }]]
	local parent_id = msg_.parent_id
	-- Collect descendant IDs via recursive CTE.
	local iter, qerr = db:query(
		"WITH RECURSIVE subtree(id) AS ("
		.. " SELECT id FROM messages WHERE id = ?"
		.. " UNION ALL"
		.. " SELECT m.id FROM messages m JOIN subtree s ON m.parent_id = s.id"
		.. ") SELECT id FROM subtree",
		message_id
	)
	if not iter then return nil, qerr end
	local ids = {}
	while true do
		local mid, ierr = iter()
		if iter_done(mid, ierr) then break end
		if mid == nil then return nil, "conversation: delete_subtree query error: " .. tostring(ierr) end
		ids[#ids + 1] = mid
	end
	-- Clear canonical_child_id references pointing into the subtree to avoid FK violations.
	-- Also clear canonical_child_id on nodes within the subtree that point to each other.
	for _, did in ipairs(ids) do
		db_execute(db, "UPDATE messages SET canonical_child_id = NULL WHERE canonical_child_id = ?", did)
	end
	-- Delete all nodes in reverse order (leaves first) to avoid FK issues.
	for i = #ids, 1, -1 do
		local ok, derr = db_execute(db, "DELETE FROM messages WHERE id = ?", ids[i])
		if not ok then return nil, derr end
	end
	-- Update parent's canonical_child_id.
	if parent_id ~= nil then
		local children, cerr = self_:get_children(tostring(parent_id))
		if not children then return nil, cerr end
		if #children > 0 then
			local ok, uerr = db_execute(db,
				"UPDATE messages SET canonical_child_id = ? WHERE id = ?",
				children[1].id, parent_id
			)
			if not ok then return nil, uerr end
		else
			local ok, uerr = db_execute(db,
				"UPDATE messages SET canonical_child_id = NULL WHERE id = ?",
				parent_id
			)
			if not ok then return nil, uerr end
		end
	end
	return { deleted = #ids }
end

-- get_roots(session_id) -> msgs[] | nil, err
-- Returns all root messages (parent_id IS NULL) in a session.
db_mt.get_roots = function(self, session_id)
	local self_ = self --[[:! Db]]
	local db = self_._db
	local iter, err = db:query(
		"SELECT id, session_id, parent_id, role, content, created_at, canonical_child_id, metadata"
		.. " FROM messages WHERE session_id = ? AND parent_id IS NULL ORDER BY created_at ASC",
		session_id
	)
	if not iter then return nil, err end
	local results = {}
	while true do
		local mid, sid, parent_id, role, content, created_at, canonical_child_id, meta_s = iter()
		if iter_done(mid, sid) then break end
		if mid == nil then return nil, "conversation: get_roots query error: " .. tostring(sid) end
		local meta, merr = decode_metadata(meta_s)
		if merr then return nil, merr end
		results[#results + 1] = {
			id = mid,
			session_id = sid,
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

-- get_root_children(session_id) -> msgs[] | nil, err
-- Gets children of the root message (parent_id IS NULL) in a session.
db_mt.get_root_children = function(self, session_id)
	local self_ = self --[[:! Db]]
	local db = self_._db
	local iter, err = db:query(
		"SELECT id FROM messages WHERE session_id = ? AND parent_id IS NULL",
		session_id
	)
	if not iter then return nil, err end
	local root_id, qerr = iter()
	if iter_done(root_id, qerr) then
		return nil, "conversation: no root message in session: " .. tostring(session_id)
	end
	if root_id == nil then return nil, "conversation: get_root_children query error: " .. tostring(qerr) end
	return self_:get_children(tostring(root_id))
end

-- ── open ──────────────────────────────────────────────────────────────────────

-- open(path, time_fn) -> db | nil, err
-- Opens (or creates) a SQLite database at path. Creates tables if missing.
-- time_fn: () -> integer — required, returns unix timestamp (e.g. caps.time.now).
M.open = function(path, time_fn)
	if not time_fn then
		error("conversation.open: requires time_fn (function returning unix timestamp)", 2)
	end
	math.randomseed(time_fn())
	local db, err = sqlite.open(path)
	if not db then return nil, err end
	-- Enable foreign keys and create schema.
	local ok, serr = db:execute(SCHEMA)
	if not ok then return nil, serr end
	return setmetatable({ _db = db, _time_fn = time_fn }, db_mt)
end

-- from_db(db_handle, time_fn) -> db | nil, err
-- Creates a conversation handle from a pre-opened db cap (e.g. caps.conversations).
-- The db_handle must support .execute(sql,...) and .query(sql,...).
-- Applies the schema and returns the handle.
-- time_fn: () -> integer — required, returns unix timestamp.
M.from_db = function(db_handle, time_fn)
	if not db_handle then return nil, "conversation.from_db: db_handle required" end
	if not time_fn then
		error("conversation.from_db: requires time_fn (function returning unix timestamp)", 2)
	end
	math.randomseed(time_fn())
	local ok, serr = db_handle:execute(SCHEMA)
	if not ok then return nil, serr end
	return setmetatable({ _db = db_handle, _time_fn = time_fn }, db_mt)
end

return M
