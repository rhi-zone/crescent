if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi = require("ffi")
local sqlite = require("lib.sqlite")

local M = {}

--:: sqlite = { db: cdata, execute: (self: sqlite, string, ...unknown) -> (true | nil, string | nil), query: (self: sqlite, string, ...unknown) -> ((() -> unknown) | nil, string | nil), close: (self: sqlite) -> nil, last_insert_rowid: (self: sqlite) -> number | nil, changes: (self: sqlite) -> number | nil, ... }
--:: Conn = { _db: sqlite, ... }
--:: Select = { _db: sqlite, _table: string, _columns: { [integer]: string } | nil, _wheres: { [integer]: unknown }, _where_params: { [integer]: unknown }, _order: string | nil, _limit: number | nil, _offset: number | nil, ... }
--:: Insert = { _db: sqlite, _table: string, _columns: { [integer]: string } | nil, _values: { [string]: unknown } | nil, _on_conflict: string | nil, _returning: { [integer]: string } | nil, ... }
--:: Update = { _db: sqlite, _table: string, _set: { [string]: unknown } | nil, _sets: { [integer]: unknown } | nil, _wheres: { [integer]: unknown }, _where_params: { [integer]: unknown }, _returning: { [integer]: string } | nil, ... }
--:: Delete = { _db: sqlite, _table: string, _wheres: { [integer]: unknown }, _where_params: { [integer]: unknown }, _returning: { [integer]: string } | nil, ... }

-- ── FFI: sqlite3_column_name (not exposed by lib.sqlite) ───────────────────

pcall(ffi.cdef, "const char *sqlite3_column_name(sqlite3_stmt*, int N);")

local sqlite_lib
do
	local names
	if ffi.os == "Windows" then
		names = ffi.arch == "x64" and { "dep/sqlite.dll" } or { "dep/sqlite-x86.dll" }
	else
		local function vendored_name()
			local os, arch = ffi.os, ffi.arch
			if os == "Linux" then
				return arch == "arm64" and "dep/libsqlite3-linux-aarch64.so"
				                       or  "dep/libsqlite3-linux-x86_64.so"
			elseif os == "OSX" then
				return arch == "arm64" and "dep/libsqlite3-macos-arm64.dylib"
				                       or  "dep/libsqlite3-macos-x86_64.dylib"
			end
			return nil
		end
		names = {}
		local v = vendored_name()
		if v then names[#names + 1] = v end
		names[#names + 1] = "sqlite3"
		names[#names + 1] = "libsqlite3.so"
		names[#names + 1] = "libsqlite3.so.0"
		names[#names + 1] = "libsqlite3.dylib"
		names[#names + 1] = "/usr/lib/libsqlite3.dylib"
	end
	for _, name in ipairs(names) do
		local ok, lib = pcall(ffi.load, name)
		if ok then sqlite_lib = lib; break end
	end
end

-- ── Helpers ─────────────────────────────────────────────────────────────────

--: ({ [string]: unknown, ... }) -> { [string]: unknown }
local function shallow_copy(t)
	local out = {}
	for k, v in pairs(t) do out[k] = v end
	return out
end

--: ({ [integer]: unknown }) -> { [integer]: unknown }
local function copy_array(t)
	local out = {}
	for i = 1, #t do out[i] = t[i] end
	return out
end

--: ({ query: (self: unknown, string) -> (unknown, string | nil), ... }, string) -> (string[] | nil, string | nil)
local function get_column_names(db, table_name)
	local iter_raw, err = db:query("PRAGMA table_info(" .. table_name .. ")")
	if not iter_raw then return nil, err end
	local iter = iter_raw --[[:! () -> (unknown, unknown)]]
	local names = {}
	while true do
		local cid, name = iter()
		if cid == nil then break end
		names[#names + 1] = name --[[:! string]]
	end
	return names
end

--- Get column names from an arbitrary SQL statement via sqlite3_column_name.
--: ({ prepare: (self: unknown, string) -> (unknown, string | nil), ... }, string) -> string[]
local function query_column_names(db, sql)
	if not sqlite_lib then return {} end
	local stmt_raw, err = db:prepare(sql)
	if not stmt_raw then return {} end
	local stmt = stmt_raw --[[:! { _stmt: cdata, close: (self: unknown) -> nil, ... }]]
	local raw = stmt._stmt
	local slib_ = sqlite_lib --[[:! { sqlite3_column_count: (cdata) -> integer, sqlite3_column_name: (cdata, integer) -> cdata }]]
	local col_count = slib_.sqlite3_column_count(raw)
	local names = {}
	for i = 0, col_count - 1 do
		local cname = slib_.sqlite3_column_name(raw, i)
		if cname ~= nil then
			names[i + 1] = ffi.string(cname)
		else
			names[i + 1] = "col" .. (i + 1)
		end
	end
	stmt:close()
	return names
end

--: (() -> (...unknown), string[]) -> { [string]: unknown }[]
local function collect_rows(iter, col_names)
	local rows = {}
	while true do
		local vals = { iter() }
		if vals[1] == nil then break end
		local row = {}
		for i, name in ipairs(col_names) do
			row[name] = vals[i]
		end
		rows[#rows + 1] = row
	end
	return rows
end

-- ── SELECT builder ──────────────────────────────────────────────────────────

local Select = {}
Select.__index = Select

--: (Select, ...unknown) -> Select
function Select:columns(...)
	local q = shallow_copy(self) --[[:! Select]]
	q._columns = { ... }
	return setmetatable(q, Select) --[[: unknown]]
end

--: (Select, string, ...unknown) -> Select
function Select:where(clause, ...)
	local q = shallow_copy(self) --[[:! Select]]
	q._wheres = copy_array(self._wheres)
	q._where_params = copy_array(self._where_params)
	q._wheres[#q._wheres + 1] = clause
	local n = select("#", ...)
	for i = 1, n do
		q._where_params[#q._where_params + 1] = select(i, ...)
	end
	return setmetatable(q, Select) --[[: unknown]]
end

--: (Select, string) -> Select
function Select:order(val)
	local q = shallow_copy(self) --[[:! Select]]
	q._order = val
	return setmetatable(q, Select) --[[: unknown]]
end

--: (Select, number) -> Select
function Select:limit(val)
	local q = shallow_copy(self) --[[:! Select]]
	q._limit = val
	return setmetatable(q, Select) --[[: unknown]]
end

--: (Select, number) -> Select
function Select:offset(val)
	local q = shallow_copy(self) --[[:! Select]]
	q._offset = val
	return setmetatable(q, Select) --[[: unknown]]
end

--: (Select) -> (string, { [integer]: unknown })
function Select:_build()
	local cols = self._columns and table.concat(self._columns, ", ") or "*"
	local sql = "SELECT " .. cols .. " FROM " .. self._table
	local params = copy_array(self._where_params)
	if #self._wheres > 0 then
		sql = sql .. " WHERE " .. table.concat(self._wheres --[[:! { [integer]: string }]], " AND ")
	end
	if self._order then sql = sql .. " ORDER BY " .. self._order end
	if self._limit then sql = sql .. " LIMIT " .. self._limit end
	if self._offset then sql = sql .. " OFFSET " .. self._offset end
	return sql, params
end

--: (Select) -> (string[] | nil, string | nil)
function Select:_resolve_col_names()
	if self._columns and #self._columns > 0 then
		return self._columns
	end
	return get_column_names(self._db, self._table)
end

--: (Select) -> ({ [string]: unknown }[] | nil, string | nil)
function Select:all()
	local db_ = self._db
	local select_ = self --[[: unknown]]
	local sql, params = select_:_build()
	local iter, err = db_:query(sql, unpack(params))
	if not iter then return nil, err end
	local col_names, cerr = select_:_resolve_col_names()
	if not col_names then return nil, cerr end
	return collect_rows(iter, col_names)
end

--: (Select) -> ({ [string]: unknown } | nil, string | nil)
function Select:first()
	local q = (self --[[: unknown]]):limit(1)
	local rows, err = q:all()
	if not rows then return nil, err end
	return rows[1]
end

--: (Select) -> ((number | nil), (string | nil))
function Select:count()
	local db_ = self._db
	local select_ = self --[[: unknown]]
	local sql, params = select_:_build()
	local count_sql = "SELECT COUNT(*) FROM (" .. sql .. ")"
	local iter, err = db_:query(count_sql, unpack(params))
	if not iter then return nil, err end
	local n = iter()
	return n
end

-- ── INSERT builder ──────────────────────────────────────────────────────────

local Insert = {}
Insert.__index = Insert

--: (Insert, { [string]: unknown }) -> Insert
function Insert:values(vals)
	local q = shallow_copy(self) --[[:! Insert]]
	q._values = vals
	return setmetatable(q, Insert) --[[: unknown]]
end

--: (Insert, ...unknown) -> Insert
function Insert:returning(...)
	local q = shallow_copy(self) --[[:! Insert]]
	q._returning = { ... }
	return setmetatable(q, Insert) --[[: unknown]]
end

--: (Insert) -> (string, { [integer]: unknown })
function Insert:_build()
	local values_ = self._values or {} --[[:! { [string]: unknown }]]
	--: { [integer]: string }
	local keys = {}
	for k in pairs(values_) do keys[#keys + 1] = k end
	table.sort(keys)
	--: { [integer]: string }
	local placeholders = {}
	local params = {}
	for i, k in ipairs(keys) do
		placeholders[i] = "?"
		params[i] = values_[k]
	end
	local sql = "INSERT INTO " .. self._table .. " (" .. table.concat(keys, ", ") ..
		") VALUES (" .. table.concat(placeholders, ", ") .. ")"
	if self._returning and #self._returning > 0 then
		sql = sql .. " RETURNING " .. table.concat(self._returning, ", ")
	end
	return sql, params
end

--: (Insert) -> ((true | nil), (string | nil))
function Insert:exec()
	local db_ = self._db
	local sql, params = (self --[[: unknown]]):_build()
	return db_:execute(sql, unpack(params))
end

--: (Insert) -> ({ [string]: unknown } | nil, string | nil)
function Insert:first()
	local db_ = self._db
	local sql, params = (self --[[: unknown]]):_build()
	local iter, err = db_:query(sql, unpack(params))
	if not iter then return nil, err end
	local ret_ = self._returning
	if not ret_ then return nil end
	local ret2_ = ret_ --[[:! { [integer]: string }]]
	if #ret2_ == 0 then return nil end
	return collect_rows(iter, ret2_)[1]
end

-- ── UPDATE builder ──────────────────────────────────────────────────────────

local Update = {}
Update.__index = Update

--: (Update, { [string]: unknown }) -> Update
function Update:set(vals)
	local q = shallow_copy(self) --[[:! Update]]
	q._set = vals
	return setmetatable(q, Update) --[[: unknown]]
end

--: (Update, string, ...unknown) -> Update
function Update:where(clause, ...)
	local q = shallow_copy(self) --[[:! Update]]
	q._wheres = copy_array(self._wheres)
	q._where_params = copy_array(self._where_params)
	q._wheres[#q._wheres + 1] = clause
	local n = select("#", ...)
	for i = 1, n do
		q._where_params[#q._where_params + 1] = select(i, ...)
	end
	return setmetatable(q, Update) --[[: unknown]]
end

--: (Update) -> (string, { [integer]: unknown })
function Update:_build()
	local set_ = self._set or {} --[[:! { [string]: unknown }]]
	--: { [integer]: string }
	local keys = {}
	for k in pairs(set_) do keys[#keys + 1] = k end
	table.sort(keys)
	--: { [integer]: string }
	local assignments = {}
	--: { [integer]: unknown }
	local params = {}
	for i, k in ipairs(keys) do
		assignments[i] = k .. " = ?"
		params[i] = set_[k]
	end
	local sql = "UPDATE " .. self._table .. " SET " .. table.concat(assignments, ", ")
	for _, p in ipairs(self._where_params) do
		params[#params + 1] = p
	end
	if #self._wheres > 0 then
		sql = sql .. " WHERE " .. table.concat(self._wheres --[[:! { [integer]: string }]], " AND ")
	end
	return sql, params
end

--: (Update) -> ((true | nil), (string | nil))
function Update:exec()
	local db_ = self._db
	local sql, params = (self --[[: unknown]]):_build()
	return db_:execute(sql, unpack(params))
end

-- ── DELETE builder ──────────────────────────────────────────────────────────

local Delete = {}
Delete.__index = Delete

--: (Delete, string, ...unknown) -> Delete
function Delete:where(clause, ...)
	local q = shallow_copy(self) --[[:! Delete]]
	q._wheres = copy_array(self._wheres)
	q._where_params = copy_array(self._where_params)
	q._wheres[#q._wheres + 1] = clause
	local n = select("#", ...)
	for i = 1, n do
		q._where_params[#q._where_params + 1] = select(i, ...)
	end
	return setmetatable(q, Delete) --[[: unknown]]
end

--: (Delete) -> (string, { [integer]: unknown })
function Delete:_build()
	local sql = "DELETE FROM " .. self._table
	local params = copy_array(self._where_params)
	if #self._wheres > 0 then
		sql = sql .. " WHERE " .. table.concat(self._wheres --[[:! { [integer]: string }]], " AND ")
	end
	return sql, params
end

--: (Delete) -> ((true | nil), (string | nil))
function Delete:exec()
	local db_ = self._db
	local sql, params = (self --[[: unknown]]):_build()
	return db_:execute(sql, unpack(params))
end

-- ── Connection wrapper ──────────────────────────────────────────────────────

local Conn = {}
Conn.__index = Conn

--: (Conn, string) -> Select
function Conn:select(table_name)
	return setmetatable({
		_db = self._db,
		_table = table_name,
		_columns = nil,
		_wheres = {},
		_where_params = {},
		_order = nil,
		_limit = nil,
		_offset = nil,
	}, Select) --[[: unknown]]
end

--: (Conn, string) -> Insert
function Conn:insert(table_name)
	return setmetatable({
		_db = self._db,
		_table = table_name,
		_values = nil,
		_returning = nil,
	}, Insert) --[[: unknown]]
end

--: (Conn, string) -> Update
function Conn:update(table_name)
	return setmetatable({
		_db = self._db,
		_table = table_name,
		_set = nil,
		_wheres = {},
		_where_params = {},
	}, Update) --[[: unknown]]
end

--: (Conn, string) -> Delete
function Conn:delete(table_name)
	return setmetatable({
		_db = self._db,
		_table = table_name,
		_wheres = {},
		_where_params = {},
	}, Delete) --[[: unknown]]
end

--: (Conn, string, ...unknown) -> ((true | nil), (string | nil))
function Conn:exec(sql, ...)
	local db_ = self._db
	return db_:execute(sql, ...)
end

--: (Conn, string, ...unknown) -> ({ [string]: unknown }[] | nil, string | nil)
function Conn:query(sql, ...)
	local db_ = self._db
	local iter, err = db_:query(sql, ...)
	if not iter then return nil, err end
	local col_names = query_column_names(db_, sql)
	return collect_rows(iter, col_names)
end

--: (Conn, string, ...unknown) -> ({ [string]: unknown } | nil, string | nil)
function Conn:query_one(sql, ...)
	local rows, err = (self --[[: unknown]]):query(sql, ...)
	if not rows then return nil, err end
	return rows[1]
end

--: (Conn, (Conn) -> (...unknown)) -> (...unknown)
function Conn:transaction(fn)
	local db_ = self._db
	local ok, err = db_:execute("BEGIN")
	if not ok then return nil, err end
	local success, result = pcall(fn, self)
	if not success then
		db_:execute("ROLLBACK")
		return nil, result
	end
	ok, err = db_:execute("COMMIT")
	if not ok then
		db_:execute("ROLLBACK")
		return nil, err
	end
	return result
end

--: (Conn) -> number
function Conn:migration_version()
	local db_ = self._db
	local iter, err = db_:query(
		"SELECT name FROM sqlite_master WHERE type='table' AND name='_migrations'"
	)
	if not iter then return 0 end
	local name = iter()
	if not name then return 0 end
	iter, err = db_:query("SELECT MAX(version) FROM _migrations")
	if not iter then return 0 end
	local ver = iter()
	if not ver then return 0 end
	return ver --[[:! number]]
end

--: (Conn, { [integer]: { version: integer, up: string, ... } }) -> ((boolean | nil), (string | nil))
function Conn:migrate(migrations)
	local db_ = self._db
	local conn_ = self --[[: unknown]]
	local ok, err = db_:execute(
		"CREATE TABLE IF NOT EXISTS _migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)"
	)
	if not ok then return nil, err end
	local current = conn_:migration_version()
	--: { [integer]: { version: integer, up: string } }
	local sorted = {}
	for i = 1, #migrations do sorted[i] = migrations[i] --[[:! { version: integer, up: string }]] end
	table.sort(sorted --[[: unknown]], function(a, b)
		local a_ = a --[[:! { version: integer, up: string }]]
		local b_ = b --[[:! { version: integer, up: string }]]
		return a_.version < b_.version
	end)
	--: { [integer]: { version: integer, up: string } }
	local pending = {}
	for _, m in ipairs(sorted) do
		local m_ = m --[[:! { version: integer, up: string }]]
		if m_.version > current then
			pending[#pending + 1] = m_
		end
	end
	local pending_ = pending --[[:! { [integer]: { version: integer, up: string } }]]
	if #pending_ == 0 then return true end
	ok, err = db_:execute("BEGIN")
	if not ok then return nil, err end
	for _, m in ipairs(pending_) do
		local m_ = m --[[:! { version: integer, up: string }]]
		ok, err = db_:execute(m_.up)
		if not ok then
			db_:execute("ROLLBACK")
			return nil, err
		end
		ok, err = db_:execute(
			"INSERT INTO _migrations (version, applied_at) VALUES (?, datetime('now'))",
			m_.version
		)
		if not ok then
			db_:execute("ROLLBACK")
			return nil, err
		end
	end
	ok, err = db_:execute("COMMIT")
	if not ok then
		db_:execute("ROLLBACK")
		return nil, err
	end
	return true
end

--: (Conn) -> nil
function Conn:close()
	local db_ = self._db
	db_:close()
end

-- ── Public API ──────────────────────────────────────────────────────────────

--: (string) -> ((Conn | nil), (string | nil))
function M.connect(path)
	local db, err = sqlite.open(path)
	if not db then return nil, err end
	return setmetatable({ _db = db }, Conn) --[[: Conn]]
end

--: (sqlite) -> Conn
function M.wrap(db)
	return setmetatable({ _db = db }, Conn) --[[: Conn]]
end

return M
