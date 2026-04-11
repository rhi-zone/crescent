if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- lib/config: layered configuration management
-- Priority (highest to lowest): args > env > layers (later first) > defaults

local M = {}

M._tier = "pure"

-- Split a dot-notation key into segments
local function split_key(key)
  local parts = {}
  for part in key:gmatch("[^%.]+") do
    parts[#parts + 1] = part
  end
  return parts
end

-- Navigate a nested table using a list of key segments
-- Returns value or nil
local function nested_get(t, parts)
  local cur = t
  for i = 1, #parts do
    if type(cur) ~= "table" then return nil end
    cur = cur[parts[i]]
  end
  return cur
end

-- Look up a key (dot-notation) in a flat or nested table.
-- First tries the full dot-notation string as a flat key.
-- Then navigates nested tables using dot segments.
local function table_get(t, key)
  local flat = t[key]
  if flat ~= nil then return flat end
  local parts = split_key(key)
  if #parts > 1 then
    return nested_get(t, parts)
  end
  return nil
end

-- Recursively merge src into dst (dst takes priority for conflicts)
local function merge_into(dst, src)
  for k, v in pairs(src) do
    if dst[k] == nil then
      dst[k] = v
    elseif type(dst[k]) == "table" and type(v) == "table" then
      merge_into(dst[k], v)
    end
    -- dst wins on conflict
  end
end

-- Deep copy a table
local function deep_copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do
    out[k] = deep_copy(v)
  end
  return out
end

-- Config object prototype
local Config = {}
Config.__index = Config

-- Create a new Config.
-- opts.env_reader: function(name) -> string|nil  (default: os.getenv)
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Config)
  self._defaults = {}   -- lowest priority
  self._layers = {}     -- list of tables, index 1 = first added (lowest among layers)
  self._env_prefix = nil
  self._args_table = nil
  self._env_reader = opts.env_reader or os.getenv
  return self
end

-- Set defaults (lowest priority). Returns self for chaining.
function Config:defaults(t)
  self._defaults = deep_copy(t)
  return self
end

-- Add a table layer (higher priority than defaults and prior layers).
-- Returns self for chaining.
function Config:layer(t)
  self._layers[#self._layers + 1] = deep_copy(t)
  return self
end

-- Register an env prefix for lookups.
-- APP_DB_HOST with prefix "APP" -> key "db.host"
-- Returns self for chaining.
function Config:env(prefix)
  self._env_prefix = prefix
  return self
end

-- Register a parsed CLI args table for lookups.
-- Returns self for chaining.
function Config:args(t)
  self._args_table = t and deep_copy(t) or nil
  return self
end

-- Convert a key to the env variable name for the given prefix.
-- "db.host" with prefix "APP" -> "APP_DB_HOST"
local function key_to_env_name(prefix, key)
  local upper = key:upper():gsub("%.", "_")
  return prefix .. "_" .. upper
end

-- Convert an env variable name to a config key given the prefix.
-- "APP_DB_HOST" with prefix "APP" -> "db.host"
-- Returns nil if the name doesn't match the prefix.
local function env_name_to_key(prefix, name)
  local p = prefix .. "_"
  if name:sub(1, #p) ~= p then return nil end
  local rest = name:sub(#p + 1):lower():gsub("_", ".", 1)
  -- Only replace first underscore after prefix with dot for top-level segment,
  -- but spec says APP_DB_HOST -> db.host (underscores after first segment -> dots)
  -- Re-read spec: "APP_DB_HOST" with prefix "APP" -> key "db.host"
  -- So the part after "APP_" is lowercased and underscores become dots.
  return name:sub(#p + 1):lower():gsub("_", ".")
end

-- Look up a key across all layers in priority order.
-- Priority: args > env > layers (later index = higher priority) > defaults
function Config:get(key, default)
  -- 1. args
  if self._args_table ~= nil then
    local v = table_get(self._args_table, key)
    if v ~= nil then return v end
  end

  -- 2. env
  if self._env_prefix ~= nil then
    local env_name = key_to_env_name(self._env_prefix, key)
    local v = self._env_reader(env_name)
    if v ~= nil then return v end
  end

  -- 3. layers (later = higher priority, so iterate from end)
  for i = #self._layers, 1, -1 do
    local v = table_get(self._layers[i], key)
    if v ~= nil then return v end
  end

  -- 4. defaults
  local v = table_get(self._defaults, key)
  if v ~= nil then return v end

  return default
end

-- Typed accessors

-- Returns integer or nil (+ errmsg on type mismatch)
function Config:int(key, default)
  local v = self:get(key, default)
  if v == nil then return nil end
  local n = tonumber(v)
  if n == nil then
    return nil, "config key '" .. key .. "': expected integer, got " .. tostring(v)
  end
  return math.floor(n)
end

-- Returns number (float) or nil
function Config:float(key, default)
  local v = self:get(key, default)
  if v == nil then return nil end
  local n = tonumber(v)
  if n == nil then
    return nil, "config key '" .. key .. "': expected number, got " .. tostring(v)
  end
  return n
end

-- Returns boolean or nil. Coerces "true"/"false"/"1"/"0".
function Config:bool(key, default)
  local v = self:get(key, default)
  if v == nil then return nil end
  if type(v) == "boolean" then return v end
  local s = tostring(v):lower()
  if s == "true" or s == "1" then return true end
  if s == "false" or s == "0" then return false end
  return nil, "config key '" .. key .. "': expected boolean, got " .. tostring(v)
end

-- Returns string or nil
function Config:string(key, default)
  local v = self:get(key, default)
  if v == nil then return nil end
  return tostring(v)
end

-- Returns array. If value is already a table, returns it as-is.
-- If value is a string, splits on commas.
function Config:list(key, default)
  local v = self:get(key, default)
  if v == nil then return nil end
  if type(v) == "table" then return v end
  local s = tostring(v)
  local result = {}
  for item in s:gmatch("[^,]+") do
    result[#result + 1] = item:match("^%s*(.-)%s*$") -- trim whitespace
  end
  return result
end

-- Get or error if nil
function Config:require(key)
  local v = self:get(key)
  if v == nil then
    error("config key '" .. key .. "' is required but not set", 2)
  end
  return v
end

-- Return a namespaced view: all lookups prepend prefix + "."
function Config:ns(prefix)
  local ns = setmetatable({}, Config)
  ns._defaults = self._defaults
  ns._layers = self._layers
  ns._env_prefix = self._env_prefix
  ns._args_table = self._args_table
  ns._env_reader = self._env_reader
  ns._ns_prefix = (self._ns_prefix and (self._ns_prefix .. ".") or "") .. prefix
  return ns
end

-- Override get to prepend namespace prefix
local _orig_get = Config.get
function Config:get(key, default)
  if self._ns_prefix then
    key = self._ns_prefix .. "." .. key
  end
  return _orig_get(self, key, default)
end

-- Produce a merged flat table snapshot of all current values.
-- Higher-priority layers win. Nested tables are merged recursively.
function Config:to_table()
  local out = {}
  -- Start with defaults
  merge_into(out, self._defaults)
  -- Apply layers in order (later layers override)
  for i = 1, #self._layers do
    for k, v in pairs(self._layers[i]) do
      if type(v) == "table" and type(out[k]) == "table" then
        local merged = deep_copy(out[k])
        merge_into(merged, {}) -- no-op
        -- layer overrides: layer wins for conflicts
        for lk, lv in pairs(v) do
          merged[lk] = lv
        end
        out[k] = merged
      else
        out[k] = v
      end
    end
  end
  -- Apply env values (for known keys already in the table)
  if self._env_prefix then
    for k, _ in pairs(out) do
      local env_name = key_to_env_name(self._env_prefix, tostring(k))
      local ev = self._env_reader(env_name)
      if ev ~= nil then out[k] = ev end
    end
  end
  -- Apply args
  if self._args_table then
    for k, v in pairs(self._args_table) do
      out[k] = v
    end
  end
  return out
end

-- Validate configuration.
-- opts.required: list of keys that must be present
-- opts.types: { [key] = "integer"|"number"|"boolean"|"string" }
-- Returns true on success, or (nil, errmsg) listing all failures.
function Config:validate(opts)
  opts = opts or {}
  local failures = {}

  if opts.required then
    for _, key in ipairs(opts.required) do
      if self:get(key) == nil then
        failures[#failures + 1] = "missing required key: " .. key
      end
    end
  end

  if opts.types then
    for key, expected_type in pairs(opts.types) do
      local v = self:get(key)
      if v ~= nil then
        if expected_type == "integer" then
          local n, err = self:int(key)
          if err or (n ~= nil and n ~= math.floor(n)) then
            failures[#failures + 1] = "key '" .. key .. "': expected integer"
          end
        elseif expected_type == "number" then
          local _, err = self:float(key)
          if err then
            failures[#failures + 1] = "key '" .. key .. "': expected number"
          end
        elseif expected_type == "boolean" then
          local _, err = self:bool(key)
          if err then
            failures[#failures + 1] = "key '" .. key .. "': expected boolean"
          end
        elseif expected_type == "string" then
          -- everything can be stringified; only fail if the raw type is wrong
          -- (allow any value to be treated as string)
        end
      end
    end
  end

  if #failures > 0 then
    return nil, table.concat(failures, "; ")
  end
  return true
end

return M
