-- lib/mini_orm/init.lua
-- Lightweight pure-Lua in-memory ORM with query builder, relationships, migrations.
-- No external dependencies. Pure in-memory storage.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function shallow_copy(t)
	local out = {}
	for k, v in pairs(t) do out[k] = v end
	return out
end

local function deep_copy_tables(storage)
	-- Copy the two-level structure: storage[model_name][id] = record
	local out = {}
	for model_name, records in pairs(storage) do
		out[model_name] = {}
		for id, record in pairs(records) do
			out[model_name][id] = shallow_copy(record)
		end
	end
	return out
end

local function copy_next_ids(ids)
	local out = {}
	for k, v in pairs(ids) do out[k] = v end
	return out
end

-- Validate an email-ish string (contains @)
local function is_valid_email(s)
	return type(s) == "string" and s:find("@", 1, true) ~= nil
end

-- ── Validation ────────────────────────────────────────────────────────────────

-- Returns nil on success, or a table {field=errmsg} on failure.
-- `data` is the user-supplied table; `fields` is the model field schema.
-- `existing_records` is the table of all records (for unique checks).
-- `is_update` skips required check for fields not present in data.
--: (unknown, unknown, unknown, unknown, unknown) -> ({ [string]: string } | nil)
local function validate(data, fields, existing_records, is_update, record_id)
	local errs = {} --[[: { [string]: string } ]]
	local has_err = false
	local data_ = (data --[[:! { [string]: unknown }]])
	local fields_ = (fields --[[:! { [string]: { type: string, primary_key: boolean | nil, auto_increment: boolean | nil, required: boolean | nil, unique: boolean | nil, max_length: integer | nil } }]])
	local existing_records_ = (existing_records --[[:! { [unknown]: { [string]: unknown } }]])

	for field_name, def in pairs(fields_) do
		local val = data_[field_name]
		local present = val ~= nil

		-- Skip auto_increment/primary_key fields
		if def.primary_key and def.auto_increment then
			-- skip
		elseif not is_update and def.required and not present then
			errs[field_name] = "required"
			has_err = true
		elseif present then
			-- Type checking
			if def.type == "integer" then
				if type(val) ~= "number" or math.floor((val --[[:! number]])) ~= val then
					errs[field_name] = "must be integer"
					has_err = true
				end
			elseif def.type == "string" then
				if type(val) ~= "string" then
					errs[field_name] = "must be string"
					has_err = true
				else
					local max_len = def.max_length
					if max_len and #(val --[[:! string]]) > max_len then
						errs[field_name] = "max_length " .. max_len .. " exceeded"
						has_err = true
					end
				end
			elseif def.type == "boolean" then
				if type(val) ~= "boolean" then
					errs[field_name] = "must be boolean"
					has_err = true
				end
			elseif def.type == "number" then
				if type(val) ~= "number" then
					errs[field_name] = "must be number"
					has_err = true
				end
			end

			-- Unique check
			if def.unique and not errs[field_name] then
				for rec_id, rec in pairs(existing_records_) do
					-- On update, skip the current record
					if rec_id ~= record_id and rec[field_name] == val then
						errs[field_name] = "must be unique"
						has_err = true
						break
					end
				end
			end
		end
	end

	if has_err then return errs end
	return nil
end

-- ── Apply defaults ────────────────────────────────────────────────────────────

local function apply_defaults(data, fields)
	local out = shallow_copy(data)
	for field_name, def in pairs(fields) do
		if out[field_name] == nil and def.default ~= nil then
			out[field_name] = def.default
		end
	end
	return out
end

-- ── Type declarations ─────────────────────────────────────────────────────────

--:: FieldDef = { type?: string, required?: boolean, primary_key?: boolean, auto_increment?: boolean, unique?: boolean, default?: unknown, max_length?: integer, foreign_key?: string, ... }
--:: RecordStorage = { [unknown]: { [string]: unknown } }
--:: DbStorage = { [string]: RecordStorage }
--:: NextIds = { [string]: integer }
--:: DbRef = { _storage: DbStorage, _next_id: NextIds, _models: { [string]: ModelRef }, _migration_version: integer, ... }
--:: ModelRef = { _db: DbRef, _name: string, _pk: string, _fields: { [string]: FieldDef }, _relationships: { [string]: unknown }, _wrap: (self: ModelRef, rec: { [string]: unknown }) -> { [string]: unknown }, ... }

-- ── Query Builder ─────────────────────────────────────────────────────────────

local QB = {}
QB.__index = QB

local function new_query_builder(model)
	return setmetatable({
		_model      = model,
		_wheres     = {},   -- array of predicate functions
		_order_col  = nil,
		_order_dir  = "asc",
		_limit_n    = nil,
		_offset_n   = 0,
	}, QB)
end

function QB:where(conditions)
	self._wheres[#self._wheres + 1] = function(rec)
		for k, v in pairs(conditions) do
			if rec[k] ~= v then return false end
		end
		return true
	end
	return self
end

function QB:where_gt(field, value)
	self._wheres[#self._wheres + 1] = function(rec)
		return type(rec[field]) == "number" and rec[field] > value
	end
	return self
end

function QB:where_lt(field, value)
	self._wheres[#self._wheres + 1] = function(rec)
		return type(rec[field]) == "number" and rec[field] < value
	end
	return self
end

function QB:where_gte(field, value)
	self._wheres[#self._wheres + 1] = function(rec)
		return type(rec[field]) == "number" and rec[field] >= value
	end
	return self
end

function QB:where_lte(field, value)
	self._wheres[#self._wheres + 1] = function(rec)
		return type(rec[field]) == "number" and rec[field] <= value
	end
	return self
end

-- Simple SQL LIKE: % matches any sequence, _ matches any single char.
local function like_to_pattern(pat)
	-- Escape magic chars except % and _
	local out = pat:gsub("([%(%)%.%+%-%*%?%[%^%$%%])", function(c)
		if c == "%" or c == "_" then return c end
		return "%" .. c
	end)
	-- Replace LIKE wildcards with Lua pattern equivalents
	out = out:gsub("%%", ".*")
	out = out:gsub("_", ".")
	return "^" .. out .. "$"
end

function QB:where_like(field, pattern)
	local lua_pat = like_to_pattern(pattern)
	self._wheres[#self._wheres + 1] = function(rec)
		return type(rec[field]) == "string" and rec[field]:match(lua_pat) ~= nil
	end
	return self
end

function QB:order_by(field, dir)
	self._order_col = field
	self._order_dir = dir or "asc"
	return self
end

function QB:limit(n)
	self._limit_n = n
	return self
end

function QB:offset(n)
	self._offset_n = n or 0
	return self
end

function QB:execute()
	local model = self._model --[[:! ModelRef]]
	local storage = model._db._storage[model._name] or {}

	-- Collect matching records
	local results = {}
	for _, rec in pairs(storage) do
		local ok = true
		for _, pred in ipairs(self._wheres) do
			if not pred(rec) then ok = false; break end
		end
		if ok then
			results[#results + 1] = model:_wrap(shallow_copy(rec))
		end
	end

	-- Sort
	if self._order_col then
		local col = self._order_col
		local asc = self._order_dir ~= "desc"
		table.sort(results, function(a, b)
			local av, bv = a[col], b[col]
			if av == nil then return asc end
			if bv == nil then return not asc end
			if asc then return av < bv else return av > bv end
		end)
	end

	-- Offset + limit
	local off = self._offset_n or 0
	local lim = self._limit_n

	if off == 0 and not lim then
		return results
	end

	local out = {}
	for i = off + 1, #results do
		if lim and #out >= lim then break end
		out[#out + 1] = results[i]
	end
	return out
end

-- ── Record instance ───────────────────────────────────────────────────────────

local Record = {}
Record.__index = Record

function Record:update(changes)
	local model = self._model --[[:! ModelRef]]
	local pk = model._pk
	local id = self[pk]

	local storage = model._db._storage[model._name]
	if not storage or not storage[id] then
		return nil, "record not found"
	end

	-- Validate changes
	local errs = validate(changes, model._fields, storage, true, id)
	if errs then return nil, errs end

	-- Apply
	for k, v in pairs(changes) do
		storage[id][k] = v
		self[k] = v
	end
	return self
end

function Record:delete()
	local model = self._model --[[:! ModelRef]]
	local pk = model._pk
	local id = self[pk]

	local storage = model._db._storage[model._name]
	if not storage then return nil, "record not found" end
	storage[id] = nil
	return true
end

-- ── Model ─────────────────────────────────────────────────────────────────────

local Model = {}
Model.__index = Model

-- Wrap a raw record table in a Record instance with relationship methods.
function Model:_wrap(rec)
	-- Attach model reference
	local inst = setmetatable(rec, {
		__index = function(t, k)
			-- First check Record methods
			local rv = Record[k]
			if rv ~= nil then return rv end
			-- Then check relationship accessors
			local rel = self._relationships[k]
			if rel then
				return function(self_rec)
					return rel(self_rec, self._db)
				end
			end
		end
	})
	-- Store model ref for Record methods
	rawset(inst, "_model", self)
	return inst
end

-- Register a has_many relationship accessor by name.
-- `fn(rec, db) -> records`
function Model:_add_relationship(name, fn)
	self._relationships[name] = fn
end

--: (self: ModelRef, data: { [string]: unknown }) -> ({ [string]: unknown } | nil, { [string]: string } | nil)
function Model:create(data)
	local pk = self._pk
	local storage = self._db._storage[self._name]

	-- Apply defaults first
	local merged = apply_defaults(data, self._fields)

	-- Validate
	local errs = validate(merged, self._fields, storage, false, nil)
	if errs then return nil, errs end

	-- Assign primary key
	local id = self._db._next_id[self._name]
	self._db._next_id[self._name] = id + 1
	merged[pk] = id

	storage[id] = merged
	return self:_wrap(shallow_copy(merged))
end

--: (self: ModelRef, pk_val: unknown) -> { [string]: unknown } | nil
function Model:find(pk_val)
	local storage = self._db._storage[self._name]
	local rec = storage[pk_val]
	if not rec then return nil end
	return self:_wrap(shallow_copy(rec))
end

--: (self: ModelRef, conditions: { [string]: unknown }) -> { [string]: unknown } | nil
function Model:find_by(conditions)
	local storage = self._db._storage[self._name]
	for _, rec in pairs(storage) do
		local match = true
		for k, v in pairs(conditions) do
			if rec[k] ~= v then match = false; break end
		end
		if match then return self:_wrap(shallow_copy(rec)) end
	end
	return nil
end

--: (self: ModelRef, conditions: { [string]: unknown }) -> { [integer]: { [string]: unknown } }
function Model:where(conditions)
	local storage = self._db._storage[self._name]
	local results = {}
	for _, rec in pairs(storage) do
		local match = true
		for k, v in pairs(conditions) do
			if rec[k] ~= v then match = false; break end
		end
		if match then results[#results + 1] = self:_wrap(shallow_copy(rec)) end
	end
	return results
end

--: (self: ModelRef) -> { [integer]: { [string]: unknown } }
function Model:all()
	local storage = self._db._storage[self._name]
	local results = {}
	for _, rec in pairs(storage) do
		results[#results + 1] = self:_wrap(shallow_copy(rec))
	end
	return results
end

function Model:count(conditions)
	local storage = self._db._storage[self._name]
	local n = 0
	for _, rec in pairs(storage) do
		if not conditions then
			n = n + 1
		else
			local match = true
			for k, v in pairs(conditions) do
				if rec[k] ~= v then match = false; break end
			end
			if match then n = n + 1 end
		end
	end
	return n
end

function Model:query()
	return new_query_builder(self)
end

--: (self: ModelRef, conditions: { [string]: unknown }, changes: { [string]: unknown }) -> (integer | nil, { [string]: string } | nil)
function Model:update_where(conditions, changes)
	local storage = self._db._storage[self._name]
	local count = 0
	for id, rec in pairs(storage) do
		local match = true
		for k, v in pairs(conditions) do
			if rec[k] ~= v then match = false; break end
		end
		if match then
			-- Validate changes against this record
			local errs = validate(changes, self._fields, storage, true, id --[[:! integer]])
			if errs then return nil, errs end
			for k, v in pairs(changes) do
				rec[k] = v
			end
			count = count + 1
		end
	end
	return count
end

function Model:delete_where(conditions)
	local storage = self._db._storage[self._name]
	local count = 0
	local to_delete = {}
	for id, rec in pairs(storage) do
		local match = true
		for k, v in pairs(conditions) do
			if rec[k] ~= v then match = false; break end
		end
		if match then to_delete[#to_delete + 1] = id end
	end
	for _, id in ipairs(to_delete) do
		storage[id] = nil
		count = count + 1
	end
	return count
end

-- ── Database ──────────────────────────────────────────────────────────────────

local DB = {}
DB.__index = DB

function DB:model(name, schema)
	local fields = schema.fields or {}

	-- Find primary key
	local pk = "id"
	for fname, def in pairs(fields) do
		if def.primary_key then pk = fname; break end
	end

	-- Ensure storage exists
	if not self._storage[name] then
		self._storage[name] = {}
	end
	if not self._next_id[name] then
		self._next_id[name] = 1
	end

	local mod = setmetatable({
		_db            = self,
		_name          = name,
		_pk            = pk,
		_fields        = fields,
		_relationships = {},
	}, Model)

	-- Auto-build relationships from foreign_key declarations
	for fname, def in pairs(fields) do
		if def.foreign_key then
			-- e.g. "users.id" → target model "users", target field "id"
			local target_model_name, target_field = def.foreign_key:match("^(.+)%.(.+)$")
			if target_model_name and target_field then
				-- This model belongs_to the target; register accessor with target's model name
				-- e.g. for post with user_id FK to users.id, register post:user()
				local accessor_name = target_model_name:gsub("s$", "")  -- naive singular
				local fk_field = fname
				mod:_add_relationship(accessor_name, function(rec, db)
					local target_model = db._models[target_model_name]
					if not target_model then return nil end
					local target_storage = db._storage[target_model_name]
					if not target_storage then return nil end
					local fk_val = rec[fk_field]
					if fk_val == nil then return nil end
					for _, trec in pairs(target_storage) do
						if trec[target_field] == fk_val then
							return target_model:_wrap(shallow_copy(trec))
						end
					end
					return nil
				end)
			end
		end
	end

	self._models[name] = mod
	return mod
end

-- Wire up has_many after models are defined (called lazily at first access).
-- For each model with a foreign_key pointing to this model, register accessor.
--: (self: DbRef) -> nil
function DB:_build_has_many()
	for source_name, source_model in pairs(self._models) do
		for fname, def in pairs(source_model._fields) do
			if def.foreign_key then
				local target_name, target_field = def.foreign_key:match("^(.+)%.(.+)$")
				if target_name and target_field then
					local target_model = self._models[target_name]
					if target_model and not target_model._relationships[source_name] then
						-- Register "posts" accessor on User that returns all Posts for user.id
						local fk_field = fname
						local src_model_ref = source_model
						local src_name = source_name
						target_model:_add_relationship(src_name, function(rec, db)
							local pk_val = rec[target_model._pk]
							local src_storage = db._storage[src_name]
							if not src_storage then return {} end
							local results = {}
							for _, srec in pairs(src_storage) do
								if srec[fk_field] == pk_val then
									results[#results + 1] = (src_model_ref --[[:! ModelRef]]):_wrap(shallow_copy(srec))
								end
							end
							return results
						end)
					end
				end
			end
		end
	end
end

function DB:transaction(fn)
	-- Copy-on-write snapshot
	local saved_storage = deep_copy_tables(self._storage)
	local saved_next_id = copy_next_ids(self._next_id)

	local ok, err = pcall(fn)
	if not ok then
		-- Rollback
		self._storage = saved_storage
		self._next_id = saved_next_id
		return nil, err
	end
	return true
end

-- ── Migrations ────────────────────────────────────────────────────────────────

local Schema = {}
Schema.__index = Schema

function Schema:add_column(model_name, col_name, def)
	local db = self._db
	-- Update field schema
	if db._models[model_name] then
		db._models[model_name]._fields[col_name] = def
	end
	-- Apply default to all existing records
	local storage = db._storage[model_name]
	if storage and def and def.default ~= nil then
		for _, rec in pairs(storage) do
			if rec[col_name] == nil then
				rec[col_name] = def.default
			end
		end
	end
end

function Schema:remove_column(model_name, col_name)
	local db = self._db
	if db._models[model_name] then
		db._models[model_name]._fields[col_name] = nil
	end
	local storage = db._storage[model_name]
	if storage then
		for _, rec in pairs(storage) do
			rec[col_name] = nil
		end
	end
end

function Schema:rename_column(model_name, old_name, new_name)
	local db = self._db
	if db._models[model_name] then
		local fields = db._models[model_name]._fields
		fields[new_name] = fields[old_name]
		fields[old_name] = nil
	end
	local storage = db._storage[model_name]
	if storage then
		for _, rec in pairs(storage) do
			rec[new_name] = rec[old_name]
			rec[old_name] = nil
		end
	end
end

function DB:migrate(migrations)
	local current = self._migration_version

	-- Sort by version
	local sorted = {}
	for _, m in ipairs(migrations) do
		sorted[#sorted + 1] = m
	end
	table.sort(sorted, function(a, b) return a.version < b.version end)

	local schema = setmetatable({ _db = self }, Schema)

	for _, m in ipairs(sorted) do
		if m.version > current then
			m.up(schema)
			self._migration_version = m.version
		end
	end
end

function DB:rollback(migrations, target_version)
	local current = self._migration_version
	target_version = target_version or (current - 1)

	-- Sort descending
	local sorted = {}
	for _, m in ipairs(migrations) do
		sorted[#sorted + 1] = m
	end
	table.sort(sorted, function(a, b) return a.version > b.version end)

	local schema = setmetatable({ _db = self }, Schema)

	for _, m in ipairs(sorted) do
		if m.version <= current and m.version > target_version and m.down then
			m.down(schema)
			self._migration_version = m.version - 1
		end
	end
end

function DB:current_version()
	return self._migration_version
end

-- ── Dump / Load ───────────────────────────────────────────────────────────────

function DB:dump()
	local out = {
		storage         = deep_copy_tables(self._storage),
		next_id         = copy_next_ids(self._next_id),
		migration_version = self._migration_version,
		-- We don't serialize model schemas in the dump (caller must recreate models)
	}
	return out
end

function M.load(dump)
	local db = M.database()
	db._storage = deep_copy_tables(dump.storage or {})
	db._next_id = copy_next_ids(dump.next_id or {})
	db._migration_version = dump.migration_version or 0
	return db
end

-- ── ORM.database() ────────────────────────────────────────────────────────────

function M.database()
	local db = setmetatable({
		_storage          = {},
		_next_id          = {},
		_models           = {},
		_migration_version = 0,
	}, DB)
	return db
end

return M
