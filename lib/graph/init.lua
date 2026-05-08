if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Graph object
-- ---------------------------------------------------------------------------

--:: Graph = { _directed: boolean, _nodes: { [unknown]: unknown }, _adj: { [unknown]: { [unknown]: unknown } }, _in_adj: { [unknown]: { [unknown]: unknown } } | nil, _nedges: integer, ... }

local Graph = {}
Graph.__index = Graph

-- Create a new graph.
-- opts.directed: boolean, default false
--: ({ directed: boolean | nil } | nil) -> Graph
function M.new(opts)
  opts = opts or {} --[[:! { directed: boolean | nil }]]
  local directed = opts.directed and true or false
  local self = setmetatable({
    _directed = directed,
    _nodes    = {},   -- id -> data|true
    _adj      = {},   -- id -> { nb_id -> edge_data|true }
    _in_adj   = nil,  -- id -> { nb_id -> edge_data|true }, directed only
    _nedges   = 0,
  }, Graph)
  if directed then
    self._in_adj = {}
  end
  return self
end

-- Add a node with optional data. If the node already exists, data is updated.
-- Returns self for chaining.
function Graph:add_node(id, data)
  if not self._nodes[id] then
    self._adj[id] = {}
    if self._directed then
      self._in_adj[id] = {}
    end
  end
  self._nodes[id] = data ~= nil and data or true
  return self
end

-- Add an edge from u to v with optional data table.
-- Auto-creates nodes. For undirected graphs both directions share the same
-- data table reference.
function Graph:add_edge(u, v, data)
  if not self._nodes[u] then (self --[[: any]]):add_node(u) end
  if not self._nodes[v] then (self --[[: any]]):add_node(v) end
  local edata = data ~= nil and data or true
  if self._directed then
    if not self._adj[u][v] then
      self._nedges = (self._nedges --[[:! integer]]) + 1
    end
    self._adj[u][v]   = edata
    self._in_adj[v][u] = edata
  else
    if not self._adj[u][v] then
      self._nedges = (self._nedges --[[:! integer]]) + 1
    end
    self._adj[u][v] = edata
    self._adj[v][u] = edata
  end
  return self
end

-- Remove an edge. Returns true if removed, false if not present.
function Graph:remove_edge(u, v)
  if not self._adj[u] or not self._adj[u][v] then return false end
  self._adj[u][v] = nil
  if self._directed then
    self._in_adj[v][u] = nil
  else
    self._adj[v][u] = nil
  end
  self._nedges = (self._nedges --[[:! integer]]) - 1
  return true
end

-- Remove a node and all incident edges. Returns true if the node existed.
function Graph:remove_node(id)
  if not self._nodes[id] then return false end
  -- Remove outgoing edges
  for nb in pairs(self._adj[id]) do
    if self._directed then
      self._in_adj[nb][id] = nil
    else
      self._adj[nb][id] = nil
    end
    self._nedges = (self._nedges --[[:! integer]]) - 1
  end
  -- Remove incoming edges (directed only)
  if self._directed then
    for nb in pairs(self._in_adj[id]) do
      self._adj[nb][id] = nil
      self._nedges = (self._nedges --[[:! integer]]) - 1
    end
    self._in_adj[id] = nil
  end
  self._adj[id]   = nil
  self._nodes[id] = nil
  return true
end

-- Query methods

function Graph:has_node(id)
  return self._nodes[id] ~= nil
end

function Graph:has_edge(u, v)
  return self._adj[u] ~= nil and self._adj[u][v] ~= nil
end

-- Returns the data passed to add_node, or nil if none / node missing.
function Graph:node_data(id)
  local d = self._nodes[id]
  if d == nil or d == true then return nil end
  return d
end

-- Returns the data passed to add_edge, or nil if none / edge missing.
function Graph:edge_data(u, v)
  if not self._adj[u] then return nil end
  local d = self._adj[u][v]
  if d == nil or d == true then return nil end
  return d
end

-- Array of neighbor ids.
-- Undirected: all neighbors. Directed: out-neighbors.
function Graph:neighbors(id)
  if not self._adj[id] then return {} end
  local r = {}
  for nb in pairs(self._adj[id]) do r[#r+1] = nb end
  return r
end

-- Out-neighbors for directed graphs (same as neighbors).
function Graph:out_neighbors(id)
  return self:neighbors(id)
end

-- In-neighbors for directed graphs; same as neighbors for undirected.
function Graph:in_neighbors(id)
  if not self._directed then return (self --[[: any]]):neighbors(id) end
  if not self._in_adj[id] then return {} end
  local r = {}
  for nb in pairs(self._in_adj[id]) do r[#r+1] = nb end
  return r
end

-- Degree. Undirected: edge count. Directed: out-degree + in-degree.
function Graph:degree(id)
  local n = 0
  if self._adj[id] then
    for _ in pairs(self._adj[id]) do n = n + 1 end
  end
  if self._directed and self._in_adj[id] then
    for _ in pairs(self._in_adj[id]) do n = n + 1 end
  end
  return n
end

function Graph:out_degree(id)
  if not self._adj[id] then return 0 end
  local n = 0
  for _ in pairs(self._adj[id]) do n = n + 1 end
  return n
end

function Graph:in_degree(id)
  if not self._directed then return (self --[[: any]]):degree(id) end
  if not self._in_adj[id] then return 0 end
  local n = 0
  for _ in pairs(self._in_adj[id]) do n = n + 1 end
  return n
end

function Graph:node_count()
  local n = 0
  for _ in pairs(self._nodes) do n = n + 1 end
  return n
end

function Graph:edge_count()
  return self._nedges
end

-- Iterator over node ids (and their raw internal value — callers should use
-- node_data() to retrieve clean data).
function Graph:nodes()
  return pairs(self._nodes)
end

-- Iterator over edges, yielding {from, to, data}.
-- For undirected graphs each edge is yielded once.
function Graph:edges()
  local seen   = self._directed and nil or {}
  local niter, nstate, nkey = pairs(self._nodes)
  local eiter, estate, ekey
  local cur

  local function step()
    while true do
      if eiter then
        while true do
          local nb, edata = eiter(estate, ekey)
          if nb == nil then eiter = nil; break end
          ekey = nb
          if not self._directed then
            -- produce each undirected edge once
            local a, b = tostring(cur), tostring(nb)
            local key = a < b and (a.."\0"..b) or (b.."\0"..a)
            if not seen[key] then
              seen[key] = true
              return {cur, nb, edata == true and nil or edata}
            end
          else
            return {cur, nb, edata == true and nil or edata}
          end
        end
      end
      local nid = niter(nstate, nkey)
      if nid == nil then return nil end
      nkey = nid
      cur  = nid
      eiter, estate, ekey = pairs(self._adj[nid])
    end
  end

  return step
end

-- ---------------------------------------------------------------------------
-- Algorithms
-- ---------------------------------------------------------------------------

-- BFS from start. Returns order (array) and parent table (id -> parent_id).
--: (any, unknown) -> ({ [integer]: unknown } | nil, { [unknown]: unknown } | string | nil)
function M.bfs(g, start)
  if not g:has_node(start) then return nil, "start node not found" end
  local order   = {}
  local parent  = {}
  local visited = {[start] = true}
  local queue   = {start}
  local head    = 1
  while head <= #queue do
    local cur = queue[head]; head = head + 1
    order[#order+1] = cur
    local nbs = g:neighbors(cur)
    for i = 1, #nbs do
      local nb = nbs[i]
      if not visited[nb] then
        visited[nb]  = true
        parent[nb]   = cur
        queue[#queue+1] = nb
      end
    end
  end
  return order, parent
end

-- DFS from start. Returns order (array) and parent table (id -> parent_id).
--: (any, unknown) -> ({ [integer]: unknown } | nil, { [unknown]: unknown } | string | nil)
function M.dfs(g, start)
  if not g:has_node(start) then return nil, "start node not found" end
  local order   = {}
  local parent  = {}
  local visited = {}
  local stack   = {start}
  while #stack > 0 do
    local cur = stack[#stack]; stack[#stack] = nil
    if not visited[cur] then
      visited[cur]    = true
      order[#order+1] = cur
      local nbs = g:neighbors(cur)
      for i = #nbs, 1, -1 do
        local nb = nbs[i]
        if not visited[nb] then
          if not parent[nb] then parent[nb] = cur end
          stack[#stack+1] = nb
        end
      end
    end
  end
  return order, parent
end

-- Dijkstra shortest path.
-- Edge weight is taken from edge_data(u,v).weight (number), or 1 if absent.
-- Returns (dist_table, path_array) on success, (nil, errmsg) on failure.
--: (any, unknown, unknown) -> (unknown | nil, unknown)
function M.shortest_path(g, start, target)
  if not g:has_node(start)  then return nil, "start node not found"  end
  if not g:has_node(target) then return nil, "target node not found" end

  local INF  = math.huge
  local dist = {}
  local prev = {}
  local vis  = {}

  for id in g:nodes() do dist[id] = INF end
  dist[start] = 0

  while true do
    -- Find unvisited node with minimum distance (O(V) scan)
    local u, ud = nil, INF
    for id in g:nodes() do
      if not vis[id] and dist[id] < ud then u = id; ud = dist[id] end
    end
    if u == nil then break end
    vis[u] = true
    if u == target then break end

    local nbs = g:neighbors(u)
    for i = 1, #nbs do
      local v = nbs[i]
      if not vis[v] then
        local edata = g:edge_data(u, v)
        local w = (type(edata) == "table" and type(edata.weight) == "number")
                  and edata.weight or 1
        local nd = ud + w
        if nd < dist[v] then
          dist[v] = nd
          prev[v] = u
        end
      end
    end
  end

  if dist[target] == INF then
    return nil, "no path from "..tostring(start).." to "..tostring(target)
  end

  local path = {}
  local cur  = target
  while cur ~= nil do
    table.insert(path, 1, cur)
    cur = prev[cur]
  end
  return dist, path
end

-- Topological sort (Kahn's algorithm, directed graphs only).
-- Returns sorted array on success, (nil, errmsg) if cycle or undirected.
--: (any) -> ({ [integer]: unknown } | nil, string | nil)
function M.topological_sort(g)
  if not g._directed then
    return nil, "topological sort requires a directed graph"
  end

  local indegree = {}
  for id in g:nodes() do indegree[id] = 0 end
  for id in g:nodes() do
    for _, nb in ipairs(g:out_neighbors(id)) do
      indegree[nb] = (indegree[nb] or 0) + 1
    end
  end

  local queue = {}
  for id, deg in pairs(indegree) do
    if deg == 0 then queue[#queue+1] = id end
  end
  table.sort(queue)

  local result = {}
  while #queue > 0 do
    table.sort(queue)
    local u = table.remove(queue, 1)
    result[#result+1] = u
    local nbs = g:out_neighbors(u)
    table.sort(nbs)
    for i = 1, #nbs do
      local v = nbs[i]
      indegree[v] = (indegree[v] --[[:! integer]]) - 1
      if indegree[v] == 0 then queue[#queue+1] = v end
    end
  end

  if #result ~= g:node_count() then
    return nil, "cycle detected: graph is not a DAG"
  end
  return result
end

-- Connected components (undirected). Returns array of arrays of node ids.
--: (any) -> { [integer]: { [integer]: unknown } }
function M.components(g)
  local visited = {}
  local comps   = {}
  for id in g:nodes() do
    if not visited[id] then
      local order = M.bfs(g, id)
      local comp  = {}
      if order then
        for i = 1, #order do
          visited[order[i]] = true
          comp[i] = order[i]
        end
      end
      comps[#comps+1] = comp
    end
  end
  return comps
end

-- Cycle detection.
-- Directed: true if any back edge (DFS 3-color).
-- Undirected: true if BFS finds cross-edge to visited non-parent.
--: (any) -> boolean
function M.has_cycle(g)
  if g._directed then
    local color = {}
    for id in g:nodes() do color[id] = 0 end

    local visit
    visit = function(u)
      color[u] = 1
      for _, v in ipairs(g:out_neighbors(u)) do
        if color[v] == 1 then return true end
        if color[v] == 0 and visit(v) then return true end
      end
      color[u] = 2
      return false
    end

    for id in g:nodes() do
      if color[id] == 0 and visit(id) then return true end
    end
    return false
  else
    local visited = {}
    for start in g:nodes() do
      if not visited[start] then
        local par   = {}
        local queue = {start}
        local head  = 1
        visited[start] = true
        while head <= #queue do
          local u = queue[head]; head = head + 1
          for _, v in ipairs(g:neighbors(u)) do
            if not visited[v] then
              visited[v] = true
              par[v]     = u
              queue[#queue+1] = v
            elseif par[u] ~= v then
              return true
            end
          end
        end
      end
    end
    return false
  end
end

-- Minimum spanning tree (Kruskal, undirected only).
-- Returns array of {from, to, data}, or (nil, errmsg) for directed graphs.
--: (any) -> (unknown | nil, string | nil)
function M.mst(g)
  if g._directed then return nil, "MST requires an undirected graph" end

  -- Collect edges with weights
  local edges = {} --: { [integer]: { from: any, to: any, data: any, weight: number } }
  for e in g:edges() do
    local w = (type(e[3]) == "table" and type(e[3].weight) == "number")
              and e[3].weight or 1
    edges[#edges+1] = {from=e[1], to=e[2], data=e[3], weight=w}
  end
  table.sort(edges, function(a, b) return a.weight < b.weight end)

  -- Union-Find with path halving + union by rank
  local uf_par  = {}
  local uf_rank = {}
  for id in g:nodes() do uf_par[id] = id; uf_rank[id] = 0 end

  local function find(x)
    while uf_par[x] ~= x do
      uf_par[x] = uf_par[uf_par[x]]
      x = uf_par[x]
    end
    return x
  end

  local function union(x, y)
    local rx, ry = find(x), find(y)
    if rx == ry then return false end
    if uf_rank[rx] < uf_rank[ry] then rx, ry = ry, rx end
    uf_par[ry] = rx
    if uf_rank[rx] == uf_rank[ry] then uf_rank[rx] = (uf_rank[rx] --[[:! integer]]) + 1 end
    return true
  end

  local result = {}
  for i = 1, #edges do
    local e = edges[i]
    if union(e.from, e.to) then
      result[#result+1] = {e.from, e.to, e.data}
    end
  end
  return result
end

-- Strongly-connected components (Tarjan's algorithm, directed graphs).
-- Returns array of arrays of node ids.
--: (any) -> { [integer]: { [integer]: unknown } }
function M.strongly_connected(g)
  local idx_ctr  = 0
  local stk      = {}
  local on_stk   = {} --: { [unknown]: boolean }
  local idx      = {}
  local lowlink  = {}
  local result   = {}

  local function sc(v)
    idx[v]     = idx_ctr
    lowlink[v] = idx_ctr
    idx_ctr    = idx_ctr + 1
    stk[#stk+1] = v
    on_stk[v]  = true

    for _, w in ipairs(g:out_neighbors(v)) do
      if idx[w] == nil then
        sc(w)
        if lowlink[w] < lowlink[v] then lowlink[v] = lowlink[w] end
      elseif on_stk[w] then
        if idx[w] < lowlink[v] then lowlink[v] = idx[w] end
      end
    end

    if lowlink[v] == idx[v] then
      local comp = {}
      while true do
        local w = stk[#stk]; stk[#stk] = nil
        on_stk[w] = false
        comp[#comp+1] = w
        if w == v then break end
      end
      result[#result+1] = comp
    end
  end

  for id in g:nodes() do
    if idx[id] == nil then sc(id) end
  end
  return result
end

-- Transpose a directed graph (reverse all edges). Returns a new Graph.
--: (any) -> Graph
function M.transpose(g)
  local t = M.new({directed = g._directed}) --[[: any]]
  for id in g:nodes() do
    t:add_node(id, g:node_data(id))
  end
  for id in g:nodes() do
    for _, nb in ipairs(g:out_neighbors(id)) do
      local edata = g:edge_data(id, nb)
      t:add_edge(nb, id, edata)
    end
  end
  return t
end

return M
