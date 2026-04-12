if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local G = require("lib.graph_algorithms")

T.describe("graph_algorithms", function()

  -- ──────────────────────────────────────────────────────────────────
  T.describe("graph construction", function()

    T.it("creates empty graph", function()
      local g = G.graph()
      T.eq(g:node_count(), 0)
      T.eq(g:edge_count(), 0)
    end)

    T.it("adds nodes", function()
      local g = G.graph()
      g:add_node("a"):add_node("b"):add_node("c")
      T.eq(g:node_count(), 3)
      T.ok(g:has_node("a"))
      T.ok(g:has_node("b"))
      T.ok(not g:has_node("d"))
    end)

    T.it("stores node data", function()
      local g = G.graph()
      g:add_node("x", { label = "hello" })
      T.eq(g:get_node("x").label, "hello")
    end)

    T.it("adds undirected edges", function()
      local g = G.graph()
      g:add_edge("a", "b", 5)
      T.ok(g:has_edge("a", "b"))
      T.ok(g:has_edge("b", "a"))
      T.eq(g:edge_count(), 1)
    end)

    T.it("adds directed edges", function()
      local g = G.graph({ directed = true })
      g:add_edge("a", "b", 3)
      T.ok(g:has_edge("a", "b"))
      T.ok(not g:has_edge("b", "a"))
      T.eq(g:edge_count(), 1)
    end)

    T.it("gets edge weight", function()
      local g = G.graph()
      g:add_edge("a", "b", 7)
      local w = g:get_edge("a", "b")
      T.eq(w, 7)
    end)

    T.it("auto-creates nodes when adding edges", function()
      local g = G.graph()
      g:add_edge("x", "y")
      T.ok(g:has_node("x"))
      T.ok(g:has_node("y"))
      T.eq(g:node_count(), 2)
    end)

    T.it("removes node and its edges", function()
      local g = G.graph()
      g:add_edge("a", "b"):add_edge("b", "c")
      g:remove_node("b")
      T.ok(not g:has_node("b"))
      T.ok(not g:has_edge("a", "b"))
      T.ok(not g:has_edge("b", "c"))
    end)

    T.it("removes edge", function()
      local g = G.graph()
      g:add_edge("a", "b"):add_edge("b", "c")
      g:remove_edge("a", "b")
      T.ok(not g:has_edge("a", "b"))
      T.ok(g:has_edge("b", "c"))
    end)

    T.it("lists neighbors", function()
      local g = G.graph()
      g:add_edge("a", "b"):add_edge("a", "c")
      local nbs = g:neighbors("a")
      T.eq(#nbs, 2)
    end)

    T.it("lists all nodes", function()
      local g = G.graph()
      g:add_node(1):add_node(2):add_node(3)
      local ns = g:nodes()
      T.eq(#ns, 3)
    end)

    T.it("lists all edges (undirected)", function()
      local g = G.graph()
      g:add_edge("a", "b"):add_edge("b", "c")
      local es = g:edges()
      T.eq(#es, 2)
    end)

  end)

  -- ──────────────────────────────────────────────────────────────────
  T.describe("BFS", function()

    -- Graph:  1-2-3
    --         |
    --         4
    local function make_bfs_graph()
      local g = G.graph()
      g:add_edge(1, 2):add_edge(2, 3):add_edge(1, 4)
      return g
    end

    T.it("visits all reachable nodes", function()
      local g = make_bfs_graph()
      local res = G.bfs(g, 1)
      T.eq(#res.order, 4)
    end)

    T.it("computes correct distances", function()
      local g = make_bfs_graph()
      local res = G.bfs(g, 1)
      T.eq(res.distances[1], 0)
      T.eq(res.distances[2], 1)
      T.eq(res.distances[3], 2)
      T.eq(res.distances[4], 1)
    end)

    T.it("bfs_path finds shortest hop path", function()
      local g = make_bfs_graph()
      local path = G.bfs_path(g, 1, 3)
      T.eq(path[1], 1)
      T.eq(path[#path], 3)
      T.eq(#path, 3)
    end)

    T.it("bfs_path returns nil for unreachable", function()
      local g = G.graph()
      g:add_node("a"):add_node("b")
      local path = G.bfs_path(g, "a", "b")
      T.eq(path, nil)
    end)

    T.it("bfs_path single node", function()
      local g = G.graph()
      g:add_node("x")
      local path = G.bfs_path(g, "x", "x")
      T.eq(#path, 1)
      T.eq(path[1], "x")
    end)

    T.it("returns error for missing start node", function()
      local g = G.graph()
      local res, err = G.bfs(g, "nope")
      T.eq(res, nil)
      T.ok(err ~= nil)
    end)

  end)

  -- ──────────────────────────────────────────────────────────────────
  T.describe("DFS", function()

    T.it("visits all connected nodes", function()
      local g = G.graph()
      g:add_edge("a", "b"):add_edge("b", "c"):add_edge("a", "d")
      local res = G.dfs(g, "a")
      T.eq(#res.order, 4)
    end)

    T.it("discovery times are set", function()
      local g = G.graph()
      g:add_edge(1, 2):add_edge(2, 3)
      local res = G.dfs(g, 1)
      T.ok(res.discovery[1] ~= nil)
      T.ok(res.discovery[2] ~= nil)
      T.ok(res.discovery[3] ~= nil)
      T.ok(res.finish[1] ~= nil)
    end)

    T.it("discovery < finish for each node", function()
      local g = G.graph()
      g:add_edge(1, 2):add_edge(2, 3):add_edge(1, 3)
      local res = G.dfs(g, 1)
      for _, id in ipairs({ 1, 2, 3 }) do
        T.ok(res.discovery[id] < res.finish[id])
      end
    end)

  end)

  -- ──────────────────────────────────────────────────────────────────
  T.describe("has_cycle", function()

    T.it("detects cycle in undirected graph", function()
      local g = G.graph()
      g:add_edge("a", "b"):add_edge("b", "c"):add_edge("c", "a")
      T.ok(G.has_cycle(g))
    end)

    T.it("no cycle in tree", function()
      local g = G.graph()
      g:add_edge("a", "b"):add_edge("b", "c"):add_edge("c", "d")
      T.ok(not G.has_cycle(g))
    end)

    T.it("detects cycle in directed graph", function()
      local g = G.graph({ directed = true })
      g:add_edge("a", "b"):add_edge("b", "c"):add_edge("c", "a")
      T.ok(G.has_cycle(g))
    end)

    T.it("no cycle in DAG", function()
      local g = G.graph({ directed = true })
      g:add_edge("a", "b"):add_edge("b", "c"):add_edge("a", "c")
      T.ok(not G.has_cycle(g))
    end)

  end)

  -- ──────────────────────────────────────────────────────────────────
  T.describe("Dijkstra", function()

    --  1 --2-- 2 --1-- 3
    --  |               |
    --  4               1
    --  |               |
    --  4 --3-- 5 --1-- 6
    local function make_weighted_graph()
      local g = G.graph({ weighted = true })
      g:add_edge(1, 2, 2)
      g:add_edge(2, 3, 1)
      g:add_edge(1, 4, 4)
      g:add_edge(3, 6, 1)
      g:add_edge(4, 5, 3)
      g:add_edge(5, 6, 1)
      return g
    end

    T.it("correct distances from node 1", function()
      local g = make_weighted_graph()
      local res = G.dijkstra(g, 1)
      T.eq(res.distances[1], 0)
      T.eq(res.distances[2], 2)
      T.eq(res.distances[3], 3)
      T.eq(res.distances[6], 4)
      -- path via 1-4-5-6 = 8, via 1-2-3-6 = 4
      T.ok(res.distances[6] <= res.distances[4] + 3 + 1)
    end)

    T.it("dijkstra_path reconstructs path", function()
      local g = make_weighted_graph()
      local res = G.dijkstra_path(g, 1, 6)
      T.ok(res ~= nil)
      T.eq(res.path[1], 1)
      T.eq(res.path[#res.path], 6)
      T.eq(res.distance, 4)
    end)

    T.it("dijkstra_path returns nil for unreachable", function()
      local g = G.graph({ directed = true })
      g:add_node("a"):add_node("b")
      local res = G.dijkstra_path(g, "a", "b")
      T.eq(res, nil)
    end)

  end)

  -- ──────────────────────────────────────────────────────────────────
  T.describe("A*", function()

    -- Grid graph: nodes are "row_col" strings
    -- 3x3 grid, edges to 4-neighbors, weight=1
    local function make_grid(rows, cols)
      local g = G.graph({ directed = false, weighted = true })
      for r = 1, rows do
        for c = 1, cols do
          local id = r .. "_" .. c
          g:add_node(id)
          if r > 1 then g:add_edge(id, (r-1) .. "_" .. c, 1) end
          if c > 1 then g:add_edge(id, r .. "_" .. (c-1), 1) end
        end
      end
      return g
    end

    -- Manhattan heuristic: parse "r_c" format
    local function manhattan_to(gr, gc)
      return function(node)
        local r, c = node:match("^(%d+)_(%d+)$")
        if not r then return 0 end
        return math.abs(tonumber(r) - gr) + math.abs(tonumber(c) - gc)
      end
    end

    T.it("finds path on 3x3 grid", function()
      local g = make_grid(3, 3)
      local h = manhattan_to(3, 3)
      local res = G.astar(g, "1_1", "3_3", h)
      T.ok(res ~= nil)
      T.eq(res.path[1], "1_1")
      T.eq(res.path[#res.path], "3_3")
      T.eq(res.cost, 4)  -- Manhattan distance = (3-1)+(3-1) = 4
    end)

    T.it("returns nil when no path", function()
      local g = G.graph({ directed = true })
      g:add_node("a"):add_node("b")
      local res = G.astar(g, "a", "b", function() return 0 end)
      T.eq(res, nil)
    end)

    T.it("start == goal returns single-node path", function()
      local g = make_grid(2, 2)
      local h = manhattan_to(1, 1)
      local res = G.astar(g, "1_1", "1_1", h)
      T.ok(res ~= nil)
      T.eq(#res.path, 1)
      T.eq(res.cost, 0)
    end)

  end)

  -- ──────────────────────────────────────────────────────────────────
  T.describe("Bellman-Ford", function()

    T.it("correct distances on directed weighted graph", function()
      local g = G.graph({ directed = true })
      g:add_edge("s", "a", 4)
      g:add_edge("s", "b", 5)
      g:add_edge("a", "c", 3)
      g:add_edge("b", "c", 2)
      g:add_edge("b", "d", 6)
      g:add_edge("c", "d", 1)
      local res = G.bellman_ford(g, "s")
      T.ok(res ~= nil)
      T.eq(res.distances["s"], 0)
      T.eq(res.distances["a"], 4)
      T.eq(res.distances["b"], 5)
      T.eq(res.distances["c"], 7)  -- s->b->c = 7
      T.eq(res.distances["d"], 8)  -- s->b->c->d = 8
    end)

    T.it("handles negative weights without cycle", function()
      local g = G.graph({ directed = true })
      g:add_edge("a", "b", -1)
      g:add_edge("b", "c", 2)
      g:add_edge("a", "c", 4)
      local res = G.bellman_ford(g, "a")
      T.ok(res ~= nil)
      T.eq(res.distances["b"], -1)
      T.eq(res.distances["c"], 1)  -- a->b->c = -1+2 = 1
    end)

    T.it("detects negative cycle", function()
      local g = G.graph({ directed = true })
      g:add_edge("a", "b", 1)
      g:add_edge("b", "c", -3)
      g:add_edge("c", "a", 1)
      local res, err = G.bellman_ford(g, "a")
      T.eq(res, nil)
      T.eq(err, "graph: negative cycle detected")
    end)

  end)

  -- ──────────────────────────────────────────────────────────────────
  T.describe("Floyd-Warshall", function()

    T.it("all-pairs shortest paths on 4-node graph", function()
      --  1 --1-- 2
      --  |       |
      --  4       2
      --  |       |
      --  3 --1-- 4
      local g = G.graph({ directed = false, weighted = true })
      g:add_edge(1, 2, 1)
      g:add_edge(2, 4, 2)
      g:add_edge(1, 3, 4)
      g:add_edge(3, 4, 1)
      local res = G.floyd_warshall(g)
      T.eq(res.dist[1][2], 1)
      T.eq(res.dist[1][4], 3)   -- 1->2->4 = 3
      T.eq(res.dist[1][3], 4)   -- 1->3 = 4, but 1->2->4->3 = 4 too
      T.eq(res.dist[2][3], 3)   -- 2->4->3=2+1=3 (shorter than 2->1->3=5)
      T.ok(res.dist[2][3] <= 5)
      -- symmetry for undirected
      T.eq(res.dist[1][4], res.dist[4][1])
    end)

    T.it("self-distance is 0", function()
      local g = G.graph()
      g:add_edge("a", "b"):add_edge("b", "c")
      local res = G.floyd_warshall(g)
      T.eq(res.dist["a"]["a"], 0)
      T.eq(res.dist["b"]["b"], 0)
    end)

  end)

  -- ──────────────────────────────────────────────────────────────────
  T.describe("topological_sort", function()

    T.it("sorts a simple DAG", function()
      local g = G.graph({ directed = true })
      g:add_edge("a", "b"):add_edge("b", "c"):add_edge("a", "c")
      local order, err = G.topological_sort(g)
      T.ok(err == nil)
      T.eq(#order, 3)
      -- a must come before b and c; b must come before c
      local pos = {}
      for i, v in ipairs(order) do pos[v] = i end
      T.ok(pos["a"] < pos["b"])
      T.ok(pos["b"] < pos["c"])
    end)

    T.it("returns error on cycle", function()
      local g = G.graph({ directed = true })
      g:add_edge("a", "b"):add_edge("b", "c"):add_edge("c", "a")
      local order, err = G.topological_sort(g)
      T.eq(order, nil)
      T.ok(err ~= nil)
    end)

    T.it("works on single node", function()
      local g = G.graph({ directed = true })
      g:add_node("x")
      local order, err = G.topological_sort(g)
      T.eq(err, nil)
      T.eq(#order, 1)
    end)

  end)

  -- ──────────────────────────────────────────────────────────────────
  T.describe("connected_components", function()

    T.it("single component", function()
      local g = G.graph()
      g:add_edge(1, 2):add_edge(2, 3):add_edge(3, 4)
      local comps = G.connected_components(g)
      T.eq(#comps, 1)
      T.eq(#comps[1], 4)
    end)

    T.it("multiple components", function()
      local g = G.graph()
      g:add_edge(1, 2):add_edge(3, 4):add_node(5)
      local comps = G.connected_components(g)
      T.eq(#comps, 3)
    end)

    T.it("is_connected true for connected graph", function()
      local g = G.graph()
      g:add_edge("a", "b"):add_edge("b", "c")
      T.ok(G.is_connected(g))
    end)

    T.it("is_connected false for disconnected graph", function()
      local g = G.graph()
      g:add_node("a"):add_node("b")
      T.ok(not G.is_connected(g))
    end)

  end)

  -- ──────────────────────────────────────────────────────────────────
  T.describe("strongly_connected_components", function()

    T.it("Tarjan SCC on directed graph", function()
      -- Classic example: 0->1->2->0, 3->1, 3->2->4
      local g = G.graph({ directed = true })
      g:add_edge(0, 1):add_edge(1, 2):add_edge(2, 0)  -- SCC: {0,1,2}
      g:add_edge(3, 1):add_edge(2, 4)                  -- SCCs: {3}, {4}
      local sccs = G.strongly_connected_components(g)
      T.eq(#sccs, 3)
      -- find the big SCC
      local found_big = false
      for _, scc in ipairs(sccs) do
        if #scc == 3 then found_big = true end
      end
      T.ok(found_big)
    end)

    T.it("each node is its own SCC in a DAG", function()
      local g = G.graph({ directed = true })
      g:add_edge("a", "b"):add_edge("b", "c")
      local sccs = G.strongly_connected_components(g)
      T.eq(#sccs, 3)
      for _, scc in ipairs(sccs) do
        T.eq(#scc, 1)
      end
    end)

  end)

  -- ──────────────────────────────────────────────────────────────────
  T.describe("minimum_spanning_tree", function()

    T.it("Kruskal MST on known graph", function()
      --  a --1-- b --4-- c
      --  |               |
      --  3               2
      --  |               |
      --  d ------5------ e
      local g = G.graph()
      g:add_edge("a", "b", 1)
      g:add_edge("a", "d", 3)
      g:add_edge("b", "c", 4)
      g:add_edge("c", "e", 2)
      g:add_edge("d", "e", 5)
      local mst, total = G.minimum_spanning_tree(g)
      -- MST: a-b(1), c-e(2), a-d(3), b-c(4) = total 10
      T.eq(total, 10)
      T.eq(#mst, 4)
    end)

    T.it("maximum spanning tree has larger weight", function()
      local g = G.graph()
      g:add_edge(1, 2, 1)
      g:add_edge(2, 3, 5)
      g:add_edge(1, 3, 3)
      local _, min_w = G.minimum_spanning_tree(g)
      local _, max_w = G.maximum_spanning_tree(g)
      T.ok(max_w > min_w)
    end)

  end)

  -- ──────────────────────────────────────────────────────────────────
  T.describe("max_flow", function()

    T.it("Edmonds-Karp on simple network", function()
      --  s --10-- a --10-- t
      --  |                 |
      --  10                10
      --  |                 |
      --  b ------10------- t (via b)
      -- Actually: s->a->t, s->b->t with capacities
      local g = G.graph({ directed = true, weighted = true })
      g:add_edge("s", "a", 10)
      g:add_edge("s", "b", 10)
      g:add_edge("a", "t", 10)
      g:add_edge("b", "t", 10)
      local res = G.max_flow(g, "s", "t")
      T.eq(res.flow, 20)
    end)

    T.it("bottleneck limits flow", function()
      --  s --10-- a --1-- t
      local g = G.graph({ directed = true, weighted = true })
      g:add_edge("s", "a", 10)
      g:add_edge("a", "t", 1)
      local res = G.max_flow(g, "s", "t")
      T.eq(res.flow, 1)
    end)

    T.it("flow_edges are populated", function()
      local g = G.graph({ directed = true, weighted = true })
      g:add_edge("s", "a", 5)
      g:add_edge("a", "t", 5)
      local res = G.max_flow(g, "s", "t")
      T.ok(#res.flow_edges >= 1)
    end)

    T.it("classic max-flow example", function()
      -- Ford-Fulkerson textbook example
      --       10        10
      --  s --------> a ------> t
      --  |      ^         ^    |
      --  |      |10       |10  |
      --  |      |         |    |
      --  +-> b  +    10   +    |
      --      |               10|
      -- Simpler: s->a(3), s->b(2), a->t(2), b->t(3), a->b(1)
      local g = G.graph({ directed = true })
      g:add_edge("s", "a", 3)
      g:add_edge("s", "b", 2)
      g:add_edge("a", "t", 2)
      g:add_edge("b", "t", 3)
      g:add_edge("a", "b", 1)
      -- max flow: s->a->t(2) + s->b->t(2) + s->a->b->t(1) = 5, capped by t in-cap = 2+3 = 5
      local res = G.max_flow(g, "s", "t")
      T.ok(res.flow >= 4)
      T.ok(res.flow <= 5)
    end)

  end)

  -- ──────────────────────────────────────────────────────────────────
  T.describe("is_bipartite", function()

    T.it("complete bipartite graph K(2,3) is bipartite", function()
      local g = G.graph()
      -- left: 1,2  right: 3,4,5
      for _, l in ipairs({ 1, 2 }) do
        for _, r in ipairs({ 3, 4, 5 }) do
          g:add_edge(l, r)
        end
      end
      local ok, coloring = G.is_bipartite(g)
      T.ok(ok)
      T.ok(coloring ~= nil)
      -- left and right should have different colors
      T.neq(coloring[1], coloring[3])
      T.neq(coloring[1], coloring[4])
    end)

    T.it("triangle is NOT bipartite", function()
      local g = G.graph()
      g:add_edge(1, 2):add_edge(2, 3):add_edge(3, 1)
      local ok = G.is_bipartite(g)
      T.ok(not ok)
    end)

    T.it("path graph is bipartite", function()
      local g = G.graph()
      g:add_edge(1, 2):add_edge(2, 3):add_edge(3, 4)
      local ok = G.is_bipartite(g)
      T.ok(ok)
    end)

    T.it("even cycle is bipartite", function()
      local g = G.graph()
      g:add_edge(1, 2):add_edge(2, 3):add_edge(3, 4):add_edge(4, 1)
      local ok = G.is_bipartite(g)
      T.ok(ok)
    end)

    T.it("odd cycle is NOT bipartite", function()
      local g = G.graph()
      g:add_edge(1, 2):add_edge(2, 3):add_edge(3, 4):add_edge(4, 5):add_edge(5, 1)
      local ok = G.is_bipartite(g)
      T.ok(not ok)
    end)

  end)

  -- ──────────────────────────────────────────────────────────────────
  T.describe("centrality", function()

    T.it("degree_centrality on star graph", function()
      local g = G.graph()
      -- center=1, leaves=2,3,4,5
      for i = 2, 5 do g:add_edge(1, i) end
      local dc = G.degree_centrality(g)
      -- center: degree=4, n=5, centrality=4/4=1.0
      T.eq(dc[1], 1.0)
      -- leaf: degree=1, n=5, centrality=1/4=0.25
      T.eq(dc[2], 0.25)
    end)

    T.it("betweenness_centrality: center node has highest BC", function()
      -- Linear chain: 1-2-3-4-5
      -- Node 3 is on all paths from {1,2} to {4,5}
      local g = G.graph()
      g:add_edge(1, 2):add_edge(2, 3):add_edge(3, 4):add_edge(4, 5)
      local bc = G.betweenness_centrality(g)
      -- node 3 should have higher BC than nodes 1, 5
      T.ok(bc[3] > bc[1])
      T.ok(bc[3] > bc[5])
    end)

    T.it("betweenness_centrality: endpoints have 0 BC on path", function()
      local g = G.graph()
      g:add_edge("a", "b"):add_edge("b", "c")
      local bc = G.betweenness_centrality(g)
      T.eq(bc["a"], 0)
      T.eq(bc["c"], 0)
    end)

  end)

end)
