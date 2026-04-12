if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function typename(v)
  if v == nil then return "nil" end
  return type(v)
end

local function shallow_copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

local function add_issue(issues, path, message, type_)
  issues[#issues + 1] = { path = path, message = message, type = type_ or "validation_error" }
end

local function join_path(parent, key)
  if type(key) == "number" then
    return (parent == "" and "" or parent) .. "[" .. key .. "]"
  end
  if parent == "" then return tostring(key) end
  return parent .. "." .. key
end

-- ---------------------------------------------------------------------------
-- Design: Zod-style dot-call chaining in Lua
--
-- In Lua, `obj.method(arg)` is different from `obj:method(arg)`:
--   obj.method(arg)  → looks up obj.method, calls it with (arg)         [no self]
--   obj:method(arg)  → looks up obj.method, calls it with (obj, arg)    [self prepended]
--
-- Zod-style chaining like z.string().min(3).max(50) uses dot calls.
-- parse/safe_parse are conventionally called with colon: schema:parse(data).
--
-- Strategy:
--   - Chaining methods (min, max, integer, ...) are stored in a vtable and
--     accessed via __index as bound closures, so dot-call works: .min(3).
--   - parse, safe_parse, and _run are stored as direct fields on each schema
--     instance, so colon-call works correctly: schema:parse(data).
-- ---------------------------------------------------------------------------

-- Forward declarations
local run_schema    -- dispatch _run through the correct vtable

-- ---------------------------------------------------------------------------
-- Vtable definitions (one per schema type, inheriting from SchemaVtable)
-- ---------------------------------------------------------------------------

local SchemaVtable = {}
local StringVtable  = setmetatable({}, { __index = SchemaVtable })
local NumberVtable  = setmetatable({}, { __index = SchemaVtable })
local BooleanVtable = setmetatable({}, { __index = SchemaVtable })
local NilVtable     = setmetatable({}, { __index = SchemaVtable })
local AnyVtable     = setmetatable({}, { __index = SchemaVtable })
local LiteralVtable = setmetatable({}, { __index = SchemaVtable })
local EnumVtable    = setmetatable({}, { __index = SchemaVtable })
local ObjectVtable  = setmetatable({}, { __index = SchemaVtable })
local ArrayVtable   = setmetatable({}, { __index = SchemaVtable })
local UnionVtable   = setmetatable({}, { __index = SchemaVtable })

local function make_metatable(vtable)
  return {
    __index = function(self, key)
      local fn = vtable[key]
      if fn ~= nil then
        -- Return a bound closure for dot-call chaining: schema.min(3)
        return function(...) return fn(self, ...) end
      end
      return nil
    end
  }
end

local StringMT  = make_metatable(StringVtable)
local NumberMT  = make_metatable(NumberVtable)
local BooleanMT = make_metatable(BooleanVtable)
local NilMT     = make_metatable(NilVtable)
local AnyMT     = make_metatable(AnyVtable)
local LiteralMT = make_metatable(LiteralVtable)
local EnumMT    = make_metatable(EnumVtable)
local ObjectMT  = make_metatable(ObjectVtable)
local ArrayMT   = make_metatable(ArrayVtable)
local UnionMT   = make_metatable(UnionVtable)

-- ---------------------------------------------------------------------------
-- parse and safe_parse as regular methods (colon-call compatible)
-- stored directly on instances so __index is never invoked for them
-- ---------------------------------------------------------------------------

local function schema_parse(self, data)
  local issues = {}
  local result = run_schema(self, data, "", issues)
  if #issues > 0 then
    return nil, { type = "error", issues = issues }
  end
  return result
end

local function schema_safe_parse(self, data)
  local value, err = schema_parse(self, data)
  if err then
    return { success = false, error = err }
  end
  return { success = true, data = value }
end

-- Attach parse/safe_parse directly to a schema table (bypasses __index)
local function attach_parse(s)
  s.parse      = schema_parse
  s.safe_parse = schema_safe_parse
  return s
end

-- ---------------------------------------------------------------------------
-- Schema construction / cloning
-- ---------------------------------------------------------------------------

local function new_schema(mt, base_type, extra)
  local s = setmetatable({}, mt)
  s._mt          = mt
  s._base_type   = base_type
  s._checks      = {}
  s._optional    = false
  s._nullable    = false
  s._default     = nil
  s._has_default = false
  s._transforms  = {}
  s._description = nil
  s._coerce_fn   = nil
  if extra then
    for k, v in pairs(extra) do s[k] = v end
  end
  attach_parse(s)
  return s
end

local function clone_schema(s)
  local c = setmetatable({}, s._mt)
  c._mt          = s._mt
  c._base_type   = s._base_type
  c._checks      = shallow_copy(s._checks)
  c._optional    = s._optional
  c._nullable    = s._nullable
  c._default     = s._default
  c._has_default = s._has_default
  c._transforms  = shallow_copy(s._transforms)
  c._description = s._description
  c._coerce_fn   = s._coerce_fn
  -- subclass-specific fields
  if s._fields        ~= nil then c._fields        = s._fields        end
  if s._strict        ~= nil then c._strict        = s._strict        end
  if s._item_schema   ~= nil then c._item_schema   = s._item_schema   end
  if s._schemas       ~= nil then c._schemas       = s._schemas       end
  if s._literal_value ~= nil then c._literal_value = s._literal_value end
  if s._enum_values   ~= nil then c._enum_values   = s._enum_values   end
  if s._arr_min       ~= nil then c._arr_min       = s._arr_min       end
  if s._arr_max       ~= nil then c._arr_max       = s._arr_max       end
  attach_parse(c)
  return c
end

local function add_check(s, fn, fatal)
  local c = clone_schema(s)
  c._checks[#c._checks + 1] = { fn = fn, fatal = fatal }
  return c
end

-- ---------------------------------------------------------------------------
-- default_run: standard check+transform loop for most schema types
-- ---------------------------------------------------------------------------

local function default_run(s, value, path, issues)
  if value == nil and s._has_default then
    value = s._default
  end
  if value == nil and (s._optional or s._nullable) then
    return nil
  end
  if s._coerce_fn and value ~= nil then
    local coerced = s._coerce_fn(value)
    if coerced ~= nil then value = coerced end
  end

  local start_issues = #issues

  for i = 1, #s._checks do
    local c = s._checks[i]
    local result = c.fn(value, path, issues)
    if result ~= nil then
      value = result
    end
    if c.fatal and #issues > start_issues then
      return nil
    end
  end

  if #issues > start_issues then
    return nil
  end

  for i = 1, #s._transforms do
    value = s._transforms[i](value)
  end
  return value
end

-- ---------------------------------------------------------------------------
-- run_schema: dispatch _run via the vtable for a given schema
-- ---------------------------------------------------------------------------

-- Vtable override registry: maps vtable -> _run function
-- We populate this after defining the vtable functions.
local vtable_run_overrides = {}

run_schema = function(s, value, path, issues)
  local mt = s._mt
  if mt then
    local vtable_mt = getmetatable(mt)
    -- mt is the schema's metatable (e.g. StringMT).
    -- The vtable is accessible through mt.__index closure scope — we can't
    -- directly access it from outside. Instead we use a side table keyed by mt.
    local override = vtable_run_overrides[mt]
    if override then
      return override(s, value, path, issues)
    end
  end
  return default_run(s, value, path, issues)
end

local function register_run(mt, fn)
  vtable_run_overrides[mt] = fn
end

-- ---------------------------------------------------------------------------
-- Common vtable methods (chaining, shared by all schema types)
-- ---------------------------------------------------------------------------

function SchemaVtable:optional()
  local s = clone_schema(self)
  s._optional = true
  return s
end

function SchemaVtable:nullable()
  local s = clone_schema(self)
  s._nullable = true
  return s
end

function SchemaVtable:default(v)
  local s = clone_schema(self)
  s._default = v
  s._has_default = true
  s._optional = true
  return s
end

function SchemaVtable:transform(fn)
  local s = clone_schema(self)
  s._transforms[#s._transforms + 1] = fn
  return s
end

function SchemaVtable:refine(fn, msg)
  return add_check(self, function(value, path, issues)
    if not fn(value) then
      add_issue(issues, path, msg or "refinement failed")
      return nil
    end
    return value
  end, false)
end

function SchemaVtable:describe(msg)
  local s = clone_schema(self)
  s._description = msg
  return s
end

-- ---------------------------------------------------------------------------
-- String schema
-- ---------------------------------------------------------------------------

local function string_type_check(value, path, issues)
  if type(value) ~= "string" then
    add_issue(issues, path, "expected string, got " .. typename(value), "type_error")
    return nil
  end
  return value
end

local function new_string_schema()
  local s = new_schema(StringMT, "string")
  s._checks[1] = { fn = string_type_check, fatal = true }
  return s
end

function StringVtable:min(n)
  return add_check(self, function(value, path, issues)
    if #value < n then
      add_issue(issues, path, "string too short: minimum length is " .. n .. ", got " .. #value)
      return nil
    end
    return value
  end, false)
end

function StringVtable:max(n)
  return add_check(self, function(value, path, issues)
    if #value > n then
      add_issue(issues, path, "string too long: maximum length is " .. n .. ", got " .. #value)
      return nil
    end
    return value
  end, false)
end

function StringVtable:length(n)
  return add_check(self, function(value, path, issues)
    if #value ~= n then
      add_issue(issues, path, "string must be exactly " .. n .. " characters, got " .. #value)
      return nil
    end
    return value
  end, false)
end

function StringVtable:pattern(pat)
  return add_check(self, function(value, path, issues)
    if not value:find(pat) then
      add_issue(issues, path, "string does not match pattern '" .. pat .. "'")
      return nil
    end
    return value
  end, false)
end

function StringVtable:email()
  return add_check(self, function(value, path, issues)
    if not value:find("^[^@]+@[^@]+%.[^@]+$") then
      add_issue(issues, path, "invalid email address")
      return nil
    end
    return value
  end, false)
end

function StringVtable:url()
  return add_check(self, function(value, path, issues)
    if not value:find("^https?://") then
      add_issue(issues, path, "invalid URL (must start with http:// or https://)")
      return nil
    end
    return value
  end, false)
end

function StringVtable:trim()
  local s = clone_schema(self)
  s._transforms[#s._transforms + 1] = function(v)
    return v:match("^%s*(.-)%s*$")
  end
  return s
end

-- ---------------------------------------------------------------------------
-- Number schema
-- ---------------------------------------------------------------------------

local function number_type_check(value, path, issues)
  if type(value) ~= "number" then
    add_issue(issues, path, "expected number, got " .. typename(value), "type_error")
    return nil
  end
  return value
end

local function new_number_schema()
  local s = new_schema(NumberMT, "number")
  s._checks[1] = { fn = number_type_check, fatal = true }
  return s
end

function NumberVtable:min(n)
  return add_check(self, function(value, path, issues)
    if value < n then
      add_issue(issues, path, "number too small: minimum is " .. n .. ", got " .. value)
      return nil
    end
    return value
  end, false)
end

function NumberVtable:max(n)
  return add_check(self, function(value, path, issues)
    if value > n then
      add_issue(issues, path, "number too large: maximum is " .. n .. ", got " .. value)
      return nil
    end
    return value
  end, false)
end

function NumberVtable:integer()
  return add_check(self, function(value, path, issues)
    if value ~= math.floor(value) then
      add_issue(issues, path, "expected integer, got " .. value)
      return nil
    end
    return value
  end, false)
end

function NumberVtable:positive()
  return add_check(self, function(value, path, issues)
    if value <= 0 then
      add_issue(issues, path, "expected positive number, got " .. value)
      return nil
    end
    return value
  end, false)
end

function NumberVtable:negative()
  return add_check(self, function(value, path, issues)
    if value >= 0 then
      add_issue(issues, path, "expected negative number, got " .. value)
      return nil
    end
    return value
  end, false)
end

-- ---------------------------------------------------------------------------
-- Boolean schema
-- ---------------------------------------------------------------------------

local function boolean_type_check(value, path, issues)
  if type(value) ~= "boolean" then
    add_issue(issues, path, "expected boolean, got " .. typename(value), "type_error")
    return nil
  end
  return value
end

local function new_boolean_schema()
  local s = new_schema(BooleanMT, "boolean")
  s._checks[1] = { fn = boolean_type_check, fatal = true }
  return s
end

-- ---------------------------------------------------------------------------
-- Nil schema
-- ---------------------------------------------------------------------------

local function new_nil_schema()
  local s = new_schema(NilMT, "nil")
  s._nullable = true
  s._checks[1] = { fn = function(value, path, issues)
    if value ~= nil then
      add_issue(issues, path, "expected nil, got " .. typename(value), "type_error")
      return nil
    end
    return value
  end, fatal = true }
  return s
end

-- ---------------------------------------------------------------------------
-- Any schema
-- ---------------------------------------------------------------------------

local function new_any_schema()
  return new_schema(AnyMT, "any")
end

local function any_run(s, value, path, issues)
  if value == nil and s._has_default then value = s._default end
  for i = 1, #s._transforms do
    value = s._transforms[i](value)
  end
  return value
end

register_run(AnyMT, any_run)

-- ---------------------------------------------------------------------------
-- Literal schema
-- ---------------------------------------------------------------------------

local function new_literal_schema(literal_value)
  local s = new_schema(LiteralMT, "literal")
  s._literal_value = literal_value
  s._checks[1] = { fn = function(value, path, issues)
    if value ~= literal_value then
      add_issue(issues, path, "expected literal " .. tostring(literal_value) .. ", got " .. tostring(value), "type_error")
      return nil
    end
    return value
  end, fatal = true }
  return s
end

-- ---------------------------------------------------------------------------
-- Enum schema
-- ---------------------------------------------------------------------------

local function new_enum_schema(values)
  local s = new_schema(EnumMT, "enum")
  s._enum_values = values
  local lookup = {}
  for i = 1, #values do lookup[values[i]] = true end
  s._checks[1] = { fn = function(value, path, issues)
    if not lookup[value] then
      local listed = {}
      for i = 1, #values do listed[i] = tostring(values[i]) end
      add_issue(issues, path, "expected one of [" .. table.concat(listed, ", ") .. "], got " .. tostring(value), "type_error")
      return nil
    end
    return value
  end, fatal = true }
  return s
end

-- ---------------------------------------------------------------------------
-- Object schema
-- ---------------------------------------------------------------------------

local function new_object_schema(fields)
  local s = new_schema(ObjectMT, "object")
  s._fields = fields
  s._strict = false
  return s
end

function ObjectVtable:strict()
  local s = clone_schema(self)
  s._strict = true
  return s
end

local function object_run(s, value, path, issues)
  if value == nil and s._has_default then value = s._default end
  if value == nil and (s._optional or s._nullable) then return nil end

  if type(value) ~= "table" then
    add_issue(issues, path, "expected object (table), got " .. typename(value), "type_error")
    return nil
  end

  if s._strict then
    for k in pairs(value) do
      if s._fields[k] == nil then
        add_issue(issues, join_path(path, k), "unknown key '" .. tostring(k) .. "'")
      end
    end
  end

  local out = {}
  for key, field_schema in pairs(s._fields) do
    local child_path = join_path(path, key)
    local raw = value[key]
    local field_val = run_schema(field_schema, raw, child_path, issues)
    if field_val ~= nil then
      out[key] = field_val
    end
  end

  local result = out
  for i = 1, #s._transforms do
    result = s._transforms[i](result)
  end
  return result
end

register_run(ObjectMT, object_run)

-- ---------------------------------------------------------------------------
-- Array schema
-- ---------------------------------------------------------------------------

local function new_array_schema(item_schema)
  local s = new_schema(ArrayMT, "array")
  s._item_schema = item_schema
  s._arr_min = nil
  s._arr_max = nil
  return s
end

function ArrayVtable:min(n)
  local s = clone_schema(self)
  s._arr_min = n
  return s
end

function ArrayVtable:max(n)
  local s = clone_schema(self)
  s._arr_max = n
  return s
end

function ArrayVtable:nonempty()
  local s = clone_schema(self)
  s._arr_min = 1
  return s
end

local function array_run(s, value, path, issues)
  if value == nil and s._has_default then value = s._default end
  if value == nil and (s._optional or s._nullable) then return nil end

  if type(value) ~= "table" then
    add_issue(issues, path, "expected array (table), got " .. typename(value), "type_error")
    return nil
  end

  local len = #value
  if s._arr_min and len < s._arr_min then
    add_issue(issues, path, "array too short: minimum " .. s._arr_min .. " items, got " .. len)
  end
  if s._arr_max and len > s._arr_max then
    add_issue(issues, path, "array too long: maximum " .. s._arr_max .. " items, got " .. len)
  end

  local item = s._item_schema
  local out = {}
  for i = 1, len do
    local child_path = join_path(path, i)
    local item_val = run_schema(item, value[i], child_path, issues)
    out[i] = item_val
  end

  local result = out
  for i = 1, #s._transforms do
    result = s._transforms[i](result)
  end
  return result
end

register_run(ArrayMT, array_run)

-- ---------------------------------------------------------------------------
-- Union schema
-- ---------------------------------------------------------------------------

local function new_union_schema(schemas)
  local s = new_schema(UnionMT, "union")
  s._schemas = schemas
  return s
end

local function union_run(s, value, path, issues)
  if value == nil and s._has_default then value = s._default end
  if value == nil and (s._optional or s._nullable) then return nil end

  for i = 1, #s._schemas do
    local trial_issues = {}
    local sub = s._schemas[i]
    local result = run_schema(sub, value, path, trial_issues)
    if #trial_issues == 0 then
      for j = 1, #s._transforms do
        result = s._transforms[j](result)
      end
      return result
    end
  end

  add_issue(issues, path, "value did not match any schema in union", "type_error")
  return nil
end

register_run(UnionMT, union_run)

-- ---------------------------------------------------------------------------
-- Coerce wrappers
-- ---------------------------------------------------------------------------

local function with_coerce(s, fn)
  local c = clone_schema(s)
  c._coerce_fn = fn
  return c
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.string()    return new_string_schema()         end
function M.number()    return new_number_schema()         end
function M.boolean()   return new_boolean_schema()        end
function M.nil_()      return new_nil_schema()            end
function M.any()       return new_any_schema()            end
function M.literal(v)  return new_literal_schema(v)       end
function M.enum(vals)  return new_enum_schema(vals)        end
function M.object(f)   return new_object_schema(f)        end
function M.array(item) return new_array_schema(item)      end
function M.union(ss)   return new_union_schema(ss)        end

function M.merge(base_schema, extra)
  local new_fields = {}
  for k, v in pairs(base_schema._fields) do new_fields[k] = v end
  local extra_fields = extra._fields or extra
  for k, v in pairs(extra_fields) do new_fields[k] = v end
  return new_object_schema(new_fields)
end

M.coerce = {
  number = function()
    return with_coerce(new_number_schema(), function(v)
      return tonumber(v)  -- nil if not convertible; type check will catch it
    end)
  end,
  string = function()
    return with_coerce(new_string_schema(), function(v)
      return tostring(v)
    end)
  end,
  boolean = function()
    return with_coerce(new_boolean_schema(), function(v)
      if v == true  or v == 1 or v == "true"  or v == "1"  then return true  end
      if v == false or v == 0 or v == "false" or v == "0"  then return false end
      return v
    end)
  end,
}

return M
