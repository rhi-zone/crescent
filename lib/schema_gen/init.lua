if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- JSON Schema inference, generation, and validation.
-- M.infer(data)              -> schema
-- M.infer_many(samples)      -> schema
-- M.generate(schema)         -> value
-- M.generate_many(schema, n) -> array of values
-- M.generate_random(schema)  -> value (randomized)
-- M.validate(schema, data)   -> true | (false, errmsg)
-- DSL: M.string/number/integer/boolean/null/array/object/enum/one_of/any_of/all_of/nullable/ref

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function is_integer(v)
  return type(v) == "number" and math.floor(v) == v and v == v
end

-- Merge two type strings into a oneOf list (deduplicating).
-- Returns either a single schema or {oneOf = {...}}.
local function merge_schemas(a, b)
  if a == nil then return b end
  if b == nil then return a end
  -- Structural equality: same type string schemas
  if a.type and b.type and a.type == b.type and not next(a, next(a)) and not next(b, next(b)) then
    -- both are single-key {type=X} schemas — identical
    return a
  end
  -- Collect oneOf members from both sides
  local seen = {}
  local members = {}
  local function add_members(s)
    if s.oneOf then
      for _, m in ipairs(s.oneOf) do add_members(m) end
    else
      -- Use type as dedup key (simple heuristic for primitive schemas)
      local key = s.type or tostring(s)
      if not seen[key] then
        seen[key] = true
        members[#members + 1] = s
      end
    end
  end
  add_members(a)
  add_members(b)
  if #members == 1 then return members[1] end
  return { oneOf = members }
end

-- ---------------------------------------------------------------------------
-- Infer
-- ---------------------------------------------------------------------------

--- Infer a JSON Schema from a single Lua value.
-- nil      -> {type="null"}
-- boolean  -> {type="boolean"}
-- integer  -> {type="integer"}
-- number   -> {type="number"}
-- string   -> {type="string"}
-- table (array) -> {type="array", items=...}
-- table (object) -> {type="object", properties=..., required=...}
function M.infer(data)
  local t = type(data)
  if data == nil then
    return { type = "null" }
  elseif t == "boolean" then
    return { type = "boolean" }
  elseif t == "number" then
    if is_integer(data) then
      return { type = "integer" }
    else
      return { type = "number" }
    end
  elseif t == "string" then
    return { type = "string" }
  elseif t == "table" then
    -- Determine array vs object: array has only consecutive integer keys from 1
    local n = #data
    local is_array = true
    local count = 0
    for k, _ in pairs(data) do
      count = count + 1
      if type(k) ~= "number" or k ~= math.floor(k) or k < 1 or k > n then
        is_array = false
        break
      end
    end
    if count == 0 then
      -- empty table — treat as empty object (no properties, no required)
      return { type = "object", properties = {}, required = {} }
    end
    if is_array then
      -- infer items schema by merging all element schemas
      local items_schema = nil
      for i = 1, n do
        local elem_schema = M.infer(data[i])
        items_schema = merge_schemas(items_schema, elem_schema)
      end
      return { type = "array", items = items_schema or { type = "null" } }
    else
      -- object
      local properties = {}
      local required = {}
      for k, v in pairs(data) do
        if type(k) == "string" then
          properties[k] = M.infer(v)
          required[#required + 1] = k
        end
      end
      -- sort required for determinism
      table.sort(required)
      return { type = "object", properties = properties, required = required }
    end
  else
    -- functions, userdata, etc. — not JSON-representable
    return { type = "null" }
  end
end

--- Infer a schema that covers all samples in the array.
-- Keys present in all object samples → required
-- Keys present in some but not all   → not required
function M.infer_many(samples)
  if #samples == 0 then return { type = "null" } end
  if #samples == 1 then return M.infer(samples[1]) end

  -- Collect per-sample schemas
  local schemas = {}
  for i, s in ipairs(samples) do schemas[i] = M.infer(s) end

  -- Check if all are the same type
  local first_type = schemas[1].type
  local all_same_type = true
  for i = 2, #schemas do
    if schemas[i].type ~= first_type then
      all_same_type = false
      break
    end
  end

  if not all_same_type then
    -- Different types: build oneOf
    local merged = schemas[1]
    for i = 2, #schemas do
      merged = merge_schemas(merged, schemas[i])
    end
    return merged
  end

  -- All same type
  if first_type == "object" then
    -- Merge properties; required = intersection (keys present in ALL samples)
    local all_props = {}      -- key -> merged schema
    local key_count = {}      -- key -> how many samples have it
    local total = #schemas

    for _, s in ipairs(schemas) do
      for k, v in pairs(s.properties) do
        if all_props[k] then
          all_props[k] = merge_schemas(all_props[k], v)
        else
          all_props[k] = v
        end
        key_count[k] = (key_count[k] or 0) + 1
      end
    end

    local required = {}
    for k, cnt in pairs(key_count) do
      if cnt == total then
        required[#required + 1] = k
      end
    end
    table.sort(required)

    return { type = "object", properties = all_props, required = required }
  elseif first_type == "array" then
    -- Merge item schemas
    local items_schema = schemas[1].items
    for i = 2, #schemas do
      items_schema = merge_schemas(items_schema, schemas[i].items)
    end
    return { type = "array", items = items_schema }
  else
    -- primitives: all same type, return first schema
    return schemas[1]
  end
end

-- ---------------------------------------------------------------------------
-- Generate
-- ---------------------------------------------------------------------------

-- Deterministic defaults per type
local DEFAULTS = {
  integer = 42,
  number  = 3.14,
  string  = "example",
  boolean = true,
  null    = nil,  -- special-cased below
}

--- Generate a deterministic example value from a schema.
function M.generate(schema)
  if not schema then return nil end

  -- $ref — not resolvable without a registry; return nil
  if schema["$ref"] then return nil end

  -- enum — first value
  if schema["enum"] then
    return schema["enum"][1]
  end

  -- oneOf / anyOf — first matching branch
  if schema.oneOf then return M.generate(schema.oneOf[1]) end
  if schema.anyOf then return M.generate(schema.anyOf[1]) end

  -- allOf — try to merge (simplistic: just generate from first)
  if schema.allOf then return M.generate(schema.allOf[1]) end

  local t = schema.type
  if t == "null" then
    return nil
  elseif t == "boolean" then
    return true
  elseif t == "integer" then
    local v = schema.minimum or 42
    if schema.maximum and v > schema.maximum then v = schema.maximum end
    return v
  elseif t == "number" then
    local v = schema.minimum or 3.14
    if schema.maximum and v > schema.maximum then v = schema.maximum end
    return v
  elseif t == "string" then
    if schema.minLength then
      local base = "abcdefghijklmnopqrstuvwxyz"
      local s = ""
      while #s < schema.minLength do s = s .. base end
      s = s:sub(1, schema.minLength)
      if schema.maxLength then s = s:sub(1, schema.maxLength) end
      return s
    end
    local s = "example"
    if schema.maxLength then s = s:sub(1, schema.maxLength) end
    return s
  elseif t == "array" then
    local min = schema.minItems or 0
    local max = schema.maxItems
    local count = math.max(1, min)  -- at least 1 item for a useful example
    if max then count = math.min(count, max) end
    local result = {}
    for i = 1, count do
      result[i] = M.generate(schema.items or {})
    end
    return result
  elseif t == "object" then
    local result = {}
    local props = schema.properties or {}
    local req_set = {}
    if schema.required then
      for _, k in ipairs(schema.required) do req_set[k] = true end
    end
    for k, sub in pairs(props) do
      if req_set[k] or not schema.required then
        result[k] = M.generate(sub)
      end
    end
    return result
  end
  return nil
end

--- Generate n distinct examples (deterministic: all return same value in pure mode).
function M.generate_many(schema, n)
  local results = {}
  for i = 1, n do results[i] = M.generate(schema) end
  return results
end

--- Generate a randomized example value from a schema.
function M.generate_random(schema)
  if not schema then return nil end
  if schema["enum"] then
    local i = math.random(1, #schema["enum"])
    return schema["enum"][i]
  end
  if schema.oneOf then return M.generate_random(schema.oneOf[math.random(1, #schema.oneOf)]) end
  if schema.anyOf then return M.generate_random(schema.anyOf[math.random(1, #schema.anyOf)]) end
  if schema.allOf then return M.generate_random(schema.allOf[1]) end

  local t = schema.type
  if t == "null" then
    return nil
  elseif t == "boolean" then
    return math.random() > 0.5
  elseif t == "integer" then
    local lo = schema.minimum or 0
    local hi = schema.maximum or 100
    return math.random(lo, hi)
  elseif t == "number" then
    local lo = schema.minimum or 0
    local hi = schema.maximum or 100
    return lo + math.random() * (hi - lo)
  elseif t == "string" then
    local chars = "abcdefghijklmnopqrstuvwxyz"
    local min = schema.minLength or 3
    local max = schema.maxLength or 10
    local len = min + math.random(0, max - min)
    local s = {}
    for i = 1, len do s[i] = chars:sub(math.random(1, #chars), math.random(1, #chars)) end
    return table.concat(s)
  elseif t == "array" then
    local min = schema.minItems or 0
    local max = schema.maxItems or 5
    local count = min + math.random(0, max - min)
    local result = {}
    for i = 1, count do result[i] = M.generate_random(schema.items or {}) end
    return result
  elseif t == "object" then
    local result = {}
    local props = schema.properties or {}
    local req_set = {}
    if schema.required then
      for _, k in ipairs(schema.required) do req_set[k] = true end
    end
    for k, sub in pairs(props) do
      if req_set[k] or math.random() > 0.5 then
        result[k] = M.generate_random(sub)
      end
    end
    return result
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Validate
-- ---------------------------------------------------------------------------

--- Validate data against a JSON Schema.
-- Returns true on success, or (false, errmsg) on failure.
function M.validate(schema, data)
  if not schema then return true end

  -- $ref — not resolvable without registry; skip
  if schema["$ref"] then return true end

  -- enum
  if schema["enum"] then
    for _, v in ipairs(schema["enum"]) do
      if data == v then return true end
    end
    return false, "value not in enum"
  end

  -- oneOf: exactly one must match (we treat as "at least one" for simplicity)
  if schema.oneOf then
    local matched = 0
    for _, sub in ipairs(schema.oneOf) do
      local ok = M.validate(sub, data)
      if ok then matched = matched + 1 end
    end
    if matched == 0 then
      return false, "value does not match any oneOf schema"
    end
    return true
  end

  -- anyOf: at least one must match
  if schema.anyOf then
    for _, sub in ipairs(schema.anyOf) do
      local ok = M.validate(sub, data)
      if ok then return true end
    end
    return false, "value does not match any anyOf schema"
  end

  -- allOf: all must match
  if schema.allOf then
    for _, sub in ipairs(schema.allOf) do
      local ok, err = M.validate(sub, data)
      if not ok then return false, "allOf: " .. (err or "mismatch") end
    end
    return true
  end

  local t = schema.type
  if not t then return true end  -- no type constraint

  -- type check
  if t == "null" then
    if data ~= nil then
      return false, "expected null, got " .. type(data)
    end
    return true
  elseif t == "boolean" then
    if type(data) ~= "boolean" then
      return false, "expected boolean, got " .. type(data)
    end
    return true
  elseif t == "integer" then
    if type(data) ~= "number" or not is_integer(data) then
      return false, "expected integer, got " .. type(data) .. (type(data)=="number" and " (non-integer)" or "")
    end
  elseif t == "number" then
    if type(data) ~= "number" then
      return false, "expected number, got " .. type(data)
    end
  elseif t == "string" then
    if type(data) ~= "string" then
      return false, "expected string, got " .. type(data)
    end
  elseif t == "array" then
    if type(data) ~= "table" then
      return false, "expected array, got " .. type(data)
    end
    -- check it's sequence-like
    local n = #data
    if schema.minItems and n < schema.minItems then
      return false, "array has " .. n .. " items, minimum is " .. schema.minItems
    end
    if schema.maxItems and n > schema.maxItems then
      return false, "array has " .. n .. " items, maximum is " .. schema.maxItems
    end
    if schema.items then
      for i = 1, n do
        local ok, err = M.validate(schema.items, data[i])
        if not ok then
          return false, "array[" .. i .. "]: " .. (err or "invalid")
        end
      end
    end
    return true
  elseif t == "object" then
    if type(data) ~= "table" then
      return false, "expected object, got " .. type(data)
    end
    -- required fields
    if schema.required then
      for _, k in ipairs(schema.required) do
        if data[k] == nil then
          return false, "missing required field: " .. k
        end
      end
    end
    -- properties
    if schema.properties then
      for k, sub in pairs(schema.properties) do
        if data[k] ~= nil then
          local ok, err = M.validate(sub, data[k])
          if not ok then
            return false, "property '" .. k .. "': " .. (err or "invalid")
          end
        end
      end
    end
    return true
  end

  -- number/string constraints (after type check passed)
  if t == "number" or t == "integer" then
    if schema.minimum and data < schema.minimum then
      return false, "value " .. data .. " is less than minimum " .. schema.minimum
    end
    if schema.maximum and data > schema.maximum then
      return false, "value " .. data .. " is greater than maximum " .. schema.maximum
    end
  end
  if t == "string" then
    if schema.minLength and #data < schema.minLength then
      return false, "string length " .. #data .. " is less than minLength " .. schema.minLength
    end
    if schema.maxLength and #data > schema.maxLength then
      return false, "string length " .. #data .. " is greater than maxLength " .. schema.maxLength
    end
  end

  return true
end

-- ---------------------------------------------------------------------------
-- Schema DSL helpers
-- ---------------------------------------------------------------------------

--- Build a string schema.
function M.string(opts)
  local s = { type = "string" }
  if opts then for k, v in pairs(opts) do s[k] = v end end
  return s
end

--- Build a number schema.
function M.number(opts)
  local s = { type = "number" }
  if opts then for k, v in pairs(opts) do s[k] = v end end
  return s
end

--- Build an integer schema.
function M.integer(opts)
  local s = { type = "integer" }
  if opts then for k, v in pairs(opts) do s[k] = v end end
  return s
end

--- Build a boolean schema.
function M.boolean()
  return { type = "boolean" }
end

--- Build a null schema.
function M.null()
  return { type = "null" }
end

--- Build an array schema.
function M.array(items, opts)
  local s = { type = "array", items = items }
  if opts then for k, v in pairs(opts) do s[k] = v end end
  return s
end

--- Build an object schema.
-- properties: { key = schema, ... }
-- required:   array of key strings (or nil to require all properties)
function M.object(properties, required, opts)
  local s = { type = "object", properties = properties or {} }
  if required then
    s.required = required
  else
    -- default: require all listed properties
    local req = {}
    for k, _ in pairs(s.properties) do req[#req + 1] = k end
    table.sort(req)
    s.required = req
  end
  if opts then for k, v in pairs(opts) do s[k] = v end end
  return s
end

--- Build an enum schema.
function M.enum(values)
  return { ["enum"] = values }
end

--- Build a oneOf schema.
function M.one_of(schemas)
  return { oneOf = schemas }
end

--- Build an anyOf schema.
function M.any_of(schemas)
  return { anyOf = schemas }
end

--- Build an allOf schema.
function M.all_of(schemas)
  return { allOf = schemas }
end

--- Wrap schema to also allow null: {oneOf = {schema, {type="null"}}}.
function M.nullable(schema)
  return { oneOf = { schema, { type = "null" } } }
end

--- Build a $ref schema.
function M.ref(name)
  return { ["$ref"] = "#/definitions/" .. name }
end

return M
