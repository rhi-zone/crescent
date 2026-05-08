if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: Validator = (value: unknown) -> boolean | (nil, string)

-- Helper: type name for error messages
local function typename(v)
  if v == nil then return "nil" end
  return type(v)
end

-- Primitive validators

--: ({ min?: integer, max?: integer, pattern?: string, enum?: string[] } | nil) -> Validator
function M.string(opts)
  return function(value)
    if type(value) ~= "string" then
      return nil, "expected string, got " .. typename(value)
    end
    if opts then
      if opts.min and #value < opts.min then
        return nil, "string length " .. #value .. " is less than minimum " .. opts.min
      end
      if opts.max and #value > opts.max then
        return nil, "string length " .. #value .. " is greater than maximum " .. opts.max
      end
      if opts.pattern and not value:find(opts.pattern) then
        return nil, "string does not match pattern '" .. opts.pattern .. "'"
      end
      if opts.enum then
        local found = false
        for i = 1, #opts.enum do
          if value == opts.enum[i] then found = true; break end
        end
        if not found then
          local allowed = {} --: Arr<string>
          for i = 1, #opts.enum do allowed[i] = "'" .. opts.enum[i] .. "'" end
          return nil, "string '" .. value .. "' is not one of " .. table.concat(allowed, ", ")
        end
      end
    end
    return true
  end
end

--: ({ integer?: boolean, min?: number, max?: number } | nil) -> Validator
function M.number(opts)
  return function(value)
    if type(value) ~= "number" then
      return nil, "expected number, got " .. typename(value)
    end
    if opts then
      if opts.integer and value ~= math.floor(value) then
        return nil, "expected integer, got float"
      end
      if opts.min and value < opts.min then
        return nil, "number " .. value .. " is less than minimum " .. opts.min
      end
      if opts.max and value > opts.max then
        return nil, "number " .. value .. " is greater than maximum " .. opts.max
      end
    end
    return true
  end
end

--: ({ min?: integer, max?: integer } | nil) -> Validator
function M.integer(opts)
  return function(value)
    if type(value) ~= "number" then
      return nil, "expected integer, got " .. typename(value)
    end
    if value ~= math.floor(value) or value == 1/0 or value == -1/0 then
      return nil, "expected integer, got float"
    end
    if opts then
      if opts.min and value < opts.min then
        return nil, "integer " .. value .. " is less than minimum " .. opts.min
      end
      if opts.max and value > opts.max then
        return nil, "integer " .. value .. " is greater than maximum " .. opts.max
      end
    end
    return true
  end
end

--: () -> Validator
function M.boolean()
  return function(value)
    if type(value) ~= "boolean" then
      return nil, "expected boolean, got " .. typename(value)
    end
    return true
  end
end

--: () -> Validator
function M.table()
  return function(value)
    if type(value) ~= "table" then
      return nil, "expected table, got " .. typename(value)
    end
    return true
  end
end

--: () -> Validator
function M.func()
  return function(value)
    if type(value) ~= "function" then
      return nil, "expected function, got " .. typename(value)
    end
    return true
  end
end

--: () -> Validator
function M.any()
  return function(_value)
    return true
  end
end

--: () -> Validator
function M.nil_()
  return function(value)
    if value ~= nil then
      return nil, "expected nil, got " .. typename(value)
    end
    return true
  end
end

--: (x: unknown) -> Validator
function M.literal(x)
  return function(value)
    if value ~= x then
      local xstr = type(x) == "string" and ("'" .. x .. "'") or tostring(x)
      local vstr = type(value) == "string" and ("'" .. value .. "'") or tostring(value)
      return nil, "expected literal " .. xstr .. ", got " .. vstr
    end
    return true
  end
end

-- Combinators

--: (validator: Validator) -> Validator
function M.optional(validator)
  --: (unknown) -> boolean | (nil, string)
  return function(value)
    if value == nil then return true end
    local ok, err = validator(value)
    if not ok then return nil, err or "" end
    return true
  end
end

--: (...Validator) -> Validator
function M.one_of(...)
  local validators = { ... } --: Validator[]
  return function(value)
    local errs = {} --: Arr<string>
    for i = 1, #validators do
      local ok, err = validators[i](value)
      if ok then return true end
      errs[#errs + 1] = err or ""
    end
    return nil, "none of the validators matched: " .. table.concat(errs, "; ")
  end
end

--: (...Validator) -> Validator
function M.all_of(...)
  local validators = { ... } --: Validator[]
  --: (unknown) -> boolean | (nil, string)
  return function(value)
    for i = 1, #validators do
      local ok, err = validators[i](value)
      if not ok then return nil, err or "" end
    end
    return true
  end
end

--: (elem_validator: Validator, opts: { min?: number, max?: number } | nil) -> Validator
function M.array(elem_validator, opts)
  return function(value)
    if type(value) ~= "table" then
      return nil, "expected array, got " .. typename(value)
    end
    local n = #value
    if opts then
      if opts.min and n < opts.min then
        return nil, "array length " .. n .. " is less than minimum " .. opts.min
      end
      if opts.max and n > opts.max then
        return nil, "array length " .. n .. " is greater than maximum " .. opts.max
      end
    end
    local errs = {} --: Arr<string>
    for i = 1, n do
      local ok, err = elem_validator(value[i])
      if not ok then
        errs[#errs + 1] = "[" .. i .. "]: " .. (err or "")
      end
    end
    if #errs > 0 then
      return nil, table.concat(errs, "; ")
    end
    return true
  end
end

--: (key_validator: Validator, val_validator: Validator) -> Validator
function M.map(key_validator, val_validator)
  return function(value)
    if type(value) ~= "table" then
      return nil, "expected map, got " .. typename(value)
    end
    local errs = {} --: Arr<string>
    for k, v in pairs(value) do
      local ok, err = key_validator(k)
      if not ok then
        errs[#errs + 1] = "key " .. tostring(k) .. ": " .. (err or "")
      end
      local ok2, err2 = val_validator(v)
      if not ok2 then
        errs[#errs + 1] = "[" .. tostring(k) .. "]: " .. (err2 or "")
      end
    end
    if #errs > 0 then
      return nil, table.concat(errs, "; ")
    end
    return true
  end
end

--: (schema: { [string]: Validator }) -> Validator
function M.record(schema)
  return function(value)
    if type(value) ~= "table" then
      return nil, "expected record, got " .. typename(value)
    end
    local errs = {} --: Arr<string>
    for field, validator in pairs(schema) do
      local ok, err = validator(value[field])
      if not ok then
        errs[#errs + 1] = field .. ": " .. (err or "")
      end
    end
    if #errs > 0 then
      -- Sort errors for deterministic output
      table.sort(errs)
      return nil, table.concat(errs, "; ")
    end
    return true
  end
end

--: (fn: Validator) -> Validator
function M.custom(fn)
  return fn
end

return M
