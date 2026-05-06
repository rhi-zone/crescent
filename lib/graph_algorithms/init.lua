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

--:: NodeId = unknown
--:: EdgeEntry = { node: NodeId, weight: number, data: unknown }
--:: EdgeResult = { from: NodeId, to: NodeId, weight: number, data: unknown }
--:: HeapEntry = { [1]: number, [2]: NodeId }
--:: HeapT = { n: integer, [integer]: HeapEntry | nil }
--:: UFT = { parent: { [unknown]: NodeId }, rank: { [unknown]: integer } }
--:: GraphT = { _directed: boolean, _weighted: boolean, _nodes: { [unknown]: unknown }, _adj: { [unknown]: { [integer]: EdgeEntry } }, _radj: { [unknown]: { [integer]: EdgeEntry } }, _edge_data: { [string]: { [1]: number, [2]: unknown } }, _node_count: integer, _edge_count: integer }

-- ────────────────────────────────────────────────────────────────────
-- Priority queue (binary min-heap)
-- ────────────────────────────────────────────────────────────────────

local Heap = {}
Heap.__index = Heap

--: () -> HeapT
local function heap_new()
  return setmetatable({ n = 0 }, Heap) --[[:! HeapT]]
end

-- heap_push/pop/empty: direct prototype calls for typed access
--: (HeapT, number, NodeId) -> nil
local function heap_push(h, priority, value)
  local h_ = h --[[:! HeapT]]
  h_.n = h_.n + 1
  local i = h_.n
  local entry = { priority, value } --[[:! HeapEntry]]
  h_[i] = entry
  -- sift up
  while i > 1 do
    local parent = math.floor(i / 2)
    if (h_[parent] --[[:! HeapEntry]])[1] > (h_[i] --[[:! HeapEntry]])[1] then
      h_[parent], h_[i] = h_[i], h_[parent]
      i = parent
    else
      break
    end
  end
end

--: (HeapT) -> (number | nil, NodeId | nil)
local function heap_pop(h)
  local h_ = h --[[:! HeapT]]
  if h_.n == 0 then return nil end
  local top = h_[1] --[[:! HeapEntry]]
  h_[1] = h_[h_.n]
  h_[h_.n] = nil
  h_.n = h_.n - 1
  -- sift down
  local i = 1
  while true do
    local l, r, smallest = i * 2, i * 2 + 1, i
    local hl = h_[l]
    local hr = h_[r]
    local hs = h_[smallest] --[[:! HeapEntry]]
    if l <= h_.n and hl ~= nil and (hl --[[:! HeapEntry]])[1] < hs[1] then smallest = l; hs = hl --[[:! HeapEntry]] end
    if r <= h_.n and hr ~= nil and (hr --[[:! HeapEntry]])[1] < hs[1] then smallest = r end
    if smallest == i then break end
    h_[i], h_[smallest] = h_[smallest], h_[i]
    i = smallest
  end
  return top[1], top[2]
end

--: (HeapT) -> boolean
local function heap_empty(h)
  return (h --[[:! HeapT]]).n == 0
end

function Heap:push(priority, value) heap_push(self --[[:! HeapT]], priority, value) end
function Heap:pop() return heap_pop(self --[[:! HeapT]]) end
function Heap:empty() return heap_empty(self --[[:! HeapT]]) end

-- ────────────────────────────────────────────────────────────────────
-- Union-Find (for Kruskal's MST)
-- ────────────────────────────────────────────────────────────────────

--: () -> UFT
local function uf_new()
  return { parent = {}, rank = {} }
end

--: (UFT, NodeId) -> NodeId
local function uf_find(uf, x)
  local uf_ = uf --[[:! UFT]]
  if uf_.parent[x] == nil then uf_.parent[x] = x; uf_.rank[x] = 0 end
  if uf_.parent[x] ~= x then uf_.parent[x] = uf_find(uf_, uf_.parent[x]) end
  return uf_.parent[x]
end

--: (UFT, NodeId, NodeId) -> boolean
local function uf_union(uf, x, y)
  local uf_ = uf --[[:! UFT]]
  local rx, ry = uf_find(uf_, x), uf_find(uf_, y)
  if rx == ry then return false end
  if ((uf_.rank[rx] or 0) --[[:! integer]]) < ((uf_.rank[ry] or 0) --[[:! integer]]) then rx, ry = ry, rx end
  uf_.parent[ry] = rx
  if ((uf_.rank[rx] or 0) --[[:! integer]]) == ((uf_.rank[ry] or 0) --[[:! integer]]) then uf_.rank[rx] = ((uf_.rank[rx] or 0) --[[:! integer]]) + 1 end
  return true
end

-- ────────────────────────────────────────────────────────────────────
-- Graph constructor
-- ────────────────────────────────────────────────────────────────────

local Graph = {}
Graph.__index = Graph

--- Create a new graph.
-- opts: { directed=false, weighted=false }
--: (unknown) -> GraphT
function M.graph(opts)
  local opts_ = opts --[[:! { directed: boolean | nil, weighted: boolean | nil }]]
  if opts_ == nil then opts_ = {} --[[:! { directed: boolean | nil, weighted: boolean | nil }]] end
  local g = setmetatable({
    _directed = opts_.directed and true or false,
    _weighted = opts_.weighted and true or false,
    _nodes = {},
    _adj = {},
    _radj = {},
    _edge_data = {},
    _node_count = 0,
    _edge_count = 0,
  }, Graph) --[[:! GraphT]]
  return g
end

--: (GraphT, NodeId, unknown) -> GraphT
function Graph:add_node(id, data)
  local self_ = self --[[:! GraphT]]
  if not self_._nodes[id] then
    self_._nodes[id] = data ~= nil and data or true
    self_._adj[id] = self_._adj[id] or {}
    self_._radj[id] = self_._radj[id] or {}
    self_._node_count = self_._node_count + 1
  else
    if data ~= nil then self_._nodes[id] = data end
  end
  return self_
end

--: (GraphT, NodeId, NodeId, number | nil, unknown) -> GraphT
function Graph:add_edge(from, to, weight, data)
  local self_ = self --[[:! GraphT]]
  -- auto-create nodes
  if not self_._nodes[from] then Graph.add_node(self_, from, nil) end
  if not self_._nodes[to] then Graph.add_node(self_, to, nil) end
  local w = (weight or 1) --[[:! number]]
  local sfrom = tostring(from); local sto = tostring(to)
  local key = sfrom .. "\0" .. sto
  if not self_._edge_data[key] then
    self_._edge_count = self_._edge_count + 1
    self_._edge_data[key] = { w, data }
    local adj_from = self_._adj[from] --[[:! { [integer]: EdgeEntry }]]
    adj_from[#adj_from + 1] = { node = to, weight = w, data = data }
    local radj_to = self_._radj[to] --[[:! { [integer]: EdgeEntry }]]
    radj_to[#radj_to + 1] = { node = from, weight = w, data = data }
    if not self_._directed then
      local rkey = sto .. "\0" .. sfrom
      if not self_._edge_data[rkey] then
        self_._edge_data[rkey] = { w, data }
        local adj_to = self_._adj[to] --[[:! { [integer]: EdgeEntry }]]
        adj_to[#adj_to + 1] = { node = from, weight = w, data = data }
        local radj_from = self_._radj[from] --[[:! { [integer]: EdgeEntry }]]
        radj_from[#radj_from + 1] = { node = to, weight = w, data = data }
      end
    end
  else
    -- update weight/data
    self_._edge_data[key][1] = w
    self_._edge_data[key][2] = data
    for _, e in ipairs(self_._adj[from]) do
      if e.node == to then e.weight = w; e.data = data; break end
    end
    if not self_._directed then
      local rkey = sto .. "\0" .. sfrom
      self_._edge_data[rkey][1] = w
      self_._edge_data[rkey][2] = data
      for _, e in ipairs(self_._adj[to]) do
        if e.node == from then e.weight = w; e.data = data; break end
      end
    end
  end
  return self_
end

--: (GraphT, NodeId) -> GraphT
function Graph:remove_node(id)
  local self_ = self --[[:! GraphT]]
  if not self_._nodes[id] then return self_ end
  local sid = tostring(id)
  -- remove all edges involving id
  for _, nb in ipairs(self_._adj[id] or {}) do
    local snb = tostring(nb.node)
    local key = snb .. "\0" .. sid
    if self_._edge_data[key] then
      self_._edge_data[key] = nil
      self_._edge_count = self_._edge_count - 1
    end
    -- remove from neighbor's adj
    local adj = self_._adj[nb.node]
    if adj then
      for i = #adj, 1, -1 do
        if adj[i].node == id then table.remove(adj, i) end
      end
    end
    local radj = self_._radj[nb.node]
    if radj then
      for i = #radj, 1, -1 do
        if radj[i].node == id then table.remove(radj, i) end
      end
    end
  end
  for _, nb in ipairs(self_._radj[id] or {}) do
    local snb = tostring(nb.node)
    local key = snb .. "\0" .. sid
    if self_._edge_data[key] then
      self_._edge_data[key] = nil
      self_._edge_count = self_._edge_count - 1
    end
    local key2 = sid .. "\0" .. snb
    if self_._edge_data[key2] then
      self_._edge_data[key2] = nil
      self_._edge_count = self_._edge_count - 1
    end
    local adj = self_._adj[nb.node]
    if adj then
      for i = #adj, 1, -1 do
        if adj[i].node == id then table.remove(adj, i) end
      end
    end
    local radj = self_._radj[nb.node]
    if radj then
      for i = #radj, 1, -1 do
        if radj[i].node == id then table.remove(radj, i) end
      end
    end
  end
  -- remove self edges
  local skey = sid .. "\0" .. sid
  if self_._edge_data[skey] then
    self_._edge_data[skey] = nil
    self_._edge_count = self_._edge_count - 1
  end
  self_._nodes[id] = nil
  self_._adj[id] = nil
  self_._radj[id] = nil
  self_._node_count = self_._node_count - 1
  return self_
end

--: (GraphT, NodeId, NodeId) -> GraphT
function Graph:remove_edge(from, to)
  local self_ = self --[[:! GraphT]]
  local sfrom = tostring(from); local sto = tostring(to)
  local key = sfrom .. "\0" .. sto
  if not self_._edge_data[key] then return self_ end
  self_._edge_data[key] = nil
  self_._edge_count = self_._edge_count - 1
  local adj = self_._adj[from] --[[:! { [integer]: EdgeEntry }]]
  for i = #adj, 1, -1 do
    if adj[i].node == to then table.remove(adj, i) end
  end
  local radj = self_._radj[to] --[[:! { [integer]: EdgeEntry }]]
  for i = #radj, 1, -1 do
    if radj[i].node == from then table.remove(radj, i) end
  end
  if not self_._directed then
    local rkey = sto .. "\0" .. sfrom
    self_._edge_data[rkey] = nil
    local adj2 = self_._adj[to] --[[:! { [integer]: EdgeEntry }]]
    for i = #adj2, 1, -1 do
      if adj2[i].node == from then table.remove(adj2, i) end
    end
    local radj2 = self_._radj[from] --[[:! { [integer]: EdgeEntry }]]
    for i = #radj2, 1, -1 do
      if radj2[i].node == to then table.remove(radj2, i) end
    end
  end
  return self_
end

--: (GraphT, NodeId) -> { [integer]: EdgeEntry }
function Graph:neighbors(id)
  local self_ = self --[[:! GraphT]]
  return self_._adj[id] or {}
end

--: (GraphT) -> { [integer]: NodeId }
function Graph:nodes()
  local self_ = self --[[:! GraphT]]
  local result = {} --[[:! { [integer]: NodeId }]]
  for id in pairs(self_._nodes) do
    result[#result + 1] = id
  end
  return result
end

--: (GraphT) -> { [integer]: EdgeResult }
function Graph:edges()
  local self_ = self --[[:! GraphT]]
  local result = {} --[[:! { [integer]: EdgeResult }]]
  local seen = {} --[[:! { [string]: boolean }]]
  for id in pairs(self_._nodes) do
    local sid = tostring(id)
    for _, e in ipairs(self_._adj[id] or {}) do
      local key = sid .. "\0" .. tostring(e.node)
      local rkey = tostring(e.node) .. "\0" .. sid
      if not seen[key] and (self_._directed or not seen[rkey]) then
        seen[key] = true
        result[#result + 1] = { from = id, to = e.node, weight = e.weight, data = e.data }
      end
    end
  end
  return result
end

--: (GraphT) -> integer
function Graph:node_count()
  return (self --[[:! GraphT]])._node_count
end
--: (GraphT) -> integer
function Graph:edge_count()
  return (self --[[:! GraphT]])._edge_count
end
--: (GraphT, NodeId) -> boolean
function Graph:has_node(id)
  return (self --[[:! GraphT]])._nodes[id] ~= nil
end
--: (GraphT, NodeId, NodeId) -> boolean
function Graph:has_edge(from, to)
  local key = tostring(from) .. "\0" .. tostring(to)
  return (self --[[:! GraphT]])._edge_data[key] ~= nil
end
--: (GraphT, NodeId) -> unknown
function Graph:get_node(id)
  return (self --[[:! GraphT]])._nodes[id]
end
--: (GraphT, NodeId, NodeId) -> (number | nil, unknown | nil)
function Graph:get_edge(from, to)
  local e = (self --[[:! GraphT]])._edge_data[tostring(from) .. "\0" .. tostring(to)]
  if not e then return nil end
  return e[1], e[2]
end

-- ────────────────────────────────────────────────────────────────────
-- BFS
-- ────────────────────────────────────────────────────────────────────

--- BFS from start node.
-- Returns { order, distances, parents }
function M.bfs(graph, start)
  local graph = graph --[[:! GraphT]]
  if not Graph.has_node(graph, start) then
    return nil, "graph: node not found: " .. tostring(start)
  end
  local order = {} --[[:! { [integer]: NodeId }]]
  local distances = {} --[[:! { [unknown]: integer }]]
  local parents = {} --[[:! { [unknown]: NodeId | false }]]
  distances[start] = 0
  parents[start] = false
  local queue = { start } --[[:! { [integer]: NodeId }]]
  local head = 1
  while head <= #queue do
    local node = queue[head]; head = head + 1
    order[#order + 1] = node
    for _, e in ipairs(Graph.neighbors(graph, node)) do
      if distances[e.node] == nil then
        distances[e.node] = (distances[node] --[[:! integer]]) + 1
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
  local graph = graph --[[:! GraphT]]
  if not Graph.has_node(graph, start) then
    return nil, "graph: node not found: " .. tostring(start)
  end
  if not Graph.has_node(graph, goal) then
    return nil, "graph: node not found: " .. tostring(goal)
  end
  if start == goal then return { start } end
  local parents = {} --[[:! { [unknown]: NodeId | false }]]
  parents[start] = false
  local queue = { start } --[[:! { [integer]: NodeId }]]
  local head = 1
  while head <= #queue do
    local node = queue[head]; head = head + 1
    for _, e in ipairs(Graph.neighbors(graph, node)) do
      if parents[e.node] == nil then
        parents[e.node] = node
        if e.node == goal then
          -- reconstruct
          local path = {} --[[:! { [integer]: NodeId }]]
          local cur = goal --[[:! NodeId | false]]
          while cur do
            path[#path + 1] = cur
            cur = parents[cur --[[:! NodeId]]]
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
  local graph = graph --[[:! GraphT]]
  if not Graph.has_node(graph, start) then
    return nil, "graph: node not found: " .. tostring(start)
  end
  local order, discovery, finish, parents = {}, {}, {}, {}
  local timer = 0
  parents[start] = false

  local function visit(node)
    timer = timer + 1
    discovery[node] = timer
    order[#order + 1] = node
    for _, e in ipairs(Graph.neighbors(graph, node)) do
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
  local graph = graph --[[:! GraphT]]
  if not Graph.has_node(graph, start) then
    return nil, "graph: node not found: " .. tostring(start)
  end
  local dist = {} --[[:! { [unknown]: number }]]
  local parents = {} --[[:! { [unknown]: NodeId | false }]]
  local visited = {} --[[:! { [unknown]: boolean }]]
  for _, id in ipairs(Graph.nodes(graph)) do
    dist[id] = math.huge
  end
  dist[start] = 0
  parents[start] = false

  local pq = heap_new()
  heap_push(pq, 0, start)

  while not heap_empty(pq) do
    local d, node = heap_pop(pq)
    local d_ = (d or 0) --[[:! number]]
    if not visited[node] then
      visited[node] = true
      for _, e in ipairs(Graph.neighbors(graph, node)) do
        local nd = d_ + e.weight
        if nd < (dist[e.node] --[[:! number]]) then
          dist[e.node] = nd
          parents[e.node] = node
          heap_push(pq, nd, e.node)
        end
      end
    end
  end

  return { distances = dist, parents = parents }
end

--- Dijkstra path from start to goal.
-- Returns { path, distance } or nil if unreachable.
function M.dijkstra_path(graph, start, goal)
  local graph = graph --[[:! GraphT]]
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
  local graph = graph --[[:! GraphT]]
  if not Graph.has_node(graph, start) then
    return nil, "graph: node not found: " .. tostring(start)
  end
  if not Graph.has_node(graph, goal) then
    return nil, "graph: node not found: " .. tostring(goal)
  end
  local g_score = {} --[[:! { [unknown]: number }]]
  local f_score = {} --[[:! { [unknown]: number }]]
  local parents = {} --[[:! { [unknown]: NodeId | false }]]
  local closed = {} --[[:! { [unknown]: boolean }]]

  for _, id in ipairs(Graph.nodes(graph)) do
    g_score[id] = math.huge
    f_score[id] = math.huge
  end
  g_score[start] = 0
  f_score[start] = heuristic(start) --[[:! number]]
  parents[start] = false

  local open = heap_new()
  heap_push(open, f_score[start], start)

  while not heap_empty(open) do
    local _, node = heap_pop(open)
    if node == goal then
      local path = {} --[[:! { [integer]: NodeId }]]
      local cur = goal --[[:! NodeId | false]]
      while cur do
        path[#path + 1] = cur
        cur = parents[cur --[[:! NodeId]]]
      end
      local n = #path
      for i = 1, math.floor(n / 2) do
        path[i], path[n - i + 1] = path[n - i + 1], path[i]
      end
      return { path = path, cost = g_score[goal] }
    end
    if not closed[node] then
      closed[node] = true
      for _, e in ipairs(Graph.neighbors(graph, node)) do
        if not closed[e.node] then
          local tentative_g = (g_score[node] --[[:! number]]) + e.weight
          if tentative_g < ((g_score[e.node] or math.huge) --[[:! number]]) then
            g_score[e.node] = tentative_g
            f_score[e.node] = tentative_g + (heuristic(e.node) --[[:! number]])
            parents[e.node] = node
            heap_push(open, f_score[e.node], e.node)
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
  local graph = graph --[[:! GraphT]]
  if not Graph.has_node(graph, start) then
    return nil, "graph: node not found: " .. tostring(start)
  end
  local nodes = Graph.nodes(graph)
  local edges = Graph.edges(graph)
  -- for undirected we need both directions
  local all_edges = {}
  for _, e in ipairs(edges) do
    all_edges[#all_edges + 1] = e
    if not graph._directed then
      all_edges[#all_edges + 1] = { from = e.to, to = e.from, weight = e.weight }
    end
  end

  local dist = {} --[[:! { [unknown]: number }]]
  local parents = {} --[[:! { [unknown]: NodeId | false }]]
  for _, id in ipairs(nodes) do dist[id] = math.huge end
  dist[start] = 0
  parents[start] = false

  local n = #nodes
  for _ = 1, n - 1 do
    local updated = false
    for _, e in ipairs(all_edges) do
      local df = dist[e.from] --[[:! number]]
      if df ~= math.huge then
        local nd = df + e.weight
        if nd < (dist[e.to] --[[:! number]]) then
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
    local df = dist[e.from] --[[:! number]]
    if df ~= math.huge and df + e.weight < (dist[e.to] --[[:! number]]) then
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
  local graph = graph --[[:! GraphT]]
  local nodes = Graph.nodes(graph)
  local n = #nodes
  local idx = {}
  for i, id in ipairs(nodes) do idx[id] = i end

  local dist = {} --[[:! { [integer]: { [integer]: number } }]]
  local nxt = {} --[[:! { [integer]: { [integer]: NodeId | nil } }]]
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
  for _, e in ipairs(Graph.edges(graph)) do
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
      local dik = dist[i][k]
      if dik ~= math.huge then
        for j = 1, n do
          local dkj = dist[k][j]
          if dkj ~= math.huge then
            local nd = dik + dkj
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
  local graph = graph --[[:! GraphT]]
  local in_degree = {} --[[:! { [unknown]: integer }]]
  local nodes = Graph.nodes(graph)
  for _, id in ipairs(nodes) do in_degree[id] = 0 end

  for _, id in ipairs(nodes) do
    for _, e in ipairs(Graph.neighbors(graph, id)) do
      in_degree[e.node] = ((in_degree[e.node] or 0) --[[:! integer]]) + 1
    end
  end

  local queue = {} --[[:! { [integer]: NodeId }]]
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
    for _, e in ipairs(Graph.neighbors(graph, node)) do nbs[#nbs + 1] = e.node end
    table.sort(nbs, function(a, b) return tostring(a) < tostring(b) end)
    for _, nb in ipairs(nbs) do
      in_degree[nb] = (in_degree[nb] --[[:! integer]]) - 1
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
  local graph = graph --[[:! GraphT]]
  if graph._directed then
    -- DFS-based cycle detection for directed graphs
    local WHITE = 0 --[[:! integer]]
    local GRAY  = 1 --[[:! integer]]
    local BLACK = 2 --[[:! integer]]
    local color = {} --[[:! { [unknown]: integer }]]
    for _, id in ipairs(Graph.nodes(graph)) do color[id] = WHITE end

    local dfs_visit
    dfs_visit = function(node)
      color[node] = GRAY
      for _, e in ipairs(Graph.neighbors(graph, node)) do
        if color[e.node] == GRAY then return true end
        if color[e.node] == WHITE then
          if dfs_visit(e.node) then return true end
        end
      end
      color[node] = BLACK
      return false
    end

    for _, id in ipairs(Graph.nodes(graph)) do
      if color[id] == WHITE then
        if dfs_visit(id) then return true end
      end
    end
    return false
  else
    -- Union-Find for undirected
    local uf = uf_new()
    for _, e in ipairs(Graph.edges(graph)) do
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
  local graph = graph --[[:! GraphT]]
  local visited = {}
  local components = {}

  for _, start in ipairs(Graph.nodes(graph)) do
    if not visited[start] then
      local comp = {}
      local queue = { start }
      local head = 1
      visited[start] = true
      while head <= #queue do
        local node = queue[head]; head = head + 1
        comp[#comp + 1] = node
        for _, e in ipairs(Graph.neighbors(graph, node)) do
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
  local graph = graph --[[:! GraphT]]
  local nodes = Graph.nodes(graph)
  if #nodes == 0 then return true end
  local comps = M.connected_components(graph)
  return #comps == 1
end

--- Is bipartite? (2-colorable)
-- Returns bool, coloring (node -> 0 or 1)
function M.is_bipartite(graph)
  local graph = graph --[[:! GraphT]]
  local color = {} --[[:! { [unknown]: integer }]]
  local nodes = Graph.nodes(graph)

  for _, start in ipairs(nodes) do
    if color[start] == nil then
      color[start] = 0
      local queue = { start } --[[:! { [integer]: NodeId }]]
      local head = 1
      while head <= #queue do
        local node = queue[head]; head = head + 1
        for _, e in ipairs(Graph.neighbors(graph, node)) do
          if color[e.node] == nil then
            color[e.node] = 1 - (color[node] --[[:! integer]])
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
  local graph = graph --[[:! GraphT]]
  local index_counter = 0
  local stack = {} --[[:! { [integer]: NodeId | nil }]]
  local lowlink = {} --[[:! { [unknown]: integer }]]
  local index = {} --[[:! { [unknown]: integer }]]
  local on_stack = {} --[[:! { [unknown]: boolean }]]
  local sccs = {} --[[:! { [integer]: { [integer]: NodeId } }]]

  local function strongconnect(v)
    index[v] = index_counter
    lowlink[v] = index_counter
    index_counter = index_counter + 1
    stack[#stack + 1] = v
    on_stack[v] = true

    for _, e in ipairs(Graph.neighbors(graph, v)) do
      local w = e.node
      if index[w] == nil then
        strongconnect(w)
        if lowlink[w] < lowlink[v] then lowlink[v] = lowlink[w] end
      elseif on_stack[w] then
        if index[w] < lowlink[v] then lowlink[v] = index[w] end
      end
    end

    if lowlink[v] == index[v] then
      local scc = {} --[[:! { [integer]: NodeId }]]
      while true do
        local w = stack[#stack] --[[:! NodeId]]
        stack[#stack] = nil
        on_stack[w] = false
        scc[#scc + 1] = w
        if w == v then break end
      end
      sccs[#sccs + 1] = scc
    end
  end

  for _, v in ipairs(Graph.nodes(graph)) do
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
  local graph = graph --[[:! GraphT]]
  local edges = Graph.edges(graph)
  table.sort(edges --[[:! { [integer]: unknown }]], function(a, b)
    local a_ = a --[[:! EdgeResult]]; local b_ = b --[[:! EdgeResult]]
    if maximize then return a_.weight > b_.weight end
    return a_.weight < b_.weight
  end)
  local uf = uf_new()
  local mst_edges = {} --[[:! { [integer]: EdgeResult }]]
  local total_weight = 0 --[[:! number]]
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
  local graph = graph --[[:! GraphT]]
  return kruskal(graph, false)
end

--- Maximum spanning tree (Kruskal's with reversed sort).
-- Returns mst_edges, total_weight
function M.maximum_spanning_tree(graph)
  local graph = graph --[[:! GraphT]]
  return kruskal(graph, true)
end

-- ────────────────────────────────────────────────────────────────────
-- Max Flow (Edmonds-Karp = BFS-based Ford-Fulkerson)
-- ────────────────────────────────────────────────────────────────────

--- Edmonds-Karp max flow from source to sink.
-- Returns { flow, flow_edges }
-- flow_edges: list of { from, to, flow, capacity }
function M.max_flow(graph, source, sink)
  local graph = graph --[[:! GraphT]]
  if not Graph.has_node(graph, source) then
    return nil, "graph: node not found: " .. tostring(source)
  end
  if not Graph.has_node(graph, sink) then
    return nil, "graph: node not found: " .. tostring(sink)
  end

  -- Build residual capacity graph as adjacency map
  -- cap[u][v] = capacity; flow tracked via cap reduction
  local cap = {} --[[:! { [unknown]: { [unknown]: number } }]]
  local function ensure(u, v)
    local cap_ = cap --[[:! { [unknown]: { [unknown]: number } }]]
    if not cap_[u] then cap_[u] = {} end
    if not (cap_[u] --[[:! { [unknown]: number }]])[v] then (cap_[u] --[[:! { [unknown]: number }]])[v] = 0 end
    if not cap_[v] then cap_[v] = {} end
    if not (cap_[v] --[[:! { [unknown]: number }]])[u] then (cap_[v] --[[:! { [unknown]: number }]])[u] = 0 end
  end

  for _, e in ipairs(Graph.edges(graph)) do
    ensure(e.from, e.to)
    local cu = cap[e.from] --[[:! { [unknown]: number }]]
    cu[e.to] = (cu[e.to] or 0) + e.weight
    if not graph._directed then
      local cv = cap[e.to] --[[:! { [unknown]: number }]]
      cv[e.from] = (cv[e.from] or 0) + e.weight
    end
  end
  -- for directed, reverse edges start at 0 (already set by ensure)

  -- record original capacities for result
  local orig_cap = {} --[[:! { [unknown]: { [unknown]: number } }]]
  for u, row in pairs(cap) do
    orig_cap[u] = {}
    for v, c in pairs(row) do (orig_cap[u] --[[:! { [unknown]: number }]])[v] = c end
  end

  local total_flow = 0 --[[:! number]]

  -- BFS to find augmenting path
  local function bfs_augment()
    local parent = {} --[[:! { [unknown]: NodeId | false }]]
    parent[source] = false
    local queue = { source } --[[:! { [integer]: NodeId }]]
    local head = 1
    while head <= #queue do
      local u = queue[head]; head = head + 1
      if u == sink then break end
      local cu = cap[u] --[[:! { [unknown]: number } | nil]]
      if cu then
        for v, c in pairs(cu --[[:! { [unknown]: number }]]) do
          if parent[v] == nil and c > 0 then
            parent[v] = u
            queue[#queue + 1] = v
          end
        end
      end
    end
    if parent[sink] == nil then return 0 end
    -- find bottleneck
    local path_flow = math.huge --[[:! number]]
    local cur = sink --[[:! NodeId | false]]
    while cur ~= source do
      local prev = parent[cur --[[:! NodeId]]] --[[:! NodeId | false]]
      local cprev = cap[prev --[[:! NodeId]]] --[[:! { [unknown]: number }]]
      local c = cprev[cur --[[:! NodeId]]] or 0
      if c < path_flow then path_flow = c end
      cur = prev
    end
    -- update residual
    cur = sink --[[:! NodeId | false]]
    while cur ~= source do
      local prev = parent[cur --[[:! NodeId]]] --[[:! NodeId | false]]
      local cprev = cap[prev --[[:! NodeId]]] --[[:! { [unknown]: number }]]
      local ccur = cap[cur --[[:! NodeId]]] --[[:! { [unknown]: number }]]
      cprev[cur --[[:! NodeId]]] = (cprev[cur --[[:! NodeId]]] or 0) - path_flow
      ccur[prev --[[:! NodeId]]] = (ccur[prev --[[:! NodeId]]] or 0) + path_flow
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
  local flow_edges = {} --[[:! { [integer]: { from: NodeId, to: NodeId, flow: number, capacity: number } }]]
  for u, row in pairs(orig_cap) do
    for v, oc in pairs(row --[[:! { [unknown]: number }]]) do
      if oc > 0 then
        local cu = cap[u] --[[:! { [unknown]: number } | nil]]
        local remaining = cu and ((cu --[[:! { [unknown]: number }]])[v] or 0) or 0
        local f = oc - (remaining --[[:! number]])
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
  local graph = graph --[[:! GraphT]]
  local nodes = Graph.nodes(graph)
  local n = #nodes
  if n <= 1 then
    local result = {} --[[:! { [unknown]: number }]]
    for _, id in ipairs(nodes) do result[id] = 0 end
    return result
  end
  local result = {} --[[:! { [unknown]: number }]]
  for _, id in ipairs(nodes) do
    local deg = #Graph.neighbors(graph, id)
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
  local graph = graph --[[:! GraphT]]
  local nodes = Graph.nodes(graph)
  local n = #nodes
  local bc = {} --[[:! { [unknown]: number }]]
  for _, id in ipairs(nodes) do bc[id] = 0 end

  for _, s in ipairs(nodes) do
    -- BFS from s
    local stack = {} --[[:! { [integer]: NodeId }]]
    local pred = {} --[[:! { [unknown]: { [integer]: NodeId } }]]
    local sigma = {} --[[:! { [unknown]: number }]]
    local dist2 = {} --[[:! { [unknown]: integer }]]
    for _, id in ipairs(nodes) do
      pred[id] = {}
      sigma[id] = 0
      dist2[id] = -1
    end
    sigma[s] = 1
    dist2[s] = 0
    local queue = { s } --[[:! { [integer]: NodeId }]]
    local head = 1
    while head <= #queue do
      local v = queue[head]; head = head + 1
      stack[#stack + 1] = v
      for _, e in ipairs(Graph.neighbors(graph, v)) do
        local w = e.node
        if (dist2[w] --[[:! integer]]) < 0 then
          queue[#queue + 1] = w
          dist2[w] = (dist2[v] --[[:! integer]]) + 1
        end
        if dist2[w] == (dist2[v] --[[:! integer]]) + 1 then
          sigma[w] = (sigma[w] or 0) + (sigma[v] or 0)
          pred[w][#pred[w] + 1] = v
        end
      end
    end

    -- back-propagation
    local delta = {} --[[:! { [unknown]: number }]]
    for _, id in ipairs(nodes) do delta[id] = 0 end
    while #stack > 0 do
      local w = stack[#stack] --[[:! NodeId]]
      stack[#stack] = nil
      for _, v in ipairs(pred[w]) do
        delta[v] = (delta[v] or 0) + ((sigma[v] or 0) / (sigma[w] or 1)) * (1 + (delta[w] or 0))
      end
      if w ~= s then bc[w] = (bc[w] or 0) + (delta[w] or 0) end
    end
  end

  -- normalize
  local norm = (n > 2 and 1 / ((n - 1) * (n - 2)) or 1) --[[:! number]]
  if not graph._directed then norm = norm * 2 end
  for _, id in ipairs(nodes) do
    bc[id] = (bc[id] or 0) * norm
  end

  return bc
end

return M
