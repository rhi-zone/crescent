-- lib/pool_allocator/pool_allocator_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local P = require("lib.pool_allocator")

-- ---------------------------------------------------------------------------
-- pool
-- ---------------------------------------------------------------------------
T.describe("pool", function()

  T.it("acquire returns a fresh object", function()
    local pool = P.pool({
      create = function() return {x=0} end,
    })
    local obj = pool:acquire()
    T.ok(obj ~= nil, "object not nil")
    T.eq(type(obj), "table")
  end)

  T.it("release returns object to pool and increments size", function()
    local pool = P.pool({ create = function() return {x=0} end })
    local obj = pool:acquire()
    T.eq(pool:size(), 0, "pool empty after acquire")
    pool:release(obj)
    T.eq(pool:size(), 1, "pool has one after release")
  end)

  T.it("reset is called on release", function()
    local reset_called = false
    local pool = P.pool({
      create = function() return {x=5} end,
      reset  = function(o)
        reset_called = true
        o.x = 0
      end,
    })
    local obj = pool:acquire()
    obj.x = 99
    pool:release(obj)
    T.ok(reset_called, "reset was called")
    -- Acquire again — should get the reset object
    local obj2 = pool:acquire()
    T.eq(obj2.x, 0, "x was reset to 0")
  end)

  T.it("reuses released objects (pool hit)", function()
    local pool = P.pool({ create = function() return {} end })
    local obj = pool:acquire()
    pool:release(obj)
    local obj2 = pool:acquire()
    T.ok(obj == obj2, "same object returned from pool")
  end)

  T.it("grows beyond pre-allocated size when needed", function()
    local created = 0
    local pool = P.pool({
      size   = 2,
      create = function() created = created + 1; return {} end,
    })
    -- pre-allocated 2 objects
    T.eq(created, 2)
    local a = pool:acquire()
    local b = pool:acquire()
    local c = pool:acquire()  -- must create a new one
    T.eq(created, 3, "a third object was created")
    T.ok(c ~= nil)
    pool:release(a)
    pool:release(b)
    pool:release(c)
  end)

  T.it("in_use tracks acquired objects", function()
    local pool = P.pool({ create = function() return {} end })
    T.eq(pool:in_use(), 0)
    local a = pool:acquire()
    T.eq(pool:in_use(), 1)
    local b = pool:acquire()
    T.eq(pool:in_use(), 2)
    pool:release(a)
    T.eq(pool:in_use(), 1)
    pool:release(b)
    T.eq(pool:in_use(), 0)
  end)

  T.it("stats: hits, misses, created, acquired, released", function()
    local pool = P.pool({ create = function() return {} end })
    local a = pool:acquire()   -- miss (pool empty)
    pool:release(a)
    local b = pool:acquire()   -- hit
    pool:release(b)
    local s = pool:stats()
    T.eq(s.acquired,    2)
    T.eq(s.released,    2)
    T.eq(s.created,     1)
    T.eq(s.pool_hits,   1)
    T.eq(s.pool_misses, 1)
  end)

  T.it("stats with pre-allocation: no misses for first N acquires", function()
    local pool = P.pool({ size = 3, create = function() return {} end })
    local s0 = pool:stats()
    T.eq(s0.created, 3)
    local a = pool:acquire()
    local b = pool:acquire()
    local c = pool:acquire()
    local s = pool:stats()
    T.eq(s.pool_hits,   3)
    T.eq(s.pool_misses, 0)
    pool:release(a); pool:release(b); pool:release(c)
  end)

  T.it("pool:with auto-releases on success", function()
    local pool = P.pool({ create = function() return {} end })
    pool:with(function(obj)
      T.eq(pool:in_use(), 1)
      T.ok(obj ~= nil)
    end)
    T.eq(pool:in_use(), 0, "released after with")
    T.eq(pool:size(), 1)
  end)

  T.it("pool:with auto-releases on error", function()
    local pool = P.pool({ create = function() return {} end })
    local ok = pcall(function()
      pool:with(function()
        error("oops")
      end)
    end)
    T.ok(not ok, "error propagated")
    T.eq(pool:in_use(), 0, "still released despite error")
    T.eq(pool:size(), 1)
  end)

  T.it("acquire_batch returns N objects", function()
    local pool = P.pool({ create = function() return {} end })
    local objs = pool:acquire_batch(5)
    T.eq(#objs, 5)
    T.eq(pool:in_use(), 5)
    for i = 1, 5 do
      T.ok(objs[i] ~= nil)
    end
    pool:release_batch(objs)
    T.eq(pool:in_use(), 0)
    T.eq(pool:size(), 5)
  end)

  T.it("release_batch returns all objects to pool", function()
    local reset_count = 0
    local pool = P.pool({
      create = function() return {} end,
      reset  = function() reset_count = reset_count + 1 end,
    })
    local objs = pool:acquire_batch(4)
    pool:release_batch(objs)
    T.eq(reset_count, 4, "reset called for each object")
    T.eq(pool:size(), 4)
  end)

  T.it("release nil is a no-op", function()
    local pool = P.pool({ create = function() return {} end })
    pool:release(nil)  -- should not error
    T.eq(pool:size(), 0)
  end)

end)

-- ---------------------------------------------------------------------------
-- fixed_pool
-- ---------------------------------------------------------------------------
T.describe("fixed_pool", function()

  T.it("returns nil,err when exhausted", function()
    local fixed = P.fixed_pool({ size = 2, create = function() return {} end })
    local a = fixed:acquire()
    local b = fixed:acquire()
    T.ok(a ~= nil)
    T.ok(b ~= nil)
    local c, err = fixed:acquire()
    T.ok(c == nil, "nil on exhaustion")
    T.eq(err, "pool exhausted")
  end)

  T.it("released objects are reusable", function()
    local fixed = P.fixed_pool({
      size   = 1,
      create = function() return {v=0} end,
      reset  = function(o) o.v = 0 end,
    })
    local a = fixed:acquire()
    a.v = 42
    fixed:release(a)
    local b = fixed:acquire()
    T.ok(b ~= nil, "can acquire after release")
    T.eq(b.v, 0, "reset was applied")
  end)

  T.it("capacity is fixed", function()
    local fixed = P.fixed_pool({ size = 5, create = function() return {} end })
    T.eq(fixed:capacity(), 5)
  end)

  T.it("size decreases on acquire, increases on release", function()
    local fixed = P.fixed_pool({ size = 3, create = function() return {} end })
    T.eq(fixed:size(), 3)
    local a = fixed:acquire()
    T.eq(fixed:size(), 2)
    fixed:release(a)
    T.eq(fixed:size(), 3)
  end)

  T.it("reset called on release", function()
    local reset_calls = 0
    local fixed = P.fixed_pool({
      size   = 2,
      create = function() return {n=0} end,
      reset  = function(o) reset_calls = reset_calls + 1; o.n = 0 end,
    })
    local a = fixed:acquire()
    a.n = 7
    fixed:release(a)
    T.eq(reset_calls, 1)
    local b = fixed:acquire()
    T.eq(b.n, 0)
  end)

end)

-- ---------------------------------------------------------------------------
-- arena
-- ---------------------------------------------------------------------------
T.describe("arena", function()

  T.it("alloc returns increasing offsets", function()
    local arena = P.arena(256)
    local s1 = arena:alloc(16)
    local s2 = arena:alloc(32)
    T.eq(s1, 0)
    T.eq(s2, 16)
  end)

  T.it("used tracks allocated bytes", function()
    local arena = P.arena(256)
    T.eq(arena:used(), 0)
    arena:alloc(10)
    T.eq(arena:used(), 10)
    arena:alloc(20)
    T.eq(arena:used(), 30)
  end)

  T.it("remaining decreases with allocs", function()
    local arena = P.arena(100)
    T.eq(arena:remaining(), 100)
    arena:alloc(40)
    T.eq(arena:remaining(), 60)
  end)

  T.it("capacity is constant", function()
    local arena = P.arena(512)
    T.eq(arena:capacity(), 512)
    arena:alloc(100)
    T.eq(arena:capacity(), 512)
  end)

  T.it("reset clears all allocations", function()
    local arena = P.arena(256)
    arena:alloc(64)
    arena:alloc(64)
    T.eq(arena:used(), 128)
    arena:reset()
    T.eq(arena:used(), 0)
    T.eq(arena:remaining(), 256)
    -- Can allocate from scratch again
    local s = arena:alloc(16)
    T.eq(s, 0)
  end)

  T.it("out of space returns nil, err", function()
    local arena = P.arena(32)
    arena:alloc(24)
    local slot, err = arena:alloc(16)
    T.ok(slot == nil, "nil on overflow")
    T.eq(err, "arena out of space")
  end)

  T.it("exact-fit allocation succeeds", function()
    local arena = P.arena(64)
    local s = arena:alloc(64)
    T.eq(s, 0)
    T.eq(arena:remaining(), 0)
  end)

  T.it("zero-size alloc is valid", function()
    local arena = P.arena(64)
    local s = arena:alloc(0)
    T.eq(s, 0)
    T.eq(arena:used(), 0)
  end)

end)

-- ---------------------------------------------------------------------------
-- freelist
-- ---------------------------------------------------------------------------
T.describe("freelist", function()

  T.it("alloc returns ids in 1..n", function()
    local fl = P.freelist(5)
    for _ = 1, 5 do
      local id = fl:alloc()
      T.ok(id ~= nil)
      T.ok(id >= 1 and id <= 5)
    end
  end)

  T.it("in_use and available track allocations", function()
    local fl = P.freelist(4)
    T.eq(fl:in_use(), 0)
    T.eq(fl:available(), 4)
    fl:alloc()
    T.eq(fl:in_use(), 1)
    T.eq(fl:available(), 3)
    fl:alloc()
    T.eq(fl:in_use(), 2)
    T.eq(fl:available(), 2)
  end)

  T.it("capacity is constant", function()
    local fl = P.freelist(8)
    T.eq(fl:capacity(), 8)
    fl:alloc()
    T.eq(fl:capacity(), 8)
  end)

  T.it("exhaustion returns nil", function()
    local fl = P.freelist(2)
    fl:alloc()
    fl:alloc()
    local id = fl:alloc()
    T.ok(id == nil, "nil when exhausted")
  end)

  T.it("freed slots are reused", function()
    local fl = P.freelist(2)
    local a = fl:alloc()
    local b = fl:alloc()
    T.ok(fl:alloc() == nil)
    fl:free(a)
    T.eq(fl:available(), 1)
    local c = fl:alloc()
    T.ok(c ~= nil, "reused freed slot")
    T.eq(c, a)
  end)

  T.it("free nil is a no-op", function()
    local fl = P.freelist(3)
    fl:free(nil)
    T.eq(fl:available(), 3)
  end)

  T.it("full cycle alloc/free/alloc", function()
    local fl = P.freelist(3)
    local ids = {}
    for i = 1, 3 do ids[i] = fl:alloc() end
    T.eq(fl:available(), 0)
    for i = 1, 3 do fl:free(ids[i]) end
    T.eq(fl:available(), 3)
    for _ = 1, 3 do
      T.ok(fl:alloc() ~= nil)
    end
  end)

end)

-- ---------------------------------------------------------------------------
-- ring buffer
-- ---------------------------------------------------------------------------
T.describe("ring", function()

  T.it("push/pop maintains FIFO order", function()
    local rb = P.ring(8)
    rb:push(1)
    rb:push(2)
    rb:push(3)
    T.eq(rb:pop(), 1)
    T.eq(rb:pop(), 2)
    T.eq(rb:pop(), 3)
    T.ok(rb:pop() == nil)
  end)

  T.it("size tracks count", function()
    local rb = P.ring(4)
    T.eq(rb:size(), 0)
    rb:push("a")
    T.eq(rb:size(), 1)
    rb:push("b")
    T.eq(rb:size(), 2)
    rb:pop()
    T.eq(rb:size(), 1)
  end)

  T.it("capacity is constant", function()
    local rb = P.ring(5)
    T.eq(rb:capacity(), 5)
    rb:push(1)
    T.eq(rb:capacity(), 5)
  end)

  T.it("is_empty and is_full", function()
    local rb = P.ring(2)
    T.ok(rb:is_empty())
    T.ok(not rb:is_full())
    rb:push(1)
    rb:push(2)
    T.ok(rb:is_full())
    T.ok(not rb:is_empty())
  end)

  T.it("pop from empty returns nil", function()
    local rb = P.ring(4)
    T.ok(rb:pop() == nil)
  end)

  T.it("peek does not remove element", function()
    local rb = P.ring(4)
    rb:push(42)
    T.eq(rb:peek(), 42)
    T.eq(rb:size(), 1)
    T.eq(rb:pop(), 42)
    T.eq(rb:size(), 0)
  end)

  T.it("peek on empty returns nil", function()
    local rb = P.ring(4)
    T.ok(rb:peek() == nil)
  end)

  T.it("push when full overwrites oldest", function()
    local rb = P.ring(3)
    rb:push(1)
    rb:push(2)
    rb:push(3)
    -- Full: pushing 4 drops 1
    rb:push(4)
    T.eq(rb:size(), 3)
    T.eq(rb:pop(), 2)
    T.eq(rb:pop(), 3)
    T.eq(rb:pop(), 4)
  end)

  T.it("push when full repeatedly", function()
    local rb = P.ring(2)
    rb:push("a")
    rb:push("b")
    rb:push("c")  -- drops "a"
    rb:push("d")  -- drops "b"
    T.eq(rb:pop(), "c")
    T.eq(rb:pop(), "d")
  end)

  T.it("to_array returns snapshot in FIFO order", function()
    local rb = P.ring(4)
    rb:push(10)
    rb:push(20)
    rb:push(30)
    local arr = rb:to_array()
    T.eq(#arr, 3)
    T.eq(arr[1], 10)
    T.eq(arr[2], 20)
    T.eq(arr[3], 30)
  end)

  T.it("to_array after wrap-around", function()
    local rb = P.ring(3)
    rb:push(1)
    rb:push(2)
    rb:push(3)
    rb:pop()   -- remove 1, head wraps
    rb:push(4) -- now holds 2,3,4
    local arr = rb:to_array()
    T.eq(#arr, 3)
    T.eq(arr[1], 2)
    T.eq(arr[2], 3)
    T.eq(arr[3], 4)
  end)

  T.it("to_array on empty ring returns empty table", function()
    local rb = P.ring(4)
    local arr = rb:to_array()
    T.eq(#arr, 0)
  end)

  T.it("interleaved push/pop across wrap-around boundary", function()
    local rb = P.ring(4)
    for i = 1, 4 do rb:push(i) end
    T.eq(rb:pop(), 1)
    T.eq(rb:pop(), 2)
    rb:push(5)
    rb:push(6)
    T.eq(rb:pop(), 3)
    T.eq(rb:pop(), 4)
    T.eq(rb:pop(), 5)
    T.eq(rb:pop(), 6)
    T.ok(rb:is_empty())
  end)

end)
