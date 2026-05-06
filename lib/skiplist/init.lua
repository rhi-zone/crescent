if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Skip list: O(log n) average insert/delete/search with order statistics.
-- Implements an augmented skip list with span[] arrays for O(log n) rank queries.
-- Max level 32 supports ~2^32 elements at p=0.5.

local M = {}
--: string
M._tier = "pure"

--:: SLNode = { key: any, value: any, forward: { [integer]: SLNode }, span: { [integer]: integer }, level: integer }
--:: Skiplist = { _header: SLNode, _tail: SLNode, _cmp: (any, any) -> boolean, _level: integer, _size: integer }

local MAX_LEVEL = 32
local P = 0.5  -- coin-flip probability

-- Generate a random level using geometric distribution.
local function random_level()
  local level = 1
  while level < MAX_LEVEL and math.random() < P do
    level = level + 1
  end
  return level
end

-- Create a new node.
-- forward[i] = next node at level i (1-indexed)
-- span[i] = number of nodes skipped at level i (for rank queries)
--: (any, any, integer) -> SLNode
local function new_node(key, value, level)
  --: { [integer]: SLNode }
  local fwd = {} --[[:! { [integer]: SLNode }]]
  --: { [integer]: integer }
  local span = {}
  for i = 1, level do
    span[i] = 0
  end
  return { key = key, value = value, forward = fwd, span = span, level = level }
end

-- Skiplist metatable and methods
local SL = {}
SL.__index = SL

-- Create a new skip list.
-- seed: required RNG seed for level generation.
-- cmp(a, b) returns true when a should come before b (default: a < b)
function M.new(seed, cmp)
  if not seed then error("skiplist.new: seed is required") end
  math.randomseed(seed)
  --: (any, any) -> boolean
  local cmp_ = cmp or function(a, b) return a < b end
  -- Header sentinel: key = -math.huge, forward array of MAX_LEVEL nils
  local header = new_node(-math.huge, nil, MAX_LEVEL)
  -- tail sentinel: key = math.huge
  local tail = new_node(math.huge, nil, MAX_LEVEL)
  for i = 1, MAX_LEVEL do
    header.forward[i] = tail
    header.span[i] = 1  -- header→tail spans 1 position (the tail itself)
  end
  local sl = setmetatable({
    _header = header,
    _tail = tail,
    _cmp = cmp_,
    _level = 1,  -- current max level in use
    _size = 0,
  }, SL) --[[:! Skiplist]]
  return sl
end

-- Internal: find predecessors at each level for a given key.
-- Returns: update[] (predecessor nodes), rank[] (cumulative rank of each predecessor)
--: (Skiplist, any) -> ({ [integer]: SLNode }, { [integer]: integer })
local function find_update(sl, key)
  local cmp = sl._cmp
  --: { [integer]: SLNode }
  local update = {}
  --: { [integer]: integer }
  local rank = {}
  local x = sl._header
  local r = 0
  for i = sl._level, 1, -1 do
    rank[i] = (i == sl._level) and 0 or rank[i + 1]
    local xfi = x.forward[i]
    while xfi ~= sl._tail and cmp(xfi.key, key) do
      r = r + x.span[i]
      rank[i] = rank[i] + x.span[i]
      x = xfi
      xfi = x.forward[i]
    end
    update[i] = x
  end
  return update, rank
end

-- Insert a key/value pair. If key already exists, update its value.
--: (Skiplist, any, any) -> Skiplist
function SL:insert(key, value)
  local cmp = self._cmp
  local update, rank = find_update(self, key)

  -- Check if key already exists at level 1
  local next1 = update[1].forward[1]
  if next1 ~= self._tail and next1.key == key then
    next1.value = value
    return self
  end

  local lvl = random_level()
  if lvl > self._level then
    -- Extend update and rank arrays for new levels
    for i = self._level + 1, lvl do
      update[i] = self._header
      rank[i] = 0
    end
    self._level = lvl
  end

  local node = new_node(key, value, lvl)
  for i = 1, lvl do
    node.forward[i] = update[i].forward[i]
    update[i].forward[i] = node
    -- span of node at level i = span of predecessor at level i - (rank of pred - rank of node pred)
    local pred_span = update[i].span[i]
    local node_rank = rank[1] + 1  -- 1-based rank of the new node
    local pred_rank = rank[i]       -- rank of predecessor up to level i
    -- nodes skipped from node to node.forward[i] at level i
    node.span[i] = pred_span - (node_rank - pred_rank - 1)
    update[i].span[i] = node_rank - pred_rank
  end

  -- For levels above lvl, increment span of predecessors (new node inserted below)
  for i = lvl + 1, self._level do
    update[i].span[i] = update[i].span[i] + 1
  end

  self._size = self._size + 1
  return self
end

-- Delete a key. Returns true if found and deleted, false if not found.
--: (Skiplist, any) -> boolean
function SL:delete(key)
  local update, _ = find_update(self, key)
  local x = update[1].forward[1]

  if x == self._tail or x.key ~= key then
    return false
  end

  for i = 1, self._level do
    if update[i].forward[i] ~= x then break end
    -- Merge x's span into predecessor
    update[i].span[i] = update[i].span[i] + x.span[i] - 1
    update[i].forward[i] = x.forward[i]
  end

  -- For levels above x.level where x is not in the list, just decrement span
  for i = x.level + 1, self._level do
    if update[i].forward[i] ~= x then
      update[i].span[i] = update[i].span[i] - 1
    end
  end

  -- Shrink level if needed
  while self._level > 1 and self._header.forward[self._level] == self._tail do
    self._level = self._level - 1
  end

  self._size = self._size - 1
  return true
end

-- Get value for key, or nil if not found.
--: (Skiplist, any) -> any
function SL:get(key)
  local cmp = self._cmp
  local x = self._header
  for i = self._level, 1, -1 do
    local xfi = x.forward[i]
    while xfi ~= self._tail and cmp(xfi.key, key) do
      x = xfi
      xfi = x.forward[i]
    end
  end
  x = x.forward[1]
  if x ~= self._tail and x.key == key then
    return x.value
  end
  return nil
end

-- Returns true if key is present.
--: (Skiplist, any) -> boolean
function SL:has(key)
  local cmp = self._cmp
  local x = self._header
  for i = self._level, 1, -1 do
    local xfi = x.forward[i]
    while xfi ~= self._tail and cmp(xfi.key, key) do
      x = xfi
      xfi = x.forward[i]
    end
  end
  x = x.forward[1]
  if x ~= self._tail and x.key == key then return true end
  return false
end

-- Minimum key (nil if empty).
--: (Skiplist) -> any
function SL:min()
  local x = self._header.forward[1]
  if x == self._tail then return nil end
  return x.key
end

-- Maximum key (nil if empty).
--: (Skiplist) -> any
function SL:max()
  -- Walk forward at each level greedily
  local x = self._header
  for i = self._level, 1, -1 do
    local xfi = x.forward[i]
    while xfi ~= self._tail do
      x = xfi
      xfi = x.forward[i]
    end
  end
  if x == self._header then return nil end
  return x.key
end

-- Number of elements.
--: (Skiplist) -> integer
function SL:size()
  return self._size
end

-- Iterator over all (key, value) pairs in sorted order.
--: (Skiplist) -> () -> (any, any) | nil
function SL:iter()
  local x = self._header.forward[1]
  local tail = self._tail
  return function()
    if x == tail then return nil end
    local k, v = x.key, x.value
    x = x.forward[1]
    return k, v
  end
end

-- Return sorted array of all keys.
--: (Skiplist) -> { [integer]: any }
function SL:keys()
  local t = {}
  local x = self._header.forward[1]
  local tail = self._tail
  while x ~= tail do
    t[#t + 1] = x.key
    x = x.forward[1]
  end
  return t
end

-- Return values in key-sorted order.
--: (Skiplist) -> { [integer]: any }
function SL:values()
  local t = {}
  local x = self._header.forward[1]
  local tail = self._tail
  while x ~= tail do
    t[#t + 1] = x.value
    x = x.forward[1]
  end
  return t
end

-- Return array of {key, value} pairs in sorted order.
--: (Skiplist) -> { [integer]: { key: any, value: any } }
function SL:pairs()
  local t = {}
  local x = self._header.forward[1]
  local tail = self._tail
  while x ~= tail do
    t[#t + 1] = { key = x.key, value = x.value }
    x = x.forward[1]
  end
  return t
end

-- Range query: return array of {key, value} with lo <= key <= hi.
-- Uses the comparator: lo <= key means not(key < lo) and not(hi < key).
--: (Skiplist, any, any) -> { [integer]: { key: any, value: any } }
function SL:range(lo, hi)
  local cmp = self._cmp
  local result = {}
  -- Find first node with key >= lo: advance while key < lo
  local x = self._header
  for i = self._level, 1, -1 do
    local xfi = x.forward[i]
    while xfi ~= self._tail and cmp(xfi.key, lo) do
      x = xfi
      xfi = x.forward[i]
    end
  end
  x = x.forward[1]
  local tail = self._tail
  -- Iterate while key <= hi (i.e. not(hi < key))
  while x ~= tail and not cmp(hi, x.key) do
    result[#result + 1] = { key = x.key, value = x.value }
    x = x.forward[1]
  end
  return result
end

-- Range query: return just the keys with lo <= key <= hi.
--: (Skiplist, any, any) -> { [integer]: any }
function SL:range_keys(lo, hi)
  local cmp = self._cmp
  local result = {}
  local x = self._header
  for i = self._level, 1, -1 do
    local xfi = x.forward[i]
    while xfi ~= self._tail and cmp(xfi.key, lo) do
      x = xfi
      xfi = x.forward[i]
    end
  end
  x = x.forward[1]
  local tail = self._tail
  while x ~= tail and not cmp(hi, x.key) do
    result[#result + 1] = x.key
    x = x.forward[1]
  end
  return result
end

-- Rank: 1-based position of key in sorted order. Returns nil if not found.
--: (Skiplist, any) -> integer | nil
function SL:rank(key)
  local cmp = self._cmp
  local x = self._header
  local r = 0
  for i = self._level, 1, -1 do
    local xfi = x.forward[i]
    while xfi ~= self._tail and cmp(xfi.key, key) do
      r = r + x.span[i]
      x = xfi
      xfi = x.forward[i]
    end
  end
  x = x.forward[1]
  if x ~= self._tail and x.key == key then
    return r + 1
  end
  return nil
end

-- at_rank: return {key, value} at 1-based rank position. Returns nil if out of range.
--: (Skiplist, integer) -> { key: any, value: any } | nil
function SL:at_rank(pos)
  if pos < 1 or pos > self._size then return nil end
  local x = self._header
  local traversed = 0
  for i = self._level, 1, -1 do
    local xfi = x.forward[i]
    while xfi ~= self._tail and traversed + x.span[i] < pos do
      traversed = traversed + x.span[i]
      x = xfi
      xfi = x.forward[i]
    end
  end
  x = x.forward[1]
  if x == self._tail then return nil end
  return { key = x.key, value = x.value }
end

-- Predecessor: largest key strictly less than the given key.
-- Returns {key, value} or nil if no such key exists.
--: (Skiplist, any) -> { key: any, value: any } | nil
function SL:pred(key)
  local cmp = self._cmp
  local x = self._header
  for i = self._level, 1, -1 do
    local xfi = x.forward[i]
    while xfi ~= self._tail and cmp(xfi.key, key) do
      x = xfi
      xfi = x.forward[i]
    end
  end
  if x == self._header then return nil end
  return { key = x.key, value = x.value }
end

-- Successor: smallest key strictly greater than the given key.
-- Returns {key, value} or nil if no such key exists.
--: (Skiplist, any) -> { key: any, value: any } | nil
function SL:succ(key)
  local cmp = self._cmp
  local x = self._header
  for i = self._level, 1, -1 do
    local xfi = x.forward[i]
    while xfi ~= self._tail and cmp(xfi.key, key) do
      x = xfi
      xfi = x.forward[i]
    end
  end
  -- x is the last node with key < given key; x.forward[1] has key >= given key
  -- We need key strictly greater, so skip equal keys
  x = x.forward[1]
  while x ~= self._tail and x.key == key do
    x = x.forward[1]
  end
  if x == self._tail then return nil end
  return { key = x.key, value = x.value }
end

-- Floor: largest key <= the given key.
-- Returns {key, value} or nil if no such key exists.
--: (Skiplist, any) -> { key: any, value: any } | nil
function SL:floor(key)
  local cmp = self._cmp
  local x = self._header
  for i = self._level, 1, -1 do
    local xfi = x.forward[i]
    while xfi ~= self._tail and cmp(xfi.key, key) do
      x = xfi
      xfi = x.forward[i]
    end
  end
  -- x is the last node strictly less than key; check if x.forward[1] == key
  local candidate = x.forward[1]
  if candidate ~= self._tail and candidate.key == key then
    return { key = candidate.key, value = candidate.value }
  end
  if x == self._header then return nil end
  return { key = x.key, value = x.value }
end

-- Ceil: smallest key >= the given key.
-- Returns {key, value} or nil if no such key exists.
--: (Skiplist, any) -> { key: any, value: any } | nil
function SL:ceil(key)
  local cmp = self._cmp
  local x = self._header
  for i = self._level, 1, -1 do
    local xfi = x.forward[i]
    while xfi ~= self._tail and cmp(xfi.key, key) do
      x = xfi
      xfi = x.forward[i]
    end
  end
  x = x.forward[1]
  if x == self._tail then return nil end
  return { key = x.key, value = x.value }
end

return M
