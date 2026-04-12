if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- Pure-Lua fluent SQL query builder.
-- Generates parameterized SQL strings; no database connection required.
-- All builder methods return a NEW builder (immutable-style chaining).
-- Call :build() to get (sql_string, params_table).

local M = {}
M._tier = "pure"

-- ── Helpers ──────────────────────────────────────────────────────────────────

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

-- Append all items from src into dst.
--: (table, table) -> nil
local function extend(dst, src)
	for i = 1, #src do dst[#dst + 1] = src[i] end
end

-- ── WHERE clause internal representation ─────────────────────────────────────
-- Each entry: { kind = "and"|"or", sql = string, params = table }
-- "and"  → joined with AND
-- "or"   → joined with OR (treated as OR before the next AND group)
-- We flatten everything at build time using standard SQL precedence.

-- Build the WHERE string and collect params from a _wheres list.
--: (table) -> string, table
local function build_where(wheres)
	if #wheres == 0 then return nil, {} end
	local parts = {}
	local params = {}
	for _, w in ipairs(wheres) do
		parts[#parts + 1] = { kind = w.kind, sql = w.sql }
		extend(params, w.params)
	end
	-- Join: first clause has no connector; subsequent use their kind.
	local buf = {}
	for i, p in ipairs(parts) do
		if i == 1 then
			buf[#buf + 1] = p.sql
		else
			buf[#buf + 1] = (p.kind == "or" and " OR " or " AND ") .. p.sql
		end
	end
	return table.concat(buf), params
end

-- ── SELECT builder ────────────────────────────────────────────────────────────

local Select = {}
Select.__index = Select

-- Internal constructor (used by M.select).
--: (string) -> Select
local function new_select(table_name)
	return setmetatable({
		_table    = table_name,
		_columns  = nil,   -- nil = *, table = list of column strings
		_raw_cols = nil,   -- raw column fragment (string)
		_joins    = {},    -- list of { kind, table, on }
		_wheres   = {},    -- list of { kind, sql, params }
		_order    = nil,   -- string
		_group    = nil,   -- string
		_having   = nil,   -- { sql, params }
		_limit    = nil,
		_offset   = nil,
		_count    = false,
		_exists   = false,
	}, Select)
end

-- Clone self, applying fn(copy) -> copy.
--: (Select, fun(table):table) -> Select
local function sel_clone(self, fn)
	local q = shallow_copy(self)
	q._joins   = copy_array(self._joins)
	q._wheres  = copy_array(self._wheres)
	if self._having then
		q._having = { sql = self._having.sql, params = copy_array(self._having.params) }
	end
	return setmetatable(fn(q), Select)
end

--: (Select, ...) -> Select
function Select:columns(...)
	local cols = { ... }
	return sel_clone(self, function(q)
		q._columns  = cols
		q._raw_cols = nil
		return q
	end)
end

-- Raw column fragment, e.g. "id, name, strftime('%Y', created_at) AS year"
--: (Select, string) -> Select
function Select:columns_raw(fragment)
	return sel_clone(self, function(q)
		q._raw_cols = fragment
		q._columns  = nil
		return q
	end)
end

-- SELECT COUNT(*) FROM ...
--: (Select) -> Select
function Select:count()
	return sel_clone(self, function(q)
		q._count = true
		q._exists = false
		return q
	end)
end

-- SELECT EXISTS(SELECT 1 FROM ...)
--: (Select) -> Select
function Select:exists()
	return sel_clone(self, function(q)
		q._exists = true
		q._count  = false
		return q
	end)
end

-- Add a JOIN clause.  kind = "INNER"|"LEFT"|"RIGHT"|"FULL"
--: (Select, string, string, string) -> Select
local function add_join(self, kind, tbl, on)
	return sel_clone(self, function(q)
		q._joins[#q._joins + 1] = { kind = kind, tbl = tbl, on = on }
		return q
	end)
end

--: (Select, string, string) -> Select
function Select:join(tbl, on)       return add_join(self, "INNER", tbl, on) end
--: (Select, string, string) -> Select
function Select:left_join(tbl, on)  return add_join(self, "LEFT",  tbl, on) end
--: (Select, string, string) -> Select
function Select:right_join(tbl, on) return add_join(self, "RIGHT", tbl, on) end
--: (Select, string, string) -> Select
function Select:full_join(tbl, on)  return add_join(self, "FULL",  tbl, on) end

-- Add an AND WHERE condition with optional params.
--: (Select, string, ...unknown) -> Select
function Select:where(clause, ...)
	local args = { ... }
	return sel_clone(self, function(q)
		q._wheres[#q._wheres + 1] = { kind = "and", sql = clause, params = args }
		return q
	end)
end

-- Add an OR WHERE condition.
--: (Select, string, ...unknown) -> Select
function Select:where_or(clause, ...)
	local args = { ... }
	return sel_clone(self, function(q)
		q._wheres[#q._wheres + 1] = { kind = "or", sql = clause, params = args }
		return q
	end)
end

-- WHERE col IN (v1, v2, ...) or WHERE col IN (subquery)
--: (Select, string, table|Select) -> Select
function Select:where_in(col, values)
	return sel_clone(self, function(q)
		if type(values) == "table" and getmetatable(values) == Select then
			-- subquery
			local sub_sql, sub_params = values:build()
			q._wheres[#q._wheres + 1] = {
				kind = "and",
				sql  = col .. " IN (" .. sub_sql .. ")",
				params = sub_params,
			}
		else
			-- array of values
			local placeholders = {}
			for i = 1, #values do placeholders[i] = "?" end
			q._wheres[#q._wheres + 1] = {
				kind   = "and",
				sql    = col .. " IN (" .. table.concat(placeholders, ", ") .. ")",
				params = copy_array(values),
			}
		end
		return q
	end)
end

-- WHERE col NOT IN (...)
--: (Select, string, table|Select) -> Select
function Select:where_not_in(col, values)
	return sel_clone(self, function(q)
		if type(values) == "table" and getmetatable(values) == Select then
			local sub_sql, sub_params = values:build()
			q._wheres[#q._wheres + 1] = {
				kind   = "and",
				sql    = col .. " NOT IN (" .. sub_sql .. ")",
				params = sub_params,
			}
		else
			local placeholders = {}
			for i = 1, #values do placeholders[i] = "?" end
			q._wheres[#q._wheres + 1] = {
				kind   = "and",
				sql    = col .. " NOT IN (" .. table.concat(placeholders, ", ") .. ")",
				params = copy_array(values),
			}
		end
		return q
	end)
end

-- WHERE col IS NULL
--: (Select, string) -> Select
function Select:where_null(col)
	return sel_clone(self, function(q)
		q._wheres[#q._wheres + 1] = { kind = "and", sql = col .. " IS NULL", params = {} }
		return q
	end)
end

-- WHERE col IS NOT NULL
--: (Select, string) -> Select
function Select:where_not_null(col)
	return sel_clone(self, function(q)
		q._wheres[#q._wheres + 1] = { kind = "and", sql = col .. " IS NOT NULL", params = {} }
		return q
	end)
end

-- WHERE col BETWEEN lo AND hi
--: (Select, string, unknown, unknown) -> Select
function Select:where_between(col, lo, hi)
	return sel_clone(self, function(q)
		q._wheres[#q._wheres + 1] = {
			kind   = "and",
			sql    = col .. " BETWEEN ? AND ?",
			params = { lo, hi },
		}
		return q
	end)
end

-- WHERE col LIKE pattern
--: (Select, string, string) -> Select
function Select:where_like(col, pattern)
	return sel_clone(self, function(q)
		q._wheres[#q._wheres + 1] = {
			kind   = "and",
			sql    = col .. " LIKE ?",
			params = { pattern },
		}
		return q
	end)
end

-- Raw WHERE fragment with variadic params (positional ? placeholders).
--: (Select, string, ...unknown) -> Select
function Select:where_raw(clause, ...)
	local args = { ... }
	return sel_clone(self, function(q)
		q._wheres[#q._wheres + 1] = { kind = "and", sql = clause, params = args }
		return q
	end)
end

-- ORDER BY columns (comma-separated string or variadic column names).
--: (Select, ...) -> Select
function Select:order_by(...)
	local cols = { ... }
	return sel_clone(self, function(q)
		q._order = table.concat(cols, ", ")
		return q
	end)
end

-- GROUP BY columns.
--: (Select, ...) -> Select
function Select:group_by(...)
	local cols = { ... }
	return sel_clone(self, function(q)
		q._group = table.concat(cols, ", ")
		return q
	end)
end

-- HAVING clause with params.
--: (Select, string, ...unknown) -> Select
function Select:having(clause, ...)
	local args = { ... }
	return sel_clone(self, function(q)
		q._having = { sql = clause, params = args }
		return q
	end)
end

--: (Select, number) -> Select
function Select:limit(val)
	return sel_clone(self, function(q) q._limit = val; return q end)
end

--: (Select, number) -> Select
function Select:offset(val)
	return sel_clone(self, function(q) q._offset = val; return q end)
end

-- Build the inner SELECT (without EXISTS wrapper).
--: (Select) -> string, table
local function build_select_inner(self)
	local col_fragment
	if self._count then
		col_fragment = "COUNT(*)"
	elseif self._raw_cols then
		col_fragment = self._raw_cols
	elseif self._columns and #self._columns > 0 then
		col_fragment = table.concat(self._columns, ", ")
	else
		col_fragment = "*"
	end

	local sql = "SELECT " .. col_fragment .. " FROM " .. self._table

	-- JOINs
	for _, j in ipairs(self._joins) do
		sql = sql .. " " .. j.kind .. " JOIN " .. j.tbl .. " ON " .. j.on
	end

	local params = {}

	-- WHERE
	local where_sql, where_params = build_where(self._wheres)
	if where_sql then
		sql = sql .. " WHERE " .. where_sql
		extend(params, where_params)
	end

	-- GROUP BY
	if self._group then
		sql = sql .. " GROUP BY " .. self._group
	end

	-- HAVING
	if self._having then
		sql = sql .. " HAVING " .. self._having.sql
		extend(params, self._having.params)
	end

	-- ORDER BY
	if self._order then
		sql = sql .. " ORDER BY " .. self._order
	end

	-- LIMIT / OFFSET
	if self._limit  then sql = sql .. " LIMIT "  .. self._limit  end
	if self._offset then sql = sql .. " OFFSET " .. self._offset end

	return sql, params
end

--: (Select) -> string, table
function Select:build()
	local sql, params = build_select_inner(self)
	if self._exists then
		-- Replace the column fragment with "1" for the EXISTS inner query.
		local from_pos = sql:find(" FROM ")
		local inner1 = "SELECT 1" .. sql:sub(from_pos)
		return "SELECT EXISTS(" .. inner1 .. ")", params
	end
	return sql, params
end

-- ── INSERT builder ────────────────────────────────────────────────────────────

local Insert = {}
Insert.__index = Insert

--: (string) -> Insert
local function new_insert(table_name)
	return setmetatable({
		_table = table_name,
		_rows  = nil,   -- array of row tables (multi-row)
		_vals  = nil,   -- single row table
	}, Insert)
end

--: (Insert, table) -> Insert
function Insert:values(vals)
	local q = shallow_copy(self)
	q._vals = vals
	q._rows = nil
	return setmetatable(q, Insert)
end

--: (Insert, table[]) -> Insert
function Insert:rows(row_list)
	local q = shallow_copy(self)
	q._rows = row_list
	q._vals = nil
	return setmetatable(q, Insert)
end

--: (Insert) -> string, table
function Insert:build()
	local rows
	if self._rows then
		rows = self._rows
	elseif self._vals then
		rows = { self._vals }
	else
		return nil, "insert: no values provided"
	end

	if #rows == 0 then
		return nil, "insert: empty rows list"
	end

	-- Derive sorted column list from first row.
	local keys = {}
	for k in pairs(rows[1]) do keys[#keys + 1] = k end
	table.sort(keys)

	local params = {}
	local value_groups = {}
	for _, row in ipairs(rows) do
		local placeholders = {}
		for _, k in ipairs(keys) do
			placeholders[#placeholders + 1] = "?"
			params[#params + 1] = row[k]
		end
		value_groups[#value_groups + 1] = "(" .. table.concat(placeholders, ", ") .. ")"
	end

	local sql = "INSERT INTO " .. self._table ..
		" (" .. table.concat(keys, ", ") .. ")" ..
		" VALUES " .. table.concat(value_groups, ", ")

	return sql, params
end

-- ── UPDATE builder ────────────────────────────────────────────────────────────

local Update = {}
Update.__index = Update

--: (string) -> Update
local function new_update(table_name)
	return setmetatable({
		_table        = table_name,
		_set          = nil,
		_wheres       = {},
	}, Update)
end

--: (Update, table) -> Update
local function upd_clone(self, fn)
	local q = shallow_copy(self)
	q._wheres = copy_array(self._wheres)
	return setmetatable(fn(q), Update)
end

--: (Update, table) -> Update
function Update:set(vals)
	return upd_clone(self, function(q) q._set = vals; return q end)
end

--: (Update, string, ...unknown) -> Update
function Update:where(clause, ...)
	local args = { ... }
	return upd_clone(self, function(q)
		q._wheres[#q._wheres + 1] = { kind = "and", sql = clause, params = args }
		return q
	end)
end

--: (Update) -> string, table
function Update:build()
	if not self._set then return nil, "update: no set() called" end

	local keys = {}
	for k in pairs(self._set) do keys[#keys + 1] = k end
	table.sort(keys)

	local assignments = {}
	local params = {}
	for _, k in ipairs(keys) do
		assignments[#assignments + 1] = k .. " = ?"
		params[#params + 1] = self._set[k]
	end

	local sql = "UPDATE " .. self._table .. " SET " .. table.concat(assignments, ", ")

	local where_sql, where_params = build_where(self._wheres)
	if where_sql then
		sql = sql .. " WHERE " .. where_sql
		extend(params, where_params)
	end

	return sql, params
end

-- ── DELETE builder ────────────────────────────────────────────────────────────

local Delete = {}
Delete.__index = Delete

--: (string) -> Delete
local function new_delete(table_name)
	return setmetatable({
		_table  = table_name,
		_wheres = {},
	}, Delete)
end

--: (Delete, fun(table):table) -> Delete
local function del_clone(self, fn)
	local q = shallow_copy(self)
	q._wheres = copy_array(self._wheres)
	return setmetatable(fn(q), Delete)
end

--: (Delete, string, ...unknown) -> Delete
function Delete:where(clause, ...)
	local args = { ... }
	return del_clone(self, function(q)
		q._wheres[#q._wheres + 1] = { kind = "and", sql = clause, params = args }
		return q
	end)
end

--: (Delete) -> string, table
function Delete:build()
	local sql = "DELETE FROM " .. self._table
	local where_sql, where_params = build_where(self._wheres)
	if where_sql then
		sql = sql .. " WHERE " .. where_sql
	end
	return sql, where_params
end

-- ── UNION builder ─────────────────────────────────────────────────────────────

local Union = {}
Union.__index = Union

--: (Select[]) -> Union
local function new_union(queries)
	return setmetatable({ _queries = queries, _all = false }, Union)
end

-- Use UNION ALL instead of UNION (keeps duplicates).
--: (Union) -> Union
function Union:all()
	local q = shallow_copy(self)
	q._queries = copy_array(self._queries)
	q._all = true
	return setmetatable(q, Union)
end

--: (Union) -> string, table
function Union:build()
	local parts  = {}
	local params = {}
	local kw     = self._all and " UNION ALL " or " UNION "
	for _, q in ipairs(self._queries) do
		local s, p = q:build()
		parts[#parts + 1]  = s
		extend(params, p)
	end
	return table.concat(parts, kw), params
end

-- ── Public API ────────────────────────────────────────────────────────────────

--: (string) -> Select
function M.select(table_name)
	return new_select(table_name)
end

--: (string) -> Insert
function M.insert(table_name)
	return new_insert(table_name)
end

--: (string) -> Update
function M.update(table_name)
	return new_update(table_name)
end

--: (string) -> Delete
function M.delete(table_name)
	return new_delete(table_name)
end

-- M.union(q1, q2, ...) or M.union({q1, q2, ...})
--: (...Select) -> Union
function M.union(...)
	local args = { ... }
	if type(args[1]) == "table" and getmetatable(args[1]) ~= Select then
		return new_union(args[1])
	end
	return new_union(args)
end

return M
