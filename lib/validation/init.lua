if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- lib/validation: composable schema-based data validation with structured errors

local M = {}
M._tier = "pure"

-- ── helpers ──────────────────────────────────────────────────────────────────

local function make_error(message, errors)
  return { message = message, errors = errors or {} }
end

local function push_error(errs, path, message)
  errs[#errs + 1] = { path = path, message = message }
end

local function prefix_errors(errs, prefix)
  local out = {}
  for i = 1, #errs do
    local e = errs[i]
    local p = e.path and (e.path ~= "" and (prefix .. "." .. e.path) or prefix) or prefix
    out[i] = { path = p, message = e.message }
  end
  return out
end

-- ── schema base ──────────────────────────────────────────────────────────────

-- Every schema is a table with a `_validate(value, path) -> ok, errs` method.
-- `check` and `parse` are defined on the base prototype.


local Schema = {}
Schema.__index = Schema

function Schema:check(value)
  local ok, errs = self:_validate(value, "")
  if ok then
    return true
  end
  return false, make_error("validation failed", errs)
end

function Schema:parse(value)
  local ok, errs, coerced = self:_parse(value, "")
  if ok then
    return coerced
  end
  return nil, make_error("validation failed", errs)
end

-- Default _parse delegates to _validate (no coercion).
function Schema:_parse(value, path)
  local ok, errs = self:_validate(value, path)
  return ok, errs, value
end

function Schema:is_optional()
  return self._is_optional or false
end

function Schema:type_name()
  return self._type_name or "unknown"
end

-- Modifiers that return new schema objects (chainable).

function Schema:nullable()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._is_optional = true
  return s
end

Schema.optional = Schema.nullable  -- alias

function Schema:default(val)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._default = val
  s._is_optional = true
  return s
end

-- ── primitive factory ─────────────────────────────────────────────────────────

--: (unknown) -> unknown
local function new_schema(proto)
  proto.__index = proto
  setmetatable(proto, { __index = Schema })
  return proto
end

-- Wrap _validate to handle optional/default before checking.
local function wrap_optional(schema)
  local orig = schema._validate
  schema._validate = function(self, value, path)
    if value == nil then
      if self._default ~= nil then
        return true, nil
      end
      if self._is_optional then
        return true, nil
      end
      local errs = {}
      push_error(errs, path, "required")
      return false, errs
    end
    return orig(self, value, path)
  end

  local orig_parse = schema._parse
  schema._parse = function(self, value, path)
    if value == nil then
      if self._default ~= nil then
        return true, nil, self._default
      end
      if self._is_optional then
        return true, nil, nil
      end
      local errs = {}
      push_error(errs, path, "required")
      return false, errs, nil
    end
    return orig_parse(self, value, path)
  end
end

-- ── string ────────────────────────────────────────────────────────────────────

local StringSchema = new_schema({ _type_name = "string", _coerce = false })

function StringSchema:_validate_inner(value, path)
  local errs = {}
  if type(value) ~= "string" then
    push_error(errs, path, "expected string, got " .. type(value))
    return false, errs
  end
  if self._min ~= nil and #value < self._min then
    push_error(errs, path, "too short (min " .. self._min .. ")")
    return false, errs
  end
  if self._max ~= nil and #value > self._max then
    push_error(errs, path, "too long (max " .. tostring(self._max) .. ")")
    return false, errs
  end
  if self._pattern ~= nil and not value:match(self._pattern) then
    push_error(errs, path, self._pattern_msg or ("must match pattern " .. tostring(self._pattern)))
    return false, errs
  end
  if self._non_empty and #value == 0 then
    push_error(errs, path, "must not be empty")
    return false, errs
  end
  if self._email then
    -- Basic email: something@something.something
    if not value:match("^[^@]+@[^@]+%.[^@]+$") then
      push_error(errs, path, "invalid email address")
      return false, errs
    end
  end
  if self._url then
    -- Basic URL: scheme://rest
    if not value:match("^%a[%a%d+%-%.]*://") then
      push_error(errs, path, "invalid URL")
      return false, errs
    end
  end
  return true, errs
end

function StringSchema:_validate(value, path)
  if value == nil then
    if self._default ~= nil then return true, {} end
    if self._is_optional then return true, {} end
    local errs = {}; push_error(errs, path, "required"); return false, errs
  end
  return self:_validate_inner(value, path)
end

function StringSchema:_parse(value, path)
  if value == nil then
    if self._default ~= nil then return true, nil, self._default end
    if self._is_optional then return true, nil, nil end
    local errs = {}; push_error(errs, path, "required"); return false, errs, nil
  end
  local coerced = value
  if self._coerce and type(value) ~= "string" then
    coerced = tostring(value)
  end
  local ok, errs = self:_validate_inner(coerced, path)
  return ok, errs, coerced
end

function StringSchema:min(n)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._min = n
  return s
end

function StringSchema:max(n)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._max = n
  return s
end

function StringSchema:pattern(pat, msg)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._pattern = pat
  s._pattern_msg = msg
  return s
end

function StringSchema:non_empty()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._non_empty = true
  return s
end

function StringSchema:email()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._email = true
  return s
end

function StringSchema:url()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._url = true
  return s
end

function StringSchema:coerce()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._coerce = true
  return s
end

function StringSchema:nullable()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._is_optional = true
  return s
end

StringSchema.optional = Schema.nullable

function StringSchema:default(val)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._default = val
  s._is_optional = true
  return s
end

function M.string()
  return setmetatable({ _type_name = "string", _coerce = false }, StringSchema)
end

-- ── number ────────────────────────────────────────────────────────────────────

local NumberSchema = new_schema({ _type_name = "number", _coerce = false })

function NumberSchema:_validate_inner(value, path)
  local errs = {}
  if type(value) ~= "number" then
    push_error(errs, path, "expected number, got " .. type(value))
    return false, errs
  end
  if self._int and math.floor(value) ~= value then
    push_error(errs, path, "must be a whole number")
    return false, errs
  end
  if self._positive and value <= 0 then
    push_error(errs, path, "must be positive")
    return false, errs
  end
  if self._min ~= nil and value < self._min then
    push_error(errs, path, "too small (min " .. tostring(self._min) .. ")")
    return false, errs
  end
  if self._max ~= nil and value > self._max then
    push_error(errs, path, "too large (max " .. tostring(self._max) .. ")")
    return false, errs
  end
  return true, errs
end

function NumberSchema:_validate(value, path)
  if value == nil then
    if self._default ~= nil then return true, {} end
    if self._is_optional then return true, {} end
    local errs = {}; push_error(errs, path, "required"); return false, errs
  end
  return self:_validate_inner(value, path)
end

function NumberSchema:_parse(value, path)
  if value == nil then
    if self._default ~= nil then return true, nil, self._default end
    if self._is_optional then return true, nil, nil end
    local errs = {}; push_error(errs, path, "required"); return false, errs, nil
  end
  local coerced = value
  if self._coerce and type(value) ~= "number" then
    local n = tonumber(value)
    if n == nil then
      local errs = {}
      push_error(errs, path, "cannot coerce to number: " .. tostring(value))
      return false, errs, nil
    end
    coerced = n
  end
  local ok, errs = self:_validate_inner(coerced, path)
  return ok, errs, coerced
end

function NumberSchema:min(n)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._min = n
  return s
end

function NumberSchema:max(n)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._max = n
  return s
end

function NumberSchema:positive()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._positive = true
  return s
end

function NumberSchema:int()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._int = true
  return s
end

function NumberSchema:coerce()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._coerce = true
  return s
end

function NumberSchema:nullable()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._is_optional = true
  return s
end

NumberSchema.optional = Schema.nullable

function NumberSchema:default(val)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._default = val
  s._is_optional = true
  return s
end

function M.number()
  return setmetatable({ _type_name = "number", _coerce = false }, NumberSchema)
end

-- ── integer ───────────────────────────────────────────────────────────────────

local IntegerSchema = new_schema({ _type_name = "integer", _coerce = false })

function IntegerSchema:_validate_inner(value, path)
  local errs = {}
  if type(value) ~= "number" then
    push_error(errs, path, "expected integer, got " .. type(value))
    return false, errs
  end
  if math.floor(value) ~= value then
    push_error(errs, path, "must be an integer")
    return false, errs
  end
  if self._min ~= nil and value < self._min then
    push_error(errs, path, "too small (min " .. tostring(self._min) .. ")")
    return false, errs
  end
  if self._max ~= nil and value > self._max then
    push_error(errs, path, "too large (max " .. tostring(self._max) .. ")")
    return false, errs
  end
  return true, errs
end

function IntegerSchema:_validate(value, path)
  if value == nil then
    if self._default ~= nil then return true, {} end
    if self._is_optional then return true, {} end
    local errs = {}; push_error(errs, path, "required"); return false, errs
  end
  return self:_validate_inner(value, path)
end

function IntegerSchema:_parse(value, path)
  if value == nil then
    if self._default ~= nil then return true, nil, self._default end
    if self._is_optional then return true, nil, nil end
    local errs = {}; push_error(errs, path, "required"); return false, errs, nil
  end
  local ok, errs = self:_validate_inner(value, path)
  return ok, errs, value
end

function IntegerSchema:between(lo, hi)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._min = lo
  s._max = hi
  return s
end

function IntegerSchema:min(n)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._min = n
  return s
end

function IntegerSchema:max(n)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._max = n
  return s
end

function IntegerSchema:nullable()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._is_optional = true
  return s
end

IntegerSchema.optional = Schema.nullable

function IntegerSchema:default(val)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._default = val
  s._is_optional = true
  return s
end

function M.integer()
  return setmetatable({ _type_name = "integer", _coerce = false }, IntegerSchema)
end

-- ── boolean ───────────────────────────────────────────────────────────────────

local BooleanSchema = new_schema({ _type_name = "boolean", _coerce = false })

local TRUTHY = { ["true"] = true, ["1"] = true, ["yes"] = true, [1] = true }
local FALSY  = { ["false"] = true, ["0"] = true, ["no"] = true, [0] = true }

function BooleanSchema:_validate_inner(value, path)
  local errs = {}
  if type(value) ~= "boolean" then
    push_error(errs, path, "expected boolean, got " .. type(value))
    return false, errs
  end
  return true, errs
end

function BooleanSchema:_validate(value, path)
  if value == nil then
    if self._default ~= nil then return true, {} end
    if self._is_optional then return true, {} end
    local errs = {}; push_error(errs, path, "required"); return false, errs
  end
  return self:_validate_inner(value, path)
end

function BooleanSchema:_parse(value, path)
  if value == nil then
    if self._default ~= nil then return true, nil, self._default end
    if self._is_optional then return true, nil, nil end
    local errs = {}; push_error(errs, path, "required"); return false, errs, nil
  end
  local coerced = value
  if self._coerce and type(value) ~= "boolean" then
    if TRUTHY[value] then
      coerced = true
    elseif FALSY[value] then
      coerced = false
    else
      local errs = {}
      push_error(errs, path, "cannot coerce to boolean: " .. tostring(value))
      return false, errs, nil
    end
  end
  local ok, errs = self:_validate_inner(coerced, path)
  return ok, errs, coerced
end

function BooleanSchema:coerce()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._coerce = true
  return s
end

function BooleanSchema:nullable()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._is_optional = true
  return s
end

BooleanSchema.optional = Schema.nullable

function BooleanSchema:default(val)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._default = val
  s._is_optional = true
  return s
end

function M.boolean()
  return setmetatable({ _type_name = "boolean", _coerce = false }, BooleanSchema)
end

-- ── nil_val ───────────────────────────────────────────────────────────────────

local NilSchema = new_schema({ _type_name = "nil" })

function NilSchema:_validate(value, path)
  if value ~= nil then
    local errs = {}
    push_error(errs, path, "expected nil, got " .. type(value))
    return false, errs
  end
  return true, {}
end

function NilSchema:_parse(value, path)
  local ok, errs = self:_validate(value, path)
  return ok, errs, nil
end

function NilSchema:is_optional() return true end

function M.nil_val()
  return setmetatable({ _type_name = "nil" }, NilSchema)
end

-- ── any ───────────────────────────────────────────────────────────────────────

local AnySchema = new_schema({ _type_name = "any" })

function AnySchema:_validate(_value, _path)
  return true, {}
end

function AnySchema:_parse(value, _path)
  return true, {}, value
end

function AnySchema:is_optional() return true end

function M.any()
  return setmetatable({ _type_name = "any" }, AnySchema)
end

-- ── array ─────────────────────────────────────────────────────────────────────

local ArraySchema = new_schema({ _type_name = "array" })

function ArraySchema:_validate_inner(value, path)
  local errs = {}
  if type(value) ~= "table" then
    push_error(errs, path, "expected array (table), got " .. type(value))
    return false, errs
  end
  local len = #value
  if self._min ~= nil and len < self._min then
    push_error(errs, path, "too few items (min " .. tostring(self._min) .. ")")
    return false, errs
  end
  if self._max ~= nil and len > self._max then
    push_error(errs, path, "too many items (max " .. tostring(self._max) .. ")")
    return false, errs
  end
  local all_ok = true
  for i = 1, len do
    local elem_path = path ~= "" and (path .. "[" .. i .. "]") or ("[" .. i .. "]")
    local ok, elem_errs = self._item:_validate(value[i], elem_path)
    if not ok then
      all_ok = false
      for j = 1, #elem_errs do errs[#errs + 1] = elem_errs[j] end
    end
  end
  return all_ok, errs
end

function ArraySchema:_validate(value, path)
  if value == nil then
    if self._default ~= nil then return true, {} end
    if self._is_optional then return true, {} end
    local errs = {}; push_error(errs, path, "required"); return false, errs
  end
  return self:_validate_inner(value, path)
end

function ArraySchema:_parse(value, path)
  if value == nil then
    if self._default ~= nil then return true, nil, self._default end
    if self._is_optional then return true, nil, nil end
    local errs = {}; push_error(errs, path, "required"); return false, errs, nil
  end
  local errs = {}
  if type(value) ~= "table" then
    push_error(errs, path, "expected array (table), got " .. type(value))
    return false, errs, nil
  end
  local len = #value
  if self._min ~= nil and len < self._min then
    push_error(errs, path, "too few items (min " .. tostring(self._min) .. ")")
    return false, errs, nil
  end
  if self._max ~= nil and len > self._max then
    push_error(errs, path, "too many items (max " .. tostring(self._max) .. ")")
    return false, errs, nil
  end
  local all_ok = true
  local out = {}
  for i = 1, len do
    local elem_path = path ~= "" and (path .. "[" .. i .. "]") or ("[" .. i .. "]")
    local ok, elem_errs, coerced = self._item:_parse(value[i], elem_path)
    if not ok then
      all_ok = false
      for j = 1, #elem_errs do errs[#errs + 1] = elem_errs[j] end
    else
      out[i] = coerced
    end
  end
  if all_ok then return true, {}, out end
  return false, errs, nil
end

function ArraySchema:min(n)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._min = n
  return s
end

function ArraySchema:max(n)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._max = n
  return s
end

function ArraySchema:nullable()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._is_optional = true
  return s
end

ArraySchema.optional = Schema.nullable

function ArraySchema:default(val)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._default = val
  s._is_optional = true
  return s
end

function M.array(item_schema)
  return setmetatable({ _type_name = "array", _item = item_schema }, ArraySchema)
end

-- ── record ────────────────────────────────────────────────────────────────────

local RecordSchema = new_schema({ _type_name = "record" })

function RecordSchema:_validate_inner(value, path)
  local errs = {}
  if type(value) ~= "table" then
    push_error(errs, path, "expected record (table), got " .. type(value))
    return false, errs
  end
  local all_ok = true
  for field, field_schema in pairs(self._fields) do
    local field_path = path ~= "" and (path .. "." .. field) or field
    local ok, field_errs = field_schema:_validate(value[field], field_path)
    if not ok then
      all_ok = false
      for j = 1, #field_errs do errs[#errs + 1] = field_errs[j] end
    end
  end
  return all_ok, errs
end

function RecordSchema:_validate(value, path)
  if value == nil then
    if self._default ~= nil then return true, {} end
    if self._is_optional then return true, {} end
    local errs = {}; push_error(errs, path, "required"); return false, errs
  end
  return self:_validate_inner(value, path)
end

function RecordSchema:_parse(value, path)
  if value == nil then
    if self._default ~= nil then return true, nil, self._default end
    if self._is_optional then return true, nil, nil end
    local errs = {}; push_error(errs, path, "required"); return false, errs, nil
  end
  local errs = {}
  if type(value) ~= "table" then
    push_error(errs, path, "expected record (table), got " .. type(value))
    return false, errs, nil
  end
  local all_ok = true
  local out = {}
  for field, field_schema in pairs(self._fields) do
    local field_path = path ~= "" and (path .. "." .. field) or field
    local ok, field_errs, coerced = field_schema:_parse(value[field], field_path)
    if not ok then
      all_ok = false
      for j = 1, #field_errs do errs[#errs + 1] = field_errs[j] end
    else
      out[field] = coerced
    end
  end
  if all_ok then return true, {}, out end
  return false, errs, nil
end

function RecordSchema:nullable()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._is_optional = true
  return s
end

RecordSchema.optional = Schema.nullable

function RecordSchema:default(val)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._default = val
  s._is_optional = true
  return s
end

function M.record(fields)
  return setmetatable({ _type_name = "record", _fields = fields }, RecordSchema)
end

-- ── map ───────────────────────────────────────────────────────────────────────

local MapSchema = new_schema({ _type_name = "map" })

function MapSchema:_validate_inner(value, path)
  local errs = {}
  if type(value) ~= "table" then
    push_error(errs, path, "expected map (table), got " .. type(value))
    return false, errs
  end
  local all_ok = true
  for k, v in pairs(value) do
    local key_path = path ~= "" and (path .. "[" .. tostring(k) .. "]") or ("[" .. tostring(k) .. "]")
    local ok_k, errs_k = self._key_schema:_validate(k, key_path .. "<key>")
    if not ok_k then
      all_ok = false
      for j = 1, #errs_k do errs[#errs + 1] = errs_k[j] end
    end
    local ok_v, errs_v = self._val_schema:_validate(v, key_path)
    if not ok_v then
      all_ok = false
      for j = 1, #errs_v do errs[#errs + 1] = errs_v[j] end
    end
  end
  return all_ok, errs
end

function MapSchema:_validate(value, path)
  if value == nil then
    if self._default ~= nil then return true, {} end
    if self._is_optional then return true, {} end
    local errs = {}; push_error(errs, path, "required"); return false, errs
  end
  return self:_validate_inner(value, path)
end

function MapSchema:_parse(value, path)
  if value == nil then
    if self._default ~= nil then return true, nil, self._default end
    if self._is_optional then return true, nil, nil end
    local errs = {}; push_error(errs, path, "required"); return false, errs, nil
  end
  local errs = {}
  if type(value) ~= "table" then
    push_error(errs, path, "expected map (table), got " .. type(value))
    return false, errs, nil
  end
  local all_ok = true
  local out = {}
  for k, v in pairs(value) do
    local key_path = path ~= "" and (path .. "[" .. tostring(k) .. "]") or ("[" .. tostring(k) .. "]")
    local ok_k, errs_k = self._key_schema:_validate(k, key_path .. "<key>")
    if not ok_k then
      all_ok = false
      for j = 1, #errs_k do errs[#errs + 1] = errs_k[j] end
    end
    local ok_v, errs_v, coerced_v = self._val_schema:_parse(v, key_path)
    if not ok_v then
      all_ok = false
      for j = 1, #errs_v do errs[#errs + 1] = errs_v[j] end
    else
      out[k] = coerced_v
    end
  end
  if all_ok then return true, {}, out end
  return false, errs, nil
end

function MapSchema:nullable()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._is_optional = true
  return s
end

MapSchema.optional = Schema.nullable

function MapSchema:default(val)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._default = val
  s._is_optional = true
  return s
end

function M.map(key_schema, val_schema)
  return setmetatable({ _type_name = "map", _key_schema = key_schema, _val_schema = val_schema }, MapSchema)
end

-- ── tuple ─────────────────────────────────────────────────────────────────────

local TupleSchema = new_schema({ _type_name = "tuple" })

function TupleSchema:_validate_inner(value, path)
  local errs = {}
  if type(value) ~= "table" then
    push_error(errs, path, "expected tuple (table), got " .. type(value))
    return false, errs
  end
  local n = #self._schemas
  if #value ~= n then
    push_error(errs, path, "expected " .. n .. " elements, got " .. #value)
    return false, errs
  end
  local all_ok = true
  for i = 1, n do
    local elem_path = path ~= "" and (path .. "[" .. i .. "]") or ("[" .. i .. "]")
    local ok, elem_errs = self._schemas[i]:_validate(value[i], elem_path)
    if not ok then
      all_ok = false
      for j = 1, #elem_errs do errs[#errs + 1] = elem_errs[j] end
    end
  end
  return all_ok, errs
end

function TupleSchema:_validate(value, path)
  if value == nil then
    if self._default ~= nil then return true, {} end
    if self._is_optional then return true, {} end
    local errs = {}; push_error(errs, path, "required"); return false, errs
  end
  return self:_validate_inner(value, path)
end

function TupleSchema:_parse(value, path)
  if value == nil then
    if self._default ~= nil then return true, nil, self._default end
    if self._is_optional then return true, nil, nil end
    local errs = {}; push_error(errs, path, "required"); return false, errs, nil
  end
  local errs = {}
  if type(value) ~= "table" then
    push_error(errs, path, "expected tuple (table), got " .. type(value))
    return false, errs, nil
  end
  local n = #self._schemas
  if #value ~= n then
    push_error(errs, path, "expected " .. n .. " elements, got " .. #value)
    return false, errs, nil
  end
  local all_ok = true
  local out = {}
  for i = 1, n do
    local elem_path = path ~= "" and (path .. "[" .. i .. "]") or ("[" .. i .. "]")
    local ok, elem_errs, coerced = self._schemas[i]:_parse(value[i], elem_path)
    if not ok then
      all_ok = false
      for j = 1, #elem_errs do errs[#errs + 1] = elem_errs[j] end
    else
      out[i] = coerced
    end
  end
  if all_ok then return true, {}, out end
  return false, errs, nil
end

function TupleSchema:nullable()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._is_optional = true
  return s
end

TupleSchema.optional = Schema.nullable

function TupleSchema:default(val)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._default = val
  s._is_optional = true
  return s
end

function M.tuple(...)
  local schemas = { ... }
  return setmetatable({ _type_name = "tuple", _schemas = schemas }, TupleSchema)
end

-- ── union ─────────────────────────────────────────────────────────────────────

local UnionSchema = new_schema({ _type_name = "union" })

function UnionSchema:_validate(value, path)
  if value == nil and self._is_optional then return true, {} end
  for i = 1, #self._schemas do
    local ok = self._schemas[i]:_validate(value, path)
    if ok then return true, {} end
  end
  local errs = {}
  push_error(errs, path, "value does not match any variant")
  return false, errs
end

function UnionSchema:_parse(value, path)
  if value == nil then
    if self._default ~= nil then return true, nil, self._default end
    if self._is_optional then return true, nil, nil end
  end
  for i = 1, #self._schemas do
    local ok, _, coerced = self._schemas[i]:_parse(value, path)
    if ok then return true, {}, coerced end
  end
  local errs = {}
  push_error(errs, path, "value does not match any variant")
  return false, errs, nil
end

function UnionSchema:nullable()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._is_optional = true
  return s
end

UnionSchema.optional = Schema.nullable

function UnionSchema:default(val)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._default = val
  s._is_optional = true
  return s
end

function M.union(...)
  local schemas = { ... }
  return setmetatable({ _type_name = "union", _schemas = schemas }, UnionSchema)
end

-- ── intersection ──────────────────────────────────────────────────────────────

local IntersectionSchema = new_schema({ _type_name = "intersection" })

function IntersectionSchema:_validate(value, path)
  if value == nil and self._is_optional then return true, {} end
  local errs = {}
  local all_ok = true
  for i = 1, #self._schemas do
    local ok, sub_errs = self._schemas[i]:_validate(value, path)
    if not ok then
      all_ok = false
      for j = 1, #sub_errs do errs[#errs + 1] = sub_errs[j] end
    end
  end
  return all_ok, errs
end

function IntersectionSchema:_parse(value, path)
  if value == nil then
    if self._default ~= nil then return true, nil, self._default end
    if self._is_optional then return true, nil, nil end
  end
  local errs = {}
  local all_ok = true
  local coerced = value
  for i = 1, #self._schemas do
    local ok, sub_errs, c = self._schemas[i]:_parse(coerced, path)
    if not ok then
      all_ok = false
      for j = 1, #sub_errs do errs[#errs + 1] = sub_errs[j] end
    else
      coerced = c
    end
  end
  if all_ok then return true, {}, coerced end
  return false, errs, nil
end

function IntersectionSchema:nullable()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._is_optional = true
  return s
end

IntersectionSchema.optional = Schema.nullable

function IntersectionSchema:default(val)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._default = val
  s._is_optional = true
  return s
end

function M.intersection(...)
  local schemas = { ... }
  return setmetatable({ _type_name = "intersection", _schemas = schemas }, IntersectionSchema)
end

-- ── literal ───────────────────────────────────────────────────────────────────

local LiteralSchema = new_schema({ _type_name = "literal" })

function LiteralSchema:_validate(value, path)
  if value == nil and self._is_optional then return true, {} end
  if value ~= self._value then
    local errs = {}
    push_error(errs, path, "expected " .. tostring(self._value) .. ", got " .. tostring(value))
    return false, errs
  end
  return true, {}
end

function LiteralSchema:_parse(value, path)
  if value == nil then
    if self._default ~= nil then return true, nil, self._default end
    if self._is_optional then return true, nil, nil end
  end
  local ok, errs = self:_validate(value, path)
  return ok, errs, value
end

function LiteralSchema:nullable()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._is_optional = true
  return s
end

LiteralSchema.optional = Schema.nullable

function LiteralSchema:default(val)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._default = val
  s._is_optional = true
  return s
end

function M.literal(value)
  return setmetatable({ _type_name = "literal", _value = value }, LiteralSchema)
end

-- ── enum ──────────────────────────────────────────────────────────────────────

local EnumSchema = new_schema({ _type_name = "enum" })

function EnumSchema:_validate(value, path)
  if value == nil and self._is_optional then return true, {} end
  for i = 1, #self._values do
    if self._values[i] == value then return true, {} end
  end
  local errs = {}
  push_error(errs, path, "expected one of: " .. table.concat(self._values, ", ") .. "; got " .. tostring(value))
  return false, errs
end

function EnumSchema:_parse(value, path)
  if value == nil then
    if self._default ~= nil then return true, nil, self._default end
    if self._is_optional then return true, nil, nil end
  end
  local ok, errs = self:_validate(value, path)
  return ok, errs, value
end

function EnumSchema:nullable()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._is_optional = true
  return s
end

EnumSchema.optional = Schema.nullable

function EnumSchema:default(val)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._default = val
  s._is_optional = true
  return s
end

function M.enum(values)
  return setmetatable({ _type_name = "enum", _values = values }, EnumSchema)
end

-- ── not_ ──────────────────────────────────────────────────────────────────────

local NotSchema = new_schema({ _type_name = "not" })

function NotSchema:_validate(value, path)
  if value == nil and self._is_optional then return true, {} end
  local ok = self._inner:_validate(value, path)
  if ok then
    local errs = {}
    push_error(errs, path, "value must not match schema")
    return false, errs
  end
  return true, {}
end

function NotSchema:_parse(value, path)
  if value == nil then
    if self._default ~= nil then return true, nil, self._default end
    if self._is_optional then return true, nil, nil end
  end
  local ok, errs = self:_validate(value, path)
  return ok, errs, value
end

function NotSchema:nullable()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._is_optional = true
  return s
end

NotSchema.optional = Schema.nullable

function NotSchema:default(val)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._default = val
  s._is_optional = true
  return s
end

function M.not_(inner)
  return setmetatable({ _type_name = "not", _inner = inner }, NotSchema)
end

-- ── custom ────────────────────────────────────────────────────────────────────

local CustomSchema = new_schema({ _type_name = "custom" })

-- _fn(value) -> nil (ok) or string (error message)
function CustomSchema:_validate(value, path)
  if value == nil and self._is_optional then return true, {} end
  local msg = self._fn(value)
  if msg then
    local errs = {}
    push_error(errs, path, msg)
    return false, errs
  end
  return true, {}
end

function CustomSchema:_parse(value, path)
  if value == nil then
    if self._default ~= nil then return true, nil, self._default end
    if self._is_optional then return true, nil, nil end
  end
  local ok, errs = self:_validate(value, path)
  return ok, errs, value
end

function CustomSchema:nullable()
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._is_optional = true
  return s
end

CustomSchema.optional = Schema.nullable

function CustomSchema:default(val)
  local s = setmetatable({}, getmetatable(self))
  for k, v in pairs(self) do s[k] = v end
  s._default = val
  s._is_optional = true
  return s
end

function M.custom(fn)
  return setmetatable({ _type_name = "custom", _fn = fn }, CustomSchema)
end

-- ── format_errors ─────────────────────────────────────────────────────────────

function M.format_errors(err)
  if not err then return "" end
  local lines = {}
  lines[#lines + 1] = err.message or "validation failed"
  for _, e in ipairs(err.errors or {}) do
    local path = e.path and e.path ~= "" and e.path or "(root)"
    lines[#lines + 1] = "  " .. path .. ": " .. (e.message or "")
  end
  return table.concat(lines, "\n")
end

return M
