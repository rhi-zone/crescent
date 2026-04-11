if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local pool = require("lib.pool")

T.describe("pool.new", function()
	T.it("requires create function", function()
		local p, err = pool.new({})
		T.eq(p, nil)
		T.ok(err ~= nil, "error message returned")
	end)

	T.it("acquire calls create when pool is empty", function()
		local calls = 0
		local p = pool.new({ create = function()
			calls = calls + 1
			return { id = calls }
		end })
		local obj = p:acquire()
		T.eq(calls, 1)
		T.eq(obj.id, 1)
	end)

	T.it("release returns object to pool; acquire reuses it (LIFO)", function()
		local calls = 0
		local p = pool.new({ create = function()
			calls = calls + 1
			return { id = calls }
		end })
		local a = p:acquire()
		T.eq(calls, 1)
		p:release(a)
		T.eq(p:size(), 1)
		local b = p:acquire()
		T.eq(calls, 1, "no new object created")
		T.eq(b, a, "same object returned")
		T.eq(p:size(), 0)
	end)

	T.it("LIFO ordering: last released is first acquired", function()
		local p = pool.new({ create = function() return {} end })
		local a = p:acquire()
		local b = p:acquire()
		p:release(a)
		p:release(b)
		local first = p:acquire()
		T.eq(first, b, "LIFO: b was released last")
		local second = p:acquire()
		T.eq(second, a)
	end)

	T.it("reset is called on release", function()
		local reset_calls = 0
		local last_reset = nil
		local p = pool.new({
			create = function() return { value = 0 } end,
			reset = function(obj)
				reset_calls = reset_calls + 1
				last_reset = obj
				obj.value = 0
			end,
		})
		local obj = p:acquire()
		obj.value = 42
		p:release(obj)
		T.eq(reset_calls, 1)
		T.eq(last_reset, obj)
		local obj2 = p:acquire()
		T.eq(obj2.value, 0, "reset cleared value")
	end)

	T.it("max cap: releasing beyond max discards object", function()
		local p = pool.new({ create = function() return {} end, max = 2 })
		local a = p:acquire()
		local b = p:acquire()
		local c = p:acquire()
		p:release(a)
		p:release(b)
		T.eq(p:size(), 2)
		p:release(c)
		T.eq(p:size(), 2, "c was discarded (pool full)")
	end)

	T.it("capacity returns max", function()
		local p = pool.new({ create = function() return {} end, max = 5 })
		T.eq(p:capacity(), 5)
	end)

	T.it("capacity returns nil when unlimited", function()
		local p = pool.new({ create = function() return {} end })
		T.eq(p:capacity(), nil)
	end)

	T.it("size reflects idle count", function()
		local p = pool.new({ create = function() return {} end })
		T.eq(p:size(), 0)
		local a = p:acquire()
		local b = p:acquire()
		T.eq(p:size(), 0)
		p:release(a)
		T.eq(p:size(), 1)
		p:release(b)
		T.eq(p:size(), 2)
		p:acquire()
		T.eq(p:size(), 1)
	end)

	T.it("drain empties the pool", function()
		local p = pool.new({ create = function() return {} end })
		local a = p:acquire()
		local b = p:acquire()
		p:release(a)
		p:release(b)
		T.eq(p:size(), 2)
		p:drain()
		T.eq(p:size(), 0)
	end)

	T.it("prefill prepopulates the pool", function()
		local calls = 0
		local p = pool.new({ create = function()
			calls = calls + 1
			return { id = calls }
		end })
		p:prefill(3)
		T.eq(calls, 3)
		T.eq(p:size(), 3)
	end)

	T.it("prefill calls reset on each created object", function()
		local reset_calls = 0
		local p = pool.new({
			create = function() return { x = 1 } end,
			reset = function(obj)
				reset_calls = reset_calls + 1
				obj.x = 0
			end,
		})
		p:prefill(2)
		T.eq(reset_calls, 2)
		local obj = p:acquire()
		T.eq(obj.x, 0)
	end)

	T.it("on_acquire hook is called", function()
		local acquired = {}
		local p = pool.new({
			create = function() return {} end,
			on_acquire = function(obj) acquired[#acquired + 1] = obj end,
		})
		local a = p:acquire()
		T.eq(#acquired, 1)
		T.eq(acquired[1], a)
		p:release(a)
		local b = p:acquire()
		T.eq(#acquired, 2)
		T.eq(acquired[2], b)
	end)

	T.it("on_release hook is called", function()
		local released = {}
		local p = pool.new({
			create = function() return {} end,
			on_release = function(obj) released[#released + 1] = obj end,
		})
		local a = p:acquire()
		p:release(a)
		T.eq(#released, 1)
		T.eq(released[1], a)
	end)

	T.it("on_release called even when object is discarded (max exceeded)", function()
		local released = {}
		local p = pool.new({
			create = function() return {} end,
			max = 1,
			on_release = function(obj) released[#released + 1] = obj end,
		})
		local a = p:acquire()
		local b = p:acquire()
		p:release(a)
		p:release(b)
		T.eq(#released, 2, "on_release called for both")
		T.eq(p:size(), 1, "only one kept")
	end)
end)

T.describe("pool:use", function()
	T.it("calls fn with acquired object and returns result", function()
		local p = pool.new({ create = function() return { v = 7 } end })
		local result = p:use(function(obj)
			return obj.v * 2
		end)
		T.eq(result, 14)
	end)

	T.it("releases object after fn returns", function()
		local p = pool.new({ create = function() return {} end })
		T.eq(p:size(), 0)
		p:use(function(_) end)
		T.eq(p:size(), 1, "object returned to pool")
	end)

	T.it("releases object even when fn errors", function()
		local p = pool.new({ create = function() return {} end })
		local ok, err = pcall(function()
			p:use(function(_)
				error("oops")
			end)
		end)
		T.eq(ok, false)
		T.ok(err:find("oops"), "error propagated")
		T.eq(p:size(), 1, "object still returned to pool")
	end)

	T.it("object reused across multiple use calls", function()
		local calls = 0
		local p = pool.new({ create = function()
			calls = calls + 1
			return {}
		end })
		p:use(function(_) end)
		p:use(function(_) end)
		p:use(function(_) end)
		T.eq(calls, 1, "only one object created")
	end)
end)

T.describe("pool.table_pool", function()
	T.it("acquire returns table with template values", function()
		local tp = pool.table_pool({ x = 1, y = 2 })
		local t = tp:acquire()
		T.eq(t.x, 1)
		T.eq(t.y, 2)
	end)

	T.it("acquired tables are independent copies", function()
		local tp = pool.table_pool({ x = 0 })
		local a = tp:acquire()
		local b = tp:acquire()
		a.x = 99
		T.eq(b.x, 0, "b unaffected by a mutation")
	end)

	T.it("release resets table to template values", function()
		local tp = pool.table_pool({ x = 1, y = 2 })
		local t = tp:acquire()
		t.x = 99
		t.y = 100
		t.z = "extra"
		tp:release(t)
		local t2 = tp:acquire()
		T.eq(t2.x, 1)
		T.eq(t2.y, 2)
		T.eq(t2.z, nil, "extra key removed")
	end)

	T.it("release removes keys not in template", function()
		local tp = pool.table_pool({ a = "keep" })
		local t = tp:acquire()
		t.b = "transient"
		tp:release(t)
		local t2 = tp:acquire()
		T.eq(t2.a, "keep")
		T.eq(t2.b, nil)
	end)

	T.it("respects max cap", function()
		local tp = pool.table_pool({}, 1)
		T.eq(tp:capacity(), 1)
		local a = tp:acquire()
		local b = tp:acquire()
		tp:release(a)
		tp:release(b)
		T.eq(tp:size(), 1)
	end)

	T.it("multiple acquire/release cycles reuse objects", function()
		local creates = 0
		-- custom create tracking via new directly
		local tmpl = { val = 0 }
		local tp = pool.new({
			create = function()
				creates = creates + 1
				local t = {}
				for k, v in pairs(tmpl) do t[k] = v end
				return t
			end,
			reset = function(t)
				for k in pairs(t) do t[k] = nil end
				for k, v in pairs(tmpl) do t[k] = v end
			end,
		})
		for _ = 1, 10 do
			local obj = tp:acquire()
			obj.val = 42
			tp:release(obj)
		end
		T.eq(creates, 1, "only one object created across 10 cycles")
	end)

	T.it("empty template produces empty tables", function()
		local tp = pool.table_pool()
		local t = tp:acquire()
		local count = 0
		for _ in pairs(t) do count = count + 1 end
		T.eq(count, 0)
	end)
end)

T.describe("multiple cycles", function()
	T.it("many acquire/release cycles work correctly", function()
		local n = 0
		local p = pool.new({ create = function()
			n = n + 1
			return { id = n }
		end })
		-- Acquire 5 objects, release them all, then re-acquire
		local objs = {}
		for i = 1, 5 do objs[i] = p:acquire() end
		T.eq(n, 5)
		T.eq(p:size(), 0)
		for i = 1, 5 do p:release(objs[i]) end
		T.eq(p:size(), 5)
		-- Re-acquire all 5 — no new objects should be created
		for i = 1, 5 do objs[i] = p:acquire() end
		T.eq(n, 5, "no new objects created")
		T.eq(p:size(), 0)
	end)

	T.it("interleaved acquire/release maintains correct size", function()
		local p = pool.new({ create = function() return {} end })
		local a = p:acquire()
		local b = p:acquire()
		p:release(a)
		local c = p:acquire() -- should reuse a
		T.eq(c, a)
		T.eq(p:size(), 0)
		p:release(b)
		p:release(c)
		T.eq(p:size(), 2)
		p:drain()
		T.eq(p:size(), 0)
	end)
end)
