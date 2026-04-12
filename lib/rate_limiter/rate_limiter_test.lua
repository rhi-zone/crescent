if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local RL = require("lib.rate_limiter")

T.describe("rate_limiter", function()

  T.describe("token_bucket", function()
    T.it("initial capacity allows n requests", function()
      local t = 0
      local clock = function() return t end
      local tb = RL.token_bucket({ capacity = 10, rate = 1, clock = clock })
      for i = 1, 10 do
        local ok, wait = tb:allow()
        T.ok(ok, "request " .. i .. " should be allowed")
        T.eq(wait, nil)
      end
    end)

    T.it("rate limits after capacity exhausted", function()
      local t = 0
      local clock = function() return t end
      local tb = RL.token_bucket({ capacity = 3, rate = 1, clock = clock })
      T.ok(tb:allow())
      T.ok(tb:allow())
      T.ok(tb:allow())
      local ok, wait = tb:allow()
      T.eq(ok, false)
      T.ok(wait ~= nil, "wait should be returned")
      T.ok(wait > 0, "wait should be positive")
    end)

    T.it("refills over time (injected clock)", function()
      local t = 0
      local clock = function() return t end
      local tb = RL.token_bucket({ capacity = 10, rate = 2, clock = clock })
      -- exhaust tokens
      for i = 1, 10 do tb:allow() end
      local ok1, _ = tb:allow()
      T.eq(ok1, false)
      -- advance 3 seconds => 6 new tokens
      t = 3
      for i = 1, 6 do
        local ok = tb:allow()
        T.ok(ok, "refilled token " .. i .. " should be allowed")
      end
      local ok2, _ = tb:allow()
      T.eq(ok2, false)
    end)

    T.it("allow(n) consumes n tokens", function()
      local t = 0
      local clock = function() return t end
      local tb = RL.token_bucket({ capacity = 10, rate = 1, clock = clock })
      local ok = tb:allow(5)
      T.ok(ok)
      T.eq(tb:tokens(), 5)
      local ok2 = tb:allow(5)
      T.ok(ok2)
      T.eq(tb:tokens(), 0)
    end)

    T.it("returns wait time when denied", function()
      local t = 0
      local clock = function() return t end
      local tb = RL.token_bucket({ capacity = 5, rate = 2, clock = clock })
      -- consume all tokens
      tb:allow(5)
      local ok, wait = tb:allow(4)
      T.eq(ok, false)
      -- need 4 tokens, have 0, rate=2 => wait = 4/2 = 2
      T.ok(math.abs(wait - 2.0) < 0.001, "wait should be ~2 seconds, got " .. tostring(wait))
    end)

    T.it("tokens() reports current count", function()
      local t = 0
      local clock = function() return t end
      local tb = RL.token_bucket({ capacity = 10, rate = 1, clock = clock })
      T.eq(tb:tokens(), 10)
      tb:allow(3)
      T.eq(tb:tokens(), 7)
    end)

    T.it("refill() can be called manually", function()
      local t = 0
      local clock = function() return t end
      local tb = RL.token_bucket({ capacity = 10, rate = 5, clock = clock })
      tb:allow(10)
      T.eq(tb:tokens(), 0)
      t = 2
      tb:refill()
      T.eq(tb:tokens(), 10) -- capped at capacity
    end)

    T.it("stats track allowed and denied counts", function()
      local t = 0
      local clock = function() return t end
      local tb = RL.token_bucket({ capacity = 3, rate = 1, clock = clock })
      tb:allow()
      tb:allow()
      tb:allow()
      tb:allow() -- denied
      tb:allow() -- denied
      local stats = tb:stats()
      T.eq(stats.allowed, 3)
      T.eq(stats.denied, 2)
      T.eq(stats.total, 5)
    end)
  end)

  T.describe("leaky_bucket", function()
    T.it("allows requests up to capacity", function()
      local t = 0
      local clock = function() return t end
      local lb = RL.leaky_bucket({ capacity = 5, rate = 1, clock = clock })
      for i = 1, 5 do
        T.ok(lb:allow(), "request " .. i .. " should be allowed")
      end
    end)

    T.it("limits output rate", function()
      local t = 0
      local clock = function() return t end
      local lb = RL.leaky_bucket({ capacity = 5, rate = 1, clock = clock })
      for i = 1, 5 do lb:allow() end
      local ok, wait = lb:allow()
      T.eq(ok, false)
      T.ok(wait ~= nil)
      T.ok(wait > 0)
    end)

    T.it("drains over time", function()
      local t = 0
      local clock = function() return t end
      local lb = RL.leaky_bucket({ capacity = 5, rate = 2, clock = clock })
      for i = 1, 5 do lb:allow() end
      T.eq(lb:size(), 5)
      t = 2
      -- 2 seconds * rate 2 = 4 drained
      T.ok(lb:allow(), "should be allowed after draining")
    end)

    T.it("size() reports queue depth", function()
      local t = 0
      local clock = function() return t end
      local lb = RL.leaky_bucket({ capacity = 10, rate = 1, clock = clock })
      lb:allow(3)
      T.eq(lb:size(), 3)
    end)

    T.it("returns wait time when denied", function()
      local t = 0
      local clock = function() return t end
      local lb = RL.leaky_bucket({ capacity = 4, rate = 2, clock = clock })
      for i = 1, 4 do lb:allow() end
      -- water=4, capacity=4, need 1 more => overflow by 1 => drain 1 at rate 2 => wait=0.5
      local ok, wait = lb:allow()
      T.eq(ok, false)
      T.ok(math.abs(wait - 0.5) < 0.001, "wait should be ~0.5, got " .. tostring(wait))
    end)

    T.it("stats track allowed and denied", function()
      local t = 0
      local clock = function() return t end
      local lb = RL.leaky_bucket({ capacity = 2, rate = 1, clock = clock })
      lb:allow()
      lb:allow()
      lb:allow() -- denied
      local stats = lb:stats()
      T.eq(stats.allowed, 2)
      T.eq(stats.denied, 1)
      T.eq(stats.total, 3)
    end)
  end)

  T.describe("fixed_window", function()
    T.it("allows up to limit", function()
      local t = 0
      local clock = function() return t end
      local fw = RL.fixed_window({ limit = 5, window = 60, clock = clock })
      for i = 1, 5 do
        T.ok(fw:allow(), "request " .. i .. " should be allowed")
      end
    end)

    T.it("denies after limit", function()
      local t = 0
      local clock = function() return t end
      local fw = RL.fixed_window({ limit = 3, window = 60, clock = clock })
      fw:allow()
      fw:allow()
      fw:allow()
      local ok, wait = fw:allow()
      T.eq(ok, false)
      T.ok(wait ~= nil)
      T.ok(wait > 0)
    end)

    T.it("resets on new window", function()
      local t = 0
      local clock = function() return t end
      local fw = RL.fixed_window({ limit = 3, window = 10, clock = clock })
      fw:allow()
      fw:allow()
      fw:allow()
      T.eq(fw:allow(), false)
      t = 11
      T.ok(fw:allow(), "should be allowed in new window")
    end)

    T.it("per-key limits are independent", function()
      local t = 0
      local clock = function() return t end
      local fw = RL.fixed_window({ limit = 2, window = 60, clock = clock })
      T.ok(fw:allow("user1"))
      T.ok(fw:allow("user1"))
      T.eq(fw:allow("user1"), false)
      -- user2 should still have full quota
      T.ok(fw:allow("user2"))
      T.ok(fw:allow("user2"))
      T.eq(fw:allow("user2"), false)
    end)

    T.it("reset() clears a specific key", function()
      local t = 0
      local clock = function() return t end
      local fw = RL.fixed_window({ limit = 2, window = 60, clock = clock })
      fw:allow("user1")
      fw:allow("user1")
      T.eq(fw:allow("user1"), false)
      fw:reset("user1")
      T.ok(fw:allow("user1"), "should be allowed after reset")
    end)

    T.it("count() returns current count for key", function()
      local t = 0
      local clock = function() return t end
      local fw = RL.fixed_window({ limit = 10, window = 60, clock = clock })
      fw:allow("k")
      fw:allow("k")
      fw:allow("k")
      T.eq(fw:count("k"), 3)
    end)

    T.it("default key works without explicit key", function()
      local t = 0
      local clock = function() return t end
      local fw = RL.fixed_window({ limit = 2, window = 60, clock = clock })
      T.ok(fw:allow())
      T.ok(fw:allow())
      T.eq(fw:allow(), false)
    end)

    T.it("stats track allowed and denied", function()
      local t = 0
      local clock = function() return t end
      local fw = RL.fixed_window({ limit = 2, window = 60, clock = clock })
      fw:allow()
      fw:allow()
      fw:allow() -- denied
      local stats = fw:stats()
      T.eq(stats.allowed, 2)
      T.eq(stats.denied, 1)
      T.eq(stats.total, 3)
    end)
  end)

  T.describe("sliding_window_log", function()
    T.it("precise limiting within window", function()
      local t = 0
      local clock = function() return t end
      local sw = RL.sliding_window_log({ limit = 5, window = 10, clock = clock })
      for i = 1, 5 do
        T.ok(sw:allow(), "request " .. i .. " should be allowed")
      end
      T.eq(sw:allow(), false)
    end)

    T.it("allows again after window slides", function()
      local t = 0
      local clock = function() return t end
      local sw = RL.sliding_window_log({ limit = 3, window = 10, clock = clock })
      sw:allow()
      sw:allow()
      sw:allow()
      T.eq(sw:allow(), false)
      -- advance past window
      t = 11
      T.ok(sw:allow(), "should be allowed after window expires")
    end)

    T.it("per-key limits are independent", function()
      local t = 0
      local clock = function() return t end
      local sw = RL.sliding_window_log({ limit = 2, window = 60, clock = clock })
      T.ok(sw:allow("a"))
      T.ok(sw:allow("a"))
      T.eq(sw:allow("a"), false)
      T.ok(sw:allow("b"))
      T.ok(sw:allow("b"))
      T.eq(sw:allow("b"), false)
    end)

    T.it("returns wait time when denied", function()
      local t = 0
      local clock = function() return t end
      local sw = RL.sliding_window_log({ limit = 1, window = 10, clock = clock })
      sw:allow() -- allowed at t=0
      local ok, wait = sw:allow()
      T.eq(ok, false)
      -- oldest entry is at t=0, window=10 => wait = 0+10-0 = 10
      T.ok(math.abs(wait - 10) < 0.001, "wait should be ~10, got " .. tostring(wait))
    end)

    T.it("stats track allowed and denied", function()
      local t = 0
      local clock = function() return t end
      local sw = RL.sliding_window_log({ limit = 2, window = 60, clock = clock })
      sw:allow()
      sw:allow()
      sw:allow() -- denied
      local stats = sw:stats()
      T.eq(stats.allowed, 2)
      T.eq(stats.denied, 1)
      T.eq(stats.total, 3)
    end)
  end)

  T.describe("sliding_window_counter", function()
    T.it("approximate limiting within window", function()
      local t = 0
      local clock = function() return t end
      local swc = RL.sliding_window_counter({ limit = 5, window = 10, clock = clock })
      for i = 1, 5 do
        T.ok(swc:allow(), "request " .. i .. " should be allowed")
      end
      T.eq(swc:allow(), false)
    end)

    T.it("allows again after full window passes", function()
      local t = 0
      local clock = function() return t end
      local swc = RL.sliding_window_counter({ limit = 3, window = 10, clock = clock })
      swc:allow()
      swc:allow()
      swc:allow()
      T.eq(swc:allow(), false)
      -- advance past 2 full windows => prev=0, curr=0
      t = 21
      T.ok(swc:allow(), "should be allowed after two windows")
    end)

    T.it("per-key limits are independent", function()
      local t = 0
      local clock = function() return t end
      local swc = RL.sliding_window_counter({ limit = 2, window = 60, clock = clock })
      T.ok(swc:allow("a"))
      T.ok(swc:allow("a"))
      T.eq(swc:allow("a"), false)
      T.ok(swc:allow("b"))
    end)

    T.it("stats track allowed and denied", function()
      local t = 0
      local clock = function() return t end
      local swc = RL.sliding_window_counter({ limit = 2, window = 60, clock = clock })
      swc:allow()
      swc:allow()
      swc:allow() -- denied
      local stats = swc:stats()
      T.eq(stats.allowed, 2)
      T.eq(stats.denied, 1)
      T.eq(stats.total, 3)
    end)
  end)

  T.describe("concurrent", function()
    T.it("acquire returns a release function", function()
      local cl = RL.concurrent({ limit = 5 })
      local release = cl:acquire()
      T.ok(release ~= nil, "acquire should return a release function")
      T.eq(type(release), "function")
    end)

    T.it("count tracks current concurrent requests", function()
      local cl = RL.concurrent({ limit = 5 })
      T.eq(cl:count(), 0)
      local r1 = cl:acquire()
      T.eq(cl:count(), 1)
      local r2 = cl:acquire()
      T.eq(cl:count(), 2)
      r1()
      T.eq(cl:count(), 1)
      r2()
      T.eq(cl:count(), 0)
    end)

    T.it("at limit returns nil", function()
      local cl = RL.concurrent({ limit = 2 })
      cl:acquire()
      cl:acquire()
      local r = cl:acquire()
      T.eq(r, nil, "should return nil at limit")
    end)

    T.it("release decrements counter", function()
      local cl = RL.concurrent({ limit = 2 })
      local r1 = cl:acquire()
      local r2 = cl:acquire()
      T.eq(cl:acquire(), nil)
      r1()
      T.ok(cl:acquire() ~= nil, "should allow after release")
    end)

    T.it("release is idempotent", function()
      local cl = RL.concurrent({ limit = 2 })
      local r = cl:acquire()
      T.eq(cl:count(), 1)
      r()
      T.eq(cl:count(), 0)
      r() -- second call should not decrement below 0
      T.eq(cl:count(), 0)
    end)

    T.it("stats track allowed and denied", function()
      local cl = RL.concurrent({ limit = 2 })
      cl:acquire()
      cl:acquire()
      cl:acquire() -- denied (at limit)
      local stats = cl:stats()
      T.eq(stats.allowed, 2)
      T.eq(stats.denied, 1)
      T.eq(stats.total, 3)
    end)
  end)

  T.describe("multi", function()
    T.it("allows when all limiters pass", function()
      local t = 0
      local clock = function() return t end
      local tb = RL.token_bucket({ capacity = 10, rate = 1, clock = clock })
      local fw = RL.fixed_window({ limit = 10, window = 60, clock = clock })
      local multi = RL.multi(tb, fw)
      local ok = multi:allow()
      T.ok(ok, "multi should allow when all pass")
    end)

    T.it("denies when any limiter fails", function()
      local t = 0
      local clock = function() return t end
      local tb = RL.token_bucket({ capacity = 1, rate = 1, clock = clock })
      local fw = RL.fixed_window({ limit = 100, window = 60, clock = clock })
      local multi = RL.multi(tb, fw)
      multi:allow() -- consume the 1 token
      local ok, wait = multi:allow()
      T.eq(ok, false)
      T.ok(wait ~= nil)
    end)

    T.it("first limiter denial stops evaluation", function()
      local t = 0
      local clock = function() return t end
      local tb = RL.token_bucket({ capacity = 1, rate = 1, clock = clock })
      local fw = RL.fixed_window({ limit = 100, window = 60, clock = clock })
      local multi = RL.multi(tb, fw)
      -- consume token bucket
      multi:allow()
      -- fw should not have been charged for the denied call
      local fw_count = fw:count()
      multi:allow() -- denied by tb, fw not called
      T.eq(fw:count(), fw_count, "fw should not be incremented when tb denies")
    end)

    T.it("works with a single limiter", function()
      local t = 0
      local clock = function() return t end
      local tb = RL.token_bucket({ capacity = 2, rate = 1, clock = clock })
      local multi = RL.multi(tb)
      T.ok(multi:allow())
      T.ok(multi:allow())
      T.eq(multi:allow(), false)
    end)
  end)

  T.describe("error handling", function()
    T.it("token_bucket rejects missing clock", function()
      local result, err = RL.token_bucket({ capacity = 10, rate = 1 })
      T.eq(result, nil)
      T.ok(err ~= nil)
    end)

    T.it("token_bucket rejects zero capacity", function()
      local result, err = RL.token_bucket({ capacity = 0, rate = 1, clock = os.time })
      T.eq(result, nil)
      T.ok(err ~= nil)
    end)

    T.it("fixed_window rejects missing clock", function()
      local result, err = RL.fixed_window({ limit = 10, window = 60 })
      T.eq(result, nil)
      T.ok(err ~= nil)
    end)

    T.it("concurrent rejects zero limit", function()
      local result, err = RL.concurrent({ limit = 0 })
      T.eq(result, nil)
      T.ok(err ~= nil)
    end)

    T.it("multi rejects empty limiter list", function()
      local result, err = RL.multi()
      T.eq(result, nil)
      T.ok(err ~= nil)
    end)
  end)

end)
