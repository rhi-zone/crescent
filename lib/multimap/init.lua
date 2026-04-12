if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local MM = {}
MM.__index = MM

-- Internal: insert into a list bucket
local function list_insert(bucket, v)
  bucket[#bucket + 1] = v
end

-- Internal: insert into a set bucket (no duplicates)
local function set_insert(bucket, v)
  for i = 1, #bucket do
    if bucket[i] == v then return false end
  end
  bucket[#bucket + 1] = v
  return true
end

-- Internal: insert into a sorted bucket (ascending)
local function sorted_insert(bucket, v)
  local lo, hi = 1, #bucket
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if bucket[mid] < v then
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  table.insert(bucket, lo, v)
end

-- Internal: remove first occurrence of v from bucket; returns true if removed
local function bucket_remove_one(bucket, v)
  for i = 1, #bucket do
    if bucket[i] == v then
      table.remove(bucket, i)
      return true
    end
  end
  return false
end

--: (string?) -> multimap
function M.new(mode)
  mode = mode or "list"
  return setmetatable({
    _data  = {},   -- key -> array of values
    _mode  = mode,
    _total = 0,    -- total value count across all keys
  }, MM)
end

--: (unknown, unknown) -> nil
function MM:put(k, v)
  local bucket = self._data[k]
  if not bucket then
    bucket = {}
    self._data[k] = bucket
  end
  local mode = self._mode
  if mode == "set" then
    local added = set_insert(bucket, v)
    if added then self._total = self._total + 1 end
  elseif mode == "sorted" then
    sorted_insert(bucket, v)
    self._total = self._total + 1
  else -- list
    list_insert(bucket, v)
    self._total = self._total + 1
  end
end

--: (unknown, unknown[]) -> nil
function MM:put_all(k, vals)
  for i = 1, #vals do
    self:put(k, vals[i])
  end
end

--: (unknown) -> unknown[]
function MM:get(k)
  local bucket = self._data[k]
  if not bucket then return {} end
  local copy = {}
  for i = 1, #bucket do copy[i] = bucket[i] end
  return copy
end

--: (unknown, unknown) -> boolean
function MM:has(k, v)
  local bucket = self._data[k]
  if not bucket then return false end
  for i = 1, #bucket do
    if bucket[i] == v then return true end
  end
  return false
end

--: (unknown) -> boolean
function MM:has_key(k)
  return self._data[k] ~= nil
end

--: (unknown, unknown) -> boolean
function MM:remove(k, v)
  local bucket = self._data[k]
  if not bucket then return false end
  local removed = bucket_remove_one(bucket, v)
  if removed then
    self._total = self._total - 1
    if #bucket == 0 then
      self._data[k] = nil
    end
  end
  return removed
end

--: (unknown) -> nil
function MM:remove_all(k)
  local bucket = self._data[k]
  if bucket then
    self._total = self._total - #bucket
    self._data[k] = nil
  end
end

-- Alias for remove_all
MM.delete_key = MM.remove_all

--: () -> unknown[]
function MM:keys()
  local ks = {}
  for k in pairs(self._data) do
    ks[#ks + 1] = k
  end
  return ks
end

--: () -> number
function MM:key_count()
  local n = 0
  for _ in pairs(self._data) do n = n + 1 end
  return n
end

--: () -> number
function MM:value_count()
  return self._total
end

--: (unknown) -> number
function MM:size(k)
  local bucket = self._data[k]
  if not bucket then return 0 end
  return #bucket
end

--: () -> () -> unknown, unknown | nil
function MM:each()
  local keys = self:keys()
  local ki = 1
  local bucket = self._data[keys[1]] or {}
  local vi = 0
  return function()
    while true do
      vi = vi + 1
      if vi <= #bucket then
        return keys[ki], bucket[vi]
      end
      ki = ki + 1
      if ki > #keys then return nil end
      bucket = self._data[keys[ki]] or {}
      vi = 0
    end
  end
end

--: () -> () -> unknown, unknown[] | nil
function MM:each_key()
  local keys = self:keys()
  local ki = 0
  return function()
    ki = ki + 1
    local k = keys[ki]
    if k == nil then return nil end
    return k, self:get(k)
  end
end

--: () -> { [unknown]: unknown[] }
function MM:to_table()
  local t = {}
  for k, bucket in pairs(self._data) do
    local copy = {}
    for i = 1, #bucket do copy[i] = bucket[i] end
    t[k] = copy
  end
  return t
end

--: () -> { unknown, unknown }[]
function MM:flatten()
  local pairs_list = {}
  for k, bucket in pairs(self._data) do
    for i = 1, #bucket do
      pairs_list[#pairs_list + 1] = { k, bucket[i] }
    end
  end
  return pairs_list
end

--: () -> multimap
function MM:invert()
  local inv = M.new(self._mode)
  for k, bucket in pairs(self._data) do
    for i = 1, #bucket do
      inv:put(bucket[i], k)
    end
  end
  return inv
end

--: () -> multimap
function MM:copy()
  local c = M.new(self._mode)
  for k, bucket in pairs(self._data) do
    local copy = {}
    for i = 1, #bucket do copy[i] = bucket[i] end
    c._data[k] = copy
    c._total = c._total + #copy
  end
  return c
end

--: ((unknown, unknown) -> unknown) -> multimap
function MM:map_values(fn)
  local result = M.new(self._mode)
  for k, bucket in pairs(self._data) do
    for i = 1, #bucket do
      result:put(k, fn(k, bucket[i]))
    end
  end
  return result
end

--: ((unknown, unknown) -> boolean) -> multimap
function MM:filter_values(pred)
  local result = M.new(self._mode)
  for k, bucket in pairs(self._data) do
    for i = 1, #bucket do
      if pred(k, bucket[i]) then
        result:put(k, bucket[i])
      end
    end
  end
  return result
end

--: (multimap, multimap) -> multimap
function M.merge(mm1, mm2)
  local result = mm1:copy()
  for k, bucket in pairs(mm2._data) do
    for i = 1, #bucket do
      result:put(k, bucket[i])
    end
  end
  return result
end

--: ({ [unknown]: unknown | unknown[] }) -> multimap
function M.from_table(t)
  local mm = M.new()
  for k, v in pairs(t) do
    if type(v) == "table" then
      for i = 1, #v do
        mm:put(k, v[i])
      end
    else
      mm:put(k, v)
    end
  end
  return mm
end

return M
