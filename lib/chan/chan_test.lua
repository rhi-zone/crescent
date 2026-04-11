if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local M = require("lib.chan")

-- ── tier ──────────────────────────────────────────────────────────────────────

T.describe("meta", function()
  T.it("_tier is pure", function()
    T.eq(M._tier, "pure")
  end)
end)

-- ── buffered channel ──────────────────────────────────────────────────────────

T.describe("buffered channel", function()

  T.it("basic send and recv", function()
    M.run(function()
      local ch = M.new(1)
      local ok = ch:send(42)
      T.eq(ok, true)
      local v, ok2 = ch:recv()
      T.eq(v, 42)
      T.eq(ok2, true)
    end)
  end)

  T.it("multiple items FIFO", function()
    M.run(function()
      local ch = M.new(3)
      ch:send(1); ch:send(2); ch:send(3)
      T.eq(ch:recv(), 1)
      T.eq(ch:recv(), 2)
      T.eq(ch:recv(), 3)
    end)
  end)

  T.it("len and cap", function()
    M.run(function()
      local ch = M.new(4)
      T.eq(ch:cap(), 4)
      T.eq(ch:len(), 0)
      ch:send("a"); ch:send("b")
      T.eq(ch:len(), 2)
      ch:recv()
      T.eq(ch:len(), 1)
    end)
  end)

  T.it("is_closed starts false", function()
    local ch = M.new(2)
    T.eq(ch:is_closed(), false)
  end)

  T.it("producer-consumer goroutines with blocking send", function()
    -- channel capacity 1; producer sends 3 values, consumer reads 3
    local results = {}
    M.run(function()
      local ch = M.new(1)
      M.go(function()
        ch:send(10); ch:send(20); ch:send(30)
      end)
      M.go(function()
        results[1] = ch:recv()
        results[2] = ch:recv()
        results[3] = ch:recv()
      end)
    end)
    T.eq(results[1], 10)
    T.eq(results[2], 20)
    T.eq(results[3], 30)
  end)

  T.it("send blocks when full, recv unblocks sender", function()
    M.run(function()
      local ch = M.new(1)
      local order = {}
      M.go(function()
        ch:send("first")         -- fits in buffer
        order[#order+1] = "send1"
        ch:send("second")        -- will block (buffer full)
        order[#order+1] = "send2"
      end)
      M.go(function()
        order[#order+1] = "recv1"
        local v1 = ch:recv()     -- frees space, wakes sender
        order[#order+1] = "recv2"
        local v2 = ch:recv()
        T.eq(v1, "first")
        T.eq(v2, "second")
      end)
    end)
  end)

end)

-- ── unbuffered (rendezvous) ───────────────────────────────────────────────────

T.describe("unbuffered channel", function()

  T.it("cap is 0", function()
    local ch = M.new(0)
    T.eq(ch:cap(), 0)
  end)

  T.it("M.new() defaults to cap 0", function()
    local ch = M.new()
    T.eq(ch:cap(), 0)
  end)

  T.it("producer-consumer rendezvous", function()
    local got
    M.run(function()
      local ch = M.new(0)
      M.go(function() ch:send(99) end)
      M.go(function() got = ch:recv() end)
    end)
    T.eq(got, 99)
  end)

  T.it("multiple values over unbuffered channel", function()
    local results = {}
    M.run(function()
      local ch = M.new(0)
      M.go(function()
        for i = 1, 5 do ch:send(i) end
      end)
      M.go(function()
        for _ = 1, 5 do
          local v = ch:recv()
          results[#results + 1] = v
        end
      end)
    end)
    T.eq(#results, 5)
    T.eq(results[1], 1)
    T.eq(results[5], 5)
  end)

  T.it("receiver waits for sender", function()
    local got
    M.run(function()
      local ch = M.new(0)
      M.go(function()
        got = ch:recv()   -- blocks first
      end)
      M.go(function()
        ch:send(77)        -- wakes receiver
      end)
    end)
    T.eq(got, 77)
  end)

end)

-- ── close ─────────────────────────────────────────────────────────────────────

T.describe("close", function()

  T.it("is_closed after close", function()
    local ch = M.new(1)
    T.eq(ch:is_closed(), false)
    ch:close()
    T.eq(ch:is_closed(), true)
  end)

  T.it("recv on closed empty returns nil, false", function()
    M.run(function()
      local ch = M.new(1)
      ch:close()
      local v, ok = ch:recv()
      T.eq(v, nil)
      T.eq(ok, false)
    end)
  end)

  T.it("send on closed returns nil, closed", function()
    M.run(function()
      local ch = M.new(1)
      ch:close()
      local ok, err = ch:send(1)
      T.eq(ok, nil)
      T.eq(err, "closed")
    end)
  end)

  T.it("recv drains buffer before returning closed", function()
    M.run(function()
      local ch = M.new(2)
      ch:send(1); ch:send(2)
      ch:close()
      local v1, ok1 = ch:recv()
      T.eq(v1, 1); T.eq(ok1, true)
      local v2, ok2 = ch:recv()
      T.eq(v2, 2); T.eq(ok2, true)
      local v3, ok3 = ch:recv()
      T.eq(v3, nil); T.eq(ok3, false)
    end)
  end)

  T.it("blocked receiver wakes on close", function()
    local got_ok
    M.run(function()
      local ch = M.new(0)
      M.go(function()
        local _, ok = ch:recv()  -- will block, then be woken by close
        got_ok = ok
      end)
      M.go(function()
        ch:close()
      end)
    end)
    T.eq(got_ok, false)
  end)

  T.it("range-style drain loop", function()
    local sum = 0
    M.run(function()
      local ch = M.new(4)
      for i = 1, 4 do ch:send(i) end
      ch:close()
      while true do
        local v, ok = ch:recv()
        if not ok then break end
        sum = sum + v
      end
    end)
    T.eq(sum, 10)
  end)

end)

-- ── try_send / try_recv ───────────────────────────────────────────────────────

T.describe("try_send / try_recv", function()

  T.it("try_send succeeds when room", function()
    local ch = M.new(2)
    local ok, err = ch:try_send(1)
    T.eq(ok, true)
    T.eq(err, nil)
  end)

  T.it("try_send returns full when buffer full", function()
    local ch = M.new(1)
    ch:try_send("x")
    local ok, err = ch:try_send("y")
    T.eq(ok, nil)
    T.eq(err, "full")
  end)

  T.it("try_recv succeeds when data available", function()
    local ch = M.new(2)
    ch:try_send(7)
    local v, ok = ch:try_recv()
    T.eq(v, 7)
    T.eq(ok, true)
  end)

  T.it("try_recv returns empty when no data and open", function()
    local ch = M.new(2)
    local v, ok, err = ch:try_recv()
    T.eq(v, nil)
    T.eq(err, "empty")
  end)

  T.it("try_recv returns false when closed empty", function()
    local ch = M.new(1)
    ch:close()
    local v, ok = ch:try_recv()
    T.eq(v, nil)
    T.eq(ok, false)
  end)

  T.it("try_send returns closed on closed channel", function()
    local ch = M.new(1)
    ch:close()
    local ok, err = ch:try_send(1)
    T.eq(ok, nil)
    T.eq(err, "closed")
  end)

end)

-- ── select ────────────────────────────────────────────────────────────────────

T.describe("select", function()

  T.it("selects ready recv", function()
    M.run(function()
      local ch = M.new(1)
      ch:send(55)
      local result = M.select({ { ch, "recv" } })
      T.eq(result.op, "recv")
      T.eq(result.value, 55)
    end)
  end)

  T.it("selects ready send", function()
    M.run(function()
      local ch = M.new(1)
      local result = M.select({ { ch, "send", 77 } })
      T.eq(result.op, "send")
      local v = ch:recv()
      T.eq(v, 77)
    end)
  end)

  T.it("default fires when nothing ready", function()
    M.run(function()
      local ch = M.new(0)
      local result = M.select({
        { ch, "recv" },
        { default = true },
      })
      T.eq(result.default, true)
    end)
  end)

  T.it("selects between two ready channels", function()
    M.run(function()
      local ch1 = M.new(1)
      local ch2 = M.new(1)
      ch1:send("a")
      ch2:send("b")
      local result = M.select({ { ch1, "recv" }, { ch2, "recv" } })
      T.ok(result.value == "a" or result.value == "b")
    end)
  end)

end)

-- ── go + pipeline ─────────────────────────────────────────────────────────────

T.describe("pipeline", function()

  T.it("three-stage pipeline", function()
    local out_vals = {}
    M.run(function()
      local ch1 = M.new(0)
      local ch2 = M.new(0)
      -- stage 1: generate 1..3
      M.go(function()
        for i = 1, 3 do ch1:send(i) end
        ch1:close()
      end)
      -- stage 2: double
      M.go(function()
        while true do
          local v, ok = ch1:recv()
          if not ok then break end
          ch2:send(v * 2)
        end
        ch2:close()
      end)
      -- stage 3: collect
      M.go(function()
        while true do
          local v, ok = ch2:recv()
          if not ok then break end
          out_vals[#out_vals + 1] = v
        end
      end)
    end)
    T.eq(#out_vals, 3)
    T.eq(out_vals[1], 2)
    T.eq(out_vals[2], 4)
    T.eq(out_vals[3], 6)
  end)

  T.it("fan-out: one sender, two receivers", function()
    local results = {}
    M.run(function()
      local ch = M.new(0)
      M.go(function()
        for i = 1, 4 do ch:send(i) end
      end)
      M.go(function()
        for _ = 1, 2 do
          local v = ch:recv()
          results[#results + 1] = v
        end
      end)
      M.go(function()
        for _ = 1, 2 do
          local v = ch:recv()
          results[#results + 1] = v
        end
      end)
    end)
    T.eq(#results, 4)
    -- Sort to make assertion order-independent
    table.sort(results)
    T.eq(results[1], 1)
    T.eq(results[4], 4)
  end)

  T.it("done channel pattern", function()
    local done_fired = false
    M.run(function()
      local done = M.new(0)
      M.go(function()
        done:close()
      end)
      M.go(function()
        local _, ok = done:recv()
        done_fired = (ok == false)
      end)
    end)
    T.eq(done_fired, true)
  end)

end)

-- ── M.go return value ─────────────────────────────────────────────────────────

T.describe("M.go", function()
  T.it("returns a coroutine", function()
    M.run(function()
      local co = M.go(function() end)
      T.eq(type(co), "thread")
    end)
  end)
end)
