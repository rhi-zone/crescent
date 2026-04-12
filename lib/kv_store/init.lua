-- lib/kv_store/init.lua
-- In-memory key-value store with TTL expiry, namespaces, and iteration.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ── internal helpers ──────────────────────────────────────────────────────────

local function now(store)
  return store._clock()
end

-- Check if a key is expired. Returns true if expired (and deletes it).
local function is_expired(store, key)
  local exp = store._expiry[key]
  if exp == nil then return false end
  if now(store) >= exp then
    local v = store._data[key]
    store._data[key]   = nil
    store._expiry[key] = nil
    -- fire on_del callbacks
    for _, cb in ipairs(store._on_del) do cb(key) end
    return true, v
  end
  return false
end

-- ── store methods ─────────────────────────────────────────────────────────────

local Store = {}
Store.__index = Store

function Store:set(key, value, opts)
  self._data[key] = value
  if opts and opts.ttl then
    self._expiry[key] = now(self) + opts.ttl
  else
    -- preserve existing expiry only if caller didn't pass opts at all;
    -- if opts={} (no ttl key), clear any existing expiry
    if opts ~= nil then
      self._expiry[key] = nil
    end
    -- opts == nil: no change to expiry (pure set without touching TTL)
  end
  for _, cb in ipairs(self._on_set) do cb(key, value) end
end

function Store:get(key)
  local expired = is_expired(self, key)
  if expired then return nil end
  return self._data[key]
end

function Store:has(key)
  local expired = is_expired(self, key)
  if expired then return false end
  return self._data[key] ~= nil
end

function Store:delete(key)
  if self._data[key] == nil then return false end
  -- still fire even if expired check happens to clear it
  is_expired(self, key)
  if self._data[key] == nil then
    -- was just expired-deleted; treat as existed but now gone
    return true
  end
  self._data[key]   = nil
  self._expiry[key] = nil
  for _, cb in ipairs(self._on_del) do cb(key) end
  return true
end

function Store:set_many(tbl, opts)
  for k, v in pairs(tbl) do
    self:set(k, v, opts)
  end
end

function Store:get_many(keys)
  local result = {}
  for _, k in ipairs(keys) do
    result[k] = self:get(k)
  end
  return result
end

function Store:expire(key, seconds)
  if self._data[key] == nil then return false end
  local expired = is_expired(self, key)
  if expired then return false end
  self._expiry[key] = now(self) + seconds
  return true
end

function Store:ttl(key)
  local expired = is_expired(self, key)
  if expired then return nil end
  if self._data[key] == nil then return nil end
  local exp = self._expiry[key]
  if exp == nil then return nil end
  local remaining = exp - now(self)
  if remaining < 0 then return 0 end
  return remaining
end

function Store:persist(key)
  if self._data[key] == nil then return false end
  local expired = is_expired(self, key)
  if expired then return false end
  if self._expiry[key] == nil then return false end
  self._expiry[key] = nil
  return true
end

function Store:incr(key, n)
  n = n or 1
  local expired = is_expired(self, key)
  local val = self._data[key]
  if expired or val == nil then
    val = 0
  end
  if type(val) ~= "number" then
    return nil, "value is not a number"
  end
  local new = val + n
  -- preserve TTL on incr (pass nil opts so existing expiry is unchanged)
  self._data[key] = new
  for _, cb in ipairs(self._on_set) do cb(key, new) end
  return new
end

function Store:decr(key, n)
  n = n or 1
  return self:incr(key, -n)
end

function Store:keys()
  local result = {}
  for k in pairs(self._data) do
    if not is_expired(self, k) then
      result[#result + 1] = k
    end
  end
  return result
end

function Store:values()
  local result = {}
  for k, v in pairs(self._data) do
    if not is_expired(self, k) then
      result[#result + 1] = v
    end
  end
  return result
end

function Store:size()
  local count = 0
  for k in pairs(self._data) do
    if not is_expired(self, k) then
      count = count + 1
    end
  end
  return count
end

function Store:clear()
  -- fire on_del for each key
  for k in pairs(self._data) do
    for _, cb in ipairs(self._on_del) do cb(k) end
  end
  self._data   = {}
  self._expiry = {}
end

function Store:each(fn)
  -- collect keys first to avoid iterator invalidation from is_expired deletes
  local snapshot = {}
  for k in pairs(self._data) do
    snapshot[#snapshot + 1] = k
  end
  for _, k in ipairs(snapshot) do
    if not is_expired(self, k) then
      fn(k, self._data[k])
    end
  end
end

function Store:namespace(prefix)
  local ns = {}
  local sep = ":"
  local full_prefix = prefix .. sep

  function ns:set(key, value, opts)
    return self._store:set(full_prefix .. key, value, opts)
  end
  function ns:get(key)
    return self._store:get(full_prefix .. key)
  end
  function ns:has(key)
    return self._store:has(full_prefix .. key)
  end
  function ns:delete(key)
    return self._store:delete(full_prefix .. key)
  end
  function ns:set_many(tbl, opts)
    for k, v in pairs(tbl) do
      self._store:set(full_prefix .. k, v, opts)
    end
  end
  function ns:get_many(keys)
    local result = {}
    for _, k in ipairs(keys) do
      result[k] = self._store:get(full_prefix .. k)
    end
    return result
  end
  function ns:expire(key, seconds)
    return self._store:expire(full_prefix .. key, seconds)
  end
  function ns:ttl(key)
    return self._store:ttl(full_prefix .. key)
  end
  function ns:persist(key)
    return self._store:persist(full_prefix .. key)
  end
  function ns:incr(key, n)
    return self._store:incr(full_prefix .. key, n)
  end
  function ns:decr(key, n)
    return self._store:decr(full_prefix .. key, n)
  end
  function ns:keys()
    local result = {}
    local store_keys = self._store:keys()
    local plen = #full_prefix
    for _, k in ipairs(store_keys) do
      if k:sub(1, plen) == full_prefix then
        result[#result + 1] = k:sub(plen + 1)
      end
    end
    return result
  end
  function ns:values()
    local result = {}
    local plen = #full_prefix
    local store_keys = self._store:keys()
    for _, k in ipairs(store_keys) do
      if k:sub(1, plen) == full_prefix then
        result[#result + 1] = self._store:get(k)
      end
    end
    return result
  end
  function ns:size()
    local count = 0
    local plen = #full_prefix
    local store_keys = self._store:keys()
    for _, k in ipairs(store_keys) do
      if k:sub(1, plen) == full_prefix then
        count = count + 1
      end
    end
    return count
  end
  function ns:clear()
    local plen = #full_prefix
    local store_keys = self._store:keys()
    for _, k in ipairs(store_keys) do
      if k:sub(1, plen) == full_prefix then
        self._store:delete(k)
      end
    end
  end
  function ns:each(fn)
    local plen = #full_prefix
    local store_keys = self._store:keys()
    for _, k in ipairs(store_keys) do
      if k:sub(1, plen) == full_prefix then
        fn(k:sub(plen + 1), self._store:get(k))
      end
    end
  end
  function ns:on_set(fn)
    return self._store:on_set(function(k, v)
      if k:sub(1, #full_prefix) == full_prefix then
        fn(k:sub(#full_prefix + 1), v)
      end
    end)
  end
  function ns:on_del(fn)
    return self._store:on_del(function(k)
      if k:sub(1, #full_prefix) == full_prefix then
        fn(k:sub(#full_prefix + 1))
      end
    end)
  end
  function ns:namespace(sub_prefix)
    return self._store:namespace(full_prefix .. sub_prefix)
  end

  ns._store = self
  return ns
end

function Store:on_set(fn)
  self._on_set[#self._on_set + 1] = fn
end

function Store:on_del(fn)
  self._on_del[#self._on_del + 1] = fn
end

-- ── constructor ───────────────────────────────────────────────────────────────

function M.new(opts)
  opts = opts or {}
  local store = setmetatable({
    _data    = {},
    _expiry  = {},
    _on_set  = {},
    _on_del  = {},
    _clock   = opts.clock or os.time,
  }, Store)
  return store
end

return M
