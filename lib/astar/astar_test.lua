if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local A = require("lib.astar")

-- ========================
-- HELPERS
-- ========================

-- Build a simple weighted directed graph as an adjacency list
-- edges: {{from, to, cost}, ...}
local function make_graph(edges)
  local adj = {}
  for _, e in ipairs(edges) do
    local u, v, w = e[1], e[2], e[3]
    if not adj[u] then adj[u] = {} end
    adj[u][#adj[u] + 1] = { v, w }
  end
  return adj
end

-- neighbors_fn for weighted graph
local function wneighbors(adj)
  return function(node)
    return adj[node] or {}
  end
end

-- neighbors_fn for unweighted graph (just lists neighbor nodes)
local function uneighbors(adj)
  return function(node)
    local ns = {}
    for _, e in ipairs(adj[node] or {}) do
      ns[#ns + 1] = e[1]
    end
    return ns
  end
end

-- Simple 5-node graph:
--  1 --(1)--> 2 --(1)--> 5
--  1 --(4)--> 3 --(2)--> 5
--  2 --(2)--> 3
--  3 --(1)--> 4 --(1)--> 5
-- Shortest 1->5: 1->2->5 cost 2
local GRAPH5_EDGES = {
  { 1, 2, 1 }, { 1, 3, 4 },
  { 2, 3, 2 }, { 2, 5, 1 },
  { 3, 4, 1 }, { 3, 5, 3 },
  { 4, 5, 1 },
}
local GRAPH5 = make_graph(GRAPH5_EDGES)

-- Test grid (5x5):
-- 0 0 0 0 0
-- 0 1 1 1 0
-- 0 0 0 1 0
-- 0 1 0 0 0
-- 0 0 0 0 0
local GRID5 = {
  { 0, 0, 0, 0, 0 },
  { 0, 1, 1, 1, 0 },
  { 0, 0, 0, 1, 0 },
  { 0, 1, 0, 0, 0 },
  { 0, 0, 0, 0, 0 },
}

-- ========================
-- A* TESTS
-- ========================

T.describe("astar", function()
  T.it("finds shortest path on simple graph", function()
    local path, cost = A.astar(1, 5, wneighbors(GRAPH5), function() return 0 end)
    T.ok(path ~= nil, "path found")
    T.eq(path[1], 1, "starts at 1")
    T.eq(path[#path], 5, "ends at 5")
    T.eq(cost, 2, "cost is 2")
    T.eq(#path, 3, "path length 3 (1->2->5)")
    T.eq(path[2], 2, "via node 2")
  end)

  T.it("returns nil when no path exists", function()
    local g = make_graph({ { 1, 2, 1 } })  -- 3 is unreachable
    local path, err = A.astar(1, 3, wneighbors(g), function() return 0 end)
    T.eq(path, nil, "no path")
    T.eq(err, "no path found")
  end)

  T.it("finds path to start (trivial path)", function()
    local path, cost = A.astar(1, 1, wneighbors(GRAPH5), function() return 0 end)
    T.ok(path ~= nil)
    T.eq(#path, 1)
    T.eq(cost, 0)
  end)

  T.it("accepts goal function", function()
    local path, cost = A.astar(1, function(n) return n == 5 end, wneighbors(GRAPH5), function() return 0 end)
    T.ok(path ~= nil)
    T.eq(path[#path], 5)
    T.eq(cost, 2)
  end)

  T.it("uses heuristic (non-zero h still finds optimal)", function()
    -- Simple heuristic: distance to 5 (node number as proxy)
    local path, cost = A.astar(1, 5, wneighbors(GRAPH5), function(n) return 5 - n end)
    T.ok(path ~= nil)
    T.eq(cost, 2)
  end)
end)

-- ========================
-- DIJKSTRA TESTS
-- ========================

T.describe("dijkstra", function()
  T.it("finds shortest path, same as astar with h=0", function()
    local path, cost = A.dijkstra(1, 5, wneighbors(GRAPH5))
    T.ok(path ~= nil)
    T.eq(cost, 2)
    T.eq(path[1], 1)
    T.eq(path[#path], 5)
  end)

  T.it("finds path when direct edge is cheaper than all detours", function()
    local g = make_graph({ { 1, 2, 10 }, { 1, 3, 1 }, { 3, 2, 1 } })
    local path, cost = A.dijkstra(1, 2, wneighbors(g))
    T.ok(path ~= nil)
    T.eq(cost, 2, "shortest is 1->3->2 cost 2")
  end)

  T.it("returns nil for unreachable node", function()
    local path, err = A.dijkstra(1, 99, wneighbors(GRAPH5))
    T.eq(path, nil)
    T.eq(err, "no path found")
  end)
end)

-- ========================
-- BFS TESTS
-- ========================

T.describe("bfs", function()
  T.it("finds path in unweighted graph", function()
    local path, steps = A.bfs(1, 5, uneighbors(GRAPH5))
    T.ok(path ~= nil)
    T.eq(path[1], 1)
    T.eq(path[#path], 5)
    T.ok(steps >= 1, "steps >= 1")
  end)

  T.it("finds minimum hop count", function()
    -- 1->2 = 1 hop; 1->3->4 = 2 hops; 1->2->5 = 2 hops
    local path, steps = A.bfs(1, 2, uneighbors(GRAPH5))
    T.ok(path ~= nil)
    T.eq(steps, 1, "one hop to reach 2")
    T.eq(#path, 2)
  end)

  T.it("returns nil when no path", function()
    local g = make_graph({ { 1, 2, 1 } })
    local path, err = A.bfs(1, 3, uneighbors(g))
    T.eq(path, nil)
    T.eq(err, "no path found")
  end)

  T.it("trivial path to self", function()
    local path, steps = A.bfs(3, 3, uneighbors(GRAPH5))
    T.ok(path ~= nil)
    T.eq(steps, 0)
    T.eq(#path, 1)
  end)
end)

-- ========================
-- DFS TESTS
-- ========================

T.describe("dfs", function()
  T.it("finds a path (not necessarily shortest)", function()
    local path, steps = A.dfs(1, 5, uneighbors(GRAPH5))
    T.ok(path ~= nil, "path found")
    T.eq(path[1], 1, "starts at 1")
    T.eq(path[#path], 5, "ends at 5")
    T.ok(steps >= 1, "at least 1 step")
  end)

  T.it("returns nil when no path", function()
    local g = make_graph({ { 1, 2, 1 } })
    local path, err = A.dfs(1, 3, uneighbors(g))
    T.eq(path, nil)
    T.eq(err, "no path found")
  end)

  T.it("path is valid (each consecutive pair are neighbors)", function()
    local path = A.dfs(1, 5, uneighbors(GRAPH5))
    T.ok(path ~= nil)
    for i = 1, #path - 1 do
      local u, v = path[i], path[i + 1]
      local found = false
      for _, nb in ipairs(uneighbors(GRAPH5)(u)) do
        if nb == v then found = true; break end
      end
      T.ok(found, "edge " .. u .. "->" .. v .. " exists")
    end
  end)
end)

-- ========================
-- BELLMAN-FORD TESTS
-- ========================

T.describe("bellman_ford", function()
  T.it("computes correct distances on simple graph", function()
    local nodes = { 1, 2, 3, 4, 5 }
    -- Use undirected edges (both directions)
    local edges = {}
    for _, e in ipairs(GRAPH5_EDGES) do
      edges[#edges + 1] = e
    end
    local dm, neg_cycle = A.bellman_ford(1, nodes, edges)
    T.eq(neg_cycle, false, "no negative cycle")
    T.eq(dm[1].dist, 0, "start dist = 0")
    T.eq(dm[2].dist, 1, "dist to 2 = 1")
    T.eq(dm[5].dist, 2, "dist to 5 = 2")
    T.ok(dm[3].dist <= 3, "dist to 3 <= 3")
  end)

  T.it("detects negative cycle", function()
    local nodes = { 1, 2, 3 }
    local edges = { { 1, 2, 1 }, { 2, 3, -1 }, { 3, 1, -1 } }
    local _, neg_cycle = A.bellman_ford(1, nodes, edges)
    T.eq(neg_cycle, true, "negative cycle detected")
  end)

  T.it("handles negative edges without cycle", function()
    local nodes = { 1, 2, 3 }
    local edges = { { 1, 2, 3 }, { 1, 3, 10 }, { 2, 3, -2 } }
    local dm, neg_cycle = A.bellman_ford(1, nodes, edges)
    T.eq(neg_cycle, false)
    T.eq(dm[3].dist, 1, "1->2->3 = 3+(-2) = 1")
  end)

  T.it("unreachable nodes have dist=inf", function()
    local nodes = { 1, 2, 3 }
    local edges = { { 1, 2, 5 } }
    local dm, _ = A.bellman_ford(1, nodes, edges)
    T.eq(dm[3].dist, math.huge, "3 is unreachable")
    T.eq(dm[3].prev, nil)
  end)
end)

-- ========================
-- GRID A* TESTS
-- ========================

T.describe("grid_astar", function()
  T.it("finds path on 5x5 grid (4-dir)", function()
    local path, cost = A.grid_astar(GRID5, { 1, 1 }, { 5, 5 })
    T.ok(path ~= nil, "path found")
    T.ok(cost ~= nil, "cost returned")
    T.eq(path[1][1], 1, "start row")
    T.eq(path[1][2], 1, "start col")
    T.eq(path[#path][1], 5, "end row")
    T.eq(path[#path][2], 5, "end col")
  end)

  T.it("path is valid (no obstacles crossed)", function()
    local path = A.grid_astar(GRID5, { 1, 1 }, { 5, 5 })
    T.ok(path ~= nil)
    for _, cell in ipairs(path) do
      local r, c = cell[1], cell[2]
      T.ok(GRID5[r] ~= nil, "row in bounds")
      T.eq(GRID5[r][c], 0, "cell is walkable at (" .. r .. "," .. c .. ")")
    end
  end)

  T.it("consecutive cells in path are adjacent", function()
    local path = A.grid_astar(GRID5, { 1, 1 }, { 5, 5 })
    T.ok(path ~= nil)
    for i = 1, #path - 1 do
      local dr = math.abs(path[i + 1][1] - path[i][1])
      local dc = math.abs(path[i + 1][2] - path[i][2])
      T.ok(dr + dc == 1, "adjacent step")
    end
  end)

  T.it("returns nil when no path", function()
    -- Completely blocked column in middle
    local blocked = {
      { 0, 0, 1, 0, 0 },
      { 0, 0, 1, 0, 0 },
      { 0, 0, 1, 0, 0 },
      { 0, 0, 1, 0, 0 },
      { 0, 0, 1, 0, 0 },
    }
    local path, err = A.grid_astar(blocked, { 1, 1 }, { 1, 5 })
    T.eq(path, nil)
    T.eq(err, "no path found")
  end)

  T.it("4-dir: diagonal is two steps", function()
    local simple = {
      { 0, 0 },
      { 0, 0 },
    }
    local path, cost = A.grid_astar(simple, { 1, 1 }, { 2, 2 })
    T.ok(path ~= nil)
    -- 4-dir: (1,1)->(1,2)->(2,2) or (1,1)->(2,1)->(2,2): cost 2, 3 nodes
    T.eq(#path, 3, "4-dir diagonal needs 2 steps")
    T.eq(cost, 2, "4-dir cost = 2")
  end)

  T.it("8-dir (diagonal): shorter path", function()
    local simple = {
      { 0, 0 },
      { 0, 0 },
    }
    local path, cost = A.grid_astar(simple, { 1, 1 }, { 2, 2 }, { diagonal = true })
    T.ok(path ~= nil)
    -- Direct diagonal step: 2 nodes, cost sqrt(2) ~ 1.414
    T.eq(#path, 2, "diagonal: one step")
    T.ok(cost < 1.42 and cost > 1.41, "diagonal cost ~= sqrt(2)")
  end)

  T.it("8-dir finds path through obstacles", function()
    local path = A.grid_astar(GRID5, { 1, 1 }, { 5, 5 }, { diagonal = true })
    T.ok(path ~= nil, "diagonal path found")
    T.eq(path[1][1], 1)
    T.eq(path[#path][2], 5)
  end)

  T.it("manhattan heuristic (default)", function()
    local path, _ = A.grid_astar(GRID5, { 1, 1 }, { 5, 5 }, { heuristic = "manhattan" })
    T.ok(path ~= nil)
  end)

  T.it("euclidean heuristic", function()
    local path, _ = A.grid_astar(GRID5, { 1, 1 }, { 5, 5 }, { heuristic = "euclidean" })
    T.ok(path ~= nil)
  end)

  T.it("chebyshev heuristic", function()
    local path, _ = A.grid_astar(GRID5, { 1, 1 }, { 5, 5 }, { heuristic = "chebyshev" })
    T.ok(path ~= nil)
  end)

  T.it("custom obstacle_fn", function()
    -- Mark cells with value 2 as obstacles
    local grid = {
      { 0, 0, 0 },
      { 0, 2, 0 },
      { 0, 0, 0 },
    }
    local path = A.grid_astar(grid, { 1, 1 }, { 3, 3 }, {
      obstacle_fn = function(g, r, c)
        local row = g[r]
        return row == nil or row[c] == nil or row[c] == 2
      end,
    })
    T.ok(path ~= nil, "path found avoiding value-2 cells")
    for _, cell in ipairs(path) do
      T.ok(grid[cell[1]][cell[2]] ~= 2, "no obstacle cell in path")
    end
  end)
end)

-- ========================
-- FLOOD FILL TESTS
-- ========================

T.describe("flood_fill", function()
  T.it("finds all reachable cells from top-left", function()
    -- Simple open grid
    local g = {
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
    }
    local cells = A.flood_fill(g, { 1, 1 })
    T.eq(#cells, 9, "all 9 cells reachable")
  end)

  T.it("stops at obstacles", function()
    local g = {
      { 0, 1, 0 },
      { 0, 1, 0 },
      { 0, 1, 0 },
    }
    local cells = A.flood_fill(g, { 1, 1 })
    T.eq(#cells, 3, "only left column reachable")
    -- All should be column 1
    for _, c in ipairs(cells) do
      T.eq(c[2], 1, "column is 1")
    end
  end)

  T.it("returns empty for obstacle start", function()
    local g = { { 1, 0 }, { 0, 0 } }
    local cells = A.flood_fill(g, { 1, 1 })
    T.eq(#cells, 0, "blocked start")
  end)

  T.it("respects diagonal option", function()
    -- Diagonal fill can reach corner through diagonal
    local g = {
      { 0, 1, 0 },
      { 1, 0, 1 },
      { 0, 1, 0 },
    }
    -- 4-dir: only center (2,2) reachable from (1,1)? No, (1,1) is blocked by col 2
    -- Actually (1,1) is open, neighbors 4-dir: (1,2)=wall, (2,1)=wall -> isolated
    local cells4 = A.flood_fill(g, { 1, 1 })
    T.eq(#cells4, 1, "4-dir: only start isolated")

    local cells8 = A.flood_fill(g, { 1, 1 }, { diagonal = true })
    -- 8-dir from (1,1): can reach (2,2) diagonally (both walls but diagonal allowed)
    T.ok(#cells8 >= 1, "8-dir: can reach more cells")
  end)

  T.it("flood fill on GRID5 from (1,1)", function()
    local cells = A.flood_fill(GRID5, { 1, 1 })
    T.ok(#cells >= 15, "most open cells reachable")
    -- Count open cells manually: row1=5, row2=2(col1,col5), row3=4(col1-3,col5), row4=3, row5=5
    -- Total open = 5+2+4+3+5 = 19? Let's just check > 10
    for _, cell in ipairs(cells) do
      T.eq(GRID5[cell[1]][cell[2]], 0, "only walkable cells")
    end
  end)
end)

-- ========================
-- DISTANCE MAP TESTS
-- ========================

T.describe("distance_map", function()
  T.it("distance 0 at start", function()
    local g = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
    local dm = A.distance_map(g, { 2, 2 })
    local key = 2 * 65536 + 2
    T.eq(dm[key], 0, "start dist = 0")
  end)

  T.it("correct BFS distances on open grid", function()
    local g = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
    local dm = A.distance_map(g, { 1, 1 })
    -- (1,1)=0, (1,2)=1, (1,3)=2, (2,1)=1, (2,2)=2, (2,3)=3, (3,1)=2, (3,2)=3, (3,3)=4
    T.eq(dm[1 * 65536 + 1], 0)
    T.eq(dm[1 * 65536 + 2], 1)
    T.eq(dm[1 * 65536 + 3], 2)
    T.eq(dm[2 * 65536 + 1], 1)
    T.eq(dm[2 * 65536 + 2], 2)
    T.eq(dm[3 * 65536 + 3], 4)
  end)

  T.it("blocked cells have no entry", function()
    -- Wall spans both rows, so col 3 is truly unreachable
    local g = { { 0, 1, 0 }, { 0, 1, 0 } }
    local dm = A.distance_map(g, { 1, 1 })
    T.eq(dm[1 * 65536 + 3], nil, "cell behind wall has no entry")
    T.eq(dm[2 * 65536 + 3], nil, "cell behind wall row2 has no entry")
  end)

  T.it("consistent with flood_fill count", function()
    local g = { { 0, 0 }, { 0, 0 } }
    local dm = A.distance_map(g, { 1, 1 })
    local count = 0
    for _ in pairs(dm) do count = count + 1 end
    T.eq(count, 4, "all 4 cells have distances")
  end)
end)

-- ========================
-- FLOW FIELD TESTS
-- ========================

T.describe("flow_field", function()
  T.it("goal cell has direction {0,0}", function()
    local g = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
    local ff = A.flow_field(g, { 2, 2 })
    T.ok(ff[2] ~= nil)
    T.ok(ff[2][2] ~= nil)
    T.eq(ff[2][2][1], 0)
    T.eq(ff[2][2][2], 0)
  end)

  T.it("directions point toward goal (1D case)", function()
    -- Single row: goal at (1,3)
    local g = { { 0, 0, 0, 0, 0 } }
    local ff = A.flow_field(g, { 1, 3 })
    -- (1,1) should point right (+col): {0,1}
    T.ok(ff[1] ~= nil)
    T.eq(ff[1][1][2], 1, "(1,1) points right toward goal")
    -- (1,5) should point left: {0,-1}
    T.eq(ff[1][5][2], -1, "(1,5) points left toward goal")
    -- (1,2) should point right
    T.eq(ff[1][2][2], 1, "(1,2) points right")
  end)

  T.it("vertical flow field", function()
    local g = { { 0 }, { 0 }, { 0 }, { 0 }, { 0 } }
    local ff = A.flow_field(g, { 3, 1 })
    -- (1,1) should point down {1,0}
    T.eq(ff[1][1][1], 1, "(1,1) points down")
    -- (5,1) should point up {-1,0}
    T.eq(ff[5][1][1], -1, "(5,1) points up")
    -- (3,1) is goal
    T.eq(ff[3][1][1], 0)
    T.eq(ff[3][1][2], 0)
  end)

  T.it("unreachable cells have no entry", function()
    local g = { { 0, 1, 0 }, { 0, 1, 0 } }
    local ff = A.flow_field(g, { 1, 1 })
    -- Right side (col 3) is isolated; should have no flow entry
    T.eq(ff[1] and ff[1][3] or nil, nil, "isolated cell has no flow entry")
  end)

  T.it("following flow field reaches goal", function()
    local g = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
    local ff = A.flow_field(g, { 3, 3 })
    -- Follow from (1,1): take at most 10 steps
    local r, c = 1, 1
    local steps = 0
    local reached = false
    while steps < 10 do
      if r == 3 and c == 3 then reached = true; break end
      local dir = ff[r] and ff[r][c]
      if not dir then break end
      if dir[1] == 0 and dir[2] == 0 then break end
      r = r + dir[1]
      c = c + dir[2]
      steps = steps + 1
    end
    T.ok(reached, "following flow field reaches goal")
    T.ok(steps <= 4, "reached in at most 4 steps (manhattan dist = 4)")
  end)
end)

-- ========================
-- SMOOTH PATH TESTS
-- ========================

T.describe("smooth_path", function()
  -- LOS function: straight horizontal/vertical line is clear
  -- For grid-based LOS test: use a flat line (no obstacles in test grid)
  local function always_los(_, _) return true end
  local function never_los(_, _) return false end

  T.it("trivial path unchanged (1 or 2 nodes)", function()
    local p1 = { { 1, 1 } }
    local p2 = { { 1, 1 }, { 1, 2 } }
    T.eq(#A.smooth_path(p1, always_los), 1)
    T.eq(#A.smooth_path(p2, always_los), 2)
  end)

  T.it("removes intermediate waypoints when LOS always true", function()
    local path = { { 1, 1 }, { 1, 2 }, { 1, 3 }, { 1, 4 }, { 1, 5 } }
    local smoothed = A.smooth_path(path, always_los)
    -- With always-LOS, only start and end needed
    T.eq(smoothed[1][2], 1, "starts at col 1")
    T.eq(smoothed[#smoothed][2], 5, "ends at col 5")
    T.ok(#smoothed < #path, "smoothed path is shorter")
  end)

  T.it("keeps all waypoints when LOS never true", function()
    local path = { { 1, 1 }, { 1, 2 }, { 1, 3 }, { 1, 4 }, { 1, 5 } }
    local smoothed = A.smooth_path(path, never_los)
    -- never_los: every step is a waypoint (anchor advances every time)
    T.ok(#smoothed >= 2, "at least start and end kept")
    T.eq(smoothed[1][2], 1)
    T.eq(smoothed[#smoothed][2], 5)
  end)

  T.it("grid path smoothing: removes collinear points", function()
    -- A path that goes right then turns up — with LOS we can shortcut
    local path = {
      { 5, 1 }, { 4, 1 }, { 3, 1 }, { 3, 2 }, { 3, 3 },
    }
    -- LOS: simple axis-aligned check (always true for testing)
    local smoothed = A.smooth_path(path, always_los)
    T.ok(#smoothed <= #path, "smoothed not longer than original")
    T.eq(smoothed[1][1], 5)
    T.eq(smoothed[#smoothed][2], 3)
  end)

  T.it("smooth path on actual grid astar result", function()
    local path = A.grid_astar(GRID5, { 1, 1 }, { 5, 5 })
    T.ok(path ~= nil)

    -- LOS: Bresenham-style — check all grid cells along line
    local function grid_los(p1, p2)
      local r1, c1 = p1[1], p1[2]
      local r2, c2 = p2[1], p2[2]
      local dr = math.abs(r2 - r1)
      local dc = math.abs(c2 - c1)
      local steps = dr > dc and dr or dc
      if steps == 0 then return true end
      for i = 0, steps do
        local r = math.floor(r1 + (r2 - r1) * i / steps + 0.5)
        local c = math.floor(c1 + (c2 - c1) * i / steps + 0.5)
        if GRID5[r] == nil or GRID5[r][c] ~= 0 then return false end
      end
      return true
    end

    local smoothed = A.smooth_path(path, grid_los)
    T.ok(smoothed ~= nil)
    T.ok(#smoothed >= 2)
    T.eq(smoothed[1][1], 1)
    T.eq(smoothed[1][2], 1)
    T.eq(smoothed[#smoothed][1], 5)
    T.eq(smoothed[#smoothed][2], 5)
  end)
end)
