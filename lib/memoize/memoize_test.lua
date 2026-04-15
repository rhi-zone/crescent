-- lib/memoize/memoize_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local memo = require("lib.memoize")

-- ---------------------------------------------------------------------------
T.describe("memoize: basic", function()
  T.it("fn called once for same args", function()
    local calls = 0
    local f = memo.memoize(function(x) calls = calls + 1; return x * 2 end)
    T.eq(f(3), 6)
    T.eq(f(3), 6)
    T.eq(calls, 1)
  end)

  T.it("fn called for different args", function()
    local calls = 0
    local f = memo.memoize(function(x) calls = calls + 1; return x + 1 end)
    T.eq(f(1), 2)
    T.eq(f(2), 3)
    T.eq(calls, 2)
  end)

  T.it("multiple args produce distinct keys", function()
    local calls = 0
    local f = memo.memoize(function(a, b) calls = calls + 1; return a .. b end)
    T.eq(f("x", "y"), "xy")
    T.eq(f("xy", ""),  "xy")
    T.eq(calls, 2)  -- distinct keys
  end)

  T.it("nil return values cached correctly", function()
    local calls = 0
    local f = memo.memoize(function() calls = calls + 1 end)
    local r1 = f(1)
    local r2 = f(1)
    T.eq(r1, nil)
    T.eq(r2, nil)
    T.eq(calls, 1)
  end)

  T.it("different argument types keyed separately", function()
    local calls = 0
    local f = memo.memoize(function(x) calls = calls + 1; return x end)
    f(1)
    f("1")
    -- tostring(1) == "1" so these share a key — that's correct per spec
    -- The spec says numbers use direct key; strings use direct key.
    -- When single-arg, key = the value itself (number vs string differ as table keys).
    T.eq(calls, 2)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("memoize: fibonacci", function()
  T.it("recursive memoize produces correct results", function()
    local fib
    fib = memo.memoize(function(n)
      if n <= 1 then return n end
      return fib(n-1) + fib(n-2)
    end)
    T.eq(fib(0),  0)
    T.eq(fib(1),  1)
    T.eq(fib(10), 55)
    T.eq(fib(20), 6765)
  end)

  T.it("fibonacci calls fn minimal times", function()
    local calls = 0
    local fib
    fib = memo.memoize(function(n)
      calls = calls + 1
      if n <= 1 then return n end
      return fib(n-1) + fib(n-2)
    end)
    fib(10)
    T.eq(calls, 11)  -- 0..10 each computed once
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("memoize: max_size LRU", function()
  T.it("oldest entry evicted when full", function()
    local calls = 0
    local f = memo.memoize(function(x) calls = calls + 1; return x end, { max_size = 3 })
    f(1); f(2); f(3)  -- fill cache
    T.eq(calls, 3)
    f(4)  -- evicts 1 (LRU)
    T.eq(calls, 4)
    f(1)  -- must recompute (was evicted)
    T.eq(calls, 5)
    f(2)  -- still in cache (was promoted by f(2) access... wait, 2 was accessed earlier)
    -- After f(1) f(2) f(3) f(4): LRU order (MRU→LRU): 4,3,2 (1 evicted)
    -- f(1) misses → recomputes, cache now: 1,4,3 (2 evicted)
    -- f(2) should miss
    T.eq(calls, 6)
  end)

  T.it("recently used entry not evicted", function()
    local f = memo.memoize(function(x) return x end, { max_size = 2 })
    f(1); f(2)
    f(1)  -- promote 1 to MRU
    f(3)  -- evicts 2 (now LRU), not 1
    local calls = 0
    local g = memo.memoize(function(x) calls = calls + 1; return x end, { max_size = 2 })
    g(1); g(2); g(1); g(3)
    g(1)  -- should still be cached
    T.eq(calls, 3)  -- 1, 2, 3 each computed once
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("memoize: TTL", function()
  T.it("entry valid before TTL expires", function()
    local calls = 0
    local t = 0
    local f = memo.memoize(
      function(x) calls = calls + 1; return x end,
      { ttl = 10, clock_fn = function() return t end }
    )
    f(1)
    t = 5
    f(1)
    T.eq(calls, 1)
  end)

  T.it("entry expires after ttl", function()
    local calls = 0
    local t = 0
    local f = memo.memoize(
      function(x) calls = calls + 1; return x end,
      { ttl = 10, clock_fn = function() return t end }
    )
    f(1)
    T.eq(calls, 1)
    t = 11  -- past expiry
    f(1)
    T.eq(calls, 2)
  end)

  T.it("expired entry recomputed and re-cached", function()
    local calls = 0
    local t = 0
    local f = memo.memoize(
      function(x) calls = calls + 1; return x * 10 end,
      { ttl = 5, clock_fn = function() return t end }
    )
    T.eq(f(3), 30)
    t = 6
    T.eq(f(3), 30)  -- recomputed, same result
    T.eq(calls, 2)
    t = 7
    T.eq(f(3), 30)  -- now cached again (expires at 6+5=11)
    T.eq(calls, 2)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("memoize: custom key function", function()
  T.it("custom key function used correctly", function()
    local calls = 0
    local f = memo.memoize(
      function(a, b) calls = calls + 1; return a + b end,
      { key = function(a, b) return tostring(a) .. "+" .. tostring(b) end }
    )
    T.eq(f(1, 2), 3)
    T.eq(f(1, 2), 3)
    T.eq(calls, 1)
    T.eq(f(2, 1), 3)
    T.eq(calls, 2)  -- different key
  end)

  T.it("custom key can collapse different args to same key", function()
    local calls = 0
    local f = memo.memoize(
      function(a, b) calls = calls + 1; return a + b end,
      { key = function(a, b) return tostring(a + b) end }  -- sum as key
    )
    f(1, 2)
    f(2, 1)  -- same key "3" as above — should hit cache
    T.eq(calls, 1)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("memoize: stats", function()
  T.it("hits and misses counted correctly", function()
    local f = memo.memoize(function(x) return x end)
    f(1); f(2); f(1); f(1); f(3)
    local hits, misses = f:stats()
    T.eq(hits,   2)  -- f(1) called twice after initial miss
    T.eq(misses, 3)  -- f(1), f(2), f(3) each missed once
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("memoize: clear", function()
  T.it("cache emptied, fn called again after clear", function()
    local calls = 0
    local f = memo.memoize(function(x) calls = calls + 1; return x end)
    f(1); f(2)
    T.eq(calls, 2)
    f:clear()
    f(1); f(2)
    T.eq(calls, 4)
  end)

  T.it("stats reset on clear", function()
    local f = memo.memoize(function(x) return x end)
    f(1); f(1)
    f:clear()
    local hits, misses = f:stats()
    T.eq(hits,   0)
    T.eq(misses, 0)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("memoize: invalidate", function()
  T.it("specific entry removed", function()
    local calls = 0
    local f = memo.memoize(function(x) calls = calls + 1; return x end)
    f(1); f(2)
    T.eq(calls, 2)
    f:invalidate(1)
    f(1)  -- must recompute
    T.eq(calls, 3)
    f(2)  -- still cached
    T.eq(calls, 3)
  end)

  T.it("invalidate with multi-arg key", function()
    local calls = 0
    local f = memo.memoize(function(a, b) calls = calls + 1; return a + b end)
    f(1, 2); f(3, 4)
    T.eq(calls, 2)
    f:invalidate(1, 2)
    f(1, 2)
    T.eq(calls, 3)
    f(3, 4)
    T.eq(calls, 3)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("thunk", function()
  T.it("called once regardless of call count", function()
    local calls = 0
    local t = memo.thunk(function() calls = calls + 1; return 42 end)
    T.eq(t(), 42)
    T.eq(t(), 42)
    T.eq(t(), 42)
    T.eq(calls, 1)
  end)

  T.it("nil return cached", function()
    local calls = 0
    local t = memo.thunk(function() calls = calls + 1 end)
    T.eq(t(), nil)
    T.eq(t(), nil)
    T.eq(calls, 1)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("once", function()
  T.it("returns same value, fn called only once", function()
    local calls = 0
    local f = memo.once(function() calls = calls + 1; return 99 end)
    T.eq(f(), 99)
    T.eq(f(), 99)
    T.eq(f(), 99)
    T.eq(calls, 1)
  end)

  T.it("nil return cached", function()
    local calls = 0
    local f = memo.once(function() calls = calls + 1 end)
    f(); f()
    T.eq(calls, 1)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("weak memoize", function()
  T.it("behaves like memoize for alive values", function()
    local calls = 0
    local f = memo.weak(function(x) calls = calls + 1; return { x = x } end)
    local r1 = f(1)
    local r2 = f(1)
    -- r1 and r2 should be the same table (alive in cache)
    T.eq(r1, r2)
    T.eq(calls, 1)
  end)

  T.it("different args produce different results", function()
    local calls = 0
    local f = memo.weak(function(x) calls = calls + 1; return x * 3 end)
    T.eq(f(2), 6)
    T.eq(f(3), 9)
    T.eq(calls, 2)
  end)
end)
