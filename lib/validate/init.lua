if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Helper: type name for error messages
local function typename(v)
  if v == nil then return "nil" end
  return type(v)
end

-- Primitive validators

--: () -> (value: unknown) -> true | (nil, string)
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
          local allowed = {}
          for i = 1, #opts.enum do allowed[i] = "'" .. opts.enum[i] .. "'" end
          return nil, "string '" .. value .. "' is not one of " .. table.concat(allowed, ", ")
        end
      end
    end
    return true
  end
end

--: () -> (value: unknown) -> true | (nil, string)
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

--: () -> (value: unknown) -> true | (nil, string)
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

--: () -> (value: unknown) -> true | (nil, string)
function M.boolean()
  return function(value)
    if type(value) ~= "boolean" then
      return nil, "expected boolean, got " .. typename(value)
    end
    return true
  end
end

--: () -> (value: unknown) -> true | (nil, string)
function M.table()
  return function(value)
    if type(value) ~= "table" then
      return nil, "expected table, got " .. typename(value)
    end
    return true
  end
end

--: () -> (value: unknown) -> true | (nil, string)
function M.func()
  return function(value)
    if type(value) ~= "function" then
      return nil, "expected function, got " .. typename(value)
    end
    return true
  end
end

--: () -> (value: unknown) -> true | (nil, string)
function M.any()
  return function()
    return true
  end
end

--: () -> (value: unknown) -> true | (nil, string)
function M.nil_()
  return function(value)
    if value ~= nil then
      return nil, "expected nil, got " .. typename(value)
    end
    return true
  end
end

--: (x: unknown) -> (value: unknown) -> true | (nil, string)
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

--: (validator: (value: unknown) -> true | (nil, string)) -> (value: unknown) -> true | (nil, string)
function M.optional(validator)
  return function(value)
    if value == nil then return true end
    return validator(value)
  end
end

--: (...((value: unknown) -> true | (nil, string))) -> ((value: unknown) -> true | (nil, string))
function M.one_of(...)
  local validators = { ... }
  return function(value)
    local errs = {}
    for i = 1, #validators do
      local ok, err = validators[i](value)
      if ok then return true end
      errs[#errs + 1] = err
    end
    return nil, "none of the validators matched: " .. table.concat(errs, "; ")
  end
end

--: (...((value: unknown) -> true | (nil, string))) -> ((value: unknown) -> true | (nil, string))
function M.all_of(...)
  local validators = { ... }
  return function(value)
    for i = 1, #validators do
      local ok, err = validators[i](value)
      if not ok then return nil, err end
    end
    return true
  end
end

--: (elem_validator: (value: unknown) -> true | (nil, string), opts: { min: number, max: number } | nil) -> (value: unknown) -> true | (nil, string)
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
    local errs = {}
    for i = 1, n do
      local ok, err = elem_validator(value[i])
      if not ok then
        errs[#errs + 1] = "[" .. i .. "]: " .. err
      end
    end
    if #errs > 0 then
      return nil, table.concat(errs, "; ")
    end
    return true
  end
end

--: (key_validator: (value: unknown) -> true | (nil, string), val_validator: (value: unknown) -> true | (nil, string)) -> (value: unknown) -> true | (nil, string)
function M.map(key_validator, val_validator)
  return function(value)
    if type(value) ~= "table" then
      return nil, "expected map, got " .. typename(value)
    end
    local errs = {}
    for k, v in pairs(value) do
      local ok, err = key_validator(k)
      if not ok then
        errs[#errs + 1] = "key " .. tostring(k) .. ": " .. err
      end
      ok, err = val_validator(v)
      if not ok then
        errs[#errs + 1] = "[" .. tostring(k) .. "]: " .. err
      end
    end
    if #errs > 0 then
      return nil, table.concat(errs, "; ")
    end
    return true
  end
end

--: (schema: { [string]: (value: unknown) -> true | (nil, string) }) -> (value: unknown) -> true | (nil, string)
function M.record(schema)
  return function(value)
    if type(value) ~= "table" then
      return nil, "expected record, got " .. typename(value)
    end
    local errs = {}
    for field, validator in pairs(schema) do
      local ok, err = validator(value[field])
      if not ok then
        errs[#errs + 1] = field .. ": " .. err
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

--: (fn: (value: unknown) -> true | (nil, string)) -> (value: unknown) -> true | (nil, string)
function M.custom(fn)
  return fn
end

return M
