if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: Heap = {
--::   _data: { [integer]: unknown },
--::   _n: integer,
--::   _cmp: (unknown, unknown) -> boolean,
--::   _keyed: boolean,
--::   _index: { [unknown]: integer } | nil,
--::   push: (Heap, unknown, number | nil) -> nil,
--::   peek: (Heap) -> unknown | nil,
--::   peek_priority: (Heap) -> number | nil,
--::   pop: (Heap) -> unknown | nil,
--::   size: (Heap) -> number,
--::   empty: (Heap) -> boolean,
--::   clear: (Heap) -> nil,
--::   drain: (Heap) -> () -> unknown | nil,
--::   to_sorted_array: (Heap) -> { [integer]: unknown },
--::   push_or_update: (Heap, unknown, number) -> nil,
--::   remove: (Heap, unknown) -> boolean,
--:: }

-- Heap metatable
local Heap = {}
Heap.__index = Heap

-- Internal: compare function for min-heap
local function min_cmp(a, b) return a < b end
-- Internal: compare function for max-heap
local function max_cmp(a, b) return a > b end

-- Internal: sift up element at position i
local function sift_up(data, cmp, i)
  while i > 1 do
    local parent = (i - i % 2) / 2
    if cmp(data[i], data[parent]) then
      data[i], data[parent] = data[parent], data[i]
      i = parent
    else
      break
    end
  end
end

-- Internal: sift down element at position i
local function sift_down(data, cmp, i, n)
  while true do
    local smallest = i
    local left = 2 * i
    local right = 2 * i + 1
    if left <= n and cmp(data[left], data[smallest]) then
      smallest = left
    end
    if right <= n and cmp(data[right], data[smallest]) then
      smallest = right
    end
    if smallest == i then break end
    data[i], data[smallest] = data[smallest], data[i]
    i = smallest
  end
end

-- Internal: heapify an array in-place, O(n)
local function heapify(data, cmp)
  local n = #data
  for i = (n - n % 2) / 2, 1, -1 do
    sift_down(data, cmp, i, n)
  end
end

-- Internal: sift up for keyed heap (separate priority mode)
local function sift_up_keyed(data, cmp, index, i)
  while i > 1 do
    local parent = (i - i % 2) / 2
    if cmp(data[i][2], data[parent][2]) then
      data[i], data[parent] = data[parent], data[i]
      index[data[i][1]] = i
      index[data[parent][1]] = parent
      i = parent
    else
      break
    end
  end
end

-- Internal: sift down for keyed heap
local function sift_down_keyed(data, cmp, index, i, n)
  while true do
    local smallest = i
    local left = 2 * i
    local right = 2 * i + 1
    if left <= n and cmp(data[left][2], data[smallest][2]) then
      smallest = left
    end
    if right <= n and cmp(data[right][2], data[smallest][2]) then
      smallest = right
    end
    if smallest == i then break end
    data[i], data[smallest] = data[smallest], data[i]
    index[data[i][1]] = i
    index[data[smallest][1]] = smallest
    i = smallest
  end
end

--- Create a new heap.
--: (mode: "min" | "max" | (a: unknown, b: unknown) -> boolean) -> Heap
function M.new(mode)
  local cmp
  if type(mode) == "function" then
    cmp = mode
  elseif mode == "max" then
    cmp = max_cmp
  else
    cmp = min_cmp
  end
  return setmetatable({
    _data = {},
    _n = 0,
    _cmp = cmp,
    _keyed = false,
    _index = nil,
  }, Heap)
end

--- Build a heap from an array using O(n) heapify.
--: (arr: {unknown}, mode: "min" | "max" | (a: unknown, b: unknown) -> boolean) -> Heap
function M.from_array(arr, mode)
  local cmp
  if type(mode) == "function" then
    cmp = mode
  elseif mode == "max" then
    cmp = max_cmp
  else
    cmp = min_cmp
  end
  -- Copy the array
  local data = {}
  local n = #arr
  for i = 1, n do
    data[i] = arr[i]
  end
  heapify(data, cmp)
  return setmetatable({
    _data = data,
    _n = n,
    _cmp = cmp,
    _keyed = false,
    _index = nil,
  }, Heap)
end

--- Push a value onto the heap.
--- If priority is given, switches to keyed mode (separate priority).
--: (self: Heap, value: unknown, priority: number | nil) -> nil
function Heap:push(value, priority)
  if priority ~= nil then
    -- Keyed mode
    if not self._keyed then
      -- Convert to keyed mode if there are existing elements
      if self._n > 0 then
        return nil, "cannot mix keyed and unkeyed push on the same heap"
      end
      self._keyed = true
      self._index = {}
    end
    if self._index[value] then
      return nil, "duplicate key; use push_or_update to update existing keys"
    end
    self._n = self._n + 1
    local i = self._n
    self._data[i] = { value, priority }
    self._index[value] = i
    sift_up_keyed(self._data, self._cmp, self._index, i)
  else
    -- Simple mode
    if self._keyed then
      return nil, "cannot mix keyed and unkeyed push on the same heap"
    end
    self._n = self._n + 1
    local i = self._n
    self._data[i] = value
    sift_up(self._data, self._cmp, i)
  end
end

--- Peek at the top element without removing it.
--: (self: Heap) -> unknown | nil
function Heap:peek()
  if self._n == 0 then return nil end
  if self._keyed then
    return self._data[1][1]
  end
  return self._data[1]
end

--- Peek at the top element's priority (keyed mode only).
--: (self: Heap) -> number | nil
function Heap:peek_priority()
  if self._n == 0 or not self._keyed then return nil end
  return self._data[1][2]
end

--- Pop the top element from the heap.
--: (self: Heap) -> unknown | nil
function Heap:pop()
  if self._n == 0 then return nil end
  local data = self._data
  local n = self._n
  if self._keyed then
    local top = data[1]
    self._index[top[1]] = nil
    if n == 1 then
      data[1] = nil
      self._n = 0
      return top[1]
    end
    data[1] = data[n]
    data[n] = nil
    self._n = n - 1
    self._index[data[1][1]] = 1
    sift_down_keyed(data, self._cmp, self._index, 1, self._n)
    return top[1]
  else
    local top = data[1]
    if n == 1 then
      data[1] = nil
      self._n = 0
      return top
    end
    data[1] = data[n]
    data[n] = nil
    self._n = n - 1
    sift_down(data, self._cmp, 1, self._n)
    return top
  end
end

--- Return the number of elements.
--: (self: Heap) -> number
function Heap:size()
  return self._n
end

--- Return true if the heap is empty.
--: (self: Heap) -> boolean
function Heap:empty()
  return self._n == 0
end

--- Remove all elements.
--: (self: Heap) -> nil
function Heap:clear()
  self._data = {}
  self._n = 0
  if self._keyed then
    self._index = {}
  end
end

--- Drain iterator: yields elements in priority order (destructive).
--: (self: Heap) -> () -> unknown | nil
function Heap:drain()
  return function()
    if self._n == 0 then return nil end
    return self:pop()
  end
end

--- Return a sorted array of all elements (non-destructive).
--: (self: Heap) -> {unknown}
function Heap:to_sorted_array()
  -- Copy the heap, then drain it
  local result = {}
  local data = self._data
  local n = self._n
  local cmp = self._cmp
  if self._keyed then
    -- Copy keyed data
    local copy = {}
    local copy_index = {}
    for i = 1, n do
      copy[i] = { data[i][1], data[i][2] }
      copy_index[copy[i][1]] = i
    end
    local tmp = setmetatable({
      _data = copy,
      _n = n,
      _cmp = cmp,
      _keyed = true,
      _index = copy_index,
    }, Heap)
    for val in tmp:drain() do
      result[#result + 1] = val
    end
  else
    local copy = {}
    for i = 1, n do copy[i] = data[i] end
    local tmp = setmetatable({
      _data = copy,
      _n = n,
      _cmp = cmp,
      _keyed = false,
      _index = nil,
    }, Heap)
    for val in tmp:drain() do
      result[#result + 1] = val
    end
  end
  return result
end

--- Push or update: if key exists, update its priority; otherwise push.
--: (self: Heap, key: unknown, priority: number) -> nil
function Heap:push_or_update(key, priority)
  if not self._keyed then
    if self._n > 0 then
      return nil, "cannot use push_or_update on a non-keyed heap with existing elements"
    end
    self._keyed = true
    self._index = {}
  end
  local idx = self._index[key]
  if idx then
    -- Update existing
    local old_priority = self._data[idx][2]
    self._data[idx][2] = priority
    -- Re-heapify: could go up or down
    if self._cmp(priority, old_priority) then
      sift_up_keyed(self._data, self._cmp, self._index, idx)
    else
      sift_down_keyed(self._data, self._cmp, self._index, idx, self._n)
    end
  else
    -- Insert new
    self._n = self._n + 1
    local i = self._n
    self._data[i] = { key, priority }
    self._index[key] = i
    sift_up_keyed(self._data, self._cmp, self._index, i)
  end
end

--- Remove a key from a keyed heap.
--: (self: Heap, key: unknown) -> boolean
function Heap:remove(key)
  if not self._keyed or not self._index then
    return nil, "remove requires a keyed heap"
  end
  local idx = self._index[key]
  if not idx then
    return false
  end
  local data = self._data
  local n = self._n
  self._index[key] = nil
  if idx == n then
    data[n] = nil
    self._n = n - 1
    return true
  end
  -- Move last element to the removed position
  data[idx] = data[n]
  data[n] = nil
  self._n = n - 1
  self._index[data[idx][1]] = idx
  -- Re-heapify
  sift_up_keyed(data, self._cmp, self._index, idx)
  sift_down_keyed(data, self._cmp, self._index, idx, self._n)
  return true
end

--- Merge two heaps into a new heap. Both must be the same mode (keyed or unkeyed).
--: (h1: Heap, h2: Heap) -> Heap
function M.merge(h1, h2)
  if h1._keyed or h2._keyed then
    return nil, "merge is not supported for keyed heaps"
  end
  local cmp = h1._cmp
  local data = {}
  local n = 0
  for i = 1, h1._n do
    n = n + 1
    data[n] = h1._data[i]
  end
  for i = 1, h2._n do
    n = n + 1
    data[n] = h2._data[i]
  end
  heapify(data, cmp)
  return setmetatable({
    _data = data,
    _n = n,
    _cmp = cmp,
    _keyed = false,
    _index = nil,
  }, Heap)
end

--- Heap sort: return a new sorted array.
--: (arr: {unknown}, direction: "asc" | "desc" | nil) -> {unknown}
function M.sort(arr, direction)
  local n = #arr
  if n <= 1 then
    local result = {}
    for i = 1, n do result[i] = arr[i] end
    return result
  end
  -- For ascending: build a max-heap, then extract from end
  -- For descending: build a min-heap, then extract from end
  local cmp
  if direction == "desc" then
    cmp = min_cmp
  else
    cmp = max_cmp
  end
  -- Copy
  local data = {}
  for i = 1, n do data[i] = arr[i] end
  -- Heapify
  heapify(data, cmp)
  -- Extract
  for i = n, 2, -1 do
    data[1], data[i] = data[i], data[1]
    sift_down(data, cmp, 1, i - 1)
  end
  return data
end

return M
