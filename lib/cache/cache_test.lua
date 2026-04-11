if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local cache = require("lib.cache")

T.describe("cache", function()

  T.describe("new", function()
    T.it("creates a cache with given capacity", function()
      local c = cache.new(10)
      T.ok(c)
      T.eq(c:capacity(), 10)
      T.eq(c:count(), 0)
    end)

    T.it("returns nil, errmsg for invalid capacity", function()
      local c, err = cache.new(0)
      T.eq(c, nil)
      T.ok(err)
      local c2, err2 = cache.new(-1)
      T.eq(c2, nil)
      T.ok(err2)
    end)

    T.it("floors fractional capacity", function()
      local c = cache.new(3.9)
      T.eq(c:capacity(), 3)
    end)
  end)

  T.describe("basic get/set/delete", function()
    T.it("set and get a value", function()
      local c = cache.new(10)
      c:set("a", 1)
      T.eq(c:get("a"), 1)
    end)

    T.it("set returns old value on overwrite", function()
      local c = cache.new(10)
      local old1 = c:set("a", 1)
      T.eq(old1, nil)
      local old2 = c:set("a", 2)
      T.eq(old2, 1)
      T.eq(c:get("a"), 2)
    end)

    T.it("get returns nil for missing key", function()
      local c = cache.new(10)
      T.eq(c:get("missing"), nil)
    end)

    T.it("delete removes entry and returns old value", function()
      local c = cache.new(10)
      c:set("a", 42)
      local old = c:delete("a")
      T.eq(old, 42)
      T.eq(c:get("a"), nil)
      T.eq(c:count(), 0)
    end)

    T.it("delete non-existent key returns nil", function()
      local c = cache.new(10)
      T.eq(c:delete("nope"), nil)
    end)

    T.it("has returns true for existing key", function()
      local c = cache.new(10)
      c:set("x", 1)
      T.ok(c:has("x"))
    end)

    T.it("has returns false for missing key", function()
      local c = cache.new(10)
      T.eq(c:has("x"), false)
    end)
  end)

  T.describe("LRU eviction", function()
    T.it("evicts oldest entry when capacity exceeded", function()
      local c = cache.new(3)
      c:set("a", 1)
      c:set("b", 2)
      c:set("c", 3)
      c:set("d", 4) -- should evict "a"
      T.eq(c:get("a"), nil)
      T.eq(c:get("b"), 2)
      T.eq(c:get("d"), 4)
      T.eq(c:count(), 3)
    end)

    T.it("access promotes entry, changing eviction order", function()
      local c = cache.new(3)
      c:set("a", 1)
      c:set("b", 2)
      c:set("c", 3)
      c:get("a") -- promote "a" to most recent
      c:set("d", 4) -- should evict "b" (now oldest)
      T.eq(c:get("a"), 1)
      T.eq(c:get("b"), nil)
      T.eq(c:get("c"), 3)
      T.eq(c:get("d"), 4)
    end)

    T.it("overwrite promotes entry", function()
      local c = cache.new(3)
      c:set("a", 1)
      c:set("b", 2)
      c:set("c", 3)
      c:set("a", 10) -- overwrite promotes "a"
      c:set("d", 4) -- should evict "b"
      T.eq(c:get("a"), 10)
      T.eq(c:get("b"), nil)
    end)
  end)

  T.describe("peek", function()
    T.it("returns value without promoting", function()
      local c = cache.new(3)
      c:set("a", 1)
      c:set("b", 2)
      c:set("c", 3)
      T.eq(c:peek("a"), 1) -- does NOT promote "a"
      c:set("d", 4) -- should evict "a" (still oldest)
      T.eq(c:get("a"), nil)
      T.eq(c:get("b"), 2)
    end)

    T.it("returns nil for missing key", function()
      local c = cache.new(5)
      T.eq(c:peek("nope"), nil)
    end)
  end)

  T.describe("TTL expiration", function()
    T.it("entries expire after default TTL", function()
      local now = 1000
      local c = cache.new(10, { ttl = 60, clock = function() return now end })
      c:set("a", 1)
      T.eq(c:get("a"), 1)
      now = 1059 -- not yet expired
      T.eq(c:get("a"), 1)
      now = 1060 -- exactly at expiry
      T.eq(c:get("a"), nil)
    end)

    T.it("per-entry TTL override", function()
      local now = 1000
      local c = cache.new(10, { ttl = 60, clock = function() return now end })
      c:set("short", "val", 10) -- 10s TTL override
      c:set("long", "val") -- uses default 60s
      now = 1011
      T.eq(c:get("short"), nil) -- expired
      T.eq(c:get("long"), "val") -- still alive
    end)

    T.it("has returns false for expired entry", function()
      local now = 100
      local c = cache.new(10, { ttl = 5, clock = function() return now end })
      c:set("a", 1)
      T.ok(c:has("a"))
      now = 105
      T.eq(c:has("a"), false)
    end)

    T.it("peek returns nil for expired entry", function()
      local now = 100
      local c = cache.new(10, { ttl = 5, clock = function() return now end })
      c:set("a", 1)
      now = 200
      T.eq(c:peek("a"), nil)
    end)

    T.it("expired entry is removed from count", function()
      local now = 100
      local c = cache.new(10, { ttl = 5, clock = function() return now end })
      c:set("a", 1)
      T.eq(c:count(), 1)
      now = 200
      c:get("a") -- triggers lazy removal
      T.eq(c:count(), 0)
    end)

    T.it("no TTL means entry never expires", function()
      local now = 0
      local c = cache.new(10, { clock = function() return now end })
      c:set("a", 1)
      now = 999999999
      T.eq(c:get("a"), 1)
    end)
  end)

  T.describe("on_evict callback", function()
    T.it("fires on capacity eviction", function()
      local evicted = {}
      local c = cache.new(2, {
        on_evict = function(k, v) evicted[#evicted + 1] = { k, v } end,
      })
      c:set("a", 1)
      c:set("b", 2)
      c:set("c", 3) -- evicts "a"
      T.eq(#evicted, 1)
      T.eq(evicted[1][1], "a")
      T.eq(evicted[1][2], 1)
    end)

    T.it("fires on TTL expiration during get", function()
      local now = 100
      local evicted = {}
      local c = cache.new(10, {
        ttl = 5,
        clock = function() return now end,
        on_evict = function(k, v) evicted[#evicted + 1] = { k, v } end,
      })
      c:set("a", 1)
      now = 200
      c:get("a") -- triggers expiry
      T.eq(#evicted, 1)
      T.eq(evicted[1][1], "a")
      T.eq(evicted[1][2], 1)
    end)

    T.it("does NOT fire on delete", function()
      local evicted = {}
      local c = cache.new(10, {
        on_evict = function(k, v) evicted[#evicted + 1] = { k, v } end,
      })
      c:set("a", 1)
      c:delete("a")
      T.eq(#evicted, 0)
    end)

    T.it("does NOT fire on clear", function()
      local evicted = {}
      local c = cache.new(10, {
        on_evict = function(k, v) evicted[#evicted + 1] = { k, v } end,
      })
      c:set("a", 1)
      c:set("b", 2)
      c:clear()
      T.eq(#evicted, 0)
    end)
  end)

  T.describe("clear", function()
    T.it("removes all entries", function()
      local c = cache.new(10)
      c:set("a", 1)
      c:set("b", 2)
      c:set("c", 3)
      c:clear()
      T.eq(c:count(), 0)
      T.eq(c:get("a"), nil)
      T.eq(c:get("b"), nil)
      T.eq(c:get("c"), nil)
    end)
  end)

  T.describe("keys", function()
    T.it("returns keys in most-recent-first order", function()
      local c = cache.new(10)
      c:set("a", 1)
      c:set("b", 2)
      c:set("c", 3)
      local k = c:keys()
      T.eq(k[1], "c")
      T.eq(k[2], "b")
      T.eq(k[3], "a")
      T.eq(#k, 3)
    end)

    T.it("skips expired entries", function()
      local now = 100
      local c = cache.new(10, { ttl = 5, clock = function() return now end })
      c:set("a", 1)
      c:set("b", 2)
      now = 200
      c:set("c", 3) -- fresh
      local k = c:keys()
      T.eq(#k, 1)
      T.eq(k[1], "c")
    end)
  end)

  T.describe("pairs", function()
    T.it("iterates in most-recent-first order", function()
      local c = cache.new(10)
      c:set("a", 1)
      c:set("b", 2)
      c:set("c", 3)
      local collected = {}
      for k, v in c:pairs() do
        collected[#collected + 1] = { k, v }
      end
      T.eq(#collected, 3)
      T.eq(collected[1][1], "c")
      T.eq(collected[2][1], "b")
      T.eq(collected[3][1], "a")
    end)
  end)

  T.describe("set_many / get_many", function()
    T.it("set_many inserts multiple entries", function()
      local c = cache.new(10)
      c:set_many({ { "a", 1 }, { "b", 2 }, { "c", 3 } })
      T.eq(c:count(), 3)
      T.eq(c:get("a"), 1)
      T.eq(c:get("b"), 2)
      T.eq(c:get("c"), 3)
    end)

    T.it("set_many with per-entry TTL", function()
      local now = 100
      local c = cache.new(10, { clock = function() return now end })
      c:set_many({ { "a", 1, 5 }, { "b", 2, 50 } })
      now = 106
      T.eq(c:get("a"), nil) -- expired
      T.eq(c:get("b"), 2)   -- still alive
    end)

    T.it("get_many returns found entries", function()
      local c = cache.new(10)
      c:set("a", 1)
      c:set("b", 2)
      local result = c:get_many({ "a", "b", "missing" })
      T.eq(result.a, 1)
      T.eq(result.b, 2)
      T.eq(result.missing, nil)
    end)
  end)

  T.describe("resize", function()
    T.it("grow allows more entries", function()
      local c = cache.new(2)
      c:set("a", 1)
      c:set("b", 2)
      c:resize(5)
      T.eq(c:capacity(), 5)
      c:set("c", 3)
      c:set("d", 4)
      T.eq(c:count(), 4)
      T.eq(c:get("a"), 1) -- still present
    end)

    T.it("shrink evicts least recently used", function()
      local evicted = {}
      local c = cache.new(5, {
        on_evict = function(k, v) evicted[#evicted + 1] = { k, v } end,
      })
      c:set("a", 1)
      c:set("b", 2)
      c:set("c", 3)
      c:set("d", 4)
      c:set("e", 5)
      c:resize(2) -- should evict a, b, c (oldest 3)
      T.eq(c:count(), 2)
      T.eq(c:capacity(), 2)
      T.eq(c:get("a"), nil)
      T.eq(c:get("b"), nil)
      T.eq(c:get("c"), nil)
      T.eq(c:get("d"), 4)
      T.eq(c:get("e"), 5)
      T.eq(#evicted, 3)
    end)

    T.it("returns nil, errmsg for invalid capacity", function()
      local c = cache.new(5)
      local r, err = c:resize(0)
      T.eq(r, nil)
      T.ok(err)
    end)
  end)

  T.describe("empty cache operations", function()
    T.it("get on empty cache returns nil", function()
      local c = cache.new(5)
      T.eq(c:get("anything"), nil)
    end)

    T.it("delete on empty cache returns nil", function()
      local c = cache.new(5)
      T.eq(c:delete("anything"), nil)
    end)

    T.it("keys on empty cache returns empty table", function()
      local c = cache.new(5)
      T.eq(#c:keys(), 0)
    end)

    T.it("pairs on empty cache produces no iterations", function()
      local c = cache.new(5)
      local count = 0
      for _ in c:pairs() do count = count + 1 end
      T.eq(count, 0)
    end)

    T.it("clear on empty cache is safe", function()
      local c = cache.new(5)
      c:clear()
      T.eq(c:count(), 0)
    end)
  end)

  T.describe("capacity 1", function()
    T.it("works with capacity 1", function()
      local c = cache.new(1)
      c:set("a", 1)
      T.eq(c:get("a"), 1)
      c:set("b", 2) -- evicts "a"
      T.eq(c:get("a"), nil)
      T.eq(c:get("b"), 2)
      T.eq(c:count(), 1)
    end)
  end)

  T.describe("various key types", function()
    T.it("supports number keys", function()
      local c = cache.new(10)
      c:set(1, "one")
      c:set(2, "two")
      T.eq(c:get(1), "one")
      T.eq(c:get(2), "two")
    end)

    T.it("supports boolean keys", function()
      local c = cache.new(10)
      c:set(true, "yes")
      c:set(false, "no")
      T.eq(c:get(true), "yes")
      T.eq(c:get(false), "no")
    end)

    T.it("supports table keys", function()
      local c = cache.new(10)
      local k = {}
      c:set(k, "val")
      T.eq(c:get(k), "val")
    end)
  end)

end)
