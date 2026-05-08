if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- env_schema: typed environment variable schema validation
-- Injectable source table; no os.getenv calls inside the library.

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function trim(s)
  return s:match("^%s*(.-)%s*$")
end

-- ---------------------------------------------------------------------------
-- Field type constructors
-- Each returns a field descriptor table with a :validate(raw_string) method
-- that returns (value, errmsg).
-- ---------------------------------------------------------------------------

--:: StringOpts = { required: boolean | nil, default: string | nil, min_length: integer | nil, max_length: integer | nil, pattern: string | nil }
--:: NumberOpts = { required: boolean | nil, default: number | nil, min: number | nil, max: number | nil }

-- env.string(opts)
-- opts: required, default, min_length, max_length, pattern
function M.string(opts)
  local sopts = (opts or {}) --[[:! StringOpts]]
  local field = { _kind = "string", opts = sopts }
  function field:validate(raw)
    local raw = raw --[[:! string | nil]]
    local vopts = self.opts --[[:! StringOpts]]
    if raw == nil or raw == "" then
      if vopts.required then
        return nil, "required"
      end
      if vopts.default ~= nil then
        return vopts.default, nil
      end
      return nil, nil
    end
    local min_len = vopts.min_length
    if min_len and #raw < min_len then
      return nil, "min_length is " .. min_len .. ", got length " .. #raw
    end
    local max_len = vopts.max_length
    if max_len and #raw > max_len then
      return nil, "max_length is " .. max_len .. ", got length " .. #raw
    end
    local pat = vopts.pattern
    if pat and not raw:match(pat) then
      return nil, "does not match pattern " .. pat
    end
    return raw, nil
  end
  return field
end

-- env.number(opts)
-- opts: required, default, min, max
function M.number(opts)
  local nopts = (opts or {}) --[[:! NumberOpts]]
  local field = { _kind = "number", opts = nopts }
  function field:validate(raw)
    local vopts = self.opts --[[:! NumberOpts]]
    if raw == nil or raw == "" then
      if vopts.required then
        return nil, "required"
      end
      if vopts.default ~= nil then
        return vopts.default, nil
      end
      return nil, nil
    end
    local n = tonumber(raw)
    if n == nil then
      return nil, "expected number, got " .. string.format("%q", raw)
    end
    local min = vopts.min
    if min ~= nil and n < min then
      return nil, "min is " .. min .. ", got " .. n
    end
    local max = vopts.max
    if max ~= nil and n > max then
      return nil, "max is " .. max .. ", got " .. n
    end
    return n, nil
  end
  return field
end

-- env.integer(opts)
-- opts: required, default, min, max
-- Rejects values that are not whole numbers.
function M.integer(opts)
  local nopts = (opts or {}) --[[:! NumberOpts]]
  local field = { _kind = "integer", opts = nopts }
  function field:validate(raw)
    local vopts = self.opts --[[:! NumberOpts]]
    if raw == nil or raw == "" then
      if vopts.required then
        return nil, "required"
      end
      if vopts.default ~= nil then
        return vopts.default, nil
      end
      return nil, nil
    end
    local n = tonumber(raw)
    if n == nil then
      return nil, "expected integer, got " .. string.format("%q", raw)
    end
    if math.floor(n) ~= n then
      return nil, "expected integer (whole number), got " .. raw
    end
    local min = vopts.min
    if min ~= nil and n < min then
      return nil, "min is " .. min .. ", got " .. n
    end
    local max = vopts.max
    if max ~= nil and n > max then
      return nil, "max is " .. max .. ", got " .. n
    end
    return n, nil
  end
  return field
end

local TRUTHY  = { ["true"]=true,  ["1"]=true,  ["yes"]=true,  ["on"]=true  }
local FALSY   = { ["false"]=true, ["0"]=true,  ["no"]=true,   ["off"]=true }

-- env.boolean(opts)
-- opts: required, default
-- Accepts "true"/"1"/"yes"/"on" → true; "false"/"0"/"no"/"off" → false
function M.boolean(opts)
  opts = opts or {}
  local field = { _kind = "boolean", opts = opts }
  function field:validate(raw)
    if raw == nil or raw == "" then
      if self.opts.required then
        return nil, "required"
      end
      if self.opts.default ~= nil then
        return self.opts.default, nil
      end
      return nil, nil
    end
    local lower = raw:lower()
    if TRUTHY[lower] then return true, nil end
    if FALSY[lower]  then return false, nil end
    return nil, "expected boolean (true/false/1/0/yes/no/on/off), got " .. string.format("%q", raw)
  end
  return field
end

-- env.enum(values, opts)
-- opts: required, default
function M.enum(values, opts)
  opts = opts or {}
  local field = { _kind = "enum", values = values, opts = opts }
  -- build a lookup set
  local set = {}
  for _, v in ipairs(values) do set[v] = true end
  function field:validate(raw)
    if raw == nil or raw == "" then
      if self.opts.required then
        return nil, "required"
      end
      if self.opts.default ~= nil then
        return self.opts.default, nil
      end
      return nil, nil
    end
    if not set[raw] then
      return nil, "expected one of (" .. table.concat(values, ", ") .. "), got " .. string.format("%q", raw)
    end
    return raw, nil
  end
  return field
end

-- env.list(opts)
-- opts: required, default, sep (default ",")
-- Splits by sep and trims whitespace from each item.
function M.list(opts)
  opts = opts or {}
  local field = { _kind = "list", opts = opts }
  local sep = opts.sep or ","
  function field:validate(raw)
    local raw = raw --[[:! string | nil]]
    if raw == nil or raw == "" then
      if self.opts.required then
        return nil, "required"
      end
      if self.opts.default ~= nil then
        return self.opts.default, nil
      end
      return {}, nil
    end
    local sraw = raw --[[:! string]]
    local items = {}
    -- plain-string split (sep is a literal, not a pattern)
    local start = 1
    local seplen = #sep
    while true do
      local pos = sraw:find(sep, start, true)
      if pos then
        items[#items + 1] = trim(sraw:sub(start, pos - 1))
        start = pos + seplen
      else
        items[#items + 1] = trim(sraw:sub(start))
        break
      end
    end
    return items, nil
  end
  return field
end

-- env.url(opts)
-- opts: required, default
-- Validates that the value has a scheme (word://) and a non-empty host.
function M.url(opts)
  opts = opts or {}
  local field = { _kind = "url", opts = opts }
  function field:validate(raw)
    if raw == nil or raw == "" then
      if self.opts.required then
        return nil, "required"
      end
      if self.opts.default ~= nil then
        return self.opts.default, nil
      end
      return nil, nil
    end
    -- require scheme://host at minimum
    local scheme, rest = raw:match("^([%a][%w%+%-%.]*)://(.+)$")
    if not scheme then
      return nil, "expected URL with scheme (e.g. https://host/path), got " .. string.format("%q", raw)
    end
    -- rest must have a non-empty host (at least one char before / or end)
    local host = rest:match("^([^/?#]+)")
    if not host or host == "" then
      return nil, "URL missing host"
    end
    return raw, nil
  end
  return field
end

-- env.port(opts)
-- opts: required, default
-- Integer in range 1-65535.
function M.port(opts)
  opts = opts or {}
  -- compose on top of integer with fixed range
  local inner = M.integer({ required = opts.required, default = opts.default, min = 1, max = 65535 })
  local field = { _kind = "port", opts = opts }
  function field:validate(raw)
    local v, err = inner:validate(raw)
    if err then
      -- reword integer errors for port context
      if err == "required" then return nil, err end
      if raw ~= nil and raw ~= "" then
        local n = tonumber(raw)
        if n == nil then
          return nil, "expected port (integer 1-65535), got " .. string.format("%q", raw)
        end
        if math.floor(n) ~= n then
          return nil, "expected port (integer 1-65535), got " .. string.format("%q", raw)
        end
        return nil, "port out of range (1-65535), got " .. raw
      end
      return nil, err
    end
    return v, nil
  end
  return field
end

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

-- env.schema(fields) → schema object with :parse(source) and :template()
function M.schema(fields)
  local s = { _fields = fields }

  -- parse(source) → (config, errmsg | nil)
  -- source: string-keyed table (e.g. os.environ result, or a test table)
  function s:parse(source)
    local config = {}
    local errs   = {}
    for name, field in pairs(self._fields) do
      local raw = source[name]
      local value, err = field:validate(raw)
      if err then
        errs[#errs + 1] = name .. ": " .. err
      else
        config[name] = value
      end
    end
    if #errs > 0 then
      -- sort for deterministic output
      table.sort(errs)
      return nil, table.concat(errs, "\n")
    end
    return config, nil
  end

  -- template() → string with commented .env lines for each field
  function s:template()
    local lines = {}
    -- collect names and sort for deterministic output
    local names = {}
    for name in pairs(self._fields) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local field = self._fields[name]
      local kind  = field._kind
      local opts  = field.opts or {}
      -- build descriptor comment
      local desc = kind
      if kind == "enum" and field.values then
        desc = "enum(" .. table.concat(field.values, "|") .. ")"
      end
      local parts = { desc }
      if opts.required then parts[#parts + 1] = "required" end
      if opts.default ~= nil then
        local dv = opts.default
        if type(dv) == "table" then
          dv = table.concat(dv, (opts.sep or ","))
        end
        parts[#parts + 1] = "default: " .. tostring(dv)
      end
      lines[#lines + 1] = "# " .. name .. " (" .. table.concat(parts, ", ") .. ")"
      -- example line
      local example
      if opts.default ~= nil then
        local dv = opts.default
        if type(dv) == "table" then
          dv = table.concat(dv, (opts.sep or ","))
        end
        example = tostring(dv)
      else
        example = ""
      end
      lines[#lines + 1] = "# " .. name .. "=" .. example
      lines[#lines + 1] = ""
    end
    -- trim trailing blank line
    if lines[#lines] == "" then lines[#lines] = nil end
    return table.concat(lines, "\n")
  end

  return s
end

return M
