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

local function child_path(path, key)
  if type(key) == "number" then
    return path .. "/" .. (key - 1)  -- 0-indexed in JSON pointer style
  end
  return path .. "/" .. tostring(key)
end

-- Validate `value` against `schema`. Errors appended to `errors`.
-- Returns true if valid, false if not.
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

  local ok = true

  -- ── $ref ──────────────────────────────────────────────────────────────────
  if schema["$ref"] then
    local ref = schema["$ref"]
    local def_name = ref:match("^#/definitions/(.+)$")
    if def_name and root_schema.definitions and root_schema.definitions[def_name] then
      local sub_ok = validate_schema(root_schema.definitions[def_name], value, path, errors, root_schema)
      if not sub_ok then ok = false end
    else
      add_error(errors, path, "unresolved $ref: " .. ref)
      ok = false
    end
    -- $ref replaces all other keywords in draft-07
    return ok
  end

  -- ── type ──────────────────────────────────────────────────────────────────
  if schema.type ~= nil then
    local types = schema.type
    if type(types) == "string" then types = { types } end
    local type_ok = false
    for i = 1, #types do
      if matches_type(value, types[i]) then
        type_ok = true
        break
      end
    end
    if not type_ok then
      local allowed = table.concat(types, ", ")
      add_error(errors, path, "expected type " .. allowed .. ", got " .. lua_type(value))
      ok = false
    end
  end

  -- ── enum ──────────────────────────────────────────────────────────────────
  if schema.enum ~= nil then
    local found = false
    for i = 1, #schema.enum do
      if deep_eq(value, schema.enum[i]) then
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
  if schema["const"] ~= nil then
    if not deep_eq(value, schema["const"]) then
      add_error(errors, path, "value does not match const")
      ok = false
    end
  end

  -- ── String keywords ───────────────────────────────────────────────────────
  if type(value) == "string" then
    if schema.minLength ~= nil and #value < schema.minLength then
      add_error(errors, path, "string length " .. #value .. " is less than minLength " .. schema.minLength)
      ok = false
    end
    if schema.maxLength ~= nil and #value > schema.maxLength then
      add_error(errors, path, "string length " .. #value .. " is greater than maxLength " .. schema.maxLength)
      ok = false
    end
    if schema.pattern ~= nil then
      if not value:find(schema.pattern) then
        add_error(errors, path, "string does not match pattern '" .. schema.pattern .. "'")
        ok = false
      end
    end
    if schema.format ~= nil then
      -- format is advisory in draft-07; we silently ignore unknown formats
    end
  end

  -- ── Number/integer keywords ───────────────────────────────────────────────
  if type(value) == "number" then
    if schema.minimum ~= nil and value < schema.minimum then
      add_error(errors, path, "value " .. value .. " is less than minimum " .. schema.minimum)
      ok = false
    end
    if schema.maximum ~= nil and value > schema.maximum then
      add_error(errors, path, "value " .. value .. " is greater than maximum " .. schema.maximum)
      ok = false
    end
    if schema.exclusiveMinimum ~= nil then
      -- draft-07: exclusiveMinimum is a number
      if type(schema.exclusiveMinimum) == "number" then
        if value <= schema.exclusiveMinimum then
          add_error(errors, path, "value " .. value .. " must be greater than exclusiveMinimum " .. schema.exclusiveMinimum)
          ok = false
        end
      end
    end
    if schema.exclusiveMaximum ~= nil then
      if type(schema.exclusiveMaximum) == "number" then
        if value >= schema.exclusiveMaximum then
          add_error(errors, path, "value " .. value .. " must be less than exclusiveMaximum " .. schema.exclusiveMaximum)
          ok = false
        end
      end
    end
    if schema.multipleOf ~= nil then
      local m = schema.multipleOf
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

    if schema.minItems ~= nil and n < schema.minItems then
      add_error(errors, path, "array has " .. n .. " items, minimum is " .. schema.minItems)
      ok = false
    end
    if schema.maxItems ~= nil and n > schema.maxItems then
      add_error(errors, path, "array has " .. n .. " items, maximum is " .. schema.maxItems)
      ok = false
    end

    if schema.uniqueItems then
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

    if schema.items ~= nil then
      if type(schema.items) == "table" and is_array(schema.items) then
        -- Tuple validation
        local item_schemas = schema.items
        for i = 1, math.min(n, #item_schemas) do
          local sub_ok = validate_schema(item_schemas[i], value[i], child_path(path, i), errors, root_schema)
          if not sub_ok then ok = false end
        end
        -- additionalItems applies to items beyond the tuple length
        if n > #item_schemas then
          local ai = schema.additionalItems
          if ai == false then
            add_error(errors, path, "additional items not allowed (got " .. n .. " items, tuple has " .. #item_schemas .. ")")
            ok = false
          elseif type(ai) == "table" then
            for i = #item_schemas + 1, n do
              local sub_ok = validate_schema(ai, value[i], child_path(path, i), errors, root_schema)
              if not sub_ok then ok = false end
            end
          end
        end
      else
        -- Single schema for all items
        for i = 1, n do
          local sub_ok = validate_schema(schema.items, value[i], child_path(path, i), errors, root_schema)
          if not sub_ok then ok = false end
        end
      end
    end

    if schema.contains ~= nil then
      local found = false
      for i = 1, n do
        local sub_errors = {}
        if validate_schema(schema.contains, value[i], child_path(path, i), sub_errors, root_schema) then
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

    if schema.minProperties ~= nil and prop_count < schema.minProperties then
      add_error(errors, path, "object has " .. prop_count .. " properties, minimum is " .. schema.minProperties)
      ok = false
    end
    if schema.maxProperties ~= nil and prop_count > schema.maxProperties then
      add_error(errors, path, "object has " .. prop_count .. " properties, maximum is " .. schema.maxProperties)
      ok = false
    end

    if schema.required ~= nil then
      for i = 1, #schema.required do
        local key = schema.required[i]
        if value[key] == nil then
          add_error(errors, child_path(path, key), "required property '" .. key .. "' is missing")
          ok = false
        end
      end
    end

    -- Track which keys are covered by `properties` or `patternProperties`
    local covered = {}

    if schema.properties ~= nil then
      for key, prop_schema in pairs(schema.properties) do
        if value[key] ~= nil then
          covered[key] = true
          local sub_ok = validate_schema(prop_schema, value[key], child_path(path, key), errors, root_schema)
          if not sub_ok then ok = false end
        end
      end
    end

    if schema.patternProperties ~= nil then
      for pattern, prop_schema in pairs(schema.patternProperties) do
        for key, val in pairs(value) do
          if type(key) == "string" and key:find(pattern) then
            covered[key] = true
            local sub_ok = validate_schema(prop_schema, val, child_path(path, key), errors, root_schema)
            if not sub_ok then ok = false end
          end
        end
      end
    end

    if schema.additionalProperties ~= nil then
      local ap = schema.additionalProperties
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

    if schema.propertyNames ~= nil then
      for key in pairs(value) do
        if type(key) == "string" then
          local sub_ok = validate_schema(schema.propertyNames, key, child_path(path, key), errors, root_schema)
          if not sub_ok then ok = false end
        end
      end
    end

    if schema.dependencies ~= nil then
      for key, dep in pairs(schema.dependencies) do
        if value[key] ~= nil then
          if type(dep) == "table" and is_array(dep) then
            -- Array of required keys
            for i = 1, #dep do
              if value[dep[i]] == nil then
                add_error(errors, path, "property '" .. dep[i] .. "' is required when '" .. key .. "' is present")
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
  if schema.allOf ~= nil then
    for i = 1, #schema.allOf do
      local sub_ok = validate_schema(schema.allOf[i], value, path, errors, root_schema)
      if not sub_ok then ok = false end
    end
  end

  if schema.anyOf ~= nil then
    local any_ok = false
    local any_errors = {}
    for i = 1, #schema.anyOf do
      local sub_errs = {}
      if validate_schema(schema.anyOf[i], value, path, sub_errs, root_schema) then
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

  if schema.oneOf ~= nil then
    local match_count = 0
    local one_errors = {}
    for i = 1, #schema.oneOf do
      local sub_errs = {}
      if validate_schema(schema.oneOf[i], value, path, sub_errs, root_schema) then
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

  if schema["not"] ~= nil then
    local sub_errs = {}
    if validate_schema(schema["not"], value, path, sub_errs, root_schema) then
      add_error(errors, path, "value must not match the 'not' schema")
      ok = false
    end
  end

  -- ── Conditional keywords ──────────────────────────────────────────────────
  if schema["if"] ~= nil then
    local sub_errs = {}
    local cond_ok = validate_schema(schema["if"], value, path, sub_errs, root_schema)
    if cond_ok then
      if schema["then"] ~= nil then
        local sub_ok = validate_schema(schema["then"], value, path, errors, root_schema)
        if not sub_ok then ok = false end
      end
    else
      if schema["else"] ~= nil then
        local sub_ok = validate_schema(schema["else"], value, path, errors, root_schema)
        if not sub_ok then ok = false end
      end
    end
  end

  return ok
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Validate a Lua value against a JSON Schema.
--- Returns: true, nil on success; nil, errors on failure.
--: (schema: unknown, value: unknown) -> true | (nil, unknown)
function M.validate(schema, value)
  local errors = {}
  local ok = validate_schema(schema, value, "", errors, schema)
  if ok then
    return true
  end
  return nil, errors
end

--- Compile a schema for repeated use.
--- Returns a validator function: fn(value) -> true OR (nil, errors)
--: (schema: unknown) -> (value: unknown) -> true | (nil, unknown)
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
