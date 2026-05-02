if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- Go-style coroutine channels for LuaJIT.
-- No FFI, no threads — blocking is coroutine.yield().
-- Use M.run(fn) to drive a program with channels to completion.

local M = {}

--: string
M._tier = "pure"

local co_running = coroutine.running
local co_yield   = coroutine.yield
local co_resume  = coroutine.resume
local co_status  = coroutine.status
local co_create  = coroutine.create
local co_wrap    = coroutine.wrap

-- ── Type aliases ──────────────────────────────────────────────────────���──────

--:: SendEntry = { value: unknown, co: Thread }
--:: RecvEntry = { co: Thread }
--:: ChanBuf = { [integer]: unknown }
--:: SendQ = { [integer]: SendEntry }
--:: RecvQ = { [integer]: RecvEntry }
--:: ChanObj = { _cap: integer, _buf: ChanBuf, _head: integer, _tail: integer, _len: integer, _send_q: SendQ, _recv_q: RecvQ, _closed: boolean, ... }

-- ── channel metatable ────────────────────────────────────────────────────────

local Chan = {}
Chan.__index = Chan

--- Create a new channel.
-- capacity=0 (default) means unbuffered (rendezvous).
--: (integer | nil) -> ChanObj
function M.new(capacity)
  capacity = capacity or 0
  local buf = {} --: ChanBuf
  local sq  = {} --: SendQ
  local rq  = {} --: RecvQ
  local cap_ = capacity --[[:! integer]]
  return setmetatable({
    _cap     = cap_,
    _buf     = buf,
    _head    = 1,
    _tail    = 1,
    _len     = 0,
    _send_q  = sq,
    _recv_q  = rq,
    _closed  = false,
  }, Chan) --[[: any]] --[[:! ChanObj]]
end

-- ── internal circular buffer helpers ─────────────────────────────────────────

--: (ChanObj, unknown) -> nil
local function buf_push(ch, value)
  ch._buf[ch._tail] = value
  ch._tail = ch._tail % ch._cap + 1
  ch._len  = ch._len + 1
end

--: (ChanObj) -> unknown
local function buf_pop(ch)
  local v = ch._buf[ch._head]
  ch._buf[ch._head] = nil
  ch._head = ch._head % ch._cap + 1
  ch._len  = ch._len - 1
  return v
end

-- ── send ─────────────────────────────────────────────────────────────────────

function Chan:send(value)
  local self_ = self --[[:! ChanObj]]
  if self_._closed then
    return nil, "closed"
  end

  -- Fast path: a receiver is waiting — hand off directly.
  if #self_._recv_q > 0 then
    local rq_ = self_._recv_q
    local entry = rq_[1] --[[:! RecvEntry]]
    rq_[1] = nil; for ii=1,#rq_-1 do rq_[ii]=rq_[ii+1] end; rq_[#rq_]=nil
    local eco = entry.co --[[:! Thread]]
    local ok, err = co_resume(eco, value, true)
    if not ok then error(err) end
    return true
  end

  -- Buffered: room in buffer.
  if self_._cap > 0 and self_._len < self_._cap then
    buf_push(self_, value)
    return true
  end

  -- Must block: yield until a receiver wakes us.
  local me = co_running()
  if not me then
    return nil, "cannot block: not inside a coroutine"
  end
  local entry = { value = value, co = me }
  self_._send_q[#self_._send_q + 1] = entry
  co_yield()
  -- Resumed by a receiver or by the scheduler after channel close.
  if self_._closed then
    return nil, "closed"
  end
  return true
end

-- ── recv ─────────────────────────────────────────────────────────────────────

function Chan:recv()
  local self_ = self --[[:! ChanObj]]
  -- Data in buffer.
  if self_._len > 0 then
    local value = buf_pop(self_)
    -- Pump one waiting sender into the buffer.
    if #self_._send_q > 0 then
      local sq_ = self_._send_q
      local raw_e = sq_[1] --[[:! SendEntry]]
      sq_[1] = nil; for ii=1,#sq_-1 do sq_[ii]=sq_[ii+1] end; sq_[#sq_]=nil
      buf_push(self_, raw_e.value)
      local eco = raw_e.co --[[:! Thread]]
      local ok, err = co_resume(eco)
      if not ok then error(err) end
    end
    return value, true
  end

  -- No buffer data: waiting sender can rendezvous.
  if #self_._send_q > 0 then
    local sq2_ = self_._send_q
    local raw_e2 = sq2_[1] --[[:! SendEntry]]
    sq2_[1] = nil; for ii=1,#sq2_-1 do sq2_[ii]=sq2_[ii+1] end; sq2_[#sq2_]=nil
    local value = raw_e2.value
    local eco = raw_e2.co --[[:! Thread]]
    local ok, err = co_resume(eco)
    if not ok then error(err) end
    return value, true
  end

  -- Closed and empty.
  if self_._closed then
    return nil, false
  end

  -- Must block: yield until a sender wakes us.
  local me = co_running()
  if not me then
    return nil, false
  end
  local entry = { co = me }
  self_._recv_q[#self_._recv_q + 1] = entry
  local value, ok = co_yield()
  -- Resumed by sender (value passed back) or channel close.
  if ok == nil then
    -- Closed while waiting.
    return nil, false
  end
  return value, ok
end

-- ── close ────────────────────────────────────────────────────────────────────

function Chan:close()
  local self_ = self --[[:! ChanObj]]
  if self_._closed then return end
  self_._closed = true
  -- Wake all waiting receivers with closed signal.
  for _, entry in ipairs(self_._recv_q) do
    local eco = entry.co --[[:! Thread]]
    co_resume(eco, nil, nil)   -- value=nil, ok=nil → closed
  end
  self_._recv_q = {}
  -- Wake all waiting senders; they will see _closed=true and return nil,"closed".
  for _, entry in ipairs(self_._send_q) do
    local eco = entry.co --[[:! Thread]]
    co_resume(eco)
  end
  self_._send_q = {}
end

-- ── non-blocking variants ────────────────────────────────────────────────────

function Chan:try_send(value)
  local self_ = self --[[:! ChanObj]]
  if self_._closed then
    return nil, "closed"
  end
  if #self_._recv_q > 0 then
    local rq2_ = self_._recv_q
    local entry = rq2_[1] --[[:! RecvEntry]]
    rq2_[1] = nil; for ii=1,#rq2_-1 do rq2_[ii]=rq2_[ii+1] end; rq2_[#rq2_]=nil
    local eco = entry.co --[[:! Thread]]
    local ok, err = co_resume(eco, value, true)
    if not ok then error(err) end
    return true
  end
  if self_._cap > 0 and self_._len < self_._cap then
    buf_push(self_, value)
    return true
  end
  return nil, "full"
end

function Chan:try_recv()
  local self_ = self --[[:! ChanObj]]
  if self_._len > 0 then
    local value = buf_pop(self_)
    if #self_._send_q > 0 then
      local sq3_ = self_._send_q
      local raw_e3 = sq3_[1] --[[:! SendEntry]]
      sq3_[1] = nil; for ii=1,#sq3_-1 do sq3_[ii]=sq3_[ii+1] end; sq3_[#sq3_]=nil
      buf_push(self_, raw_e3.value)
      local eco = raw_e3.co --[[:! Thread]]
      local ok, err = co_resume(eco)
      if not ok then error(err) end
    end
    return value, true
  end
  if #self_._send_q > 0 then
    local sq4_ = self_._send_q
    local raw_e4 = sq4_[1] --[[:! SendEntry]]
    sq4_[1] = nil; for ii=1,#sq4_-1 do sq4_[ii]=sq4_[ii+1] end; sq4_[#sq4_]=nil
    local value = raw_e4.value
    local eco = raw_e4.co --[[:! Thread]]
    local ok, err = co_resume(eco)
    if not ok then error(err) end
    return value, true
  end
  if self_._closed then
    return nil, false
  end
  return nil, false, "empty"
end

-- ── state queries ─────────────────────────────────────────────────────────────

function Chan:len()       local s = self --[[:! ChanObj]]; return s._len      end
function Chan:cap()       local s = self --[[:! ChanObj]]; return s._cap      end
function Chan:is_closed() local s = self --[[:! ChanObj]]; return s._closed   end

-- ── select ────────────────────────────────────────────────────────────────────

--- Select over multiple channel operations.
-- cases: list of {ch, "recv"} or {ch, "send", value} or {default=true}
-- Tries cases in random order; if none ready and no default, yields.
-- Returns {ch=ch, op="recv"|"send", value=v} or {default=true}.
function M.select(cases)
  -- Separate default case.
  local has_default = false
  local ops = {}
  for _, case in ipairs(cases) do
    if case.default then
      has_default = true
    else
      ops[#ops + 1] = case
    end
  end

  -- Shuffle ops for fairness (Fisher-Yates).
  for i = #ops, 2, -1 do
    local j = math.random(i)
    ops[i], ops[j] = ops[j], ops[i]
  end

  -- Try each op non-blocking.
  local function try_op(case)
    local ch, op, value = case[1], case[2], case[3]
    if op == "recv" then
      local v, ok, err = ch:try_recv()
      if err ~= "empty" then
        -- got something (value or closed)
        return { ch = ch, op = "recv", value = v, ok = ok }
      end
    elseif op == "send" then
      local ok, err = ch:try_send(value)
      if err ~= "full" then
        return { ch = ch, op = "send", value = value }
      end
    end
    return nil
  end

  for _, case in ipairs(ops) do
    local result = try_op(case)
    if result then return result end
  end

  if has_default then
    return { default = true }
  end

  -- None ready — register on all and yield.
  local me = co_running()
  local fired = nil

  -- We use a shared "fired" flag so only the first wake-up wins.
  local function make_recv_waiter(case)
    local entry = { co = me, _select = true, _case = case }
    case[1]._recv_q[#case[1]._recv_q + 1] = entry
    return entry
  end

  local function make_send_waiter(case)
    local entry = { value = case[3], co = me, _select = true, _case = case }
    case[1]._send_q[#case[1]._send_q + 1] = entry
    return entry
  end

  local waiters = {}
  for _, case in ipairs(ops) do
    if case[2] == "recv" then
      waiters[#waiters + 1] = { entry = make_recv_waiter(case), case = case }
    elseif case[2] == "send" then
      waiters[#waiters + 1] = { entry = make_send_waiter(case), case = case }
    end
  end

  -- Yield; the scheduler or a peer coroutine will resume us with (result_table).
  local result = co_yield()

  -- Remove our entries from queues we didn't fire on.
  for _, w in ipairs(waiters) do
    local ch = w.case[1]
    local op = w.case[2]
    local q  = op == "recv" and ch._recv_q or ch._send_q
    for i = #q, 1, -1 do
      if q[i] == w.entry then
        table.remove(q, i)
        break
      end
    end
  end

  return result
end

-- ── go ────────────────────────────────────────────────────────────────────────

-- Global ready queue used by go/run.
-- Each element is a coroutine ready to be resumed (with no arguments on next step).
local _ready_q = {} --: { [integer]: Thread }

--- Spawn a coroutine. Adds it to the ready queue for M.run to pick up.
function M.go(fn)
  local co = co_create(fn)
  _ready_q[#_ready_q + 1] = co
  return co
end

-- ── run ───────────────────────────────────────────────────────────────────────

--- Drive all coroutines (including fn itself) to completion.
-- Maintains a round-robin ready queue.
function M.run(fn)
  -- Save and clear global ready queue so nested M.run calls are independent.
  local saved_ready = _ready_q
  _ready_q = {}

  local main_co = co_create(fn) --[[:! Thread]]
  local queue   = {} --: { [integer]: Thread }
  queue[1] = main_co

  -- Flush any coroutines that were go()'d before run() was called
  -- (shouldn't happen normally, but be safe).
  for _, co in ipairs(_ready_q) do
    queue[#queue + 1] = co
  end
  _ready_q = queue  -- go() inside fn will push into this same table

  local i = 1
  while i <= #_ready_q do
    local co = _ready_q[i]
    if co_status(co) ~= "dead" then
      local ok, err = co_resume(co)
      if not ok then
        -- Restore before erroring
        _ready_q = saved_ready
        error(err, 2)
      end
    end
    i = i + 1
    -- After each step, re-scan from where we are to pick up newly added coroutines.
    -- New coroutines added via M.go() are appended to _ready_q.
    -- Loop terminates when we've processed all entries including late additions.
  end

  _ready_q = saved_ready
end

return M
