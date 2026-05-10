-- lib/queue/init.lua
-- Priority queue (binary min-heap), FIFO queue (growable ring buffer),
-- and fixed-capacity ring buffer. Pure Lua — no external dependencies.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local floor = math.floor

--:: PQState = { _heap: { [integer]: unknown }, _size: integer, _cmp: (unknown, unknown) -> boolean, push: (PQState, unknown) -> (), pop: (PQState) -> unknown, is_empty: (PQState) -> boolean }
--:: FIFOState = { _buf: { [integer]: unknown }, _head: integer, _tail: integer, _size: integer, _cap: integer, push: (FIFOState, unknown) -> () }
--:: RBState = { _buf: { [integer]: unknown }, _head: integer, _tail: integer, _size: integer, _cap: integer }

-- ---------------------------------------------------------------------------
-- Priority Queue (binary min-heap)
-- ---------------------------------------------------------------------------

-- Default comparator: min-heap (smaller values have higher priority)
--: (unknown, unknown) -> boolean
local function default_cmp(a, b)
  local x = a --[[:! number]]
  local y = b --[[:! number]]
  return x < y
end

local PQ = {}
PQ.__index = PQ

--- Push a value onto the heap.
--: (self: PQState, v: unknown) -> ()
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
--: (self: PQState, arr: { [integer]: unknown }) -> ()
function PQ:push_all(arr)
  for i = 1, #arr do self:push(arr[i]) end
end

--- Remove and return the top (highest-priority) element. Returns nil if empty.
--: (self: PQState) -> unknown
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
--: (self: PQState) -> unknown
function PQ:peek()
  return self._heap[1]
end

--- Return the number of elements.
--: (self: PQState) -> integer
function PQ:size()
  return self._size
end

--- Return true if the heap is empty.
--: (self: PQState) -> boolean
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
--: (arr: { [integer]: unknown }, cmp: ((unknown, unknown) -> boolean) | nil) -> PQState
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
--: (self: FIFOState, v: unknown) -> ()
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
--: (self: FIFOState) -> unknown
function FIFO:pop()
  if self._size == 0 then return nil
  else
  local head      = self._head
  local v         = self._buf[head]
  self._buf[head] = nil
  self._head      = head % self._cap + 1
  self._size      = self._size - 1
  return v
  end
end
FIFO.dequeue = FIFO.pop

--- Return the front element without removing it. Returns nil if empty.
--: (self: FIFOState) -> unknown
function FIFO:peek()
  if self._size == 0 then return nil
  else return self._buf[self._head]
  end
end

--- Add a value to the front.
--: (self: FIFOState, v: unknown) -> ()
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
--: (self: FIFOState) -> unknown
function FIFO:pop_back()
  if self._size == 0 then return nil
  else
  local tail      = (self._tail - 2) % self._cap + 1
  local v         = self._buf[tail]
  self._buf[tail] = nil
  self._tail      = tail
  self._size      = self._size - 1
  return v
  end
end

--- Enqueue all values from an array (in order) at the back.
--: (self: FIFOState, arr: { [integer]: unknown }) -> ()
function FIFO:push_all(arr)
  for i = 1, #arr do self:push(arr[i]) end
end

--- Return a snapshot of all elements as an array in FIFO order (front first).
--: (self: FIFOState) -> { [integer]: unknown }
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
--: (self: FIFOState) -> integer
function FIFO:size()
  return self._size
end

--- Return true if empty.
--: (self: FIFOState) -> boolean
function FIFO:is_empty()
  return self._size == 0
end

--- Remove all elements. Capacity is kept.
--: (self: FIFOState) -> ()
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
--: (self: RBState, v: unknown) -> ()
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
--: (self: RBState) -> unknown
function RB:pop()
  if self._size == 0 then return nil
  else
    local head      = self._head
    local v         = self._buf[head]
    self._buf[head] = nil
    self._head      = head % self._cap + 1
    self._size      = self._size - 1
    return v
  end
end

--- Return the oldest element without removing it. Returns nil if empty.
--: (self: RBState) -> unknown
function RB:peek()
  if self._size == 0 then return nil
  else return self._buf[self._head]
  end
end

--- Return the number of elements currently stored.
--: (self: RBState) -> integer
function RB:size()
  return self._size
end

--- Return true if no elements are stored.
--: (self: RBState) -> boolean
function RB:is_empty()
  return self._size == 0
end

--- Return true when at capacity (next push overwrites oldest).
--: (self: RBState) -> boolean
function RB:is_full()
  return self._size == self._cap
end

--- Return the fixed capacity.
--: (self: RBState) -> integer
function RB:capacity()
  return self._cap
end

--- Return all elements as an array from oldest to newest.
--: (self: RBState) -> { [integer]: unknown }
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
