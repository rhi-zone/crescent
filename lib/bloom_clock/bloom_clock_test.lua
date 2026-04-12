if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local BC = require("lib.bloom_clock")

T.describe("bloom_clock", function()

  T.describe("new", function()
    T.it("creates clock with time 0", function()
      local c = BC.new("node1")
      T.eq(c:time(), 0)
    end)

    T.it("uses default size and hash_count", function()
      local c = BC.new("node1")
      T.ok(c._size == 64)
      T.ok(c._hash_count == 3)
    end)

    T.it("accepts custom size and hash_count", function()
      local c = BC.new("node1", {size=128, hash_count=5})
      T.ok(c._size == 128)
      T.ok(c._hash_count == 5)
    end)

    T.it("returns nil,err for non-string node_id", function()
      local c, err = BC.new(42)
      T.eq(c, nil)
      T.ok(type(err) == "string")
    end)

    T.it("returns nil,err for size < 1", function()
      local c, err = BC.new("x", {size=0})
      T.eq(c, nil)
      T.ok(type(err) == "string")
    end)
  end)

  T.describe("tick", function()
    T.it("increments time by 1", function()
      local c = BC.new("node1")
      c:tick()
      T.eq(c:time(), 1)
    end)

    T.it("increments time multiple times", function()
      local c = BC.new("node1")
      c:tick()
      c:tick()
      c:tick()
      T.eq(c:time(), 3)
    end)

    T.it("sets bits in the filter on tick", function()
      local c = BC.new("node1", {size=64})
      -- All words should be zero before tick
      local all_zero = true
      for _, w in ipairs(c._filter) do
        if w ~= 0 then all_zero = false end
      end
      T.ok(all_zero)
      c:tick()
      -- After tick, at least some bits should be set
      local any_set = false
      for _, w in ipairs(c._filter) do
        if w ~= 0 then any_set = true end
      end
      T.ok(any_set)
    end)

    T.it("multiple ticks accumulate filter bits", function()
      local c = BC.new("node1", {size=64})
      c:tick()
      -- Count set bits after 1 tick
      local bits1 = 0
      for _, w in ipairs(c._filter) do
        local v = w
        while v ~= 0 do
          bits1 = bits1 + (v % 2)
          v = math.floor(v / 2)
        end
      end
      c:tick()
      c:tick()
      -- After more ticks, count should be >= bits1 (union grows)
      local bits3 = 0
      for _, w in ipairs(c._filter) do
        local v = w
        while v ~= 0 do
          bits3 = bits3 + (v % 2)
          v = math.floor(v / 2)
        end
      end
      T.ok(bits3 >= bits1)
    end)
  end)

  T.describe("merge", function()
    T.it("takes max time when other is larger", function()
      local a = BC.new("A")
      local b = BC.new("B")
      a:tick()
      a:tick()  -- a.time = 2
      b:tick()  -- b.time = 1
      b:merge(a)
      T.eq(b:time(), 2)
    end)

    T.it("keeps own time when larger", function()
      local a = BC.new("A")
      local b = BC.new("B")
      a:tick()         -- a.time = 1
      b:tick()
      b:tick()
      b:tick()         -- b.time = 3
      b:merge(a)
      T.eq(b:time(), 3)
    end)

    T.it("ORs filter bits together", function()
      local a = BC.new("A", {size=64, hash_count=3})
      local b = BC.new("B", {size=64, hash_count=3})
      a:tick()
      b:tick()
      -- Save b's filter word states before merge
      local b_pre = {}
      for i, w in ipairs(b._filter) do b_pre[i] = w end
      b:merge(a)
      -- Every bit in b_pre should still be in b._filter
      local require_bit = require("bit")
      for i, w in ipairs(b._filter) do
        T.ok(require_bit.band(w, b_pre[i]) == b_pre[i])
      end
    end)

    T.it("b's filter contains a's bits after merge", function()
      local a = BC.new("A", {size=128, hash_count=3})
      local b = BC.new("B", {size=128, hash_count=3})
      a:tick()
      b:merge(a)
      -- Every bit in a's filter should be in b's filter
      local require_bit = require("bit")
      for i, w in ipairs(a._filter) do
        T.ok(require_bit.band(b._filter[i], w) == w)
      end
    end)
  end)

  T.describe("happened_before", function()
    T.it("A happened_before B after A sends to B", function()
      local a = BC.new("A", {size=128, hash_count=3})
      local b = BC.new("B", {size=128, hash_count=3})
      a:tick()  -- a: time=1
      b:merge(a)
      b:tick()  -- b: time=2, filter contains a's bits
      T.ok(BC.happened_before(a, b))
    end)

    T.it("B did NOT happen_before A (reverse false)", function()
      local a = BC.new("A", {size=128, hash_count=3})
      local b = BC.new("B", {size=128, hash_count=3})
      a:tick()
      b:merge(a)
      b:tick()
      T.ok(not BC.happened_before(b, a))
    end)

    T.it("happened_before is false for equal clocks", function()
      local a = BC.new("A", {size=64})
      a:tick()
      local b = a:clone()
      T.ok(not BC.happened_before(a, b))
      T.ok(not BC.happened_before(b, a))
    end)

    T.it("happened_before is transitive: A->B->C implies A hb C", function()
      local a = BC.new("A", {size=128, hash_count=3})
      local b = BC.new("B", {size=128, hash_count=3})
      local c_node = BC.new("C", {size=128, hash_count=3})

      a:tick()
      b:merge(a)
      b:tick()
      c_node:merge(b)
      c_node:tick()

      T.ok(BC.happened_before(a, b))
      T.ok(BC.happened_before(b, c_node))
      T.ok(BC.happened_before(a, c_node))
    end)

    T.it("fresh clocks with no events are not happened_before each other", function()
      local a = BC.new("A", {size=64})
      local b = BC.new("B", {size=64})
      T.ok(not BC.happened_before(a, b))
      T.ok(not BC.happened_before(b, a))
    end)
  end)

  T.describe("concurrent", function()
    T.it("two independent clocks are concurrent", function()
      local a = BC.new("A", {size=128, hash_count=3})
      local b = BC.new("B", {size=128, hash_count=3})
      a:tick()
      b:tick()
      T.ok(BC.concurrent(a, b))
    end)

    T.it("causally related clocks are not concurrent", function()
      local a = BC.new("A", {size=128, hash_count=3})
      local b = BC.new("B", {size=128, hash_count=3})
      a:tick()
      b:merge(a)
      b:tick()
      T.ok(not BC.concurrent(a, b))
    end)

    T.it("fresh clocks are concurrent (both time=0, empty filter)", function()
      local a = BC.new("A", {size=64})
      local b = BC.new("B", {size=64})
      -- Both have time=0 and empty filter: neither is strictly before
      T.ok(BC.concurrent(a, b))
    end)
  end)

  T.describe("serialize/deserialize", function()
    T.it("round-trips node_id, time, size, hash_count", function()
      local c = BC.new("node42", {size=64, hash_count=4})
      c:tick()
      c:tick()
      local tbl = c:serialize()
      local c2 = BC.deserialize(tbl)
      T.eq(c2._node_id, "node42")
      T.eq(c2:time(), 2)
      T.eq(c2._size, 64)
      T.eq(c2._hash_count, 4)
    end)

    T.it("round-trips filter bits", function()
      local c = BC.new("n", {size=64, hash_count=3})
      c:tick()
      c:tick()
      c:tick()
      local tbl = c:serialize()
      local c2 = BC.deserialize(tbl)
      for i, w in ipairs(c._filter) do
        T.eq(c2._filter[i], w)
      end
    end)

    T.it("deserialize returns nil,err for non-table", function()
      local c, err = BC.deserialize("not a table")
      T.eq(c, nil)
      T.ok(type(err) == "string")
    end)

    T.it("deserialize returns nil,err for missing node_id", function()
      local c, err = BC.deserialize({time=0, size=64, hash_count=3, filter={}})
      T.eq(c, nil)
      T.ok(type(err) == "string")
    end)
  end)

  T.describe("clone", function()
    T.it("clone has same state", function()
      local c = BC.new("X", {size=64, hash_count=3})
      c:tick()
      c:tick()
      local c2 = c:clone()
      T.eq(c2:time(), c:time())
      T.eq(c2._node_id, c._node_id)
      for i, w in ipairs(c._filter) do
        T.eq(c2._filter[i], w)
      end
    end)

    T.it("modifying clone does not affect original", function()
      local c = BC.new("X", {size=64, hash_count=3})
      c:tick()
      local c2 = c:clone()
      c2:tick()
      c2:tick()
      T.eq(c:time(), 1)
      T.eq(c2:time(), 3)
    end)

    T.it("modifying original does not affect clone", function()
      local c = BC.new("X", {size=64, hash_count=3})
      c:tick()
      local c2 = c:clone()
      c:tick()
      T.eq(c:time(), 2)
      T.eq(c2:time(), 1)
    end)
  end)

  T.describe("different node IDs", function()
    T.it("different node IDs produce different filter states after tick", function()
      local a = BC.new("alpha", {size=128, hash_count=3})
      local b = BC.new("beta",  {size=128, hash_count=3})
      a:tick()
      b:tick()
      -- Their filters should differ (with high probability for different keys)
      local same = true
      for i, w in ipairs(a._filter) do
        if w ~= b._filter[i] then same = false break end
      end
      T.ok(not same)
    end)
  end)

  T.describe("to_string", function()
    T.it("returns a string", function()
      local c = BC.new("mynode")
      T.ok(type(c:to_string()) == "string")
    end)

    T.it("contains node_id", function()
      local c = BC.new("mynode")
      T.ok(c:to_string():find("mynode") ~= nil)
    end)

    T.it("tostring works via __tostring", function()
      local c = BC.new("mynode")
      T.ok(type(tostring(c)) == "string")
    end)
  end)

end)
