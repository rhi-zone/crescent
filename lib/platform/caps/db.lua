-- lib/platform/caps/db.lua
-- db_cap(path, opts?) -> capability table
-- Opens (or creates) a SQLite database at path and exposes a safe API.
--
-- opts.readonly: boolean — open with SQLITE_OPEN_READONLY (writes fail at SQLite level)
--
-- Capability API (passed to sandbox as caps.db):
--   cap.exec(sql)              -> true | nil, err
--   cap.query(sql, params?)    -> rows | nil, err
--   cap.close()                -> nil

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi = require("ffi")

local M = {}

-- ── FFI declarations ──────────────────────────────────────────────────────────
--
-- We declare only what db_cap needs, keeping this file self-contained.
-- lib/sqlite/init.lua has a broader set; both may coexist because LuaJIT
-- deduplicates cdef declarations (re-declaring the same struct/function is a
-- no-op as long as the text is identical).

local ok_cdef = pcall(ffi.cdef, [[
	typedef struct sqlite3      sqlite3;
	typedef struct sqlite3_stmt sqlite3_stmt;
	typedef int64_t             sqlite3_int64;

	int         sqlite3_open(const char *filename, sqlite3 **ppDb);
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
]])
if not ok_cdef then
	-- Already declared by lib/sqlite/init.lua — that's fine, declarations match.
end

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
		error("db_cap: sqlite3 shared library not found (tried: " .. table.concat(names, ", ") .. ")")
	end
end

-- ── constants ─────────────────────────────────────────────────────────────────

local SQLITE_OPEN_READONLY  = 0x00000001
local SQLITE_OPEN_READWRITE = 0x00000002
local SQLITE_OPEN_CREATE    = 0x00000004

local SQLITE_ROW  = 100
local SQLITE_DONE = 101

local SQLITE_INTEGER = 1
local SQLITE_FLOAT   = 2
local SQLITE_TEXT    = 3
local SQLITE_BLOB    = 4
local SQLITE_NULL    = 5

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
			error("db_cap: cannot bind param " .. i .. " of type " .. t, 2)
		end
	end
end

-- ── constructor ───────────────────────────────────────────────────────────────

-- db_cap(path, opts?) -> cap | nil, err
--   path: filesystem path passed to sqlite3_open; ":memory:" is valid.
--   opts.readonly: boolean — open with SQLITE_OPEN_READONLY (no writes at SQLite level)
function M.db_cap(path, opts)
	opts = opts or {}
	local db_ptr = ffi.new("sqlite3 *[1]")
	local rc
	if opts.readonly then
		rc = sqlite_ffi.sqlite3_open_v2(path, db_ptr, SQLITE_OPEN_READONLY, nil)
	else
		rc = sqlite_ffi.sqlite3_open_v2(path, db_ptr,
			SQLITE_OPEN_READWRITE + SQLITE_OPEN_CREATE, nil)
	end
	if rc ~= 0 then
		local msg = ffi.string(sqlite_ffi.sqlite3_errmsg(db_ptr[0]))
		sqlite_ffi.sqlite3_close_v2(db_ptr[0])
		return nil, "db_cap: open failed: " .. msg
	end
	local db = db_ptr[0]

	local function errmsg()
		return ffi.string(sqlite_ffi.sqlite3_errmsg(db))
	end

	-- exec(sql) -> true | nil, err
	-- Execute one or more SQL statements that produce no result rows.
	local function exec(sql)
		local c_sql = sql
		local next_sql = ffi.new("const char *[1]")
		local stmt_ptr = ffi.new("sqlite3_stmt *[1]")
		while true do
			if sqlite_ffi.sqlite3_prepare_v2(db, c_sql, -1, stmt_ptr, next_sql) ~= 0 then
				return nil, "db_cap: prepare: " .. errmsg()
			end
			local stmt = stmt_ptr[0]
			if stmt == nil then break end
			local ret = sqlite_ffi.sqlite3_step(stmt)
			if ret ~= SQLITE_DONE then
				local msg = errmsg()
				sqlite_ffi.sqlite3_finalize(stmt)
				return nil, "db_cap: exec: " .. msg
			end
			sqlite_ffi.sqlite3_finalize(stmt)
			c_sql = next_sql[0]
			if c_sql == nil then break end
		end
		return true
	end

	-- query(sql, params?) -> rows | nil, err
	-- Execute a SELECT (or any row-returning) statement.
	-- params: optional array of values for ? placeholders.
	-- Returns an array of { colname = value, ... } tables.
	local function query(sql, params)
		local stmt_ptr = ffi.new("sqlite3_stmt *[1]")
		if sqlite_ffi.sqlite3_prepare_v2(db, sql, #sql + 1, stmt_ptr, nil) ~= 0 then
			return nil, "db_cap: prepare: " .. errmsg()
		end
		local stmt = stmt_ptr[0]
		local ok, bind_err = pcall(bind_params, stmt, params)
		if not ok then
			sqlite_ffi.sqlite3_finalize(stmt)
			return nil, "db_cap: bind: " .. tostring(bind_err)
		end
		local col_count = sqlite_ffi.sqlite3_column_count(stmt)
		-- Collect column names once before stepping.
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
				return nil, "db_cap: step: " .. msg
			end
		end
		sqlite_ffi.sqlite3_finalize(stmt)
		return rows
	end

	local function close()
		sqlite_ffi.sqlite3_close_v2(db)
	end

	return { exec = exec, query = query, close = close }
end

return M
