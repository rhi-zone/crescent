if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local ecs = require("lib.entity_component")

T.describe("entity_component", function()

  -- -------------------------------------------------------------------------
  T.describe("world basics", function()

    T.it("creates independent worlds", function()
      local w1 = ecs.world()
      local w2 = ecs.world()
      w1:register("pos", {x=0, y=0})
      w2:register("pos", {x=0, y=0})
      local e1 = w1:entity()
      w1:add(e1, "pos", {x=5})
      -- w2 has no entities
      T.eq(w1:count(), 1)
      T.eq(w2:count(), 0)
    end)

    T.it("assigns unique sequential IDs", function()
      local w = ecs.world()
      local a = w:entity()
      local b = w:entity()
      local c = w:entity()
      T.ok(a ~= b)
      T.ok(b ~= c)
      T.ok(a ~= c)
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("register + add + get + has", function()

    T.it("registers a component with defaults", function()
      local w = ecs.world()
      w:register("hp", {hp=100, max=100})
      local e = w:entity()
      w:add(e, "hp")
      local c = w:get(e, "hp")
      T.eq(c.hp,  100)
      T.eq(c.max, 100)
    end)

    T.it("merges supplied data with defaults", function()
      local w = ecs.world()
      w:register("hp", {hp=100, max=100})
      local e = w:entity()
      w:add(e, "hp", {hp=50})
      local c = w:get(e, "hp")
      T.eq(c.hp,  50)   -- supplied value
      T.eq(c.max, 100)  -- default filled in
    end)

    T.it("supplied data fully overrides when all fields given", function()
      local w = ecs.world()
      w:register("pos", {x=0, y=0})
      local e = w:entity()
      w:add(e, "pos", {x=3, y=7})
      local c = w:get(e, "pos")
      T.eq(c.x, 3)
      T.eq(c.y, 7)
    end)

    T.it("has() returns true when component present", function()
      local w = ecs.world()
      w:register("vel", {x=0, y=0})
      local e = w:entity()
      w:add(e, "vel", {x=1})
      T.ok(w:has(e, "vel"))
    end)

    T.it("has() returns false when component absent", function()
      local w = ecs.world()
      w:register("vel", {x=0, y=0})
      local e = w:entity()
      T.ok(not w:has(e, "vel"))
    end)

    T.it("get() returns nil when component absent", function()
      local w = ecs.world()
      w:register("vel", {x=0, y=0})
      local e = w:entity()
      T.eq(w:get(e, "vel"), nil)
    end)

    T.it("tag component (no defaults) stores empty table", function()
      local w = ecs.world()
      w:register("tag")
      local e = w:entity()
      w:add(e, "tag")
      T.ok(w:has(e, "tag"))
    end)

    T.it("add returns error for unregistered component", function()
      local w = ecs.world()
      local e = w:entity()
      local ok, err = w:add(e, "nonexistent")
      T.eq(ok, nil)
      T.ok(err ~= nil)
    end)

    T.it("add returns error for dead entity", function()
      local w = ecs.world()
      w:register("pos", {x=0})
      local e = w:entity()
      w:destroy(e)
      local ok, err = w:add(e, "pos")
      T.eq(ok, nil)
      T.ok(err ~= nil)
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("remove", function()

    T.it("removes a component from an entity", function()
      local w = ecs.world()
      w:register("vel", {x=0, y=0})
      local e = w:entity()
      w:add(e, "vel", {x=2})
      w:remove(e, "vel")
      T.ok(not w:has(e, "vel"))
      T.eq(w:get(e, "vel"), nil)
    end)

    T.it("entity with removed component excluded from queries", function()
      local w = ecs.world()
      w:register("pos", {x=0, y=0})
      w:register("vel", {x=0, y=0})
      local e = w:entity()
      w:add(e, "pos", {x=1})
      w:add(e, "vel", {x=1})
      w:remove(e, "vel")
      local count = 0
      for _ in w:query("pos", "vel") do count = count + 1 end
      T.eq(count, 0)
    end)

    T.it("remove is a no-op when component absent", function()
      local w = ecs.world()
      w:register("pos", {x=0})
      local e = w:entity()
      w:remove(e, "pos")  -- should not error
      T.ok(not w:has(e, "pos"))
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("destroy", function()

    T.it("removes entity from all component stores", function()
      local w = ecs.world()
      w:register("pos", {x=0, y=0})
      w:register("vel", {x=0, y=0})
      local e = w:entity()
      w:add(e, "pos", {x=1})
      w:add(e, "vel", {x=2})
      w:destroy(e)
      T.ok(not w:has(e, "pos"))
      T.ok(not w:has(e, "vel"))
    end)

    T.it("destroyed entity does not appear in queries", function()
      local w = ecs.world()
      w:register("pos", {x=0, y=0})
      local e1 = w:entity()
      local e2 = w:entity()
      w:add(e1, "pos", {x=1})
      w:add(e2, "pos", {x=2})
      w:destroy(e1)
      local found = {}
      for e in w:query("pos") do found[e] = true end
      T.ok(not found[e1])
      T.ok(found[e2])
    end)

    T.it("destroy is idempotent", function()
      local w = ecs.world()
      local e = w:entity()
      w:destroy(e)
      w:destroy(e)  -- should not error
      T.eq(w:count(), 0)
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("query", function()

    T.it("returns only entities with ALL queried components", function()
      local w = ecs.world()
      w:register("pos", {x=0})
      w:register("vel", {x=0})
      w:register("hp",  {hp=100})
      local e1 = w:entity(); w:add(e1, "pos"); w:add(e1, "vel")
      local e2 = w:entity(); w:add(e2, "pos")
      local e3 = w:entity(); w:add(e3, "pos"); w:add(e3, "vel"); w:add(e3, "hp")

      local results = {}
      for e in w:query("pos", "vel") do results[#results+1] = e end
      table.sort(results)
      T.eq(#results, 2)
      T.eq(results[1], e1)
      T.eq(results[2], e3)
    end)

    T.it("yields component tables as extra return values", function()
      local w = ecs.world()
      w:register("pos", {x=0, y=0})
      w:register("vel", {vx=0, vy=0})
      local e = w:entity()
      w:add(e, "pos", {x=3, y=4})
      w:add(e, "vel", {vx=1, vy=2})
      for _, pos, vel in w:query("pos", "vel") do
        T.eq(pos.x,  3)
        T.eq(pos.y,  4)
        T.eq(vel.vx, 1)
        T.eq(vel.vy, 2)
      end
    end)

    T.it("query over unregistered component returns nothing", function()
      local w = ecs.world()
      local count = 0
      for _ in w:query("ghost") do count = count + 1 end
      T.eq(count, 0)
    end)

    T.it("mutations via query iterator are reflected in get()", function()
      local w = ecs.world()
      w:register("pos", {x=0, y=0})
      w:register("vel", {x=1, y=0})
      local e = w:entity()
      w:add(e, "pos", {x=10, y=0})
      w:add(e, "vel", {x=3,  y=1})
      for _, pos, vel in w:query("pos", "vel") do
        pos.x = pos.x + vel.x
        pos.y = pos.y + vel.y
      end
      local p = w:get(e, "pos")
      T.eq(p.x, 13)
      T.eq(p.y, 1)
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("count", function()

    T.it("count() returns total living entities", function()
      local w = ecs.world()
      w:register("pos", {x=0})
      T.eq(w:count(), 0)
      local e1 = w:entity()
      T.eq(w:count(), 1)
      w:entity()
      T.eq(w:count(), 2)
      w:destroy(e1)
      T.eq(w:count(), 1)
    end)

    T.it("count(name) returns entities with that component", function()
      local w = ecs.world()
      w:register("pos", {x=0})
      w:register("vel", {x=0})
      local e1 = w:entity(); w:add(e1, "pos")
      local e2 = w:entity(); w:add(e2, "pos"); w:add(e2, "vel")
      w:entity()
      T.eq(w:count("pos"), 2)
      T.eq(w:count("vel"), 1)
    end)

    T.it("count(name) on unregistered component returns 0", function()
      local w = ecs.world()
      T.eq(w:count("ghost"), 0)
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("systems", function()

    T.it("system runs fn over matching entities", function()
      local w = ecs.world()
      w:register("pos", {x=0, y=0})
      w:register("vel", {x=0, y=0})
      local e1 = w:entity(); w:add(e1, "pos", {x=0}); w:add(e1, "vel", {x=2, y=1})
      local e2 = w:entity(); w:add(e2, "pos", {x=5})   -- no vel, should be skipped

      local move = w:system({"pos", "vel"}, function(e, pos, vel, dt)
        pos.x = pos.x + vel.x * dt
        pos.y = pos.y + vel.y * dt
      end)
      w:run(move, 0.5)

      local p1 = w:get(e1, "pos")
      T.eq(p1.x, 1.0)
      T.eq(p1.y, 0.5)
      -- e2 pos unchanged
      local p2 = w:get(e2, "pos")
      T.eq(p2.x, 5)
    end)

    T.it("system with no matching entities runs cleanly", function()
      local w = ecs.world()
      w:register("pos", {x=0})
      w:register("vel", {x=0})
      local called = false
      local sys = w:system({"pos", "vel"}, function() called = true end)
      w:run(sys)
      T.ok(not called)
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("events", function()

    T.it("entity_created fires on world:entity()", function()
      local w = ecs.world()
      local fired = {}
      w:on("entity_created", function(e) fired[#fired+1] = e end)
      local e = w:entity()
      T.eq(#fired, 1)
      T.eq(fired[1], e)
    end)

    T.it("component_added fires on world:add()", function()
      local w = ecs.world()
      w:register("pos", {x=0})
      local log = {}
      w:on("component_added", function(e, name) log[#log+1] = {e, name} end)
      local e = w:entity()
      w:add(e, "pos")
      T.eq(#log, 1)
      T.eq(log[1][1], e)
      T.eq(log[1][2], "pos")
    end)

    T.it("component_removed fires on world:remove()", function()
      local w = ecs.world()
      w:register("vel", {x=0})
      local log = {}
      w:on("component_removed", function(e, name) log[#log+1] = {e, name} end)
      local e = w:entity()
      w:add(e, "vel")
      w:remove(e, "vel")
      -- last log entry is from remove (first was not from remove)
      local found = false
      for _, entry in ipairs(log) do
        if entry[1] == e and entry[2] == "vel" then found = true end
      end
      T.ok(found)
    end)

    T.it("entity_destroyed fires on world:destroy()", function()
      local w = ecs.world()
      local log = {}
      w:on("entity_destroyed", function(e) log[#log+1] = e end)
      local e = w:entity()
      w:destroy(e)
      T.eq(#log, 1)
      T.eq(log[1], e)
    end)

    T.it("component_removed fires for each component on destroy", function()
      local w = ecs.world()
      w:register("pos", {x=0})
      w:register("vel", {x=0})
      local removed = {}
      w:on("component_removed", function(_, name) removed[name] = true end)
      local e = w:entity()
      w:add(e, "pos")
      w:add(e, "vel")
      w:destroy(e)
      T.ok(removed["pos"])
      T.ok(removed["vel"])
    end)

    T.it("custom events fire via emit", function()
      local w = ecs.world()
      local got = {}
      w:on("level_up", function(e, lvl) got[#got+1] = {e, lvl} end)
      w:emit("level_up", 42, 5)
      T.eq(#got, 1)
      T.eq(got[1][1], 42)
      T.eq(got[1][2], 5)
    end)

    T.it("multiple listeners on same event all fire", function()
      local w = ecs.world()
      local a, b = 0, 0
      w:on("tick", function() a = a + 1 end)
      w:on("tick", function() b = b + 1 end)
      w:emit("tick")
      w:emit("tick")
      T.eq(a, 2)
      T.eq(b, 2)
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("clear", function()

    T.it("removes all entities", function()
      local w = ecs.world()
      w:register("pos", {x=0})
      for _ = 1, 5 do
        local e = w:entity()
        w:add(e, "pos")
      end
      T.eq(w:count(), 5)
      w:clear()
      T.eq(w:count(), 0)
      T.eq(w:count("pos"), 0)
    end)

    T.it("clear fires entity_destroyed for each entity", function()
      local w = ecs.world()
      local destroyed = 0
      w:on("entity_destroyed", function() destroyed = destroyed + 1 end)
      for _ = 1, 3 do w:entity() end
      w:clear()
      T.eq(destroyed, 3)
    end)

    T.it("world is reusable after clear", function()
      local w = ecs.world()
      w:register("pos", {x=0})
      local e = w:entity(); w:add(e, "pos", {x=99})
      w:clear()
      local e2 = w:entity(); w:add(e2, "pos", {x=7})
      T.eq(w:count(), 1)
      T.eq(w:get(e2, "pos").x, 7)
    end)

  end)

end)
