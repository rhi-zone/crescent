local sqlite = require("lib.sqlite")

local mod = {}

-- ── type → SQL column type ────────────────────────────────────────────────────

local type_converters = {}
local function convert_type(t)
	local fn = type_converters[t.type]
	if fn then return fn(t) end
	return nil, "sqlitex: no SQL type for schema type '" .. t.type .. "'"
end
type_converters.integer  = function()   return "INTEGER NOT NULL" end
type_converters.number   = function()   return "REAL NOT NULL" end
type_converters.string   = function()   return "TEXT NOT NULL" end
type_converters.boolean  = function()   return "INTEGER NOT NULL" end -- stored as 0/1
type_converters.optional = function(t)
	local inner, err = convert_type(t.inner)
	if not inner then return nil, err end
	-- strip NOT NULL for optional columns
	return (inner:gsub(" NOT NULL$", ""))
end

-- ── database ──────────────────────────────────────────────────────────────────

--[[@class sqlitex_database]]
--[[@field db sqlite]]
--[[@field models table<string, sqlitex_model>]]
local database = {}
mod.database   = database
database.__index = database

--[[@param path string]]
--[[@return sqlitex_database? db, string? err]]
database.new = function(self, path)
	local db, err = sqlite.open(path)
	if not db then return nil, err end
	local ret = setmetatable({ db = db, models = {} }, self)
	local ok, serr = ret.db:execute("PRAGMA foreign_keys = ON;")
	if not ok then return nil, serr end
	return ret
end

--[[@param path string]]
--[[@return sqlitex_database? db, string? err]]
mod.new = function(path) return database:new(path) end

-- ── model ─────────────────────────────────────────────────────────────────────
--
-- A model wraps a single SQLite table. The schema must be a struct or
-- struct_exact (flat record). Each model field becomes a column.
--
-- Key ordering: pass an explicit keyorder array to pin column order; otherwise
-- keys are sorted alphabetically (deterministic, reproducible CREATE TABLE).
--
-- Prepared statements are compiled on first use and reused thereafter.

--[[@class sqlitex_model]]
--[[@field name string]]
--[[@field db sqlitex_database]]
--[[@field schema table]]
--[[@field keyorder string[] ]]
--[[@field _stmts table]]
local model = {}
mod.model    = model
model.__index = model

--[[@param db sqlitex_database]]
--[[@param name string]]
--[[@param schema table]]
--[[@param keyorder? string[] ]]
--[[@return sqlitex_model? m, string? err]]
model.new = function(self, db, name, schema, keyorder)
	if name:find("`") then return nil, "sqlitex: name contains backtick: " .. name end
	if schema.type ~= "struct" and schema.type ~= "struct_exact" then
		return nil, "sqlitex: schema must be struct or struct_exact"
	end

	if not keyorder then
		keyorder = {}
		for k in pairs(schema.shape) do
			if k:find("`") then return nil, "sqlitex: column name contains backtick: " .. k end
			keyorder[#keyorder + 1] = k
		end
		table.sort(keyorder)
	end

	-- Build CREATE TABLE
	local parts = { "CREATE TABLE IF NOT EXISTS `", name, "` (" }
	for i, k in ipairs(keyorder) do
		local col_type, err = convert_type(schema.shape[k])
		if not col_type then return nil, err end
		if i > 1 then parts[#parts + 1] = ", " end
		parts[#parts + 1] = "`" .. k .. "` " .. col_type
	end
	parts[#parts + 1] = ");"

	local ok, err = db.db:execute(table.concat(parts))
	if not ok then return nil, err end

	return setmetatable({
		name     = name,
		schema   = schema,
		db       = db,
		keyorder = keyorder,
		_stmts   = {},
	}, self)
end

--[[@param name string]]
--[[@param schema table]]
--[[@param keyorder? string[] ]]
--[[@return sqlitex_model? m, string? err]]
database.model = function(self, name, schema, keyorder)
	return model:new(self, name, schema, keyorder)
end

-- ── prepared statement helpers ────────────────────────────────────────────────

local function get_insert_stmt(m)
	if m._stmts.insert then return m._stmts.insert end
	local qs = {}
	for i = 1, #m.keyorder do qs[i] = "?" end
	local sql = "INSERT INTO `" .. m.name .. "` VALUES (" .. table.concat(qs, ", ") .. ");"
	local stmt, err = m.db.db:prepare(sql)
	if not stmt then return nil, err end
	m._stmts.insert = stmt
	return stmt
end

local function get_delete_stmt(m)
	if m._stmts.delete then return m._stmts.delete end
	local sql = "DELETE FROM `" .. m.name .. "` WHERE `id` = ?;"
	local stmt, err = m.db.db:prepare(sql)
	if not stmt then return nil, err end
	m._stmts.delete = stmt
	return stmt
end

local function get_select_stmt(m)
	if m._stmts.select then return m._stmts.select end
	local sql = "SELECT " .. table.concat(m.keyorder, ", ") .. " FROM `" .. m.name .. "`;"
	local stmt, err = m.db.db:prepare(sql)
	if not stmt then return nil, err end
	m._stmts.select = stmt
	return stmt
end

local function get_find_stmt(m)
	if m._stmts.find then return m._stmts.find end
	local sql = "SELECT " .. table.concat(m.keyorder, ", ") .. " FROM `" .. m.name .. "` WHERE `id` = ?;"
	local stmt, err = m.db.db:prepare(sql)
	if not stmt then return nil, err end
	m._stmts.find = stmt
	return stmt
end

local function get_update_stmt(m)
	if m._stmts.update then return m._stmts.update end
	local sets = {}
	for _, k in ipairs(m.keyorder) do
		if k ~= "id" then sets[#sets + 1] = "`" .. k .. "` = ?" end
	end
	local sql = "UPDATE `" .. m.name .. "` SET " .. table.concat(sets, ", ") .. " WHERE `id` = ?;"
	local stmt, err = m.db.db:prepare(sql)
	if not stmt then return nil, err end
	m._stmts.update = stmt
	return stmt
end

-- Deserialize a row (positional values matching keyorder) into a Lua table.
local function row_to_table(m, ...)
	local t = {}
	local vals = { ... }
	for i, k in ipairs(m.keyorder) do
		t[k] = vals[i]
	end
	return t
end

-- ── CRUD ──────────────────────────────────────────────────────────────────────

-- insert(value) → rowid | nil, err
--[[@param value table]]
--[[@return integer? rowid, string? err]]
model.insert = function(self, value)
	local stmt, serr = get_insert_stmt(self)
	if not stmt then return nil, serr end

	local params = {}
	for i, k in ipairs(self.keyorder) do params[i] = value[k] end
	local ok, eerr = stmt:exec(unpack(params))
	if not ok then return nil, eerr end
	return self.db.db:last_insert_rowid()
end

-- delete(id) → true | nil, err
--[[@param id integer]]
--[[@return true? ok, string? err]]
model.delete = function(self, id)
	local stmt, err = get_delete_stmt(self)
	if not stmt then return nil, err end
	return stmt:exec(id)
end

-- find_all() → array of tables | nil, err
--[[@return table[]? rows, string? err]]
model.find_all = function(self)
	local stmt, err = get_select_stmt(self)
	if not stmt then return nil, err end
	local iter = stmt:rows()
	local rows = {}
	while true do
		local vals = { iter() }
		if vals[1] == nil then break end
		rows[#rows + 1] = row_to_table(self, unpack(vals))
	end
	return rows
end

-- find(id) → table | nil, err
--[[@param id integer]]
--[[@return table? row, string? err]]
model.find = function(self, id)
	local stmt, err = get_find_stmt(self)
	if not stmt then return nil, err end
	local iter = stmt:rows(id)
	local vals = { iter() }
	if vals[1] == nil then return nil end -- not found (or error; done sentinel)
	return row_to_table(self, unpack(vals))
end

-- update(value) → true | nil, err
-- value must contain an 'id' field. All other keyorder fields are updated.
--[[@param value table]]
--[[@return true? ok, string? err]]
model.update = function(self, value)
	local stmt, err = get_update_stmt(self)
	if not stmt then return nil, err end

	-- params: all non-id fields in keyorder, then id at the end (for WHERE)
	local params = {}
	for _, k in ipairs(self.keyorder) do
		if k ~= "id" then params[#params + 1] = value[k] end
	end
	params[#params + 1] = value.id
	return stmt:exec(unpack(params))
end

return mod
