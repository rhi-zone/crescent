if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

-- Multiset (bag) — elements can appear multiple times.
-- Internal: counts[element] = count (only stored when count > 0)

local MT = {}
MT.__index = MT

-- Construction

function M.new()
  return setmetatable({ counts = {} }, MT)
end

function M.from(arr)
  local ms = M.new()
  for _, v in ipairs(arr) do
    MT.add(ms, v)
  end
  return ms
end

function M.from_counts(tbl)
  local ms = M.new()
  for k, n in pairs(tbl) do
    if n > 0 then
      ms.counts[k] = n
    end
  end
  return ms
end

-- Basic operations

function MT:add(elem, n)
  n = n or 1
  self.counts[elem] = (self.counts[elem] or 0) + n
end

function MT:remove(elem, n)
  n = n or 1
  local c = self.counts[elem]
  if not c then return end
  local new = c - n
  if new <= 0 then
    self.counts[elem] = nil
  else
    self.counts[elem] = new
  end
end

function MT:remove_all(elem)
  self.counts[elem] = nil
end

function MT:count(elem)
  return self.counts[elem] or 0
end

function MT:contains(elem)
  return (self.counts[elem] or 0) > 0
end

function MT:total()
  local sum = 0
  for _, c in pairs(self.counts) do
    sum = sum + c
  end
  return sum
end

function MT:distinct()
  local n = 0
  for _ in pairs(self.counts) do n = n + 1 end
  return n
end

function MT:is_empty()
  return next(self.counts) == nil
end

-- Iteration

function MT:elements()
  local result = {}
  for elem, c in pairs(self.counts) do
    for _ = 1, c do
      result[#result + 1] = elem
    end
  end
  table.sort(result, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return result
end

function MT:pairs()
  local result = {}
  for elem, c in pairs(self.counts) do
    result[#result + 1] = { elem, c }
  end
  return result
end

function MT:keys()
  local result = {}
  for elem in pairs(self.counts) do
    result[#result + 1] = elem
  end
  return result
end

-- Set-like operations (return new multisets)

function MT:union(other)
  local result = M.new()
  local seen = {}
  for elem, c in pairs(self.counts) do
    local oc = other.counts[elem] or 0
    result.counts[elem] = math.max(c, oc)
    seen[elem] = true
  end
  for elem, oc in pairs(other.counts) do
    if not seen[elem] then
      result.counts[elem] = oc
    end
  end
  return result
end

function MT:intersection(other)
  local result = M.new()
  for elem, c in pairs(self.counts) do
    local oc = other.counts[elem] or 0
    local m = math.min(c, oc)
    if m > 0 then
      result.counts[elem] = m
    end
  end
  return result
end

function MT:sum(other)
  local result = M.new()
  for elem, c in pairs(self.counts) do
    result.counts[elem] = c
  end
  for elem, oc in pairs(other.counts) do
    result.counts[elem] = (result.counts[elem] or 0) + oc
  end
  return result
end

function MT:difference(other)
  local result = M.new()
  for elem, c in pairs(self.counts) do
    local oc = other.counts[elem] or 0
    local d = c - oc
    if d > 0 then
      result.counts[elem] = d
    end
  end
  return result
end

function MT:scale(n)
  local result = M.new()
  if n <= 0 then return result end
  for elem, c in pairs(self.counts) do
    result.counts[elem] = c * n
  end
  return result
end

-- Predicates

function MT:subset(other)
  for elem, c in pairs(self.counts) do
    if c > (other.counts[elem] or 0) then return false end
  end
  return true
end

function MT:eq(other)
  for elem, c in pairs(self.counts) do
    if c ~= (other.counts[elem] or 0) then return false end
  end
  for elem, oc in pairs(other.counts) do
    if oc ~= (self.counts[elem] or 0) then return false end
  end
  return true
end

-- Conversion

function MT:to_set()
  local result = {}
  for elem in pairs(self.counts) do
    result[elem] = true
  end
  return result
end

function MT:to_counts()
  local result = {}
  for elem, c in pairs(self.counts) do
    result[elem] = c
  end
  return result
end

local function sort_by_count(a, b)
  return a[2] > b[2]
end

local function sort_by_count_asc(a, b)
  return a[2] < b[2]
end

function MT:most_common(n)
  local all = self:pairs()
  table.sort(all, sort_by_count)
  if n and n < #all then
    local result = {}
    for i = 1, n do result[i] = all[i] end
    return result
  end
  return all
end

function MT:least_common(n)
  local all = self:pairs()
  table.sort(all, sort_by_count_asc)
  if n and n < #all then
    local result = {}
    for i = 1, n do result[i] = all[i] end
    return result
  end
  return all
end

-- Functional

function MT:map(fn)
  local result = M.new()
  for elem, c in pairs(self.counts) do
    local new_elem = fn(elem)
    result.counts[new_elem] = (result.counts[new_elem] or 0) + c
  end
  return result
end

function MT:filter(fn)
  local result = M.new()
  for elem, c in pairs(self.counts) do
    if fn(elem, c) then
      result.counts[elem] = c
    end
  end
  return result
end

function MT:each(fn)
  for elem, c in pairs(self.counts) do
    fn(elem, c)
  end
end

return M
