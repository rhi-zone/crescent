-- lib/actor/init.lua
-- Coroutine-based actor model with cooperative multitasking, supervision,
-- links, monitors, and request-reply (call).
--
-- Each actor runs as a Lua coroutine. The scheduler drives actors forward
-- by resuming coroutines that have pending messages. All concurrency is
-- cooperative: no preemption, no threads.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--: string
M._tier = "pure"

local co_create  = coroutine.create
local co_resume  = coroutine.resume
local co_status  = coroutine.status
local co_yield   = coroutine.yield

-- ---------------------------------------------------------------------------
-- Pid (opaque integer handle) — just a sequential integer, kept as-is
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- ActorContext — the `ctx` object passed to actor bodies
-- ---------------------------------------------------------------------------

local ActorCtx = {}
ActorCtx.__index = ActorCtx

function ActorCtx:receive(timeout_ms)
  -- If mailbox already has a message, return it immediately.
  local mailbox = self._actor._mailbox
  if #mailbox > 0 then
    return table.remove(mailbox, 1)
  end
  -- Otherwise yield back to the scheduler, which will resume us when a message
  -- arrives (or the timeout fires).
  local clock_fn = self._system._clock_fn
  local deadline
  if timeout_ms then
    deadline = clock_fn() + timeout_ms / 1000.0
  end
  while true do
    co_yield(deadline)
    if #mailbox > 0 then
      return table.remove(mailbox, 1)
    end
    -- If we're back here and mailbox is still empty, the scheduler woke us for
    -- timeout checking.
    if deadline and clock_fn() >= deadline then
      return nil
    end
  end
end

function ActorCtx:send(pid, msg)
  return self._system:send(pid, msg)
end

function ActorCtx:self()
  return self._actor._pid
end

function ActorCtx:name()
  return self._actor._name
end

function ActorCtx:link(pid)
  local sys = self._system
  local target = sys._actors[pid]
  if not target then return nil, "actor not found" end
  -- Bidirectional link
  self._actor._links[pid] = true
  target._links[self._actor._pid] = true
  return true
end

function ActorCtx:monitor(pid)
  local sys = self._system
  local target = sys._actors[pid]
  if not target then
    -- Already dead — send :down immediately next step
    local ref = sys:_next_ref()
    sys:send(self._actor._pid, {type = "down", pid = pid, ref = ref, reason = "noproc"})
    return ref
  end
  local ref = sys:_next_ref()
  target._monitors[ref] = self._actor._pid
  self._actor._monitor_refs[ref] = pid
  return ref
end

function ActorCtx:spawn(fn, opts)
  return self._system:spawn(fn, opts)
end

-- ---------------------------------------------------------------------------
-- Actor record
-- ---------------------------------------------------------------------------

local function make_actor(pid, fn, opts, system)
  opts = opts or {}
  local actor = {
    _pid      = pid,
    _name     = opts.name,
    _restart  = opts.restart or "temporary",
    _mailbox  = {},
    _links    = {},    -- pid -> true
    _monitors = {},    -- ref -> observer_pid
    _monitor_refs = {}, -- ref -> monitored_pid
    _status   = "running",  -- "running" | "dead"
    _fn       = fn,
    _co       = nil,   -- created on first step
    _ctx      = nil,
    _exit_reason = nil,
    _deadline = nil,   -- coroutine waiting until this clock value
    _system   = system,
  }
  local ctx = setmetatable({
    _actor  = actor,
    _system = system,
  }, ActorCtx)
  actor._ctx = ctx
  actor._co = co_create(function()
    fn(ctx)
  end)
  return actor
end

-- ---------------------------------------------------------------------------
-- System
-- ---------------------------------------------------------------------------

local System = {}
System.__index = System

function M.system(opts)
  opts = opts or {}
  local sys = setmetatable({
    _actors      = {},    -- pid -> actor
    _names       = {},    -- name -> pid
    _next_pid    = 1,
    _next_ref_id = 1,
    _mailbox_size = opts.mailbox_size or 100,
    _clock_fn    = opts.clock_fn or error("actor.system: opts.clock_fn is required"),
  }, System)
  return sys
end

function System:_next_ref()
  local r = self._next_ref_id
  self._next_ref_id = r + 1
  return r
end

function System:spawn(fn, opts)
  opts = opts or {}
  local pid = self._next_pid
  self._next_pid = pid + 1
  local actor = make_actor(pid, fn, opts, self)
  self._actors[pid] = actor
  if opts.name then
    self._names[opts.name] = pid
  end
  -- Do an initial step so the actor runs until its first receive/yield.
  self:_resume_actor(actor)
  return pid
end

function System:send(pid, msg)
  local actor = self._actors[pid]
  if not actor or actor._status ~= "running" then
    return nil, "actor not found or dead"
  end
  local mailbox = actor._mailbox
  if #mailbox >= self._mailbox_size then
    return nil, "mailbox full"
  end
  mailbox[#mailbox + 1] = msg
  -- If the actor is suspended waiting for a message, resume it now.
  if co_status(actor._co) == "suspended" then
    self:_resume_actor(actor)
  end
  return true
end

function System:call(pid, msg, timeout_ms)
  -- We need a temporary "caller" mechanism without a real actor for the
  -- return channel. We use a single-element result table and a unique reply_to
  -- pid: the pid of a synthetic receiver actor.
  local result_box = {}
  local caller_pid = self._next_pid
  self._next_pid = caller_pid + 1

  -- Create a synthetic one-shot actor that just receives one message.
  local reply_actor = make_actor(caller_pid, function(ctx)
    local reply = ctx:receive(timeout_ms)
    result_box[1] = reply
  end, {}, self)
  self._actors[caller_pid] = reply_actor

  -- Inject reply_to into msg
  msg = msg or {}
  msg.reply_to = caller_pid

  -- Send the message
  self:send(pid, msg)

  -- Drive the system until the reply actor is dead or timeout
  local clock_fn = self._clock_fn
  local deadline
  if timeout_ms then
    deadline = clock_fn() + timeout_ms / 1000.0
  end

  local max_steps = 10000
  local steps = 0
  while reply_actor._status == "running" and steps < max_steps do
    steps = steps + 1
    self:step()
    if deadline and clock_fn() >= deadline then
      break
    end
  end

  -- Clean up synthetic actor
  self._actors[caller_pid] = nil

  return result_box[1]
end

function System:whereis(name)
  return self._names[name]
end

function System:stop(pid)
  local actor = self._actors[pid]
  if not actor then return end
  self:_kill_actor(actor, "stopped")
end

function System:alive(pid)
  local actor = self._actors[pid]
  return actor ~= nil and actor._status == "running"
end

function System:actor_count()
  local n = 0
  for _ in pairs(self._actors) do
    n = n + 1
  end
  return n
end

-- Resume an actor's coroutine, catching errors, and handle exit.
function System:_resume_actor(actor)
  if actor._status ~= "running" then return end
  if co_status(actor._co) == "dead" then
    self:_kill_actor(actor, "normal")
    return
  end
  local ok, val = co_resume(actor._co)
  if not ok then
    -- val is the error message
    self:_kill_actor(actor, tostring(val))
    return
  end
  -- val is the deadline yielded from receive (or nil)
  actor._deadline = val
  -- If coroutine finished normally
  if co_status(actor._co) == "dead" then
    self:_kill_actor(actor, "normal")
  end
end

function System:_kill_actor(actor, reason)
  if actor._status == "dead" then return end
  actor._status = "dead"
  actor._exit_reason = reason
  local pid = actor._pid

  -- Remove name registration
  if actor._name then
    self._names[actor._name] = nil
  end

  -- Notify linked actors
  for linked_pid in pairs(actor._links) do
    local linked = self._actors[linked_pid]
    if linked and linked._status == "running" then
      -- Remove reciprocal link first to avoid re-notification
      linked._links[pid] = nil
      -- Send exit signal
      self:send(linked_pid, {type = "exit", pid = pid, reason = reason})
    end
  end

  -- Notify monitors
  for ref, observer_pid in pairs(actor._monitors) do
    local observer = self._actors[observer_pid]
    if observer and observer._status == "running" then
      self:send(observer_pid, {type = "down", pid = pid, ref = ref, reason = reason})
    end
  end

  -- Remove from system (after notifications so send() still works for observers)
  self._actors[pid] = nil
end

function System:step()
  -- Collect actors to step (snapshot — actors may die during step)
  local to_step = {}
  local now = self._clock_fn()
  for pid, actor in pairs(self._actors) do
    if actor._status == "running" then
      local has_mail  = #actor._mailbox > 0
      local timed_out = actor._deadline and now >= actor._deadline
      local suspended = co_status(actor._co) == "suspended"
      if (has_mail or timed_out) and suspended then
        to_step[#to_step + 1] = actor
      end
    end
  end
  for i = 1, #to_step do
    local actor = to_step[i]
    if actor._status == "running" then
      self:_resume_actor(actor)
    end
  end
end

function System:run(n)
  for _ = 1, n do
    self:step()
  end
end

function System:run_until_idle()
  local max = 100000
  for _ = 1, max do
    -- Check if any actor has pending messages or timed-out deadlines
    local now = self._clock_fn()
    local active = false
    for _, actor in pairs(self._actors) do
      if actor._status == "running" then
        local has_mail  = #actor._mailbox > 0
        local timed_out = actor._deadline and now >= actor._deadline
        if has_mail or timed_out then
          active = true
          break
        end
      end
    end
    if not active then break end
    self:step()
  end
end

-- ---------------------------------------------------------------------------
-- Supervisor
-- ---------------------------------------------------------------------------

local Supervisor = {}
Supervisor.__index = Supervisor

function System:supervisor(opts)
  opts = opts or {}
  local sup = setmetatable({
    _system       = self,
    _strategy     = opts.strategy or "one_for_one",
    _max_restarts = opts.max_restarts or 3,
    _period       = opts.period or 5,
    _children     = {},   -- array of {id, fn, restart, pid}
    _failures     = {},   -- id -> {times=[], ...}
    _pid          = nil,
  }, Supervisor)

  -- Spawn supervisor actor
  local sup_pid = self:spawn(function(ctx)
    while true do
      local msg = ctx:receive()
      if msg == nil then break end
      if msg.type == "child_exit" then
        sup:_handle_exit(msg.id, msg.reason, ctx)
      end
    end
  end, {name = opts.name})
  sup._pid = sup_pid

  -- Pre-register ALL children before spawning any, so that if a child crashes
  -- synchronously on first resume, _handle_exit sees the full children list
  -- (needed for one_for_all / rest_for_one strategies).
  if opts.children then
    for _, spec in ipairs(opts.children) do
      local entry = {
        id      = spec.id,
        fn      = spec.fn,
        restart = spec.restart or "temporary",
        pid     = nil,
        name    = spec.name,
      }
      sup._children[#sup._children + 1] = entry
      sup._failures[spec.id] = sup._failures[spec.id] or {times = {}}
    end
    -- Now spawn them all
    for i, spec in ipairs(opts.children) do
      sup:_spawn_child(sup._children[i])
    end
  end

  return sup
end

-- Spawn the coroutine for an already-registered child entry.
function Supervisor:_spawn_child(entry)
  local sys = self._system
  local child_id = entry.id
  local fn = entry.fn
  local sup_pid = self._pid

  local wrapped = function(ctx)
    local ok, err = pcall(fn, ctx)
    local reason = ok and "normal" or tostring(err)
    sys:send(sup_pid, {type = "child_exit", id = child_id, reason = reason})
  end

  local pid = sys:spawn(wrapped, {name = entry.name})
  -- Only set entry.pid if _handle_exit hasn't already updated it during
  -- a synchronous crash + restart that happened inside spawn().
  if entry.pid == nil then
    entry.pid = pid
  end
  return pid
end

function Supervisor:_start_child(spec)
  -- Register and spawn a new child (used for dynamic child addition or restart).
  local entry = {
    id      = spec.id,
    fn      = spec.fn,
    restart = spec.restart or "temporary",
    pid     = nil,
    name    = spec.name,
  }
  self._children[#self._children + 1] = entry
  self._failures[spec.id] = self._failures[spec.id] or {times = {}}
  self:_spawn_child(entry)
  return entry.pid
end

function Supervisor:_find_child(id)
  for i, c in ipairs(self._children) do
    if c.id == id then return c, i end
  end
  return nil, nil
end

function Supervisor:_should_restart(child, reason)
  local r = child.restart
  if r == "permanent" then return true end
  if r == "temporary" then return false end
  if r == "transient" then return reason ~= "normal" end
  return false
end

function Supervisor:_record_failure(id)
  local now = self._system._clock_fn()
  local rec = self._failures[id]
  -- Prune old failures outside the period window
  local period = self._period
  local times = rec.times
  local j = 1
  while j <= #times do
    if now - times[j] > period then
      table.remove(times, j)
    else
      j = j + 1
    end
  end
  times[#times + 1] = now
  return #times
end

function Supervisor:_handle_exit(id, reason, ctx)
  local child = self:_find_child(id)
  if not child then return end

  if not self:_should_restart(child, reason) then
    -- Remove child from list
    for i, c in ipairs(self._children) do
      if c.id == id then
        table.remove(self._children, i)
        break
      end
    end
    return
  end

  -- Check restart intensity
  local count = self:_record_failure(id)
  if count > self._max_restarts then
    -- Exceeded — stop supervisor itself (simplified: just stop)
    return
  end

  local strategy = self._strategy
  if strategy == "one_for_one" then
    -- Restart only the failed child by re-using its existing entry.
    child.pid = nil  -- clear so _spawn_child sets it
    self:_spawn_child(child)
  elseif strategy == "one_for_all" then
    -- Stop all other living children, then rebuild the children list and
    -- spawn all of them. Pre-register all entries before spawning any so
    -- that if a restarted child crashes synchronously, _handle_exit can
    -- see the complete children list.
    local entries = {}
    for _, c in ipairs(self._children) do
      entries[#entries + 1] = {id = c.id, fn = c.fn, restart = c.restart, name = c.name}
      if c.id ~= id and c.pid then
        self._system:stop(c.pid)
      end
    end
    self._children = {}
    -- Pre-register all
    for _, e in ipairs(entries) do
      local new_entry = {id = e.id, fn = e.fn, restart = e.restart, name = e.name, pid = nil}
      self._children[#self._children + 1] = new_entry
      self._failures[e.id] = self._failures[e.id] or {times = {}}
    end
    -- Spawn all
    for i = 1, #self._children do
      self:_spawn_child(self._children[i])
    end
  elseif strategy == "rest_for_one" then
    -- Stop children started after the failed one, then restart from failed onward.
    local found = false
    local to_restart_entries = {}
    for _, c in ipairs(self._children) do
      if c.id == id then
        found = true
        to_restart_entries[#to_restart_entries + 1] = c
      elseif found then
        if c.pid then self._system:stop(c.pid) end
        to_restart_entries[#to_restart_entries + 1] = c
      end
    end
    -- Reset pids for entries to restart
    for _, e in ipairs(to_restart_entries) do
      e.pid = nil
    end
    -- Spawn them in order
    for _, e in ipairs(to_restart_entries) do
      self:_spawn_child(e)
    end
  end
end

function Supervisor:get_pid(id)
  local child = self:_find_child(id)
  if child then return child.pid end
  return nil
end

return M
