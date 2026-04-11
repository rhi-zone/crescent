if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- Coroutine-based concurrency primitives.
-- Semaphore, mutex, condition variable, WaitGroup, and Once.
-- All primitives work with the built-in scheduler (M.run / M.go).
-- Pure Lua — no FFI, no OS threads.
local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Minimal coroutine scheduler
-- ---------------------------------------------------------------------------

local _ready = {}

-- Tracks which coroutines are doing a blocking wait (yield_me).
-- Such coroutines have already been placed in a primitive's waiter list, so
-- the scheduler must NOT re-enqueue them automatically when they yield.
-- Plain coroutine.yield() from user code is NOT in this set, so the scheduler
-- treats it as a voluntary context switch and re-enqueues the coroutine.
local _blocking = {}

--- Spawn a coroutine to be run by the current scheduler.
function M.go(fn)
  _ready[#_ready + 1] = coroutine.create(fn)
end

--- Run fn as the root coroutine of a scheduler event loop.
-- Nested M.run calls each get their own _ready queue that is restored on exit.
function M.run(fn)
  local prev = _ready
  _ready = {}
  M.go(fn)
  while #_ready > 0 do
    local q = _ready
    _ready = {}
    for _, co in ipairs(q) do
      local ok, err = coroutine.resume(co)
      if not ok then
        _ready = prev
        error(err, 2)
      end
      -- If the coroutine is still alive and did NOT mark itself as blocking,
      -- it did a voluntary yield — re-enqueue it for the next scheduler turn.
      if coroutine.status(co) == "suspended" and not _blocking[co] then
        _ready[#_ready + 1] = co
      end
      _blocking[co] = nil
    end
  end
  _ready = prev
end

-- Internal: yield the current coroutine and mark it as blocking.
-- The calling code is responsible for placing this coroutine in a waiter list
-- so it will be re-enqueued when the resource becomes available.
local function yield_me()
  local co = coroutine.running()
  _blocking[co] = true
  coroutine.yield()
end

-- ---------------------------------------------------------------------------
-- Semaphore
-- ---------------------------------------------------------------------------

local Sem = {}
Sem.__index = Sem

--- Create a counting semaphore with initial count n (n >= 0).
function M.semaphore(n)
  if n == nil then n = 1 end
  return setmetatable({ _count = n, _waiters = {} }, Sem)
end

--- Decrement the semaphore. Yields if count is 0.
function Sem:acquire()
  while self._count <= 0 do
    local co = coroutine.running()
    self._waiters[#self._waiters + 1] = co
    yield_me()
  end
  self._count = self._count - 1
end

--- Try to acquire without blocking. Returns true on success, false otherwise.
function Sem:try_acquire()
  if self._count > 0 then
    self._count = self._count - 1
    return true
  end
  return false
end

--- Increment the semaphore. Wakes one waiter if any.
function Sem:release()
  self._count = self._count + 1
  if #self._waiters > 0 then
    local co = table.remove(self._waiters, 1)
    _ready[#_ready + 1] = co
  end
end

--- Return the current count.
function Sem:count()
  return self._count
end

-- ---------------------------------------------------------------------------
-- Mutex (binary semaphore)
-- ---------------------------------------------------------------------------

local Mtx = {}
Mtx.__index = Mtx

--- Create an unlocked mutex.
function M.mutex()
  return setmetatable({ _locked = false, _waiters = {} }, Mtx)
end

--- Acquire the mutex. Yields if already locked.
function Mtx:lock()
  while self._locked do
    local co = coroutine.running()
    self._waiters[#self._waiters + 1] = co
    yield_me()
  end
  self._locked = true
end

--- Try to acquire without blocking. Returns true on success.
function Mtx:try_lock()
  if not self._locked then
    self._locked = true
    return true
  end
  return false
end

--- Release the mutex. Wakes one waiter if any.
function Mtx:unlock()
  if not self._locked then
    return nil, "mutex: unlock of unlocked mutex"
  end
  self._locked = false
  if #self._waiters > 0 then
    local co = table.remove(self._waiters, 1)
    _ready[#_ready + 1] = co
  end
  return true
end

--- Return true if the mutex is currently locked.
function Mtx:is_locked()
  return self._locked
end

--- Run fn while holding the mutex. Unlocks even if fn errors.
function Mtx:with(fn)
  self:lock()
  local ok, err = pcall(fn)
  self:unlock()
  if not ok then error(err, 2) end
end

-- ---------------------------------------------------------------------------
-- Condition variable
-- ---------------------------------------------------------------------------

local CV = {}
CV.__index = CV

--- Create a condition variable associated with mutex m.
function M.cond(m)
  return setmetatable({ _mutex = m, _waiters = {} }, CV)
end

--- Atomically release the mutex and yield; reacquires on wake.
function CV:wait()
  local co = coroutine.running()
  self._waiters[#self._waiters + 1] = co
  self._mutex:unlock()
  yield_me()
  -- Reacquire mutex before returning. Schedule ourselves back on the ready
  -- queue after acquiring — use the same blocking acquire path.
  self._mutex:lock()
end

--- Wake one waiter.
function CV:signal()
  if #self._waiters > 0 then
    local co = table.remove(self._waiters, 1)
    _ready[#_ready + 1] = co
  end
end

--- Wake all waiters.
function CV:broadcast()
  for i = 1, #self._waiters do
    _ready[#_ready + 1] = self._waiters[i]
    self._waiters[i] = nil
  end
end

-- ---------------------------------------------------------------------------
-- WaitGroup
-- ---------------------------------------------------------------------------

local WG = {}
WG.__index = WG

--- Create a WaitGroup with counter starting at 0.
function M.waitgroup()
  return setmetatable({ _count = 0, _waiters = {} }, WG)
end

--- Add n to the counter (n may be negative).
function WG:add(n)
  self._count = self._count + n
  if self._count < 0 then
    error("waitgroup: negative counter", 2)
  end
  if self._count == 0 then
    -- Wake all waiters.
    for i = 1, #self._waiters do
      _ready[#_ready + 1] = self._waiters[i]
      self._waiters[i] = nil
    end
  end
end

--- Decrement counter by 1.
function WG:done()
  self:add(-1)
end

--- Yield until the counter reaches 0.
function WG:wait()
  while self._count > 0 do
    local co = coroutine.running()
    self._waiters[#self._waiters + 1] = co
    yield_me()
  end
end

-- ---------------------------------------------------------------------------
-- Once
-- ---------------------------------------------------------------------------

local Once = {}
Once.__index = Once

--- Create a Once object. The function passed to do_ runs at most once.
function M.once()
  return setmetatable({ _done = false }, Once)
end

--- Call fn if it has not been called before on this Once.
function Once:do_(fn)
  if not self._done then
    self._done = true
    fn()
  end
end

return M
