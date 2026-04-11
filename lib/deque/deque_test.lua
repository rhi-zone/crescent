-- lib/deque/deque_test.lua — tests for lib/deque/init.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local deque = require("lib.deque")

-- ── construction ─────────────────────────────────────────────────────────────

T.describe("new", function()
	T.it("creates an empty deque", function()
		local d = deque.new()
		T.eq(d:size(), 0)
		T.eq(d:empty(), true)
	end)
end)

-- ── push_back / pop_back ─────────────────────────────────────────────────────

T.describe("push_back / pop_back", function()
	T.it("pushes and pops single element", function()
		local d = deque.new()
		d:push_back(42)
		T.eq(d:size(), 1)
		T.eq(d:pop_back(), 42)
		T.eq(d:size(), 0)
	end)

	T.it("LIFO order for back operations", function()
		local d = deque.new()
		d:push_back(1)
		d:push_back(2)
		d:push_back(3)
		T.eq(d:pop_back(), 3)
		T.eq(d:pop_back(), 2)
		T.eq(d:pop_back(), 1)
	end)

	T.it("pop_back on empty returns nil and error", function()
		local d = deque.new()
		local v, err = d:pop_back()
		T.eq(v, nil)
		T.eq(err, "deque is empty")
	end)
end)

-- ── push_front / pop_front ───────────────────────────────────────────────────

T.describe("push_front / pop_front", function()
	T.it("pushes and pops single element", function()
		local d = deque.new()
		d:push_front(99)
		T.eq(d:size(), 1)
		T.eq(d:pop_front(), 99)
		T.eq(d:size(), 0)
	end)

	T.it("LIFO order for front operations", function()
		local d = deque.new()
		d:push_front(1)
		d:push_front(2)
		d:push_front(3)
		T.eq(d:pop_front(), 3)
		T.eq(d:pop_front(), 2)
		T.eq(d:pop_front(), 1)
	end)

	T.it("pop_front on empty returns nil and error", function()
		local d = deque.new()
		local v, err = d:pop_front()
		T.eq(v, nil)
		T.eq(err, "deque is empty")
	end)
end)

-- ── queue behavior (FIFO) ────────────────────────────────────────────────────

T.describe("queue (FIFO)", function()
	T.it("push_back, pop_front gives FIFO", function()
		local d = deque.new()
		d:push_back("a")
		d:push_back("b")
		d:push_back("c")
		T.eq(d:pop_front(), "a")
		T.eq(d:pop_front(), "b")
		T.eq(d:pop_front(), "c")
	end)

	T.it("push_front, pop_back gives FIFO", function()
		local d = deque.new()
		d:push_front("x")
		d:push_front("y")
		d:push_front("z")
		T.eq(d:pop_back(), "x")
		T.eq(d:pop_back(), "y")
		T.eq(d:pop_back(), "z")
	end)
end)

-- ── mixed operations ─────────────────────────────────────────────────────────

T.describe("mixed push/pop", function()
	T.it("interleaved front and back pushes", function()
		local d = deque.new()
		d:push_back(1)
		d:push_front(2)
		d:push_back(3)
		d:push_front(4)
		-- order: 4, 2, 1, 3
		T.eq(d:pop_front(), 4)
		T.eq(d:pop_front(), 2)
		T.eq(d:pop_front(), 1)
		T.eq(d:pop_front(), 3)
	end)

	T.it("push and pop interleaved", function()
		local d = deque.new()
		d:push_back(1)
		d:push_back(2)
		T.eq(d:pop_front(), 1)
		d:push_back(3)
		T.eq(d:pop_front(), 2)
		T.eq(d:pop_front(), 3)
		T.eq(d:empty(), true)
	end)

	T.it("drain and refill", function()
		local d = deque.new()
		for i = 1, 5 do d:push_back(i) end
		for _ = 1, 5 do d:pop_front() end
		T.eq(d:empty(), true)
		for i = 10, 15 do d:push_back(i) end
		T.eq(d:size(), 6)
		T.eq(d:pop_front(), 10)
	end)
end)

-- ── peek ─────────────────────────────────────────────────────────────────────

T.describe("peek_front / peek_back", function()
	T.it("returns front/back without removing", function()
		local d = deque.new()
		d:push_back(10)
		d:push_back(20)
		d:push_back(30)
		T.eq(d:peek_front(), 10)
		T.eq(d:peek_back(), 30)
		T.eq(d:size(), 3)
	end)

	T.it("peek on empty returns nil and error", function()
		local d = deque.new()
		local v, err = d:peek_front()
		T.eq(v, nil)
		T.eq(err, "deque is empty")
		v, err = d:peek_back()
		T.eq(v, nil)
		T.eq(err, "deque is empty")
	end)

	T.it("peek after push_front", function()
		local d = deque.new()
		d:push_front(5)
		T.eq(d:peek_front(), 5)
		T.eq(d:peek_back(), 5)
	end)
end)

-- ── get / set ────────────────────────────────────────────────────────────────

T.describe("get / set", function()
	T.it("1-based indexing from front", function()
		local d = deque.new()
		d:push_back("a")
		d:push_back("b")
		d:push_back("c")
		T.eq(d:get(1), "a")
		T.eq(d:get(2), "b")
		T.eq(d:get(3), "c")
	end)

	T.it("works after push_front", function()
		local d = deque.new()
		d:push_front(3)
		d:push_front(2)
		d:push_front(1)
		T.eq(d:get(1), 1)
		T.eq(d:get(2), 2)
		T.eq(d:get(3), 3)
	end)

	T.it("set replaces element", function()
		local d = deque.new()
		d:push_back(1)
		d:push_back(2)
		d:push_back(3)
		T.eq(d:set(2, 99), true)
		T.eq(d:get(2), 99)
	end)

	T.it("get out of bounds returns nil and error", function()
		local d = deque.new()
		d:push_back(1)
		local v, err = d:get(0)
		T.eq(v, nil)
		T.eq(err, "index out of bounds")
		v, err = d:get(2)
		T.eq(v, nil)
		T.eq(err, "index out of bounds")
	end)

	T.it("set out of bounds returns nil and error", function()
		local d = deque.new()
		d:push_back(1)
		local ok, err = d:set(0, 5)
		T.eq(ok, nil)
		T.eq(err, "index out of bounds")
		ok, err = d:set(2, 5)
		T.eq(ok, nil)
		T.eq(err, "index out of bounds")
	end)

	T.it("get on empty returns error", function()
		local d = deque.new()
		local v, err = d:get(1)
		T.eq(v, nil)
		T.eq(err, "index out of bounds")
	end)
end)

-- ── size / empty / clear ─────────────────────────────────────────────────────

T.describe("size / empty / clear", function()
	T.it("size tracks pushes and pops", function()
		local d = deque.new()
		T.eq(d:size(), 0)
		d:push_back(1)
		T.eq(d:size(), 1)
		d:push_front(2)
		T.eq(d:size(), 2)
		d:pop_back()
		T.eq(d:size(), 1)
		d:pop_front()
		T.eq(d:size(), 0)
	end)

	T.it("empty is true only when size is 0", function()
		local d = deque.new()
		T.eq(d:empty(), true)
		d:push_back(1)
		T.eq(d:empty(), false)
		d:pop_back()
		T.eq(d:empty(), true)
	end)

	T.it("clear resets the deque", function()
		local d = deque.new()
		for i = 1, 10 do d:push_back(i) end
		d:clear()
		T.eq(d:size(), 0)
		T.eq(d:empty(), true)
		local v, err = d:pop_front()
		T.eq(v, nil)
		T.eq(err, "deque is empty")
	end)

	T.it("clear then reuse", function()
		local d = deque.new()
		d:push_back(1)
		d:push_back(2)
		d:clear()
		d:push_back(3)
		T.eq(d:size(), 1)
		T.eq(d:pop_front(), 3)
	end)
end)

-- ── to_array ─────────────────────────────────────────────────────────────────

T.describe("to_array", function()
	T.it("returns elements front to back", function()
		local d = deque.new()
		d:push_back(1)
		d:push_back(2)
		d:push_back(3)
		local arr = d:to_array()
		T.eq(#arr, 3)
		T.eq(arr[1], 1)
		T.eq(arr[2], 2)
		T.eq(arr[3], 3)
	end)

	T.it("handles mixed push_front and push_back", function()
		local d = deque.new()
		d:push_front(2)
		d:push_front(1)
		d:push_back(3)
		local arr = d:to_array()
		T.eq(arr[1], 1)
		T.eq(arr[2], 2)
		T.eq(arr[3], 3)
	end)

	T.it("returns empty table for empty deque", function()
		local d = deque.new()
		local arr = d:to_array()
		T.eq(#arr, 0)
	end)

	T.it("does not alias internal storage", function()
		local d = deque.new()
		d:push_back(1)
		local arr = d:to_array()
		arr[1] = 999
		T.eq(d:get(1), 1) -- original unchanged
	end)
end)

-- ── iter ─────────────────────────────────────────────────────────────────────

T.describe("iter", function()
	T.it("iterates front to back", function()
		local d = deque.new()
		d:push_back(10)
		d:push_back(20)
		d:push_back(30)
		local result = {}
		for v in d:iter() do
			result[#result + 1] = v
		end
		T.eq(#result, 3)
		T.eq(result[1], 10)
		T.eq(result[2], 20)
		T.eq(result[3], 30)
	end)

	T.it("iterates empty deque without error", function()
		local d = deque.new()
		local count = 0
		for _ in d:iter() do count = count + 1 end
		T.eq(count, 0)
	end)

	T.it("iterates after mixed operations", function()
		local d = deque.new()
		d:push_front(1)
		d:push_back(2)
		d:push_front(0)
		local result = {}
		for v in d:iter() do result[#result + 1] = v end
		T.eq(result[1], 0)
		T.eq(result[2], 1)
		T.eq(result[3], 2)
	end)
end)

-- ── iter_reverse ─────────────────────────────────────────────────────────────

T.describe("iter_reverse", function()
	T.it("iterates back to front", function()
		local d = deque.new()
		d:push_back(10)
		d:push_back(20)
		d:push_back(30)
		local result = {}
		for v in d:iter_reverse() do
			result[#result + 1] = v
		end
		T.eq(#result, 3)
		T.eq(result[1], 30)
		T.eq(result[2], 20)
		T.eq(result[3], 10)
	end)

	T.it("iterates empty deque without error", function()
		local d = deque.new()
		local count = 0
		for _ in d:iter_reverse() do count = count + 1 end
		T.eq(count, 0)
	end)
end)

-- ── rotate ───────────────────────────────────────────────────────────────────

T.describe("rotate", function()
	T.it("rotate(1) moves front to back", function()
		local d = deque.new()
		d:push_back(1)
		d:push_back(2)
		d:push_back(3)
		d:rotate(1)
		T.eq(d:pop_front(), 2)
		T.eq(d:pop_front(), 3)
		T.eq(d:pop_front(), 1)
	end)

	T.it("rotate(2) moves two elements", function()
		local d = deque.new()
		d:push_back(1)
		d:push_back(2)
		d:push_back(3)
		d:push_back(4)
		d:rotate(2)
		local arr = d:to_array()
		T.eq(arr[1], 3)
		T.eq(arr[2], 4)
		T.eq(arr[3], 1)
		T.eq(arr[4], 2)
	end)

	T.it("negative rotation moves back to front", function()
		local d = deque.new()
		d:push_back(1)
		d:push_back(2)
		d:push_back(3)
		d:rotate(-1)
		-- -1 on size 3 => rotate(2)
		local arr = d:to_array()
		T.eq(arr[1], 3)
		T.eq(arr[2], 1)
		T.eq(arr[3], 2)
	end)

	T.it("rotate(0) is a no-op", function()
		local d = deque.new()
		d:push_back(1)
		d:push_back(2)
		d:rotate(0)
		T.eq(d:get(1), 1)
		T.eq(d:get(2), 2)
	end)

	T.it("rotate by size is a no-op", function()
		local d = deque.new()
		d:push_back(1)
		d:push_back(2)
		d:push_back(3)
		d:rotate(3)
		T.eq(d:get(1), 1)
		T.eq(d:get(2), 2)
		T.eq(d:get(3), 3)
	end)

	T.it("rotate single element is a no-op", function()
		local d = deque.new()
		d:push_back(42)
		d:rotate(1)
		T.eq(d:get(1), 42)
	end)

	T.it("rotate empty is a no-op", function()
		local d = deque.new()
		d:rotate(5) -- should not error
		T.eq(d:empty(), true)
	end)

	T.it("rotate large n wraps around", function()
		local d = deque.new()
		d:push_back(1)
		d:push_back(2)
		d:push_back(3)
		d:rotate(7) -- 7 % 3 = 1
		T.eq(d:get(1), 2)
		T.eq(d:get(2), 3)
		T.eq(d:get(3), 1)
	end)
end)

-- ── contains ─────────────────────────────────────────────────────────────────

T.describe("contains", function()
	T.it("finds present element", function()
		local d = deque.new()
		d:push_back(1)
		d:push_back(2)
		d:push_back(3)
		T.eq(d:contains(2), true)
	end)

	T.it("returns false for absent element", function()
		local d = deque.new()
		d:push_back(1)
		d:push_back(2)
		T.eq(d:contains(99), false)
	end)

	T.it("returns false on empty deque", function()
		local d = deque.new()
		T.eq(d:contains(1), false)
	end)

	T.it("finds element added via push_front", function()
		local d = deque.new()
		d:push_front(5)
		T.eq(d:contains(5), true)
	end)

	T.it("finds string values", function()
		local d = deque.new()
		d:push_back("hello")
		d:push_back("world")
		T.eq(d:contains("hello"), true)
		T.eq(d:contains("missing"), false)
	end)

	T.it("distinguishes nil-like values", function()
		local d = deque.new()
		d:push_back(false)
		T.eq(d:contains(false), true)
		T.eq(d:contains(nil), false)
	end)
end)

-- ── growth / large deque ─────────────────────────────────────────────────────

T.describe("growth", function()
	T.it("handles many elements (push_back)", function()
		local d = deque.new()
		local n = 1000
		for i = 1, n do d:push_back(i) end
		T.eq(d:size(), n)
		T.eq(d:get(1), 1)
		T.eq(d:get(n), n)
		for i = 1, n do
			T.eq(d:pop_front(), i)
		end
		T.eq(d:empty(), true)
	end)

	T.it("handles many elements (push_front)", function()
		local d = deque.new()
		local n = 1000
		for i = 1, n do d:push_front(i) end
		T.eq(d:size(), n)
		-- push_front reverses order: last pushed is at front
		T.eq(d:get(1), n)
		T.eq(d:get(n), 1)
	end)

	T.it("alternating push_front/push_back grows both directions", function()
		local d = deque.new()
		for i = 1, 100 do
			d:push_back(i)
			d:push_front(-i)
		end
		T.eq(d:size(), 200)
		T.eq(d:peek_front(), -100)
		T.eq(d:peek_back(), 100)
	end)
end)

-- ── edge cases ───────────────────────────────────────────────────────────────

T.describe("edge cases", function()
	T.it("stores nil-ish values (false)", function()
		local d = deque.new()
		d:push_back(false)
		T.eq(d:size(), 1)
		T.eq(d:peek_front(), false)
		T.eq(d:pop_front(), false)
	end)

	T.it("stores 0", function()
		local d = deque.new()
		d:push_back(0)
		T.eq(d:peek_back(), 0)
		T.eq(d:pop_back(), 0)
	end)

	T.it("stores empty string", function()
		local d = deque.new()
		d:push_back("")
		T.eq(d:contains(""), true)
		T.eq(d:pop_back(), "")
	end)

	T.it("single element: peek_front == peek_back", function()
		local d = deque.new()
		d:push_back(7)
		T.eq(d:peek_front(), 7)
		T.eq(d:peek_back(), 7)
	end)

	T.it("push/pop/push reuses indices without corruption", function()
		local d = deque.new()
		for i = 1, 50 do d:push_back(i) end
		for _ = 1, 50 do d:pop_front() end
		for i = 51, 100 do d:push_back(i) end
		T.eq(d:size(), 50)
		T.eq(d:get(1), 51)
		T.eq(d:get(50), 100)
	end)

	T.it("get/set after pop_front still correct", function()
		local d = deque.new()
		d:push_back(1)
		d:push_back(2)
		d:push_back(3)
		d:pop_front()
		-- now [2, 3] with indices shifted
		T.eq(d:get(1), 2)
		T.eq(d:get(2), 3)
		T.eq(d:set(1, 20), true)
		T.eq(d:get(1), 20)
	end)

	T.it("multiple clears", function()
		local d = deque.new()
		d:push_back(1)
		d:clear()
		d:clear() -- double clear should be safe
		T.eq(d:empty(), true)
		d:push_back(2)
		T.eq(d:pop_front(), 2)
	end)

	T.it("to_array after partial drain", function()
		local d = deque.new()
		d:push_back(1)
		d:push_back(2)
		d:push_back(3)
		d:pop_front()
		local arr = d:to_array()
		T.eq(#arr, 2)
		T.eq(arr[1], 2)
		T.eq(arr[2], 3)
	end)

	T.it("iter_reverse on single element", function()
		local d = deque.new()
		d:push_back(42)
		local result = {}
		for v in d:iter_reverse() do result[#result + 1] = v end
		T.eq(#result, 1)
		T.eq(result[1], 42)
	end)

	T.it("table values are stored by reference", function()
		local d = deque.new()
		local t = { x = 1 }
		d:push_back(t)
		t.x = 2
		T.eq(d:get(1).x, 2)
	end)
end)
