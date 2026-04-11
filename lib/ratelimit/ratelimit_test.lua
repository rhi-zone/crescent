if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local rl = require("lib.ratelimit")

-- Helper: create a mock clock that can be advanced manually.
local function mock_clock(start)
  local t = start or 0
  local function clock() return t end
  local function advance(dt) t = t + dt end
  return clock, advance
end

-- ============================================================
-- Token Bucket
-- ============================================================

T.describe("token_bucket", function()
  T.it("allows requests within burst", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.token_bucket({ rate = 10, burst = 5, clock = clock })
    T.ok(limiter:allow())
    T.ok(limiter:allow())
    T.ok(limiter:allow())
    T.ok(limiter:allow())
    T.ok(limiter:allow())
  end)

  T.it("blocks when tokens exhausted", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.token_bucket({ rate = 10, burst = 3, clock = clock })
    T.ok(limiter:allow())
    T.ok(limiter:allow())
    T.ok(limiter:allow())
    T.eq(limiter:allow(), false)
  end)

  T.it("refills tokens over time", function()
    local clock, advance = mock_clock(0)
    local limiter = rl.token_bucket({ rate = 10, burst = 10, clock = clock })
    -- drain all
    for _ = 1, 10 do limiter:allow() end
    T.eq(limiter:allow(), false)
    -- advance 0.5s -> 5 tokens refilled
    advance(0.5)
    T.ok(limiter:allow())
    T.ok(limiter:allow())
    T.ok(limiter:allow())
    T.ok(limiter:allow())
    T.ok(limiter:allow())
    T.eq(limiter:allow(), false)
  end)

  T.it("does not exceed burst on refill", function()
    local clock, advance = mock_clock(0)
    local limiter = rl.token_bucket({ rate = 100, burst = 5, clock = clock })
    -- drain
    for _ = 1, 5 do limiter:allow() end
    -- advance a lot
    advance(100)
    -- should cap at burst=5
    local tokens = limiter:tokens()
    T.eq(tokens, 5)
  end)

  T.it("allows consuming multiple tokens", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.token_bucket({ rate = 10, burst = 10, clock = clock })
    T.ok(limiter:allow(5))
    T.ok(limiter:allow(5))
    T.eq(limiter:allow(1), false)
  end)

  T.it("rejects multi-token when insufficient", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.token_bucket({ rate = 10, burst = 10, clock = clock })
    T.ok(limiter:allow(7))
    T.eq(limiter:allow(5), false)
    T.ok(limiter:allow(3))
  end)

  T.it("tokens() returns current count", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.token_bucket({ rate = 10, burst = 10, clock = clock })
    T.eq(limiter:tokens(), 10)
    limiter:allow(3)
    T.eq(limiter:tokens(), 7)
  end)

  T.it("reset restores to burst", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.token_bucket({ rate = 10, burst = 10, clock = clock })
    for _ = 1, 10 do limiter:allow() end
    T.eq(limiter:tokens(), 0)
    limiter:reset()
    T.eq(limiter:tokens(), 10)
  end)

  T.it("returns nil,errmsg for invalid opts", function()
    local l, err = rl.token_bucket({ rate = 0, burst = 10, clock = os.time })
    T.eq(l, nil)
    T.ok(err)
    l, err = rl.token_bucket({ rate = 10, burst = 0, clock = os.time })
    T.eq(l, nil)
    T.ok(err)
    l, err = rl.token_bucket({ rate = 10, burst = 10 })
    T.eq(l, nil)
    T.ok(err)
  end)

  T.it("fractional refill works correctly", function()
    local clock, advance = mock_clock(0)
    local limiter = rl.token_bucket({ rate = 2, burst = 10, clock = clock })
    for _ = 1, 10 do limiter:allow() end
    advance(0.25) -- 0.5 tokens
    T.eq(limiter:allow(), false)
    advance(0.25) -- now 1.0 token total
    T.ok(limiter:allow())
    T.eq(limiter:allow(), false)
  end)

  T.it("zero elapsed time does not add tokens", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.token_bucket({ rate = 10, burst = 3, clock = clock })
    for _ = 1, 3 do limiter:allow() end
    T.eq(limiter:allow(), false)
    -- no advance
    T.eq(limiter:allow(), false)
  end)
end)

-- ============================================================
-- Sliding Window
-- ============================================================

T.describe("sliding_window", function()
  T.it("allows within limit", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.sliding_window({ limit = 5, window = 60, clock = clock })
    for _ = 1, 5 do T.ok(limiter:allow()) end
  end)

  T.it("blocks over limit", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.sliding_window({ limit = 3, window = 60, clock = clock })
    T.ok(limiter:allow())
    T.ok(limiter:allow())
    T.ok(limiter:allow())
    T.eq(limiter:allow(), false)
  end)

  T.it("window expiry allows new requests", function()
    local clock, advance = mock_clock(0)
    local limiter = rl.sliding_window({ limit = 2, window = 10, clock = clock })
    T.ok(limiter:allow())
    T.ok(limiter:allow())
    T.eq(limiter:allow(), false)
    -- advance past two full windows so prev_count is fully gone
    advance(20)
    T.ok(limiter:allow())
  end)

  T.it("count returns approximate request count", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.sliding_window({ limit = 100, window = 60, clock = clock })
    limiter:allow()
    limiter:allow()
    limiter:allow()
    local c = limiter:count()
    T.ok(c >= 3 and c <= 3.1, "count should be ~3, got " .. c)
  end)

  T.it("remaining decreases as requests come in", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.sliding_window({ limit = 10, window = 60, clock = clock })
    local r1 = limiter:remaining()
    limiter:allow()
    limiter:allow()
    local r2 = limiter:remaining()
    T.ok(r2 < r1, "remaining should decrease")
  end)

  T.it("reset clears all counts", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.sliding_window({ limit = 3, window = 60, clock = clock })
    limiter:allow()
    limiter:allow()
    limiter:allow()
    T.eq(limiter:allow(), false)
    limiter:reset()
    T.ok(limiter:allow())
  end)

  T.it("sliding window blends previous and current", function()
    local clock, advance = mock_clock(0)
    local limiter = rl.sliding_window({ limit = 10, window = 10, clock = clock })
    -- fill to 8 in first window
    for _ = 1, 8 do limiter:allow() end
    -- move to second window, halfway through
    advance(15) -- 15s into it: window_start advances to 10, now at 15 => fraction=0.5
    -- effective = curr(0) + prev(8) * (1-0.5) = 4
    -- so we should be able to add 6 more
    for _ = 1, 6 do T.ok(limiter:allow()) end
    T.eq(limiter:allow(), false)
  end)

  T.it("returns nil,errmsg for invalid opts", function()
    local l, err = rl.sliding_window({ limit = 0, window = 60, clock = os.time })
    T.eq(l, nil)
    T.ok(err)
    l, err = rl.sliding_window({ limit = 10, window = 0, clock = os.time })
    T.eq(l, nil)
    T.ok(err)
  end)

  T.it("far future jump resets both windows", function()
    local clock, advance = mock_clock(0)
    local limiter = rl.sliding_window({ limit = 5, window = 10, clock = clock })
    for _ = 1, 5 do limiter:allow() end
    T.eq(limiter:allow(), false)
    advance(1000) -- way past both windows
    T.ok(limiter:allow())
  end)
end)

-- ============================================================
-- Fixed Window
-- ============================================================

T.describe("fixed_window", function()
  T.it("allows within limit", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.fixed_window({ limit = 5, window = 60, clock = clock })
    for _ = 1, 5 do T.ok(limiter:allow()) end
  end)

  T.it("blocks over limit", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.fixed_window({ limit = 3, window = 60, clock = clock })
    T.ok(limiter:allow())
    T.ok(limiter:allow())
    T.ok(limiter:allow())
    T.eq(limiter:allow(), false)
  end)

  T.it("resets at window boundary", function()
    local clock, advance = mock_clock(0)
    local limiter = rl.fixed_window({ limit = 2, window = 10, clock = clock })
    T.ok(limiter:allow())
    T.ok(limiter:allow())
    T.eq(limiter:allow(), false)
    advance(10)
    T.ok(limiter:allow())
  end)

  T.it("count tracks requests in current window", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.fixed_window({ limit = 10, window = 60, clock = clock })
    T.eq(limiter:count(), 0)
    limiter:allow()
    limiter:allow()
    T.eq(limiter:count(), 2)
  end)

  T.it("remaining shows available capacity", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.fixed_window({ limit = 5, window = 60, clock = clock })
    T.eq(limiter:remaining(), 5)
    limiter:allow()
    T.eq(limiter:remaining(), 4)
  end)

  T.it("reset clears counter", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.fixed_window({ limit = 2, window = 60, clock = clock })
    limiter:allow()
    limiter:allow()
    T.eq(limiter:allow(), false)
    limiter:reset()
    T.ok(limiter:allow())
  end)

  T.it("multiple windows work correctly", function()
    local clock, advance = mock_clock(0)
    local limiter = rl.fixed_window({ limit = 2, window = 5, clock = clock })
    T.ok(limiter:allow())
    T.ok(limiter:allow())
    T.eq(limiter:allow(), false)
    advance(5)
    T.ok(limiter:allow())
    T.ok(limiter:allow())
    T.eq(limiter:allow(), false)
    advance(5)
    T.ok(limiter:allow())
  end)

  T.it("returns nil,errmsg for invalid opts", function()
    local l, err = rl.fixed_window({ limit = -1, window = 60, clock = os.time })
    T.eq(l, nil)
    T.ok(err)
  end)

  T.it("mid-window time does not reset", function()
    local clock, advance = mock_clock(0)
    local limiter = rl.fixed_window({ limit = 3, window = 10, clock = clock })
    limiter:allow()
    limiter:allow()
    advance(5) -- mid-window
    limiter:allow()
    T.eq(limiter:allow(), false) -- still same window
  end)

  T.it("skipping multiple windows works", function()
    local clock, advance = mock_clock(0)
    local limiter = rl.fixed_window({ limit = 2, window = 10, clock = clock })
    limiter:allow()
    limiter:allow()
    advance(35) -- skip 3+ windows
    T.ok(limiter:allow())
    T.eq(limiter:count(), 1)
  end)
end)

-- ============================================================
-- Leaky Bucket
-- ============================================================

T.describe("leaky_bucket", function()
  T.it("allows within capacity", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.leaky_bucket({ rate = 10, capacity = 5, clock = clock })
    for _ = 1, 5 do T.ok(limiter:allow()) end
  end)

  T.it("blocks when full", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.leaky_bucket({ rate = 10, capacity = 3, clock = clock })
    T.ok(limiter:allow())
    T.ok(limiter:allow())
    T.ok(limiter:allow())
    T.eq(limiter:allow(), false)
  end)

  T.it("drains over time", function()
    local clock, advance = mock_clock(0)
    local limiter = rl.leaky_bucket({ rate = 10, capacity = 5, clock = clock })
    for _ = 1, 5 do limiter:allow() end
    T.eq(limiter:allow(), false)
    advance(0.5) -- drains 5
    T.ok(limiter:allow())
  end)

  T.it("allow with N tokens", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.leaky_bucket({ rate = 10, capacity = 10, clock = clock })
    T.ok(limiter:allow(5))
    T.ok(limiter:allow(5))
    T.eq(limiter:allow(1), false)
  end)

  T.it("level returns current fill", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.leaky_bucket({ rate = 10, capacity = 10, clock = clock })
    T.eq(limiter:level(), 0)
    limiter:allow(3)
    T.eq(limiter:level(), 3)
  end)

  T.it("remaining shows available space", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.leaky_bucket({ rate = 10, capacity = 10, clock = clock })
    T.eq(limiter:remaining(), 10)
    limiter:allow(4)
    T.eq(limiter:remaining(), 6)
  end)

  T.it("reset empties bucket", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.leaky_bucket({ rate = 10, capacity = 5, clock = clock })
    for _ = 1, 5 do limiter:allow() end
    T.eq(limiter:allow(), false)
    limiter:reset()
    T.ok(limiter:allow())
  end)

  T.it("water does not go below zero", function()
    local clock, advance = mock_clock(0)
    local limiter = rl.leaky_bucket({ rate = 10, capacity = 10, clock = clock })
    limiter:allow(2)
    advance(100) -- drains way more than 2
    T.eq(limiter:level(), 0)
    T.ok(limiter:allow(10)) -- full capacity available
  end)

  T.it("returns nil,errmsg for invalid opts", function()
    local l, err = rl.leaky_bucket({ rate = 0, capacity = 10, clock = os.time })
    T.eq(l, nil)
    T.ok(err)
    l, err = rl.leaky_bucket({ rate = 10, capacity = 0, clock = os.time })
    T.eq(l, nil)
    T.ok(err)
  end)

  T.it("partial drain allows partial refill", function()
    local clock, advance = mock_clock(0)
    local limiter = rl.leaky_bucket({ rate = 2, capacity = 10, clock = clock })
    limiter:allow(10) -- full
    T.eq(limiter:allow(), false)
    advance(1) -- drains 2
    T.ok(limiter:allow())
    T.ok(limiter:allow())
    T.eq(limiter:allow(), false)
  end)
end)

-- ============================================================
-- Keyed Rate Limiter
-- ============================================================

T.describe("keyed", function()
  T.it("independent keys", function()
    local clock, _ = mock_clock(0)
    local keyed = rl.keyed(rl.token_bucket, { rate = 10, burst = 2, clock = clock })
    T.ok(keyed:allow("a"))
    T.ok(keyed:allow("a"))
    T.eq(keyed:allow("a"), false)
    -- b is independent
    T.ok(keyed:allow("b"))
    T.ok(keyed:allow("b"))
    T.eq(keyed:allow("b"), false)
  end)

  T.it("get returns the limiter for a key", function()
    local clock, _ = mock_clock(0)
    local keyed = rl.keyed(rl.token_bucket, { rate = 10, burst = 5, clock = clock })
    keyed:allow("x")
    local limiter = keyed:get("x")
    T.ok(limiter)
    T.eq(limiter:tokens(), 4)
  end)

  T.it("reset single key", function()
    local clock, _ = mock_clock(0)
    local keyed = rl.keyed(rl.token_bucket, { rate = 10, burst = 2, clock = clock })
    keyed:allow("a")
    keyed:allow("a")
    T.eq(keyed:allow("a"), false)
    keyed:reset("a")
    T.ok(keyed:allow("a"))
  end)

  T.it("reset all keys", function()
    local clock, _ = mock_clock(0)
    local keyed = rl.keyed(rl.token_bucket, { rate = 10, burst = 1, clock = clock })
    keyed:allow("a")
    keyed:allow("b")
    T.eq(keyed:allow("a"), false)
    T.eq(keyed:allow("b"), false)
    keyed:reset()
    T.ok(keyed:allow("a"))
    T.ok(keyed:allow("b"))
  end)

  T.it("works with fixed_window", function()
    local clock, advance = mock_clock(0)
    local keyed = rl.keyed(rl.fixed_window, { limit = 2, window = 10, clock = clock })
    T.ok(keyed:allow("user:1"))
    T.ok(keyed:allow("user:1"))
    T.eq(keyed:allow("user:1"), false)
    T.ok(keyed:allow("user:2"))
    advance(10)
    T.ok(keyed:allow("user:1"))
  end)

  T.it("works with leaky_bucket", function()
    local clock, advance = mock_clock(0)
    local keyed = rl.keyed(rl.leaky_bucket, { rate = 10, capacity = 2, clock = clock })
    T.ok(keyed:allow("k"))
    T.ok(keyed:allow("k"))
    T.eq(keyed:allow("k"), false)
    advance(0.2) -- drain 2
    T.ok(keyed:allow("k"))
  end)

  T.it("works with sliding_window", function()
    local clock, advance = mock_clock(0)
    local keyed = rl.keyed(rl.sliding_window, { limit = 2, window = 10, clock = clock })
    T.ok(keyed:allow("s"))
    T.ok(keyed:allow("s"))
    T.eq(keyed:allow("s"), false)
    advance(20) -- past both windows
    T.ok(keyed:allow("s"))
  end)

  T.it("returns nil,errmsg for invalid opts", function()
    local l, err = rl.keyed(nil, {})
    T.eq(l, nil)
    T.ok(err)
    l, err = rl.keyed(rl.token_bucket, nil)
    T.eq(l, nil)
    T.ok(err)
  end)

  T.it("many keys stay independent", function()
    local clock, _ = mock_clock(0)
    local keyed = rl.keyed(rl.token_bucket, { rate = 10, burst = 1, clock = clock })
    for i = 1, 20 do
      T.ok(keyed:allow("user:" .. i))
    end
    for i = 1, 20 do
      T.eq(keyed:allow("user:" .. i), false)
    end
  end)
end)

-- ============================================================
-- Edge cases
-- ============================================================

T.describe("edge_cases", function()
  T.it("token_bucket burst=1 allows exactly one", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.token_bucket({ rate = 1, burst = 1, clock = clock })
    T.ok(limiter:allow())
    T.eq(limiter:allow(), false)
  end)

  T.it("fixed_window limit=1", function()
    local clock, advance = mock_clock(0)
    local limiter = rl.fixed_window({ limit = 1, window = 1, clock = clock })
    T.ok(limiter:allow())
    T.eq(limiter:allow(), false)
    advance(1)
    T.ok(limiter:allow())
    T.eq(limiter:allow(), false)
  end)

  T.it("leaky_bucket capacity=1", function()
    local clock, advance = mock_clock(0)
    local limiter = rl.leaky_bucket({ rate = 1, capacity = 1, clock = clock })
    T.ok(limiter:allow())
    T.eq(limiter:allow(), false)
    advance(1)
    T.ok(limiter:allow())
  end)

  T.it("token_bucket high rate refills fast", function()
    local clock, advance = mock_clock(0)
    local limiter = rl.token_bucket({ rate = 1000, burst = 1000, clock = clock })
    for _ = 1, 1000 do limiter:allow() end
    T.eq(limiter:allow(), false)
    advance(0.001) -- 1ms -> 1 token
    T.ok(limiter:allow())
  end)

  T.it("leaky_bucket rejects exactly at capacity+1", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.leaky_bucket({ rate = 1, capacity = 5, clock = clock })
    for _ = 1, 5 do T.ok(limiter:allow()) end
    T.eq(limiter:allow(), false)
  end)

  T.it("sliding_window limit=1", function()
    local clock, advance = mock_clock(0)
    local limiter = rl.sliding_window({ limit = 1, window = 10, clock = clock })
    T.ok(limiter:allow())
    T.eq(limiter:allow(), false)
    advance(20) -- fully clear
    T.ok(limiter:allow())
  end)

  T.it("token_bucket allow(0) always succeeds", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.token_bucket({ rate = 1, burst = 1, clock = clock })
    limiter:allow() -- consume the 1 token
    T.ok(limiter:allow(0)) -- 0 tokens requested
  end)

  T.it("leaky_bucket allow(0) always succeeds", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.leaky_bucket({ rate = 1, capacity = 1, clock = clock })
    limiter:allow() -- fill to capacity
    T.ok(limiter:allow(0))
  end)

  T.it("token_bucket negative rate rejected", function()
    local l, err = rl.token_bucket({ rate = -5, burst = 10, clock = os.time })
    T.eq(l, nil)
    T.ok(err)
  end)

  T.it("leaky_bucket negative rate rejected", function()
    local l, err = rl.leaky_bucket({ rate = -1, capacity = 10, clock = os.time })
    T.eq(l, nil)
    T.ok(err)
  end)

  T.it("fixed_window negative limit rejected", function()
    local l, err = rl.fixed_window({ limit = -1, window = 10, clock = os.time })
    T.eq(l, nil)
    T.ok(err)
  end)

  T.it("sliding_window negative limit rejected", function()
    local l, err = rl.sliding_window({ limit = -1, window = 10, clock = os.time })
    T.eq(l, nil)
    T.ok(err)
  end)

  T.it("token_bucket rapid drain and refill cycle", function()
    local clock, advance = mock_clock(0)
    local limiter = rl.token_bucket({ rate = 5, burst = 5, clock = clock })
    for cycle = 1, 3 do
      for _ = 1, 5 do T.ok(limiter:allow(), "cycle " .. cycle) end
      T.eq(limiter:allow(), false)
      advance(1) -- refill 5 tokens
    end
  end)

  T.it("leaky_bucket steady state: 1 request per drain interval", function()
    local clock, advance = mock_clock(0)
    local limiter = rl.leaky_bucket({ rate = 1, capacity = 5, clock = clock })
    -- fill to capacity
    for _ = 1, 5 do limiter:allow() end
    -- at steady state, one drain per second = one allow per second
    for _ = 1, 5 do
      advance(1)
      T.ok(limiter:allow())
      T.eq(limiter:allow(), false)
    end
  end)

  T.it("fixed_window count resets across windows", function()
    local clock, advance = mock_clock(0)
    local limiter = rl.fixed_window({ limit = 10, window = 5, clock = clock })
    limiter:allow()
    limiter:allow()
    T.eq(limiter:count(), 2)
    advance(5)
    T.eq(limiter:count(), 0)
  end)

  T.it("sliding_window remaining never negative", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.sliding_window({ limit = 2, window = 10, clock = clock })
    limiter:allow()
    limiter:allow()
    T.ok(limiter:remaining() >= 0)
  end)

  T.it("fixed_window remaining never negative", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.fixed_window({ limit = 2, window = 10, clock = clock })
    limiter:allow()
    limiter:allow()
    T.ok(limiter:remaining() >= 0)
  end)

  T.it("leaky_bucket remaining never negative", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.leaky_bucket({ rate = 1, capacity = 2, clock = clock })
    limiter:allow()
    limiter:allow()
    T.ok(limiter:remaining() >= 0)
  end)

  T.it("keyed creates new limiter on first access", function()
    local clock, _ = mock_clock(0)
    local keyed = rl.keyed(rl.token_bucket, { rate = 10, burst = 5, clock = clock })
    local limiter = keyed:get("new_key")
    T.ok(limiter)
    T.eq(limiter:tokens(), 5)
  end)

  T.it("keyed reset nonexistent key is safe", function()
    local clock, _ = mock_clock(0)
    local keyed = rl.keyed(rl.token_bucket, { rate = 10, burst = 5, clock = clock })
    keyed:reset("nonexistent") -- should not error
    T.ok(true)
  end)

  T.it("token_bucket large burst value", function()
    local clock, _ = mock_clock(0)
    local limiter = rl.token_bucket({ rate = 1, burst = 1000000, clock = clock })
    for _ = 1, 100 do T.ok(limiter:allow()) end
    T.ok(limiter:tokens() > 999000)
  end)
end)
