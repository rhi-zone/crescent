-- lib/queue/init.lua
-- Priority queue (binary min-heap), FIFO queue (growable ring buffer),
-- and fixed-capacity ring buffer. Pure Lua — no external dependencies.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local floor = math.floor

-- ---------------------------------------------------------------------------
-- Priority Queue (binary min-heap)
-- ---------------------------------------------------------------------------

-- Default comparator: min-heap (smaller values have higher priority)
local function default_cmp(a, b) return a < b end

local PQ = {}
PQ.__index = PQ

--- Push a value onto the heap.
function PQ:push(v)
  local heap = self._heap
  local n = self._size + 1
  heap[n] = v
  self._size = n
  -- Sift up
  local cmp = self._cmp
  local i = n
  while i > 1 do
    local parent = floor(i / 2)
    if cmp(heap[i], heap[parent]) then
      heap[i], heap[parent] = heap[parent], heap[i]
      i = parent
    else
      break
    end
  end
end

--- Push all values from an array onto the heap.
function PQ:push_all(arr)
  for i = 1, #arr do self:push(arr[i]) end
end

--- Remove and return the top (highest-priority) element. Returns nil if empty.
function PQ:pop()
  local n = self._size
  if n == 0 then return nil end
  local heap = self._heap
  local top  = heap[1]
  if n == 1 then
    heap[1] = nil
    self._size = 0
    return top
  end
  -- Move last element to root, then sift down
  heap[1]   = heap[n]
  heap[n]   = nil
  self._size = n - 1
  local size = self._size
  local cmp  = self._cmp
  local i = 1
  while true do
    local left  = 2 * i
    local right = 2 * i + 1
    local best  = i
    if left  <= size and cmp(heap[left],  heap[best]) then best = left  end
    if right <= size and cmp(heap[right], heap[best]) then best = right end
    if best == i then break end
    heap[i], heap[best] = heap[best], heap[i]
    i = best
  end
  return top
end

--- Return the top element without removing it. Returns nil if empty.
function PQ:peek()
  return self._heap[1]
end

--- Return the number of elements.
function PQ:size()
  return self._size
end

--- Return true if the heap is empty.
function PQ:is_empty()
  return self._size == 0
end

--- Create a new priority queue with an optional comparator.
-- The comparator `cmp(a, b)` should return true when `a` should be popped
-- before `b`. Default: `a < b` (min-heap, smallest value first).
function M.priority_new(cmp)
  return setmetatable({ _heap = {}, _size = 0, _cmp = cmp or default_cmp }, PQ)
end

--- Build a heap from an existing array in O(n) using Floyd's algorithm.
-- The source array is not modified. Returns a new heap.
function M.heapify(arr, cmp)
  local n    = #arr
  local heap = {}
  for i = 1, n do heap[i] = arr[i] end
  local comp = cmp or default_cmp
  -- Sift down from floor(n/2) down to 1
  for start = floor(n / 2), 1, -1 do
    local i = start
    while true do
      local left  = 2 * i
      local right = 2 * i + 1
      local best  = i
      if left  <= n and comp(heap[left],  heap[best]) then best = left  end
      if right <= n and comp(heap[right], heap[best]) then best = right end
      if best == i then break end
      heap[i], heap[best] = heap[best], heap[i]
      i = best
    end
  end
  return setmetatable({ _heap = heap, _size = n, _cmp = comp }, PQ)
end

--- Return a sorted copy of the array using heap sort (ascending by default).
function M.heapsort(arr, cmp)
  local pq     = M.heapify(arr, cmp)
  local result = {}
  while not pq:is_empty() do
    result[#result + 1] = pq:pop()
  end
  return result
end

-- ---------------------------------------------------------------------------
-- FIFO Queue (growable ring buffer, O(1) amortised all ops)
-- ---------------------------------------------------------------------------

local FIFO = {}
FIFO.__index = FIFO

local FIFO_INIT_CAP = 8

--- Enqueue a value at the back (alias: enqueue).
function FIFO:push(v)
  local size = self._size
  local cap  = self._cap
  if size == cap then
    -- Grow: double capacity, linearise elements
    local newcap = cap * 2
    local buf    = self._buf
    local head   = self._head
    local new    = {}
    for i = 0, size - 1 do
      new[i + 1] = buf[(head + i - 1) % cap + 1]
    end
    self._buf  = new
    self._head = 1
    self._tail = size + 1
    self._cap  = newcap
    cap = newcap
  end
  local tail      = self._tail
  self._buf[tail] = v
  self._tail      = tail % cap + 1
  self._size      = size + 1
end
FIFO.enqueue = FIFO.push

--- Dequeue from the front. Returns nil if empty (alias: dequeue).
function FIFO:pop()
  if self._size == 0 then return nil end
  local head      = self._head
  local v         = self._buf[head]
  self._buf[head] = nil
  self._head      = head % self._cap + 1
  self._size      = self._size - 1
  return v
end
FIFO.dequeue = FIFO.pop

--- Return the front element without removing it. Returns nil if empty.
function FIFO:peek()
  if self._size == 0 then return nil end
  return self._buf[self._head]
end

--- Add a value to the front.
function FIFO:push_front(v)
  local size = self._size
  local cap  = self._cap
  if size == cap then
    -- Grow first
    local newcap = cap * 2
    local buf    = self._buf
    local head   = self._head
    local new    = {}
    for i = 0, size - 1 do
      new[i + 1] = buf[(head + i - 1) % cap + 1]
    end
    self._buf  = new
    self._head = 1
    self._tail = size + 1
    self._cap  = newcap
    cap = newcap
  end
  -- Step head back by one slot
  local new_head      = (self._head - 2) % cap + 1
  self._buf[new_head] = v
  self._head          = new_head
  self._size          = size + 1
end

--- Remove and return the back element. Returns nil if empty.
function FIFO:pop_back()
  if self._size == 0 then return nil end
  local tail      = (self._tail - 2) % self._cap + 1
  local v         = self._buf[tail]
  self._buf[tail] = nil
  self._tail      = tail
  self._size      = self._size - 1
  return v
end

--- Enqueue all values from an array (in order) at the back.
function FIFO:push_all(arr)
  for i = 1, #arr do self:push(arr[i]) end
end

--- Return a snapshot of all elements as an array in FIFO order (front first).
function FIFO:to_array()
  local result = {}
  local buf    = self._buf
  local head   = self._head
  local cap    = self._cap
  for i = 0, self._size - 1 do
    result[i + 1] = buf[(head + i - 1) % cap + 1]
  end
  return result
end

--- Return the number of elements.
function FIFO:size()
  return self._size
end

--- Return true if empty.
function FIFO:is_empty()
  return self._size == 0
end

--- Remove all elements. Capacity is kept.
function FIFO:clear()
  self._buf  = {}
  self._head = 1
  self._tail = 1
  self._size = 0
end

--- Create a new FIFO queue.
function M.new()
  return setmetatable({
    _buf  = {},
    _head = 1,
    _tail = 1,
    _size = 0,
    _cap  = FIFO_INIT_CAP,
  }, FIFO)
end

-- ---------------------------------------------------------------------------
-- Fixed-capacity Ring Buffer (overwrites oldest element on overflow)
-- ---------------------------------------------------------------------------

local RB = {}
RB.__index = RB

--- Push a value. Overwrites the oldest element when at capacity.
function RB:push(v)
  local cap  = self._cap
  local tail = self._tail
  self._buf[tail] = v
  self._tail = tail % cap + 1
  if self._size < cap then
    self._size = self._size + 1
  else
    -- Buffer full: advance head over the overwritten slot
    self._head = self._head % cap + 1
  end
end

--- Remove and return the oldest element. Returns nil if empty.
function RB:pop()
  if self._size == 0 then return nil end
  local head      = self._head
  local v         = self._buf[head]
  self._buf[head] = nil
  self._head      = head % self._cap + 1
  self._size      = self._size - 1
  return v
end

--- Return the oldest element without removing it. Returns nil if empty.
function RB:peek()
  if self._size == 0 then return nil end
  return self._buf[self._head]
end

--- Return the number of elements currently stored.
function RB:size()
  return self._size
end

--- Return true if no elements are stored.
function RB:is_empty()
  return self._size == 0
end

--- Return true when at capacity (next push overwrites oldest).
function RB:is_full()
  return self._size == self._cap
end

--- Return the fixed capacity.
function RB:capacity()
  return self._cap
end

--- Return all elements as an array from oldest to newest.
function RB:to_array()
  local result = {}
  local buf    = self._buf
  local head   = self._head
  local cap    = self._cap
  for i = 0, self._size - 1 do
    result[i + 1] = buf[(head + i - 1) % cap + 1]
  end
  return result
end

--- Create a new fixed-capacity ring buffer.
-- Returns (nil, errmsg) if capacity is not a positive integer.
function M.ring_new(capacity)
  if type(capacity) ~= "number" or capacity < 1 or capacity ~= floor(capacity) then
    return nil, "capacity must be a positive integer"
  end
  return setmetatable({
    _buf  = {},
    _head = 1,
    _tail = 1,
    _size = 0,
    _cap  = capacity,
  }, RB)
end

return M
