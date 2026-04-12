-- lib/service_registry/service_registry_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local SR = require("lib.service_registry")

-- ── Module shape ─────────────────────────────────────────────────────────────

T.describe("service_registry: module shape", function()
  T.it("exports new and _tier", function()
    T.eq(type(SR.new), "function", "SR.new is a function")
    T.eq(SR._tier, "pure", "_tier is pure")
  end)
end)

-- ── register / discover ───────────────────────────────────────────────────────

T.describe("service_registry: register/discover", function()
  T.it("instance found after register", function()
    local reg = SR.new()
    local id = reg:register("db", { host = "localhost", port = 5432 })
    T.ok(id ~= nil, "register returns an id")
    local instances = reg:discover("db")
    T.eq(#instances, 1, "one instance found")
    T.eq(instances[1].id, id, "instance id matches")
    T.eq(instances[1].host, "localhost", "host matches")
    T.eq(instances[1].port, 5432, "port matches")
    T.eq(instances[1].name, "db", "name matches")
  end)

  T.it("discover returns empty for unknown service", function()
    local reg = SR.new()
    local instances = reg:discover("unknown")
    T.eq(#instances, 0, "empty for unknown service")
  end)

  T.it("multiple instances registered separately", function()
    local reg = SR.new()
    reg:register("api", { host = "h1", port = 80 })
    reg:register("api", { host = "h2", port = 80 })
    local instances = reg:discover("api")
    T.eq(#instances, 2, "two instances found")
  end)

  T.it("id format contains service name", function()
    local reg = SR.new()
    local id = reg:register("cache", { host = "c1", port = 6379 })
    T.ok(id:find("cache", 1, true) ~= nil, "id contains service name")
  end)

  T.it("instance has registered_at and last_seen", function()
    local t = 1000
    local reg = SR.new({ clock = function() return t end })
    reg:register("svc", { host = "h", port = 1 })
    local inst = reg:discover("svc")[1]
    T.eq(inst.registered_at, 1000, "registered_at set")
    T.eq(inst.last_seen, 1000, "last_seen set")
  end)

  T.it("meta and tags stored on instance", function()
    local reg = SR.new()
    reg:register("svc", {
      host = "h", port = 9,
      meta = { region = "us-east" },
      tags = { "v1", "canary" },
    })
    local inst = reg:discover("svc")[1]
    T.eq(inst.meta.region, "us-east", "meta.region")
    T.eq(inst.tags[1], "v1", "tags[1]")
    T.eq(inst.tags[2], "canary", "tags[2]")
  end)
end)

-- ── deregister ────────────────────────────────────────────────────────────────

T.describe("service_registry: deregister", function()
  T.it("instance gone after deregister", function()
    local reg = SR.new()
    local id = reg:register("db", { host = "h", port = 1 })
    reg:deregister(id)
    local instances = reg:discover("db")
    T.eq(#instances, 0, "no instances after deregister")
  end)

  T.it("deregister only removes the specified id", function()
    local reg = SR.new()
    local id1 = reg:register("db", { host = "h1", port = 1 })
    reg:register("db", { host = "h2", port = 2 })
    reg:deregister(id1)
    local instances = reg:discover("db")
    T.eq(#instances, 1, "one instance remains")
    T.neq(instances[1].id, id1, "remaining instance is not the deregistered one")
  end)
end)

-- ── deregister_all ────────────────────────────────────────────────────────────

T.describe("service_registry: deregister_all", function()
  T.it("all instances of service removed", function()
    local reg = SR.new()
    reg:register("db", { host = "h1", port = 1 })
    reg:register("db", { host = "h2", port = 2 })
    reg:register("db", { host = "h3", port = 3 })
    reg:deregister_all("db")
    local instances = reg:discover("db")
    T.eq(#instances, 0, "no instances after deregister_all")
  end)

  T.it("deregister_all does not affect other services", function()
    local reg = SR.new()
    reg:register("db", { host = "h1", port = 1 })
    reg:register("api", { host = "h2", port = 80 })
    reg:deregister_all("db")
    local api_instances = reg:discover("api")
    T.eq(#api_instances, 1, "api instance still present")
  end)

  T.it("deregister_all on nonexistent service is safe", function()
    local reg = SR.new()
    -- should not error
    reg:deregister_all("nonexistent")
    T.ok(true, "no error on nonexistent service")
  end)
end)

-- ── healthy / unhealthy ───────────────────────────────────────────────────────

T.describe("service_registry: healthy/unhealthy", function()
  T.it("unhealthy instance excluded from discover", function()
    local reg = SR.new()
    local id = reg:register("db", { host = "h", port = 1 })
    reg:unhealthy(id)
    local instances = reg:discover("db")
    T.eq(#instances, 0, "unhealthy not in discover")
  end)

  T.it("healthy restores instance to discover", function()
    local reg = SR.new()
    local id = reg:register("db", { host = "h", port = 1 })
    reg:unhealthy(id)
    reg:healthy(id)
    local instances = reg:discover("db")
    T.eq(#instances, 1, "healthy instance back in discover")
  end)

  T.it("healthy updates last_seen", function()
    local t = 1000
    local reg = SR.new({ clock = function() return t end })
    local id = reg:register("svc", { host = "h", port = 1 })
    t = 2000
    reg:healthy(id)
    local inst = reg:discover("svc")[1]
    T.eq(inst.last_seen, 2000, "last_seen updated by healthy")
  end)

  T.it("mixed healthy/unhealthy: only healthy returned", function()
    local reg = SR.new()
    local id1 = reg:register("db", { host = "h1", port = 1 })
    reg:register("db", { host = "h2", port = 2 })
    reg:unhealthy(id1)
    local instances = reg:discover("db")
    T.eq(#instances, 1, "only one healthy instance returned")
    T.neq(instances[1].id, id1, "the unhealthy instance is excluded")
  end)
end)

-- ── heartbeat ─────────────────────────────────────────────────────────────────

T.describe("service_registry: heartbeat", function()
  T.it("heartbeat updates last_seen", function()
    local t = 1000
    local reg = SR.new({ clock = function() return t end })
    local id = reg:register("svc", { host = "h", port = 1 })
    t = 5000
    reg:heartbeat(id)
    local inst = reg:discover("svc")[1]
    T.eq(inst.last_seen, 5000, "last_seen updated by heartbeat")
  end)

  T.it("heartbeat on unknown id returns nil,err", function()
    local reg = SR.new()
    local result, err = reg:heartbeat("nonexistent#99")
    T.eq(result, nil, "nil returned")
    T.ok(err ~= nil, "error message returned")
  end)
end)

-- ── TTL expiry ────────────────────────────────────────────────────────────────

T.describe("service_registry: TTL expiry", function()
  T.it("instance removed after TTL via discover", function()
    local t = 1000
    local reg = SR.new({ clock = function() return t end, ttl = 30 })
    reg:register("svc", { host = "h", port = 1 })
    -- advance past TTL
    t = 1031
    local instances = reg:discover("svc")
    T.eq(#instances, 0, "expired instance not returned")
  end)

  T.it("instance still present just before TTL expires", function()
    local t = 1000
    local reg = SR.new({ clock = function() return t end, ttl = 30 })
    reg:register("svc", { host = "h", port = 1 })
    t = 1029  -- last_seen(1000) + ttl(30) = 1030; 1029 < 1030 → not expired
    local instances = reg:discover("svc")
    T.eq(#instances, 1, "instance present before TTL")
  end)

  T.it("heartbeat prevents expiry", function()
    local t = 1000
    local reg = SR.new({ clock = function() return t end, ttl = 30 })
    local id = reg:register("svc", { host = "h", port = 1 })
    t = 1020
    reg:heartbeat(id)  -- last_seen = 1020
    t = 1045           -- 1020 + 30 = 1050; 1045 < 1050 → not expired
    local instances = reg:discover("svc")
    T.eq(#instances, 1, "heartbeated instance not expired")
  end)

  T.it("evict_expired fires expired event", function()
    local t = 1000
    local reg = SR.new({ clock = function() return t end, ttl = 30 })
    local events = {}
    reg:register("svc", { host = "h", port = 1 })
    reg:watch("svc", function(ev, inst)
      events[#events + 1] = ev
    end)
    t = 1031
    reg:evict_expired()
    T.eq(events[#events], "expired", "expired event fired")
  end)
end)

-- ── get with round-robin ──────────────────────────────────────────────────────

T.describe("service_registry: get round-robin", function()
  T.it("cycles through instances", function()
    local reg = SR.new()
    -- register three instances and collect their ids in discovery order
    reg:register("api", { host = "h1", port = 1 })
    reg:register("api", { host = "h2", port = 2 })
    reg:register("api", { host = "h3", port = 3 })
    local seen = {}
    for _ = 1, 9 do
      local inst = reg:get("api")
      seen[inst.id] = (seen[inst.id] or 0) + 1
    end
    -- each id should appear exactly 3 times in 9 round-robin calls
    local total = 0
    for _, count in pairs(seen) do
      total = total + count
    end
    T.eq(total, 9, "9 total picks")
    -- each of the 3 instances should appear 3 times
    local keys = 0
    for _ in pairs(seen) do keys = keys + 1 end
    T.eq(keys, 3, "all 3 instances were selected")
  end)

  T.it("returns nil,err for no healthy instances", function()
    local reg = SR.new()
    local inst, err = reg:get("missing")
    T.eq(inst, nil, "nil returned")
    T.ok(err ~= nil, "error message returned")
  end)
end)

-- ── get with random ───────────────────────────────────────────────────────────

T.describe("service_registry: get random", function()
  T.it("returns a valid instance", function()
    local reg = SR.new()
    reg:register("api", { host = "h1", port = 1 })
    reg:register("api", { host = "h2", port = 2 })
    local inst, err = reg:get("api", "random")
    T.ok(inst ~= nil, "instance returned")
    T.eq(err, nil, "no error")
    T.ok(inst.host == "h1" or inst.host == "h2", "valid host returned")
  end)

  T.it("random with one instance always returns that instance", function()
    local reg = SR.new()
    local id = reg:register("solo", { host = "h1", port = 1 })
    for _ = 1, 5 do
      local inst = reg:get("solo", "random")
      T.eq(inst.id, id, "only instance always selected")
    end
  end)
end)

-- ── get with least_conn ───────────────────────────────────────────────────────

T.describe("service_registry: get least_conn", function()
  T.it("returns instance with fewest connections", function()
    local reg = SR.new()
    local id1 = reg:register("api", { host = "h1", port = 1 })
    local id2 = reg:register("api", { host = "h2", port = 2 })
    reg:connection_open(id1)
    reg:connection_open(id1)
    reg:connection_open(id2)
    -- id2 has 1 conn, id1 has 2: should pick id2
    local inst = reg:get("api", "least_conn")
    T.eq(inst.id, id2, "instance with fewest connections selected")
  end)

  T.it("least_conn with equal connections: deterministic by id", function()
    local reg = SR.new()
    reg:register("api", { host = "h1", port = 1 })
    reg:register("api", { host = "h2", port = 2 })
    -- both have 0 connections; result should be consistent
    local inst1 = reg:get("api", "least_conn")
    local inst2 = reg:get("api", "least_conn")
    T.eq(inst1.id, inst2.id, "same instance picked when equal connections")
  end)
end)

-- ── connection_open / connection_close ────────────────────────────────────────

T.describe("service_registry: connection tracking", function()
  T.it("connection_open increments active_connections", function()
    local reg = SR.new()
    local id = reg:register("svc", { host = "h", port = 1 })
    reg:connection_open(id)
    reg:connection_open(id)
    local inst = reg:discover("svc")[1]
    T.eq(inst.active_connections, 2, "active_connections = 2")
  end)

  T.it("connection_close decrements active_connections", function()
    local reg = SR.new()
    local id = reg:register("svc", { host = "h", port = 1 })
    reg:connection_open(id)
    reg:connection_open(id)
    reg:connection_close(id)
    local inst = reg:discover("svc")[1]
    T.eq(inst.active_connections, 1, "active_connections = 1 after close")
  end)

  T.it("connection_close does not go below zero", function()
    local reg = SR.new()
    local id = reg:register("svc", { host = "h", port = 1 })
    reg:connection_close(id)
    local inst = reg:discover("svc")[1]
    T.eq(inst.active_connections, 0, "active_connections stays at 0")
  end)

  T.it("connection_open on unknown id returns nil,err", function()
    local reg = SR.new()
    local result, err = reg:connection_open("ghost#1")
    T.eq(result, nil, "nil result")
    T.ok(err ~= nil, "error returned")
  end)
end)

-- ── watch / unwatch ───────────────────────────────────────────────────────────

T.describe("service_registry: watch", function()
  T.it("callback fires on register", function()
    local reg = SR.new()
    local events = {}
    reg:watch("db", function(ev, inst)
      events[#events + 1] = { ev = ev, id = inst.id }
    end)
    local id = reg:register("db", { host = "h", port = 1 })
    T.eq(#events, 1, "one event fired")
    T.eq(events[1].ev, "register", "event is register")
    T.eq(events[1].id, id, "event has correct id")
  end)

  T.it("callback fires on deregister", function()
    local reg = SR.new()
    local events = {}
    local id = reg:register("db", { host = "h", port = 1 })
    reg:watch("db", function(ev, _)
      events[#events + 1] = ev
    end)
    reg:deregister(id)
    T.ok(#events >= 1, "at least one event fired")
    T.eq(events[#events], "deregister", "deregister event fired")
  end)

  T.it("callback fires on healthy", function()
    local reg = SR.new()
    local events = {}
    local id = reg:register("db", { host = "h", port = 1 })
    reg:watch("db", function(ev, _)
      events[#events + 1] = ev
    end)
    reg:unhealthy(id)
    reg:healthy(id)
    -- last two events: unhealthy, healthy
    T.ok(#events >= 2, "at least 2 events")
    T.eq(events[#events], "healthy", "last event is healthy")
  end)

  T.it("callback fires on unhealthy", function()
    local reg = SR.new()
    local events = {}
    local id = reg:register("db", { host = "h", port = 1 })
    reg:watch("db", function(ev, _)
      events[#events + 1] = ev
    end)
    reg:unhealthy(id)
    T.eq(events[#events], "unhealthy", "unhealthy event fired")
  end)

  T.it("callback fires on deregister_all", function()
    local reg = SR.new()
    local events = {}
    reg:register("db", { host = "h1", port = 1 })
    reg:register("db", { host = "h2", port = 2 })
    reg:watch("db", function(ev, _)
      events[#events + 1] = ev
    end)
    reg:deregister_all("db")
    T.eq(#events, 2, "two deregister events fired")
    T.eq(events[1], "deregister", "first event is deregister")
    T.eq(events[2], "deregister", "second event is deregister")
  end)

  T.it("unwatch stops callbacks", function()
    local reg = SR.new()
    local events = {}
    local unwatch = reg:watch("db", function(ev, _)
      events[#events + 1] = ev
    end)
    reg:register("db", { host = "h", port = 1 })
    T.eq(#events, 1, "event fired before unwatch")
    unwatch()
    reg:register("db", { host = "h2", port = 2 })
    T.eq(#events, 1, "no more events after unwatch")
  end)

  T.it("multiple watchers all receive events", function()
    local reg = SR.new()
    local count1, count2 = 0, 0
    reg:watch("svc", function() count1 = count1 + 1 end)
    reg:watch("svc", function() count2 = count2 + 1 end)
    reg:register("svc", { host = "h", port = 1 })
    T.eq(count1, 1, "watcher 1 received event")
    T.eq(count2, 1, "watcher 2 received event")
  end)
end)

-- ── tags filtering ────────────────────────────────────────────────────────────

T.describe("service_registry: tags filtering", function()
  T.it("discover with tags filter returns only matching instances", function()
    local reg = SR.new()
    reg:register("api", { host = "h1", port = 1, tags = { "v2", "production" } })
    reg:register("api", { host = "h2", port = 2, tags = { "v1", "production" } })
    local v2 = reg:discover("api", { tags = { "v2" } })
    T.eq(#v2, 1, "one v2 instance")
    T.eq(v2[1].host, "h1", "correct instance returned")
  end)

  T.it("multi-tag filter requires all tags", function()
    local reg = SR.new()
    reg:register("api", { host = "h1", port = 1, tags = { "v2", "canary" } })
    reg:register("api", { host = "h2", port = 2, tags = { "v2", "production" } })
    local result = reg:discover("api", { tags = { "v2", "canary" } })
    T.eq(#result, 1, "only instance with both tags returned")
    T.eq(result[1].host, "h1", "correct instance")
  end)

  T.it("no tag filter returns all healthy instances", function()
    local reg = SR.new()
    reg:register("api", { host = "h1", port = 1, tags = { "v2" } })
    reg:register("api", { host = "h2", port = 2, tags = { "v1" } })
    local all = reg:discover("api")
    T.eq(#all, 2, "all instances returned without tag filter")
  end)

  T.it("empty tags filter returns all healthy instances", function()
    local reg = SR.new()
    reg:register("api", { host = "h1", port = 1, tags = { "v2" } })
    reg:register("api", { host = "h2", port = 2, tags = { "v1" } })
    local all = reg:discover("api", { tags = {} })
    T.eq(#all, 2, "all instances returned with empty tags filter")
  end)

  T.it("tag filter with no match returns empty", function()
    local reg = SR.new()
    reg:register("api", { host = "h1", port = 1, tags = { "v1" } })
    local result = reg:discover("api", { tags = { "v99" } })
    T.eq(#result, 0, "no instances match unknown tag")
  end)
end)

-- ── services() ───────────────────────────────────────────────────────────────

T.describe("service_registry: services()", function()
  T.it("lists all known service names", function()
    local reg = SR.new()
    reg:register("alpha", { host = "h", port = 1 })
    reg:register("beta", { host = "h", port = 2 })
    reg:register("gamma", { host = "h", port = 3 })
    local names = reg:services()
    T.eq(#names, 3, "three services listed")
    -- sorted alphabetically
    T.eq(names[1], "alpha", "first: alpha")
    T.eq(names[2], "beta", "second: beta")
    T.eq(names[3], "gamma", "third: gamma")
  end)

  T.it("empty registry returns empty list", function()
    local reg = SR.new()
    local names = reg:services()
    T.eq(#names, 0, "no services initially")
  end)

  T.it("registering same service twice does not duplicate", function()
    local reg = SR.new()
    reg:register("db", { host = "h1", port = 1 })
    reg:register("db", { host = "h2", port = 2 })
    local names = reg:services()
    T.eq(#names, 1, "service listed once")
    T.eq(names[1], "db", "service name is db")
  end)
end)

-- ── stats() ──────────────────────────────────────────────────────────────────

T.describe("service_registry: stats()", function()
  T.it("correct total count", function()
    local reg = SR.new()
    reg:register("db", { host = "h1", port = 1 })
    reg:register("db", { host = "h2", port = 2 })
    reg:register("api", { host = "h3", port = 80 })
    local stats = reg:stats()
    T.eq(stats.total, 3, "total = 3")
  end)

  T.it("correct healthy/unhealthy counts", function()
    local reg = SR.new()
    local id1 = reg:register("db", { host = "h1", port = 1 })
    reg:register("db", { host = "h2", port = 2 })
    reg:unhealthy(id1)
    local stats = reg:stats()
    T.eq(stats.healthy, 1, "healthy = 1")
    T.eq(stats.unhealthy, 1, "unhealthy = 1")
  end)

  T.it("per-service stats populated", function()
    local reg = SR.new()
    local id1 = reg:register("db", { host = "h1", port = 1 })
    reg:register("db", { host = "h2", port = 2 })
    reg:unhealthy(id1)
    local stats = reg:stats()
    T.ok(stats.by_service["db"] ~= nil, "by_service.db present")
    T.eq(stats.by_service["db"].total, 2, "db total = 2")
    T.eq(stats.by_service["db"].healthy, 1, "db healthy = 1")
  end)

  T.it("empty registry returns zero stats", function()
    local reg = SR.new()
    local stats = reg:stats()
    T.eq(stats.total, 0, "total = 0")
    T.eq(stats.healthy, 0, "healthy = 0")
    T.eq(stats.unhealthy, 0, "unhealthy = 0")
  end)

  T.it("all healthy when no unhealthy called", function()
    local reg = SR.new()
    reg:register("svc", { host = "h1", port = 1 })
    reg:register("svc", { host = "h2", port = 2 })
    local stats = reg:stats()
    T.eq(stats.total, 2, "total = 2")
    T.eq(stats.healthy, 2, "healthy = 2")
    T.eq(stats.unhealthy, 0, "unhealthy = 0")
  end)
end)
