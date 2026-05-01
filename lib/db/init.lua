if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi = require("ffi")
local sqlite = require("lib.sqlite")

local M = {}

--:: sqlite = unknown
--:: Conn = { _db: unknown }
--:: Select = { _db: unknown, _table: string, _columns: { [integer]: string } | nil, _wheres: { [integer]: unknown }, _order: string | nil, _limit: integer | nil, _offset: integer | nil }
--:: Insert = { _db: unknown, _table: string, _columns: { [integer]: string } | nil, _values: { [integer]: unknown }, _on_conflict: unknown, _returning: { [integer]: string } | nil }
--:: Update = { _db: unknown, _table: string, _sets: { [integer]: unknown }, _wheres: { [integer]: unknown }, _returning: { [integer]: string } | nil }
--:: Delete = { _db: unknown, _table: string, _wheres: { [integer]: unknown }, _returning: { [integer]: string } | nil }

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

--: (table) -> table
local function shallow_copy(t)
	local out = {}
	for k, v in pairs(t) do out[k] = v end
	return out
end

--: (table) -> table
local function copy_array(t)
	local out = {}
	for i = 1, #t do out[i] = t[i] end
	return out
end

--: (sqlite, string) -> string[]
local function get_column_names(db, table_name)
	local iter, err = db:query("PRAGMA table_info(" .. table_name .. ")")
	if not iter then return nil, err end
	local names = {}
	while true do
		local cid, name = iter()
		if cid == nil then break end
		names[#names + 1] = name
	end
	return names
end

--- Get column names from an arbitrary SQL statement via sqlite3_column_name.
--: (sqlite, string) -> string[]
local function query_column_names(db, sql)
	if not sqlite_lib then return {} end
	local stmt, err = db:prepare(sql)
	if not stmt then return {} end
	local raw = stmt._stmt
	local col_count = sqlite_lib.sqlite3_column_count(raw)
	local names = {}
	for i = 0, col_count - 1 do
		local cname = sqlite_lib.sqlite3_column_name(raw, i)
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
	local q = shallow_copy(self)
	q._columns = { ... }
	return setmetatable(q, Select)
end

--: (Select, string, ...unknown) -> Select
function Select:where(clause, ...)
	local q = shallow_copy(self)
	q._wheres = copy_array(self._wheres)
	q._where_params = copy_array(self._where_params)
	q._wheres[#q._wheres + 1] = clause
	local n = select("#", ...)
	for i = 1, n do
		q._where_params[#q._where_params + 1] = select(i, ...)
	end
	return setmetatable(q, Select)
end

--: (Select, string) -> Select
function Select:order(val)
	local q = shallow_copy(self)
	q._order = val
	return setmetatable(q, Select)
end

--: (Select, number) -> Select
function Select:limit(val)
	local q = shallow_copy(self)
	q._limit = val
	return setmetatable(q, Select)
end

--: (Select, number) -> Select
function Select:offset(val)
	local q = shallow_copy(self)
	q._offset = val
	return setmetatable(q, Select)
end

--: (Select) -> (string, unknown[])
function Select:_build()
	local cols = self._columns and table.concat(self._columns, ", ") or "*"
	local sql = "SELECT " .. cols .. " FROM " .. self._table
	local params = copy_array(self._where_params)
	if #self._wheres > 0 then
		sql = sql .. " WHERE " .. table.concat(self._wheres, " AND ")
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
	local sql, params = self:_build()
	local iter, err = self._db:query(sql, unpack(params))
	if not iter then return nil, err end
	local col_names, cerr = self:_resolve_col_names()
	if not col_names then return nil, cerr end
	return collect_rows(iter, col_names)
end

--: (Select) -> ({ [string]: unknown } | nil, string | nil)
function Select:first()
	local q = self:limit(1)
	local rows, err = q:all()
	if not rows then return nil, err end
	return rows[1]
end

--: (Select) -> ((number | nil), (string | nil))
function Select:count()
	local sql, params = self:_build()
	local count_sql = "SELECT COUNT(*) FROM (" .. sql .. ")"
	local iter, err = self._db:query(count_sql, unpack(params))
	if not iter then return nil, err end
	local n = iter()
	return n
end

-- ── INSERT builder ──────────────────────────────────────────────────────────

local Insert = {}
Insert.__index = Insert

--: (Insert, { [string]: unknown }) -> Insert
function Insert:values(vals)
	local q = shallow_copy(self)
	q._values = vals
	return setmetatable(q, Insert)
end

--: (Insert, ...unknown) -> Insert
function Insert:returning(...)
	local q = shallow_copy(self)
	q._returning = { ... }
	return setmetatable(q, Insert)
end

--: (Insert) -> (string, unknown[])
function Insert:_build()
	local keys = {}
	for k in pairs(self._values) do keys[#keys + 1] = k end
	table.sort(keys)
	local placeholders = {}
	local params = {}
	for i, k in ipairs(keys) do
		placeholders[i] = "?"
		params[i] = self._values[k]
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
	local sql, params = self:_build()
	return self._db:execute(sql, unpack(params))
end

--: (Insert) -> ({ [string]: unknown } | nil, string | nil)
function Insert:first()
	local sql, params = self:_build()
	local iter, err = self._db:query(sql, unpack(params))
	if not iter then return nil, err end
	if not self._returning or #self._returning == 0 then return nil end
	return collect_rows(iter, self._returning)[1]
end

-- ── UPDATE builder ──────────────────────────────────────────────────────────

local Update = {}
Update.__index = Update

--: (Update, { [string]: unknown }) -> Update
function Update:set(vals)
	local q = shallow_copy(self)
	q._set = vals
	return setmetatable(q, Update)
end

--: (Update, string, ...unknown) -> Update
function Update:where(clause, ...)
	local q = shallow_copy(self)
	q._wheres = copy_array(self._wheres)
	q._where_params = copy_array(self._where_params)
	q._wheres[#q._wheres + 1] = clause
	local n = select("#", ...)
	for i = 1, n do
		q._where_params[#q._where_params + 1] = select(i, ...)
	end
	return setmetatable(q, Update)
end

--: (Update) -> (string, unknown[])
function Update:_build()
	local keys = {}
	for k in pairs(self._set) do keys[#keys + 1] = k end
	table.sort(keys)
	local assignments = {}
	local params = {}
	for i, k in ipairs(keys) do
		assignments[i] = k .. " = ?"
		params[i] = self._set[k]
	end
	local sql = "UPDATE " .. self._table .. " SET " .. table.concat(assignments, ", ")
	for _, p in ipairs(self._where_params) do
		params[#params + 1] = p
	end
	if #self._wheres > 0 then
		sql = sql .. " WHERE " .. table.concat(self._wheres, " AND ")
	end
	return sql, params
end

--: (Update) -> ((true | nil), (string | nil))
function Update:exec()
	local sql, params = self:_build()
	return self._db:execute(sql, unpack(params))
end

-- ── DELETE builder ──────────────────────────────────────────────────────────

local Delete = {}
Delete.__index = Delete

--: (Delete, string, ...unknown) -> Delete
function Delete:where(clause, ...)
	local q = shallow_copy(self)
	q._wheres = copy_array(self._wheres)
	q._where_params = copy_array(self._where_params)
	q._wheres[#q._wheres + 1] = clause
	local n = select("#", ...)
	for i = 1, n do
		q._where_params[#q._where_params + 1] = select(i, ...)
	end
	return setmetatable(q, Delete)
end

--: (Delete) -> (string, unknown[])
function Delete:_build()
	local sql = "DELETE FROM " .. self._table
	local params = copy_array(self._where_params)
	if #self._wheres > 0 then
		sql = sql .. " WHERE " .. table.concat(self._wheres, " AND ")
	end
	return sql, params
end

--: (Delete) -> ((true | nil), (string | nil))
function Delete:exec()
	local sql, params = self:_build()
	return self._db:execute(sql, unpack(params))
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
	}, Select)
end

--: (Conn, string) -> Insert
function Conn:insert(table_name)
	return setmetatable({
		_db = self._db,
		_table = table_name,
		_values = nil,
		_returning = nil,
	}, Insert)
end

--: (Conn, string) -> Update
function Conn:update(table_name)
	return setmetatable({
		_db = self._db,
		_table = table_name,
		_set = nil,
		_wheres = {},
		_where_params = {},
	}, Update)
end

--: (Conn, string) -> Delete
function Conn:delete(table_name)
	return setmetatable({
		_db = self._db,
		_table = table_name,
		_wheres = {},
		_where_params = {},
	}, Delete)
end

--: (Conn, string, ...unknown) -> ((true | nil), (string | nil))
function Conn:exec(sql, ...)
	return self._db:execute(sql, ...)
end

--: (Conn, string, ...unknown) -> ({ [string]: unknown }[] | nil, string | nil)
function Conn:query(sql, ...)
	local iter, err = self._db:query(sql, ...)
	if not iter then return nil, err end
	local col_names = query_column_names(self._db, sql)
	return collect_rows(iter, col_names)
end

--: (Conn, string, ...unknown) -> ({ [string]: unknown } | nil, string | nil)
function Conn:query_one(sql, ...)
	local rows, err = self:query(sql, ...)
	if not rows then return nil, err end
	return rows[1]
end

--: (Conn, (Conn) -> (...unknown)) -> (...unknown)
function Conn:transaction(fn)
	local ok, err = self._db:execute("BEGIN")
	if not ok then return nil, err end
	local success, result = pcall(fn, self)
	if not success then
		self._db:execute("ROLLBACK")
		return nil, result
	end
	ok, err = self._db:execute("COMMIT")
	if not ok then
		self._db:execute("ROLLBACK")
		return nil, err
	end
	return result
end

--: (Conn) -> number
function Conn:migration_version()
	local iter, err = self._db:query(
		"SELECT name FROM sqlite_master WHERE type='table' AND name='_migrations'"
	)
	if not iter then return 0 end
	local name = iter()
	if not name then return 0 end
	iter, err = self._db:query("SELECT MAX(version) FROM _migrations")
	if not iter then return 0 end
	local ver = iter()
	if not ver then return 0 end
	return ver
end

--: (Conn, { [integer]: { version: integer, up: string, ... } }) -> ((true | nil), (string | nil))
function Conn:migrate(migrations)
	local ok, err = self._db:execute(
		"CREATE TABLE IF NOT EXISTS _migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)"
	)
	if not ok then return nil, err end
	local current = self:migration_version()
	local sorted = {}
	for i = 1, #migrations do sorted[i] = migrations[i] end
	table.sort(sorted, function(a, b) return a.version < b.version end)
	local pending = {}
	for _, m in ipairs(sorted) do
		if m.version > current then
			pending[#pending + 1] = m
		end
	end
	if #pending == 0 then return true end
	ok, err = self._db:execute("BEGIN")
	if not ok then return nil, err end
	for _, m in ipairs(pending) do
		ok, err = self._db:execute(m.up)
		if not ok then
			self._db:execute("ROLLBACK")
			return nil, err
		end
		ok, err = self._db:execute(
			"INSERT INTO _migrations (version, applied_at) VALUES (?, datetime('now'))",
			m.version
		)
		if not ok then
			self._db:execute("ROLLBACK")
			return nil, err
		end
	end
	ok, err = self._db:execute("COMMIT")
	if not ok then
		self._db:execute("ROLLBACK")
		return nil, err
	end
	return true
end

--: (Conn) -> nil
function Conn:close()
	self._db:close()
end

-- ── Public API ──────────────────────────────────────────────────────────────

--: (string) -> ((Conn | nil), (string | nil))
function M.connect(path)
	local db, err = sqlite.open(path)
	if not db then return nil, err end
	return setmetatable({ _db = db }, Conn)
end

--: (sqlite) -> Conn
function M.wrap(db)
	return setmetatable({ _db = db }, Conn)
end

return M
