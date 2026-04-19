-- lib/platform/audit/init.lua
-- Append-only tamper-evident audit log for the platform daemon.
--
-- Each row's hash = SHA1(prev_hash | "|" | ts | "|" | event | "|" | payload).
-- The first row uses prev_hash = "0". Verification walks rows in id order
-- and recomputes every hash; any mismatch returns the first broken rowid.
--
-- API:
--   audit.open(db_path, opts)              -> log | nil, err
--   log:append(event_type, payload)        -> true | nil, err
--   log:query(opts)                        -> { [integer]: entry }
--   log:verify()                           -> true | (nil, rowid, errmsg)
--   log:close()
--
-- opts for open:
--   time_fn  : () -> integer   (unix timestamp; default: os.time)
--   sha1_fn  : (string) -> string  (hex SHA1; default: lib.hash.sha1.sha1)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local sqlite = require("lib.sqlite")
local json   = require("lib.format.json")

local M = {}

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS audit_log (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  ts        INTEGER NOT NULL,
  event     TEXT    NOT NULL,
  app_id    TEXT,
  payload   TEXT    NOT NULL,
  prev_hash TEXT    NOT NULL,
  hash      TEXT    NOT NULL
);
]]

--:: audit_entry = { id: integer, ts: integer, event: string, app_id: string | nil, payload: string, prev_hash: string, hash: string }
--:: audit_open_opts = { time_fn: (() -> integer) | nil, sha1_fn: ((string) -> string) | nil }
--:: audit_query_opts = { limit: integer | nil, offset: integer | nil, event_type: string | nil, app_id: string | nil, since: integer | nil, ["until"]: integer | nil }

-- ── Internal helpers ──────────────────────────────────────────────────────────

-- Compute the canonical hash input for a row.
--: (string, integer, string, string) -> string
local function hash_input(prev_hash, ts, event, payload)
	return prev_hash .. "|" .. tostring(ts) .. "|" .. event .. "|" .. payload
end

-- ── Open ─────────────────────────────────────────────────────────────────────

-- open(db_path, opts) -> log_obj | nil, err
--
-- log_obj exposes: append, query, verify, close (plus _db for raw test access).
-- The typechecker cannot fully type the sqlite handle or the multi-value
-- iterator returns; those sites use `any` as a documented escape hatch (same
-- as lib/platform/index.lua and lib/platform/daemon/init.lua).
function M.open(db_path, opts)
	local o = opts or {}
	local db, err = sqlite.open(db_path)
	if not db then return nil, "audit.open: " .. tostring(err) end
	-- `any`: sqlite handle type not visible to checker (FFI cdata + metatable).
	local real_db = db --: any
	local ok, serr = real_db:execute(SCHEMA)
	if not ok then
		real_db:close()
		return nil, "audit.open: schema init failed: " .. tostring(serr)
	end

	-- time_fn: prefer injected, fall back to os.time.
	-- `any` escape: o.time_fn is `(() -> integer) | nil` but open-table reads
	-- return `unknown`; the checker can't narrow the if-then assignment.
	local time_fn_any = o.time_fn --: any
	--: () -> integer
	local time_fn = time_fn_any or os.time

	-- sha1_fn: prefer injected, fall back to lib.hash.sha1.
	-- Same `any` escape as time_fn above.
	local sha1_fn_any = o.sha1_fn --: any
	--: (string) -> string
	local sha1_fn
	if sha1_fn_any then
		sha1_fn = sha1_fn_any
	else
		local sha1_mod = require("lib.hash.sha1")
		sha1_fn = sha1_mod.sha1
	end

	-- Build the log object with methods attached directly (no metatable needed).
	-- This pattern avoids the `self` field-access limitation in the typechecker.

	local log = {
		_db      = real_db,
		_time_fn = time_fn,
		_sha1_fn = sha1_fn,
	}

	-- append(event_type, payload) -> true | nil, err
	function log:append(event_type, payload_tbl)
		if type(event_type) ~= "string" or event_type == "" then
			return nil, "audit.append: event_type must be a non-empty string"
		end
		-- Encode payload as JSON.
		local payload_str --: string
		if payload_tbl == nil then
			payload_str = "{}"
		else
			-- `any`: json.encode accepts any table; checker doesn't narrow payload_tbl
			-- to non-nil here even though it was checked above.
			local ptbl_any = payload_tbl --: any
			local enc, enc_err = json.encode(ptbl_any)
			if type(enc) ~= "string" then
				return nil, "audit.append: payload encode failed: " .. tostring(enc_err)
			end
			payload_str = enc
		end

		-- Extract app_id from payload if present.
		local app_id --: string | nil
		if type(payload_tbl) == "table" and payload_tbl.app_id ~= nil then
			app_id = tostring(payload_tbl.app_id)
		end

		-- `any`: sqlite FFI handle and function fields from open-table self.
		local db = self._db --: any
		local tfn = self._time_fn --: any
		local ts = tfn()

		-- Get the most recent hash to chain from.
		local prev_hash = "0"
		local raw_iter = db:query("SELECT hash FROM audit_log ORDER BY id DESC LIMIT 1") --: any
		if raw_iter then
			local h = raw_iter()
			if h and type(h) == "string" then
				prev_hash = h
			end
		end

		local sfn = self._sha1_fn --: any
		local row_hash = sfn(hash_input(prev_hash, ts, event_type, payload_str))

		local ins_ok, ins_err = db:execute(
			"INSERT INTO audit_log (ts, event, app_id, payload, prev_hash, hash) VALUES (?, ?, ?, ?, ?, ?)",
			ts, event_type, app_id, payload_str, prev_hash, row_hash
		)
		if not ins_ok then return nil, "audit.append: insert failed: " .. tostring(ins_err) end
		return true
	end

	-- query(opts) -> audit_entry[]
	function log:query(opts)
		local o2 = opts or {}
		local wheres = {} --: { [integer]: string }
		local args   = {} --: { [integer]: unknown }

		if o2.event_type then
			wheres[#wheres + 1] = "event = ?"
			args[#args + 1] = o2.event_type
		end
		if o2.app_id then
			wheres[#wheres + 1] = "app_id = ?"
			args[#args + 1] = o2.app_id
		end
		if o2.since then
			wheres[#wheres + 1] = "ts >= ?"
			args[#args + 1] = o2.since
		end
		if o2["until"] then
			wheres[#wheres + 1] = "ts <= ?"
			args[#args + 1] = o2["until"]
		end

		-- app_id is nullable; put it last so NULL doesn't truncate unpack().
		local sql = "SELECT id, ts, event, payload, prev_hash, hash, app_id FROM audit_log"
		if #wheres > 0 then
			sql = sql .. " WHERE " .. table.concat(wheres, " AND ")
		end
		sql = sql .. " ORDER BY id ASC"

		-- `any` then tonumber: open-table reads return unknown; tonumber narrows.
		local limit_raw  = o2.limit  --: any
		local offset_raw = o2.offset --: any
		local limit_n  = tonumber(limit_raw)  --: number | nil
		local offset_n = tonumber(offset_raw) --: number | nil
		if limit_n and offset_n then
			sql = sql .. " LIMIT " .. tostring(limit_n) .. " OFFSET " .. tostring(offset_n)
		elseif limit_n then
			sql = sql .. " LIMIT " .. tostring(limit_n)
		elseif offset_n then
			-- SQLite requires LIMIT when using OFFSET; -1 means unlimited.
			sql = sql .. " LIMIT -1 OFFSET " .. tostring(offset_n)
		end

		-- `any`: sqlite iterator returns multiple unknown values via unpack.
		local db = self._db --: any
		local raw_iter = db:query(sql, unpack(args)) --: any
		if not raw_iter then return {} end

		local results = {} --: { [integer]: audit_entry }
		while true do
			local id, ts, event, payload, prev_hash, row_hash, app_id_col = raw_iter()
			if id == nil then break end
			results[#results + 1] = {
				id        = id,
				ts        = ts,
				event     = event or "",
				app_id    = app_id_col,
				payload   = payload or "",
				prev_hash = prev_hash or "",
				hash      = row_hash or "",
			}
		end
		return results
	end

	-- verify() -> true | nil, rowid, errmsg
	function log:verify()
		-- `any`: same FFI escape.
		local db = self._db --: any
		local raw_iter = db:query(
			"SELECT id, ts, event, payload, prev_hash, hash FROM audit_log ORDER BY id ASC"
		) --: any
		if not raw_iter then return true end -- empty log is trivially valid

		local expected_prev = "0"
		while true do
			local id, ts, event, payload, prev_hash, row_hash = raw_iter()
			if id == nil then break end
			-- Check that this row's prev_hash matches what we expect.
			if prev_hash ~= expected_prev then
				return nil, id, "broken chain: prev_hash mismatch at row " .. tostring(id)
			end
			-- Recompute this row's hash.
			local sfn2 = self._sha1_fn --: any
			local computed = sfn2(hash_input(prev_hash, ts, event, payload))
			if computed ~= row_hash then
				return nil, id, "broken chain: hash mismatch at row " .. tostring(id)
			end
			expected_prev = row_hash
		end
		return true
	end

	-- close()
	function log:close()
		local db = self._db --: any
		db:close()
	end

	return log
end

return M
