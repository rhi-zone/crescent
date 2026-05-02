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

--:: ActorRecord = { _pid: integer, _name: string|nil, _restart: string, _mailbox: { [integer]: any }, _links: { [integer]: boolean }, _monitors: { [integer]: integer }, _monitor_refs: { [integer]: integer }, _status: string, _fn: (any) -> any, _co: any|nil, _ctx: any, _exit_reason: string|nil, _deadline: number|nil, _system: any }
--:: ActorCtxShape = { _actor: ActorRecord, _system: any, receive: (ActorCtxShape, number|nil) -> any, send: (ActorCtxShape, integer, any) -> any, self: (ActorCtxShape) -> integer, name: (ActorCtxShape) -> string|nil, link: (ActorCtxShape, integer) -> boolean|nil, monitor: (ActorCtxShape, integer) -> integer, spawn: (ActorCtxShape, any, any) -> integer }
--:: SystemShape = { _actors: { [integer]: ActorRecord }, _names: { [string]: integer }, _next_pid: integer, _next_ref_id: integer, _mailbox_size: integer, _clock_fn: () -> number, _next_ref: (SystemShape) -> integer, spawn: (SystemShape, any, any) -> integer, send: (SystemShape, integer, any) -> boolean|nil, call: (SystemShape, integer, any, number|nil) -> any, whereis: (SystemShape, string) -> integer|nil, stop: (SystemShape, integer) -> nil, alive: (SystemShape, integer) -> boolean, actor_count: (SystemShape) -> integer, _resume_actor: (SystemShape, ActorRecord) -> nil, _kill_actor: (SystemShape, ActorRecord, string) -> nil, step: (SystemShape) -> nil, run: (SystemShape, integer) -> nil, run_until_idle: (SystemShape) -> nil, supervisor: (SystemShape, any) -> any }
--:: SupervisorShape = { _system: SystemShape, _strategy: string, _max_restarts: integer, _period: number, _children: { [integer]: any }, _failures: { [string]: any }, _pid: integer|nil, _spawn_child: (SupervisorShape, any) -> integer, _start_child: (SupervisorShape, any) -> integer|nil, _find_child: (SupervisorShape, string) -> any, _should_restart: (SupervisorShape, any, string) -> boolean, _record_failure: (SupervisorShape, string) -> integer, _handle_exit: (SupervisorShape, string, string, any) -> nil, get_pid: (SupervisorShape, string) -> integer|nil }

-- ---------------------------------------------------------------------------
-- Pid (opaque integer handle) — just a sequential integer, kept as-is
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- ActorContext — the `ctx` object passed to actor bodies
-- ---------------------------------------------------------------------------

local ActorCtx = {}
ActorCtx.__index = ActorCtx

function ActorCtx:receive(timeout_ms)
  local self_ = self --[[:! ActorCtxShape]]
  -- If mailbox already has a message, return it immediately.
  local mailbox = self_._actor._mailbox
  if #mailbox > 0 then
    return table.remove(mailbox, 1)
  end
  -- Otherwise yield back to the scheduler, which will resume us when a message
  -- arrives (or the timeout fires).
  local sys_ = self_._system --[[:! SystemShape]]
  local clock_fn = sys_._clock_fn
  local deadline --: number|nil
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
    local dl_ = deadline --: number|nil
    if dl_ ~= nil and clock_fn() >= dl_ then
      return nil
    end
  end
end

function ActorCtx:send(pid, msg)
  local self_ = self --[[:! ActorCtxShape]]
  local sys_ = self_._system --[[:! SystemShape]]
  return sys_:send(pid, msg)
end

function ActorCtx:self()
  local self_ = self --[[:! ActorCtxShape]]
  return self_._actor._pid
end

function ActorCtx:name()
  local self_ = self --[[:! ActorCtxShape]]
  return self_._actor._name
end

function ActorCtx:link(pid)
  local self_ = self --[[:! ActorCtxShape]]
  local sys_ = self_._system --[[:! SystemShape]]
  local target = sys_._actors[pid]
  if not target then return nil, "actor not found" end
  -- Bidirectional link
  self_._actor._links[pid] = true
  target._links[self_._actor._pid] = true
  return true
end

function ActorCtx:monitor(pid)
  local self_ = self --[[:! ActorCtxShape]]
  local sys_ = self_._system --[[:! SystemShape]]
  local target = sys_._actors[pid]
  if not target then
    -- Already dead — send :down immediately next step
    local ref = sys_:_next_ref()
    sys_:send(self_._actor._pid, {type = "down", pid = pid, ref = ref, reason = "noproc"})
    return ref
  end
  local ref = sys_:_next_ref()
  target._monitors[ref] = self_._actor._pid
  self_._actor._monitor_refs[ref] = pid
  return ref
end

function ActorCtx:spawn(fn, opts)
  local self_ = self --[[:! ActorCtxShape]]
  local sys_ = self_._system --[[:! SystemShape]]
  return sys_:spawn(fn, opts)
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
  }, ActorCtx) --[[: any]]
  actor._ctx = ctx
  actor._co = co_create(function()
    local fn_ = fn --[[:! (any) -> any]]
    fn_(ctx)
  end) --[[: any]]
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
  local self_ = self --[[:! SystemShape]]
  local r = self_._next_ref_id
  self_._next_ref_id = r + 1
  return r
end

function System:spawn(fn, opts)
  local self_ = self --[[:! SystemShape]]
  opts = opts or {}
  local opts_ = opts --[[:! { name: string|nil, restart: string|nil, mailbox_size: integer|nil }]]
  local pid = self_._next_pid
  self_._next_pid = pid + 1
  local actor = make_actor(pid, fn, opts_, self_)
  self_._actors[pid] = actor
  if opts_.name then
    self_._names[opts_.name] = pid
  end
  -- Do an initial step so the actor runs until its first receive/yield.
  self_:_resume_actor(actor)
  return pid
end

function System:send(pid, msg)
  local self_ = self --[[:! SystemShape]]
  local actor = self_._actors[pid]
  if not actor or actor._status ~= "running" then
    return nil, "actor not found or dead"
  end
  local mailbox = actor._mailbox
  if #mailbox >= self_._mailbox_size then
    return nil, "mailbox full"
  end
  mailbox[#mailbox + 1] = msg
  -- If the actor is suspended waiting for a message, resume it now.
  local co_ = actor._co --[[: any]]
  if co_status(co_) == "suspended" then
    self_:_resume_actor(actor)
  end
  return true
end

--: (SystemShape, integer, any, number|nil) -> any
function System:call(pid, msg, timeout_ms)
  local self_ = self --[[:! SystemShape]]
  local timeout_ms_ = timeout_ms --[[:! number|nil]]
  -- We need a temporary "caller" mechanism without a real actor for the
  -- return channel. We use a single-element result table and a unique reply_to
  -- pid: the pid of a synthetic receiver actor.
  local result_box = {} --: { [integer]: any }
  local caller_pid = self_._next_pid
  self_._next_pid = caller_pid + 1

  -- Create a synthetic one-shot actor that just receives one message.
  local reply_actor = make_actor(caller_pid, function(ctx)
    local ctx_ = ctx --[[:! ActorCtxShape]]
    local reply = ctx_:receive(timeout_ms_)
    result_box[1] = reply
  end, {} --[[:! { name: string|nil, restart: string|nil, mailbox_size: integer|nil }]], self_)
  self_._actors[caller_pid] = reply_actor

  -- Inject reply_to into msg
  msg = msg or {}
  local msg_ = msg --[[:! { [string]: any }]]
  msg_["reply_to"] = caller_pid

  -- Send the message
  self_:send(pid, msg_)

  -- Drive the system until the reply actor is dead or timeout
  local clock_fn = self_._clock_fn
  local deadline --: number|nil
  if timeout_ms_ ~= nil then
    deadline = clock_fn() + timeout_ms_ / 1000.0
  end

  local max_steps = 10000
  local steps = 0
  while reply_actor._status == "running" and steps < max_steps do
    steps = steps + 1
    self_:step()
    local dl2_ = deadline --: number|nil
    if dl2_ ~= nil and clock_fn() >= dl2_ then
      break
    end
  end

  -- Clean up synthetic actor
  self_._actors[caller_pid] = nil

  return result_box[1]
end

function System:whereis(name)
  local self_ = self --[[:! SystemShape]]
  return self_._names[name]
end

function System:stop(pid)
  local self_ = self --[[:! SystemShape]]
  local actor = self_._actors[pid]
  if not actor then return end
  self_:_kill_actor(actor, "stopped")
end

function System:alive(pid)
  local self_ = self --[[:! SystemShape]]
  local actor = self_._actors[pid]
  return actor ~= nil and actor._status == "running"
end

function System:actor_count()
  local self_ = self --[[:! SystemShape]]
  local n = 0
  for _ in pairs(self_._actors) do
    n = n + 1
  end
  return n
end

-- Resume an actor's coroutine, catching errors, and handle exit.
function System:_resume_actor(actor)
  local self_ = self --[[:! SystemShape]]
  local actor_ = actor --[[:! ActorRecord]]
  if actor_._status ~= "running" then return end
  local co_ = actor_._co --[[: any]]
  if co_status(co_) == "dead" then
    self_:_kill_actor(actor, "normal")
    return
  end
  local ok, val = co_resume(co_)
  if not ok then
    -- val is the error message
    self_:_kill_actor(actor_, tostring(val))
    return
  end
  -- val is the deadline yielded from receive (or nil)
  actor_._deadline = val --[[:! number|nil]]
  -- If coroutine finished normally
  if co_status(co_) == "dead" then
    self_:_kill_actor(actor_, "normal")
  end
end

function System:_kill_actor(actor, reason)
  local self_ = self --[[:! SystemShape]]
  local actor_ = actor --[[:! ActorRecord]]
  if actor_._status == "dead" then return end
  actor_._status = "dead"
  actor_._exit_reason = reason
  local pid = actor_._pid

  -- Remove name registration
  if actor_._name then
    self_._names[actor_._name] = nil
  end

  -- Notify linked actors
  for linked_pid in pairs(actor_._links) do
    local lp_ = linked_pid --[[:! integer]]
    local linked = self_._actors[lp_]
    if linked and linked._status == "running" then
      -- Remove reciprocal link first to avoid re-notification
      linked._links[pid] = nil
      -- Send exit signal
      self_:send(lp_, {type = "exit", pid = pid, reason = reason})
    end
  end

  -- Notify monitors
  for ref, observer_pid in pairs(actor_._monitors) do
    local op_ = observer_pid --[[:! integer]]
    local observer = self_._actors[op_]
    if observer and observer._status == "running" then
      self_:send(op_, {type = "down", pid = pid, ref = ref, reason = reason})
    end
  end

  -- Remove from system (after notifications so send() still works for observers)
  self_._actors[pid] = nil
end

function System:step()
  local self_ = self --[[:! SystemShape]]
  -- Collect actors to step (snapshot — actors may die during step)
  local to_step = {} --: { [integer]: ActorRecord }
  local now = self_._clock_fn()
  for _, actor in pairs(self_._actors) do
    if actor._status == "running" then
      local has_mail  = #actor._mailbox > 0
      local dl = actor._deadline --: number|nil
      local timed_out = dl ~= nil and now >= dl
      local co_ = actor._co --[[: any]]
      local suspended = co_status(co_) == "suspended"
      if (has_mail or timed_out) and suspended then
        to_step[#to_step + 1] = actor
      end
    end
  end
  for i = 1, #to_step do
    local actor = to_step[i]
    if actor._status == "running" then
      self_:_resume_actor(actor)
    end
  end
end

function System:run(n)
  local self_ = self --[[:! SystemShape]]
  for _ = 1, n do
    self_:step()
  end
end

function System:run_until_idle()
  local self_ = self --[[:! SystemShape]]
  local max = 100000
  for _ = 1, max do
    -- Check if any actor has pending messages or timed-out deadlines
    local now = self_._clock_fn()
    local active = false
    for _, actor in pairs(self_._actors) do
      if actor._status == "running" then
        local has_mail  = #actor._mailbox > 0
        local dl = actor._deadline --: number|nil
        local timed_out = dl ~= nil and now >= dl
        if has_mail or timed_out then
          active = true
          break
        end
      end
    end
    if not active then break end
    self_:step()
  end
end

-- ---------------------------------------------------------------------------
-- Supervisor
-- ---------------------------------------------------------------------------

local Supervisor = {}
Supervisor.__index = Supervisor

function System:supervisor(opts)
  local self_ = self --[[:! SystemShape]]
  opts = opts or {}
  local opts_ = opts --[[:! { strategy: string|nil, max_restarts: integer|nil, period: number|nil, name: string|nil, children: { [integer]: any }|nil }]]
  local sup = setmetatable({
    _system       = self_,
    _strategy     = opts_.strategy or "one_for_one",
    _max_restarts = opts_.max_restarts or 3,
    _period       = opts_.period or 5,
    _children     = {},   -- array of {id, fn, restart, pid}
    _failures     = {},   -- id -> {times=[], ...}
    _pid          = nil,
  }, Supervisor) --[[: any]]
  local sup_ = sup --[[:! SupervisorShape]]

  -- Spawn supervisor actor
  local sup_pid = self_:spawn(function(ctx)
    while true do
      local ctx_ = ctx --[[:! ActorCtxShape]]
      local msg = ctx_:receive()
      if msg == nil then break end
      local msg_ = msg --[[:! { type: string, id: string, reason: string }]]
      if msg_.type == "child_exit" then
        sup_:_handle_exit(msg_.id, msg_.reason, ctx)
      end
    end
  end, {name = opts_.name})
  sup_._pid = sup_pid

  -- Pre-register ALL children before spawning any, so that if a child crashes
  -- synchronously on first resume, _handle_exit sees the full children list
  -- (needed for one_for_all / rest_for_one strategies).
  local children_ = opts_.children
  if children_ then
    for _, spec in ipairs(children_) do
      local spec_ = spec --[[:! { id: string, fn: any, restart: string|nil, name: string|nil }]]
      local entry = {
        id      = spec_.id,
        fn      = spec_.fn,
        restart = spec_.restart or "temporary",
        pid     = nil,
        name    = spec_.name,
      }
      sup_._children[#sup_._children + 1] = entry
      sup_._failures[spec_.id] = sup_._failures[spec_.id] or {times = {}}
    end
    -- Now spawn them all
    for i = 1, #sup_._children do
      sup_:_spawn_child(sup_._children[i])
    end
  end

  return sup_
end

--:: ChildEntry = { id: string, fn: any, restart: string, pid: integer|nil, name: string|nil }
--:: FailureRec = { times: { [integer]: number } }

-- Spawn the coroutine for an already-registered child entry.
function Supervisor:_spawn_child(entry)
  local self_ = self --[[:! SupervisorShape]]
  local sys_ = self_._system
  local entry_ = entry --[[:! ChildEntry]]
  local child_id = entry_.id
  local fn = entry_.fn
  local sup_pid = self_._pid

  local wrapped = function(ctx)
    local ok, err = pcall(fn, ctx)
    local reason = ok and "normal" or tostring(err)
    local spid = sup_pid --[[:! integer]]
    sys_:send(spid, {type = "child_exit", id = child_id, reason = reason})
  end

  local pid = sys_:spawn(wrapped, {name = entry_.name})
  -- Only set entry.pid if _handle_exit hasn't already updated it during
  -- a synchronous crash + restart that happened inside spawn().
  if entry_.pid == nil then
    entry_.pid = pid
  end
  return pid
end

function Supervisor:_start_child(spec)
  local self_ = self --[[:! SupervisorShape]]
  local spec_ = spec --[[:! ChildEntry]]
  -- Register and spawn a new child (used for dynamic child addition or restart).
  local entry = {
    id      = spec_.id,
    fn      = spec_.fn,
    restart = spec_.restart or "temporary",
    pid     = nil,
    name    = spec_.name,
  }
  self_._children[#self_._children + 1] = entry
  self_._failures[spec_.id] = self_._failures[spec_.id] or {times = {}}
  self_:_spawn_child(entry)
  local entry_ = entry --[[:! ChildEntry]]
  return entry_.pid
end

function Supervisor:_find_child(id)
  local self_ = self --[[:! SupervisorShape]]
  for i, c in ipairs(self_._children) do
    local c_ = c --[[:! ChildEntry]]
    if c_.id == id then return c_, i end
  end
  return nil, nil
end

function Supervisor:_should_restart(child, reason)
  local child_ = child --[[:! ChildEntry]]
  local r = child_.restart
  if r == "permanent" then return true end
  if r == "temporary" then return false end
  if r == "transient" then return reason ~= "normal" end
  return false
end

function Supervisor:_record_failure(id)
  local self_ = self --[[:! SupervisorShape]]
  local now = self_._system._clock_fn()
  local rec = self_._failures[id] --[[:! FailureRec]]
  -- Prune old failures outside the period window
  local period = self_._period
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
  local self_ = self --[[:! SupervisorShape]]
  local child = self_:_find_child(id)
  if not child then return end
  local child_ = child --[[:! ChildEntry]]

  if not self_:_should_restart(child_, reason) then
    -- Remove child from list
    for i, c in ipairs(self_._children) do
      local c_ = c --[[:! ChildEntry]]
      if c_.id == id then
        table.remove(self_._children, i)
        break
      end
    end
    return
  end

  -- Check restart intensity
  local count = self_:_record_failure(id)
  if count > self_._max_restarts then
    -- Exceeded — stop supervisor itself (simplified: just stop)
    return
  end

  local strategy = self_._strategy
  if strategy == "one_for_one" then
    -- Restart only the failed child by re-using its existing entry.
    child_.pid = nil  -- clear so _spawn_child sets it
    self_:_spawn_child(child_)
  elseif strategy == "one_for_all" then
    -- Stop all other living children, then rebuild the children list and
    -- spawn all of them. Pre-register all entries before spawning any so
    -- that if a restarted child crashes synchronously, _handle_exit can
    -- see the complete children list.
    local entries = {} --: { [integer]: ChildEntry }
    for _, c in ipairs(self_._children) do
      local c_ = c --[[:! ChildEntry]]
      entries[#entries + 1] = {id = c_.id, fn = c_.fn, restart = c_.restart, name = c_.name, pid = nil}
      if c_.id ~= id and c_.pid then
        self_._system:stop(c_.pid --[[:! integer]])
      end
    end
    self_._children = {}
    -- Pre-register all
    for _, e in ipairs(entries) do
      local e_ = e --[[:! ChildEntry]]
      local new_entry = {id = e_.id, fn = e_.fn, restart = e_.restart, name = e_.name, pid = nil}
      self_._children[#self_._children + 1] = new_entry
      self_._failures[e_.id] = self_._failures[e_.id] or {times = {}}
    end
    -- Spawn all
    for i = 1, #self_._children do
      self_:_spawn_child(self_._children[i])
    end
  elseif strategy == "rest_for_one" then
    -- Stop children started after the failed one, then restart from failed onward.
    local found = false
    local to_restart_entries = {} --: { [integer]: ChildEntry }
    for _, c in ipairs(self_._children) do
      local c_ = c --[[:! ChildEntry]]
      if c_.id == id then
        found = true
        to_restart_entries[#to_restart_entries + 1] = c_
      elseif found then
        if c_.pid then self_._system:stop(c_.pid --[[:! integer]]) end
        to_restart_entries[#to_restart_entries + 1] = c_
      end
    end
    -- Reset pids for entries to restart
    for _, e in ipairs(to_restart_entries) do
      local e_ = e --[[:! ChildEntry]]
      e_.pid = nil
    end
    -- Spawn them in order
    for _, e in ipairs(to_restart_entries) do
      local e_ = e --[[:! ChildEntry]]
      self_:_spawn_child(e_)
    end
  end
end

function Supervisor:get_pid(id)
  local self_ = self --[[:! SupervisorShape]]
  local child = self_:_find_child(id)
  if child then
    local child_ = child --[[:! ChildEntry]]
    return child_.pid
  end
  return nil
end

return M
