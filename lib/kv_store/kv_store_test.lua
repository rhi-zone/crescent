-- lib/kv_store/kv_store_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local KV = require("lib.kv_store")

-- ── basic set/get/has/delete ──────────────────────────────────────────────────

T.describe("basic operations", function()
  T.it("set and get a value", function()
    local s = KV.new()
    s:set("x", 42)
    T.eq(s:get("x"), 42)
  end)

  T.it("get returns nil for missing key", function()
    local s = KV.new()
    T.eq(s:get("missing"), nil)
  end)

  T.it("has returns true for existing key", function()
    local s = KV.new()
    s:set("a", true)
    T.ok(s:has("a"))
  end)

  T.it("has returns false for missing key", function()
    local s = KV.new()
    T.ok(not s:has("nope"))
  end)

  T.it("delete removes a key and returns true", function()
    local s = KV.new()
    s:set("k", "v")
    T.ok(s:delete("k"))
    T.eq(s:get("k"), nil)
  end)

  T.it("delete returns false for missing key", function()
    local s = KV.new()
    T.ok(not s:delete("nonexistent"))
  end)

  T.it("overwrite value", function()
    local s = KV.new()
    s:set("k", 1)
    s:set("k", 2)
    T.eq(s:get("k"), 2)
  end)

  T.it("set stores tables", function()
    local s = KV.new()
    local tbl = { name = "alice", age = 30 }
    s:set("user", tbl)
    T.eq(s:get("user"), tbl)
  end)
end)

-- ── TTL expiry ────────────────────────────────────────────────────────────────

T.describe("TTL expiry", function()
  T.it("get returns value before expiry", function()
    local t = 1000
    local s = KV.new({ clock = function() return t end })
    s:set("k", "v", { ttl = 10 })
    T.eq(s:get("k"), "v")
  end)

  T.it("get returns nil after expiry", function()
    local t = 1000
    local s = KV.new({ clock = function() return t end })
    s:set("k", "v", { ttl = 10 })
    t = 1011
    T.eq(s:get("k"), nil)
  end)

  T.it("has returns false after expiry", function()
    local t = 1000
    local s = KV.new({ clock = function() return t end })
    s:set("k", "v", { ttl = 5 })
    t = 1006
    T.ok(not s:has("k"))
  end)

  T.it("expired key counts as deleted", function()
    local t = 1000
    local s = KV.new({ clock = function() return t end })
    s:set("k", "v", { ttl = 5 })
    t = 1006
    T.ok(s:delete("k"))  -- existed before expiry check cleans it up
  end)

  T.it("set without opts does not clear existing TTL", function()
    local t = 1000
    local s = KV.new({ clock = function() return t end })
    s:set("k", "v", { ttl = 10 })
    s:set("k", "v2")  -- no opts: preserve existing expiry
    t = 1011
    T.eq(s:get("k"), nil)  -- still expires
  end)

  T.it("set with opts={} clears TTL", function()
    local t = 1000
    local s = KV.new({ clock = function() return t end })
    s:set("k", "v", { ttl = 10 })
    s:set("k", "v2", {})  -- opts present but no ttl: clear expiry
    t = 1011
    T.eq(s:get("k"), "v2")  -- should not expire
  end)
end)

-- ── set_many / get_many ───────────────────────────────────────────────────────

T.describe("set_many and get_many", function()
  T.it("set_many stores multiple keys", function()
    local s = KV.new()
    s:set_many({ a = 1, b = 2, c = 3 })
    T.eq(s:get("a"), 1)
    T.eq(s:get("b"), 2)
    T.eq(s:get("c"), 3)
  end)

  T.it("get_many returns table of results", function()
    local s = KV.new()
    s:set_many({ x = 10, y = 20 })
    local r = s:get_many({ "x", "y", "z" })
    T.eq(r["x"], 10)
    T.eq(r["y"], 20)
    T.eq(r["z"], nil)
  end)

  T.it("set_many with TTL", function()
    local t = 1000
    local s = KV.new({ clock = function() return t end })
    s:set_many({ p = 1, q = 2 }, { ttl = 5 })
    t = 1006
    T.eq(s:get("p"), nil)
    T.eq(s:get("q"), nil)
  end)
end)

-- ── expire / ttl / persist ────────────────────────────────────────────────────

T.describe("expire, ttl, persist", function()
  T.it("expire sets TTL on existing key", function()
    local t = 1000
    local s = KV.new({ clock = function() return t end })
    s:set("k", "v")
    T.ok(s:expire("k", 10))
    t = 1011
    T.eq(s:get("k"), nil)
  end)

  T.it("expire returns false for missing key", function()
    local s = KV.new()
    T.ok(not s:expire("nope", 10))
  end)

  T.it("ttl returns remaining seconds", function()
    local t = 1000
    local s = KV.new({ clock = function() return t end })
    s:set("k", "v", { ttl = 30 })
    t = 1010
    T.eq(s:ttl("k"), 20)
  end)

  T.it("ttl returns nil for key with no expiry", function()
    local s = KV.new()
    s:set("k", "v")
    T.eq(s:ttl("k"), nil)
  end)

  T.it("ttl returns nil for missing key", function()
    local s = KV.new()
    T.eq(s:ttl("nope"), nil)
  end)

  T.it("persist removes TTL", function()
    local t = 1000
    local s = KV.new({ clock = function() return t end })
    s:set("k", "v", { ttl = 10 })
    T.ok(s:persist("k"))
    T.eq(s:ttl("k"), nil)
    t = 1011
    T.eq(s:get("k"), "v")  -- still alive
  end)

  T.it("persist returns false if no TTL set", function()
    local s = KV.new()
    s:set("k", "v")
    T.ok(not s:persist("k"))
  end)

  T.it("persist returns false for missing key", function()
    local s = KV.new()
    T.ok(not s:persist("nope"))
  end)
end)

-- ── incr / decr ───────────────────────────────────────────────────────────────

T.describe("incr and decr", function()
  T.it("incr initializes to 1 for missing key", function()
    local s = KV.new()
    T.eq(s:incr("c"), 1)
  end)

  T.it("incr increments by 1 by default", function()
    local s = KV.new()
    s:set("c", 5)
    T.eq(s:incr("c"), 6)
  end)

  T.it("incr increments by n", function()
    local s = KV.new()
    s:set("c", 10)
    T.eq(s:incr("c", 5), 15)
  end)

  T.it("decr decrements by 1 by default", function()
    local s = KV.new()
    s:set("c", 10)
    T.eq(s:decr("c"), 9)
  end)

  T.it("decr decrements by n", function()
    local s = KV.new()
    s:set("c", 10)
    T.eq(s:decr("c", 3), 7)
  end)

  T.it("incr returns nil, errmsg on non-number value", function()
    local s = KV.new()
    s:set("k", "not a number")
    local v, err = s:incr("k")
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("incr on expired key reinitializes to 1", function()
    local t = 1000
    local s = KV.new({ clock = function() return t end })
    s:set("c", 99, { ttl = 5 })
    t = 1006
    T.eq(s:incr("c"), 1)
  end)

  T.it("incr preserves TTL", function()
    local t = 1000
    local s = KV.new({ clock = function() return t end })
    s:set("c", 1, { ttl = 20 })
    s:incr("c")
    T.eq(s:get("c"), 2)
    -- TTL preserved: advance past and check
    t = 1021
    T.eq(s:get("c"), nil)
  end)
end)

-- ── keys / values / size / clear / each ──────────────────────────────────────

T.describe("iteration and inspection", function()
  T.it("keys returns all unexpired keys", function()
    local s = KV.new()
    s:set("a", 1)
    s:set("b", 2)
    local ks = s:keys()
    table.sort(ks)
    T.eq(ks[1], "a")
    T.eq(ks[2], "b")
    T.eq(#ks, 2)
  end)

  T.it("keys excludes expired keys", function()
    local t = 1000
    local s = KV.new({ clock = function() return t end })
    s:set("a", 1, { ttl = 5 })
    s:set("b", 2)
    t = 1006
    local ks = s:keys()
    T.eq(#ks, 1)
    T.eq(ks[1], "b")
  end)

  T.it("values returns all unexpired values", function()
    local s = KV.new()
    s:set("a", 10)
    s:set("b", 20)
    local vs = s:values()
    table.sort(vs)
    T.eq(vs[1], 10)
    T.eq(vs[2], 20)
    T.eq(#vs, 2)
  end)

  T.it("size returns correct count", function()
    local s = KV.new()
    s:set("a", 1)
    s:set("b", 2)
    s:set("c", 3)
    T.eq(s:size(), 3)
  end)

  T.it("size excludes expired keys", function()
    local t = 1000
    local s = KV.new({ clock = function() return t end })
    s:set("x", 1, { ttl = 5 })
    s:set("y", 2)
    t = 1006
    T.eq(s:size(), 1)
  end)

  T.it("clear removes all keys", function()
    local s = KV.new()
    s:set("a", 1)
    s:set("b", 2)
    s:clear()
    T.eq(s:size(), 0)
    T.eq(s:get("a"), nil)
  end)

  T.it("each iterates over all unexpired keys", function()
    local s = KV.new()
    s:set("a", 1)
    s:set("b", 2)
    local seen = {}
    s:each(function(k, v) seen[k] = v end)
    T.eq(seen["a"], 1)
    T.eq(seen["b"], 2)
  end)

  T.it("each skips expired keys", function()
    local t = 1000
    local s = KV.new({ clock = function() return t end })
    s:set("x", 1, { ttl = 5 })
    s:set("y", 2)
    t = 1006
    local seen = {}
    s:each(function(k, v) seen[k] = v end)
    T.eq(seen["x"], nil)
    T.eq(seen["y"], 2)
  end)
end)

-- ── namespaces ────────────────────────────────────────────────────────────────

T.describe("namespaces", function()
  T.it("namespace set/get uses prefixed key", function()
    local s = KV.new()
    local ns = s:namespace("users")
    ns:set("alice", { age = 30 })
    T.eq(ns:get("alice"), s:get("users:alice"))
  end)

  T.it("namespace get returns nil for missing key", function()
    local s = KV.new()
    local ns = s:namespace("users")
    T.eq(ns:get("nobody"), nil)
  end)

  T.it("namespace has works", function()
    local s = KV.new()
    local ns = s:namespace("ns")
    ns:set("k", "v")
    T.ok(ns:has("k"))
    T.ok(not ns:has("other"))
  end)

  T.it("namespace delete works", function()
    local s = KV.new()
    local ns = s:namespace("ns")
    ns:set("k", "v")
    T.ok(ns:delete("k"))
    T.eq(ns:get("k"), nil)
  end)

  T.it("namespace keys returns unprefixed keys", function()
    local s = KV.new()
    local ns = s:namespace("ns")
    ns:set("a", 1)
    ns:set("b", 2)
    s:set("other", 99)  -- should not appear
    local ks = ns:keys()
    table.sort(ks)
    T.eq(#ks, 2)
    T.eq(ks[1], "a")
    T.eq(ks[2], "b")
  end)

  T.it("namespace size counts only prefixed keys", function()
    local s = KV.new()
    local ns = s:namespace("ns")
    ns:set("a", 1)
    ns:set("b", 2)
    s:set("other", 99)
    T.eq(ns:size(), 2)
  end)

  T.it("namespace values returns only ns values", function()
    local s = KV.new()
    local ns = s:namespace("x")
    ns:set("p", 10)
    ns:set("q", 20)
    s:set("other", 99)
    local vs = ns:values()
    table.sort(vs)
    T.eq(#vs, 2)
    T.eq(vs[1], 10)
    T.eq(vs[2], 20)
  end)

  T.it("namespace clear removes only ns keys", function()
    local s = KV.new()
    local ns = s:namespace("ns")
    ns:set("a", 1)
    ns:set("b", 2)
    s:set("keep", 99)
    ns:clear()
    T.eq(ns:size(), 0)
    T.eq(s:get("keep"), 99)
  end)

  T.it("namespace ttl and expire", function()
    local t = 1000
    local s = KV.new({ clock = function() return t end })
    local ns = s:namespace("ns")
    ns:set("k", "v", { ttl = 20 })
    t = 1010
    T.eq(ns:ttl("k"), 10)
    T.ok(ns:expire("k", 50))
    T.eq(ns:ttl("k"), 50)
  end)

  T.it("namespace persist", function()
    local t = 1000
    local s = KV.new({ clock = function() return t end })
    local ns = s:namespace("ns")
    ns:set("k", "v", { ttl = 10 })
    T.ok(ns:persist("k"))
    T.eq(ns:ttl("k"), nil)
  end)

  T.it("namespace each iterates ns keys only", function()
    local s = KV.new()
    local ns = s:namespace("ns")
    ns:set("a", 1)
    ns:set("b", 2)
    s:set("other", 99)
    local seen = {}
    ns:each(function(k, v) seen[k] = v end)
    T.eq(seen["a"], 1)
    T.eq(seen["b"], 2)
    T.eq(seen["other"], nil)
  end)

  T.it("namespace incr/decr work", function()
    local s = KV.new()
    local ns = s:namespace("counters")
    T.eq(ns:incr("hits"), 1)
    T.eq(ns:incr("hits", 4), 5)
    T.eq(ns:decr("hits", 2), 3)
  end)
end)

-- ── pub/sub callbacks ─────────────────────────────────────────────────────────

T.describe("on_set and on_del callbacks", function()
  T.it("on_set fires on set", function()
    local s = KV.new()
    local fired = {}
    s:on_set(function(k, v) fired[k] = v end)
    s:set("a", 42)
    T.eq(fired["a"], 42)
  end)

  T.it("on_set fires on set_many", function()
    local s = KV.new()
    local count = 0
    s:on_set(function() count = count + 1 end)
    s:set_many({ a = 1, b = 2 })
    T.eq(count, 2)
  end)

  T.it("on_set fires on incr", function()
    local s = KV.new()
    local last_val
    s:on_set(function(k, v) last_val = v end)
    s:incr("c", 3)
    T.eq(last_val, 3)
  end)

  T.it("on_del fires on delete", function()
    local s = KV.new()
    local deleted = {}
    s:on_del(function(k) deleted[k] = true end)
    s:set("x", 1)
    s:delete("x")
    T.ok(deleted["x"])
  end)

  T.it("on_del fires on clear", function()
    local s = KV.new()
    local deleted = {}
    s:on_del(function(k) deleted[k] = true end)
    s:set("a", 1)
    s:set("b", 2)
    s:clear()
    T.ok(deleted["a"])
    T.ok(deleted["b"])
  end)

  T.it("on_del fires on TTL expiry via get", function()
    local t = 1000
    local s = KV.new({ clock = function() return t end })
    local deleted = {}
    s:on_del(function(k) deleted[k] = true end)
    s:set("k", "v", { ttl = 5 })
    t = 1006
    s:get("k")  -- triggers expiry cleanup
    T.ok(deleted["k"])
  end)

  T.it("multiple on_set callbacks all fire", function()
    local s = KV.new()
    local a, b = 0, 0
    s:on_set(function() a = a + 1 end)
    s:on_set(function() b = b + 1 end)
    s:set("k", "v")
    T.eq(a, 1)
    T.eq(b, 1)
  end)

  T.it("namespace on_set fires with unprefixed key", function()
    local s = KV.new()
    local ns = s:namespace("ns")
    local fired_key, fired_val
    ns:on_set(function(k, v) fired_key = k; fired_val = v end)
    ns:set("hello", "world")
    T.eq(fired_key, "hello")
    T.eq(fired_val, "world")
  end)

  T.it("namespace on_del fires with unprefixed key", function()
    local s = KV.new()
    local ns = s:namespace("ns")
    local fired_key
    ns:on_del(function(k) fired_key = k end)
    ns:set("bye", "v")
    ns:delete("bye")
    T.eq(fired_key, "bye")
  end)
end)

-- ── _tier ─────────────────────────────────────────────────────────────────────

T.describe("module metadata", function()
  T.it("_tier is 'pure'", function()
    T.eq(KV._tier, "pure")
  end)
end)
