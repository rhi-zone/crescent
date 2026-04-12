-- lib/event_sourcing/init.lua
-- Event sourcing primitives: event store, aggregate roots, projections,
-- sagas (process managers), and snapshot-aware aggregate loading.
--
-- Design:
--   - Events are immutable plain tables.
--   - The store is in-memory; callers inject persistence by wrapping it or by
--     reading/writing the streams themselves.
--   - Optimistic concurrency: expected_version must match stream length.
--   - Projections are pure functions over event streams — no side effects.
--   - Snapshots reduce replay cost for long-lived aggregates.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--: string
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local _id_seq = 0
local function next_id()
  _id_seq = _id_seq + 1
  return _id_seq
end

local function shallow_copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

-- ---------------------------------------------------------------------------
-- Event constructor
-- M.event(type, data, opts) -> event
--   opts: { aggregate_id, aggregate_type, version, metadata }
--
-- Returns a plain table:
--   { id, type, aggregate_id, aggregate_type, version, timestamp, data, metadata }
-- ---------------------------------------------------------------------------

function M.event(event_type, data, opts)
  opts = opts or {}
  return {
    id             = next_id(),
    type           = event_type,
    aggregate_id   = opts.aggregate_id,
    aggregate_type = opts.aggregate_type,
    version        = opts.version or 0,
    timestamp      = os.time(),
    data           = data or {},
    metadata       = opts.metadata or {},
  }
end

-- ---------------------------------------------------------------------------
-- Event store
-- M.store() -> store
-- ---------------------------------------------------------------------------

local Store = {}
Store.__index = Store

-- store:append(aggregate_id, events, expected_version) -> true | nil, err
--   expected_version:
--     nil  — no version check
--     0    — stream must not yet exist
--     n    — stream must currently be at exactly version n (optimistic concurrency)
function Store:append(aggregate_id, events, expected_version)
  if not aggregate_id then
    return nil, "aggregate_id required"
  end
  if type(events) ~= "table" then
    return nil, "events must be a table"
  end

  local stream = self._streams[aggregate_id]
  if not stream then
    stream = {}
    self._streams[aggregate_id] = stream
  end

  local current_version = #stream

  if expected_version ~= nil then
    if current_version ~= expected_version then
      return nil, "concurrency conflict: expected version " ..
        tostring(expected_version) .. " but stream is at " ..
        tostring(current_version)
    end
  end

  for i = 1, #events do
    local ev = events[i]
    local version = current_version + i
    local stamped = shallow_copy(ev)
    stamped.aggregate_id  = aggregate_id
    stamped.version       = version
    stamped.position      = self._global_position + 1
    self._global_position = self._global_position + 1
    stream[version] = stamped
    -- Notify subscribers.
    for j = 1, #self._subscribers do
      self._subscribers[j](stamped)
    end
  end

  return true
end

-- store:load(aggregate_id, opts) -> events
--   opts: { from_version, to_version, limit }
function Store:load(aggregate_id, opts)
  opts = opts or {}
  local stream = self._streams[aggregate_id]
  if not stream then return {} end

  local from  = opts.from_version or 1
  local to    = opts.to_version   or #stream
  local limit = opts.limit

  local out   = {}
  local count = 0
  for v = from, to do
    if stream[v] then
      count = count + 1
      out[count] = stream[v]
      if limit and count >= limit then break end
    end
  end
  return out
end

-- store:load_all(opts) -> events  (ordered by global position)
--   opts: { from_position, limit, aggregate_type }
function Store:load_all(opts)
  opts = opts or {}
  local from_pos   = opts.from_position or 1
  local limit      = opts.limit
  local filter_type = opts.aggregate_type

  local all = {}
  for _, stream in pairs(self._streams) do
    for _, ev in ipairs(stream) do
      if ev.position >= from_pos then
        if not filter_type or ev.aggregate_type == filter_type then
          all[#all + 1] = ev
        end
      end
    end
  end
  table.sort(all, function(a, b) return a.position < b.position end)

  if limit and #all > limit then
    local trimmed = {}
    for i = 1, limit do trimmed[i] = all[i] end
    return trimmed
  end
  return all
end

-- store:subscribe(handler)  — handler(event) called for each appended event
function Store:subscribe(handler)
  self._subscribers[#self._subscribers + 1] = handler
end

-- store:snapshot(aggregate_id, state, version)
function Store:snapshot(aggregate_id, state, version)
  self._snapshots[aggregate_id] = { state = state, version = version }
end

-- store:load_snapshot(aggregate_id) -> { state, version } | nil
function Store:load_snapshot(aggregate_id)
  return self._snapshots[aggregate_id]
end

function M.store()
  return setmetatable({
    _streams         = {},
    _snapshots       = {},
    _subscribers     = {},
    _global_position = 0,
  }, Store)
end

-- ---------------------------------------------------------------------------
-- Aggregate root
-- M.aggregate(agg_type, handlers) -> aggregate_class
--   handlers: { EventType = function(state, event) -> new_state }
--
-- aggregate_class.new(id) -> agg
-- agg:apply(events) -> agg          (replay; mutates in place, returns self)
-- agg:raise(event_type, data) -> agg (stage + apply one event, returns self)
-- agg.pending_events                (uncommitted events)
-- agg.version                       (integer)
-- agg.state                         (current state table)
-- agg.id                            (aggregate id)
-- ---------------------------------------------------------------------------

function M.aggregate(agg_type, handlers)
  local AggClass   = {}
  AggClass.__index = AggClass

  function AggClass.new(id)
    return setmetatable({
      id             = id,
      version        = 0,
      state          = {},
      pending_events = {},
    }, AggClass)
  end

  -- Replay a list of already-stored events (no enqueueing).
  function AggClass:apply(events)
    for i = 1, #events do
      local ev      = events[i]
      local handler = handlers[ev.type]
      if handler then
        self.state = handler(self.state, ev) or self.state
      end
      self.version = ev.version
    end
    return self
  end

  -- Stage a new domain event: construct it, apply it locally, enqueue it.
  function AggClass:raise(event_type, data)
    local next_version = self.version + 1
    local ev = M.event(event_type, data, {
      aggregate_id   = self.id,
      aggregate_type = agg_type,
      version        = next_version,
    })
    local handler = handlers[event_type]
    if handler then
      self.state = handler(self.state, ev) or self.state
    end
    self.version = next_version
    self.pending_events[#self.pending_events + 1] = ev
    return self
  end

  return AggClass
end

-- ---------------------------------------------------------------------------
-- Projection (read model)
-- M.projection(handlers) -> proj
--   handlers: { EventType = function(state, event) -> new_state }
--
-- proj:handle(event) -> proj
-- proj:handle_all(events) -> proj
-- proj.state
-- ---------------------------------------------------------------------------

function M.projection(handlers)
  local proj = {
    state     = {},
    _handlers = handlers,
  }

  function proj:handle(event)
    local handler = self._handlers[event.type]
    if handler then
      self.state = handler(self.state, event) or self.state
    end
    return self
  end

  function proj:handle_all(events)
    for i = 1, #events do
      self:handle(events[i])
    end
    return self
  end

  return proj
end

-- ---------------------------------------------------------------------------
-- Saga (process manager — coordinates across aggregates)
-- M.saga(handlers) -> saga_class
--   handlers: { EventType = function(state, event) -> { commands = [...], state = ... } }
--
-- saga_class.new() -> saga_instance
-- saga_instance:handle(event) -> { commands }
-- saga_instance.state
-- ---------------------------------------------------------------------------

function M.saga(handlers)
  local SagaClass   = {}
  SagaClass.__index = SagaClass

  function SagaClass.new()
    return setmetatable({ state = {} }, SagaClass)
  end

  function SagaClass:handle(event)
    local handler = handlers[event.type]
    if not handler then
      return { commands = {} }
    end
    local result = handler(self.state, event)
    if result and result.state ~= nil then
      self.state = result.state
    end
    return { commands = result and result.commands or {} }
  end

  return SagaClass
end

-- ---------------------------------------------------------------------------
-- Snapshot-aware aggregate loader
-- M.load_aggregate(store, aggregate_class, id) -> agg | nil, err
--   1. Load snapshot (if any).
--   2. Replay events from snapshot version + 1 onwards.
-- ---------------------------------------------------------------------------

function M.load_aggregate(store, aggregate_class, id)
  if not store then           return nil, "store required" end
  if not aggregate_class then return nil, "aggregate_class required" end
  if not id then              return nil, "id required" end

  local agg  = aggregate_class.new(id)
  local snap = store:load_snapshot(id)
  if snap then
    agg.state   = snap.state
    agg.version = snap.version
  end

  local events = store:load(id, { from_version = agg.version + 1 })
  agg:apply(events)

  return agg
end

return M
