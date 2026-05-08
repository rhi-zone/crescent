if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- Coroutine-friendly synchronization primitives for LuaJIT.
-- Semaphore, mutex, event, condition variable, and channel.
-- All blocking operations use coroutine.yield() — no OS blocking.
-- Designed for use with a cooperative scheduler or direct coroutine management.
-- Pure Lua — no FFI, no OS threads.
local M = {}
M._tier = "pure"

--:: SemaphoreT = { _count: integer, _waiters: { [integer]: Thread }, acquire: (self: unknown) -> nil, release: (self: unknown) -> nil, ... }
--:: EventT = { _fired: boolean, _waiters: { [integer]: Thread }, ... }
--:: CondT = { _waiters: { [integer]: Thread }, ... }
--:: ChannelT = { _cap: integer, _buf: { [integer]: unknown }, _head: integer, _tail: integer, _len: integer, _closed: boolean, _senders: { [integer]: unknown }, _recvers: { [integer]: Thread }, ... }

-- ---------------------------------------------------------------------------
-- Internal: resume queue helpers
-- ---------------------------------------------------------------------------

-- Enqueue a coroutine to be resumed. Called by release/fire/signal/broadcast/send/recv.
-- We resume directly here so the caller drives scheduling.
local function resume_co(co, ...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then
    error("semaphore: resumed coroutine errored: " .. tostring(err), 2)
  end
end

-- Pop the first element from a senders array (typed as { [integer]: unknown } to avoid
-- table.remove generic specialization issues with Thread).
--: ({ [integer]: unknown }) -> { [integer]: unknown }
local function senders_shift(arr)
  local first = arr[1] --[[:! { [integer]: unknown }]]
  local n = #arr
  for i = 1, n - 1 do arr[i] = arr[i + 1] end
  arr[n] = nil
  return first
end

-- ---------------------------------------------------------------------------
-- Semaphore
-- ---------------------------------------------------------------------------

local Sem = {}
Sem.__index = Sem

--- Create a counting semaphore with initial count (default 1 = binary semaphore).
function M.new(initial)
  if initial == nil then initial = 1 end
  return setmetatable({ _count = initial, _waiters = {} }, Sem)
end

--- Decrement count. If count <= 0, suspends the current coroutine until released.
--: (self: SemaphoreT) -> nil
function Sem:acquire()
  if self._count > 0 then
    self._count = self._count - 1
    return
  end
  -- Must yield — place ourselves in the waiter queue.
  local co_raw = coroutine.running()
  local co = co_raw --[[:! Thread]]
  self._waiters[#self._waiters + 1] = co
  coroutine.yield()
  -- When we are resumed by release(), count was already decremented for us
  -- (release transfers the slot directly rather than incrementing then decrementing).
end

--- Increment count. If there are suspended acquirers, resume the first one.
--: (self: SemaphoreT) -> nil
function Sem:release()
  if #self._waiters > 0 then
    -- Transfer the slot directly: don't increment, just wake the waiter.
    local co = table.remove(self._waiters, 1) --[[:! Thread]]
    resume_co(co)
  else
    self._count = self._count + 1
  end
end

--- Try to acquire without blocking. Returns true on success, false if count is 0.
--: (self: SemaphoreT) -> boolean
function Sem:try_acquire()
  if self._count > 0 then
    self._count = self._count - 1
    return true
  end
  return false
end

--- Return the current count.
--: (self: SemaphoreT) -> integer
function Sem:count()
  return self._count
end

--- Return the number of coroutines currently waiting to acquire.
--: (self: SemaphoreT) -> integer
function Sem:waiting()
  return #self._waiters
end

--- Acquire, call fn(), then release. Releases even if fn errors.
--: (self: SemaphoreT, fn: () -> nil) -> nil
function Sem:with(fn)
  self:acquire()
  local ok, err = pcall(fn)
  self:release()
  if not ok then error(err, 2) end
end

--- Create a mutex (binary semaphore, initial count 1).
function M.mutex()
  return M.new(1)
end

-- ---------------------------------------------------------------------------
-- Event: one-shot broadcast signal
-- ---------------------------------------------------------------------------

local Ev = {}
Ev.__index = Ev

--- Create a new event (initially not fired).
function M.event()
  return setmetatable({ _fired = false, _waiters = {} }, Ev)
end

--- Suspend the current coroutine until fire() is called.
-- If already fired, returns immediately.
--: (self: EventT) -> nil
function Ev:wait()
  if self._fired then return end
  local co_raw = coroutine.running()
  local co = co_raw --[[:! Thread]]
  self._waiters[#self._waiters + 1] = co
  coroutine.yield()
end

--- Fire the event, waking all waiting coroutines.
-- Future calls to wait() will return immediately.
--: (self: EventT) -> nil
function Ev:fire()
  if self._fired then return end
  self._fired = true
  local waiters = self._waiters
  self._waiters = {}
  for i = 1, #waiters do
    resume_co(waiters[i])
  end
end

--- Reset the event so that future wait() calls block again.
--: (self: EventT) -> nil
function Ev:reset()
  self._fired = false
end

--- Return true if the event has been fired.
--: (self: EventT) -> boolean
function Ev:is_fired()
  return self._fired
end

-- ---------------------------------------------------------------------------
-- Condition variable (pthread_cond style)
-- ---------------------------------------------------------------------------

local CV = {}
CV.__index = CV

--- Create a condition variable.
function M.cond()
  return setmetatable({ _waiters = {} }, CV)
end

--- Atomically release mutex and suspend. Re-acquires mutex before returning.
-- mutex must be a semaphore/mutex object with acquire()/release() methods.
--: (self: CondT, mutex: SemaphoreT) -> nil
function CV:wait(mutex)
  local co_raw = coroutine.running()
  local co = co_raw --[[:! Thread]]
  self._waiters[#self._waiters + 1] = co
  mutex:release()
  coroutine.yield()
  -- Re-acquire mutex before returning to caller.
  mutex:acquire()
end

--- Wake one waiting coroutine.
--: (self: CondT) -> nil
function CV:signal()
  if #self._waiters > 0 then
    local co = table.remove(self._waiters, 1) --[[:! Thread]]
    resume_co(co)
  end
end

--- Wake all waiting coroutines.
--: (self: CondT) -> nil
function CV:broadcast()
  local waiters = self._waiters
  self._waiters = {}
  for i = 1, #waiters do
    resume_co(waiters[i])
  end
end

-- ---------------------------------------------------------------------------
-- Channel: buffered message queue
-- ---------------------------------------------------------------------------

local Ch = {}
Ch.__index = Ch

--- Create a channel with the given buffer capacity (0 = unbuffered/rendezvous).
function M.channel(capacity)
  if capacity == nil then capacity = 0 end
  return setmetatable({
    _cap      = capacity,
    _buf      = {},        -- circular buffer values
    _head     = 1,         -- index of next item to read
    _tail     = 1,         -- index where next item will be written
    _len      = 0,         -- number of items in buffer
    _closed   = false,
    _senders  = {},        -- {co, value} pairs waiting to send
    _recvers  = {},        -- coroutines waiting to receive
  }, Ch)
end

--- Send a value. Blocks if the buffer is full (or unbuffered and no receiver ready).
-- Returns nil, "closed" if the channel is closed.
--: (self: ChannelT, value: any) -> (boolean | nil, string | nil)
function Ch:send(value)
  if self._closed then
    return nil, "closed"
  end
  -- If there is a waiting receiver, hand off directly (rendezvous or drain path).
  if #self._recvers > 0 then
    local co = table.remove(self._recvers, 1) --[[:! Thread]]
    resume_co(co, value, true)
    return true
  end
  -- If there is buffer space, enqueue.
  if self._len < self._cap then
    self._buf[self._tail] = value
    self._tail = self._tail % self._cap + 1
    self._len = self._len + 1
    return true
  end
  -- No space — block.
  local co_raw = coroutine.running()
  local co = co_raw --[[:! Thread]]
  self._senders[#self._senders + 1] = { co, value }
  coroutine.yield()
  -- Resumed by a receiver that took our value.
  return true
end

--- Receive a value. Blocks if the buffer is empty and no sender is ready.
-- Returns value, true on success; nil, "closed" on closed+empty channel.
--: (self: ChannelT) -> (unknown, boolean | string | nil)
function Ch:recv()
  -- If there are buffered items, return the oldest.
  if self._len > 0 then
    local value = self._buf[self._head]
    self._buf[self._head] = nil
    self._head = self._head % self._cap + 1
    self._len = self._len - 1
    -- If a sender was blocked, let it enqueue its value now.
    if #self._senders > 0 then
      local entry_t = senders_shift(self._senders)
      local sco = entry_t[1] --[[:! Thread]]
      local sval = entry_t[2]
      self._buf[self._tail] = sval
      self._tail = self._tail % self._cap + 1
      self._len = self._len + 1
      resume_co(sco)
    end
    return value, true
  end
  -- No buffered items. If a sender is waiting (unbuffered rendezvous or blocked sender), take directly.
  if #self._senders > 0 then
    local entry_t = senders_shift(self._senders)
    local sco = entry_t[1] --[[:! Thread]]
    local sval = entry_t[2]
    resume_co(sco)
    return sval, true
  end
  -- Channel is empty. If closed, signal that.
  if self._closed then
    return nil, "closed"
  end
  -- Block until something is sent.
  local co_raw = coroutine.running()
  local co = co_raw --[[:! Thread]]
  self._recvers[#self._recvers + 1] = co
  local value, ok_raw = coroutine.yield()
  local ok = ok_raw --[[:! boolean | string | nil]]
  -- Resumed by send() with (value, true), or by close() with (nil, "closed").
  return value, ok
end

--- Non-blocking send. Returns true if sent, false if full or closed.
--: (self: ChannelT, value: any) -> (boolean, string | nil)
function Ch:try_send(value)
  if self._closed then return false end
  if #self._recvers > 0 then
    local co = table.remove(self._recvers, 1) --[[:! Thread]]
    resume_co(co, value, true)
    return true
  end
  if self._len < self._cap then
    self._buf[self._tail] = value
    self._tail = self._tail % self._cap + 1
    self._len = self._len + 1
    return true
  end
  return false
end

--- Non-blocking receive. Returns value, true on success; nil, false if empty.
-- Returns nil, "closed" if closed and empty.
--: (self: ChannelT) -> (unknown, boolean | string | nil)
function Ch:try_recv()
  if self._len > 0 then
    local value = self._buf[self._head]
    self._buf[self._head] = nil
    self._head = self._head % self._cap + 1
    self._len = self._len - 1
    if #self._senders > 0 then
      local entry_t = senders_shift(self._senders)
      local sco = entry_t[1] --[[:! Thread]]
      local sval = entry_t[2]
      self._buf[self._tail] = sval
      self._tail = self._tail % self._cap + 1
      self._len = self._len + 1
      resume_co(sco)
    end
    return value, true
  end
  if #self._senders > 0 then
    local entry_t = senders_shift(self._senders)
    local sco = entry_t[1] --[[:! Thread]]
    local sval = entry_t[2]
    resume_co(sco)
    return sval, true
  end
  if self._closed then
    return nil, "closed"
  end
  return nil, false
end

--- Close the channel. Pending receivers are woken with nil, "closed".
-- Further sends return nil, "closed". Pending items can still be drained.
--: (self: ChannelT) -> nil
function Ch:close()
  if self._closed then return end
  self._closed = true
  -- Wake all waiting receivers with the closed signal.
  local recvers = self._recvers
  self._recvers = {}
  for i = 1, #recvers do
    resume_co(recvers[i], nil, "closed")
  end
end

--- Return true if the channel is closed.
--: (self: ChannelT) -> boolean
function Ch:is_closed()
  return self._closed
end

--- Return the number of items currently in the buffer.
--: (self: ChannelT) -> integer
function Ch:len()
  return self._len
end

--- Return the channel capacity.
--: (self: ChannelT) -> integer
function Ch:cap()
  return self._cap
end

return M
