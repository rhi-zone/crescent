-- lib/schema/init.lua — declarative database schema migration DSL
-- Generates portable SQL DDL statements. No database dependency.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── Column builder ───────────────────────────────────────────────────────────

local Col = {}
Col.__index = Col

local function new_column(name, sql_type)
	return setmetatable({
		_name = name,
		_type = sql_type,
		_constraints = {},
	}, Col)
end

function Col:primary_key()
	self._constraints[#self._constraints + 1] = "PRIMARY KEY"
	return self
end

function Col:autoincrement()
	self._constraints[#self._constraints + 1] = "AUTOINCREMENT"
	return self
end

function Col:not_null()
	self._constraints[#self._constraints + 1] = "NOT NULL"
	return self
end

function Col:unique()
	self._constraints[#self._constraints + 1] = "UNIQUE"
	return self
end

function Col:default(value)
	local repr
	if value == true then
		repr = "1"
	elseif value == false then
		repr = "0"
	elseif type(value) == "number" then
		repr = tostring(value)
	elseif type(value) == "string" then
		-- Bare SQL keywords like CURRENT_TIMESTAMP are passed through unquoted
		if value:match("^[A-Z_]+$") then
			repr = value
		else
			repr = "'" .. value:gsub("'", "''") .. "'"
		end
	else
		repr = tostring(value)
	end
	self._constraints[#self._constraints + 1] = "DEFAULT " .. repr
	return self
end

function Col:references(table_name, column_name)
	self._constraints[#self._constraints + 1] = "REFERENCES " .. table_name .. "(" .. column_name .. ")"
	return self
end

function Col:check(expr)
	self._constraints[#self._constraints + 1] = "CHECK (" .. expr .. ")"
	return self
end

function Col:to_sql()
	local parts = { self._name, self._type }
	for i = 1, #self._constraints do
		parts[#parts + 1] = self._constraints[i]
	end
	return table.concat(parts, " ")
end

-- ── Table builder (used inside create_table callback) ────────────────────────

local TableBuilder = {}
TableBuilder.__index = TableBuilder

local function new_table_builder(name)
	return setmetatable({
		_name = name,
		_columns = {},
		_foreign_keys = {},
		_indexes = {},
	}, TableBuilder)
end

local function add_typed_column(self, name, sql_type)
	local col = new_column(name, sql_type)
	self._columns[#self._columns + 1] = col
	return col
end

function TableBuilder:integer(name) return add_typed_column(self, name, "INTEGER") end
function TableBuilder:text(name) return add_typed_column(self, name, "TEXT") end
function TableBuilder:real(name) return add_typed_column(self, name, "REAL") end
function TableBuilder:blob(name) return add_typed_column(self, name, "BLOB") end
function TableBuilder:boolean(name) return add_typed_column(self, name, "BOOLEAN") end
function TableBuilder:timestamp(name) return add_typed_column(self, name, "TIMESTAMP") end
function TableBuilder:numeric(name) return add_typed_column(self, name, "NUMERIC") end
function TableBuilder:varchar(name, len) return add_typed_column(self, name, "VARCHAR(" .. tostring(len) .. ")") end
function TableBuilder:column(name, sql_type) return add_typed_column(self, name, sql_type) end

function TableBuilder:foreign_key(column_name, ref_table, ref_column)
	local col = add_typed_column(self, column_name, "INTEGER")
	self._foreign_keys[#self._foreign_keys + 1] = {
		column = column_name,
		ref_table = ref_table,
		ref_column = ref_column,
	}
	return col
end

function TableBuilder:index(name, ...)
	local columns = { ... }
	if #columns == 0 then
		return nil, "index requires at least one column"
	end
	self._indexes[#self._indexes + 1] = {
		name = name,
		columns = columns,
		unique = false,
	}
end

function TableBuilder:unique_index(name, ...)
	local columns = { ... }
	if #columns == 0 then
		return nil, "unique_index requires at least one column"
	end
	self._indexes[#self._indexes + 1] = {
		name = name,
		columns = columns,
		unique = true,
	}
end

-- ── Alter table builder ──────────────────────────────────────────────────────

local AlterBuilder = {}
AlterBuilder.__index = AlterBuilder

local function new_alter_builder(name)
	return setmetatable({
		_name = name,
		_operations = {},
	}, AlterBuilder)
end

function AlterBuilder:add_column(name, sql_type, constraints)
	local suffix = ""
	if constraints then
		suffix = " " .. constraints
	end
	self._operations[#self._operations + 1] = {
		kind = "add_column",
		sql = "ALTER TABLE " .. self._name .. " ADD COLUMN " .. name .. " " .. sql_type .. suffix,
	}
end

function AlterBuilder:drop_column(name)
	self._operations[#self._operations + 1] = {
		kind = "drop_column",
		sql = "ALTER TABLE " .. self._name .. " DROP COLUMN " .. name,
	}
end

function AlterBuilder:rename_column(old_name, new_name)
	self._operations[#self._operations + 1] = {
		kind = "rename_column",
		sql = "ALTER TABLE " .. self._name .. " RENAME COLUMN " .. old_name .. " TO " .. new_name,
	}
end

function AlterBuilder:add_index(name, ...)
	local columns = { ... }
	if #columns == 0 then
		return nil, "add_index requires at least one column"
	end
	self._operations[#self._operations + 1] = {
		kind = "add_index",
		sql = "CREATE INDEX " .. name .. " ON " .. self._name .. " (" .. table.concat(columns, ", ") .. ")",
	}
end

function AlterBuilder:add_unique_index(name, ...)
	local columns = { ... }
	if #columns == 0 then
		return nil, "add_unique_index requires at least one column"
	end
	self._operations[#self._operations + 1] = {
		kind = "add_unique_index",
		sql = "CREATE UNIQUE INDEX " .. name .. " ON " .. self._name .. " (" .. table.concat(columns, ", ") .. ")",
	}
end

function AlterBuilder:drop_index(name)
	self._operations[#self._operations + 1] = {
		kind = "drop_index",
		sql = "DROP INDEX " .. name,
	}
end

-- ── Schema ───────────────────────────────────────────────────────────────────

local Schema = {}
Schema.__index = Schema

function M.new()
	return setmetatable({
		_statements = {},
	}, Schema)
end

function Schema:create_table(name, fn)
	if type(name) ~= "string" or name == "" then
		return nil, "create_table: table name must be a non-empty string"
	end
	if type(fn) ~= "function" then
		return nil, "create_table: second argument must be a function"
	end
	local builder = new_table_builder(name)
	fn(builder)

	-- Build CREATE TABLE statement
	local parts = { "CREATE TABLE " .. name .. " (\n" }
	local col_lines = {}
	for i = 1, #builder._columns do
		col_lines[#col_lines + 1] = "  " .. builder._columns[i]:to_sql()
	end
	for i = 1, #builder._foreign_keys do
		local fk = builder._foreign_keys[i]
		col_lines[#col_lines + 1] = "  FOREIGN KEY (" .. fk.column .. ") REFERENCES " .. fk.ref_table .. "(" .. fk.ref_column .. ")"
	end
	parts[#parts + 1] = table.concat(col_lines, ",\n")
	parts[#parts + 1] = "\n)"

	self._statements[#self._statements + 1] = table.concat(parts)

	-- Build index statements
	for i = 1, #builder._indexes do
		local idx = builder._indexes[i]
		local prefix = idx.unique and "CREATE UNIQUE INDEX " or "CREATE INDEX "
		self._statements[#self._statements + 1] = prefix .. idx.name .. " ON " .. name .. " (" .. table.concat(idx.columns, ", ") .. ")"
	end

	return self
end

function Schema:create_table_if_not_exists(name, fn)
	if type(name) ~= "string" or name == "" then
		return nil, "create_table_if_not_exists: table name must be a non-empty string"
	end
	if type(fn) ~= "function" then
		return nil, "create_table_if_not_exists: second argument must be a function"
	end
	local builder = new_table_builder(name)
	fn(builder)

	local parts = { "CREATE TABLE IF NOT EXISTS " .. name .. " (\n" }
	local col_lines = {}
	for i = 1, #builder._columns do
		col_lines[#col_lines + 1] = "  " .. builder._columns[i]:to_sql()
	end
	for i = 1, #builder._foreign_keys do
		local fk = builder._foreign_keys[i]
		col_lines[#col_lines + 1] = "  FOREIGN KEY (" .. fk.column .. ") REFERENCES " .. fk.ref_table .. "(" .. fk.ref_column .. ")"
	end
	parts[#parts + 1] = table.concat(col_lines, ",\n")
	parts[#parts + 1] = "\n)"

	self._statements[#self._statements + 1] = table.concat(parts)

	for i = 1, #builder._indexes do
		local idx = builder._indexes[i]
		local prefix = idx.unique and "CREATE UNIQUE INDEX " or "CREATE INDEX "
		self._statements[#self._statements + 1] = prefix .. idx.name .. " ON " .. name .. " (" .. table.concat(idx.columns, ", ") .. ")"
	end

	return self
end

function Schema:alter_table(name, fn)
	if type(name) ~= "string" or name == "" then
		return nil, "alter_table: table name must be a non-empty string"
	end
	if type(fn) ~= "function" then
		return nil, "alter_table: second argument must be a function"
	end
	local builder = new_alter_builder(name)
	fn(builder)

	for i = 1, #builder._operations do
		self._statements[#self._statements + 1] = builder._operations[i].sql
	end

	return self
end

function Schema:drop_table(name)
	if type(name) ~= "string" or name == "" then
		return nil, "drop_table: table name must be a non-empty string"
	end
	self._statements[#self._statements + 1] = "DROP TABLE " .. name
	return self
end

function Schema:drop_table_if_exists(name)
	if type(name) ~= "string" or name == "" then
		return nil, "drop_table_if_exists: table name must be a non-empty string"
	end
	self._statements[#self._statements + 1] = "DROP TABLE IF EXISTS " .. name
	return self
end

function Schema:rename_table(old_name, new_name)
	if type(old_name) ~= "string" or old_name == "" then
		return nil, "rename_table: old table name must be a non-empty string"
	end
	if type(new_name) ~= "string" or new_name == "" then
		return nil, "rename_table: new table name must be a non-empty string"
	end
	self._statements[#self._statements + 1] = "ALTER TABLE " .. old_name .. " RENAME TO " .. new_name
	return self
end

function Schema:raw(sql)
	if type(sql) ~= "string" then
		return nil, "raw: argument must be a string"
	end
	self._statements[#self._statements + 1] = sql
	return self
end

function Schema:to_sql()
	local result = {}
	for i = 1, #self._statements do
		result[i] = self._statements[i]
	end
	return result
end

function Schema:to_string(separator)
	separator = separator or ";\n"
	return table.concat(self._statements, separator)
end

return M
