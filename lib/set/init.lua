if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: Set = { _data: { [unknown]: boolean }, _size: integer }

local Set = {}
Set.__index = Set

--: (unknown) -> string
function Set:__tostring()
  local self_ = self --[[:! Set]]
  local parts = {} --: { [integer]: string }
  for v in pairs(self_._data) do
    parts[#parts + 1] = tostring(v) --[[:! string]]
  end
  table.sort(parts)
  return "Set{" .. table.concat(parts, ", ") .. "}"
end

--: () -> Set
function M.new()
  return setmetatable({ _data = {}, _size = 0 }, Set)
end

--: (unknown[]) -> Set
function M.from_array(arr)
  local s = M.new()
  for i = 1, #arr do
    Set.add(s, arr[i])
  end
  return s
end

--: (unknown) -> (nil, string | nil)
function Set:add(v)
  local self_ = self --[[:! Set]]
  if v == nil then return nil, "cannot add nil to set" end
  if not self_._data[v] then
    self_._data[v] = true
    self_._size = self_._size + 1
  end
end

--: (unknown) -> nil
function Set:remove(v)
  local self_ = self --[[:! Set]]
  if self_._data[v] then
    self_._data[v] = nil
    self_._size = self_._size - 1
  end
end

--: (unknown) -> boolean
function Set:has(v)
  local self_ = self --[[:! Set]]
  return self_._data[v] == true
end

--: () -> number
function Set:size()
  return self._size
end

--: () -> boolean
function Set:empty()
  return self._size == 0
end

--: () -> unknown[]
function Set:to_array()
  local arr = {}
  for v in pairs(self._data) do
    arr[#arr + 1] = v
  end
  return arr
end

--: () -> (unknown, { [unknown]: boolean }, nil)
function Set:values()
  return next, self._data, nil
end

--: (Set) -> Set
function Set:union(other)
  local self_ = self --[[:! Set]]
  local result = Set.copy(self_)
  for v in pairs(other._data) do
    Set.add(result, v)
  end
  return result
end

--: (Set) -> Set
function Set:intersection(other)
  local result = M.new()
  -- iterate over the smaller set for performance
  local a, b = self, other
  if self._size > other._size then
    a, b = other, self
  end
  for v in pairs(a._data) do
    if b._data[v] then
      result._data[v] = true
      result._size = result._size + 1
    end
  end
  return result
end

--: (Set) -> Set
function Set:difference(other)
  local result = M.new()
  for v in pairs(self._data) do
    if not other._data[v] then
      result._data[v] = true
      result._size = result._size + 1
    end
  end
  return result
end

--: (Set) -> Set
function Set:symmetric_difference(other)
  local result = M.new()
  for v in pairs(self._data) do
    if not other._data[v] then
      result._data[v] = true
      result._size = result._size + 1
    end
  end
  for v in pairs(other._data) do
    if not self._data[v] then
      result._data[v] = true
      result._size = result._size + 1
    end
  end
  return result
end

--: (Set) -> boolean
function Set:is_subset(other)
  if self._size > other._size then return false end
  for v in pairs(self._data) do
    if not other._data[v] then return false end
  end
  return true
end

--: (Set) -> boolean
function Set:is_superset(other)
  return other:is_subset(self)
end

--: (Set) -> boolean
function Set:is_disjoint(other)
  local a, b = self, other
  if self._size > other._size then
    a, b = other, self
  end
  for v in pairs(a._data) do
    if b._data[v] then return false end
  end
  return true
end

--: (Set) -> boolean
function Set:eq(other)
  if self._size ~= other._size then return false end
  for v in pairs(self._data) do
    if not other._data[v] then return false end
  end
  return true
end

--: (Set, (unknown) -> unknown) -> Set
function Set:map(fn)
  local self_ = self --[[:! Set]]
  local result = M.new()
  for v in pairs(self_._data) do
    Set.add(result, fn(v))
  end
  return result
end

--: (Set, (unknown) -> boolean) -> Set
function Set:filter(fn)
  local result = M.new()
  for v in pairs(self._data) do
    if fn(v) then
      result._data[v] = true
      result._size = result._size + 1
    end
  end
  return result
end

--: (Set, unknown, (unknown, unknown) -> unknown) -> unknown
function Set:reduce(init, fn)
  local self_ = self --[[:! Set]]
  local acc = init
  for v in pairs(self_._data) do
    acc = fn(acc, v)
  end
  return acc
end

--: ((unknown) -> nil) -> nil
function Set:for_each(fn)
  for v in pairs(self._data) do
    fn(v)
  end
end

--: () -> Set
function Set:copy()
  local self_ = self --[[:! Set]]
  local result = M.new()
  for v in pairs(self_._data) do
    result._data[v] = true
  end
  result._size = self_._size
  return result
end

--: () -> nil
function Set:clear()
  self._data = {}
  self._size = 0
end

-- module-level aliases
M.union = function(a, b) return a:union(b) end
M.intersection = function(a, b) return a:intersection(b) end
M.difference = function(a, b) return a:difference(b) end
M.symmetric_difference = function(a, b) return a:symmetric_difference(b) end

return M
