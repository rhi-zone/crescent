-- lib/platform/caps/shared_db.lua
-- shared_db_cap(path, app_id, tables, opts?) -> capability table
-- Opens a shared SQLite database with per-app view isolation.
--
-- Schema convention: base tables are prefixed with `_` (e.g. `_sessions`).
-- Main-schema views with clean names (e.g. `sessions`) are defined as
-- `SELECT * FROM _sessions WHERE app_id = _app_id()`. INSTEAD OF triggers
-- on the views enforce app_id on every write.
--
-- The host registers a per-connection `_app_id()` custom SQL function that
-- returns the app_id for this connection. The authorizer blocks direct
-- access to `_`-prefixed base tables, DDL, and ATTACH.
--
-- Use setup_schema() to create the base tables, views, and triggers for a
-- new shared database.
--
-- opts.readonly: boolean — if true, only query is exposed (no exec).
--
-- Capability API (same shape as caps.db):
--   cap.execute(sql)              -> true | nil, err   (not present in readonly)
--   cap.query(sql, params?)    -> rows | nil, err
--   cap.close()                -> nil

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi = require("ffi")

local M = {}

-- ── FFI declarations ──────────────────────────────────────────────────────────

pcall(ffi.cdef, [[
	typedef struct sqlite3      sqlite3;
	typedef struct sqlite3_stmt sqlite3_stmt;
	typedef int64_t             sqlite3_int64;
	typedef struct sqlite3_context sqlite3_context;
	typedef struct sqlite3_value  sqlite3_value;

	int         sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
	int         sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte,
	                               sqlite3_stmt **ppStmt, const char **pzTail);
	int         sqlite3_step(sqlite3_stmt *);
	int         sqlite3_finalize(sqlite3_stmt *);
	int         sqlite3_close_v2(sqlite3 *);
	const char *sqlite3_errmsg(sqlite3 *);

	int         sqlite3_column_count(sqlite3_stmt *);
	int         sqlite3_column_type(sqlite3_stmt *, int iCol);
	int         sqlite3_column_bytes(sqlite3_stmt *, int iCol);
	const void *sqlite3_column_blob(sqlite3_stmt *, int iCol);
	double      sqlite3_column_double(sqlite3_stmt *, int iCol);
	const char *sqlite3_column_name(sqlite3_stmt *, int iCol);

	int sqlite3_bind_null(sqlite3_stmt *, int);
	int sqlite3_bind_int(sqlite3_stmt *, int, int);
	int sqlite3_bind_int64(sqlite3_stmt *, int, sqlite3_int64);
	int sqlite3_bind_double(sqlite3_stmt *, int, double);
	int sqlite3_bind_text(sqlite3_stmt *, int, const char *, int, void(*)(void *));

	int sqlite3_set_authorizer(sqlite3 *, int (*)(void *, int, const char *, const char *, const char *, const char *), void *);

	int sqlite3_exec(sqlite3 *, const char *sql, void *, void *, char **errmsg);
	void sqlite3_free(void *);

	int sqlite3_create_function_v2(
		sqlite3 *db, const char *zFunctionName, int nArg, int eTextRep,
		void *pApp,
		void (*xFunc)(sqlite3_context *, int, sqlite3_value **),
		void (*xStep)(sqlite3_context *, int, sqlite3_value **),
		void (*xFinal)(sqlite3_context *),
		void (*xDestroy)(void *)
	);

	void sqlite3_result_text(sqlite3_context *, const char *, int, void(*)(void *));
]])

-- ── load shared library ───────────────────────────────────────────────────────

local sqlite_ffi
if ffi.os == "Windows" then
	if ffi.arch == "x64" then sqlite_ffi = ffi.load("dep/sqlite.dll")
	else sqlite_ffi = ffi.load("dep/sqlite-x86.dll") end
else
	local names = {
		"sqlite3",
		"libsqlite3.so", "libsqlite3.so.0",
		"libsqlite3.dylib", "/usr/lib/libsqlite3.dylib",
	}
	for _, name in ipairs(names) do
		local ok, lib = pcall(ffi.load, name)
		if ok then sqlite_ffi = lib; break end
	end
	if not sqlite_ffi then
		error("shared_db_cap: sqlite3 shared library not found")
	end
end

-- ── constants ─────────────────────────────────────────────────────────────────

local SQLITE_OPEN_READONLY  = 0x00000001
local SQLITE_OPEN_READWRITE = 0x00000002

local SQLITE_OK   = 0
local SQLITE_DENY = 1

local SQLITE_ROW  = 100
local SQLITE_DONE = 101

local SQLITE_INTEGER = 1
local SQLITE_FLOAT   = 2
local SQLITE_TEXT    = 3
local SQLITE_BLOB    = 4
local SQLITE_NULL    = 5

local SQLITE_UTF8 = 1

-- Authorizer action codes.
local SQLITE_CREATE_TABLE        = 2
local SQLITE_CREATE_TEMP_INDEX   = 3
local SQLITE_CREATE_TEMP_TABLE   = 4
local SQLITE_CREATE_TEMP_TRIGGER = 5
local SQLITE_CREATE_TEMP_VIEW    = 6
local SQLITE_CREATE_INDEX        = 1
local SQLITE_CREATE_TRIGGER      = 7
local SQLITE_CREATE_VIEW         = 8
local SQLITE_DELETE              = 9
local SQLITE_DROP_INDEX          = 10
local SQLITE_DROP_TABLE          = 11
local SQLITE_DROP_TEMP_INDEX     = 12
local SQLITE_DROP_TEMP_TABLE     = 13
local SQLITE_DROP_TEMP_TRIGGER   = 14
local SQLITE_DROP_TEMP_VIEW      = 15
local SQLITE_DROP_TRIGGER        = 16
local SQLITE_DROP_VIEW           = 17
local SQLITE_INSERT              = 18
local SQLITE_PRAGMA              = 19
local SQLITE_READ                = 20
local SQLITE_SELECT              = 21
local SQLITE_TRANSACTION         = 22
local SQLITE_UPDATE              = 23
local SQLITE_ATTACH              = 24
local SQLITE_DETACH              = 25
local SQLITE_FUNCTION            = 31

local SQLITE_TRANSIENT = ffi.cast("void(*)(void*)", -1)

-- ── column reading ────────────────────────────────────────────────────────────

local col_read = {
	[SQLITE_INTEGER] = function(stmt, i) return sqlite_ffi.sqlite3_column_double(stmt, i) end,
	[SQLITE_FLOAT]   = function(stmt, i) return sqlite_ffi.sqlite3_column_double(stmt, i) end,
	[SQLITE_TEXT]    = function(stmt, i)
		local n = sqlite_ffi.sqlite3_column_bytes(stmt, i)
		return ffi.string(sqlite_ffi.sqlite3_column_blob(stmt, i), n)
	end,
	[SQLITE_BLOB]    = function(stmt, i)
		local n = sqlite_ffi.sqlite3_column_bytes(stmt, i)
		return ffi.string(sqlite_ffi.sqlite3_column_blob(stmt, i), n)
	end,
	[SQLITE_NULL]    = function() return nil end,
}

-- ── parameter binding ─────────────────────────────────────────────────────────

local function bind_params(stmt, params)
	if not params then return end
	for i = 1, #params do
		local x = params[i]
		local t = type(x)
		if t == "number" then
			if x % 1 == 0 and x >= -2147483648 and x <= 2147483647 then
				sqlite_ffi.sqlite3_bind_int(stmt, i, x)
			else
				sqlite_ffi.sqlite3_bind_double(stmt, i, x)
			end
		elseif t == "string" then
			sqlite_ffi.sqlite3_bind_text(stmt, i, x, #x, SQLITE_TRANSIENT)
		elseif t == "boolean" then
			sqlite_ffi.sqlite3_bind_int(stmt, i, x and 1 or 0)
		elseif x == nil then
			sqlite_ffi.sqlite3_bind_null(stmt, i)
		else
			error("shared_db_cap: cannot bind param " .. i .. " of type " .. t, 2)
		end
	end
end

-- ── helper: exec raw SQL ──────────────────────────────────────────────────────

local function raw_exec(db, sql)
	local errmsg_ptr = ffi.new("char *[1]")
	local rc = sqlite_ffi.sqlite3_exec(db, sql, nil, nil, errmsg_ptr)
	if rc ~= SQLITE_OK then
		local msg = ffi.string(errmsg_ptr[0])
		sqlite_ffi.sqlite3_free(errmsg_ptr[0])
		return nil, "shared_db_cap: " .. msg
	end
	return true
end

-- ── setup_schema ──────────────────────────────────────────────────────────────

-- setup_schema(path, schema) -> true | nil, err
-- Creates the _-prefixed base tables, views with _app_id(), and INSTEAD OF
-- triggers for a shared database. Call once when the database is first created.
--
-- schema: array of { name = "sessions", cols = "id TEXT PRIMARY KEY, app_id TEXT NOT NULL, title TEXT" }
-- Each table MUST have an `app_id TEXT` column.
function M.setup_schema(path, schema)
	local db_mod = require("lib.platform.caps.db")
	local cap, err = db_mod.db_cap(path)
	if not cap then return nil, err end

	for _, tbl in ipairs(schema) do
		local base = "_" .. tbl.name
		-- Create base table.
		local ok2, err2 = cap.execute("CREATE TABLE IF NOT EXISTS [" .. base .. "] (" .. tbl.cols .. ")")
		if not ok2 then cap.close(); return nil, err2 end

		-- Parse column names from cols string for trigger generation.
		local col_names = {}
		for col_def in tbl.cols:gmatch("[^,]+") do
			local name = col_def:match("^%s*(%S+)")
			if name then
				-- Strip brackets if present.
				name = name:gsub("^%[", ""):gsub("%]$", "")
				col_names[#col_names + 1] = name
			end
		end

		-- Create view.
		local view_sql = "CREATE VIEW IF NOT EXISTS [" .. tbl.name ..
			"] AS SELECT * FROM [" .. base .. "] WHERE app_id = _app_id()"
		local ok3, err3 = cap.execute(view_sql)
		if not ok3 then cap.close(); return nil, err3 end

		-- Build column lists for INSERT trigger.
		local col_list = {}
		local val_list = {}
		for _, c in ipairs(col_names) do
			col_list[#col_list + 1] = "[" .. c .. "]"
			if c == "app_id" then
				val_list[#val_list + 1] = "_app_id()"
			else
				val_list[#val_list + 1] = "NEW.[" .. c .. "]"
			end
		end

		-- INSTEAD OF INSERT trigger.
		local ins_trigger = "CREATE TRIGGER IF NOT EXISTS [" .. tbl.name .. "_insert] " ..
			"INSTEAD OF INSERT ON [" .. tbl.name .. "] BEGIN " ..
			"INSERT INTO [" .. base .. "] (" .. table.concat(col_list, ", ") .. ") " ..
			"VALUES (" .. table.concat(val_list, ", ") .. "); END"
		local ok4, err4 = cap.execute(ins_trigger)
		if not ok4 then cap.close(); return nil, err4 end

		-- Build SET clause for UPDATE trigger (skip app_id).
		local set_parts = {}
		for _, c in ipairs(col_names) do
			if c ~= "app_id" then
				set_parts[#set_parts + 1] = "[" .. c .. "] = NEW.[" .. c .. "]"
			end
		end

		-- INSTEAD OF UPDATE trigger.
		local upd_trigger = "CREATE TRIGGER IF NOT EXISTS [" .. tbl.name .. "_update] " ..
			"INSTEAD OF UPDATE ON [" .. tbl.name .. "] BEGIN " ..
			"UPDATE [" .. base .. "] SET " .. table.concat(set_parts, ", ") ..
			" WHERE app_id = _app_id() AND " ..
			"[" .. col_names[1] .. "] = OLD.[" .. col_names[1] .. "]; END"
		local ok5, err5 = cap.execute(upd_trigger)
		if not ok5 then cap.close(); return nil, err5 end

		-- INSTEAD OF DELETE trigger.
		local del_trigger = "CREATE TRIGGER IF NOT EXISTS [" .. tbl.name .. "_delete] " ..
			"INSTEAD OF DELETE ON [" .. tbl.name .. "] BEGIN " ..
			"DELETE FROM [" .. base .. "] WHERE app_id = _app_id() AND " ..
			"[" .. col_names[1] .. "] = OLD.[" .. col_names[1] .. "]; END"
		local ok6, err6 = cap.execute(del_trigger)
		if not ok6 then cap.close(); return nil, err6 end
	end

	cap.close()
	return true
end

-- ── constructor ───────────────────────────────────────────────────────────────

-- shared_db_cap(path, app_id, tables, opts?) -> cap | nil, err
-- tables: array of view names (e.g. {"sessions", "messages"})
-- The corresponding _-prefixed base tables, views, and triggers must already
-- exist (via setup_schema).
function M.shared_db_cap(path, app_id, tables, opts)
	opts = opts or {}
	local readonly = opts.readonly

	local db_ptr = ffi.new("sqlite3 *[1]")
	local flags = readonly and SQLITE_OPEN_READONLY or SQLITE_OPEN_READWRITE
	local rc = sqlite_ffi.sqlite3_open_v2(path, db_ptr, flags, nil)
	if rc ~= SQLITE_OK then
		local msg = ffi.string(sqlite_ffi.sqlite3_errmsg(db_ptr[0]))
		sqlite_ffi.sqlite3_close_v2(db_ptr[0])
		return nil, "shared_db_cap: open failed: " .. msg
	end
	local db = db_ptr[0]

	local function errmsg()
		return ffi.string(sqlite_ffi.sqlite3_errmsg(db))
	end

	-- Register _app_id() custom function that returns this connection's app_id.
	local app_id_c = ffi.new("const char[?]", #app_id + 1, app_id)
	local app_id_len = #app_id

	local app_id_func = ffi.cast(
		"void (*)(sqlite3_context *, int, sqlite3_value **)",
		function(ctx, _nargs, _args)
			sqlite_ffi.sqlite3_result_text(ctx, app_id_c, app_id_len, SQLITE_TRANSIENT)
		end
	)

	rc = sqlite_ffi.sqlite3_create_function_v2(
		db, "_app_id", 0, SQLITE_UTF8, nil,
		app_id_func, nil, nil, nil
	)
	if rc ~= SQLITE_OK then
		local msg = errmsg()
		app_id_func:free()
		sqlite_ffi.sqlite3_close_v2(db)
		return nil, "shared_db_cap: create_function failed: " .. msg
	end

	-- Protected table set (base tables are _-prefixed).
	local protected_bases = {}
	for _, name in ipairs(tables) do
		protected_bases["_" .. name] = true
	end

	-- Authorizer: block direct access to _-prefixed base tables, DDL, ATTACH.
	-- The 5th callback arg (arg4) is the innermost trigger or view name that
	-- caused the access, or NULL for direct top-level statements. We allow
	-- base table access from views/triggers (non-NULL) but block direct access.
	local auth_cb = ffi.cast(
		"int (*)(void *, int, const char *, const char *, const char *, const char *)",
		function(_, action, arg1, _arg2, _arg3, arg4)
			-- Always allow: SELECT, TRANSACTION, FUNCTION, PRAGMA.
			if action == SQLITE_SELECT or action == SQLITE_TRANSACTION
				or action == SQLITE_FUNCTION or action == SQLITE_PRAGMA then
				return SQLITE_OK
			end

			-- READ: allow unless it's a direct read of a protected base table.
			if action == SQLITE_READ then
				if arg1 ~= nil then
					local tbl = ffi.string(arg1)
					if protected_bases[tbl] then
						-- Allow if coming from a view/trigger (arg4 non-NULL).
						if arg4 ~= nil then return SQLITE_OK end
						return SQLITE_DENY
					end
				end
				return SQLITE_OK
			end

			-- Allow all temp-schema operations.
			if action == SQLITE_CREATE_TEMP_TABLE or action == SQLITE_CREATE_TEMP_INDEX
				or action == SQLITE_CREATE_TEMP_TRIGGER or action == SQLITE_CREATE_TEMP_VIEW
				or action == SQLITE_DROP_TEMP_TABLE or action == SQLITE_DROP_TEMP_INDEX
				or action == SQLITE_DROP_TEMP_TRIGGER or action == SQLITE_DROP_TEMP_VIEW then
				return SQLITE_OK
			end

			-- INSERT/UPDATE/DELETE: allow on views (triggers handle scoping).
			-- Block direct writes to protected base tables unless from a trigger.
			if action == SQLITE_INSERT or action == SQLITE_UPDATE
				or action == SQLITE_DELETE then
				if arg1 ~= nil then
					local tbl = ffi.string(arg1)
					if protected_bases[tbl] then
						-- Allow if coming from a trigger (arg4 non-NULL).
						if arg4 ~= nil then return SQLITE_OK end
						return SQLITE_DENY
					end
				end
				return SQLITE_OK
			end

			-- Block main-schema DDL.
			if action == SQLITE_CREATE_TABLE or action == SQLITE_CREATE_INDEX
				or action == SQLITE_CREATE_TRIGGER or action == SQLITE_CREATE_VIEW
				or action == SQLITE_DROP_TABLE or action == SQLITE_DROP_INDEX
				or action == SQLITE_DROP_TRIGGER or action == SQLITE_DROP_VIEW then
				return SQLITE_DENY
			end

			-- Block ATTACH/DETACH.
			if action == SQLITE_ATTACH or action == SQLITE_DETACH then
				return SQLITE_DENY
			end

			return SQLITE_DENY
		end
	)

	sqlite_ffi.sqlite3_set_authorizer(db, auth_cb, nil)

	local revoked = false

	-- ── exec (writes go through views + INSTEAD OF triggers) ──────────────────

	local function exec(sql)
		if revoked then return nil, "shared_db_cap: capability revoked" end
		local c_sql = sql
		local next_sql = ffi.new("const char *[1]")
		local stmt_ptr = ffi.new("sqlite3_stmt *[1]")
		local result, result_err = true, nil
		while true do
			if sqlite_ffi.sqlite3_prepare_v2(db, c_sql, -1, stmt_ptr, next_sql) ~= SQLITE_OK then
				result, result_err = nil, "shared_db_cap: prepare: " .. errmsg()
				break
			end
			local stmt = stmt_ptr[0]
			if stmt == nil then break end
			local ret = sqlite_ffi.sqlite3_step(stmt)
			if ret ~= SQLITE_DONE and ret ~= SQLITE_ROW then
				result_err = errmsg()
				sqlite_ffi.sqlite3_finalize(stmt)
				result = nil
				result_err = "shared_db_cap: exec: " .. result_err
				break
			end
			sqlite_ffi.sqlite3_finalize(stmt)
			c_sql = next_sql[0]
			if c_sql == nil then break end
		end
		return result, result_err
	end

	-- ── query (reads go through views, filtered by _app_id()) ─────────────────

	local function query(sql, params)
		if revoked then return nil, "shared_db_cap: capability revoked" end
		local stmt_ptr = ffi.new("sqlite3_stmt *[1]")
		if sqlite_ffi.sqlite3_prepare_v2(db, sql, #sql + 1, stmt_ptr, nil) ~= SQLITE_OK then
			return nil, "shared_db_cap: prepare: " .. errmsg()
		end
		local stmt = stmt_ptr[0]
		local ok2, bind_err = pcall(bind_params, stmt, params)
		if not ok2 then
			sqlite_ffi.sqlite3_finalize(stmt)
			return nil, "shared_db_cap: bind: " .. tostring(bind_err)
		end
		local col_count = sqlite_ffi.sqlite3_column_count(stmt)
		local col_names = {}
		for i = 0, col_count - 1 do
			col_names[i + 1] = ffi.string(sqlite_ffi.sqlite3_column_name(stmt, i))
		end
		local rows = {}
		while true do
			local code = sqlite_ffi.sqlite3_step(stmt)
			if code == SQLITE_ROW then
				local row = {}
				for i = 0, col_count - 1 do
					row[col_names[i + 1]] = col_read[sqlite_ffi.sqlite3_column_type(stmt, i)](stmt, i)
				end
				rows[#rows + 1] = row
			elseif code == SQLITE_DONE then
				break
			else
				local msg = errmsg()
				sqlite_ffi.sqlite3_finalize(stmt)
				return nil, "shared_db_cap: step: " .. msg
			end
		end
		sqlite_ffi.sqlite3_finalize(stmt)
		return rows
	end

	local function close()
		sqlite_ffi.sqlite3_set_authorizer(db, nil, nil)
		auth_cb:free()
		app_id_func:free()
		sqlite_ffi.sqlite3_close_v2(db)
	end

	local function revoke() revoked = true end

	local setup_done = false
	local function setup(tables)
		if revoked then error("shared_db_cap: capability revoked", 2) end
		if setup_done then error("shared_db_cap: setup() already called", 2) end
		local ok, err = M.setup_schema(path, tables)
		if ok then setup_done = true end
		return ok, err
	end

	-- make_attenuate(is_sub_readonly) builds an attenuate function for a cap
	-- at the given readonly level. sub-caps share the same connection.
	local function make_attenuate(is_sub_readonly)
		return function(sub_opts)
			if revoked then return nil, "shared_db: capability revoked" end
			sub_opts = sub_opts or {}
			local new_readonly = sub_opts.readonly
			if new_readonly == false and is_sub_readonly then
				return nil, "shared_db.attenuate: cannot grant write not held"
			end
			-- If sub_opts.readonly is nil, inherit current level.
			if new_readonly == nil then new_readonly = is_sub_readonly end
			local sub_revoked = false
			local sub = {
				_type = "shared_db",
				query = function(sql, params)
					if revoked or sub_revoked then return nil, "shared_db: capability revoked" end
					return query(sql, params)
				end,
				close = function() end,  -- sub-cap doesn't own the connection
				setup = setup,
			}
			if not new_readonly then
				sub.execute = function(sql)
					if revoked or sub_revoked then return nil, "shared_db: capability revoked" end
					return exec(sql)
				end
			end
			sub.attenuate = make_attenuate(new_readonly)
			return sub, function() sub_revoked = true end
		end
	end

	if readonly then
		local cap = { _type = "shared_db", query = query, close = close, setup = setup }
		cap.attenuate = make_attenuate(true)
		return cap, revoke
	end

	local cap = { _type = "shared_db", execute = exec, query = query, close = close, setup = setup }
	cap.attenuate = make_attenuate(false)
	return cap, revoke
end

function M.risk(decl)
	if decl.readonly then
		return { severity = "low", text = "Reads a shared SQLite database." }
	end
	return { severity = "medium", text = "Reads and writes a shared SQLite database accessible to multiple apps." }
end

return M
