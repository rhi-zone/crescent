if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local ch = require("lib.consistent_hash")

T.describe("consistent_hash", function()

  T.it("empty ring returns nil for get_node", function()
    local ring = ch.new()
    T.eq(ring:get_node("somekey"), nil)
  end)

  T.it("empty ring returns empty array for get_nodes", function()
    local ring = ch.new()
    local nodes = ring:get_nodes("somekey", 3)
    T.eq(#nodes, 0)
  end)

  T.it("node_count is 0 for empty ring", function()
    local ring = ch.new()
    T.eq(ring:node_count(), 0)
  end)

  T.it("nodes() returns empty array for empty ring", function()
    local ring = ch.new()
    T.eq(#ring:nodes(), 0)
  end)

  T.it("single node: all keys map to it", function()
    local ring = ch.new()
    ring:add_node("node1")
    T.eq(ring:get_node("foo"), "node1")
    T.eq(ring:get_node("bar"), "node1")
    T.eq(ring:get_node("baz"), "node1")
    T.eq(ring:get_node(""), "node1")
    T.eq(ring:get_node("hello world"), "node1")
  end)

  T.it("single node: node_count is 1", function()
    local ring = ch.new()
    ring:add_node("node1")
    T.eq(ring:node_count(), 1)
  end)

  T.it("single node: nodes() returns it", function()
    local ring = ch.new()
    ring:add_node("node1")
    local nodes = ring:nodes()
    T.eq(#nodes, 1)
    T.eq(nodes[1], "node1")
  end)

  T.it("two nodes: keys distributed between them", function()
    local ring = ch.new()
    ring:add_node("nodeA")
    ring:add_node("nodeB")
    -- collect which nodes we actually see
    local seen = {}
    for i = 1, 200 do
      local node = ring:get_node("key" .. i)
      seen[node] = true
    end
    T.ok(seen["nodeA"], "nodeA should get some keys")
    T.ok(seen["nodeB"], "nodeB should get some keys")
  end)

  T.it("two nodes: node_count is 2", function()
    local ring = ch.new()
    ring:add_node("nodeA")
    ring:add_node("nodeB")
    T.eq(ring:node_count(), 2)
  end)

  T.it("add_node is idempotent", function()
    local ring = ch.new()
    ring:add_node("nodeA")
    ring:add_node("nodeA")
    T.eq(ring:node_count(), 1)
    local nodes = ring:nodes()
    T.eq(#nodes, 1)
  end)

  T.it("remove_node: ring goes empty", function()
    local ring = ch.new()
    ring:add_node("node1")
    ring:remove_node("node1")
    T.eq(ring:node_count(), 0)
    T.eq(ring:get_node("anykey"), nil)
  end)

  T.it("remove_node: nonexistent node is a no-op", function()
    local ring = ch.new()
    ring:add_node("node1")
    ring:remove_node("ghost")
    T.eq(ring:node_count(), 1)
  end)

  T.it("deterministic: same key always maps to same node", function()
    local ring = ch.new()
    ring:add_node("alpha")
    ring:add_node("beta")
    ring:add_node("gamma")
    for i = 1, 50 do
      local key = "testkey" .. i
      local first = ring:get_node(key)
      for _ = 1, 5 do
        T.eq(ring:get_node(key), first)
      end
    end
  end)

  T.it("get_nodes returns N distinct nodes", function()
    local ring = ch.new()
    ring:add_node("n1")
    ring:add_node("n2")
    ring:add_node("n3")
    ring:add_node("n4")
    local nodes = ring:get_nodes("somekey", 3)
    T.eq(#nodes, 3)
    -- verify distinctness
    local seen = {}
    for i = 1, #nodes do
      T.ok(not seen[nodes[i]], "duplicate node in get_nodes result")
      seen[nodes[i]] = true
    end
  end)

  T.it("get_nodes with n=1 returns same as get_node", function()
    local ring = ch.new()
    ring:add_node("n1")
    ring:add_node("n2")
    ring:add_node("n3")
    local key = "testkey"
    local nodes = ring:get_nodes(key, 1)
    T.eq(#nodes, 1)
    T.eq(nodes[1], ring:get_node(key))
  end)

  T.it("get_nodes with fewer nodes than requested returns all available", function()
    local ring = ch.new()
    ring:add_node("only1")
    ring:add_node("only2")
    local nodes = ring:get_nodes("anykey", 5)
    T.eq(#nodes, 2)
  end)

  T.it("get_nodes with n=0 returns empty", function()
    local ring = ch.new()
    ring:add_node("n1")
    local nodes = ring:get_nodes("key", 0)
    T.eq(#nodes, 0)
  end)

  T.it("nodes() returns sorted array", function()
    local ring = ch.new()
    ring:add_node("charlie")
    ring:add_node("alpha")
    ring:add_node("bravo")
    local nodes = ring:nodes()
    T.eq(#nodes, 3)
    T.eq(nodes[1], "alpha")
    T.eq(nodes[2], "bravo")
    T.eq(nodes[3], "charlie")
  end)

  T.it("distribution: 10 nodes, 10000 keys, each gets 5-20%", function()
    local ring = ch.new({replicas = 150})
    for i = 1, 10 do
      ring:add_node("node" .. i)
    end
    local keys = {}
    for i = 1, 10000 do
      keys[i] = "key:" .. i
    end
    local dist = ring:distribution(keys)
    local total = 0
    for name, count in pairs(dist) do
      total = total + count
      local pct = count / 10000
      T.ok(pct >= 0.05 and pct <= 0.20,
        "node " .. name .. " got " .. string.format("%.1f%%", pct*100) ..
        " (expected 5-20%)")
    end
    T.eq(total, 10000)
  end)

  T.it("removing a node: only its keys get remapped", function()
    local ring = ch.new({replicas = 150})
    ring:add_node("A")
    ring:add_node("B")
    ring:add_node("C")

    -- build mapping before removal
    local before = {}
    for i = 1, 300 do
      local key = "k" .. i
      before[key] = ring:get_node(key)
    end

    ring:remove_node("B")

    local remapped = 0
    local wrongly_remapped = 0
    for i = 1, 300 do
      local key = "k" .. i
      local after = ring:get_node(key)
      if before[key] == "B" then
        -- should be remapped to A or C
        T.ok(after == "A" or after == "C",
          "key that was on B should go to A or C")
        remapped = remapped + 1
      else
        -- should stay on same node
        if after ~= before[key] then
          wrongly_remapped = wrongly_remapped + 1
        end
      end
    end
    T.ok(remapped > 0, "some keys were on B and should have moved")
    T.eq(wrongly_remapped, 0)
  end)

  T.it("adding a node remaps only some keys", function()
    local ring = ch.new({replicas = 150})
    ring:add_node("X")
    ring:add_node("Y")

    local before = {}
    for i = 1, 300 do
      local key = "k" .. i
      before[key] = ring:get_node(key)
    end

    ring:add_node("Z")

    local changed = 0
    for i = 1, 300 do
      local key = "k" .. i
      local after = ring:get_node(key)
      if after ~= before[key] then
        T.eq(after, "Z") -- new node should be the destination
        changed = changed + 1
      end
    end
    T.ok(changed > 0, "some keys should have moved to new node Z")
    T.ok(changed < 300, "not all keys should have moved")
  end)

  T.it("custom replicas option affects ring", function()
    local ring = ch.new({replicas = 5})
    ring:add_node("n1")
    ring:add_node("n2")
    -- 5 replicas * 2 nodes = 10 virtual nodes
    T.eq(ring:node_count(), 2)
    -- still works
    T.ok(ring:get_node("key") ~= nil)
  end)

end)
