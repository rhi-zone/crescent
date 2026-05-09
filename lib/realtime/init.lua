if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── Subscription ────────────────────────────────────────────────────────

--:: Subscription = { unsubscribe: () -> () }

--:: SubImpl = { _hub: HubImpl, _topic: string, _callback: (string, unknown, unknown) -> (), _is_pattern: boolean, _lua_pattern: string | nil, _removed: boolean, id: integer, unsubscribe: (self: SubImpl) -> () }
--:: HubImpl = { _subs: SubImpl[], _exact: { [string]: SubImpl[] }, _next_id: integer, subscribe: (self: HubImpl, string, (string, unknown, unknown) -> ()) -> SubImpl, publish: (self: HubImpl, string, unknown, unknown) -> (), subscribers: (self: HubImpl, string) -> number, topics: (self: HubImpl) -> string[], has_subscribers: (self: HubImpl, string) -> boolean }

local Sub = {}
Sub.__index = Sub

--: (self: SubImpl) -> ()
function Sub:unsubscribe()
	if self._removed then return end
	self._removed = true
	local subs = self._hub._subs
	for i = #subs, 1, -1 do
		if subs[i] == self then
			table.remove(subs, i)
			break
		end
	end
	-- Remove from exact-match index if not a pattern subscription
	if not self._is_pattern then
		local exact = self._hub._exact[self._topic]
		if exact then
			for i = #exact, 1, -1 do
				if exact[i] == self then
					table.remove(exact, i)
					break
				end
			end
			if #exact == 0 then
				self._hub._exact[self._topic] = nil
			end
		end
	end
end

-- ── Hub (pub/sub) ───────────────────────────────────────────────────────

--:: Hub = { subscribe: (string, (string, unknown, unknown) -> ()) -> Subscription, publish: (string, unknown, unknown) -> (), subscribers: (string) -> number, topics: () -> string[], has_subscribers: (string) -> boolean }

local Hub = {}
Hub.__index = Hub

--: () -> HubImpl
function M.hub()
	return setmetatable({
		_subs = {},          -- all subscriptions (for pattern scan)
		_exact = {},         -- topic -> {sub, ...} for exact-match fast path
		_next_id = 1,
	}, Hub) --[[:! HubImpl]]
end

-- Convert a pattern with `*` wildcards into a Lua pattern.
-- `*` matches one segment (anything except `:`).
--: (string) -> string
local function topic_to_pattern(pat)
	-- Escape Lua magic characters except `*`
	local escaped = pat:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1")
	-- Replace `*` with `[^:]*` (one segment)
	escaped = escaped:gsub("%*", "[^:]*")
	return "^" .. escaped .. "$"
end

--: (string) -> boolean
local function has_wildcard(topic)
	return topic:find("*", 1, true) ~= nil
end

--: (self: HubImpl, string, (string, unknown, unknown) -> ()) -> SubImpl
function Hub:subscribe(topic, callback)
	local sub = setmetatable({
		_hub = self,
		_topic = topic,
		_callback = callback,
		_is_pattern = has_wildcard(topic),
		_lua_pattern = has_wildcard(topic) and topic_to_pattern(topic) or nil,
		_removed = false,
		id = self._next_id,
	}, Sub) --[[:! SubImpl]]
	self._next_id = self._next_id + 1
	self._subs[#self._subs + 1] = sub
	-- Index exact-match subscriptions for fast publish
	if not sub._is_pattern then
		local exact = self._exact[topic]
		if not exact then
			exact = {}
			self._exact[topic] = exact
		end
		exact[#exact + 1] = sub
	end
	return sub
end

--: (self: HubImpl, string, unknown, unknown) -> ()
function Hub:publish(topic, message, sender)
	-- Exact-match subscribers
	local exact = self._exact[topic]
	if exact then
		for i = 1, #exact do
			exact[i]._callback(topic, message, sender)
		end
	end
	-- Pattern subscribers
	for i = 1, #self._subs do
		local sub = self._subs[i]
		if sub._is_pattern and topic:match(sub._lua_pattern) then
			sub._callback(topic, message, sender)
		end
	end
end

--: (self: HubImpl, string) -> number
function Hub:subscribers(topic)
	local count = 0
	for i = 1, #self._subs do
		local sub = self._subs[i]
		if sub._topic == topic or (sub._is_pattern and topic:match(sub._lua_pattern)) then
			count = count + 1
		end
	end
	return count
end

--: (self: HubImpl) -> string[]
function Hub:topics()
	local seen = {}
	local result = {}
	for i = 1, #self._subs do
		local t = self._subs[i]._topic
		if not seen[t] then
			seen[t] = true
			result[#result + 1] = t
		end
	end
	table.sort(result)
	return result
end

--: (self: HubImpl, string) -> boolean
function Hub:has_subscribers(topic)
	return self:subscribers(topic) > 0
end

-- ── Presence ────────────────────────────────────────────────────────────

--:: presence_meta = { [string]: unknown }
--:: Presence = { join: (string, string, presence_meta) -> (), leave: (string, string) -> (), update: (string, string, presence_meta) -> (), list: (string) -> { { id: string, meta: presence_meta } }, get: (string, string) -> presence_meta | nil, count: (string) -> number, on_join: ((string, string, presence_meta) -> ()) -> (), on_leave: ((string, string, presence_meta) -> ()) -> (), on_update: ((string, string, presence_meta) -> ()) -> () }
--:: PresenceImpl = { _rooms: { [string]: { [string]: presence_meta } }, _on_join: ((string, string, presence_meta) -> ())[], _on_leave: ((string, string, presence_meta) -> ())[], _on_update: ((string, string, presence_meta) -> ())[], join: (self: PresenceImpl, string, string, presence_meta) -> (), leave: (self: PresenceImpl, string, string) -> (), update: (self: PresenceImpl, string, string, presence_meta) -> (), list: (self: PresenceImpl, string) -> { { id: string, meta: presence_meta } }, get: (self: PresenceImpl, string, string) -> presence_meta | nil, count: (self: PresenceImpl, string) -> number, on_join: (self: PresenceImpl, (string, string, presence_meta) -> ()) -> (), on_leave: (self: PresenceImpl, (string, string, presence_meta) -> ()) -> (), on_update: (self: PresenceImpl, (string, string, presence_meta) -> ()) -> () }

local Presence = {}
Presence.__index = Presence

--: () -> PresenceImpl
function M.presence()
	return setmetatable({
		_rooms = {},         -- room -> {user_id -> meta}
		_on_join = {},
		_on_leave = {},
		_on_update = {},
	}, Presence) --[[:! PresenceImpl]]
end

--: (self: PresenceImpl, string, string, presence_meta) -> ()
function Presence:join(room, user_id, meta)
	local r = self._rooms[room]
	if not r then
		r = {}
		self._rooms[room] = r
	end
	r[user_id] = meta or {}
	local hooks = self._on_join
	for i = 1, #hooks do
		hooks[i](room, user_id, r[user_id])
	end
end

--: (self: PresenceImpl, string, string) -> ()
function Presence:leave(room, user_id)
	local r = self._rooms[room]
	if not r then return end
	local meta = r[user_id]
	if not meta then return end
	r[user_id] = nil
	-- Clean up empty rooms
	if not next(r) then
		self._rooms[room] = nil
	end
	local hooks = self._on_leave
	for i = 1, #hooks do
		hooks[i](room, user_id, meta)
	end
end

--: (self: PresenceImpl, string, string, presence_meta) -> ()
function Presence:update(room, user_id, meta)
	local r = self._rooms[room]
	if not r or not r[user_id] then return end
	-- Merge new metadata into existing
	local existing = r[user_id]
	for k, v in pairs(meta) do
		existing[k] = v
	end
	local hooks = self._on_update
	for i = 1, #hooks do
		hooks[i](room, user_id, existing)
	end
end

--: (self: PresenceImpl, string) -> { { id: string, meta: presence_meta } }
function Presence:list(room)
	local r = self._rooms[room]
	if not r then return {} end
	local result = {}
	for user_id, meta in pairs(r) do
		result[#result + 1] = { id = user_id, meta = meta }
	end
	table.sort(result, function(a, b) return a.id < b.id end)
	return result
end

--: (self: PresenceImpl, string, string) -> presence_meta | nil
function Presence:get(room, user_id)
	local r = self._rooms[room]
	if not r then return nil end
	return r[user_id]
end

--: (self: PresenceImpl, string) -> number
function Presence:count(room)
	local r = self._rooms[room]
	if not r then return 0 end
	local n = 0
	for _ in pairs(r) do
		n = n + 1
	end
	return n
end

--: (self: PresenceImpl, (string, string, presence_meta) -> ()) -> ()
function Presence:on_join(fn)
	self._on_join[#self._on_join + 1] = fn
end

--: (self: PresenceImpl, (string, string, presence_meta) -> ()) -> ()
function Presence:on_leave(fn)
	self._on_leave[#self._on_leave + 1] = fn
end

--: (self: PresenceImpl, (string, string, presence_meta) -> ()) -> ()
function Presence:on_update(fn)
	self._on_update[#self._on_update + 1] = fn
end

-- ── Event Store ─────────────────────────────────────────────────────────

--:: event_data = { [string]: unknown }
--:: event_input = { type: string, data: event_data }
--:: read_opts = { after?: number, limit?: integer }
--:: Event = { seq: number, global_seq: number, type: string, data: event_data, timestamp: number }
--:: EventStore = { append: (string, event_input) -> (), read: (string, (read_opts | nil)) -> Event[], read_all: ((read_opts | nil)) -> Event[], on_append: ((string, Event) -> ()) -> (), aggregate: (string, (unknown, Event) -> unknown) -> unknown, streams: () -> string[], stream_length: (string) -> number }
--:: EventStoreImpl = { _streams: { [string]: Event[] }, _global_seq: number, _on_append: ((string, Event) -> ())[], _time_fn: () -> number, append: (self: EventStoreImpl, string, event_input) -> (), read: (self: EventStoreImpl, string, (read_opts | nil)) -> Event[], read_all: (self: EventStoreImpl, (read_opts | nil)) -> Event[], on_append: (self: EventStoreImpl, (string, Event) -> ()) -> (), aggregate: (self: EventStoreImpl, string, (unknown, Event) -> unknown) -> unknown, streams: (self: EventStoreImpl) -> string[], stream_length: (self: EventStoreImpl, string) -> number }

local EventStore = {}
EventStore.__index = EventStore

--: ({ time_fn: () -> number }) -> EventStoreImpl
function M.event_store(opts)
	assert(opts and opts.time_fn, "event_store requires opts.time_fn")
	return setmetatable({
		_streams = {},       -- stream_name -> {event, ...}
		_global_seq = 0,
		_on_append = {},
		_time_fn = opts.time_fn,
	}, EventStore) --[[:! EventStoreImpl]]
end

--: (self: EventStoreImpl, string, event_input) -> ()
function EventStore:append(stream, event)
	local s = self._streams[stream]
	if not s then
		s = {}
		self._streams[stream] = s
	end
	self._global_seq = self._global_seq + 1
	local seq = #s + 1
	local stored = {
		seq = seq,
		global_seq = self._global_seq,
		type = event.type,
		data = event.data,
		timestamp = self._time_fn(),
	}
	s[seq] = stored
	local hooks = self._on_append
	for i = 1, #hooks do
		hooks[i](stream, stored)
	end
end

--: (self: EventStoreImpl, string, (read_opts | nil)) -> Event[]
function EventStore:read(stream, opts)
	local s = self._streams[stream]
	if not s then return {} end
	opts = opts or {}
	local after = opts.after or 0
	local limit = opts.limit
	local result = {}
	for i = 1, #s do
		local ev = s[i]
		if ev.seq > after then
			result[#result + 1] = ev
			if limit ~= nil then
				local lim = limit --[[:! integer]]
				if #result >= lim then break end
			end
		end
	end
	return result
end

--: (self: EventStoreImpl, (read_opts | nil)) -> Event[]
function EventStore:read_all(opts)
	opts = opts or {}
	local after = opts.after or 0
	local limit = opts.limit
	-- Collect all events across streams
	local all = {}
	for _, s in pairs(self._streams) do
		for i = 1, #s do
			local ev = s[i]
			if ev.global_seq > after then
				all[#all + 1] = ev
			end
		end
	end
	-- Sort by global sequence
	table.sort(all, function(a, b) return a.global_seq < b.global_seq end)
	-- Apply limit
	if limit ~= nil then
		local lim = limit --[[:! integer]]
		if #all > lim then
			local trimmed = {}
			for i = 1, lim do
				trimmed[i] = all[i]
			end
			return trimmed
		end
	end
	return all
end

--: (self: EventStoreImpl, (string, Event) -> ()) -> ()
function EventStore:on_append(fn)
	self._on_append[#self._on_append + 1] = fn
end

--: (self: EventStoreImpl, string, (unknown, Event) -> unknown) -> unknown
function EventStore:aggregate(stream, reducer)
	local s = self._streams[stream]
	if not s then return nil end
	local state = nil
	for i = 1, #s do
		state = reducer(state, s[i])
	end
	return state
end

--: (self: EventStoreImpl) -> string[]
function EventStore:streams()
	local result = {}
	for name in pairs(self._streams) do
		result[#result + 1] = name
	end
	table.sort(result)
	return result
end

--: (self: EventStoreImpl, string) -> number
function EventStore:stream_length(stream)
	local s = self._streams[stream]
	if not s then return 0 end
	return #s
end

return M
