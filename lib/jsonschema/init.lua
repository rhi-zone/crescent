-- lib/jsonschema/init.lua — JSON Schema draft-07 validator
-- Validates Lua values against a JSON Schema table.
-- Note: `pattern` keywords use Lua regex patterns, not ECMA-262 regex.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function is_array(t)
  if type(t) ~= "table" then return false end
  local n = #t
  local count = 0
  for _ in pairs(t) do count = count + 1 end
  return count == n
end

-- JSON null sentinel — callers can use M.null to represent JSON null
M.null = {}

local function is_null(v)
  return v == nil or v == M.null
end

local function lua_type(v)
  if is_null(v) then return "null" end
  local t = type(v)
  if t == "table" then
    if is_array(v) then return "array" else return "object" end
  end
  return t
end

local function matches_type(v, typ)
  local lt = lua_type(v)
  if typ == "integer" then
    return type(v) == "number" and math.floor(v) == v and v ~= math.huge and v ~= -math.huge
  end
  return lt == typ
end

-- Deep equality for uniqueItems check
--: (unknown, unknown) -> boolean
local function deep_eq(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  -- Both tables
  for k, v in pairs(a) do
    if not deep_eq(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

-- ── Core validator ────────────────────────────────────────────────────────────

-- Forward declaration for recursion
local validate_schema

local function add_error(errors, path, message)
  errors[#errors + 1] = { path = path, message = message }
end

--: (path: string, key: unknown) -> string
local function child_path(path, key)
  if type(key) == "number" then
    local n = key --[[:! number]]
    return path .. "/" .. (n - 1)  -- 0-indexed in JSON pointer style
  end
  return path .. "/" .. tostring(key)
end

-- Validate `value` against `schema`. Errors appended to `errors`.
-- Returns true if valid, false if not.
--: (schema: unknown, value: unknown, path: string | nil, errors: unknown, root_schema: unknown) -> boolean
validate_schema = function(schema, value, path, errors, root_schema)
  path = path or ""
  errors = errors or {}
  root_schema = root_schema or schema

  -- boolean schema
  if type(schema) == "boolean" then
    if schema then
      return true
    else
      add_error(errors, path, "schema is false")
      return false
    end
  end

  if type(schema) ~= "table" then
    add_error(errors, path, "invalid schema (not a table or boolean)")
    return false
  end
  local schema_ = schema --[[:! { ["$ref"]: unknown, type: unknown, enum: unknown, const: unknown, minLength: unknown, maxLength: unknown, pattern: unknown, minimum: unknown, maximum: unknown, exclusiveMinimum: unknown, exclusiveMaximum: unknown, multipleOf: unknown, minItems: unknown, maxItems: unknown, uniqueItems: unknown, items: unknown, additionalItems: unknown, minProperties: unknown, maxProperties: unknown, required: unknown, properties: unknown, additionalProperties: unknown, patternProperties: unknown, allOf: unknown, anyOf: unknown, oneOf: unknown, not: unknown, if: unknown, then: unknown, else: unknown, nullable: unknown, ... }]]

  local ok = true
  local ref_field = schema_["$ref"] --[[:! string | nil]]
  local minLength = schema_.minLength --[[:! number | nil]]
  local maxLength = schema_.maxLength --[[:! number | nil]]
  local pattern = schema_.pattern --[[:! string | nil]]
  local minimum = schema_.minimum --[[:! number | nil]]
  local maximum = schema_.maximum --[[:! number | nil]]
  local excMin = schema_.exclusiveMinimum --[[:! number | boolean | nil]]
  local excMax = schema_.exclusiveMaximum --[[:! number | boolean | nil]]
  local multipleOf = schema_.multipleOf --[[:! number | nil]]
  local minItems = schema_.minItems --[[:! number | nil]]
  local maxItems = schema_.maxItems --[[:! number | nil]]
  local item_schemas = schema_.items --[[:! unknown]]
  local additionalItems = schema_.additionalItems --[[:! unknown]]
  local minProperties = schema_.minProperties --[[:! number | nil]]
  local maxProperties = schema_.maxProperties --[[:! number | nil]]
  local required = schema_.required --[[:! { [integer]: unknown } | nil]]
  local allOf = schema_.allOf --[[:! { [integer]: unknown } | nil]]
  local anyOf = schema_.anyOf --[[:! { [integer]: unknown } | nil]]
  local oneOf = schema_.oneOf --[[:! { [integer]: unknown } | nil]]

  -- ── $ref ──────────────────────────────────────────────────────────────────
  if ref_field then
    local ref = ref_field
    local def_name = ref:match("^#/definitions/(.+)$")
    local root = root_schema --[[:! { [string]: unknown, ... }]]
    local root_defs = root["definitions"]
    if def_name and root_defs and type(root_defs) == "table" then
      local defs = root_defs --[[:! { [string]: unknown, ... }]]
      local def = defs[def_name]
      if def then
        local sub_ok = validate_schema(def, value, path, errors, root_schema)
        if not sub_ok then ok = false end
      else
        add_error(errors, path, "unresolved $ref: " .. ref)
        ok = false
      end
    else
      add_error(errors, path, "unresolved $ref: " .. ref)
      ok = false
    end
    -- $ref replaces all other keywords in draft-07
    return ok
  end

  -- ── type ──────────────────────────────────────────────────────────────────
  if schema_.type ~= nil then
    local types = schema_.type
    if type(types) == "string" then types = { types --[[:! string]] } end
    local types_ = types --[[:! { [integer]: string }]]
    local type_ok = false
    for i = 1, #types_ do
      if matches_type(value, types_[i]) then
        type_ok = true
        break
      end
    end
    if not type_ok then
      local allowed = table.concat(types_, ", ")
      add_error(errors, path, "expected type " .. allowed .. ", got " .. lua_type(value))
      ok = false
    end
  end

  -- ── enum ──────────────────────────────────────────────────────────────────
  local enum = schema_.enum --[[:! { [integer]: unknown } | nil]]
  if enum ~= nil then
    local found = false
    for i = 1, #enum do
      if deep_eq(value, enum[i]) then
        found = true
        break
      end
    end
    if not found then
      add_error(errors, path, "value not in enum")
      ok = false
    end
  end

  -- ── const ─────────────────────────────────────────────────────────────────
  local const = schema_["const"]
  if const ~= nil then
    if not deep_eq(value, const) then
      add_error(errors, path, "value does not match const")
      ok = false
    end
  end

  -- ── String keywords ───────────────────────────────────────────────────────
  if type(value) == "string" then
    if minLength ~= nil and #value < minLength then
      add_error(errors, path, "string length " .. #value .. " is less than minLength " .. minLength)
      ok = false
    end
    if maxLength ~= nil and #value > maxLength then
      add_error(errors, path, "string length " .. #value .. " is greater than maxLength " .. maxLength)
      ok = false
    end
    if pattern ~= nil then
      if not value:find(pattern) then
        add_error(errors, path, "string does not match pattern '" .. pattern .. "'")
        ok = false
      end
    end
    if schema_.format ~= nil then
      -- format is advisory in draft-07; we silently ignore unknown formats
    end
  end

  -- ── Number/integer keywords ───────────────────────────────────────────────
  if type(value) == "number" then
    if minimum ~= nil and value < minimum then
      add_error(errors, path, "value " .. value .. " is less than minimum " .. minimum)
      ok = false
    end
    if maximum ~= nil and value > maximum then
      add_error(errors, path, "value " .. value .. " is greater than maximum " .. maximum)
      ok = false
    end
    if excMin ~= nil then
      -- draft-07: exclusiveMinimum is a number
      if type(excMin) == "number" then
        local excMin_ = excMin --[[:! number]]
        if value <= excMin_ then
          add_error(errors, path, "value " .. value .. " must be greater than exclusiveMinimum " .. excMin_)
          ok = false
        end
      end
    end
    if excMax ~= nil then
      if type(excMax) == "number" then
        local excMax_ = excMax --[[:! number]]
        if value >= excMax_ then
          add_error(errors, path, "value " .. value .. " must be less than exclusiveMaximum " .. excMax_)
          ok = false
        end
      end
    end
    if multipleOf ~= nil then
      local m = multipleOf
      -- Use modulo with tolerance for floating point
      local remainder = value % m
      -- remainder should be ~0 or ~m
      local tol = 1e-10
      if remainder > tol and (m - remainder) > tol then
        add_error(errors, path, "value " .. value .. " is not a multiple of " .. m)
        ok = false
      end
    end
  end

  -- ── Array keywords ────────────────────────────────────────────────────────
  if type(value) == "table" and is_array(value) then
    local n = #value

    if minItems ~= nil and n < minItems then
      add_error(errors, path, "array has " .. n .. " items, minimum is " .. minItems)
      ok = false
    end
    if maxItems ~= nil and n > maxItems then
      add_error(errors, path, "array has " .. n .. " items, maximum is " .. maxItems)
      ok = false
    end

    if schema_.uniqueItems then
      for i = 1, n do
        for j = i + 1, n do
          if deep_eq(value[i], value[j]) then
            add_error(errors, path, "array items are not unique (indices " .. (i-1) .. " and " .. (j-1) .. ")")
            ok = false
            break
          end
        end
      end
    end

    if item_schemas ~= nil then
      if type(item_schemas) == "table" and is_array(item_schemas) then
        -- Tuple validation
        local item_schemas_ = item_schemas --[[:! { [integer]: unknown }]]
        for i = 1, math.min(n, #item_schemas_) do
          local sub_ok = validate_schema(item_schemas_[i], value[i], child_path(path, i), errors, root_schema)
          if not sub_ok then ok = false end
        end
        -- additionalItems applies to items beyond the tuple length
        if n > #item_schemas_ then
          local ai = additionalItems
          if ai == false then
            add_error(errors, path, "additional items not allowed (got " .. n .. " items, tuple has " .. #item_schemas_ .. ")")
            ok = false
          elseif type(ai) == "table" then
            for i = #item_schemas_ + 1, n do
              local sub_ok = validate_schema(ai, value[i], child_path(path, i), errors, root_schema)
              if not sub_ok then ok = false end
            end
          end
        end
      else
        -- Single schema for all items
        for i = 1, n do
          local sub_ok = validate_schema(item_schemas, value[i], child_path(path, i), errors, root_schema)
          if not sub_ok then ok = false end
        end
      end
    end

    if schema_.contains ~= nil then
      local found = false
      for i = 1, n do
        local sub_errors = {}
        if validate_schema(schema_.contains, value[i], child_path(path, i), sub_errors, root_schema) then
          found = true
          break
        end
      end
      if not found then
        add_error(errors, path, "array does not contain a matching item")
        ok = false
      end
    end
  end

  -- ── Object keywords ───────────────────────────────────────────────────────
  if type(value) == "table" and not is_array(value) then
    -- Count properties
    local prop_count = 0
    for _ in pairs(value) do prop_count = prop_count + 1 end

    if minProperties ~= nil and prop_count < minProperties then
      add_error(errors, path, "object has " .. prop_count .. " properties, minimum is " .. minProperties)
      ok = false
    end
    if maxProperties ~= nil and prop_count > maxProperties then
      add_error(errors, path, "object has " .. prop_count .. " properties, maximum is " .. maxProperties)
      ok = false
    end

    if required ~= nil then
      for i = 1, #required do
        local key = required[i] --[[:! string]]
        if value[key] == nil then
          add_error(errors, child_path(path, key), "required property '" .. key .. "' is missing")
          ok = false
        end
      end
    end

    -- Track which keys are covered by `properties` or `patternProperties`
    local covered = {}

    if schema_.properties ~= nil then
      for key, prop_schema in pairs(schema_.properties) do
        if value[key] ~= nil then
          covered[key] = true
          local sub_ok = validate_schema(prop_schema, value[key], child_path(path, key), errors, root_schema)
          if not sub_ok then ok = false end
        end
      end
    end

    if schema_.patternProperties ~= nil then
      for pattern, prop_schema in pairs(schema_.patternProperties) do
        for key, val in pairs(value) do
          if type(key) == "string" and key:find(pattern) then
            covered[key] = true
            local sub_ok = validate_schema(prop_schema, val, child_path(path, key), errors, root_schema)
            if not sub_ok then ok = false end
          end
        end
      end
    end

    if schema_.additionalProperties ~= nil then
      local ap = schema_.additionalProperties
      for key in pairs(value) do
        if not covered[key] then
          if ap == false then
            add_error(errors, child_path(path, key), "additional property '" .. tostring(key) .. "' is not allowed")
            ok = false
          elseif type(ap) == "table" then
            local sub_ok = validate_schema(ap, value[key], child_path(path, key), errors, root_schema)
            if not sub_ok then ok = false end
          end
        end
      end
    end

    if schema_.propertyNames ~= nil then
      for key in pairs(value) do
        if type(key) == "string" then
          local sub_ok = validate_schema(schema_.propertyNames, key, child_path(path, key), errors, root_schema)
          if not sub_ok then ok = false end
        end
      end
    end

    if schema_.dependencies ~= nil then
      for key, dep in pairs(schema_.dependencies) do
        local key_str = tostring(key)
        if value[key] ~= nil then
          if type(dep) == "table" and is_array(dep) then
            -- Array of required keys
            for i = 1, #dep do
              local dep_key = dep[i]
              if value[dep_key] == nil then
                add_error(errors, path, "property '" .. tostring(dep_key) .. "' is required when '" .. key_str .. "' is present")
                ok = false
              end
            end
          elseif type(dep) == "table" then
            -- Schema dependency
            local sub_ok = validate_schema(dep, value, path, errors, root_schema)
            if not sub_ok then ok = false end
          end
        end
      end
    end
  end

  -- ── Composition keywords ──────────────────────────────────────────────────
  if allOf ~= nil then
    for i = 1, #allOf do
      local sub_ok = validate_schema(allOf[i], value, path, errors, root_schema)
      if not sub_ok then ok = false end
    end
  end

  if anyOf ~= nil then
    local any_ok = false
    local any_errors = {}
    for i = 1, #anyOf do
      local sub_errs = {}
      if validate_schema(anyOf[i], value, path, sub_errs, root_schema) then
        any_ok = true
        break
      end
      for j = 1, #sub_errs do
        any_errors[#any_errors + 1] = sub_errs[j]
      end
    end
    if not any_ok then
      add_error(errors, path, "value does not match any of the anyOf schemas")
      for i = 1, #any_errors do
        errors[#errors + 1] = any_errors[i]
      end
      ok = false
    end
  end

  if oneOf ~= nil then
    local match_count = 0 --: integer
    local one_errors = {}
    for i = 1, #oneOf do
      local sub_errs = {}
      if validate_schema(oneOf[i], value, path, sub_errs, root_schema) then
        match_count = match_count + 1
      else
        for j = 1, #sub_errs do
          one_errors[#one_errors + 1] = sub_errs[j]
        end
      end
    end
    if match_count ~= 1 then
      if match_count == 0 then
        add_error(errors, path, "value matches none of the oneOf schemas (expected exactly one)")
        for i = 1, #one_errors do
          errors[#errors + 1] = one_errors[i]
        end
      else
        add_error(errors, path, "value matches " .. match_count .. " of the oneOf schemas (expected exactly one)")
      end
      ok = false
    end
  end

  if schema_["not"] ~= nil then
    local sub_errs = {}
    if validate_schema(schema_["not"], value, path, sub_errs, root_schema) then
      add_error(errors, path, "value must not match the 'not' schema")
      ok = false
    end
  end

  -- ── Conditional keywords ──────────────────────────────────────────────────
  if schema_["if"] ~= nil then
    local sub_errs = {}
    local cond_ok = validate_schema(schema_["if"], value, path, sub_errs, root_schema)
    if cond_ok then
      if schema_["then"] ~= nil then
        local sub_ok = validate_schema(schema_["then"], value, path, errors, root_schema)
        if not sub_ok then ok = false end
      end
    else
      if schema_["else"] ~= nil then
        local sub_ok = validate_schema(schema_["else"], value, path, errors, root_schema)
        if not sub_ok then ok = false end
      end
    end
  end

  return ok
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Validate a Lua value against a JSON Schema.
--- Returns: true on success; nil, errors on failure.
--: (schema: unknown, value: unknown) -> boolean | (nil, unknown)
function M.validate(schema, value)
  local errors = {}
  local ok = validate_schema(schema, value, "", errors, schema)
  if ok then
    return true
  end
  return nil, errors
end

--- Compile a schema for repeated use.
--- Returns a validator function: fn(value) -> boolean OR (nil, errors)
--: (schema: unknown) -> (value: unknown) -> boolean | (nil, unknown)
function M.compile(schema)
  return function(value)
    return M.validate(schema, value)
  end
end

--- Check if a value satisfies a schema (returns boolean only).
--: (schema: unknown, value: unknown) -> boolean
function M.is_valid(schema, value)
  local errors = {}
  return validate_schema(schema, value, "", errors, schema)
end

return M
