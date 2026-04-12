if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local EE = require("lib.event_emitter")

T.describe("event_emitter", function()
	T.describe("EE.new", function()
		T.it("returns a new emitter", function()
			local e = EE.new()
			T.ok(e ~= nil, "emitter is not nil")
			T.eq(type(e), "table", "emitter is a table")
		end)

		T.it("has _tier pure", function()
			T.eq(EE._tier, "pure")
		end)
	end)

	T.describe("on / emit", function()
		T.it("calls listener on emit", function()
			local e = EE.new()
			local called = 0
			e:on("data", function() called = called + 1 end)
			e:emit("data")
			T.eq(called, 1, "listener called once")
		end)

		T.it("passes arguments to listener", function()
			local e = EE.new()
			local got_a, got_b
			e:on("data", function(a, b) got_a = a; got_b = b end)
			e:emit("data", "hello", 42)
			T.eq(got_a, "hello")
			T.eq(got_b, 42)
		end)

		T.it("calls multiple listeners in order", function()
			local e = EE.new()
			local order = {}
			e:on("x", function() order[#order + 1] = 1 end)
			e:on("x", function() order[#order + 1] = 2 end)
			e:on("x", function() order[#order + 1] = 3 end)
			e:emit("x")
			T.eq(order[1], 1)
			T.eq(order[2], 2)
			T.eq(order[3], 3)
		end)

		T.it("returns true when listeners fired", function()
			local e = EE.new()
			e:on("x", function() end)
			local result = e:emit("x")
			T.eq(result, true)
		end)

		T.it("returns false when no listeners", function()
			local e = EE.new()
			local result = e:emit("nothing")
			T.eq(result, false)
		end)

		T.it("on returns self for chaining", function()
			local e = EE.new()
			local ret = e:on("x", function() end)
			T.eq(ret, e, "on returns self")
		end)

		T.it("does not cross-contaminate events", function()
			local e = EE.new()
			local a_count = 0
			local b_count = 0
			e:on("a", function() a_count = a_count + 1 end)
			e:on("b", function() b_count = b_count + 1 end)
			e:emit("a")
			T.eq(a_count, 1)
			T.eq(b_count, 0)
		end)
	end)

	T.describe("off", function()
		T.it("removes the specific listener", function()
			local e = EE.new()
			local count = 0
			local function h() count = count + 1 end
			e:on("data", h)
			e:emit("data")
			T.eq(count, 1)
			e:off("data", h)
			e:emit("data")
			T.eq(count, 1, "listener not called after off")
		end)

		T.it("does not remove other listeners for same event", function()
			local e = EE.new()
			local a = 0; local b = 0
			local function ha() a = a + 1 end
			local function hb() b = b + 1 end
			e:on("x", ha)
			e:on("x", hb)
			e:off("x", ha)
			e:emit("x")
			T.eq(a, 0)
			T.eq(b, 1)
		end)

		T.it("is a no-op for unknown event", function()
			local e = EE.new()
			-- should not error
			e:off("nope", function() end)
			T.ok(true)
		end)

		T.it("off returns self", function()
			local e = EE.new()
			local function h() end
			e:on("x", h)
			local ret = e:off("x", h)
			T.eq(ret, e)
		end)
	end)

	T.describe("once", function()
		T.it("auto-removes after first fire", function()
			local e = EE.new()
			local count = 0
			e:once("end", function() count = count + 1 end)
			e:emit("end")
			e:emit("end")
			T.eq(count, 1, "once listener fires only once")
		end)

		T.it("once returns self", function()
			local e = EE.new()
			local ret = e:once("x", function() end)
			T.eq(ret, e)
		end)

		T.it("once removed before handler runs (re-entrant emit)", function()
			local e = EE.new()
			local inner_count = 0
			e:once("tick", function()
				-- re-emit the same event; the once listener should already be gone
				e:emit("tick")
				inner_count = inner_count + 1
			end)
			e:emit("tick")
			T.eq(inner_count, 1, "inner emit did not re-fire once listener")
		end)

		T.it("once passes arguments", function()
			local e = EE.new()
			local got
			e:once("val", function(v) got = v end)
			e:emit("val", 99)
			T.eq(got, 99)
		end)
	end)

	T.describe("wildcard *", function()
		T.it("wildcard listener receives event name and args", function()
			local e = EE.new()
			local received_event, received_arg
			e:on("*", function(ev, arg) received_event = ev; received_arg = arg end)
			e:emit("custom", "payload")
			T.eq(received_event, "custom")
			T.eq(received_arg, "payload")
		end)

		T.it("wildcard fires for every event", function()
			local e = EE.new()
			local events = {}
			e:on("*", function(ev) events[#events + 1] = ev end)
			e:emit("a")
			e:emit("b")
			e:emit("c")
			T.eq(#events, 3)
			T.eq(events[1], "a")
			T.eq(events[2], "b")
			T.eq(events[3], "c")
		end)

		T.it("wildcard and specific both fire", function()
			local e = EE.new()
			local specific = 0
			local wild = 0
			e:on("data", function() specific = specific + 1 end)
			e:on("*", function() wild = wild + 1 end)
			e:emit("data")
			T.eq(specific, 1)
			T.eq(wild, 1)
		end)

		T.it("emitting * directly does not double-fire wildcard", function()
			local e = EE.new()
			local count = 0
			e:on("*", function() count = count + 1 end)
			e:emit("*")
			-- when event == "*", wildcard path is skipped, so it fires once via the direct list
			T.eq(count, 1)
		end)

		T.it("wildcard emit returns true when wildcard listener present", function()
			local e = EE.new()
			e:on("*", function() end)
			local result = e:emit("anything")
			T.eq(result, true)
		end)
	end)

	T.describe("error event", function()
		T.it("raises when no error listeners", function()
			local e = EE.new()
			T.throws(function()
				e:emit("error", "something bad")
			end, "emit error with no listener raises")
		end)

		T.it("error message is propagated in raise", function()
			local e = EE.new()
			local ok, err = pcall(function() e:emit("error", "my error") end)
			T.eq(ok, false)
			T.ok(err:find("my error"), "error message present in raised error")
		end)

		T.it("error listener catches the error", function()
			local e = EE.new()
			local caught
			e:on("error", function(err) caught = err end)
			e:emit("error", "caught error")
			T.eq(caught, "caught error")
		end)

		T.it("wildcard alone prevents raise", function()
			local e = EE.new()
			local caught_event
			e:on("*", function(ev) caught_event = ev end)
			-- should not raise because wildcard covers it
			e:emit("error", "oops")
			T.eq(caught_event, "error")
		end)
	end)

	T.describe("listener_count", function()
		T.it("returns 0 for unknown event", function()
			local e = EE.new()
			T.eq(e:listener_count("nope"), 0)
		end)

		T.it("counts registered listeners", function()
			local e = EE.new()
			e:on("x", function() end)
			e:on("x", function() end)
			T.eq(e:listener_count("x"), 2)
		end)

		T.it("decrements after off", function()
			local e = EE.new()
			local function h() end
			e:on("x", h)
			e:on("x", function() end)
			T.eq(e:listener_count("x"), 2)
			e:off("x", h)
			T.eq(e:listener_count("x"), 1)
		end)

		T.it("decrements after once fires", function()
			local e = EE.new()
			e:once("x", function() end)
			T.eq(e:listener_count("x"), 1)
			e:emit("x")
			T.eq(e:listener_count("x"), 0)
		end)
	end)

	T.describe("listeners", function()
		T.it("returns empty table for unknown event", function()
			local e = EE.new()
			local ls = e:listeners("nope")
			T.eq(type(ls), "table")
			T.eq(#ls, 0)
		end)

		T.it("returns copy of listener functions", function()
			local e = EE.new()
			local function h1() end
			local function h2() end
			e:on("x", h1)
			e:on("x", h2)
			local ls = e:listeners("x")
			T.eq(#ls, 2)
			T.eq(ls[1], h1)
			T.eq(ls[2], h2)
		end)

		T.it("returned list is a copy (mutation does not affect emitter)", function()
			local e = EE.new()
			e:on("x", function() end)
			local ls = e:listeners("x")
			ls[1] = nil
			T.eq(e:listener_count("x"), 1, "emitter unchanged after mutating copy")
		end)
	end)

	T.describe("remove_all_listeners", function()
		T.it("removes all listeners for a specific event", function()
			local e = EE.new()
			e:on("a", function() end)
			e:on("a", function() end)
			e:on("b", function() end)
			e:remove_all_listeners("a")
			T.eq(e:listener_count("a"), 0)
			T.eq(e:listener_count("b"), 1)
		end)

		T.it("removes all listeners for all events when no arg", function()
			local e = EE.new()
			e:on("a", function() end)
			e:on("b", function() end)
			e:remove_all_listeners()
			T.eq(e:listener_count("a"), 0)
			T.eq(e:listener_count("b"), 0)
		end)

		T.it("returns self", function()
			local e = EE.new()
			local ret = e:remove_all_listeners("x")
			T.eq(ret, e)
		end)

		T.it("is idempotent for unknown event", function()
			local e = EE.new()
			e:remove_all_listeners("nope")
			T.ok(true)
		end)
	end)

	T.describe("set_max_listeners", function()
		T.it("returns self", function()
			local e = EE.new()
			local ret = e:set_max_listeners(20)
			T.eq(ret, e)
		end)

		T.it("sets the internal max", function()
			local e = EE.new()
			e:set_max_listeners(5)
			T.eq(e._max_listeners, 5)
		end)
	end)

	T.describe("prepend_listener", function()
		T.it("adds listener at front", function()
			local e = EE.new()
			local order = {}
			e:on("x", function() order[#order + 1] = "second" end)
			e:prepend_listener("x", function() order[#order + 1] = "first" end)
			e:emit("x")
			T.eq(order[1], "first")
			T.eq(order[2], "second")
		end)

		T.it("returns self", function()
			local e = EE.new()
			local ret = e:prepend_listener("x", function() end)
			T.eq(ret, e)
		end)

		T.it("persistent (fires multiple times)", function()
			local e = EE.new()
			local count = 0
			e:prepend_listener("x", function() count = count + 1 end)
			e:emit("x")
			e:emit("x")
			T.eq(count, 2)
		end)
	end)

	T.describe("prepend_once", function()
		T.it("adds once listener at front", function()
			local e = EE.new()
			local order = {}
			e:on("x", function() order[#order + 1] = "on" end)
			e:prepend_once("x", function() order[#order + 1] = "once" end)
			e:emit("x")
			T.eq(order[1], "once")
			T.eq(order[2], "on")
		end)

		T.it("fires only once", function()
			local e = EE.new()
			local count = 0
			e:prepend_once("x", function() count = count + 1 end)
			e:emit("x")
			e:emit("x")
			T.eq(count, 1)
		end)

		T.it("returns self", function()
			local e = EE.new()
			local ret = e:prepend_once("x", function() end)
			T.eq(ret, e)
		end)
	end)

	T.describe("mixin", function()
		T.it("adds emitter methods to a plain table", function()
			local obj = { name = "myobj" }
			EE.mixin(obj)
			T.ok(type(obj.on) == "function", "has on")
			T.ok(type(obj.emit) == "function", "has emit")
			T.ok(type(obj.off) == "function", "has off")
			T.ok(type(obj.once) == "function", "has once")
			T.ok(type(obj.listener_count) == "function", "has listener_count")
		end)

		T.it("mixed-in emitter is functional", function()
			local obj = {}
			EE.mixin(obj)
			local fired = false
			obj:on("go", function() fired = true end)
			obj:emit("go")
			T.ok(fired)
		end)

		T.it("preserves existing fields", function()
			local obj = { name = "test", value = 42 }
			EE.mixin(obj)
			T.eq(obj.name, "test")
			T.eq(obj.value, 42)
		end)

		T.it("once works on mixin", function()
			local obj = {}
			EE.mixin(obj)
			local count = 0
			obj:once("x", function() count = count + 1 end)
			obj:emit("x")
			obj:emit("x")
			T.eq(count, 1)
		end)
	end)

	T.describe("chaining", function()
		T.it("chained on calls work", function()
			local e = EE.new()
			local a = 0; local b = 0; local c = 0
			e:on("x", function() a = a + 1 end)
				:on("x", function() b = b + 1 end)
				:on("x", function() c = c + 1 end)
			e:emit("x")
			T.eq(a, 1)
			T.eq(b, 1)
			T.eq(c, 1)
		end)

		T.it("mixed chain on/once/off", function()
			local e = EE.new()
			local function h() end
			local ret = e:on("x", h):once("y", h):off("x", h):remove_all_listeners("y")
			T.eq(ret, e)
			T.eq(e:listener_count("x"), 0)
			T.eq(e:listener_count("y"), 0)
		end)
	end)

	T.describe("edge cases", function()
		T.it("emit with no args works", function()
			local e = EE.new()
			local called = false
			e:on("ping", function() called = true end)
			e:emit("ping")
			T.ok(called)
		end)

		T.it("multiple once listeners each fire once", function()
			local e = EE.new()
			local a = 0; local b = 0
			e:once("x", function() a = a + 1 end)
			e:once("x", function() b = b + 1 end)
			e:emit("x")
			e:emit("x")
			T.eq(a, 1)
			T.eq(b, 1)
		end)

		T.it("listener added during emit fires on next emit, not current", function()
			local e = EE.new()
			local inner = 0
			e:on("x", function()
				e:on("x", function() inner = inner + 1 end)
			end)
			e:emit("x") -- registers the inner listener
			T.eq(inner, 0, "inner not fired on same emit")
			e:emit("x") -- now fires both original and inner
			T.eq(inner, 1)
		end)

		T.it("off inside handler does not affect current emit snapshot", function()
			local e = EE.new()
			local second = 0
			local function second_h() second = second + 1 end
			e:on("x", function() e:off("x", second_h) end)
			e:on("x", second_h)
			e:emit("x")
			-- second_h is in the snapshot, so still fires this emit
			T.eq(second, 1)
			e:emit("x")
			-- now off took effect
			T.eq(second, 1)
		end)
	end)
end)
