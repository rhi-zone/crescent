if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local CP = require("lib.connection_pool")

-- Helper: create a simple mock connection factory
local function make_factory()
  local next_id = 0
  local factory = {
    created   = {},
    destroyed = {},
  }
  function factory.create()
    next_id = next_id + 1
    local conn = { id = next_id, alive = true, pinged = 0 }
    factory.created[#factory.created + 1] = conn
    return conn
  end
  function factory.destroy(conn)
    conn.alive = false
    factory.destroyed[#factory.destroyed + 1] = conn
  end
  function factory.validate(conn)
    conn.pinged = conn.pinged + 1
    return conn.alive
  end
  return factory
end

-- Helper: injectable clock
local function make_clock(initial)
  local t = initial or 0
  return {
    tick = function(self, n) t = t + (n or 1) end,
    fn   = function() return t end,
  }
end

-- Default clock for tests that don't care about time
local default_clock = function() return 0 end
local _CP_new = CP.new
CP.new = function(opts)
  if opts and not opts.clock then opts.clock = default_clock end
  return _CP_new(opts)
end

-- ---------------------------------------------------------------------------
T.describe("connection_pool", function()

  -- -------------------------------------------------------------------------
  T.describe("new", function()
    T.it("requires opts.create", function()
      local p, err = CP.new(nil)
      T.eq(p, nil)
      T.ok(err)
      local p2, err2 = CP.new({})
      T.eq(p2, nil)
      T.ok(err2)
    end)

    T.it("creates a pool with defaults", function()
      local p = CP.new({ create = function() return {} end })
      T.ok(p)
      local s = p:stats()
      T.eq(s.size, 0)
      T.eq(s.idle, 0)
      T.eq(s.active, 0)
      T.eq(s.created, 0)
      T.eq(s.destroyed, 0)
      T.eq(s.acquire_count, 0)
      T.eq(s.acquire_errors, 0)
    end)

    T.it("pre-warms when min_size > 0", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, destroy = f.destroy, min_size = 3, max_size = 10 })
      T.ok(p)
      local s = p:stats()
      T.eq(s.size, 3)
      T.eq(s.idle, 3)
      T.eq(s.active, 0)
      T.eq(s.created, 3)
      T.eq(#f.created, 3)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("acquire / release round-trip", function()
    T.it("acquires a new connection when pool is empty", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, max_size = 5 })
      local conn, err = p:acquire()
      T.ok(conn)
      T.eq(err, nil)
      T.eq(conn.id, 1)
      local s = p:stats()
      T.eq(s.active, 1)
      T.eq(s.idle, 0)
      T.eq(s.created, 1)
    end)

    T.it("releases connection back to idle pool", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, max_size = 5 })
      local conn = p:acquire()
      p:release(conn)
      local s = p:stats()
      T.eq(s.idle, 1)
      T.eq(s.active, 0)
    end)

    T.it("reuses idle connection on next acquire", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, max_size = 5 })
      local conn1 = p:acquire()
      p:release(conn1)
      local conn2 = p:acquire()
      -- Should reuse the same connection
      T.eq(conn1.id, conn2.id)
      T.eq(#f.created, 1)  -- only one ever created
    end)

    T.it("tracks active count correctly through multiple acquire/release cycles", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, max_size = 5 })
      local a = p:acquire()
      local b = p:acquire()
      local c = p:acquire()
      T.eq(p:stats().active, 3)
      T.eq(p:stats().idle, 0)
      p:release(b)
      T.eq(p:stats().active, 2)
      T.eq(p:stats().idle, 1)
      p:release(a)
      p:release(c)
      T.eq(p:stats().active, 0)
      T.eq(p:stats().idle, 3)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("max_size limit", function()
    T.it("returns nil, 'pool exhausted' when max_size reached", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, max_size = 2 })
      local c1 = p:acquire()
      local c2 = p:acquire()
      T.ok(c1)
      T.ok(c2)
      local c3, err = p:acquire()
      T.eq(c3, nil)
      T.eq(err, "pool exhausted")
      T.eq(p:stats().acquire_errors, 1)
    end)

    T.it("allows acquire after release when at max_size", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, max_size = 1 })
      local c1 = p:acquire()
      local c2, err = p:acquire()
      T.eq(c2, nil)
      T.eq(err, "pool exhausted")
      p:release(c1)
      local c3, err2 = p:acquire()
      T.ok(c3)
      T.eq(err2, nil)
      T.eq(c3.id, c1.id)  -- reused
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("validate", function()
    T.it("skips invalid connections and creates a new one", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, destroy = f.destroy, validate = f.validate, max_size = 5 })
      local c1 = p:acquire()
      c1.alive = false  -- mark as unhealthy
      p:release(c1)
      T.eq(p:stats().idle, 1)
      -- acquire should detect invalid conn, destroy it, create new
      local c2, err = p:acquire()
      T.ok(c2)
      T.eq(err, nil)
      T.ok(c2.id ~= c1.id)
      T.eq(c1.alive, false)  -- destroy was called (alive set to false by factory)
      T.eq(p:stats().destroyed, 1)
    end)

    T.it("does not destroy healthy connections on acquire", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, destroy = f.destroy, validate = f.validate, max_size = 5 })
      local c1 = p:acquire()
      p:release(c1)
      local c2 = p:acquire()
      T.ok(c2)
      T.eq(p:stats().destroyed, 0)
      T.eq(c2.pinged, 1)  -- validate was called once
    end)

    T.it("handles multiple invalid connections in a row", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, destroy = f.destroy, validate = f.validate, max_size = 10 })
      -- Acquire and release 3 connections, mark them all dead
      local conns = {}
      for i = 1, 3 do
        conns[i] = p:acquire()
      end
      for i = 1, 3 do
        conns[i].alive = false
        p:release(conns[i])
      end
      T.eq(p:stats().idle, 3)
      -- Next acquire should skip all 3 and create a new one
      local c, err = p:acquire()
      T.ok(c)
      T.eq(err, nil)
      T.ok(c.alive)
      T.eq(p:stats().destroyed, 3)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("idle_timeout", function()
    T.it("evicts connections idle longer than idle_timeout on acquire", function()
      local clk = make_clock(0)
      local f = make_factory()
      local p = CP.new({
        create = f.create, destroy = f.destroy,
        max_size = 5, idle_timeout = 10,
        clock = clk.fn,
      })
      local c1 = p:acquire()
      p:release(c1)
      T.eq(p:stats().idle, 1)
      -- advance clock past idle_timeout
      clk:tick(15)
      -- acquire should evict c1, then create new
      local c2, err = p:acquire()
      T.ok(c2)
      T.eq(err, nil)
      T.ok(c2.id ~= c1.id)
      T.eq(p:stats().destroyed, 1)
    end)

    T.it("does not evict connections within idle_timeout", function()
      local clk = make_clock(0)
      local f = make_factory()
      local p = CP.new({
        create = f.create, destroy = f.destroy,
        max_size = 5, idle_timeout = 10,
        clock = clk.fn,
      })
      local c1 = p:acquire()
      p:release(c1)
      clk:tick(5)  -- within timeout
      local c2 = p:acquire()
      T.ok(c2)
      T.eq(c2.id, c1.id)  -- reused
      T.eq(p:stats().destroyed, 0)
    end)

    T.it("evict() removes stale idle connections manually", function()
      local clk = make_clock(0)
      local f = make_factory()
      local p = CP.new({
        create = f.create, destroy = f.destroy,
        max_size = 5, idle_timeout = 10,
        clock = clk.fn,
      })
      local c1 = p:acquire()
      p:release(c1)
      clk:tick(20)
      p:evict()
      T.eq(p:stats().idle, 0)
      T.eq(p:stats().destroyed, 1)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("max_lifetime", function()
    T.it("evicts connections older than max_lifetime on acquire", function()
      local clk = make_clock(0)
      local f = make_factory()
      local p = CP.new({
        create = f.create, destroy = f.destroy,
        max_size = 5, max_lifetime = 100,
        clock = clk.fn,
      })
      local c1 = p:acquire()
      p:release(c1)
      -- advance past lifetime
      clk:tick(150)
      local c2, err = p:acquire()
      T.ok(c2)
      T.eq(err, nil)
      T.ok(c2.id ~= c1.id)
      T.eq(p:stats().destroyed, 1)
    end)

    T.it("does not evict connections within max_lifetime", function()
      local clk = make_clock(0)
      local f = make_factory()
      local p = CP.new({
        create = f.create, destroy = f.destroy,
        max_size = 5, max_lifetime = 100,
        clock = clk.fn,
      })
      local c1 = p:acquire()
      p:release(c1)
      clk:tick(50)
      local c2 = p:acquire()
      T.ok(c2)
      T.eq(c2.id, c1.id)
      T.eq(p:stats().destroyed, 0)
    end)

    T.it("evicts long-lived connections even if recently idle", function()
      local clk = make_clock(0)
      local f = make_factory()
      local p = CP.new({
        create = f.create, destroy = f.destroy,
        max_size = 5, max_lifetime = 100, idle_timeout = 1000,
        clock = clk.fn,
      })
      local c1 = p:acquire()
      -- advance clock to near lifetime limit, then release
      clk:tick(95)
      p:release(c1)
      -- advance just past lifetime
      clk:tick(10)
      p:evict()
      T.eq(p:stats().idle, 0)
      T.eq(p:stats().destroyed, 1)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("with(fn)", function()
    T.it("auto-releases connection on success", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, max_size = 5 })
      local seen_conn
      p:with(function(conn)
        seen_conn = conn
        T.eq(p:stats().active, 1)
      end)
      T.ok(seen_conn)
      T.eq(p:stats().active, 0)
      T.eq(p:stats().idle, 1)
    end)

    T.it("auto-releases connection on error", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, max_size = 5 })
      local result, err = p:with(function()
        error("something went wrong")
      end)
      T.eq(result, nil)
      T.ok(err)
      -- Connection must be returned to idle pool even after error
      T.eq(p:stats().active, 0)
      T.eq(p:stats().idle, 1)
    end)

    T.it("returns the function result on success", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, max_size = 5 })
      local result = p:with(function()
        return 42
      end)
      T.eq(result, 42)
    end)

    T.it("returns nil, errmsg when pool is exhausted", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, max_size = 0 })
      local result, err = p:with(function()
        return 1
      end)
      T.eq(result, nil)
      T.ok(err)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("stats", function()
    T.it("tracks created and destroyed accurately", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, destroy = f.destroy, validate = f.validate, max_size = 5 })
      local c1 = p:acquire()
      local c2 = p:acquire()
      c1.alive = false  -- mark unhealthy
      -- Release c2 first so idle stack becomes [c2, c1] (LIFO: c1 on top).
      -- On next acquire: pop c1 (invalid, destroy), pop c2 (valid, return).
      p:release(c2)
      p:release(c1)
      -- acquire: pops c1 (invalid) -> destroys; pops c2 (valid) -> returns c2
      local c3 = p:acquire()
      T.ok(c3)
      T.eq(c3.id, c2.id)   -- c3 is c2 reused
      local s = p:stats()
      T.eq(s.created, 2)   -- only c1 and c2 created
      T.eq(s.destroyed, 1) -- c1 was destroyed (invalid)
      T.eq(s.acquire_count, 3)
    end)

    T.it("tracks acquire_errors", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, max_size = 1 })
      p:acquire()
      p:acquire()  -- exhausted
      p:acquire()  -- exhausted
      T.eq(p:stats().acquire_errors, 2)
    end)

    T.it("size equals idle + active", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, max_size = 5 })
      local c1 = p:acquire()
      local c2 = p:acquire()
      p:release(c1)
      local s = p:stats()
      T.eq(s.size, s.idle + s.active)
      T.eq(s.idle, 1)
      T.eq(s.active, 1)
      p:release(c2)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("drain", function()
    T.it("destroys all idle connections", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, destroy = f.destroy, max_size = 5 })
      local c1 = p:acquire()
      local c2 = p:acquire()
      p:release(c1)
      p:release(c2)
      T.eq(p:stats().idle, 2)
      p:drain()
      T.eq(p:stats().idle, 0)
      T.eq(p:stats().destroyed, 2)
    end)

    T.it("blocks new acquires after drain", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, destroy = f.destroy, max_size = 5 })
      p:drain()
      local conn, err = p:acquire()
      T.eq(conn, nil)
      T.ok(err)
    end)

    T.it("active connections released after drain are destroyed", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, destroy = f.destroy, max_size = 5 })
      local c1 = p:acquire()
      p:drain()
      -- c1 was active during drain; releasing should destroy it
      p:release(c1)
      T.eq(p:stats().destroyed, 1)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("close", function()
    T.it("destroys all idle connections and prevents new acquires", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, destroy = f.destroy, max_size = 5 })
      local c1 = p:acquire()
      local c2 = p:acquire()
      p:release(c1)
      p:release(c2)
      p:close()
      T.eq(p:stats().idle, 0)
      T.eq(p:stats().destroyed, 2)
      local conn, err = p:acquire()
      T.eq(conn, nil)
      T.ok(err)
    end)

    T.it("destroys active connections when released after close", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, destroy = f.destroy, max_size = 5 })
      local c1 = p:acquire()
      p:close()
      p:release(c1)
      T.eq(p:stats().destroyed, 1)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("warm", function()
    T.it("pre-creates min_size connections on construction", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, destroy = f.destroy, min_size = 4, max_size = 10 })
      T.eq(p:stats().size, 4)
      T.eq(p:stats().idle, 4)
      T.eq(p:stats().created, 4)
    end)

    T.it("warm() called manually creates up to min_size", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, destroy = f.destroy, min_size = 3, max_size = 10 })
      -- already warmed to 3; warm again should not add more
      p:warm()
      T.eq(p:stats().size, 3)
    end)

    T.it("warm() respects max_size", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, destroy = f.destroy, min_size = 5, max_size = 2 })
      T.eq(p:stats().size, 2)  -- capped by max_size
    end)

    T.it("warmed connections are reusable via acquire", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, min_size = 2, max_size = 5 })
      local c1 = p:acquire()
      T.ok(c1)
      T.eq(p:stats().created, 2)  -- 2 from warm, no new ones yet
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("resize", function()
    T.it("adjusts max_size upward", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, max_size = 2 })
      p:acquire()
      p:acquire()
      local c3, err = p:acquire()
      T.eq(c3, nil)
      T.eq(err, "pool exhausted")
      p:resize(5)
      local c4, err2 = p:acquire()
      T.ok(c4)
      T.eq(err2, nil)
    end)

    T.it("adjusts max_size downward and evicts excess idle connections", function()
      local f = make_factory()
      local p = CP.new({ create = f.create, destroy = f.destroy, max_size = 5 })
      -- Acquire all 4 at once first (no reuse), then release all
      local conns = {}
      for i = 1, 4 do conns[i] = p:acquire() end
      for i = 1, 4 do p:release(conns[i]) end
      T.eq(p:stats().idle, 4)
      p:resize(2)
      T.ok(p:stats().idle <= 2)
    end)
  end)

  -- -------------------------------------------------------------------------
  T.describe("create failure", function()
    T.it("returns nil, 'create failed: ...' when factory errors", function()
      local p = CP.new({
        create = function() error("db unavailable") end,
        max_size = 5,
      })
      local conn, err = p:acquire()
      T.eq(conn, nil)
      T.ok(err)
      -- error message should contain "create failed"
      T.ok(err:find("create failed"))
      T.eq(p:stats().acquire_errors, 1)
    end)
  end)

end)
