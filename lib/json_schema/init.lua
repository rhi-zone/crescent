-- lib/json_schema/init.lua
-- JSON Schema draft-7 validator for crescent.
-- Pure Lua, no external dependencies.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function typeof(v)
  local t = type(v)
  if t == "number" then
    -- JSON Schema distinguishes integer from number.
    -- In Lua all numbers are doubles; treat x as integer when x == math.floor(x)
    -- and it fits in a safe integer range.
    if v == math.floor(v) and v >= -2^53 and v <= 2^53 then
      return "integer"
    end
    return "number"
  end
  if t == "table" then
    -- Distinguish array from object: an array has only consecutive integer keys
    -- starting at 1 (or is empty).
    local n = #v
    local count = 0
    for _ in pairs(v) do count = count + 1 end
    if count == 0 then
      -- Empty table: could be either array or object.  We treat it as array
      -- (consistent with JSON [] → Lua {}).  Callers that need "object" must
      -- pass a schema that checks properties/required explicitly.
      return "array"
    end
    if count == n then return "array" end
    return "object"
  end
  -- nil → "null", boolean → "boolean", string → "string"
  if t == "nil" then return "null" end
  return t
end

local function is_integer(v)
  return type(v) == "number" and v == math.floor(v) and v >= -2^53 and v <= 2^53
end

local function deep_equal(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function push_error(errors, path, message)
  errors[#errors + 1] = { path = path, message = message }
end

local function join_path(base, key)
  if type(key) == "number" then
    return base .. "/" .. (key - 1)  -- JSON Pointer uses 0-based array indices
  end
  -- Escape per RFC 6901: ~ → ~0, / → ~1
  local escaped = tostring(key):gsub("~", "~0"):gsub("/", "~1")
  return base .. "/" .. escaped
end

-- ---------------------------------------------------------------------------
-- $ref resolution
-- ---------------------------------------------------------------------------

-- Resolve a JSON Pointer fragment like "#/definitions/Foo" against root_schema.
-- Only supports absolute-from-root pointers (#/...).
local function resolve_ref(ref, root_schema)
  if ref == "#" then return root_schema end
  local pointer = ref:match("^#(/.*)$")
  if not pointer then return nil, "unsupported $ref format: " .. tostring(ref) end
  local node = root_schema
  for segment in pointer:gmatch("/([^/]*)") do
    -- Unescape RFC 6901
    segment = segment:gsub("~1", "/"):gsub("~0", "~")
    if type(node) ~= "table" then return nil, "path not found: " .. ref end
    -- Try string key first, then numeric
    if node[segment] ~= nil then
      node = node[segment]
    else
      local idx = tonumber(segment)
      if idx then node = node[idx + 1]  -- convert 0-based → 1-based
      else return nil, "key not found: " .. segment .. " in " .. ref end
    end
  end
  return node
end

-- ---------------------------------------------------------------------------
-- Format validators (advisory — skip unknown formats)
-- ---------------------------------------------------------------------------

local format_validators = {}

format_validators["date"] = function(s)
  -- YYYY-MM-DD
  local y, mo, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not y then return false, "invalid date format" end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  if mo < 1 or mo > 12 then return false, "month out of range" end
  if d < 1 or d > 31 then return false, "day out of range" end
  return true
end

format_validators["time"] = function(s)
  -- HH:MM:SS or HH:MM:SS.fff with optional Z or ±HH:MM
  local ok = s:match("^%d%d:%d%d:%d%d") ~= nil
  if not ok then return false, "invalid time format" end
  return true
end

format_validators["date-time"] = function(s)
  -- Very permissive: YYYY-MM-DDTHH:MM:SS...
  local ok = s:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d") ~= nil
  if not ok then return false, "invalid date-time format" end
  return true
end

format_validators["email"] = function(s)
  local ok = s:match("^[^@]+@[^@]+%.[^@]+$") ~= nil
  if not ok then return false, "invalid email format" end
  return true
end

format_validators["uri"] = function(s)
  -- Must have a scheme (letters followed by colon)
  local ok = s:match("^[%a][%w%+%.%-]*:") ~= nil
  if not ok then return false, "invalid URI: missing scheme" end
  return true
end

format_validators["ipv4"] = function(s)
  local parts = {}
  for p in (s .. "."):gmatch("([^.]*)%.") do parts[#parts + 1] = p end
  if #parts ~= 4 then return false, "invalid IPv4" end
  for _, p in ipairs(parts) do
    local n = tonumber(p)
    if not n or n < 0 or n > 255 or tostring(n) ~= p then
      return false, "invalid IPv4 octet: " .. p
    end
  end
  return true
end

format_validators["ipv6"] = function(s)
  -- Basic check: only hex digits, colons, and optional :: abbreviation
  local ok = s:match("^[%x:]+$") ~= nil
  if not ok then return false, "invalid IPv6" end
  return true
end

-- ---------------------------------------------------------------------------
-- Core recursive validator
-- ---------------------------------------------------------------------------

-- validate_value(value, schema, path, root_schema, ref_stack) → ok, errors_list
-- errors_list is an array of {path, message} tables (may be empty on success).
local function validate_value(value, schema, path, root_schema, ref_stack)
  local errors = {}

  -- Boolean schema: true accepts everything, false rejects everything.
  if schema == true then return true, errors end
  if schema == false then
    push_error(errors, path, "schema is false — all values rejected")
    return false, errors
  end

  if type(schema) ~= "table" then
    push_error(errors, path, "invalid schema (not a table or boolean)")
    return false, errors
  end

  -- $ref — resolve and validate against resolved schema, ignoring sibling keywords
  -- (draft-7 behaviour).
  if schema["$ref"] ~= nil then
    local ref = schema["$ref"]
    -- Guard against infinite recursion
    if ref_stack[ref] then
      -- Treat circular ref as accepted (we've already validated this path).
      return true, errors
    end
    local resolved, err = resolve_ref(ref, root_schema)
    if not resolved then
      push_error(errors, path, "unresolvable $ref: " .. (err or ref))
      return false, errors
    end
    ref_stack[ref] = true
    local ok2, sub_errors = validate_value(value, resolved, path, root_schema, ref_stack)
    ref_stack[ref] = nil
    if not ok2 then
      for _, e in ipairs(sub_errors) do errors[#errors + 1] = e end
      return false, errors
    end
    return true, errors
  end

  local vtype = typeof(value)

  -- -------------------------------------------------------------------------
  -- type
  -- -------------------------------------------------------------------------
  if schema.type ~= nil then
    local allowed = schema.type
    if type(allowed) == "string" then allowed = { allowed } end
    -- OpenAPI nullable extension
    if schema.nullable then
      allowed = { unpack(allowed) }
      allowed[#allowed + 1] = "null"
    end
    local type_ok = false
    for _, t in ipairs(allowed) do
      if t == vtype then type_ok = true; break end
      -- "number" also accepts integers
      if t == "number" and vtype == "integer" then type_ok = true; break end
    end
    if not type_ok then
      local allowed_str = table.concat(allowed, "|")
      push_error(errors, path, "expected " .. allowed_str .. ", got " .. vtype)
    end
  elseif schema.nullable and vtype == "null" then
    -- nullable without type: null is always allowed
  end

  -- -------------------------------------------------------------------------
  -- enum
  -- -------------------------------------------------------------------------
  if schema.enum ~= nil then
    local found = false
    for _, candidate in ipairs(schema.enum) do
      if deep_equal(value, candidate) then found = true; break end
    end
    if not found then
      push_error(errors, path, "value not in enum")
    end
  end

  -- -------------------------------------------------------------------------
  -- const
  -- -------------------------------------------------------------------------
  if schema["const"] ~= nil then
    if not deep_equal(value, schema["const"]) then
      push_error(errors, path, "value does not match const")
    end
  end

  -- -------------------------------------------------------------------------
  -- String keywords
  -- -------------------------------------------------------------------------
  if type(value) == "string" then
    -- length in Unicode codepoints is non-trivial; we use byte length as an
    -- approximation (correct for ASCII, which covers most use-cases).
    local len = #value

    if schema.minLength ~= nil and len < schema.minLength then
      push_error(errors, path, "string too short: " .. len .. " < " .. schema.minLength)
    end
    if schema.maxLength ~= nil and len > schema.maxLength then
      push_error(errors, path, "string too long: " .. len .. " > " .. schema.maxLength)
    end
    if schema.pattern ~= nil then
      if not value:find(schema.pattern) then
        push_error(errors, path, "string does not match pattern: " .. schema.pattern)
      end
    end
    if schema.format ~= nil then
      local fv = format_validators[schema.format]
      if fv then
        local fok, ferr = fv(value)
        if not fok then
          push_error(errors, path, "format " .. schema.format .. ": " .. (ferr or "invalid"))
        end
      end
      -- Unknown formats are silently skipped (advisory per spec).
    end
  end

  -- -------------------------------------------------------------------------
  -- Number/integer keywords
  -- -------------------------------------------------------------------------
  if vtype == "number" or vtype == "integer" then
    local n = value
    if schema.minimum ~= nil then
      if schema.exclusiveMinimum == true then
        if n <= schema.minimum then
          push_error(errors, path, "value " .. n .. " must be > " .. schema.minimum)
        end
      else
        if n < schema.minimum then
          push_error(errors, path, "value " .. n .. " must be >= " .. schema.minimum)
        end
      end
    end
    if schema.maximum ~= nil then
      if schema.exclusiveMaximum == true then
        if n >= schema.maximum then
          push_error(errors, path, "value " .. n .. " must be < " .. schema.maximum)
        end
      else
        if n > schema.maximum then
          push_error(errors, path, "value " .. n .. " must be <= " .. schema.maximum)
        end
      end
    end
    -- Draft-6+ numeric exclusiveMinimum / exclusiveMaximum as numbers
    if type(schema.exclusiveMinimum) == "number" then
      if n <= schema.exclusiveMinimum then
        push_error(errors, path, "value " .. n .. " must be > " .. schema.exclusiveMinimum)
      end
    end
    if type(schema.exclusiveMaximum) == "number" then
      if n >= schema.exclusiveMaximum then
        push_error(errors, path, "value " .. n .. " must be < " .. schema.exclusiveMaximum)
      end
    end
    if schema.multipleOf ~= nil then
      local divisor = schema.multipleOf
      -- Use modulo with tolerance for floating-point
      local remainder = n % divisor
      if remainder ~= 0 and math.abs(remainder - divisor) > 1e-10 then
        push_error(errors, path, "value " .. n .. " is not a multiple of " .. divisor)
      end
    end
  end

  -- -------------------------------------------------------------------------
  -- Array keywords
  -- -------------------------------------------------------------------------
  if vtype == "array" then
    local arr = value
    local len = #arr

    if schema.minItems ~= nil and len < schema.minItems then
      push_error(errors, path, "array too short: " .. len .. " < " .. schema.minItems)
    end
    if schema.maxItems ~= nil and len > schema.maxItems then
      push_error(errors, path, "array too long: " .. len .. " > " .. schema.maxItems)
    end

    -- items: schema (all items) or array of schemas (tuple validation)
    local items_schema = schema.items
    local additional_items_schema = schema.additionalItems
    if items_schema ~= nil then
      if type(items_schema) == "table" and #items_schema > 0 then
        -- Tuple mode
        for i, item in ipairs(arr) do
          local item_schema = items_schema[i]
          if item_schema ~= nil then
            local ok2, sub_errors = validate_value(item, item_schema, join_path(path, i), root_schema, ref_stack)
            if not ok2 then
              for _, e in ipairs(sub_errors) do errors[#errors + 1] = e end
            end
          elseif additional_items_schema ~= nil then
            if additional_items_schema == false then
              push_error(errors, join_path(path, i), "additional items not allowed")
            elseif type(additional_items_schema) == "table" then
              local ok2, sub_errors = validate_value(item, additional_items_schema, join_path(path, i), root_schema, ref_stack)
              if not ok2 then
                for _, e in ipairs(sub_errors) do errors[#errors + 1] = e end
              end
            end
          end
        end
      elseif items_schema ~= false then
        -- Single schema — all items
        for i, item in ipairs(arr) do
          local ok2, sub_errors = validate_value(item, items_schema, join_path(path, i), root_schema, ref_stack)
          if not ok2 then
            for _, e in ipairs(sub_errors) do errors[#errors + 1] = e end
          end
        end
      elseif items_schema == false and len > 0 then
        push_error(errors, path, "items schema is false — no items allowed")
      end
    end

    -- uniqueItems
    if schema.uniqueItems then
      for i = 1, len do
        for j = i + 1, len do
          if deep_equal(arr[i], arr[j]) then
            push_error(errors, path, "duplicate items at indices " .. (i-1) .. " and " .. (j-1))
            break
          end
        end
      end
    end

    -- contains
    if schema.contains ~= nil then
      local found = false
      for _, item in ipairs(arr) do
        local ok2 = validate_value(item, schema.contains, path, root_schema, ref_stack)
        if ok2 then found = true; break end
      end
      if not found then
        push_error(errors, path, "array does not contain required item")
      end
    end
  end

  -- -------------------------------------------------------------------------
  -- Object keywords
  -- -------------------------------------------------------------------------
  if vtype == "object" then
    local obj = value

    -- Count properties
    local prop_count = 0
    for _ in pairs(obj) do prop_count = prop_count + 1 end

    if schema.minProperties ~= nil and prop_count < schema.minProperties then
      push_error(errors, path, "too few properties: " .. prop_count .. " < " .. schema.minProperties)
    end
    if schema.maxProperties ~= nil and prop_count > schema.maxProperties then
      push_error(errors, path, "too many properties: " .. prop_count .. " > " .. schema.maxProperties)
    end

    -- required
    if schema.required ~= nil then
      for _, key in ipairs(schema.required) do
        if obj[key] == nil then
          push_error(errors, join_path(path, key), "required property missing: " .. key)
        end
      end
    end

    -- Collect which keys are validated by properties or patternProperties
    local validated_keys = {}

    -- properties
    if schema.properties ~= nil then
      for key, prop_schema in pairs(schema.properties) do
        if obj[key] ~= nil then
          validated_keys[key] = true
          local ok2, sub_errors = validate_value(obj[key], prop_schema, join_path(path, key), root_schema, ref_stack)
          if not ok2 then
            for _, e in ipairs(sub_errors) do errors[#errors + 1] = e end
          end
        end
      end
    end

    -- patternProperties
    if schema.patternProperties ~= nil then
      for pattern, prop_schema in pairs(schema.patternProperties) do
        for key, v in pairs(obj) do
          if key:find(pattern) then
            validated_keys[key] = true
            local ok2, sub_errors = validate_value(v, prop_schema, join_path(path, key), root_schema, ref_stack)
            if not ok2 then
              for _, e in ipairs(sub_errors) do errors[#errors + 1] = e end
            end
          end
        end
      end
    end

    -- additionalProperties
    if schema.additionalProperties ~= nil then
      local ap = schema.additionalProperties
      for key in pairs(obj) do
        if not validated_keys[key] then
          if ap == false then
            push_error(errors, join_path(path, key), "additional property not allowed: " .. tostring(key))
          elseif type(ap) == "table" then
            local ok2, sub_errors = validate_value(obj[key], ap, join_path(path, key), root_schema, ref_stack)
            if not ok2 then
              for _, e in ipairs(sub_errors) do errors[#errors + 1] = e end
            end
          end
        end
      end
    end

    -- dependencies
    if schema.dependencies ~= nil then
      for dep_key, dep_val in pairs(schema.dependencies) do
        if obj[dep_key] ~= nil then
          if type(dep_val) == "table" and #dep_val > 0 then
            -- Array of required keys
            for _, required_key in ipairs(dep_val) do
              if obj[required_key] == nil then
                push_error(errors, path, "dependency of '" .. dep_key .. "' requires '" .. required_key .. "'")
              end
            end
          elseif type(dep_val) == "table" then
            -- Schema dependency
            local ok2, sub_errors = validate_value(obj, dep_val, path, root_schema, ref_stack)
            if not ok2 then
              for _, e in ipairs(sub_errors) do errors[#errors + 1] = e end
            end
          end
        end
      end
    end
  end

  -- -------------------------------------------------------------------------
  -- Combining keywords
  -- -------------------------------------------------------------------------

  -- allOf
  if schema.allOf ~= nil then
    for i, sub_schema in ipairs(schema.allOf) do
      local ok2, sub_errors = validate_value(value, sub_schema, path, root_schema, ref_stack)
      if not ok2 then
        push_error(errors, path, "allOf[" .. (i-1) .. "] failed")
        for _, e in ipairs(sub_errors) do errors[#errors + 1] = e end
      end
    end
  end

  -- anyOf
  if schema.anyOf ~= nil then
    local any_ok = false
    local all_sub_errors = {}
    for _, sub_schema in ipairs(schema.anyOf) do
      local ok2, sub_errors = validate_value(value, sub_schema, path, root_schema, ref_stack)
      if ok2 then any_ok = true; break end
      for _, e in ipairs(sub_errors) do all_sub_errors[#all_sub_errors + 1] = e end
    end
    if not any_ok then
      push_error(errors, path, "anyOf: no subschema matched")
      for _, e in ipairs(all_sub_errors) do errors[#errors + 1] = e end
    end
  end

  -- oneOf
  if schema.oneOf ~= nil then
    local match_count = 0
    local all_sub_errors = {}
    for _, sub_schema in ipairs(schema.oneOf) do
      local ok2, sub_errors = validate_value(value, sub_schema, path, root_schema, ref_stack)
      if ok2 then
        match_count = match_count + 1
      else
        for _, e in ipairs(sub_errors) do all_sub_errors[#all_sub_errors + 1] = e end
      end
    end
    if match_count ~= 1 then
      push_error(errors, path, "oneOf: expected exactly 1 match, got " .. match_count)
      if match_count == 0 then
        for _, e in ipairs(all_sub_errors) do errors[#errors + 1] = e end
      end
    end
  end

  -- not
  if schema["not"] ~= nil then
    local ok2 = validate_value(value, schema["not"], path, root_schema, ref_stack)
    if ok2 then
      push_error(errors, path, "'not' subschema matched (should not)")
    end
  end

  -- -------------------------------------------------------------------------
  -- Conditional: if/then/else
  -- -------------------------------------------------------------------------
  if schema["if"] ~= nil then
    local cond_ok = validate_value(value, schema["if"], path, root_schema, ref_stack)
    if cond_ok then
      if schema["then"] ~= nil then
        local ok2, sub_errors = validate_value(value, schema["then"], path, root_schema, ref_stack)
        if not ok2 then
          push_error(errors, path, "if matched but then failed")
          for _, e in ipairs(sub_errors) do errors[#errors + 1] = e end
        end
      end
    else
      if schema["else"] ~= nil then
        local ok2, sub_errors = validate_value(value, schema["else"], path, root_schema, ref_stack)
        if not ok2 then
          push_error(errors, path, "if did not match and else failed")
          for _, e in ipairs(sub_errors) do errors[#errors + 1] = e end
        end
      end
    end
  end

  local ok = #errors == 0
  return ok, errors
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- compile(schema) → validator_fn
-- The returned function: validator(value) → ok, errors_or_nil
function M.compile(schema)
  local root = schema
  return function(value)
    local ok, errors = validate_value(value, schema, "", root, {})
    if ok then return true, nil end
    return false, errors
  end
end

-- validate(value, schema) → ok, errors_or_nil
function M.validate(value, schema)
  return M.compile(schema)(value)
end

return M
