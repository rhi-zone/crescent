if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local rb = require("lib.ringbuf")

-- ── meta ──────────────────────────────────────────────────────────────────────

T.describe("meta", function()
	T.it("_tier is pure", function()
		T.eq(rb._tier, "pure")
	end)
end)

-- ── ringbuf.new ───────────────────────────────────────────────────────────────

T.describe("ringbuf.new", function()
	T.it("creates a ring buffer with correct capacity", function()
		local r = rb.new(8)
		T.ok(r)
		T.eq(r:capacity(), 8)
	end)

	T.it("starts empty", function()
		local r = rb.new(4)
		T.eq(r:len(), 0)
		T.ok(r:is_empty())
		T.ok(not r:is_full())
	end)

	T.it("capacity 1 is allowed", function()
		local r = rb.new(1)
		T.eq(r:capacity(), 1)
	end)
end)

-- ── push / pop FIFO ordering ──────────────────────────────────────────────────

T.describe("push / pop FIFO", function()
	T.it("single push and pop", function()
		local r = rb.new(4)
		local ok = r:push(42)
		T.eq(ok, true)
		T.eq(r:len(), 1)
		local v = r:pop()
		T.eq(v, 42)
		T.eq(r:len(), 0)
	end)

	T.it("FIFO ordering across multiple items", function()
		local r = rb.new(8)
		for i = 1, 5 do r:push(i) end
		for i = 1, 5 do
			T.eq(r:pop(), i)
		end
	end)

	T.it("pop from empty returns nil", function()
		local r = rb.new(4)
		T.eq(r:pop(), nil)
	end)

	T.it("push to full returns (nil, 'full')", function()
		local r = rb.new(3)
		r:push(1); r:push(2); r:push(3)
		local ok, err = r:push(4)
		T.eq(ok, nil)
		T.eq(err, "full")
	end)

	T.it("push succeeds again after pop frees space", function()
		local r = rb.new(2)
		r:push(1); r:push(2)
		r:pop()
		local ok = r:push(3)
		T.eq(ok, true)
		T.eq(r:pop(), 2)
		T.eq(r:pop(), 3)
	end)
end)

-- ── is_empty / is_full / len / capacity ──────────────────────────────────────

T.describe("state queries", function()
	T.it("is_empty false after push", function()
		local r = rb.new(4)
		r:push("x")
		T.ok(not r:is_empty())
	end)

	T.it("is_full true when at capacity", function()
		local r = rb.new(3)
		r:push(1); r:push(2); r:push(3)
		T.ok(r:is_full())
	end)

	T.it("is_full false after pop from full", function()
		local r = rb.new(2)
		r:push(1); r:push(2)
		r:pop()
		T.ok(not r:is_full())
	end)

	T.it("len tracks correctly through push and pop", function()
		local r = rb.new(8)
		T.eq(r:len(), 0)
		r:push("a"); T.eq(r:len(), 1)
		r:push("b"); T.eq(r:len(), 2)
		r:pop();     T.eq(r:len(), 1)
		r:pop();     T.eq(r:len(), 0)
	end)

	T.it("capacity is immutable", function()
		local r = rb.new(7)
		r:push(1); r:push(2)
		T.eq(r:capacity(), 7)
	end)
end)

-- ── wrap-around ───────────────────────────────────────────────────────────────

T.describe("wrap-around", function()
	T.it("indices cross capacity boundary correctly", function()
		local r = rb.new(4)
		r:push(1); r:push(2); r:push(3); r:push(4)
		r:pop(); r:pop()            -- consume 1, 2; head now at slot 3
		r:push(5); r:push(6)       -- these wrap around
		T.eq(r:pop(), 3)
		T.eq(r:pop(), 4)
		T.eq(r:pop(), 5)
		T.eq(r:pop(), 6)
		T.ok(r:is_empty())
	end)

	T.it("to_array correct after wrap", function()
		local r = rb.new(3)
		r:push(1); r:push(2); r:push(3)
		r:pop(); r:pop()
		r:push(4); r:push(5)
		local a = r:to_array()
		T.eq(#a, 3)
		T.eq(a[1], 3)
		T.eq(a[2], 4)
		T.eq(a[3], 5)
	end)

	T.it("iter correct after wrap", function()
		local r = rb.new(3)
		r:push(10); r:push(20); r:push(30)
		r:pop()
		r:push(40)
		local out = {}
		for v in r:iter() do out[#out + 1] = v end
		T.eq(#out, 3)
		T.eq(out[1], 20)
		T.eq(out[2], 30)
		T.eq(out[3], 40)
	end)

	T.it("push_overwrite wrap-around still FIFO", function()
		local r = rb.new(4)
		r:push(1); r:push(2); r:push(3); r:push(4)
		r:pop(); r:pop()
		r:push(5); r:push(6)
		r:push_overwrite(7) -- evicts 3
		r:push_overwrite(8) -- evicts 4
		local a = r:to_array()
		T.eq(#a, 4)
		T.eq(a[1], 5)
		T.eq(a[2], 6)
		T.eq(a[3], 7)
		T.eq(a[4], 8)
	end)
end)

-- ── push_overwrite ────────────────────────────────────────────────────────────

T.describe("push_overwrite", function()
	T.it("behaves like push when not full", function()
		local r = rb.new(4)
		r:push_overwrite(1)
		r:push_overwrite(2)
		T.eq(r:len(), 2)
		T.eq(r:pop(), 1)
		T.eq(r:pop(), 2)
	end)

	T.it("evicts oldest when full", function()
		local r = rb.new(3)
		r:push(1); r:push(2); r:push(3)
		r:push_overwrite(4)
		T.eq(r:len(), 3)
		T.eq(r:pop(), 2)
		T.eq(r:pop(), 3)
		T.eq(r:pop(), 4)
	end)

	T.it("repeated overwrites keep last N", function()
		local r = rb.new(3)
		for i = 1, 10 do r:push_overwrite(i) end
		local a = r:to_array()
		T.eq(#a, 3)
		T.eq(a[1], 8)
		T.eq(a[2], 9)
		T.eq(a[3], 10)
	end)

	T.it("capacity-1 overwrite", function()
		local r = rb.new(1)
		r:push_overwrite("a")
		r:push_overwrite("b")
		r:push_overwrite("c")
		T.eq(r:len(), 1)
		T.eq(r:pop(), "c")
	end)
end)

-- ── peek / peek_newest ────────────────────────────────────────────────────────

T.describe("peek", function()
	T.it("peek returns oldest without removing", function()
		local r = rb.new(4)
		r:push(10); r:push(20); r:push(30)
		T.eq(r:peek(), 10)
		T.eq(r:len(), 3)   -- not consumed
	end)

	T.it("peek_newest returns newest without removing", function()
		local r = rb.new(4)
		r:push(10); r:push(20); r:push(30)
		T.eq(r:peek_newest(), 30)
		T.eq(r:len(), 3)
	end)

	T.it("peek on empty returns nil", function()
		local r = rb.new(4)
		T.eq(r:peek(), nil)
	end)

	T.it("peek_newest on empty returns nil", function()
		local r = rb.new(4)
		T.eq(r:peek_newest(), nil)
	end)

	T.it("peek differs from pop: value remains", function()
		local r = rb.new(2)
		r:push("x")
		T.eq(r:peek(), "x")
		T.eq(r:pop(), "x")
		T.eq(r:pop(), nil)
	end)

	T.it("peek_newest after wrap-around", function()
		local r = rb.new(3)
		r:push(1); r:push(2); r:push(3)
		r:pop()
		r:push(4)
		T.eq(r:peek(), 2)
		T.eq(r:peek_newest(), 4)
	end)
end)

-- ── to_array ──────────────────────────────────────────────────────────────────

T.describe("to_array", function()
	T.it("returns items oldest first", function()
		local r = rb.new(5)
		r:push("a"); r:push("b"); r:push("c")
		local a = r:to_array()
		T.eq(#a, 3)
		T.eq(a[1], "a")
		T.eq(a[2], "b")
		T.eq(a[3], "c")
	end)

	T.it("empty buffer gives empty array", function()
		local r = rb.new(4)
		local a = r:to_array()
		T.eq(#a, 0)
	end)

	T.it("full buffer snapshot", function()
		local r = rb.new(4)
		r:push(1); r:push(2); r:push(3); r:push(4)
		local a = r:to_array()
		T.eq(#a, 4)
		T.eq(a[1], 1); T.eq(a[4], 4)
	end)

	T.it("to_array does not modify the buffer", function()
		local r = rb.new(3)
		r:push(7); r:push(8); r:push(9)
		r:to_array()
		T.eq(r:len(), 3)
		T.eq(r:pop(), 7)
	end)
end)

-- ── iter ──────────────────────────────────────────────────────────────────────

T.describe("iter", function()
	T.it("iterates oldest-first", function()
		local r = rb.new(4)
		r:push(100); r:push(200); r:push(300)
		local out = {}
		for v in r:iter() do out[#out + 1] = v end
		T.eq(#out, 3)
		T.eq(out[1], 100)
		T.eq(out[2], 200)
		T.eq(out[3], 300)
	end)

	T.it("empty buffer iterator returns nothing", function()
		local r = rb.new(4)
		local count = 0
		for _ in r:iter() do count = count + 1 end
		T.eq(count, 0)
	end)

	T.it("iter does not consume items", function()
		local r = rb.new(3)
		r:push(1); r:push(2)
		for _ in r:iter() do end
		T.eq(r:len(), 2)
	end)

	T.it("iter matches to_array order", function()
		local r = rb.new(5)
		for i = 1, 5 do r:push(i * 3) end
		local arr = r:to_array()
		local i = 0
		for v in r:iter() do
			i = i + 1
			T.eq(v, arr[i])
		end
		T.eq(i, 5)
	end)
end)

-- ── clear ─────────────────────────────────────────────────────────────────────

T.describe("clear", function()
	T.it("resets to empty state", function()
		local r = rb.new(4)
		r:push(1); r:push(2); r:push(3)
		r:clear()
		T.ok(r:is_empty())
		T.eq(r:len(), 0)
		T.eq(r:pop(), nil)
	end)

	T.it("can push again after clear", function()
		local r = rb.new(2)
		r:push(1); r:push(2)
		r:clear()
		T.eq(r:push(10), true)
		T.eq(r:push(20), true)
		T.eq(r:pop(), 10)
		T.eq(r:pop(), 20)
	end)

	T.it("capacity unchanged after clear", function()
		local r = rb.new(6)
		r:push(1)
		r:clear()
		T.eq(r:capacity(), 6)
	end)
end)

-- ── bytes flavor ──────────────────────────────────────────────────────────────

T.describe("bytes", function()
	T.it("creates byte ring buffer", function()
		local b = rb.bytes(64)
		T.ok(b)
		T.eq(b:available(), 0)
		T.eq(b:free(), 64)
	end)

	T.it("push_string and pop_string round-trip", function()
		local b = rb.bytes(32)
		local ok = b:push_string("hello")
		T.eq(ok, true)
		T.eq(b:available(), 5)
		T.eq(b:free(), 27)
		local s = b:pop_string(5)
		T.eq(s, "hello")
		T.eq(b:available(), 0)
	end)

	T.it("push_string fails when not enough space", function()
		local b = rb.bytes(4)
		local ok, err = b:push_string("12345")
		T.eq(ok, nil)
		T.eq(err, "not enough space")
	end)

	T.it("pop_string fails when not enough data", function()
		local b = rb.bytes(16)
		b:push_string("hi")
		local s, err = b:pop_string(5)
		T.eq(s, nil)
		T.eq(err, "not enough data")
	end)

	T.it("peek_string is non-destructive", function()
		local b = rb.bytes(32)
		b:push_string("world")
		local s = b:peek_string(5)
		T.eq(s, "world")
		T.eq(b:available(), 5)   -- not consumed
	end)

	T.it("peek_string returns same bytes as pop_string", function()
		local b = rb.bytes(32)
		b:push_string("abcde")
		local peeked = b:peek_string(3)
		local popped = b:pop_string(3)
		T.eq(peeked, popped)
	end)

	T.it("peek_string fails when not enough data", function()
		local b = rb.bytes(16)
		b:push_string("xy")
		local s, err = b:peek_string(3)
		T.eq(s, nil)
		T.eq(err, "not enough data")
	end)

	T.it("partial reads: pop less than available", function()
		local b = rb.bytes(32)
		b:push_string("abcdef")
		local s1 = b:pop_string(2)
		T.eq(s1, "ab")
		T.eq(b:available(), 4)
		local s2 = b:pop_string(4)
		T.eq(s2, "cdef")
		T.eq(b:available(), 0)
	end)

	T.it("available and free sum to capacity", function()
		local b = rb.bytes(16)
		b:push_string("hello")
		T.eq(b:available() + b:free(), 16)
	end)

	T.it("wrap-around: write past end of buffer", function()
		local b = rb.bytes(8)
		b:push_string("12345678")    -- fill completely
		b:pop_string(5)              -- free first 5 bytes (head moves)
		-- now free=5 at end of ring; tail wraps around
		local ok = b:push_string("ABCDE")
		T.eq(ok, true)
		T.eq(b:available(), 8)
		local s = b:pop_string(8)
		T.eq(s, "678ABCDE")
	end)

	T.it("wrap-around: pop spanning boundary", function()
		local b = rb.bytes(6)
		b:push_string("abcdef")
		b:pop_string(4)            -- consume "abcd"; head at slot 5
		b:push_string("WXYZ")      -- W=slot5, X=slot6, Y=slot1(wrap), Z=slot2
		-- buffer holds "efWXYZ"
		local s = b:pop_string(6)
		T.eq(s, "efWXYZ")
	end)

	T.it("empty push_string returns true immediately", function()
		local b = rb.bytes(4)
		local ok = b:push_string("")
		T.eq(ok, true)
		T.eq(b:available(), 0)
	end)

	T.it("zero-byte pop_string returns empty string", function()
		local b = rb.bytes(4)
		b:push_string("abc")
		local s = b:pop_string(0)
		T.eq(s, "")
		T.eq(b:available(), 3)
	end)

	T.it("zero-byte peek_string returns empty string", function()
		local b = rb.bytes(4)
		b:push_string("abc")
		local s = b:peek_string(0)
		T.eq(s, "")
		T.eq(b:available(), 3)
	end)

	T.it("multiple push then pop maintains FIFO order", function()
		local b = rb.bytes(32)
		b:push_string("foo")
		b:push_string("bar")
		b:push_string("baz")
		local s = b:pop_string(9)
		T.eq(s, "foobarbaz")
	end)

	T.it("clear resets byte buffer", function()
		local b = rb.bytes(16)
		b:push_string("test")
		b:clear()
		T.eq(b:available(), 0)
		T.eq(b:free(), 16)
		-- can push again after clear
		local ok = b:push_string("again")
		T.eq(ok, true)
		T.eq(b:pop_string(5), "again")
	end)

	T.it("fills to exact capacity", function()
		local b = rb.bytes(5)
		local ok = b:push_string("HELLO")
		T.eq(ok, true)
		T.eq(b:available(), 5)
		T.eq(b:free(), 0)
		-- one more byte should fail
		local ok2, err = b:push_string("!")
		T.eq(ok2, nil)
		T.eq(err, "not enough space")
	end)

	T.it("binary bytes round-trip (all byte values)", function()
		local b = rb.bytes(256)
		local all = {}
		for i = 0, 255 do all[i + 1] = i end
		local s = string.char(unpack(all))
		b:push_string(s)
		local out = b:pop_string(256)
		T.eq(out, s)
	end)

	T.it("available/free tracking across interleaved push/pop", function()
		local b = rb.bytes(10)
		b:push_string("hello")    -- available=5, free=5
		T.eq(b:available(), 5)
		T.eq(b:free(), 5)
		b:pop_string(2)           -- available=3, free=7
		T.eq(b:available(), 3)
		T.eq(b:free(), 7)
		b:push_string("XYZ")     -- available=6, free=4
		T.eq(b:available(), 6)
		T.eq(b:free(), 4)
	end)
end)
