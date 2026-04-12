if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- Graph algorithms library.
-- Supports directed/undirected, weighted/unweighted graphs.
-- Algorithms: BFS, DFS, Dijkstra, A*, Bellman-Ford, Floyd-Warshall,
--   topological sort, SCC (Tarjan's), MST (Kruskal's), max flow (Edmonds-Karp),
--   centrality measures, connectivity, bipartiteness.
local M = {}
M._tier = "pure"

-- ────────────────────────────────────────────────────────────────────
-- Priority queue (binary min-heap)
-- ────────────────────────────────────────────────────────────────────

local Heap = {}
Heap.__index = Heap

local function heap_new()
  return setmetatable({ n = 0 }, Heap)
end

function Heap:push(priority, value)
  self.n = self.n + 1
  local i = self.n
  self[i] = { priority, value }
  -- sift up
  while i > 1 do
    local parent = math.floor(i / 2)
    if self[parent][1] > self[i][1] then
      self[parent], self[i] = self[i], self[parent]
      i = parent
    else
      break
    end
  end
end

function Heap:pop()
  if self.n == 0 then return nil end
  local top = self[1]
  self[1] = self[self.n]
  self[self.n] = nil
  self.n = self.n - 1
  -- sift down
  local i = 1
  while true do
    local l, r, smallest = i * 2, i * 2 + 1, i
    if l <= self.n and self[l][1] < self[smallest][1] then smallest = l end
    if r <= self.n and self[r][1] < self[smallest][1] then smallest = r end
    if smallest == i then break end
    self[i], self[smallest] = self[smallest], self[i]
    i = smallest
  end
  return top[1], top[2]
end

function Heap:empty()
  return self.n == 0
end

-- ────────────────────────────────────────────────────────────────────
-- Union-Find (for Kruskal's MST)
-- ────────────────────────────────────────────────────────────────────

local function uf_new()
  return { parent = {}, rank = {} }
end

local function uf_find(uf, x)
  if uf.parent[x] == nil then uf.parent[x] = x; uf.rank[x] = 0 end
  if uf.parent[x] ~= x then uf.parent[x] = uf_find(uf, uf.parent[x]) end
  return uf.parent[x]
end

local function uf_union(uf, x, y)
  local rx, ry = uf_find(uf, x), uf_find(uf, y)
  if rx == ry then return false end
  if (uf.rank[rx] or 0) < (uf.rank[ry] or 0) then rx, ry = ry, rx end
  uf.parent[ry] = rx
  if (uf.rank[rx] or 0) == (uf.rank[ry] or 0) then uf.rank[rx] = (uf.rank[rx] or 0) + 1 end
  return true
end

-- ────────────────────────────────────────────────────────────────────
-- Graph constructor
-- ────────────────────────────────────────────────────────────────────

local Graph = {}
Graph.__index = Graph

--- Create a new graph.
-- opts: { directed=false, weighted=false }
function M.graph(opts)
  opts = opts or {}
  local g = setmetatable({
    _directed = opts.directed and true or false,
    _weighted = opts.weighted and true or false,
    _nodes = {},      -- id -> data
    _adj = {},        -- id -> [ {node, weight, data} ]
    _radj = {},       -- id -> [ {node, weight, data} ] (reverse, for directed)
    _edge_data = {},  -- "from\0to" -> {weight, data}
    _node_count = 0,
    _edge_count = 0,
  }, Graph)
  return g
end

function Graph:add_node(id, data)
  if not self._nodes[id] then
    self._nodes[id] = data ~= nil and data or true
    self._adj[id] = self._adj[id] or {}
    self._radj[id] = self._radj[id] or {}
    self._node_count = self._node_count + 1
  else
    if data ~= nil then self._nodes[id] = data end
  end
  return self
end

function Graph:add_edge(from, to, weight, data)
  -- auto-create nodes
  if not self._nodes[from] then self:add_node(from) end
  if not self._nodes[to] then self:add_node(to) end
  weight = weight or 1
  local key = from .. "\0" .. to
  if not self._edge_data[key] then
    self._edge_count = self._edge_count + 1
    self._edge_data[key] = { weight, data }
    local adj_from = self._adj[from]
    adj_from[#adj_from + 1] = { node = to, weight = weight, data = data }
    local radj_to = self._radj[to]
    radj_to[#radj_to + 1] = { node = from, weight = weight, data = data }
    if not self._directed then
      local rkey = to .. "\0" .. from
      if not self._edge_data[rkey] then
        self._edge_data[rkey] = { weight, data }
        local adj_to = self._adj[to]
        adj_to[#adj_to + 1] = { node = from, weight = weight, data = data }
        local radj_from = self._radj[from]
        radj_from[#radj_from + 1] = { node = to, weight = weight, data = data }
      end
    end
  else
    -- update weight/data
    self._edge_data[key][1] = weight
    self._edge_data[key][2] = data
    for _, e in ipairs(self._adj[from]) do
      if e.node == to then e.weight = weight; e.data = data; break end
    end
    if not self._directed then
      local rkey = to .. "\0" .. from
      self._edge_data[rkey][1] = weight
      self._edge_data[rkey][2] = data
      for _, e in ipairs(self._adj[to]) do
        if e.node == from then e.weight = weight; e.data = data; break end
      end
    end
  end
  return self
end

function Graph:remove_node(id)
  if not self._nodes[id] then return self end
  -- remove all edges involving id
  for _, nb in ipairs(self._adj[id] or {}) do
    local key = nb.node .. "\0" .. id
    if self._edge_data[key] then
      self._edge_data[key] = nil
      self._edge_count = self._edge_count - 1
    end
    -- remove from neighbor's adj
    local adj = self._adj[nb.node]
    if adj then
      for i = #adj, 1, -1 do
        if adj[i].node == id then table.remove(adj, i) end
      end
    end
    local radj = self._radj[nb.node]
    if radj then
      for i = #radj, 1, -1 do
        if radj[i].node == id then table.remove(radj, i) end
      end
    end
  end
  for _, nb in ipairs(self._radj[id] or {}) do
    local key = nb.node .. "\0" .. id
    if self._edge_data[key] then
      self._edge_data[key] = nil
      self._edge_count = self._edge_count - 1
    end
    local key2 = id .. "\0" .. nb.node
    if self._edge_data[key2] then
      self._edge_data[key2] = nil
      self._edge_count = self._edge_count - 1
    end
    local adj = self._adj[nb.node]
    if adj then
      for i = #adj, 1, -1 do
        if adj[i].node == id then table.remove(adj, i) end
      end
    end
    local radj = self._radj[nb.node]
    if radj then
      for i = #radj, 1, -1 do
        if radj[i].node == id then table.remove(radj, i) end
      end
    end
  end
  -- remove self edges
  local skey = id .. "\0" .. id
  if self._edge_data[skey] then
    self._edge_data[skey] = nil
    self._edge_count = self._edge_count - 1
  end
  self._nodes[id] = nil
  self._adj[id] = nil
  self._radj[id] = nil
  self._node_count = self._node_count - 1
  return self
end

function Graph:remove_edge(from, to)
  local key = from .. "\0" .. to
  if not self._edge_data[key] then return self end
  self._edge_data[key] = nil
  self._edge_count = self._edge_count - 1
  local adj = self._adj[from]
  for i = #adj, 1, -1 do
    if adj[i].node == to then table.remove(adj, i) end
  end
  local radj = self._radj[to]
  for i = #radj, 1, -1 do
    if radj[i].node == from then table.remove(radj, i) end
  end
  if not self._directed then
    local rkey = to .. "\0" .. from
    self._edge_data[rkey] = nil
    local adj2 = self._adj[to]
    for i = #adj2, 1, -1 do
      if adj2[i].node == from then table.remove(adj2, i) end
    end
    local radj2 = self._radj[from]
    for i = #radj2, 1, -1 do
      if radj2[i].node == to then table.remove(radj2, i) end
    end
  end
  return self
end

function Graph:neighbors(id)
  return self._adj[id] or {}
end

function Graph:nodes()
  local result = {}
  for id in pairs(self._nodes) do
    result[#result + 1] = id
  end
  return result
end

function Graph:edges()
  local result = {}
  local seen = {}
  for id in pairs(self._nodes) do
    for _, e in ipairs(self._adj[id] or {}) do
      local key = id .. "\0" .. e.node
      local rkey = e.node .. "\0" .. id
      if not seen[key] and (self._directed or not seen[rkey]) then
        seen[key] = true
        result[#result + 1] = { from = id, to = e.node, weight = e.weight, data = e.data }
      end
    end
  end
  return result
end

function Graph:node_count() return self._node_count end
function Graph:edge_count()
  return self._edge_count
end
function Graph:has_node(id) return self._nodes[id] ~= nil end
function Graph:has_edge(from, to) return self._edge_data[from .. "\0" .. to] ~= nil end
function Graph:get_node(id) return self._nodes[id] end
function Graph:get_edge(from, to)
  local e = self._edge_data[from .. "\0" .. to]
  if not e then return nil end
  return e[1], e[2]
end

-- ────────────────────────────────────────────────────────────────────
-- BFS
-- ────────────────────────────────────────────────────────────────────

--- BFS from start node.
-- Returns { order, distances, parents }
function M.bfs(graph, start)
  if not graph:has_node(start) then
    return nil, "graph: node not found: " .. tostring(start)
  end
  local order, distances, parents = {}, {}, {}
  distances[start] = 0
  parents[start] = false  -- sentinel: root has no parent
  local queue = { start }
  local head = 1
  while head <= #queue do
    local node = queue[head]; head = head + 1
    order[#order + 1] = node
    for _, e in ipairs(graph:neighbors(node)) do
      if distances[e.node] == nil then
        distances[e.node] = distances[node] + 1
        parents[e.node] = node
        queue[#queue + 1] = e.node
      end
    end
  end
  return { order = order, distances = distances, parents = parents }
end

--- BFS shortest path (by hop count).
-- Returns array of nodes from start to goal, or nil if unreachable.
function M.bfs_path(graph, start, goal)
  if not graph:has_node(start) then
    return nil, "graph: node not found: " .. tostring(start)
  end
  if not graph:has_node(goal) then
    return nil, "graph: node not found: " .. tostring(goal)
  end
  if start == goal then return { start } end
  local parents = { [start] = false }
  local queue = { start }
  local head = 1
  while head <= #queue do
    local node = queue[head]; head = head + 1
    for _, e in ipairs(graph:neighbors(node)) do
      if parents[e.node] == nil then
        parents[e.node] = node
        if e.node == goal then
          -- reconstruct
          local path = {}
          local cur = goal
          while cur do
            path[#path + 1] = cur
            cur = parents[cur]
          end
          -- reverse
          local n = #path
          for i = 1, math.floor(n / 2) do
            path[i], path[n - i + 1] = path[n - i + 1], path[i]
          end
          return path
        end
        queue[#queue + 1] = e.node
      end
    end
  end
  return nil
end

-- ────────────────────────────────────────────────────────────────────
-- DFS
-- ────────────────────────────────────────────────────────────────────

--- DFS from start node.
-- Returns { order, discovery, finish, parents }
-- discovery[node] = step when first visited, finish[node] = step when done
function M.dfs(graph, start)
  if not graph:has_node(start) then
    return nil, "graph: node not found: " .. tostring(start)
  end
  local order, discovery, finish, parents = {}, {}, {}, {}
  local timer = 0
  parents[start] = false

  local function visit(node)
    timer = timer + 1
    discovery[node] = timer
    order[#order + 1] = node
    for _, e in ipairs(graph:neighbors(node)) do
      if discovery[e.node] == nil then
        parents[e.node] = node
        visit(e.node)
      end
    end
    timer = timer + 1
    finish[node] = timer
  end

  visit(start)
  return { order = order, discovery = discovery, finish = finish, parents = parents }
end

-- ────────────────────────────────────────────────────────────────────
-- Dijkstra
-- ────────────────────────────────────────────────────────────────────

--- Dijkstra's algorithm from start node (non-negative weights).
-- Returns { distances, parents }
function M.dijkstra(graph, start)
  if not graph:has_node(start) then
    return nil, "graph: node not found: " .. tostring(start)
  end
  local dist, parents = {}, {}
  local visited = {}
  for _, id in ipairs(graph:nodes()) do
    dist[id] = math.huge
  end
  dist[start] = 0
  parents[start] = false

  local pq = heap_new()
  pq:push(0, start)

  while not pq:empty() do
    local d, node = pq:pop()
    if not visited[node] then
      visited[node] = true
      for _, e in ipairs(graph:neighbors(node)) do
        local nd = d + e.weight
        if nd < dist[e.node] then
          dist[e.node] = nd
          parents[e.node] = node
          pq:push(nd, e.node)
        end
      end
    end
  end

  return { distances = dist, parents = parents }
end

--- Dijkstra path from start to goal.
-- Returns { path, distance } or nil if unreachable.
function M.dijkstra_path(graph, start, goal)
  local result, err = M.dijkstra(graph, start)
  if not result then return nil, err end
  if result.distances[goal] == math.huge then return nil end
  local path = {}
  local cur = goal
  while cur do
    path[#path + 1] = cur
    cur = result.parents[cur]
  end
  local n = #path
  for i = 1, math.floor(n / 2) do
    path[i], path[n - i + 1] = path[n - i + 1], path[i]
  end
  return { path = path, distance = result.distances[goal] }
end

-- ────────────────────────────────────────────────────────────────────
-- A*
-- ────────────────────────────────────────────────────────────────────

--- A* search from start to goal.
-- heuristic(node) -> estimated cost to goal (must be admissible)
-- Returns { path, cost } or nil if unreachable.
function M.astar(graph, start, goal, heuristic)
  if not graph:has_node(start) then
    return nil, "graph: node not found: " .. tostring(start)
  end
  if not graph:has_node(goal) then
    return nil, "graph: node not found: " .. tostring(goal)
  end
  local g_score = {}  -- cost from start
  local f_score = {}  -- g + h
  local parents = {}
  local closed = {}

  for _, id in ipairs(graph:nodes()) do
    g_score[id] = math.huge
    f_score[id] = math.huge
  end
  g_score[start] = 0
  f_score[start] = heuristic(start)
  parents[start] = false

  local open = heap_new()
  open:push(f_score[start], start)

  while not open:empty() do
    local _, node = open:pop()
    if node == goal then
      local path = {}
      local cur = goal
      while cur do
        path[#path + 1] = cur
        cur = parents[cur]
      end
      local n = #path
      for i = 1, math.floor(n / 2) do
        path[i], path[n - i + 1] = path[n - i + 1], path[i]
      end
      return { path = path, cost = g_score[goal] }
    end
    if not closed[node] then
      closed[node] = true
      for _, e in ipairs(graph:neighbors(node)) do
        if not closed[e.node] then
          local tentative_g = g_score[node] + e.weight
          if tentative_g < (g_score[e.node] or math.huge) then
            g_score[e.node] = tentative_g
            f_score[e.node] = tentative_g + heuristic(e.node)
            parents[e.node] = node
            open:push(f_score[e.node], e.node)
          end
        end
      end
    end
  end

  return nil
end

-- ────────────────────────────────────────────────────────────────────
-- Bellman-Ford
-- ────────────────────────────────────────────────────────────────────

--- Bellman-Ford from start (handles negative weights, detects negative cycles).
-- Returns { distances, parents }, err
-- err = "graph: negative cycle detected" if one exists
function M.bellman_ford(graph, start)
  if not graph:has_node(start) then
    return nil, "graph: node not found: " .. tostring(start)
  end
  local nodes = graph:nodes()
  local edges = graph:edges()
  -- for undirected we need both directions
  local all_edges = {}
  for _, e in ipairs(edges) do
    all_edges[#all_edges + 1] = e
    if not graph._directed then
      all_edges[#all_edges + 1] = { from = e.to, to = e.from, weight = e.weight }
    end
  end

  local dist, parents = {}, {}
  for _, id in ipairs(nodes) do dist[id] = math.huge end
  dist[start] = 0
  parents[start] = false

  local n = #nodes
  for _ = 1, n - 1 do
    local updated = false
    for _, e in ipairs(all_edges) do
      if dist[e.from] ~= math.huge then
        local nd = dist[e.from] + e.weight
        if nd < dist[e.to] then
          dist[e.to] = nd
          parents[e.to] = e.from
          updated = true
        end
      end
    end
    if not updated then break end
  end

  -- Check for negative cycles
  for _, e in ipairs(all_edges) do
    if dist[e.from] ~= math.huge and dist[e.from] + e.weight < dist[e.to] then
      return nil, "graph: negative cycle detected"
    end
  end

  return { distances = dist, parents = parents }
end

-- ────────────────────────────────────────────────────────────────────
-- Floyd-Warshall
-- ────────────────────────────────────────────────────────────────────

--- Floyd-Warshall all-pairs shortest paths.
-- Returns { dist, next } where dist[i][j] is shortest distance,
-- next[i][j] is next node on shortest path from i to j.
function M.floyd_warshall(graph)
  local nodes = graph:nodes()
  local n = #nodes
  local idx = {}
  for i, id in ipairs(nodes) do idx[id] = i end

  local dist = {}
  local nxt = {}
  for i = 1, n do
    dist[i] = {}
    nxt[i] = {}
    for j = 1, n do
      if i == j then
        dist[i][j] = 0
      else
        dist[i][j] = math.huge
      end
      nxt[i][j] = nil
    end
  end

  -- initialize from edges
  for _, e in ipairs(graph:edges()) do
    local fi, ti = idx[e.from], idx[e.to]
    if fi and ti then
      if e.weight < dist[fi][ti] then
        dist[fi][ti] = e.weight
        nxt[fi][ti] = e.to
      end
      if not graph._directed then
        if e.weight < dist[ti][fi] then
          dist[ti][fi] = e.weight
          nxt[ti][fi] = e.from
        end
      end
    end
  end
  for i = 1, n do nxt[i][i] = nodes[i] end

  -- main loop
  for k = 1, n do
    for i = 1, n do
      if dist[i][k] ~= math.huge then
        for j = 1, n do
          if dist[k][j] ~= math.huge then
            local nd = dist[i][k] + dist[k][j]
            if nd < dist[i][j] then
              dist[i][j] = nd
              nxt[i][j] = nxt[i][k]
            end
          end
        end
      end
    end
  end

  -- return using node ids as keys for ergonomics
  local result_dist = {}
  local result_next = {}
  for i, ni in ipairs(nodes) do
    result_dist[ni] = {}
    result_next[ni] = {}
    for j, nj in ipairs(nodes) do
      result_dist[ni][nj] = dist[i][j]
      result_next[ni][nj] = nxt[i][j]
    end
  end
  return { dist = result_dist, next = result_next }
end

-- ────────────────────────────────────────────────────────────────────
-- Topological Sort (Kahn's algorithm)
-- ────────────────────────────────────────────────────────────────────

--- Topological sort of a directed graph (Kahn's algorithm).
-- Returns order_array, err  (err if cycle detected)
function M.topological_sort(graph)
  local in_degree = {}
  local nodes = graph:nodes()
  for _, id in ipairs(nodes) do in_degree[id] = 0 end

  for _, id in ipairs(nodes) do
    for _, e in ipairs(graph:neighbors(id)) do
      in_degree[e.node] = (in_degree[e.node] or 0) + 1
    end
  end

  local queue = {}
  for _, id in ipairs(nodes) do
    if in_degree[id] == 0 then queue[#queue + 1] = id end
  end
  -- sort for determinism
  table.sort(queue, function(a, b) return tostring(a) < tostring(b) end)

  local order = {}
  local head = 1
  while head <= #queue do
    local node = queue[head]; head = head + 1
    order[#order + 1] = node
    local nbs = {}
    for _, e in ipairs(graph:neighbors(node)) do nbs[#nbs + 1] = e.node end
    table.sort(nbs, function(a, b) return tostring(a) < tostring(b) end)
    for _, nb in ipairs(nbs) do
      in_degree[nb] = in_degree[nb] - 1
      if in_degree[nb] == 0 then queue[#queue + 1] = nb end
    end
  end

  if #order ~= #nodes then
    return nil, "graph: cycle detected"
  end
  return order
end

--- Detect if graph has a cycle.
-- Works for both directed and undirected graphs.
function M.has_cycle(graph)
  if graph._directed then
    -- DFS-based cycle detection for directed graphs
    local WHITE, GRAY, BLACK = 0, 1, 2
    local color = {}
    for _, id in ipairs(graph:nodes()) do color[id] = WHITE end

    local function dfs_visit(node)
      color[node] = GRAY
      for _, e in ipairs(graph:neighbors(node)) do
        if color[e.node] == GRAY then return true end
        if color[e.node] == WHITE then
          if dfs_visit(e.node) then return true end
        end
      end
      color[node] = BLACK
      return false
    end

    for _, id in ipairs(graph:nodes()) do
      if color[id] == WHITE then
        if dfs_visit(id) then return true end
      end
    end
    return false
  else
    -- Union-Find for undirected
    local uf = uf_new()
    for _, e in ipairs(graph:edges()) do
      if not uf_union(uf, e.from, e.to) then return true end
    end
    return false
  end
end

-- ────────────────────────────────────────────────────────────────────
-- Connected Components
-- ────────────────────────────────────────────────────────────────────

--- Connected components for undirected graph.
-- Returns list of lists of node ids.
function M.connected_components(graph)
  local visited = {}
  local components = {}

  for _, start in ipairs(graph:nodes()) do
    if not visited[start] then
      local comp = {}
      local queue = { start }
      local head = 1
      visited[start] = true
      while head <= #queue do
        local node = queue[head]; head = head + 1
        comp[#comp + 1] = node
        for _, e in ipairs(graph:neighbors(node)) do
          if not visited[e.node] then
            visited[e.node] = true
            queue[#queue + 1] = e.node
          end
        end
      end
      components[#components + 1] = comp
    end
  end

  return components
end

--- Is the (undirected) graph connected?
function M.is_connected(graph)
  local nodes = graph:nodes()
  if #nodes == 0 then return true end
  local comps = M.connected_components(graph)
  return #comps == 1
end

--- Is bipartite? (2-colorable)
-- Returns bool, coloring (node -> 0 or 1)
function M.is_bipartite(graph)
  local color = {}
  local nodes = graph:nodes()

  for _, start in ipairs(nodes) do
    if color[start] == nil then
      color[start] = 0
      local queue = { start }
      local head = 1
      while head <= #queue do
        local node = queue[head]; head = head + 1
        for _, e in ipairs(graph:neighbors(node)) do
          if color[e.node] == nil then
            color[e.node] = 1 - color[node]
            queue[#queue + 1] = e.node
          elseif color[e.node] == color[node] then
            return false, nil
          end
        end
      end
    end
  end

  return true, color
end

-- ────────────────────────────────────────────────────────────────────
-- Strongly Connected Components (Tarjan's algorithm)
-- ────────────────────────────────────────────────────────────────────

--- Tarjan's SCC algorithm for directed graphs.
-- Returns list of SCCs (each SCC is a list of node ids), in reverse topological order.
function M.strongly_connected_components(graph)
  local index_counter = 0
  local stack = {}
  local lowlink = {}
  local index = {}
  local on_stack = {}
  local sccs = {}

  local function strongconnect(v)
    index[v] = index_counter
    lowlink[v] = index_counter
    index_counter = index_counter + 1
    stack[#stack + 1] = v
    on_stack[v] = true

    for _, e in ipairs(graph:neighbors(v)) do
      local w = e.node
      if index[w] == nil then
        strongconnect(w)
        if lowlink[w] < lowlink[v] then lowlink[v] = lowlink[w] end
      elseif on_stack[w] then
        if index[w] < lowlink[v] then lowlink[v] = index[w] end
      end
    end

    if lowlink[v] == index[v] then
      local scc = {}
      while true do
        local w = stack[#stack]
        stack[#stack] = nil
        on_stack[w] = false
        scc[#scc + 1] = w
        if w == v then break end
      end
      sccs[#sccs + 1] = scc
    end
  end

  for _, v in ipairs(graph:nodes()) do
    if index[v] == nil then
      strongconnect(v)
    end
  end

  return sccs
end

-- ────────────────────────────────────────────────────────────────────
-- Minimum / Maximum Spanning Tree (Kruskal's)
-- ────────────────────────────────────────────────────────────────────

local function kruskal(graph, maximize)
  local edges = graph:edges()
  table.sort(edges, function(a, b)
    if maximize then return a.weight > b.weight end
    return a.weight < b.weight
  end)
  local uf = uf_new()
  local mst_edges = {}
  local total_weight = 0
  for _, e in ipairs(edges) do
    if uf_union(uf, e.from, e.to) then
      mst_edges[#mst_edges + 1] = e
      total_weight = total_weight + e.weight
    end
  end
  return mst_edges, total_weight
end

--- Minimum spanning tree (Kruskal's).
-- Returns mst_edges, total_weight
function M.minimum_spanning_tree(graph)
  return kruskal(graph, false)
end

--- Maximum spanning tree (Kruskal's with reversed sort).
-- Returns mst_edges, total_weight
function M.maximum_spanning_tree(graph)
  return kruskal(graph, true)
end

-- ────────────────────────────────────────────────────────────────────
-- Max Flow (Edmonds-Karp = BFS-based Ford-Fulkerson)
-- ────────────────────────────────────────────────────────────────────

--- Edmonds-Karp max flow from source to sink.
-- Returns { flow, flow_edges }
-- flow_edges: list of { from, to, flow, capacity }
function M.max_flow(graph, source, sink)
  if not graph:has_node(source) then
    return nil, "graph: node not found: " .. tostring(source)
  end
  if not graph:has_node(sink) then
    return nil, "graph: node not found: " .. tostring(sink)
  end

  -- Build residual capacity graph as adjacency map
  -- cap[u][v] = capacity; flow tracked via cap reduction
  local cap = {}
  local function ensure(u, v)
    if not cap[u] then cap[u] = {} end
    if not cap[u][v] then cap[u][v] = 0 end
    if not cap[v] then cap[v] = {} end
    if not cap[v][u] then cap[v][u] = 0 end
  end

  for _, e in ipairs(graph:edges()) do
    ensure(e.from, e.to)
    cap[e.from][e.to] = cap[e.from][e.to] + e.weight
    if not graph._directed then
      cap[e.to][e.from] = cap[e.to][e.from] + e.weight
    end
  end
  -- for directed, reverse edges start at 0 (already set by ensure)

  -- record original capacities for result
  local orig_cap = {}
  for u, row in pairs(cap) do
    orig_cap[u] = {}
    for v, c in pairs(row) do orig_cap[u][v] = c end
  end

  local total_flow = 0

  -- BFS to find augmenting path
  local function bfs_augment()
    local parent = { [source] = false }
    local queue = { source }
    local head = 1
    while head <= #queue do
      local u = queue[head]; head = head + 1
      if u == sink then break end
      if cap[u] then
        for v, c in pairs(cap[u]) do
          if parent[v] == nil and c > 0 then
            parent[v] = u
            queue[#queue + 1] = v
          end
        end
      end
    end
    if parent[sink] == nil then return 0 end
    -- find bottleneck
    local path_flow = math.huge
    local cur = sink
    while cur ~= source do
      local prev = parent[cur]
      if cap[prev][cur] < path_flow then path_flow = cap[prev][cur] end
      cur = prev
    end
    -- update residual
    cur = sink
    while cur ~= source do
      local prev = parent[cur]
      cap[prev][cur] = cap[prev][cur] - path_flow
      cap[cur][prev] = cap[cur][prev] + path_flow
      cur = prev
    end
    return path_flow
  end

  while true do
    local f = bfs_augment()
    if f == 0 then break end
    total_flow = total_flow + f
  end

  -- compute flow on each edge: flow = orig_cap - remaining_cap (for forward edges)
  local flow_edges = {}
  for u, row in pairs(orig_cap) do
    for v, oc in pairs(row) do
      if oc > 0 then
        local remaining = cap[u] and (cap[u][v] or 0) or 0
        local f = oc - remaining
        if f > 0 then
          flow_edges[#flow_edges + 1] = { from = u, to = v, flow = f, capacity = oc }
        end
      end
    end
  end

  return { flow = total_flow, flow_edges = flow_edges }
end

-- ────────────────────────────────────────────────────────────────────
-- Centrality
-- ────────────────────────────────────────────────────────────────────

--- Degree centrality: (degree / (n-1)) for each node.
-- For directed graphs uses total degree (in + out).
function M.degree_centrality(graph)
  local nodes = graph:nodes()
  local n = #nodes
  if n <= 1 then
    local result = {}
    for _, id in ipairs(nodes) do result[id] = 0 end
    return result
  end
  local result = {}
  for _, id in ipairs(nodes) do
    local deg = #graph:neighbors(id)
    if graph._directed then
      -- add in-degree
      deg = deg + #(graph._radj[id] or {})
    end
    result[id] = deg / (n - 1)
  end
  return result
end

--- Betweenness centrality (normalized, Brandes algorithm).
-- Returns { node -> centrality }
function M.betweenness_centrality(graph)
  local nodes = graph:nodes()
  local n = #nodes
  local bc = {}
  for _, id in ipairs(nodes) do bc[id] = 0 end

  for _, s in ipairs(nodes) do
    -- BFS from s
    local stack = {}
    local pred = {}   -- pred[w] = list of predecessors on shortest paths
    local sigma = {}  -- number of shortest paths from s to node
    local dist2 = {}
    for _, id in ipairs(nodes) do
      pred[id] = {}
      sigma[id] = 0
      dist2[id] = -1
    end
    sigma[s] = 1
    dist2[s] = 0
    local queue = { s }
    local head = 1
    while head <= #queue do
      local v = queue[head]; head = head + 1
      stack[#stack + 1] = v
      for _, e in ipairs(graph:neighbors(v)) do
        local w = e.node
        if dist2[w] < 0 then
          queue[#queue + 1] = w
          dist2[w] = dist2[v] + 1
        end
        if dist2[w] == dist2[v] + 1 then
          sigma[w] = sigma[w] + sigma[v]
          pred[w][#pred[w] + 1] = v
        end
      end
    end

    -- back-propagation
    local delta = {}
    for _, id in ipairs(nodes) do delta[id] = 0 end
    while #stack > 0 do
      local w = stack[#stack]; stack[#stack] = nil
      for _, v in ipairs(pred[w]) do
        delta[v] = delta[v] + (sigma[v] / sigma[w]) * (1 + delta[w])
      end
      if w ~= s then bc[w] = bc[w] + delta[w] end
    end
  end

  -- normalize
  local norm = n > 2 and 1 / ((n - 1) * (n - 2)) or 1
  if not graph._directed then norm = norm * 2 end
  for _, id in ipairs(nodes) do
    bc[id] = bc[id] * norm
  end

  return bc
end

return M
