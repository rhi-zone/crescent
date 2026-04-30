if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- Deep copy and table utilities.
local M = {}
M._tier = "pure"

-- Internal sentinel to detect frozen tables
local FROZEN = {}

-- ─── copy ──────────────────────────────────────────────────────────────────

--- Deep copy a value, preserving metatables and handling cycles.
-- @param v any value
-- @param opts? {transform?: (v,depth)->(new_val,bool)}
-- @return copied value
function M.copy(v, opts)
  local visited = {}
  local transform = opts and opts.transform

  local function _copy(x, depth)
    if type(x) ~= "table" then
      if transform then
        local nv, handled = transform(x, depth)
        if handled then return nv end
      end
      return x
    end
    if visited[x] then return visited[x] end

    if transform then
      local nv, handled = transform(x, depth)
      if handled then
        visited[x] = nv
        return nv
      end
    end

    local result = {}
    visited[x] = result

    for k, val in pairs(x) do
      result[_copy(k, depth + 1)] = _copy(val, depth + 1)
    end

    local mt = getmetatable(x)
    if mt then
      -- Don't propagate freeze proxy metatable; the copy is a normal table
      if not mt[FROZEN] then
        setmetatable(result, mt)
      end
    end

    return result
  end

  return _copy(v, 0)
end

--- Shallow copy a table (one level only).
-- @param t table
-- @return new table with same top-level keys
function M.shallow(t)
  if type(t) ~= "table" then return t end
  local result = {}
  for k, v in pairs(t) do
    result[k] = v
  end
  local mt = getmetatable(t)
  if mt and not mt[FROZEN] then
    setmetatable(result, mt)
  end
  return result
end

-- ─── freeze ────────────────────────────────────────────────────────────────
-- Freeze uses a proxy-table pattern: the returned proxy is an empty table
-- whose metatable redirects reads to the original data table via __index
-- and blocks all writes via __newindex. Because the proxy itself has no
-- raw entries, __newindex fires for every write attempt (both new and
-- existing keys). The original data table is stored in mt.__data.

--- Make a table immutable. Returns a proxy that blocks all writes.
-- Reads are forwarded to the original table. Original is not modified.
-- @param t table
-- @return proxy table (frozen)
function M.freeze(t)
  if type(t) ~= "table" then
    error("freeze: expected table, got " .. type(t), 2)
  end
  if M.is_frozen(t) then return t end
  local proxy = {}
  local mt = {
    __index = t,
    __newindex = function(_, k, _v)
      error("attempt to write to frozen table (key: " .. tostring(k) .. ")", 2)
    end,
    __len = function() return #t end,
    __pairs = function() return pairs(t) end,
    [FROZEN] = true,
    __data = t,
  }
  setmetatable(proxy, mt)
  return proxy
end

--- Check if a table is frozen (i.e. is a freeze proxy).
-- @param t any
-- @return boolean
function M.is_frozen(t)
  if type(t) ~= "table" then return false end
  local mt = getmetatable(t)
  return mt ~= nil and mt[FROZEN] == true
end

--- Recursively freeze a table and all nested tables.
-- Returns the frozen proxy for the root; nested tables are also replaced
-- with proxies inside the root data table so reads through the proxy
-- return frozen children.
-- @param t table
-- @return frozen proxy
function M.freeze_deep(t)
  if type(t) ~= "table" then return t end
  if M.is_frozen(t) then return t end
  -- Freeze children first in-place (replace values with proxies)
  for k, v in pairs(t) do
    if type(v) == "table" and not M.is_frozen(v) then
      t[k] = M.freeze_deep(v)
    end
  end
  return M.freeze(t)
end

-- ─── equal ─────────────────────────────────────────────────────────────────

--- Deep structural equality with cycle detection.
-- @param a any
-- @param b any
-- @param opts? {strict?: bool}  -- strict=true also compares metatables
-- @return boolean
function M.equal(a, b, opts)
  local strict = opts and opts.strict
  local visited = {} -- key: a_ptr*2^32+b_ptr simulation via string key

  local function _equal(x, y)
    if x == y then return true end
    if type(x) ~= type(y) then return false end
    if type(x) ~= "table" then return false end

    -- Cycle detection: use tostring of pointers as proxy
    local key = tostring(x) .. "|" .. tostring(y)
    if visited[key] then return true end -- assume equal if we've entered this pair
    visited[key] = true

    if strict then
      if getmetatable(x) ~= getmetatable(y) then return false end
    end

    -- Check all keys in x exist with equal values in y
    for k, v in pairs(x) do
      if not _equal(v, y[k]) then return false end
    end

    -- Check y has no extra keys
    for k in pairs(y) do
      if x[k] == nil then return false end
    end

    return true
  end

  return _equal(a, b)
end

-- ─── diff ──────────────────────────────────────────────────────────────────

--- Compute structural diff between two tables.
-- @param a any (original)
-- @param b any (new)
-- @return list of {path, old, new} tables
function M.diff(a, b)
  local changes = {}

  local function _diff(x, y, path)
    if type(x) ~= "table" or type(y) ~= "table" then
      if x ~= y then
        changes[#changes + 1] = { path = path, old = x, new = y }
      end
      return
    end

    -- Keys in x
    local seen = {}
    for k, vx in pairs(x) do
      seen[k] = true
      local vy = y[k]
      local child_path
      if type(k) == "number" then
        child_path = path == "" and ("[" .. k .. "]") or (path .. "[" .. k .. "]")
      else
        child_path = path == "" and tostring(k) or (path .. "." .. tostring(k))
      end
      if vy == nil then
        changes[#changes + 1] = { path = child_path, old = vx, new = nil }
      elseif type(vx) == "table" and type(vy) == "table" then
        _diff(vx, vy, child_path)
      elseif vx ~= vy then
        changes[#changes + 1] = { path = child_path, old = vx, new = vy }
      end
    end

    -- Keys in y not in x
    for k, vy in pairs(y) do
      if not seen[k] then
        local child_path
        if type(k) == "number" then
          child_path = path == "" and ("[" .. k .. "]") or (path .. "[" .. k .. "]")
        else
          child_path = path == "" and tostring(k) or (path .. "." .. tostring(k))
        end
        changes[#changes + 1] = { path = child_path, old = nil, new = vy }
      end
    end
  end

  _diff(a, b, "")
  return changes
end

-- ─── patch ─────────────────────────────────────────────────────────────────

--- Apply a diff to a table, returning a new table (does not mutate original).
-- @param t table
-- @param d diff list from M.diff
-- @return new table
function M.patch(t, d)
  local result = M.copy(t)
  for _, change in ipairs(d) do
    if change.new == nil then
      M.delete(result, change.path)
    else
      M.set(result, change.path, change.new)
    end
  end
  return result
end

-- ─── merge ─────────────────────────────────────────────────────────────────

--- Shallow merge: rightmost wins. Returns new table, does not mutate.
-- @param ... tables
-- @return merged table
function M.merge(...)
  local result = {}
  local args = {...}
  for i = 1, #args do
    local t = args[i]
    if type(t) == "table" then
      for k, v in pairs(t) do
        result[k] = v
      end
    end
  end
  return result
end

--- Deep merge: recursively merge nested tables. Arrays in later args replace earlier.
-- @param ... tables
-- @return merged table
function M.deep_merge(...)
  local args = {...}

  local function _merge2(base, override)
    local result = {}
    for k, v in pairs(base) do
      result[k] = v
    end
    for k, v in pairs(override) do
      if type(v) == "table" and type(result[k]) == "table" then
        -- Don't recurse into arrays (integer-keyed tables)
        local is_array = false
        for ik in pairs(v) do
          if type(ik) == "number" then is_array = true break end
        end
        if is_array then
          result[k] = M.copy(v)
        else
          result[k] = _merge2(result[k], v)
        end
      else
        result[k] = type(v) == "table" and M.copy(v) or v
      end
    end
    return result
  end

  if #args == 0 then return {} end
  local result = M.copy(--[[:! any]] args[1])
  for i = 2, #args do
    result = _merge2(result, --[[:! any]] args[i])
  end
  return result
end

-- ─── path helpers ──────────────────────────────────────────────────────────

-- Parse a path string like "user.profile.name" or "arr[1].x"
-- Returns list of keys (strings or numbers)
local function parse_path(path)
  if path == "" or path == nil then return {} end
  local parts = {}
  -- Split on dots and bracket notation
  local s = path
  while #s > 0 do
    -- bracket index: [N]
    local idx = s:match("^%[(%d+)%]")
    if idx then
      parts[#parts + 1] = tonumber(idx)
      s = s:sub(#idx + 3) -- skip [N]
      if s:sub(1, 1) == "." then s = s:sub(2) end
    else
      -- dot-separated key
      local key, rest = s:match("^([^%.%[]+)(.*)")
      if not key then break end
      parts[#parts + 1] = key
      s = rest
      if s:sub(1, 1) == "." then s = s:sub(2) end
    end
  end
  return parts
end

--- Safe nested get by dot-notation path.
-- @param t table
-- @param path string e.g. "user.profile.name"
-- @return value or nil if any intermediate is missing
function M.get(t, path)
  local parts = parse_path(path)
  local cur = t
  for i = 1, #parts do
    if type(cur) ~= "table" then return nil end
    cur = cur[parts[i]]
  end
  return cur
end

--- Set value at dot-notation path, creating intermediate tables as needed.
-- @param t table
-- @param path string
-- @param v any
function M.set(t, path, v)
  local parts = parse_path(path)
  if #parts == 0 then return end
  local cur = t
  for i = 1, #parts - 1 do
    local k = parts[i]
    if type(cur[k]) ~= "table" then
      cur[k] = {}
    end
    cur = cur[k]
  end
  cur[parts[#parts]] = v
end

--- Delete key at dot-notation path. Returns old value.
-- @param t table
-- @param path string
-- @return old value
function M.delete(t, path)
  local parts = parse_path(path)
  if #parts == 0 then return nil end
  local cur = t
  for i = 1, #parts - 1 do
    if type(cur) ~= "table" then return nil end
    cur = cur[parts[i]]
  end
  if type(cur) ~= "table" then return nil end
  local k = parts[#parts]
  local old = cur[k]
  cur[k] = nil
  return old
end

-- ─── flatten / unflatten ───────────────────────────────────────────────────

--- Flatten a nested table to flat path-keyed table.
-- @param t table
-- @return flat table {"user.name"="Alice", "user.age"=30}
function M.flatten(t)
  local result = {}

  local function _flatten(x, prefix)
    if type(x) ~= "table" then
      result[prefix] = x
      return
    end
    local empty = true
    for k, v in pairs(x) do
      empty = false
      local key
      if type(k) == "number" then
        key = prefix == "" and ("[" .. k .. "]") or (prefix .. "[" .. k .. "]")
      else
        key = prefix == "" and tostring(k) or (prefix .. "." .. tostring(k))
      end
      _flatten(v, key)
    end
    if empty and prefix ~= "" then
      result[prefix] = x -- preserve empty tables
    end
  end

  _flatten(t, "")
  return result
end

--- Unflatten a flat path-keyed table to nested table.
-- @param t flat table
-- @return nested table
function M.unflatten(t)
  local result = {}
  for path, v in pairs(t) do
    M.set(result, path, v)
  end
  return result
end

-- ─── keys / values / entries ───────────────────────────────────────────────

--- Return sorted array of table keys.
-- @param t table
-- @return array of keys
function M.keys(t)
  local ks = {}
  for k in pairs(t) do
    ks[#ks + 1] = k
  end
  table.sort(ks, function(a, b)
    if type(a) == type(b) then return tostring(a) < tostring(b) end
    return type(a) < type(b)
  end)
  return ks
end

--- Return array of values in key-sorted order.
-- @param t table
-- @return array of values
function M.values(t)
  local ks = M.keys(t)
  local vs = {}
  for i = 1, #ks do
    vs[i] = t[ks[i]]
  end
  return vs
end

--- Return array of {key, value} pairs sorted by key.
-- @param t table
-- @return array of {key, value}
function M.entries(t)
  local ks = M.keys(t)
  local es = {}
  for i = 1, #ks do
    es[i] = { ks[i], t[ks[i]] }
  end
  return es
end

-- ─── pick / omit ───────────────────────────────────────────────────────────

--- Create a table containing only the specified keys.
-- @param t table
-- @param keys array of keys
-- @return subset table
function M.pick(t, keys)
  local result = {}
  for i = 1, #keys do
    local k = keys[i]
    if t[k] ~= nil then
      result[k] = t[k]
    end
  end
  return result
end

--- Create a table excluding the specified keys.
-- @param t table
-- @param keys array of keys to exclude
-- @return table without those keys
function M.omit(t, keys)
  local excluded = {}
  for i = 1, #keys do
    excluded[keys[i]] = true
  end
  local result = {}
  for k, v in pairs(t) do
    if not excluded[k] then
      result[k] = v
    end
  end
  return result
end

return M
