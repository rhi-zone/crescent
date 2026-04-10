-- lib/reactive/reactive_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local R = require("lib.reactive")
local Lens = require("lib.fp.optics.lens")
local Prism = require("lib.fp.optics.prism")
local Maybe = require("lib.fp.maybe")

T.describe("signal", function()
	T.it("get returns initial value", function()
		local s = R.signal(42)
		T.eq(s.get(), 42)
	end)

	T.it("set updates value", function()
		local s = R.signal(0)
		s.set(99)
		T.eq(s.get(), 99)
	end)

	T.it("update applies function", function()
		local s = R.signal(10)
		s.update(function(x) return x + 5 end)
		T.eq(s.get(), 15)
	end)

	T.it("subscribe notified on change", function()
		local s = R.signal("a")
		local log = {}
		s.subscribe(function(v) log[#log + 1] = v end)
		s.set("b")
		s.set("c")
		T.eq(#log, 2)
		T.eq(log[1], "b")
		T.eq(log[2], "c")
	end)

	T.it("subscribe not notified when value unchanged", function()
		local s = R.signal(1)
		local count = 0
		s.subscribe(function() count = count + 1 end)
		s.set(1)
		T.eq(count, 0)
	end)

	T.it("unsubscribe stops notifications", function()
		local s = R.signal(0)
		local log = {}
		local unsub = s.subscribe(function(v) log[#log + 1] = v end)
		s.set(1)
		unsub()
		s.set(2)
		T.eq(#log, 1)
		T.eq(log[1], 1)
	end)

	T.it("NaN treated as equal to itself (no spurious notification)", function()
		local nan = 0/0
		local s = R.signal(nan)
		local count = 0
		s.subscribe(function() count = count + 1 end)
		s.set(nan)
		T.eq(count, 0)
	end)

	T.it("multiple subscribers all notified", function()
		local s = R.signal(0)
		local a, b = 0, 0
		s.subscribe(function(v) a = v end)
		s.subscribe(function(v) b = v end)
		s.set(7)
		T.eq(a, 7)
		T.eq(b, 7)
	end)
end)

T.describe("computed", function()
	T.it("get returns fn result", function()
		local s = R.signal(3)
		local c = R.computed(function() return s.get() * 2 end, {s})
		T.eq(c.get(), 6)
	end)

	T.it("get recomputes when dependency changes", function()
		local s = R.signal(3)
		local c = R.computed(function() return s.get() * 2 end, {s})
		s.set(5)
		T.eq(c.get(), 10)
	end)

	T.it("subscriber notified when output changes", function()
		local s = R.signal(1)
		local c = R.computed(function() return s.get() > 0 end, {s})
		local log = {}
		c.subscribe(function(v) log[#log + 1] = v end)
		s.set(2)   -- output still true, no notification
		s.set(-1)  -- output changes to false
		T.eq(#log, 1)
		T.eq(log[1], false)
	end)

	T.it("subscriber not notified when computed output unchanged", function()
		local s = R.signal(1)
		local c = R.computed(function() return s.get() > 0 end, {s})
		local count = 0
		c.subscribe(function() count = count + 1 end)
		s.set(2)  -- output still true
		s.set(3)  -- still true
		T.eq(count, 0)
	end)

	T.it("unsubscribe stops computed notifications", function()
		local s = R.signal(0)
		local c = R.computed(function() return s.get() end, {s})
		local count = 0
		local unsub = c.subscribe(function() count = count + 1 end)
		s.set(1)
		unsub()
		s.set(2)
		T.eq(count, 1)
	end)

	T.it("computed from multiple deps", function()
		local a = R.signal(1)
		local b = R.signal(2)
		local c = R.computed(function() return a.get() + b.get() end, {a, b})
		T.eq(c.get(), 3)
		a.set(10)
		T.eq(c.get(), 12)
		b.set(20)
		T.eq(c.get(), 30)
	end)

	T.it("fn only called once per dep change — memoized reads", function()
		local s = R.signal(1)
		local calls = 0
		local c = R.computed(function() calls = calls + 1; return s.get() * 2 end, {s})
		T.eq(c.get(), 2);  T.eq(calls, 1)  -- first get computes
		T.eq(c.get(), 2);  T.eq(calls, 1)  -- second get uses cache
		T.eq(c.get(), 2);  T.eq(calls, 1)  -- still cached
		s.set(5)
		T.eq(c.get(), 10); T.eq(calls, 2)  -- dep changed → recomputes once
		T.eq(c.get(), 10); T.eq(calls, 2)  -- cached again
	end)
end)

T.describe("effect", function()
	T.it("runs immediately", function()
		local s = R.signal(0)
		local seen = {}
		R.effect(function() seen[#seen + 1] = s.get() end, {s})
		T.eq(#seen, 1)
		T.eq(seen[1], 0)
	end)

	T.it("runs again when dep changes", function()
		local s = R.signal(0)
		local seen = {}
		R.effect(function() seen[#seen + 1] = s.get() end, {s})
		s.set(1)
		s.set(2)
		T.eq(#seen, 3)
		T.eq(seen[1], 0)
		T.eq(seen[2], 1)
		T.eq(seen[3], 2)
	end)

	T.it("unsubscribe stops effect", function()
		local s = R.signal(0)
		local count = 0
		local stop = R.effect(function() count = count + 1 end, {s})
		s.set(1)
		stop()
		s.set(2)
		T.eq(count, 2)  -- initial + one change
	end)
end)

T.describe("batch", function()
	T.it("defers notifications until outermost batch exits", function()
		local a = R.signal(0)
		local b = R.signal(0)
		local log = {}
		a.subscribe(function(v) log[#log + 1] = {"a", v} end)
		b.subscribe(function(v) log[#log + 1] = {"b", v} end)
		R.batch(function()
			a.set(1)
			b.set(2)
			T.eq(#log, 0)  -- not yet fired inside batch
		end)
		T.eq(#log, 2)
	end)

	T.it("nested batches flush only at outermost exit", function()
		local s = R.signal(0)
		local log = {}
		s.subscribe(function(v) log[#log + 1] = v end)
		R.batch(function()
			R.batch(function()
				s.set(1)
				T.eq(#log, 0)
			end)
			T.eq(#log, 0)  -- still inside outer batch
		end)
		T.eq(#log, 1)
		T.eq(log[1], 1)
	end)

	T.it("deduplicates subscriber notified twice in batch", function()
		local a = R.signal(0)
		local b = R.signal(0)
		local count = 0
		-- same function object subscribes to both
		local function notify() count = count + 1 end
		a.subscribe(notify)
		b.subscribe(notify)
		R.batch(function()
			a.set(1)
			b.set(1)
		end)
		-- notify is the same table key in _pending → fires once
		T.eq(count, 1)
	end)

	T.it("batch with no changes fires no subscribers", function()
		local s = R.signal(0)
		local count = 0
		s.subscribe(function() count = count + 1 end)
		R.batch(function() end)
		T.eq(count, 0)
	end)

	T.it("handles cascading updates in batch flush", function()
		local s = R.signal(0)
		local doubled = 0
		s.subscribe(function(v) doubled = v * 2 end)
		R.batch(function()
			s.set(5)
		end)
		T.eq(doubled, 10)
	end)
end)

T.describe("focused (lens)", function()
	T.it("get extracts field via lens", function()
		local s = R.signal({x = 10, y = 20})
		local sx = s.focus(Lens.field("x"))
		T.eq(sx.get(), 10)
	end)

	T.it("set updates source through lens", function()
		local s = R.signal({x = 10, y = 20})
		local sx = s.focus(Lens.field("x"))
		sx.set(99)
		T.eq(s.get().x, 99)
		T.eq(s.get().y, 20)  -- other fields unchanged
	end)

	T.it("update modifies focused value", function()
		local s = R.signal({count = 5})
		local sc = s.focus(Lens.field("count"))
		sc.update(function(n) return n + 1 end)
		T.eq(s.get().count, 6)
	end)

	T.it("subscribe notified only when focused field changes", function()
		local s = R.signal({x = 1, y = 1})
		local sx = s.focus(Lens.field("x"))
		local log = {}
		sx.subscribe(function(v) log[#log + 1] = v end)
		-- set same x value, different y — x unchanged, no notification
		s.set({x = 1, y = 99})
		T.eq(#log, 0)
		-- update x — notification
		s.set({x = 42, y = 99})
		T.eq(#log, 1)
		T.eq(log[1], 42)
	end)

	T.it("composed lens via chained focus", function()
		local s = R.signal({inner = {val = 7}})
		local sv = s.focus(Lens.field("inner")).focus(Lens.field("val"))
		T.eq(sv.get(), 7)
		sv.set(100)
		T.eq(s.get().inner.val, 100)
	end)
end)

T.describe("narrowed (prism)", function()
	-- Prism for a tagged union: { tag="num", value=n } | { tag="str", value=s }
	local num_prism = Prism.new(
		function(s)
			if type(s) == "table" and s.tag == "num" then
				return Maybe.just(s.value)
			end
			return Maybe.nothing
		end,
		function(n)
			return {tag = "num", value = n}
		end
	)

	T.it("get extracts value when prism matches", function()
		local s = R.signal({tag = "num", value = 42})
		local sn = s.narrow(num_prism)
		T.eq(sn.get(), 42)
	end)

	T.it("get returns nil when prism does not match", function()
		local s = R.signal({tag = "str", value = "hello"})
		local sn = s.narrow(num_prism)
		T.eq(sn.get(), nil)
	end)

	T.it("set reconstructs source via prism.review", function()
		local s = R.signal({tag = "num", value = 1})
		local sn = s.narrow(num_prism)
		sn.set(99)
		T.eq(s.get().tag, "num")
		T.eq(s.get().value, 99)
	end)

	T.it("set(nil) is a no-op", function()
		local s = R.signal({tag = "num", value = 5})
		local sn = s.narrow(num_prism)
		sn.set(nil)
		T.eq(s.get().value, 5)
	end)

	T.it("update no-ops when prism misses", function()
		local s = R.signal({tag = "str", value = "x"})
		local sn = s.narrow(num_prism)
		sn.update(function(n) return n + 1 end)
		T.eq(s.get().tag, "str")  -- unchanged
	end)

	T.it("subscribe notified when narrowed value changes", function()
		local s = R.signal({tag = "num", value = 1})
		local sn = s.narrow(num_prism)
		local log = {}
		sn.subscribe(function(v) log[#log + 1] = v end)
		s.set({tag = "num", value = 2})
		T.eq(#log, 1)
		T.eq(log[1], 2)
	end)

	T.it("subscribe notified with nil when variant changes", function()
		local s = R.signal({tag = "num", value = 1})
		local sn = s.narrow(num_prism)
		local log = {}
		sn.subscribe(function(v) log[#log + 1] = tostring(v) end)
		s.set({tag = "str", value = "x"})
		T.eq(#log, 1)
		T.eq(log[1], "nil")
	end)
end)
