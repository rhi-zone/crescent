-- lib/platform/caps/db.lua
-- db_cap(path, opts?) -> capability table, revoke_fn
-- Sandboxed SQLite database access. Wraps a sqlite connection with revocation
-- checking on every method call.
--
-- opts.allow_write : boolean, default false. When false the database rejects writes (via PRAGMA query_only)
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

	local db, err = sqlite.open(path) --: any
	if not db then return nil, err end

	if not opts.allow_write then
		local ok, rerr = db:execute("PRAGMA query_only = ON")
		if not ok then
			db:close()
			return nil, "db: failed to set readonly: " .. tostring(rerr)
		end
	end

	local revoked = false
	local function is_revoked() return revoked end

	local cap = { _type = "db" }

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

	function cap.attenuate(sub_opts)
		if revoked then return nil, "db: capability revoked" end
		sub_opts = sub_opts or {}
		local sub_allow_write = sub_opts.allow_write
		if sub_allow_write == nil then sub_allow_write = opts.allow_write end
		if sub_allow_write and not opts.allow_write then
			return nil, "db.attenuate: cannot grant write not held"
		end
		local sub_revoked = false
		local sub = {
			_type = "db",
			query = function(sql, ...)
				if revoked or sub_revoked then return nil, "db: capability revoked" end
				return db:query(sql, ...)
			end,
			prepare = function(sql)
				if revoked or sub_revoked then return nil, "db: capability revoked" end
				local stmt, serr = db:prepare(sql)
				if not stmt then return nil, serr end
				return wrap_stmt(stmt, function() return revoked or sub_revoked end)
			end,
			last_insert_rowid = function()
				if revoked or sub_revoked then return nil, "db: capability revoked" end
				return db:last_insert_rowid()
			end,
			changes = function()
				if revoked or sub_revoked then return nil, "db: capability revoked" end
				return db:changes()
			end,
			close = function() end,  -- sub-cap doesn't own the connection
		}
		if sub_allow_write then
			sub.execute = function(sql, ...)
				if revoked or sub_revoked then return nil, "db: capability revoked" end
				return db:execute(sql, ...)
			end
		end
		sub.attenuate = function(deeper_opts)
			if revoked or sub_revoked then return nil, "db: capability revoked" end
			deeper_opts = deeper_opts or {}
			local deeper_allow_write = deeper_opts.allow_write
			if deeper_allow_write == nil then deeper_allow_write = sub_allow_write end
			if deeper_allow_write and not sub_allow_write then
				return nil, "db.attenuate: cannot grant write not held"
			end
			return cap.attenuate({ allow_write = deeper_allow_write })
		end
		return sub, function() sub_revoked = true end
	end

	local function revoke()
		if not revoked then
			revoked = true
			db:close()
		end
	end

	return cap, revoke
end

function M.risk(decl)
	if not decl.allow_write then
		return { severity = "low", text = "Reads a private SQLite database. No writes." }
	end
	return { severity = "low", text = "Reads and writes a private SQLite database. Data is isolated to this app." }
end

return M
