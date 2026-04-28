if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local ffi = require("ffi")

local mod = {}

ffi.cdef [[
	// opaque structs
	typedef struct sqlite3 sqlite3;
	typedef struct sqlite3_stmt sqlite3_stmt;
	typedef int64_t sqlite3_int64;

	int sqlite3_open(const char *filename, sqlite3 **ppDb);
	int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
	int sqlite3_step(sqlite3_stmt*);
	int sqlite3_reset(sqlite3_stmt *pStmt);

	int sqlite3_get_autocommit(sqlite3*);
	sqlite3_int64 sqlite3_last_insert_rowid(sqlite3*);
	int sqlite3_changes(sqlite3*);
	sqlite3_int64 sqlite3_changes64(sqlite3*);

	// reading columns
	int sqlite3_column_count(sqlite3_stmt *pStmt);
	int sqlite3_column_type(sqlite3_stmt*, int iCol);
	int sqlite3_column_bytes(sqlite3_stmt*, int iCol);
	const void *sqlite3_column_blob(sqlite3_stmt*, int iCol);
	double sqlite3_column_double(sqlite3_stmt*, int iCol);

	// binding values
	int sqlite3_bind_blob(sqlite3_stmt*, int, const void*, int n, void(*)(void*));
	int sqlite3_bind_double(sqlite3_stmt*, int, double);
	int sqlite3_bind_int(sqlite3_stmt*, int, int);
	int sqlite3_bind_int64(sqlite3_stmt*, int, sqlite3_int64);
	int sqlite3_bind_null(sqlite3_stmt*, int);
	int sqlite3_bind_text(sqlite3_stmt*,int,const char*,int,void(*)(void*));

	int sqlite3_finalize(sqlite3_stmt *pStmt);
	int sqlite3_close_v2(sqlite3*);

	const char *sqlite3_errmsg(sqlite3*);
]]

local double_t = ffi.typeof("double")
local float_t  = ffi.typeof("float")
local function is_float_cdata(a)
	local t = ffi.typeof(a)
	return t == double_t or t == float_t
end

local SQLITE_TRANSIENT = ffi.cast("void(*)(void*)", -1) -- sqlite copies the value

-- datatypes
local SQLITE_INTEGER = 1
local SQLITE_FLOAT   = 2
local SQLITE_TEXT    = 3
local SQLITE_BLOB    = 4
local SQLITE_NULL    = 5

--[[@type sqlite_ffi]]
local sqlite_ffi
local sqlite_loaded_from
if ffi.os == "Windows" then
	if ffi.arch == "x64" then
		sqlite_loaded_from = "dep/sqlite.dll"
	else
		sqlite_loaded_from = "dep/sqlite-x86.dll"
	end
	sqlite_ffi = ffi.load(sqlite_loaded_from)
else
	-- Build vendored name first (platform-specific compiled libraries).
	local function vendored_name()
		local os, arch = ffi.os, ffi.arch
		if os == "Linux" then
			return arch == "arm64" and "dep/libsqlite3-linux-aarch64.so"
			                       or  "dep/libsqlite3-linux-x86_64.so"
		elseif os == "OSX" then
			return arch == "arm64" and "dep/libsqlite3-macos-arm64.dylib" or nil
		end
		return nil
	end
	local names = {}
	local v = vendored_name()
	if v then names[#names + 1] = v end
	names[#names + 1] = "sqlite3"
	names[#names + 1] = "libsqlite3.so"
	names[#names + 1] = "libsqlite3.so.0"          -- Linux system
	names[#names + 1] = "libsqlite3.dylib"
	names[#names + 1] = "/usr/lib/libsqlite3.dylib" -- macOS system
	for _, name in ipairs(names) do
		local ok, lib = pcall(ffi.load, name)
		if ok then sqlite_ffi = lib; sqlite_loaded_from = name; break end
	end
	if not sqlite_ffi then
		error("sqlite3: no shared library found (tried: " .. table.concat(names, ", ") .. ")")
	end
end

mod._tier = "system-sqlite"
mod._loaded_from = sqlite_loaded_from

-- ── column reading (module-level, no per-row allocation) ─────────────────────

-- Each entry reads column i from stmt and returns a Lua value.
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

--[[@param stmt sqlite_stmt_c]]
--[[@param params table]]
--[[@param length integer required because values may be nil]]
local function bind(stmt, params, length)
	for i = 1, length do
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
		elseif t == "cdata" then
			local n = tonumber(x)
			if n ~= nil then
				if is_float_cdata(x) then sqlite_ffi.sqlite3_bind_double(stmt, i, x)
				else sqlite_ffi.sqlite3_bind_int64(stmt, i, x) end
			else
				error("sqlite bind: cannot bind cdata " .. tostring(ffi.typeof(x)))
			end
		elseif x == nil then
			sqlite_ffi.sqlite3_bind_null(stmt, i)
		else
			error("sqlite bind: cannot bind type " .. t)
		end
	end
end

-- ── database ──────────────────────────────────────────────────────────────────

--[[@class sqlite]]
--[[@field db sqlite3*[1] ]]
local sqlite = {}
sqlite.__index = sqlite
mod.sqlite = sqlite

--[[@return sqlite? database, string? error]] --[[@param path string]]
sqlite.open = function(self, path)
	local db = ffi.new("sqlite3 *[1]")
	if sqlite_ffi.sqlite3_open(path, db) ~= 0 then
		return nil, "sqlite: sqlite3_open failed"
	end
	return setmetatable({ db = db }, self)
end

--[[@return sqlite? database, string? error]] --[[@param path string]]
mod.open = function(path) return sqlite:open(path) end

sqlite.close = function(self) sqlite_ffi.sqlite3_close_v2(self.db[0]) end

--[[@return integer]]
sqlite.last_insert_rowid = function(self)
	return tonumber(sqlite_ffi.sqlite3_last_insert_rowid(self.db[0]))
end
sqlite.get_autocommit = function(self)
	return sqlite_ffi.sqlite3_get_autocommit(self.db[0]) ~= 0
end
--[[@return integer]]
sqlite.changes = function(self)
	return tonumber(sqlite_ffi.sqlite3_changes64(self.db[0]))
end

local function db_errmsg(self)
	return ffi.string(sqlite_ffi.sqlite3_errmsg(self.db[0]))
end

--[[@return true? success, string? error]] --[[@param sql string]] --[[@param ... number|string|boolean?]]
sqlite.execute = function(self, sql, ...)
	local c_sql = sql
	local next_sql = ffi.new("const char *[1]")
	local stmt_ptr = ffi.new("sqlite3_stmt *[1]")
	while true do
		if sqlite_ffi.sqlite3_prepare_v2(self.db[0], c_sql, -1, stmt_ptr, next_sql) ~= 0 then
			return nil, "sqlite: prepare: " .. db_errmsg(self)
		end
		local stmt = stmt_ptr[0]
		if stmt == nil then break end
		bind(stmt, { ... }, select("#", ...))
		local ret = sqlite_ffi.sqlite3_step(stmt)
		if ret ~= 101 then -- SQLITE_DONE
			local msg = db_errmsg(self)
			sqlite_ffi.sqlite3_finalize(stmt)
			return nil, "sqlite: step: " .. msg
		end
		sqlite_ffi.sqlite3_finalize(stmt)
		c_sql = next_sql[0]
		if c_sql == nil then break end
	end
	return true
end

-- query: returns an iterator. Each call yields multiple return values (one per column).
-- Signals done as: nil, "sqlite: done"
-- Signals error as: nil, "sqlite: <message>"
-- NOTE: the iterator returns nil for a NULL column; since done is also nil, keep a
-- non-nullable sentinel column first if any column may be NULL (SELECT 1, col ...).
--[[@return (fun():...unknown)? iter, string? error]] --[[@param sql string]] --[[@param ... number|string|boolean?]]
sqlite.query = function(self, sql, ...)
	local stmt_ptr = ffi.new("sqlite3_stmt *[1]")
	if sqlite_ffi.sqlite3_prepare_v2(self.db[0], sql, #sql + 1, stmt_ptr, nil) ~= 0 then
		return nil, "sqlite: prepare: " .. db_errmsg(self)
	end
	local stmt = stmt_ptr[0]
	bind(stmt, { ... }, select("#", ...))
	local col_count = sqlite_ffi.sqlite3_column_count(stmt) -- once, before any rows
	return function()
		local code = sqlite_ffi.sqlite3_step(stmt)
		if code == 100 then -- SQLITE_ROW
			if col_count == 0 then return nil, "sqlite: no columns" end
			local columns = {}
			for i = 0, col_count - 1 do
				columns[i + 1] = col_read[sqlite_ffi.sqlite3_column_type(stmt, i)](stmt, i)
			end
			return unpack(columns)
		elseif code == 101 then -- SQLITE_DONE
			sqlite_ffi.sqlite3_finalize(stmt)
			return nil, "sqlite: done"
		else
			return nil, "sqlite: step: unhandled code " .. code
		end
	end
end

-- ── prepared statements ───────────────────────────────────────────────────────
--
-- db:prepare(sql) → stmt | nil, err
--
-- Returns a reusable statement object. The statement is kept compiled across
-- calls; bind params, execute, then reset for the next use.
--
-- stmt:exec(...)   → true | nil, err   (INSERT / UPDATE / DELETE)
-- stmt:rows(...)   → iterator           (SELECT; same semantics as db:query)
-- stmt:close()

--[[@class sqlite_stmt]]
--[[@field _stmt sqlite3_stmt*]]
--[[@field _db sqlite]]
local stmt_mt = {}
stmt_mt.__index = stmt_mt

stmt_mt.close = function(self)
	if self._stmt ~= nil then
		sqlite_ffi.sqlite3_finalize(self._stmt)
		self._stmt = nil
	end
end

stmt_mt.exec = function(self, ...)
	local stmt = self._stmt
	sqlite_ffi.sqlite3_reset(stmt)
	bind(stmt, { ... }, select("#", ...))
	local ret = sqlite_ffi.sqlite3_step(stmt)
	if ret ~= 101 then -- SQLITE_DONE
		return nil, "sqlite: step: " .. db_errmsg(self._db)
	end
	return true
end

stmt_mt.rows = function(self, ...)
	local stmt = self._stmt
	sqlite_ffi.sqlite3_reset(stmt)
	bind(stmt, { ... }, select("#", ...))
	local col_count = sqlite_ffi.sqlite3_column_count(stmt)
	return function()
		local code = sqlite_ffi.sqlite3_step(stmt)
		if code == 100 then -- SQLITE_ROW
			if col_count == 0 then return nil, "sqlite: no columns" end
			local columns = {}
			for i = 0, col_count - 1 do
				columns[i + 1] = col_read[sqlite_ffi.sqlite3_column_type(stmt, i)](stmt, i)
			end
			return unpack(columns)
		elseif code == 101 then -- SQLITE_DONE
			return nil, "sqlite: done"
		else
			return nil, "sqlite: step: unhandled code " .. code
		end
	end
end

--[[@return sqlite_stmt? stmt, string? err]] --[[@param sql string]]
sqlite.prepare = function(self, sql)
	local stmt_ptr = ffi.new("sqlite3_stmt *[1]")
	if sqlite_ffi.sqlite3_prepare_v2(self.db[0], sql, #sql + 1, stmt_ptr, nil) ~= 0 then
		return nil, "sqlite: prepare: " .. db_errmsg(self)
	end
	return setmetatable({ _stmt = stmt_ptr[0], _db = self }, stmt_mt)
end

-- ── schema metadata ───────────────────────────────────────────────────────────

--[[@class sqlite_table]]
--[[@field type "table"|"index"|"view"|"trigger"]]
--[[@field name string]]
--[[@field table_name string]]
--[[@field root_page integer]]
--[[@field sql string]]

local table_keyorder = { "type", "name", "table_name", "root_page", "sql" }

local function tables_raw(self)
	local f = self:query("SELECT type, name, tbl_name, rootpage, sql FROM sqlite_schema WHERE type='table' ORDER BY name")
	return function()
		local type_, name, table_name, root_page, sql = f()
		if not type_ then return end
		return { type = type_, name = name, table_name = table_name, root_page = root_page, sql = sql, __keyorder = table_keyorder }
	end
end

sqlite.tables = package.loaded["lib.functional.iterable"] and function(self)
	return require("lib.functional.iterable").iter(tables_raw(self))
end or tables_raw

return mod
