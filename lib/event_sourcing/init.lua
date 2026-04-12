-- lib/event_sourcing/init.lua
-- Event sourcing pattern: append-only event log with projections, snapshots, sagas.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function next_id()
    -- Simple monotonic id using a module-level counter + timestamp hint.
    -- Not globally unique across processes, but sufficient for in-process use.
    M._id_counter = (M._id_counter or 0) + 1
    return M._id_counter
end

-- ── Event Store ───────────────────────────────────────────────────────────────

--:: EventStore = {
--::   append: (self, aggregate_id: string, event_type: string, payload: unknown, metadata: unknown) -> unknown
--::   events_for: (self, aggregate_id: string) -> unknown
--::   events_after: (self, sequence: number) -> unknown
--::   events_of_type: (self, event_type: string) -> unknown
--::   all_events: (self) -> unknown
--::   event_count: (self) -> number
--::   latest_sequence: (self, aggregate_id: string) -> number
--:: }

local EventStore = {}
EventStore.__index = EventStore

function EventStore:append(aggregate_id, event_type, payload, metadata)
    if type(aggregate_id) ~= "string" or aggregate_id == "" then
        return nil, "aggregate_id must be a non-empty string"
    end
    if type(event_type) ~= "string" or event_type == "" then
        return nil, "event_type must be a non-empty string"
    end

    self._global_sequence = self._global_sequence + 1

    if not self._by_aggregate[aggregate_id] then
        self._by_aggregate[aggregate_id] = {}
    end
    local agg_events = self._by_aggregate[aggregate_id]
    local seq = #agg_events + 1

    local event = {
        id               = next_id(),
        aggregate_id     = aggregate_id,
        event_type       = event_type,
        payload          = payload,
        metadata         = metadata or {},
        sequence         = seq,
        global_sequence  = self._global_sequence,
    }

    agg_events[seq] = event
    self._all[#self._all + 1] = event

    if self._max_events and #self._all > self._max_events then
        return nil, "event store at capacity"
    end

    return event
end

function EventStore:events_for(aggregate_id)
    local agg = self._by_aggregate[aggregate_id]
    if not agg then return {} end
    local result = {}
    for i = 1, #agg do result[i] = agg[i] end
    return result
end

function EventStore:events_after(sequence)
    local result = {}
    for i = 1, #self._all do
        local e = self._all[i]
        if e.global_sequence > sequence then
            result[#result + 1] = e
        end
    end
    return result
end

function EventStore:events_of_type(event_type)
    local result = {}
    for i = 1, #self._all do
        local e = self._all[i]
        if e.event_type == event_type then
            result[#result + 1] = e
        end
    end
    return result
end

function EventStore:all_events()
    local result = {}
    for i = 1, #self._all do result[i] = self._all[i] end
    return result
end

function EventStore:event_count()
    return #self._all
end

function EventStore:latest_sequence(aggregate_id)
    local agg = self._by_aggregate[aggregate_id]
    if not agg or #agg == 0 then return 0 end
    return #agg
end

-- Create a new event store.
-- opts.max_events: optional capacity limit
function M.store(opts)
    opts = opts or {}
    local self = setmetatable({}, EventStore)
    self._by_aggregate  = {}
    self._all           = {}
    self._global_sequence = 0
    self._max_events    = opts.max_events
    return self
end

-- ── Aggregate ─────────────────────────────────────────────────────────────────

local Aggregate = {}
Aggregate.__index = Aggregate

function Aggregate:apply(event)
    local handler = self._handlers[event.event_type]
    if handler then
        local new_state = handler(self._state, event)
        if new_state ~= nil then
            self._state = new_state
        end
    end
    self._version = self._version + 1
end

function Aggregate:replay(events)
    for i = 1, #events do
        self:apply(events[i])
    end
end

function Aggregate:state()
    return self._state
end

function Aggregate:version()
    return self._version
end

-- Create a new aggregate.
-- opts.handlers = {event_type = function(state, event) return new_state end}
-- opts.initial_state: starting state (deep copy not performed — caller owns it)
function M.aggregate(aggregate_id, opts)
    opts = opts or {}
    local self = setmetatable({}, Aggregate)
    self._id       = aggregate_id
    self._handlers = opts.handlers or {}
    self._state    = opts.initial_state or {}
    self._version  = 0
    return self
end

-- ── Projection ────────────────────────────────────────────────────────────────

local Projection = {}
Projection.__index = Projection

function Projection:handle(event)
    local handler = self._handlers[event.event_type]
    if handler then
        local new_state = handler(self._state, event)
        if new_state ~= nil then
            self._state = new_state
        end
    end
    if event.global_sequence and event.global_sequence > self._checkpoint then
        self._checkpoint = event.global_sequence
    end
end

function Projection:handle_all(events)
    for i = 1, #events do
        self:handle(events[i])
    end
end

function Projection:state()
    return self._state
end

function Projection:checkpoint()
    return self._checkpoint
end

-- Create a new projection.
-- opts.handlers = {event_type = function(state, event) return new_state end}
-- opts.initial_state: starting state
function M.projection(name, opts)
    opts = opts or {}
    local self = setmetatable({}, Projection)
    self._name       = name
    self._handlers   = opts.handlers or {}
    self._state      = opts.initial_state or {}
    self._checkpoint = 0
    return self
end

-- ── Snapshot Store ────────────────────────────────────────────────────────────

local SnapshotStore = {}
SnapshotStore.__index = SnapshotStore

function SnapshotStore:save(aggregate_id, state, version)
    if type(aggregate_id) ~= "string" or aggregate_id == "" then
        return nil, "aggregate_id must be a non-empty string"
    end
    self._snaps[aggregate_id] = { state = state, version = version }
    -- Track most recent by version across all aggregates.
    if not self._latest or version > self._latest.version then
        self._latest = { aggregate_id = aggregate_id, version = version }
    end
    return true
end

function SnapshotStore:load(aggregate_id)
    return self._snaps[aggregate_id]
end

function SnapshotStore:latest()
    return self._latest
end

function SnapshotStore:clear(aggregate_id)
    self._snaps[aggregate_id] = nil
    -- Recompute latest if we cleared the latest.
    if self._latest and self._latest.aggregate_id == aggregate_id then
        self._latest = nil
        for id, snap in pairs(self._snaps) do
            if not self._latest or snap.version > self._latest.version then
                self._latest = { aggregate_id = id, version = snap.version }
            end
        end
    end
end

function M.snapshot_store()
    local self = setmetatable({}, SnapshotStore)
    self._snaps  = {}
    self._latest = nil
    return self
end

-- ── Saga ──────────────────────────────────────────────────────────────────────

local Saga = {}
Saga.__index = Saga

function Saga:handle(event)
    if self._done then return {} end

    local step = self._steps[self._step_index]
    if not step then
        self._done = true
        return {}
    end

    if event.event_type ~= step.event_type then
        -- Not the event this step is waiting for; ignore.
        return {}
    end

    local new_state, commands = step.handler(self._state, event)
    if new_state ~= nil then
        self._state = new_state
    end
    self._step_index = self._step_index + 1
    if self._step_index > #self._steps then
        self._done = true
    end
    return commands or {}
end

function Saga:state()
    return self._state
end

function Saga:done()
    return self._done
end

-- Create a new saga.
-- opts.steps = array of {event_type, handler(state, event) -> new_state, commands}
-- opts.initial_state: starting state
function M.saga(name, opts)
    opts = opts or {}
    local self = setmetatable({}, Saga)
    self._name        = name
    self._steps       = opts.steps or {}
    self._state       = opts.initial_state or {}
    self._step_index  = 1
    self._done        = #self._steps == 0
    return self
end

-- ── Command ───────────────────────────────────────────────────────────────────

-- Create a CQRS command object.
function M.command(cmd_type, payload, metadata)
    return {
        id        = next_id(),
        type      = cmd_type,
        payload   = payload or {},
        metadata  = metadata or {},
        timestamp = os.time(),
    }
end

return M
