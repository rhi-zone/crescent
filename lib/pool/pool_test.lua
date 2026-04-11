-- lib/pool/pool_test.lua — tests for lib/pool/init.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local pool = require("lib.pool")

-- ── constructor ──────────────────────────────────────────────────────────────

T.describe("pool.new", function()
	T.it("returns pool with valid opts", function()
		local p = pool.new({ size = 4, create = function() return {} end })
		T.ok(p)
	end)

	T.it("returns nil when create missing", function()
		local p, err = pool.new({ size = 4 })
		T.eq(p, nil)
		T.eq(err, "opts.create is required")
	end)

	T.it("returns nil when opts is nil", function()
		local p, err = pool.new(nil)
		T.eq(p, nil)
		T.eq(err, "opts.create is required")
	end)

	T.it("returns nil when size missing", function()
		local p, err = pool.new({ create = function() return {} end })
		T.eq(p, nil)
		T.eq(err, "opts.size must be >= 1")
	end)

	T.it("returns nil when size is 0", function()
		local p, err = pool.new({ size = 0, create = function() return {} end })
		T.eq(p, nil)
		T.eq(err, "opts.size must be >= 1")
	end)
end)

-- ── acquire/release basics ───────────────────────────────────────────────────

T.describe("acquire/release", function()
	T.it("creates object on first acquire", function()
		local created = 0
		local p = pool.new({
			size = 4,
			create = function() created = created + 1; return { id = created } end,
		})
		local obj = p:acquire()
		T.ok(obj)
		T.eq(obj.id, 1)
		T.eq(created, 1)
	end)

	T.it("tracks size after acquire", function()
		local p = pool.new({ size = 4, create = function() return {} end })
		p:acquire()
		T.eq(p:size(), 1)
		T.eq(p:in_use(), 1)
		T.eq(p:idle(), 0)
	end)

	T.it("tracks size after release", function()
		local p = pool.new({ size = 4, create = function() return {} end })
		local obj = p:acquire()
		p:release(obj)
		T.eq(p:size(), 1)
		T.eq(p:in_use(), 0)
		T.eq(p:idle(), 1)
	end)

	T.it("release returns true on success", function()
		local p = pool.new({ size = 4, create = function() return {} end })
		local obj = p:acquire()
		local ok = p:release(obj)
		T.eq(ok, true)
	end)

	T.it("reuses released object (same reference)", function()
		local p = pool.new({ size = 4, create = function() return {} end })
		local obj1 = p:acquire()
		p:release(obj1)
		local obj2 = p:acquire()
		T.eq(obj1, obj2) -- same table reference
	end)

	T.it("creates new object when no idle", function()
		local n = 0
		local p = pool.new({
			size = 4,
			create = function() n = n + 1; return { id = n } end,
		})
		local a = p:acquire()
		local b = p:acquire()
		T.neq(a, b)
		T.eq(a.id, 1)
		T.eq(b.id, 2)
	end)

	T.it("LIFO reuse order", function()
		local n = 0
		local p = pool.new({
			size = 4,
			create = function() n = n + 1; return { id = n } end,
		})
		local a = p:acquire()
		local b = p:acquire()
		p:release(a)
		p:release(b)
		-- LIFO: b was released last, so it's acquired first
		local c = p:acquire()
		T.eq(c, b)
		local d = p:acquire()
		T.eq(d, a)
	end)
end)

-- ── max size limit ───────────────────────────────────────────────────────────

T.describe("max size", function()
	T.it("returns error when pool exhausted", function()
		local p = pool.new({
			size = 2,
			create = function() return {} end,
		})
		p:acquire()
		p:acquire()
		local obj, err = p:acquire()
		T.eq(obj, nil)
		T.eq(err, "pool exhausted")
	end)

	T.it("can acquire again after release", function()
		local p = pool.new({
			size = 1,
			create = function() return {} end,
		})
		local a = p:acquire()
		p:release(a)
		local b = p:acquire()
		T.ok(b)
		T.eq(a, b)
	end)

	T.it("size never exceeds max", function()
		local p = pool.new({
			size = 3,
			create = function() return {} end,
		})
		local objs = {}
		for i = 1, 3 do objs[i] = p:acquire() end
		T.eq(p:size(), 3)
		-- release all
		for i = 1, 3 do p:release(objs[i]) end
		T.eq(p:size(), 3)
		T.eq(p:idle(), 3)
		-- acquire one more — reuses, does not create
		local obj = p:acquire()
		T.ok(obj)
		T.eq(p:size(), 3)
	end)
end)

-- ── validate ─────────────────────────────────────────────────────────────────

T.describe("validate", function()
	T.it("rejects invalid objects on acquire", function()
		local n = 0
		local p = pool.new({
			size = 4,
			create = function() n = n + 1; return { id = n, healthy = true } end,
			validate = function(obj) return obj.healthy end,
		})
		local a = p:acquire()
		a.healthy = false
		p:release(a)
		-- acquire should reject a and create a new one
		local b = p:acquire()
		T.ok(b)
		T.neq(a, b)
		T.eq(b.healthy, true)
	end)

	T.it("destroyed invalid objects call destroy", function()
		local destroyed = {}
		local n = 0
		local p = pool.new({
			size = 4,
			create = function() n = n + 1; return { id = n, healthy = true } end,
			validate = function(obj) return obj.healthy end,
			destroy = function(obj) destroyed[#destroyed + 1] = obj.id end,
		})
		local a = p:acquire()
		a.healthy = false
		p:release(a)
		p:acquire() -- triggers validation + destroy of a
		T.eq(#destroyed, 1)
		T.eq(destroyed[1], 1)
	end)

	T.it("skips multiple invalid and finds valid", function()
		local n = 0
		local p = pool.new({
			size = 10,
			create = function() n = n + 1; return { id = n, healthy = true } end,
			validate = function(obj) return obj.healthy end,
		})
		local a = p:acquire()
		local b = p:acquire()
		local c = p:acquire()
		a.healthy = false
		b.healthy = false
		-- release all (c still healthy)
		p:release(a)
		p:release(b)
		p:release(c)
		-- LIFO: tries c first (healthy), returns it
		local got = p:acquire()
		T.eq(got, c)
	end)

	T.it("all idle invalid and under max creates new", function()
		local n = 0
		local p = pool.new({
			size = 5,
			create = function() n = n + 1; return { id = n, healthy = true } end,
			validate = function(obj) return obj.healthy end,
		})
		local a = p:acquire()
		a.healthy = false
		p:release(a)
		local b = p:acquire()
		T.neq(a, b)
		T.eq(b.id, 2)
	end)

	T.it("all idle invalid and at max returns error", function()
		local p = pool.new({
			size = 1,
			create = function() return { healthy = true } end,
			validate = function(obj) return obj.healthy end,
		})
		local a = p:acquire()
		a.healthy = false
		p:release(a)
		-- idle count is 1 but validation will reject it; after rejection size drops
		-- so it should be able to create a new one (under max again)
		local b, err = p:acquire()
		T.ok(b, err)
	end)
end)

-- ── reset ────────────────────────────────────────────────────────────────────

T.describe("reset", function()
	T.it("calls reset on release", function()
		local reset_count = 0
		local p = pool.new({
			size = 4,
			create = function() return { data = nil } end,
			reset = function(obj) obj.data = nil; reset_count = reset_count + 1 end,
		})
		local a = p:acquire()
		a.data = "dirty"
		p:release(a)
		T.eq(reset_count, 1)
		local b = p:acquire()
		T.eq(b.data, nil) -- reset cleared it
	end)

	T.it("reset called for each release", function()
		local count = 0
		local p = pool.new({
			size = 4,
			create = function() return {} end,
			reset = function() count = count + 1 end,
		})
		local a = p:acquire()
		local b = p:acquire()
		p:release(a)
		p:release(b)
		T.eq(count, 2)
	end)
end)

-- ── with() ───────────────────────────────────────────────────────────────────

T.describe("with", function()
	T.it("passes object to function and returns result", function()
		local p = pool.new({
			size = 4,
			create = function() return { value = 42 } end,
		})
		local result = p:with(function(obj)
			return obj.value
		end)
		T.eq(result, 42)
	end)

	T.it("releases object after success", function()
		local p = pool.new({
			size = 4,
			create = function() return {} end,
		})
		p:with(function() end)
		T.eq(p:in_use(), 0)
		T.eq(p:idle(), 1)
	end)

	T.it("releases object after error", function()
		local p = pool.new({
			size = 4,
			create = function() return {} end,
		})
		local ok = pcall(function()
			p:with(function() error("boom") end)
		end)
		T.eq(ok, false)
		T.eq(p:in_use(), 0)
		T.eq(p:idle(), 1)
	end)

	T.it("propagates error from function", function()
		local p = pool.new({
			size = 4,
			create = function() return {} end,
		})
		local ok, err = pcall(function()
			p:with(function() error("test error") end)
		end)
		T.eq(ok, false)
		T.ok(err:find("test error"))
	end)

	T.it("returns nil and error when pool exhausted", function()
		local p = pool.new({
			size = 1,
			create = function() return {} end,
		})
		p:acquire() -- exhaust
		local result, err = p:with(function() return "nope" end)
		T.eq(result, nil)
		T.eq(err, "pool exhausted")
	end)
end)

-- ── drain ────────────────────────────────────────────────────────────────────

T.describe("drain", function()
	T.it("destroys all idle objects", function()
		local destroyed = 0
		local p = pool.new({
			size = 4,
			create = function() return {} end,
			destroy = function() destroyed = destroyed + 1 end,
		})
		local a = p:acquire()
		local b = p:acquire()
		p:release(a)
		p:release(b)
		T.eq(p:idle(), 2)
		p:drain()
		T.eq(p:idle(), 0)
		T.eq(destroyed, 2)
	end)

	T.it("does not affect in-use objects", function()
		local p = pool.new({
			size = 4,
			create = function() return {} end,
		})
		local a = p:acquire()
		p:drain()
		T.eq(p:in_use(), 1)
		T.eq(p:size(), 1)
		-- can still release
		p:release(a)
		T.eq(p:idle(), 1)
	end)

	T.it("drain on empty pool is a no-op", function()
		local p = pool.new({
			size = 4,
			create = function() return {} end,
		})
		p:drain()
		T.eq(p:idle(), 0)
		T.eq(p:size(), 0)
	end)

	T.it("can acquire after drain", function()
		local n = 0
		local p = pool.new({
			size = 4,
			create = function() n = n + 1; return { id = n } end,
		})
		local a = p:acquire()
		p:release(a)
		p:drain()
		local b = p:acquire()
		T.ok(b)
		T.neq(a, b) -- new object, not the drained one
		T.eq(b.id, 2)
	end)
end)

-- ── stats ────────────────────────────────────────────────────────────────────

T.describe("stats", function()
	T.it("tracks created count", function()
		local p = pool.new({
			size = 4,
			create = function() return {} end,
		})
		p:acquire()
		p:acquire()
		local s = p:stats()
		T.eq(s.created, 2)
		T.eq(s.reused, 0)
	end)

	T.it("tracks reused count", function()
		local p = pool.new({
			size = 4,
			create = function() return {} end,
		})
		local a = p:acquire()
		p:release(a)
		p:acquire() -- reuse
		local s = p:stats()
		T.eq(s.created, 1)
		T.eq(s.reused, 1)
	end)

	T.it("returns all fields", function()
		local p = pool.new({
			size = 10,
			create = function() return {} end,
		})
		local a = p:acquire()
		local b = p:acquire()
		p:release(a)
		local s = p:stats()
		T.eq(s.size, 2)
		T.eq(s.idle, 1)
		T.eq(s.in_use, 1)
		T.eq(s.created, 2)
		T.eq(s.reused, 0)
	end)

	T.it("accumulates across multiple cycles", function()
		local p = pool.new({
			size = 4,
			create = function() return {} end,
		})
		local a = p:acquire() -- created=1
		p:release(a)
		local b = p:acquire() -- reuse 1
		p:release(b)
		local c = p:acquire() -- reuse 2
		p:release(c)
		local s = p:stats()
		T.eq(s.created, 1)
		T.eq(s.reused, 2)
	end)
end)

-- ── edge cases ───────────────────────────────────────────────────────────────

T.describe("edge cases", function()
	T.it("release unknown object returns error", function()
		local p = pool.new({
			size = 4,
			create = function() return {} end,
		})
		local ok, err = p:release({})
		T.eq(ok, nil)
		T.eq(err, "object not from this pool")
	end)

	T.it("double release returns error on second", function()
		local p = pool.new({
			size = 4,
			create = function() return {} end,
		})
		local obj = p:acquire()
		local ok1 = p:release(obj)
		T.eq(ok1, true)
		local ok2, err = p:release(obj)
		T.eq(ok2, nil)
		T.eq(err, "object not from this pool")
	end)

	T.it("pool of size 1 works correctly", function()
		local n = 0
		local p = pool.new({
			size = 1,
			create = function() n = n + 1; return { id = n } end,
		})
		local a = p:acquire()
		T.eq(a.id, 1)
		local b, err = p:acquire()
		T.eq(b, nil)
		T.eq(err, "pool exhausted")
		p:release(a)
		local c = p:acquire()
		T.eq(c, a)
	end)

	T.it("many acquire/release cycles", function()
		local p = pool.new({
			size = 2,
			create = function() return {} end,
		})
		for _ = 1, 100 do
			local a = p:acquire()
			local b = p:acquire()
			p:release(a)
			p:release(b)
		end
		T.eq(p:size(), 2)
		T.eq(p:idle(), 2)
		T.eq(p:in_use(), 0)
		local s = p:stats()
		T.eq(s.created, 2)
		T.eq(s.reused, 198) -- first cycle creates, rest reuse
	end)

	T.it("destroy called on drain but not on release", function()
		local destroyed = 0
		local p = pool.new({
			size = 4,
			create = function() return {} end,
			destroy = function() destroyed = destroyed + 1 end,
		})
		local a = p:acquire()
		p:release(a)
		T.eq(destroyed, 0) -- release does not destroy
		p:drain()
		T.eq(destroyed, 1) -- drain destroys
	end)

	T.it("with() works with pool of size 1", function()
		local p = pool.new({
			size = 1,
			create = function() return { x = 10 } end,
		})
		local r = p:with(function(obj) return obj.x + 5 end)
		T.eq(r, 15)
		T.eq(p:idle(), 1)
		T.eq(p:in_use(), 0)
	end)
end)

-- ── buffer pool ──────────────────────────────────────────────────────────────

T.describe("pool.buffers", function()
	T.it("creates buffer pool with defaults", function()
		local bp = pool.buffers({ size = 4 })
		T.ok(bp)
	end)

	T.it("acquire returns buffer with n and cap", function()
		local bp = pool.buffers({ size = 4, buffer_size = 256 })
		local buf = bp:acquire()
		T.ok(buf)
		T.eq(buf.n, 0)
		T.eq(buf.cap, 256)
	end)

	T.it("reset clears buffer contents on release", function()
		local bp = pool.buffers({ size = 4, buffer_size = 256 })
		local buf = bp:acquire()
		buf[1] = 65
		buf[2] = 66
		buf.n = 2
		bp:release(buf)
		local buf2 = bp:acquire()
		T.eq(buf, buf2) -- same reference
		T.eq(buf2.n, 0) -- reset cleared n
		T.eq(buf2[1], nil) -- reset cleared contents
		T.eq(buf2[2], nil)
	end)

	T.it("preserves cap across reset", function()
		local bp = pool.buffers({ size = 4, buffer_size = 1024 })
		local buf = bp:acquire()
		buf.n = 10
		bp:release(buf)
		local buf2 = bp:acquire()
		T.eq(buf2.cap, 1024)
	end)

	T.it("respects max size", function()
		local bp = pool.buffers({ size = 2 })
		bp:acquire()
		bp:acquire()
		local buf, err = bp:acquire()
		T.eq(buf, nil)
		T.eq(err, "pool exhausted")
	end)

	T.it("default buffer_size is 4096", function()
		local bp = pool.buffers({ size = 1 })
		local buf = bp:acquire()
		T.eq(buf.cap, 4096)
	end)

	T.it("default size is 16", function()
		local bp = pool.buffers({})
		T.ok(bp)
		-- acquire 16 should work
		local objs = {}
		for i = 1, 16 do objs[i] = bp:acquire() end
		local extra, err = bp:acquire()
		T.eq(extra, nil)
		T.eq(err, "pool exhausted")
	end)
end)

T.describe("destroy callback", function()
	T.it("not called on normal release", function()
		local destroyed = {}
		local n = 0
		local p = pool.new({
			size = 4,
			create = function() n = n + 1; return { id = n } end,
			destroy = function(obj) destroyed[#destroyed + 1] = obj.id end,
		})
		local a = p:acquire()
		p:release(a)
		T.eq(#destroyed, 0)
	end)

	T.it("called for each object on drain", function()
		local destroyed = {}
		local n = 0
		local p = pool.new({
			size = 4,
			create = function() n = n + 1; return { id = n } end,
			destroy = function(obj) destroyed[#destroyed + 1] = obj.id end,
		})
		local a = p:acquire()
		local b = p:acquire()
		local c = p:acquire()
		p:release(a)
		p:release(b)
		p:release(c)
		p:drain()
		T.eq(#destroyed, 3)
	end)
end)

T.describe("validate + stats interaction", function()
	T.it("invalid objects are not counted as reused", function()
		local n = 0
		local p = pool.new({
			size = 4,
			create = function() n = n + 1; return { id = n, ok = true } end,
			validate = function(obj) return obj.ok end,
		})
		local a = p:acquire()
		a.ok = false
		p:release(a)
		local b = p:acquire()
		T.ok(b)
		local s = p:stats()
		T.eq(s.created, 2) -- a and b
		T.eq(s.reused, 0) -- a was invalid, not reused
	end)
end)
