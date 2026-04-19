-- lib/platform/session_store/init.lua
-- SQLite-backed session store with idle TTL support.
--
-- API:
--   session_store.open(db_path, opts)   -> store | nil, err
--   store:put(session_id, record)       -> true | nil, err
--   store:get(session_id)               -> record | nil
--   store:touch(session_id)             -> boolean
--   store:delete(session_id)            -> true | nil, err
--   store:purge_expired()               -> true | nil, err
--   store:close()
--
-- opts:
--   time_fn  : () -> integer   (unix timestamp; no default — callers must inject)
--   idle_ttl : integer         (seconds; required)
--
-- Schema:
--   sessions(session_id TEXT PK, last_seen INTEGER, data TEXT)
--   data is a JSON-encoded table of record fields.
--
-- A session is considered expired when last_seen + idle_ttl < now().
-- get() and touch() treat expired sessions as if they do not exist; they do
-- NOT delete the row — call purge_expired() to reclaim storage.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local sqlite = require("lib.sqlite")
local json   = require("lib.format.json")

local M = {}

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS sessions (
  session_id  TEXT    PRIMARY KEY,
  last_seen   INTEGER NOT NULL,
  data        TEXT    NOT NULL
);
]]

--:: session_store_opts = { time_fn: () -> integer, idle_ttl: integer }
--:: session_record = { last_seen: integer, [string]: unknown }

-- ── Open ─────────────────────────────────────────────────────────────────────

-- open(db_path, opts) -> store | nil, err
--
-- db_path: filesystem path or ":memory:".
-- opts.time_fn and opts.idle_ttl are required; open() returns an error if
-- either is absent.
function M.open(db_path, opts)
	if not opts then return nil, "session_store.open: opts is required" end
	-- `any` escape: open-table reads return unknown; cast before use.
	local opts_any = opts --: any
	local time_fn = opts_any.time_fn --: any
	local idle_ttl = opts_any.idle_ttl --: any
	if not time_fn then
		return nil, "session_store.open: opts.time_fn is required"
	end
	if not idle_ttl then
		return nil, "session_store.open: opts.idle_ttl is required"
	end
	local ttl = tonumber(idle_ttl) --: number | nil
	if not ttl then
		return nil, "session_store.open: opts.idle_ttl must be a number"
	end

	local db, err = sqlite.open(db_path)
	if not db then return nil, "session_store.open: " .. tostring(err) end
	-- `any`: sqlite handle type not visible to checker (FFI cdata + metatable).
	local real_db = db --: any
	local ok, serr = real_db:execute(SCHEMA)
	if not ok then
		real_db:close()
		return nil, "session_store.open: schema init failed: " .. tostring(serr)
	end

	-- Build store object with methods attached directly (same pattern as
	-- lib/platform/audit/init.lua — avoids metatable + self field-access issues).
	local store = {
		_db      = real_db,
		_time_fn = time_fn,
		_ttl     = ttl,
	}

	-- put(session_id, record) -> true | nil, err
	-- Inserts or replaces the session row. record.last_seen is stored verbatim;
	-- all other fields are JSON-encoded into `data`.
	function store:put(session_id, record)
		if type(session_id) ~= "string" or session_id == "" then
			return nil, "session_store.put: session_id must be a non-empty string"
		end
		if type(record) ~= "table" then
			return nil, "session_store.put: record must be a table"
		end
		-- `any` escape for self field access.
		local db = self._db --: any
		local rec_any = record --: any
		local last_seen = rec_any.last_seen --: any
		local ts = tonumber(last_seen) --: number | nil
		if not ts then
			return nil, "session_store.put: record.last_seen must be a number"
		end

		-- Encode all non-last_seen fields into data JSON.
		local data_tbl = {} --: { [string]: unknown }
		for k, v in pairs(record) do
			if k ~= "last_seen" then
				data_tbl[k] = v
			end
		end
		local encoded, enc_err = json.encode(data_tbl)
		if type(encoded) ~= "string" then
			return nil, "session_store.put: encode failed: " .. tostring(enc_err)
		end

		local ins_ok, ins_err = db:execute(
			"INSERT OR REPLACE INTO sessions (session_id, last_seen, data) VALUES (?, ?, ?)",
			session_id, ts, encoded
		)
		if not ins_ok then
			return nil, "session_store.put: " .. tostring(ins_err)
		end
		return true
	end

	-- get(session_id) -> record | nil
	-- Returns nil if not found or if the session is idle
	-- (last_seen + idle_ttl < now).
	function store:get(session_id)
		if type(session_id) ~= "string" or session_id == "" then
			return nil
		end
		local db = self._db --: any
		local tfn = self._time_fn --: any
		local ttl_val = self._ttl --: any
		local now = tfn()

		local iter = db:query(
			"SELECT last_seen, data FROM sessions WHERE session_id = ?",
			session_id
		) --: any
		if not iter then return nil end
		local last_seen, data_str = iter()
		if last_seen == nil then return nil end

		local ls = tonumber(last_seen) --: number | nil
		if not ls then return nil end
		-- Expired: last_seen + idle_ttl < now.
		if ls + ttl_val < now then return nil end

		-- Decode extra fields from data JSON.
		local data = json.decode(data_str or "{}") or {}
		-- `any` escape for setting last_seen back into unknown-typed data table.
		local rec_any = data --: any
		rec_any.last_seen = ls
		return data
	end

	-- touch(session_id) -> boolean
	-- Updates last_seen to now(). Returns false if session not found or expired.
	function store:touch(session_id)
		if type(session_id) ~= "string" or session_id == "" then
			return false
		end
		local db = self._db --: any
		local tfn = self._time_fn --: any
		local ttl_val = self._ttl --: any
		local now = tfn()

		-- Verify the session exists and is not expired before updating.
		local iter = db:query(
			"SELECT last_seen FROM sessions WHERE session_id = ?",
			session_id
		) --: any
		if not iter then return false end
		local last_seen = iter()
		if last_seen == nil then return false end
		local ls = tonumber(last_seen) --: number | nil
		if not ls or ls + ttl_val < now then return false end

		db:execute(
			"UPDATE sessions SET last_seen = ? WHERE session_id = ?",
			now, session_id
		)
		return true
	end

	-- delete(session_id) -> true | nil, err
	function store:delete(session_id)
		if type(session_id) ~= "string" or session_id == "" then
			return nil, "session_store.delete: session_id must be a non-empty string"
		end
		local db = self._db --: any
		local ok, err = db:execute(
			"DELETE FROM sessions WHERE session_id = ?",
			session_id
		)
		if not ok then return nil, "session_store.delete: " .. tostring(err) end
		return true
	end

	-- purge_expired() -> true | nil, err
	-- Deletes all rows where last_seen + idle_ttl < now().
	function store:purge_expired()
		local db = self._db --: any
		local tfn = self._time_fn --: any
		local ttl_val = self._ttl --: any
		local now = tfn()
		-- cutoff: rows with last_seen < now - idle_ttl are expired.
		-- last_seen + ttl < now  ↔  last_seen < now - ttl
		local cutoff = now - ttl_val
		local ok, err = db:execute(
			"DELETE FROM sessions WHERE last_seen < ?",
			cutoff
		)
		if not ok then return nil, "session_store.purge_expired: " .. tostring(err) end
		return true
	end

	-- close()
	function store:close()
		local db = self._db --: any
		db:close()
	end

	return store
end

return M
