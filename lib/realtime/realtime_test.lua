if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local realtime = require("lib.realtime")

-- ── Hub (pub/sub) ───────────────────────────────────────────────────────

T.describe("Hub", function()
	T.it("subscribe and publish delivers message", function()
		local hub = realtime.hub()
		--: { topic: string, message: { text: string, ... }, sender: any } | nil
		local received
		hub:subscribe("chat:room1", function(topic, message, sender)
			received = { topic = topic, message = message --[[:! { text: string, ... }]], sender = sender }
		end)
		hub:publish("chat:room1", { text = "hello" }, "user1")
		T.ok(received, "callback was called")
		if received then
			T.eq(received.topic, "chat:room1")
			T.eq(received.message.text, "hello")
			T.eq(received.sender, "user1")
		end
	end)

	T.it("multiple subscribers all receive message", function()
		local hub = realtime.hub()
		local count = 0
		hub:subscribe("chat:room1", function(_, _, _) count = count + 1 end)
		hub:subscribe("chat:room1", function(_, _, _) count = count + 1 end)
		hub:publish("chat:room1", "msg", nil)
		T.eq(count, 2)
	end)

	T.it("unsubscribe stops delivery", function()
		local hub = realtime.hub()
		local count = 0
		local sub = hub:subscribe("chat:room1", function(_, _, _) count = count + 1 end)
		hub:publish("chat:room1", "msg1", nil)
		T.eq(count, 1)
		sub:unsubscribe()
		hub:publish("chat:room1", "msg2", nil)
		T.eq(count, 1, "should not receive after unsubscribe")
	end)

	T.it("wildcard pattern chat:* matches chat:room1", function()
		local hub = realtime.hub()
		local received_topic
		hub:subscribe("chat:*", function(topic, _, _) received_topic = topic end)
		hub:publish("chat:room1", "msg", nil)
		T.eq(received_topic, "chat:room1")
	end)

	T.it("wildcard doesn't match non-matching topic", function()
		local hub = realtime.hub()
		local called = false
		hub:subscribe("chat:*", function(_, _, _) called = true end)
		hub:publish("users:room1", "msg", nil)
		T.eq(called, false)
	end)

	T.it("subscribers count", function()
		local hub = realtime.hub()
		hub:subscribe("chat:room1", function(_, _, _) end)
		hub:subscribe("chat:room1", function(_, _, _) end)
		hub:subscribe("chat:room2", function(_, _, _) end)
		T.eq(hub:subscribers("chat:room1"), 2)
		T.eq(hub:subscribers("chat:room2"), 1)
		T.eq(hub:subscribers("chat:room3"), 0)
	end)

	T.it("topics lists topics with subscribers", function()
		local hub = realtime.hub()
		hub:subscribe("chat:room2", function(_, _, _) end)
		hub:subscribe("chat:room1", function(_, _, _) end)
		local topics = hub:topics()
		T.eq(#topics, 2)
		T.eq(topics[1], "chat:room1")
		T.eq(topics[2], "chat:room2")
	end)

	T.it("has_subscribers returns correct boolean", function()
		local hub = realtime.hub()
		T.eq(hub:has_subscribers("chat:room1"), false)
		local sub = hub:subscribe("chat:room1", function(_, _, _) end)
		T.eq(hub:has_subscribers("chat:room1"), true)
		sub:unsubscribe()
		T.eq(hub:has_subscribers("chat:room1"), false)
	end)

	T.it("publish with no subscribers is fine", function()
		local hub = realtime.hub()
		-- Should not error
		hub:publish("chat:room1", "msg", nil)
		T.ok(true, "no error")
	end)
end)

-- ── Presence ────────────────────────────────────────────────────────────

T.describe("Presence", function()
	T.it("join adds user to room", function()
		local presence = realtime.presence()
		presence:join("room1", "user1", { name = "Alice" })
		local meta = presence:get("room1", "user1")
		T.ok(meta, "user exists")
		if meta then
			T.eq(meta.name, "Alice")
		end
	end)

	T.it("list returns all users in room", function()
		local presence = realtime.presence()
		presence:join("room1", "user2", { name = "Bob" })
		presence:join("room1", "user1", { name = "Alice" })
		local list = presence:list("room1")
		T.eq(#list, 2)
		-- Sorted by id
		T.eq(list[1].id, "user1")
		T.eq(list[1].meta.name, "Alice")
		T.eq(list[2].id, "user2")
		T.eq(list[2].meta.name, "Bob")
	end)

	T.it("get returns metadata for specific user", function()
		local presence = realtime.presence()
		presence:join("room1", "user1", { name = "Alice", status = "online" })
		local meta = presence:get("room1", "user1")
		if meta then
			T.eq(meta.name, "Alice")
			T.eq(meta.status, "online")
		end
		T.eq(presence:get("room1", "nonexistent"), nil)
		T.eq(presence:get("nonexistent", "user1"), nil)
	end)

	T.it("leave removes user", function()
		local presence = realtime.presence()
		presence:join("room1", "user1", { name = "Alice" })
		presence:leave("room1", "user1")
		T.eq(presence:get("room1", "user1"), nil)
		T.eq(presence:count("room1"), 0)
	end)

	T.it("count returns correct count", function()
		local presence = realtime.presence()
		T.eq(presence:count("room1"), 0)
		presence:join("room1", "user1", {})
		T.eq(presence:count("room1"), 1)
		presence:join("room1", "user2", {})
		T.eq(presence:count("room1"), 2)
		presence:leave("room1", "user1")
		T.eq(presence:count("room1"), 1)
	end)

	T.it("update changes metadata", function()
		local presence = realtime.presence()
		presence:join("room1", "user1", { name = "Alice", status = "online" })
		presence:update("room1", "user1", { status = "away" })
		local meta = presence:get("room1", "user1")
		if meta then
			T.eq(meta.status, "away")
			T.eq(meta.name, "Alice", "other fields preserved")
		end
	end)

	T.it("on_join hook called", function()
		local presence = realtime.presence()
		--: { room: string, user_id: string, meta: presence_meta } | nil
		local hook_args
		presence:on_join(function(room, user_id, meta)
			hook_args = { room = room, user_id = user_id, meta = meta }
		end)
		presence:join("room1", "user1", { name = "Alice" })
		T.ok(hook_args, "hook was called")
		if hook_args then
			T.eq(hook_args.room, "room1")
			T.eq(hook_args.user_id, "user1")
			T.eq(hook_args.meta.name, "Alice")
		end
	end)

	T.it("on_leave hook called", function()
		local presence = realtime.presence()
		--: { room: string, user_id: string, meta: presence_meta } | nil
		local hook_args
		presence:on_leave(function(room, user_id, meta)
			hook_args = { room = room, user_id = user_id, meta = meta }
		end)
		presence:join("room1", "user1", { name = "Alice" })
		presence:leave("room1", "user1")
		T.ok(hook_args, "hook was called")
		if hook_args then
			T.eq(hook_args.room, "room1")
			T.eq(hook_args.user_id, "user1")
			T.eq(hook_args.meta.name, "Alice")
		end
	end)

	T.it("on_update hook called", function()
		local presence = realtime.presence()
		--: { room: string, user_id: string, meta: presence_meta } | nil
		local hook_args
		presence:on_update(function(room, user_id, meta)
			hook_args = { room = room, user_id = user_id, meta = meta }
		end)
		presence:join("room1", "user1", { name = "Alice", status = "online" })
		presence:update("room1", "user1", { status = "away" })
		T.ok(hook_args, "hook was called")
		if hook_args then
			T.eq(hook_args.room, "room1")
			T.eq(hook_args.user_id, "user1")
			T.eq(hook_args.meta.status, "away")
		end
	end)

	T.it("multiple rooms are independent", function()
		local presence = realtime.presence()
		presence:join("room1", "user1", { name = "Alice" })
		presence:join("room2", "user2", { name = "Bob" })
		T.eq(presence:count("room1"), 1)
		T.eq(presence:count("room2"), 1)
		T.eq(presence:get("room1", "user2"), nil)
		T.eq(presence:get("room2", "user1"), nil)
	end)
end)

-- ── Event Store ─────────────────────────────────────────────────────────

T.describe("Event Store", function()
	T.it("append and read", function()
		local store = realtime.event_store({ time_fn = os.time })
		store:append("order:123", { type = "created", data = { item = "widget" } })
		local events = store:read("order:123")
		T.eq(#events, 1)
		T.eq(events[1].type, "created")
		T.eq(events[1].data.item, "widget")
	end)

	T.it("events have incrementing sequence numbers", function()
		local store = realtime.event_store({ time_fn = os.time })
		store:append("order:123", { type = "created", data = {} })
		store:append("order:123", { type = "shipped", data = {} })
		local events = store:read("order:123")
		T.eq(events[1].seq, 1)
		T.eq(events[2].seq, 2)
		T.ok(events[1].global_seq < events[2].global_seq)
	end)

	T.it("read with after filter", function()
		local store = realtime.event_store({ time_fn = os.time })
		store:append("order:123", { type = "created", data = {} })
		store:append("order:123", { type = "shipped", data = {} })
		store:append("order:123", { type = "delivered", data = {} })
		local events = store:read("order:123", { after = 1 })
		T.eq(#events, 2)
		T.eq(events[1].seq, 2)
		T.eq(events[2].seq, 3)
	end)

	T.it("read with limit", function()
		local store = realtime.event_store({ time_fn = os.time })
		store:append("s", { type = "a", data = {} })
		store:append("s", { type = "b", data = {} })
		store:append("s", { type = "c", data = {} })
		local events = store:read("s", { limit = 2 })
		T.eq(#events, 2)
		T.eq(events[1].type, "a")
		T.eq(events[2].type, "b")
	end)

	T.it("read_all across streams", function()
		local store = realtime.event_store({ time_fn = os.time })
		store:append("order:1", { type = "created", data = {} })
		store:append("order:2", { type = "created", data = {} })
		store:append("order:1", { type = "shipped", data = {} })
		local events = store:read_all()
		T.eq(#events, 3)
		-- Ordered by global_seq
		T.eq(events[1].global_seq, 1)
		T.eq(events[2].global_seq, 2)
		T.eq(events[3].global_seq, 3)
	end)

	T.it("on_append hook", function()
		local store = realtime.event_store({ time_fn = os.time })
		--: { stream: string, event: Event } | nil
		local hook_args
		store:on_append(function(stream, event)
			hook_args = { stream = stream, event = event }
		end)
		store:append("order:123", { type = "created", data = { x = 1 } })
		T.ok(hook_args, "hook was called")
		if hook_args then
			T.eq(hook_args.stream, "order:123")
			T.eq(hook_args.event.type, "created")
			T.eq(hook_args.event.seq, 1)
		end
	end)

	T.it("aggregate folds events", function()
		local store = realtime.event_store({ time_fn = os.time })
		store:append("order:123", { type = "created", data = { item = "widget", qty = 5 } })
		store:append("order:123", { type = "shipped", data = { tracking = "ABC" } })
		local state = store:aggregate("order:123", function(state, event)
			state = state or { status = "unknown" }
			if event.type == "created" then
				state.status = "created"
				local d = event.data --[[:! { item: string, ... }]]
				state.item = d.item
			elseif event.type == "shipped" then
				state.status = "shipped"
				local d = event.data --[[:! { tracking: string, ... }]]
				state.tracking = d.tracking
			end
			return state
		end)
		if type(state) == "table" then
			T.eq(state.status, "shipped")
			T.eq(state.item, "widget")
			T.eq(state.tracking, "ABC")
		end
	end)

	T.it("streams lists stream names", function()
		local store = realtime.event_store({ time_fn = os.time })
		store:append("order:456", { type = "created", data = {} })
		store:append("order:123", { type = "created", data = {} })
		local names = store:streams()
		T.eq(#names, 2)
		T.eq(names[1], "order:123")
		T.eq(names[2], "order:456")
	end)

	T.it("stream_length", function()
		local store = realtime.event_store({ time_fn = os.time })
		T.eq(store:stream_length("order:123"), 0)
		store:append("order:123", { type = "created", data = {} })
		store:append("order:123", { type = "shipped", data = {} })
		T.eq(store:stream_length("order:123"), 2)
	end)

	T.it("empty stream returns empty array", function()
		local store = realtime.event_store({ time_fn = os.time })
		local events = store:read("nonexistent")
		T.eq(#events, 0)
	end)
end)

-- Print summary
local s = T._summary()
print(string.format("\n%d passed, %d failed", s.pass, s.fail))
if s.fail > 0 then
	for _, t in ipairs(s.tests) do
		if not t.ok then
			local err = t.err
			print("  FAIL: " .. t.name .. (err ~= nil and (" - " .. tostring(err)) or ""))
		end
	end
	os.exit(1)
end
