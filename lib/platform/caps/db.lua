-- lib/platform/caps/db.lua
-- db_cap(path, opts?) -> capability table, revoke_fn
-- Sandboxed SQLite database access. Wraps a sqlite connection with revocation
-- checking on every method call.
--
-- opts.readonly : boolean, if true the database rejects writes (via PRAGMA query_only)
--
-- Capability API (passed to sandbox as caps.db):
--   cap.execute(sql, ...)      -> true | nil, err
--   cap.prepare(sql)           -> wrapped_stmt | nil, err
--   cap.query(sql, ...)        -> iterator | nil, err
--   cap.last_insert_rowid()    -> integer
--   cap.changes()              -> integer
--   cap.close()                -> nil
--
-- Prepared statement API (returned by cap.prepare):
--   stmt.exec(...)             -> true | nil, err
--   stmt.rows(...)             -> iterator
--   stmt.close()               -> nil

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local sqlite = require("lib.sqlite")

local M = {}

-- wrap_stmt(raw_stmt, is_revoked) -> wrapped_stmt
-- Returns a statement proxy that checks revocation before each operation.
--: (unknown, () -> boolean) -> unknown
local function wrap_stmt(raw_stmt, is_revoked)
	return {
		exec = function(...)
			if is_revoked() then return nil, "db: capability revoked" end
			return raw_stmt:exec(...)
		end,
		rows = function(...)
			if is_revoked() then return nil, "db: capability revoked" end
			return raw_stmt:rows(...)
		end,
		close = function()
			raw_stmt:close()
		end,
	}
end

-- db_cap(path, opts?) -> cap, revoke | nil, err
function M.db_cap(path, opts)
	opts = opts or {}

	local db, err = sqlite.open(path)
	if not db then return nil, err end

	if opts.readonly then
		local ok, rerr = db:execute("PRAGMA query_only = ON")
		if not ok then
			db:close()
			return nil, "db: failed to set readonly: " .. tostring(rerr)
		end
	end

	local revoked = false
	local function is_revoked() return revoked end

	local cap = {}

	function cap.execute(sql, ...)
		if revoked then return nil, "db: capability revoked" end
		return db:execute(sql, ...)
	end

	function cap.prepare(sql)
		if revoked then return nil, "db: capability revoked" end
		local stmt, serr = db:prepare(sql)
		if not stmt then return nil, serr end
		return wrap_stmt(stmt, is_revoked)
	end

	function cap.query(sql, ...)
		if revoked then return nil, "db: capability revoked" end
		return db:query(sql, ...)
	end

	function cap.last_insert_rowid()
		if revoked then return nil, "db: capability revoked" end
		return db:last_insert_rowid()
	end

	function cap.changes()
		if revoked then return nil, "db: capability revoked" end
		return db:changes()
	end

	function cap.close()
		if not revoked then
			db:close()
		end
	end

	local function revoke()
		if not revoked then
			revoked = true
			db:close()
		end
	end

	return cap, revoke
end

return M
