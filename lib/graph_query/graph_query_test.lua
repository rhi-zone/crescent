if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local gq = require("lib.graph_query")

-- ---------------------------------------------------------------------------
-- Shared test graph
--
--  alice (age=30, role=admin)
--  bob   (age=25, role=user)
--  carol (age=35, role=admin)
--  dave  (age=40, role=user)   -- isolated in same component as alice via direct edge
--
--  alice -[follows,w=1]-> bob
--  bob   -[follows,w=2]-> carol
--  alice -[friend, w=3]-> carol
--  alice -[follows,w=1]-> dave
-- ---------------------------------------------------------------------------

local function make_graph()
  local g = gq.graph()
  g:node("alice", {age=30, role="admin"})
  g:node("bob",   {age=25, role="user"})
  g:node("carol", {age=35, role="admin"})
  g:node("dave",  {age=40, role="user"})
  g:edge("alice", "bob",   {type="follows", weight=1})
  g:edge("bob",   "carol", {type="follows", weight=2})
  g:edge("alice", "carol", {type="friend",  weight=3})
  g:edge("alice", "dave",  {type="follows", weight=1})
  return g
end

-- ---------------------------------------------------------------------------
T.describe("graph_query: node filters", function()

  T.it("filter by property table", function()
    local g = make_graph()
    local q = gq.query(g)
    local admins = q:nodes({role="admin"}):collect()
    T.eq(#admins, 2)
    -- Verify both alice and carol appear
    local found = {}
    for _, row in ipairs(admins) do found[row[1]] = true end
    T.ok(found["alice"])
    T.ok(found["carol"])
  end)

  T.it("filter by predicate", function()
    local g = make_graph()
    local q = gq.query(g)
    local old = q:nodes(function(_, d) return d.age > 28 end):collect()
    -- alice (30), carol (35), dave (40) => 3
    T.eq(#old, 3)
    local found = {}
    for _, row in ipairs(old) do found[row[1]] = true end
    T.ok(found["alice"])
    T.ok(found["carol"])
    T.ok(found["dave"])
  end)

  T.it("collect/count/each/map/filter on NodeResult", function()
    local g = make_graph()
    local q = gq.query(g)
    local res = q:nodes({role="admin"})
    T.eq(res:count(), 2)

    local ids = {}
    res:each(function(id, _) ids[#ids+1] = id end)
    T.eq(#ids, 2)

    local ages = res:map(function(_, d) return d.age end)
    T.eq(#ages, 2)

    local old_admins = res:filter(function(_, d) return d.age > 30 end)
    T.eq(old_admins:count(), 1)

    local fid, fdata = res:first()
    T.ok(fid ~= nil)
    T.ok(fdata ~= nil)
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("graph_query: edge filters", function()

  T.it("filter edges by property table", function()
    local g = make_graph()
    local q = gq.query(g)
    local follows = q:edges({type="follows"}):collect()
    -- alice->bob, bob->carol, alice->dave = 3 follows edges
    T.eq(#follows, 3)
    for _, e in ipairs(follows) do
      T.eq(e[3].type, "follows")
    end
  end)

  T.it("collect/count/each/map/filter on EdgeResult", function()
    local g = make_graph()
    local q = gq.query(g)
    local res = q:edges({type="follows"})
    T.eq(res:count(), 3)

    local pairs_list = {}
    res:each(function(from, to, _) pairs_list[#pairs_list+1] = {from, to} end)
    T.eq(#pairs_list, 3)

    local weights = res:map(function(_, _, d) return d.weight end)
    T.eq(#weights, 3)

    local heavy = res:filter(function(_, _, d) return d.weight >= 2 end)
    T.eq(heavy:count(), 1)

    local f, t, fd = res:first()
    T.ok(f ~= nil and t ~= nil and fd ~= nil)
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("graph_query: path finding", function()

  T.it("finds all simple paths alice->carol at max_depth 2", function()
    local g = make_graph()
    local q = gq.query(g)
    local paths = q:path("alice", "carol", {max_depth=2}):collect()
    -- alice->carol (direct) and alice->bob->carol
    T.eq(#paths, 2)
    local found_direct = false
    local found_two    = false
    for _, p in ipairs(paths) do
      if #p == 2 and p[1] == "alice" and p[2] == "carol" then found_direct = true end
      if #p == 3 and p[1] == "alice" and p[2] == "bob" and p[3] == "carol" then found_two = true end
    end
    T.ok(found_direct)
    T.ok(found_two)
  end)

  T.it("no path when max_depth is too small", function()
    local g = make_graph()
    local q = gq.query(g)
    -- bob->carol exists (length 1), but bob->alice requires reverse; no path bob->dave
    local paths = q:path("bob", "dave", {max_depth=5}):collect()
    T.eq(#paths, 0)
  end)

  T.it("path result count/each/first", function()
    local g = make_graph()
    local q = gq.query(g)
    local pr = q:path("alice", "carol", {max_depth=2})
    T.ok(pr:count() >= 1)
    local seen = 0
    pr:each(function(_) seen = seen + 1 end)
    T.eq(seen, pr:count())
    T.ok(pr:first() ~= nil)
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("graph_query: reachable", function()

  T.it("alice can reach bob, carol, dave", function()
    local g = make_graph()
    local q = gq.query(g)
    local r = q:reachable("alice")
    T.ok(r["bob"])
    T.ok(r["carol"])
    T.ok(r["dave"])
    T.ok(r["alice"] == nil)  -- self excluded
  end)

  T.it("respects max_depth", function()
    local g = make_graph()
    local q = gq.query(g)
    -- depth=1: alice reaches bob, carol, dave (all direct)
    local r1 = q:reachable("alice", {max_depth=1})
    T.ok(r1["bob"])
    T.ok(r1["carol"])
    T.ok(r1["dave"])
    -- depth=0: nobody
    local r0 = q:reachable("alice", {max_depth=0})
    T.ok(r0["bob"] == nil)
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("graph_query: neighbors", function()

  T.it("depth-1 neighbors of bob (out)", function()
    local g = make_graph()
    local q = gq.query(g)
    local nbs = q:neighbors("bob", {depth=1}):collect()
    -- bob -> carol only
    T.eq(#nbs, 1)
    T.eq(nbs[1][1], "carol")
  end)

  T.it("depth-2 neighbors of alice (out)", function()
    local g = make_graph()
    local q = gq.query(g)
    -- depth 1: bob, carol, dave
    -- depth 2 additions: carol (already at depth 1 via alice->carol)
    local nbs = q:neighbors("alice", {depth=2}):collect()
    T.eq(#nbs, 3)  -- bob, carol, dave
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("graph_query: connected_components", function()

  T.it("two components: main cluster + isolated node", function()
    local g = gq.graph()
    g:node("a", {})
    g:node("b", {})
    g:edge("a", "b", {})
    g:node("x", {})  -- isolated

    local q = gq.query(g)
    local comps = q:connected_components()
    T.eq(#comps, 2)

    -- Sizes: one comp has 2 nodes, other has 1
    local sizes = {}
    for _, c in ipairs(comps) do sizes[#sizes+1] = #c end
    table.sort(sizes)
    T.eq(sizes[1], 1)
    T.eq(sizes[2], 2)
  end)

  T.it("fully connected graph has one component", function()
    local g = make_graph()
    local q = gq.query(g)
    local comps = q:connected_components()
    T.eq(#comps, 1)
    T.eq(#comps[1], 4)
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("graph_query: density", function()

  T.it("complete directed graph K3 has density 1", function()
    local g = gq.graph()
    g:node("a", {}); g:node("b", {}); g:node("c", {})
    g:edge("a","b",{}); g:edge("a","c",{})
    g:edge("b","a",{}); g:edge("b","c",{})
    g:edge("c","a",{}); g:edge("c","b",{})
    local q = gq.query(g)
    T.eq(q:density(), 1.0)
  end)

  T.it("sparse graph has lower density", function()
    local g = make_graph()  -- 4 nodes, 4 directed edges; max=4*3=12
    local q = gq.query(g)
    local d = q:density()
    T.ok(d > 0 and d < 1)
    -- 4/12 = 0.333...
    T.ok(math.abs(d - 4/12) < 1e-9)
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("graph_query: pagerank", function()

  T.it("ranks sum to approximately 1", function()
    local g = make_graph()
    local q = gq.query(g)
    local pr = q:pagerank({damping=0.85, iterations=50})
    local total = 0
    for _, v in pairs(pr) do total = total + v end
    T.ok(math.abs(total - 1.0) < 0.01)
  end)

  T.it("more-linked node has higher rank", function()
    local g = make_graph()
    local q = gq.query(g)
    local pr = q:pagerank({damping=0.85, iterations=50})
    -- carol is pointed to by both alice and bob; should rank higher than dave
    T.ok(pr["carol"] > pr["dave"])
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("graph_query: clustering_coefficient", function()

  T.it("triangle node has coefficient 1", function()
    -- a-b-c-a forms a triangle
    local g = gq.graph()
    g:node("a",{}); g:node("b",{}); g:node("c",{})
    g:edge("a","b",{}); g:edge("b","a",{})
    g:edge("b","c",{}); g:edge("c","b",{})
    g:edge("a","c",{}); g:edge("c","a",{})

    local q  = gq.query(g)
    local cc = q:clustering_coefficient()
    -- Every node has 2 neighbors that are connected to each other
    T.ok(math.abs(cc["a"] - 1.0) < 1e-9)
    T.ok(math.abs(cc["b"] - 1.0) < 1e-9)
    T.ok(math.abs(cc["c"] - 1.0) < 1e-9)
  end)

  T.it("isolated node has coefficient 0", function()
    local g = gq.graph()
    g:node("x", {})
    local q  = gq.query(g)
    local cc = q:clustering_coefficient()
    T.eq(cc["x"], 0)
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("graph_query: degree_distribution", function()

  T.it("correct in/out degrees for main graph", function()
    local g = make_graph()
    local q = gq.query(g)
    local dd = q:degree_distribution()

    -- alice: out=3 (bob,carol,dave), in=0
    T.eq(dd["alice"].out_deg, 3)
    T.eq(dd["alice"].in_deg,  0)

    -- bob: out=1 (carol), in=1 (alice)
    T.eq(dd["bob"].out_deg, 1)
    T.eq(dd["bob"].in_deg,  1)

    -- carol: out=0, in=2 (alice,bob)
    T.eq(dd["carol"].out_deg, 0)
    T.eq(dd["carol"].in_deg,  2)

    -- dave: out=0, in=1 (alice)
    T.eq(dd["dave"].out_deg, 0)
    T.eq(dd["dave"].in_deg,  1)
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("graph_query: pattern matching", function()

  T.it("detects follows-follows-friend triangle", function()
    -- Find (A)-[:follows]->(B)-[:follows]->(C) + (A)-[:friend]->(C)
    local g = make_graph()
    local q = gq.query(g)
    local matches = q:pattern({
      nodes = {"A","B","C"},
      edges = {
        {"A","B","follows"},
        {"B","C","follows"},
        {"A","C","friend"},
      },
    }):collect()
    -- Only alice->bob->carol + alice->carol(friend) satisfies this
    T.eq(#matches, 1)
    T.eq(matches[1]["A"], "alice")
    T.eq(matches[1]["B"], "bob")
    T.eq(matches[1]["C"], "carol")
  end)

  T.it("no match when pattern cannot be satisfied", function()
    local g = make_graph()
    local q = gq.query(g)
    local matches = q:pattern({
      nodes = {"X","Y"},
      edges = {{"X","Y","nonexistent"}},
    }):collect()
    T.eq(#matches, 0)
  end)

  T.it("pattern result count/each/first", function()
    local g = make_graph()
    local q = gq.query(g)
    local mr = q:pattern({
      nodes = {"A","B"},
      edges = {{"A","B","follows"}},
    })
    -- alice->bob, alice->dave, bob->carol  = 3 matches
    T.ok(mr:count() >= 1)
    local seen = 0
    mr:each(function(_) seen = seen + 1 end)
    T.eq(seen, mr:count())
    T.ok(mr:first() ~= nil)
  end)

end)

-- ---------------------------------------------------------------------------
T.describe("graph_query: direct graph methods", function()

  T.it("QGraph exposes query methods directly", function()
    local g = make_graph()
    -- g:nodes() is the query version when called with a filter
    -- (QGraph.nodes with no args delegates to Query, which returns all nodes)
    local admins = g:nodes({role="admin"}):collect()
    T.eq(#admins, 2)
  end)

end)
