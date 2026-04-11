if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local PH = require("lib.pairing_heap")

T.describe("pairing_heap", function()

  T.describe("new / is_empty / size", function()
    T.it("starts empty", function()
      local h = PH.new()
      T.ok(h:is_empty())
      T.eq(h:size(), 0)
    end)

    T.it("is not empty after insert", function()
      local h = PH.new()
      h:insert(1, "a")
      T.ok(not h:is_empty())
      T.eq(h:size(), 1)
    end)

    T.it("size tracks insertions", function()
      local h = PH.new()
      for i = 1, 5 do h:insert(i, i) end
      T.eq(h:size(), 5)
    end)
  end)

  T.describe("peek", function()
    T.it("returns nil, nil on empty heap", function()
      local h = PH.new()
      local k, v = h:peek()
      T.eq(k, nil)
      T.eq(v, nil)
    end)

    T.it("returns minimum key", function()
      local h = PH.new()
      h:insert(5, "five")
      h:insert(3, "three")
      h:insert(7, "seven")
      local k, v = h:peek()
      T.eq(k, 3)
      T.eq(v, "three")
    end)

    T.it("does not remove the element", function()
      local h = PH.new()
      h:insert(2, "two")
      h:peek()
      T.eq(h:size(), 1)
    end)

    T.it("peek after insert of smaller key updates minimum", function()
      local h = PH.new()
      h:insert(10, "ten")
      h:insert(1, "one")
      local k, v = h:peek()
      T.eq(k, 1)
      T.eq(v, "one")
    end)
  end)

  T.describe("pop", function()
    T.it("returns nil, nil on empty heap", function()
      local h = PH.new()
      local k, v = h:pop()
      T.eq(k, nil)
      T.eq(v, nil)
    end)

    T.it("extracts minimum", function()
      local h = PH.new()
      h:insert(5, "five")
      h:insert(2, "two")
      h:insert(8, "eight")
      local k, v = h:pop()
      T.eq(k, 2)
      T.eq(v, "two")
      T.eq(h:size(), 2)
    end)

    T.it("extracts in sorted order", function()
      local h = PH.new()
      local keys = {4, 1, 7, 2, 9, 3, 6, 5, 8, 10}
      for _, k in ipairs(keys) do h:insert(k, k) end
      local out = {}
      while not h:is_empty() do
        local k = h:pop()
        out[#out + 1] = k
      end
      for i = 1, 10 do
        T.eq(out[i], i)
      end
    end)

    T.it("single element pop leaves heap empty", function()
      local h = PH.new()
      h:insert(42, "x")
      local k, v = h:pop()
      T.eq(k, 42)
      T.eq(v, "x")
      T.ok(h:is_empty())
    end)

    T.it("duplicate keys extracted in some order", function()
      local h = PH.new()
      h:insert(3, "a")
      h:insert(3, "b")
      h:insert(1, "c")
      local k1 = h:pop()
      T.eq(k1, 1)
      local k2 = h:pop()
      T.eq(k2, 3)
      local k3 = h:pop()
      T.eq(k3, 3)
      T.ok(h:is_empty())
    end)
  end)

  T.describe("insert N items, pop all → sorted", function()
    T.it("50 items in reverse order", function()
      local h = PH.new()
      for i = 50, 1, -1 do h:insert(i, i) end
      local prev = -math.huge
      local count = 0
      while not h:is_empty() do
        local k = h:pop()
        T.ok(k >= prev)
        prev = k
        count = count + 1
      end
      T.eq(count, 50)
    end)

    T.it("already sorted input", function()
      local h = PH.new()
      for i = 1, 20 do h:insert(i, i) end
      local out = {}
      while not h:is_empty() do out[#out + 1] = h:pop() end
      for i = 1, 20 do T.eq(out[i], i) end
    end)
  end)

  T.describe("merge", function()
    T.it("merge two heaps produces combined sorted output", function()
      local h1 = PH.new()
      local h2 = PH.new()
      h1:insert(1, "a"); h1:insert(3, "c"); h1:insert(5, "e")
      h2:insert(2, "b"); h2:insert(4, "d"); h2:insert(6, "f")
      h1:merge(h2)
      T.eq(h1:size(), 6)
      T.ok(h2:is_empty())
      local out = {}
      while not h1:is_empty() do out[#out + 1] = h1:pop() end
      for i = 1, 6 do T.eq(out[i], i) end
    end)

    T.it("merge with empty heap is identity", function()
      local h1 = PH.new()
      local h2 = PH.new()
      h1:insert(7, "x")
      h1:merge(h2)
      T.eq(h1:size(), 1)
      local k = h1:pop()
      T.eq(k, 7)
    end)

    T.it("merge empty with non-empty", function()
      local h1 = PH.new()
      local h2 = PH.new()
      h2:insert(5, "y")
      h1:merge(h2)
      T.eq(h1:size(), 1)
      local k = h1:pop()
      T.eq(k, 5)
      T.ok(h2:is_empty())
    end)

    T.it("merge preserves handles in receiving heap", function()
      local h1 = PH.new()
      local h2 = PH.new()
      h1:insert(10, "ten")
      local handle = h2:insert(2, "two")
      h1:merge(h2)
      -- handle still valid: remove via lazy deletion
      h1:remove(handle)
      T.eq(h1:size(), 1)
      local k = h1:pop()
      T.eq(k, 10)
    end)
  end)

  T.describe("max-heap with custom comparator", function()
    T.it("max-heap pops largest first", function()
      local h = PH.new(function(a, b) return a > b end)
      for _, k in ipairs({3, 1, 4, 1, 5, 9, 2, 6}) do
        h:insert(k, k)
      end
      local out = {}
      while not h:is_empty() do out[#out + 1] = h:pop() end
      -- Should be descending
      for i = 1, #out - 1 do
        T.ok(out[i] >= out[i + 1])
      end
      T.eq(#out, 8)
    end)

    T.it("max-heap peek returns largest", function()
      local h = PH.new(function(a, b) return a > b end)
      h:insert(7, "seven")
      h:insert(2, "two")
      h:insert(15, "fifteen")
      local k = h:peek()
      T.eq(k, 15)
    end)
  end)

  T.describe("decrease_key", function()
    T.it("decrease_key moves element forward in priority", function()
      local h = PH.new()
      h:insert(1, "one")
      local handle = h:insert(10, "ten")
      h:insert(5, "five")
      -- decrease 10 → 0
      local new_handle = h:decrease_key(handle, 0)
      T.ok(new_handle ~= nil)
      -- 0 should now be the minimum
      local k, v = h:peek()
      T.eq(k, 0)
      T.eq(v, "ten")
    end)

    T.it("decrease_key to same key is allowed", function()
      local h = PH.new()
      local handle = h:insert(5, "five")
      local new_handle, err = h:decrease_key(handle, 5)
      T.ok(new_handle ~= nil)
      T.eq(err, nil)
    end)

    T.it("decrease_key returns error for larger key", function()
      local h = PH.new()
      local handle = h:insert(3, "three")
      local result, err = h:decrease_key(handle, 10)
      T.eq(result, nil)
      T.ok(err ~= nil)
    end)

    T.it("decrease_key on removed handle returns error", function()
      local h = PH.new()
      local handle = h:insert(5, "five")
      h:remove(handle)
      local result, err = h:decrease_key(handle, 1)
      T.eq(result, nil)
      T.ok(err ~= nil)
    end)

    T.it("old handle is invalidated after decrease_key", function()
      local h = PH.new()
      h:insert(1, "a")
      local old = h:insert(8, "eight")
      h:decrease_key(old, 0)
      -- Old handle is marked removed; trying to decrease again should fail
      local result, err = h:decrease_key(old, -1)
      T.eq(result, nil)
      T.ok(err ~= nil)
    end)

    T.it("heap still sorts correctly after decrease_key", function()
      local h = PH.new()
      local handles = {}
      for i = 1, 5 do handles[i] = h:insert(i * 10, i * 10) end
      -- decrease 40 → 5, and 50 → 15
      h:decrease_key(handles[4], 5)
      h:decrease_key(handles[5], 15)
      local out = {}
      while not h:is_empty() do out[#out + 1] = h:pop() end
      -- expected order: 5, 10, 15, 20, 30
      T.eq(out[1], 5)
      T.eq(out[2], 10)
      T.eq(out[3], 15)
      T.eq(out[4], 20)
      T.eq(out[5], 30)
    end)
  end)

  T.describe("remove", function()
    T.it("remove handle: element not in subsequent pops", function()
      local h = PH.new()
      h:insert(1, "one")
      local handle = h:insert(2, "two")
      h:insert(3, "three")
      h:remove(handle)
      T.eq(h:size(), 2)
      local out = {}
      while not h:is_empty() do out[#out + 1] = h:pop() end
      T.eq(#out, 2)
      T.eq(out[1], 1)
      T.eq(out[2], 3)
    end)

    T.it("remove minimum element", function()
      local h = PH.new()
      local handle = h:insert(1, "one")
      h:insert(2, "two")
      h:insert(3, "three")
      h:remove(handle)
      T.eq(h:size(), 2)
      local k = h:pop()
      T.eq(k, 2)
    end)

    T.it("remove already-removed handle is safe (idempotent)", function()
      local h = PH.new()
      local handle = h:insert(5, "five")
      h:remove(handle)
      h:remove(handle)  -- second call should not panic or double-decrement
      T.eq(h:size(), 0)
    end)

    T.it("remove all elements one by one", function()
      local h = PH.new()
      local handles = {}
      for i = 1, 5 do handles[i] = h:insert(i, i) end
      for i = 1, 5 do h:remove(handles[i]) end
      T.ok(h:is_empty())
    end)
  end)

  T.describe("to_sorted", function()
    T.it("returns sorted key-value pairs", function()
      local h = PH.new()
      h:insert(3, "c"); h:insert(1, "a"); h:insert(2, "b")
      local sorted = h:to_sorted()
      T.eq(#sorted, 3)
      T.eq(sorted[1][1], 1); T.eq(sorted[1][2], "a")
      T.eq(sorted[2][1], 2); T.eq(sorted[2][2], "b")
      T.eq(sorted[3][1], 3); T.eq(sorted[3][2], "c")
    end)

    T.it("to_sorted on empty heap returns empty table", function()
      local h = PH.new()
      local sorted = h:to_sorted()
      T.eq(#sorted, 0)
    end)

    T.it("to_sorted consumes the heap", function()
      local h = PH.new()
      h:insert(10, "ten"); h:insert(20, "twenty")
      h:to_sorted()
      T.ok(h:is_empty())
    end)
  end)

  T.describe("pop from empty", function()
    T.it("pop returns nil, nil when empty", function()
      local h = PH.new()
      local k, v = h:pop()
      T.eq(k, nil)
      T.eq(v, nil)
    end)

    T.it("pop after draining returns nil, nil", function()
      local h = PH.new()
      h:insert(1, "x")
      h:pop()
      local k, v = h:pop()
      T.eq(k, nil)
      T.eq(v, nil)
    end)
  end)

  T.describe("1000 random items", function()
    T.it("insert 1000 items, pop all in sorted order", function()
      local h = PH.new()
      -- Simple LCG for determinism
      local seed = 12345
      local function next_rand()
        seed = (seed * 1664525 + 1013904223) % (2^32)
        return seed % 10000
      end
      for _ = 1, 1000 do
        local k = next_rand()
        h:insert(k, k)
      end
      T.eq(h:size(), 1000)
      local prev = -1
      local count = 0
      while not h:is_empty() do
        local k = h:pop()
        T.ok(k >= prev)
        prev = k
        count = count + 1
      end
      T.eq(count, 1000)
    end)
  end)

  T.describe("two-pass pairing correctness", function()
    T.it("odd number of children handled correctly", function()
      local h = PH.new()
      -- Insert 7 items to force an odd-length children list on pop
      for _, k in ipairs({10, 3, 7, 1, 5, 9, 2}) do
        h:insert(k, k)
      end
      local out = {}
      while not h:is_empty() do out[#out + 1] = h:pop() end
      local expected = {1, 2, 3, 5, 7, 9, 10}
      for i = 1, #expected do T.eq(out[i], expected[i]) end
    end)

    T.it("large merge sequence stays sorted", function()
      local h = PH.new()
      -- Interleave small and large keys to exercise pairing
      for i = 1, 30 do h:insert(31 - i, 31 - i) end
      for i = 1, 30 do h:insert(i, i) end
      local prev = -1
      local count = 0
      while not h:is_empty() do
        local k = h:pop()
        T.ok(k >= prev)
        prev = k
        count = count + 1
      end
      T.eq(count, 60)
    end)
  end)

end)
