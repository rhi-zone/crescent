if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local LRU = require("lib.lru_ttl")

-- ── Construction ──────────────────────────────────────────────────────────────

T.describe("lru_ttl.new", function()

  T.it("creates cache with given max_size", function()
    local c = LRU.new({ max_size = 10 })
    T.ok(c)
    T.eq(c:capacity(), 10)
    T.eq(c:size(), 0)
  end)

  T.it("returns nil, errmsg for missing opts", function()
    local c, err = LRU.new()
    T.eq(c, nil)
    T.ok(err)
  end)

  T.it("returns nil, errmsg for invalid max_size", function()
    local c, err = LRU.new({ max_size = 0 })
    T.eq(c, nil)
    T.ok(err)
    local c2, err2 = LRU.new({ max_size = -1 })
    T.eq(c2, nil)
    T.ok(err2)
  end)

  T.it("floors fractional max_size", function()
    local c = LRU.new({ max_size = 4.9 })
    T.eq(c:capacity(), 4)
  end)

  T.it("starts empty and not full", function()
    local c = LRU.new({ max_size = 5 })
    T.eq(c:size(), 0)
    T.eq(c:full(), false)
  end)

end)

-- ── Basic get/set/delete ──────────────────────────────────────────────────────

T.describe("basic set/get/delete", function()

  T.it("set and get a value", function()
    local c = LRU.new({ max_size = 10 })
    c:set("k", "v")
    T.eq(c:get("k"), "v")
  end)

  T.it("get returns nil for missing key", function()
    local c = LRU.new({ max_size = 10 })
    T.eq(c:get("nope"), nil)
  end)

  T.it("set overwrites existing value", function()
    local c = LRU.new({ max_size = 10 })
    c:set("k", 1)
    c:set("k", 2)
    T.eq(c:get("k"), 2)
    T.eq(c:size(), 1)
  end)

  T.it("delete removes entry and returns old value", function()
    local c = LRU.new({ max_size = 5 })
    c:set("a", 42)
    local old = c:delete("a")
    T.eq(old, 42)
    T.eq(c:get("a"), nil)
    T.eq(c:size(), 0)
  end)

  T.it("delete non-existent key returns nil", function()
    local c = LRU.new({ max_size = 5 })
    T.eq(c:delete("nope"), nil)
  end)

  T.it("clear removes all entries", function()
    local c = LRU.new({ max_size = 5 })
    c:set("a", 1); c:set("b", 2)
    c:clear()
    T.eq(c:size(), 0)
    T.eq(c:get("a"), nil)
    T.eq(c:get("b"), nil)
  end)

end)

-- ── LRU eviction ─────────────────────────────────────────────────────────────

T.describe("LRU eviction", function()

  T.it("set beyond capacity evicts LRU entry", function()
    local c = LRU.new({ max_size = 3 })
    c:set("a", 1); c:set("b", 2); c:set("c", 3)
    c:set("d", 4)  -- evicts "a"
    T.eq(c:get("a"), nil)
    T.eq(c:get("b"), 2)
    T.eq(c:get("d"), 4)
    T.eq(c:size(), 3)
  end)

  T.it("evict event fires on LRU eviction", function()
    local fired_key, fired_val
    local c = LRU.new({ max_size = 2 })
    c:on("evict", function(k, v) fired_key = k; fired_val = v end)
    c:set("a", 1); c:set("b", 2)
    c:set("c", 3)  -- evicts "a"
    T.eq(fired_key, "a")
    T.eq(fired_val, 1)
  end)

  T.it("evict event NOT fired on delete", function()
    local fired = false
    local c = LRU.new({ max_size = 5 })
    c:on("evict", function() fired = true end)
    c:set("a", 1)
    c:delete("a")
    T.eq(fired, false)
  end)

  T.it("evict event NOT fired on clear", function()
    local fired = false
    local c = LRU.new({ max_size = 5 })
    c:on("evict", function() fired = true end)
    c:set("a", 1); c:set("b", 2)
    c:clear()
    T.eq(fired, false)
  end)

end)

-- ── LRU order ─────────────────────────────────────────────────────────────────

T.describe("LRU order", function()

  T.it("get promotes entry to MRU", function()
    local c = LRU.new({ max_size = 3 })
    c:set("a", 1); c:set("b", 2); c:set("c", 3)
    c:get("a")        -- promote "a" to MRU
    c:set("d", 4)     -- evicts "b" (now LRU)
    T.eq(c:get("b"), nil)
    T.eq(c:get("a"), 1)
    T.eq(c:get("c"), 3)
  end)

  T.it("set on existing key promotes to MRU", function()
    local c = LRU.new({ max_size = 3 })
    c:set("a", 1); c:set("b", 2); c:set("c", 3)
    c:set("a", 10)    -- overwrite promotes "a"
    c:set("d", 4)     -- evicts "b"
    T.eq(c:get("a"), 10)
    T.eq(c:get("b"), nil)
  end)

  T.it("peek does NOT promote (LRU order unchanged)", function()
    local c = LRU.new({ max_size = 3 })
    c:set("a", 1); c:set("b", 2); c:set("c", 3)
    T.eq(c:peek("a"), 1)  -- "a" stays LRU
    c:set("d", 4)         -- evicts "a"
    T.eq(c:get("a"), nil)
    T.eq(c:get("b"), 2)
  end)

  T.it("has does NOT promote (LRU order unchanged)", function()
    local c = LRU.new({ max_size = 3 })
    c:set("a", 1); c:set("b", 2); c:set("c", 3)
    T.ok(c:has("a"))   -- "a" stays LRU
    c:set("d", 4)      -- evicts "a"
    T.eq(c:get("a"), nil)
  end)

end)

-- ── TTL: basic expiry ─────────────────────────────────────────────────────────

T.describe("TTL expiry", function()

  T.it("expired entry returns nil from get", function()
    local now = 1000
    local c = LRU.new({ max_size = 10, default_ttl = 60,
                         clock = function() return now end })
    c:set("a", 1)
    T.eq(c:get("a"), 1)
    now = 1059
    T.eq(c:get("a"), 1)
    now = 1060
    T.eq(c:get("a"), nil)
  end)

  T.it("per-entry TTL override takes precedence over default", function()
    local now = 1000
    local c = LRU.new({ max_size = 10, default_ttl = 60,
                         clock = function() return now end })
    c:set("short", "v", 10)
    c:set("long",  "v")
    now = 1011
    T.eq(c:get("short"), nil)
    T.eq(c:get("long"),  "v")
  end)

  T.it("ttl=0 means no expiry regardless of default_ttl", function()
    local now = 1000
    local c = LRU.new({ max_size = 10, default_ttl = 60,
                         clock = function() return now end })
    c:set("k", "v", 0)
    now = 999999
    T.eq(c:get("k"), "v")
  end)

  T.it("no default_ttl and no per-entry ttl: entry never expires", function()
    local now = 0
    local c = LRU.new({ max_size = 10, clock = function() return now end })
    c:set("a", 1)
    now = 999999999
    T.eq(c:get("a"), 1)
  end)

  T.it("expiration event fires on get of expired entry", function()
    local fired_key, fired_val
    local now = 100
    local c = LRU.new({ max_size = 10, default_ttl = 5,
                         clock = function() return now end })
    c:on("expire", function(k, v) fired_key = k; fired_val = v end)
    c:set("a", 42)
    now = 200
    c:get("a")
    T.eq(fired_key, "a")
    T.eq(fired_val, 42)
  end)

  T.it("expired entry removed from size on get", function()
    local now = 100
    local c = LRU.new({ max_size = 10, default_ttl = 5,
                         clock = function() return now end })
    c:set("a", 1)
    T.eq(c:size(), 1)
    now = 200
    c:get("a")
    T.eq(c:size(), 0)
  end)

  T.it("peek returns nil for expired entry", function()
    local now = 100
    local c = LRU.new({ max_size = 10, default_ttl = 5,
                         clock = function() return now end })
    c:set("a", 1)
    now = 200
    T.eq(c:peek("a"), nil)
  end)

  T.it("has returns false for expired entry", function()
    local now = 100
    local c = LRU.new({ max_size = 10, default_ttl = 5,
                         clock = function() return now end })
    c:set("a", 1)
    T.ok(c:has("a"))
    now = 200
    T.eq(c:has("a"), false)
  end)

end)

-- ── is_expired ────────────────────────────────────────────────────────────────

T.describe("is_expired", function()

  T.it("returns false for missing key", function()
    local c = LRU.new({ max_size = 5 })
    T.eq(c:is_expired("x"), false)
  end)

  T.it("returns false for entry with no TTL", function()
    local c = LRU.new({ max_size = 5 })
    c:set("k", 1)
    T.eq(c:is_expired("k"), false)
  end)

  T.it("returns false before TTL elapses", function()
    local now = 100
    local c = LRU.new({ max_size = 5, default_ttl = 60,
                         clock = function() return now end })
    c:set("k", 1)
    now = 150
    T.eq(c:is_expired("k"), false)
  end)

  T.it("returns true after TTL elapses", function()
    local now = 100
    local c = LRU.new({ max_size = 5, default_ttl = 60,
                         clock = function() return now end })
    c:set("k", 1)
    now = 200
    T.ok(c:is_expired("k"))
  end)

end)

-- ── get_with_meta ─────────────────────────────────────────────────────────────

T.describe("get_with_meta", function()

  T.it("returns value and metadata", function()
    local now = 1000
    local c = LRU.new({ max_size = 10, default_ttl = 60,
                         clock = function() return now end })
    c:set("k", "hello")
    local val, meta = c:get_with_meta("k")
    T.eq(val, "hello")
    T.ok(meta)
    T.eq(meta.created_at, 1000)
    T.eq(meta.expires_at, 1060)
    T.eq(meta.hit_count, 1)
  end)

  T.it("hit_count increments with each get_with_meta call", function()
    local now = 1000
    local c = LRU.new({ max_size = 10, clock = function() return now end })
    c:set("k", "v")
    c:get_with_meta("k")
    c:get_with_meta("k")
    local _, meta = c:get_with_meta("k")
    T.eq(meta.hit_count, 3)
  end)

  T.it("last_accessed updates on each call", function()
    local now = 1000
    local c = LRU.new({ max_size = 10, clock = function() return now end })
    c:set("k", "v")
    now = 2000
    local _, meta = c:get_with_meta("k")
    T.eq(meta.last_accessed, 2000)
  end)

  T.it("returns nil, nil for missing key", function()
    local c = LRU.new({ max_size = 5 })
    local v, m = c:get_with_meta("nope")
    T.eq(v, nil)
    T.eq(m, nil)
  end)

  T.it("returns nil, nil for expired entry", function()
    local now = 100
    local c = LRU.new({ max_size = 5, default_ttl = 5,
                         clock = function() return now end })
    c:set("k", 1)
    now = 200
    local v, m = c:get_with_meta("k")
    T.eq(v, nil)
    T.eq(m, nil)
  end)

  T.it("get resets hit_count to 0 on set overwrite", function()
    local now = 1000
    local c = LRU.new({ max_size = 10, clock = function() return now end })
    c:set("k", "v1")
    c:get("k"); c:get("k")
    c:set("k", "v2")  -- overwrite resets hit_count
    local _, meta = c:get_with_meta("k")
    T.eq(meta.hit_count, 1)
  end)

end)

-- ── touch / extend / expire ───────────────────────────────────────────────────

T.describe("touch", function()

  T.it("resets TTL timer so entry no longer expires at original time", function()
    local now = 1000
    local c = LRU.new({ max_size = 10, default_ttl = 60,
                         clock = function() return now end })
    c:set("k", "v")  -- expires at 1060
    now = 1050
    c:touch("k")     -- resets: expires at 1050+60=1110
    now = 1070       -- past original expiry, before new expiry
    T.eq(c:get("k"), "v")
    now = 1110
    T.eq(c:get("k"), nil)
  end)

  T.it("returns false for missing key", function()
    local c = LRU.new({ max_size = 5 })
    T.eq(c:touch("nope"), false)
  end)

  T.it("returns true for existing key", function()
    local c = LRU.new({ max_size = 5, default_ttl = 60 })
    c:set("k", 1)
    T.ok(c:touch("k"))
  end)

  T.it("returns false for already-expired entry", function()
    local now = 100
    local c = LRU.new({ max_size = 5, default_ttl = 5,
                         clock = function() return now end })
    c:set("k", 1)
    now = 200
    T.eq(c:touch("k"), false)
  end)

end)

T.describe("extend", function()

  T.it("adds seconds to existing expiry", function()
    local now = 1000
    local c = LRU.new({ max_size = 10, default_ttl = 60,
                         clock = function() return now end })
    c:set("k", "v")   -- expires at 1060
    c:extend("k", 30) -- expires at 1090
    now = 1080
    T.eq(c:get("k"), "v")
    now = 1090
    T.eq(c:get("k"), nil)
  end)

  T.it("sets expiry from now if entry has none", function()
    local now = 1000
    local c = LRU.new({ max_size = 10, clock = function() return now end })
    c:set("k", "v")     -- no TTL
    c:extend("k", 60)   -- expires at 1060
    now = 1059
    T.eq(c:get("k"), "v")
    now = 1060
    T.eq(c:get("k"), nil)
  end)

  T.it("returns false for missing key", function()
    local c = LRU.new({ max_size = 5 })
    T.eq(c:extend("nope", 10), false)
  end)

  T.it("returns false for already-expired entry", function()
    local now = 100
    local c = LRU.new({ max_size = 5, default_ttl = 5,
                         clock = function() return now end })
    c:set("k", 1)
    now = 200
    T.eq(c:extend("k", 10), false)
  end)

end)

T.describe("expire", function()

  T.it("immediately expires an entry (get returns nil)", function()
    local now = 1000
    local c = LRU.new({ max_size = 10, default_ttl = 3600,
                         clock = function() return now end })
    c:set("k", "v")
    c:expire("k")
    T.eq(c:get("k"), nil)
  end)

  T.it("returns true for existing key", function()
    local c = LRU.new({ max_size = 5, default_ttl = 60 })
    c:set("k", 1)
    T.ok(c:expire("k"))
  end)

  T.it("returns false for missing key", function()
    local c = LRU.new({ max_size = 5 })
    T.eq(c:expire("nope"), false)
  end)

  T.it("fires expiration event on next get", function()
    local fired = false
    local now = 1000
    local c = LRU.new({ max_size = 5, default_ttl = 3600,
                         clock = function() return now end })
    c:on("expire", function() fired = true end)
    c:set("k", 1)
    c:expire("k")
    c:get("k")
    T.ok(fired)
  end)

end)

-- ── evict_expired ─────────────────────────────────────────────────────────────

T.describe("evict_expired", function()

  T.it("removes all expired entries and returns count", function()
    local now = 1000
    local c = LRU.new({ max_size = 10, default_ttl = 60,
                         clock = function() return now end })
    c:set("a", 1); c:set("b", 2); c:set("c", 3)
    now = 1100  -- all expired
    local count = c:evict_expired()
    T.eq(count, 3)
    T.eq(c:size(), 0)
  end)

  T.it("only removes entries past their TTL", function()
    local now = 1000
    local c = LRU.new({ max_size = 10, clock = function() return now end })
    c:set("short", "v", 10)  -- expires at 1010
    c:set("long",  "v", 100) -- expires at 1100
    c:set("nott",  "v")      -- no TTL, never expires
    now = 1050
    local count = c:evict_expired()
    T.eq(count, 1)
    T.eq(c:size(), 2)
    T.eq(c:peek("short"), nil)
    T.eq(c:peek("long"), "v")
    T.eq(c:peek("nott"), "v")
  end)

  T.it("fires expiration events for each evicted entry", function()
    local fired = {}
    local now = 1000
    local c = LRU.new({ max_size = 10, default_ttl = 10,
                         clock = function() return now end })
    c:on("expire", function(k) fired[#fired + 1] = k end)
    c:set("a", 1); c:set("b", 2)
    now = 1100
    c:evict_expired()
    T.eq(#fired, 2)
  end)

  T.it("returns 0 when nothing is expired", function()
    local now = 1000
    local c = LRU.new({ max_size = 10, default_ttl = 3600,
                         clock = function() return now end })
    c:set("a", 1)
    local count = c:evict_expired()
    T.eq(count, 0)
    T.eq(c:size(), 1)
  end)

end)

-- ── keys / values / entries ───────────────────────────────────────────────────

T.describe("keys / values / entries", function()

  T.it("keys returns non-expired keys in MRU order", function()
    local c = LRU.new({ max_size = 10 })
    c:set("a", 1); c:set("b", 2); c:set("c", 3)
    local k = c:keys()
    T.eq(#k, 3)
    T.eq(k[1], "c"); T.eq(k[2], "b"); T.eq(k[3], "a")
  end)

  T.it("values returns non-expired values in MRU order", function()
    local c = LRU.new({ max_size = 10 })
    c:set("a", 1); c:set("b", 2); c:set("c", 3)
    local v = c:values()
    T.eq(v[1], 3); T.eq(v[2], 2); T.eq(v[3], 1)
  end)

  T.it("entries returns {key,value} pairs in MRU order", function()
    local c = LRU.new({ max_size = 10 })
    c:set("a", 1); c:set("b", 2)
    local e = c:entries()
    T.eq(#e, 2)
    T.eq(e[1][1], "b"); T.eq(e[1][2], 2)
    T.eq(e[2][1], "a"); T.eq(e[2][2], 1)
  end)

  T.it("keys/values/entries skip expired entries", function()
    local now = 100
    local c = LRU.new({ max_size = 10, default_ttl = 5,
                         clock = function() return now end })
    c:set("a", 1); c:set("b", 2)
    now = 200
    c:set("c", 3)
    local k = c:keys()
    T.eq(#k, 1); T.eq(k[1], "c")
    local v = c:values()
    T.eq(#v, 1); T.eq(v[1], 3)
    local e = c:entries()
    T.eq(#e, 1); T.eq(e[1][1], "c")
  end)

end)

-- ── pairs iterator ────────────────────────────────────────────────────────────

T.describe("pairs iterator", function()

  T.it("iterates non-expired entries in MRU order", function()
    local c = LRU.new({ max_size = 10 })
    c:set("a", 1); c:set("b", 2); c:set("c", 3)
    local out = {}
    for k, v in c:pairs() do
      out[#out + 1] = { k, v }
    end
    T.eq(#out, 3)
    T.eq(out[1][1], "c"); T.eq(out[2][1], "b"); T.eq(out[3][1], "a")
  end)

  T.it("skips expired entries during iteration", function()
    local now = 100
    local c = LRU.new({ max_size = 10, default_ttl = 5,
                         clock = function() return now end })
    c:set("a", 1); c:set("b", 2)
    now = 200
    c:set("c", 3)
    local keys = {}
    for k in c:pairs() do
      keys[#keys + 1] = k
    end
    T.eq(#keys, 1); T.eq(keys[1], "c")
  end)

end)

-- ── size / capacity / full ────────────────────────────────────────────────────

T.describe("size / capacity / full", function()

  T.it("size reflects live entries", function()
    local c = LRU.new({ max_size = 5 })
    T.eq(c:size(), 0)
    c:set("a", 1); T.eq(c:size(), 1)
    c:set("b", 2); T.eq(c:size(), 2)
    c:delete("a");  T.eq(c:size(), 1)
  end)

  T.it("full is true when at capacity", function()
    local c = LRU.new({ max_size = 2 })
    T.eq(c:full(), false)
    c:set("a", 1); T.eq(c:full(), false)
    c:set("b", 2); T.ok(c:full())
  end)

  T.it("full is false after eviction frees a slot", function()
    local c = LRU.new({ max_size = 2 })
    c:set("a", 1); c:set("b", 2)
    T.ok(c:full())
    c:set("c", 3)  -- evicts "a"
    T.ok(c:full())
    c:delete("b")
    T.eq(c:full(), false)
  end)

end)

-- ── stats ─────────────────────────────────────────────────────────────────────

T.describe("stats", function()

  T.it("hits and misses accumulate correctly", function()
    local c = LRU.new({ max_size = 5 })
    c:set("a", 1)
    c:get("a"); c:get("a")   -- 2 hits
    c:get("z"); c:get("y")   -- 2 misses
    local s = c:stats()
    T.eq(s.hits, 2)
    T.eq(s.misses, 2)
  end)

  T.it("sets counted on each set call", function()
    local c = LRU.new({ max_size = 5 })
    c:set("a", 1); c:set("b", 2); c:set("a", 10)
    T.eq(c:stats().sets, 3)
  end)

  T.it("deletes counted on each delete call", function()
    local c = LRU.new({ max_size = 5 })
    c:set("a", 1); c:delete("a"); c:delete("nope")
    T.eq(c:stats().deletes, 1)  -- only real deletes count
  end)

  T.it("evictions counted on LRU eviction", function()
    local c = LRU.new({ max_size = 2 })
    c:set("a", 1); c:set("b", 2); c:set("c", 3)
    T.eq(c:stats().evictions, 1)
  end)

  T.it("expirations counted when expired entry is accessed", function()
    local now = 100
    local c = LRU.new({ max_size = 10, default_ttl = 5,
                         clock = function() return now end })
    c:set("a", 1); c:set("b", 2)
    now = 200
    c:get("a"); c:get("b")
    T.eq(c:stats().expirations, 2)
  end)

  T.it("hit_rate calculation", function()
    local c = LRU.new({ max_size = 5 })
    c:set("a", 1)
    c:get("a"); c:get("a")  -- 2 hits
    c:get("x"); c:get("y")  -- 2 misses
    local s = c:stats()
    -- 2 / (2+2) = 0.5
    T.ok(math.abs(s.hit_rate - 0.5) < 1e-9)
  end)

  T.it("hit_rate is 0 with no lookups", function()
    local c = LRU.new({ max_size = 5 })
    T.eq(c:hit_rate(), 0)
    T.eq(c:stats().hit_rate, 0)
  end)

  T.it("reset_stats zeroes all counters", function()
    local c = LRU.new({ max_size = 2 })
    c:set("a", 1); c:set("b", 2); c:set("c", 3)
    c:get("a"); c:get("z")
    c:reset_stats()
    local s = c:stats()
    T.eq(s.hits, 0); T.eq(s.misses, 0); T.eq(s.sets, 0)
    T.eq(s.deletes, 0); T.eq(s.evictions, 0); T.eq(s.expirations, 0)
    T.eq(s.hit_rate, 0)
  end)

  T.it("evict_expired increments expirations stat", function()
    local now = 1000
    local c = LRU.new({ max_size = 10, default_ttl = 10,
                         clock = function() return now end })
    c:set("a", 1); c:set("b", 2)
    now = 2000
    c:evict_expired()
    T.eq(c:stats().expirations, 2)
  end)

end)

-- ── injectable clock ──────────────────────────────────────────────────────────

T.describe("injectable clock", function()

  T.it("no real os.time() calls when custom clock injected", function()
    local calls = 0
    local fake_time = 500
    local function clock() calls = calls + 1; return fake_time end
    local c = LRU.new({ max_size = 5, default_ttl = 100, clock = clock })
    c:set("k", "v")
    fake_time = 550
    c:get("k")
    fake_time = 601
    c:get("k")  -- expired
    T.ok(calls > 0)
    T.eq(c:size(), 0)
  end)

  T.it("time can be frozen (entries never expire at same time)", function()
    local now = 1000
    local c = LRU.new({ max_size = 5, default_ttl = 60,
                         clock = function() return now end })
    c:set("k", "v")
    -- time frozen — entry should not expire
    T.eq(c:get("k"), "v")
    T.eq(c:get("k"), "v")
  end)

end)

-- ── "set" event ───────────────────────────────────────────────────────────────

T.describe("set event", function()

  T.it("fires on every set call", function()
    local fired = {}
    local c = LRU.new({ max_size = 5 })
    c:on("set", function(k, v) fired[#fired + 1] = { k, v } end)
    c:set("a", 1); c:set("b", 2); c:set("a", 99)
    T.eq(#fired, 3)
    T.eq(fired[1][1], "a"); T.eq(fired[1][2], 1)
    T.eq(fired[3][1], "a"); T.eq(fired[3][2], 99)
  end)

end)
