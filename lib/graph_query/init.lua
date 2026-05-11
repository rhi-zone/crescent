if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: Graph = { _nodes: { [unknown]: unknown }, _adj: { [unknown]: { [unknown]: unknown } } }
--:: QGraph = { nodes: { [unknown]: unknown }, edges: { [integer]: unknown } }
--:: Query = { _graph: unknown, _ops: { [integer]: unknown } }

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Match a node/edge data table against a filter.
-- filter may be nil (pass-all), a function(id, data)->bool, or a table of
-- key=value constraints.
local function matches(id, data, filter)
  if filter == nil then return true end
  if type(filter) == "function" then return filter(id, data) end
  -- table of key=value constraints
  if type(data) ~= "table" then return false end
  for k, v in pairs(filter) do
    if data[k] ~= v then return false end
  end
  return true
end

-- Shallow-copy an array
local function copy(t)
  local r = {}
  for i = 1, #t do r[i] = t[i] end
  return r
end

-- ---------------------------------------------------------------------------
-- Result objects
-- ---------------------------------------------------------------------------

-- NodeResult: wraps a list of {id, data} pairs with functional operations.
local NodeResult = {}
NodeResult.__index = NodeResult

local function make_node_result(rows)
  return setmetatable({_rows = rows}, NodeResult)
end

function NodeResult:collect()
  local r = {}
  for i = 1, #self._rows do r[i] = self._rows[i] end
  return r
end

function NodeResult:count()
  return #self._rows
end

function NodeResult:each(fn)
  for i = 1, #self._rows do
    local row = self._rows[i]
    fn(row[1], row[2])
  end
  return self
end

-- map: fn(id, data) -> value; returns a plain array of values
function NodeResult:map(fn)
  local r = {}
  for i = 1, #self._rows do
    local row = self._rows[i]
    r[i] = fn(row[1], row[2])
  end
  return r
end

-- sum: sum a plain array (used after :map)
function NodeResult:sum()
  local s = 0
  local r = self._rows
  for i = 1, #r do s = s + r[i] end
  return s
end

function NodeResult:filter(fn)
  local rows = {}
  for i = 1, #self._rows do
    local row = self._rows[i]
    if fn(row[1], row[2]) then rows[#rows+1] = row end
  end
  return make_node_result(rows)
end

function NodeResult:first()
  if #self._rows == 0 then return nil end
  local row = self._rows[1]
  return row[1], row[2]
end

-- EdgeResult: wraps a list of {from, to, data} triples.
local EdgeResult = {}
EdgeResult.__index = EdgeResult

local function make_edge_result(rows)
  return setmetatable({_rows = rows}, EdgeResult)
end

function EdgeResult:collect()
  local r = {}
  for i = 1, #self._rows do r[i] = self._rows[i] end
  return r
end

function EdgeResult:count()
  return #self._rows
end

function EdgeResult:each(fn)
  for i = 1, #self._rows do
    local row = self._rows[i]
    fn(row[1], row[2], row[3])
  end
  return self
end

function EdgeResult:map(fn)
  local r = {}
  for i = 1, #self._rows do
    local row = self._rows[i]
    r[i] = fn(row[1], row[2], row[3])
  end
  return r
end

function EdgeResult:filter(fn)
  local rows = {}
  for i = 1, #self._rows do
    local row = self._rows[i]
    if fn(row[1], row[2], row[3]) then rows[#rows+1] = row end
  end
  return make_edge_result(rows)
end

function EdgeResult:first()
  if #self._rows == 0 then return nil end
  local row = self._rows[1]
  return row[1], row[2], row[3]
end

-- PathResult: wraps a list of path arrays (each path is an array of node ids).
local PathResult = {}
PathResult.__index = PathResult

local function make_path_result(paths)
  return setmetatable({_paths = paths}, PathResult)
end

function PathResult:collect()
  local r = {}
  for i = 1, #self._paths do r[i] = self._paths[i] end
  return r
end

function PathResult:count()
  return #self._paths
end

function PathResult:each(fn)
  for i = 1, #self._paths do fn(self._paths[i]) end
  return self
end

function PathResult:first()
  return self._paths[1]
end

-- MatchResult: wraps a list of match tables {A=id, B=id, ...}
local MatchResult = {}
MatchResult.__index = MatchResult

local function make_match_result(matches_list)
  return setmetatable({_matches = matches_list}, MatchResult)
end

function MatchResult:collect()
  local r = {}
  for i = 1, #self._matches do r[i] = self._matches[i] end
  return r
end

function MatchResult:count()
  return #self._matches
end

function MatchResult:each(fn)
  for i = 1, #self._matches do fn(self._matches[i]) end
  return self
end

function MatchResult:first()
  return self._matches[1]
end

-- ---------------------------------------------------------------------------
-- Internal graph adapter
-- ---------------------------------------------------------------------------
-- Normalizes any graph object into the interface needed by the query engine.
-- Required methods on the source graph:
--   g:nodes()          -> iterator of id (may also yield data as second val)
--   g:edges()          -> iterator yielding {from,to,data} table
--   g:neighbors(id)    -> array of neighbor ids (out-neighbors for directed)
--   g:in_neighbors(id) -> array of in-neighbor ids (optional; directed only)
-- Optional extras used when present:
--   g:node_data(id), g:edge_data(u,v), g._directed

--:: NativeAdapter = { [string]: any }
--:: QGraph = { [string]: any }
--:: QueryT = { [string]: any }

-- Wraps a native crescent Graph (from lib/graph) directly for efficiency.
local NativeAdapter = {}
NativeAdapter.__index = NativeAdapter

local function make_native_adapter(g)
  return setmetatable({_g = g}, NativeAdapter)
end

function NativeAdapter:node_ids()
  local self = self --[[: NativeAdapter]]
  local self = self --[[: NativeAdapter]]
  local g = self._g --[[: unknown]]
  local ids = {}
  for id in g:nodes() do ids[#ids+1] = id end
  return ids
end

function NativeAdapter:node_data(id)
  local self = self --[[: NativeAdapter]]
  local self = self --[[: NativeAdapter]]
  local g = self._g --[[: unknown]]
  return g:node_data(id)
end

function NativeAdapter:edge_list()
  local self = self --[[: NativeAdapter]]
  local self = self --[[: NativeAdapter]]
  local g = self._g --[[: unknown]]
  local edges = {}
  for e in g:edges() do edges[#edges+1] = e end
  return edges
end

function NativeAdapter:edge_data(u, v)
  local self = self --[[: NativeAdapter]]
  local self = self --[[: NativeAdapter]]
  local g = self._g --[[: unknown]]
  return g:edge_data(u, v)
end

function NativeAdapter:has_edge(u, v)
  local self = self --[[: NativeAdapter]]
  local self = self --[[: NativeAdapter]]
  local g = self._g --[[: unknown]]
  return g:has_edge(u, v)
end

function NativeAdapter:out_neighbors(id)
  local self = self --[[: NativeAdapter]]
  local self = self --[[: NativeAdapter]]
  local g = self._g --[[: unknown]]
  return g:neighbors(id)
end

function NativeAdapter:in_neighbors(id)
  local self = self --[[: NativeAdapter]]
  local self = self --[[: NativeAdapter]]
  local g = self._g --[[: unknown]]
  if g.in_neighbors then return g:in_neighbors(id) end
  return g:neighbors(id)
end

function NativeAdapter:is_directed()
  local self = self --[[: NativeAdapter]]
  local self = self --[[: NativeAdapter]]
  local g = self._g --[[: unknown]]
  return g._directed == true
end

-- ---------------------------------------------------------------------------
-- Queryable graph (gq.graph())
-- ---------------------------------------------------------------------------
-- A self-contained directed graph with node/edge data, built for gq queries.

local QGraph = {}
QGraph.__index = QGraph

function M.graph()
  local self = setmetatable({
    _nodes    = {},  -- id -> data
    _adj      = {},  -- from -> { to -> edge_data }
    _in_adj   = {},  -- to   -> { from -> edge_data }
    _nedges   = 0,
  }, QGraph)
  return self
end

function QGraph:node(id, data)
  local self = self --[[: QGraph]]
  if not self._nodes[id] then
    self._adj[id]   = {}
    self._in_adj[id] = {}
  end
  self._nodes[id] = data or true
  return self
end

function QGraph:edge(from, to, data)
  local self = self --[[: QGraph]]
  local self = self --[[: QGraph]]
  if not self._nodes[from] then self:node(from) end
  if not self._nodes[to]   then self:node(to)   end
  local edata = data or true
  local adj_from = self._adj[from] or {}
  if not adj_from[to] then self._nedges = self._nedges + 1 end
  adj_from[to] = edata
  self._adj[from] = adj_from
  local inadj_to = self._in_adj[to] or {}
  inadj_to[from] = edata
  self._in_adj[to] = inadj_to
  return self
end

-- Adapter methods (so query engine can treat QGraph directly)
function QGraph:node_ids()
  local self = self --[[: QGraph]]
  local ids = {}
  for id in pairs(self._nodes) do ids[#ids+1] = id end
  return ids
end

function QGraph:node_data(id)
  local self = self --[[: QGraph]]
  local d = self._nodes[id]
  if d == nil or d == true then return nil end
  return d
end

function QGraph:edge_list()
  local self = self --[[: QGraph]]
  local edges = {}
  for from, nbrs in pairs(self._adj) do
    for to, edata in pairs(nbrs) do
      edges[#edges+1] = {from, to, edata == true and nil or edata}
    end
  end
  return edges
end

function QGraph:edge_data(u, v)
  local self = self --[[: QGraph]]
  if not self._adj[u] then return nil end
  local d = self._adj[u][v]
  if d == nil or d == true then return nil end
  return d
end

function QGraph:has_edge(u, v)
  local self = self --[[: QGraph]]
  return self._adj[u] ~= nil and self._adj[u][v] ~= nil
end

function QGraph:out_neighbors(id)
  local self = self --[[: QGraph]]
  if not self._adj[id] then return {} end
  local r = {}
  for nb in pairs(self._adj[id]) do r[#r+1] = nb end
  return r
end

function QGraph:in_neighbors(id)
  local self = self --[[: QGraph]]
  if not self._in_adj[id] then return {} end
  local r = {}
  for nb in pairs(self._in_adj[id]) do r[#r+1] = nb end
  return r
end

function QGraph:is_directed() return true end

-- ---------------------------------------------------------------------------
-- Query engine
-- ---------------------------------------------------------------------------

local Query = {}
Query.__index = Query

-- Wrap any graph into a query object.
-- Accepts either a QGraph (has node_ids method) or a lib/graph Graph.
--: (QGraph | Graph) -> Query
function M.query(g)
  local adapter
  if type(g.node_ids) == "function" then
    -- Already implements our adapter interface (QGraph or compatible)
    adapter = g
  else
    -- Wrap a lib/graph native graph
    adapter = make_native_adapter(g)
  end
  return setmetatable({_g = adapter}, Query)
end

-- ---------------------------------------------------------------------------
-- nodes / edges queries
-- ---------------------------------------------------------------------------

-- Query nodes, optionally filtered by a table of key=value or a predicate.
-- Returns NodeResult of {id, data} pairs.
function Query:nodes(filter)
  local self = self --[[: QueryT]]
  local g = self._g
  local ids = g:node_ids()
  local rows = {}
  for i = 1, #ids do
    local id = ids[i]
    local data = g:node_data(id)
    if matches(id, data, filter) then
      rows[#rows+1] = {id, data}
    end
  end
  return make_node_result(rows)
end

-- Query edges, optionally filtered.
-- Returns EdgeResult of {from, to, data} triples.
function Query:edges(filter)
  local self = self --[[: QueryT]]
  local g = self._g
  local elist = g:edge_list()
  local rows = {}
  for i = 1, #elist do
    local e = elist[i]
    local from, to, data = e[1], e[2], e[3]
    if matches(from, data, filter) then
      rows[#rows+1] = {from, to, data}
    end
  end
  return make_edge_result(rows)
end

-- ---------------------------------------------------------------------------
-- Path finding
-- ---------------------------------------------------------------------------

-- Find all simple paths from `from` to `to` within max_depth hops.
-- opts: { max_depth=N (default 10), direction="out"|"in"|"both" (default "out") }
-- Returns PathResult.
function Query:path(from, to, opts)
  local self = self --[[: QueryT]]
  opts = opts or {}
  local max_depth = opts.max_depth or 10
  local direction = opts.direction or "out"
  local g = self._g

  local paths = {}
  local visited = {[from] = true} --: { [unknown]: boolean | nil }
  local current = {from}

  local function neighbors(id)
    if direction == "out" then
      return g:out_neighbors(id)
    elseif direction == "in" then
      return g:in_neighbors(id)
    else
      -- both: merge out + in, dedup
      local nbs = {}
      local seen = {}
      for _, nb in ipairs(g:out_neighbors(id)) do
        if not seen[nb] then seen[nb] = true; nbs[#nbs+1] = nb end
      end
      for _, nb in ipairs(g:in_neighbors(id)) do
        if not seen[nb] then seen[nb] = true; nbs[#nbs+1] = nb end
      end
      return nbs
    end
  end

  --: (node: unknown, depth: integer) -> nil
  local function dfs(node, depth)
    if depth > max_depth then return end
    for _, nb in ipairs(neighbors(node)) do
      if nb == to then
        local p = copy(current)
        p[#p+1] = to
        paths[#paths+1] = p
      elseif not visited[nb] then
        visited[nb] = true
        current[#current+1] = nb
        dfs(nb, depth + 1)
        current[#current] = nil
        visited[nb] = nil
      end
    end
  end

  dfs(from, 1)
  return make_path_result(paths)
end

-- Return a set of all nodes reachable from `from` within max_depth hops.
-- opts: { max_depth=N (default math.huge), direction="out"|"in"|"both" }
-- Returns a table {node_id = true}.
function Query:reachable(from, opts)
  local self = self --[[: QueryT]]
  opts = opts or {}
  local max_depth = opts.max_depth or math.huge
  local direction = opts.direction or "out"
  local g = self._g

  local reached = {} --: { [unknown]: boolean }
  local queue   = {{from, 0}} --: { [integer]: { [integer]: unknown } }
  local head    = 1 --: integer
  local visited = {[from] = true} --: { [unknown]: boolean }

  local function neighbors(id)
    if direction == "out" then
      return g:out_neighbors(id)
    elseif direction == "in" then
      return g:in_neighbors(id)
    else
      local nbs = {}
      local seen = {}
      for _, nb in ipairs(g:out_neighbors(id)) do
        if not seen[nb] then seen[nb] = true; nbs[#nbs+1] = nb end
      end
      for _, nb in ipairs(g:in_neighbors(id)) do
        if not seen[nb] then seen[nb] = true; nbs[#nbs+1] = nb end
      end
      return nbs
    end
  end

  while head <= #queue do
    local entry = queue[head]; head = head + 1
    local node, depth = entry[1], entry[2] --[[:! integer]]
    if node ~= from then reached[node] = true end
    if depth < max_depth then
      for _, nb in ipairs(neighbors(node)) do
        if not visited[nb] then
          visited[nb] = true
          queue[#queue+1] = {nb, depth + 1}
        end
      end
    end
  end

  return reached
end

-- Return a NodeResult of all neighbors of `node` within `depth` hops.
-- opts: { depth=N (default 1), direction="out"|"in"|"both" }
function Query:neighbors(node, opts)
  local self = self --[[: QueryT]]
  opts = opts or {}
  local depth = opts.depth or 1
  local reached = self:reachable(node, {max_depth = depth, direction = opts.direction or "out"})
  local g = self._g
  local rows = {}
  for id in pairs(reached) do
    rows[#rows+1] = {id, g:node_data(id)}
  end
  return make_node_result(rows)
end

-- ---------------------------------------------------------------------------
-- Pattern matching
-- ---------------------------------------------------------------------------

-- Match a subgraph pattern.
-- pattern = { nodes = {"A","B",...}, edges = {{"A","B","type"}, ...} }
-- Each edge entry: {var_from, var_to, edge_type_or_nil}
-- Returns MatchResult — list of {A=id, B=id, ...} assignment tables.
function Query:pattern(pat)
  local self = self --[[: QueryT]]
  local pat = pat --[[: { nodes: { [integer]: string }, edges: { [integer]: { [integer]: any } } }]]
  local g       = self._g
  local vars    = pat.nodes   -- ordered variable names
  local pedges  = pat.edges   -- {var_from, var_to, type_constraint}
  local ids     = g:node_ids()
  local results = {}

  -- Check that an assignment satisfies all edge constraints
  local function check(assign)
    for i = 1, #pedges do
      local pe = pedges[i]
      local from_id = assign[pe[1]]
      local to_id   = assign[pe[2]]
      if not from_id or not to_id then return false end
      if not g:has_edge(from_id, to_id) then return false end
      if pe[3] then
        -- check edge type
        local edata = g:edge_data(from_id, to_id)
        if type(edata) ~= "table" or edata.type ~= pe[3] then return false end
      end
    end
    return true
  end

  -- Enumerate all assignments (brute-force permutations of node ids)
  local assign = {}
  local function enumerate(vi)
    if vi > #vars then
      if check(assign) then
        local match = {}
        for k, v in pairs(assign) do match[k] = v end
        results[#results+1] = match
      end
      return
    end
    local vname = vars[vi]
    for i = 1, #ids do
      local id = ids[i]
      -- Ensure injective mapping (no two vars map to same node)
      local used = false
      for _, v in pairs(assign) do
        if v == id then used = true; break end
      end
      if not used then
        assign[vname] = id
        enumerate(vi + 1)
        assign[vname] = nil
      end
    end
  end

  enumerate(1)
  return make_match_result(results)
end

-- ---------------------------------------------------------------------------
-- Analytics
-- ---------------------------------------------------------------------------

-- Betweenness centrality (Brandes' algorithm, O(V*E)).
-- Returns {node_id -> score}.
function Query:betweenness_centrality()
  local self = self --[[: QueryT]]
  local g   = self._g
  local ids = g:node_ids()
  local cb  = {} --: { [unknown]: number }
  for i = 1, #ids do cb[ids[i]] = 0 end

  for si = 1, #ids do
    local s     = ids[si]
    local stack = {}
    local pred  = {} --: { [unknown]: { [integer]: unknown } }
    local sigma = {} --: { [unknown]: integer }
    local dist  = {} --: { [unknown]: integer }
    for i = 1, #ids do
      local v = ids[i]
      pred[v]  = {}
      sigma[v] = 0
      dist[v]  = -1
    end
    sigma[s] = 1
    dist[s]  = 0

    local queue = {s}
    local head  = 1
    while head <= #queue do
      local v = queue[head]; head = head + 1
      stack[#stack+1] = v
      for _, w in ipairs(g:out_neighbors(v)) do
        if dist[w] == -1 then
          dist[w] = dist[v] + 1
          queue[#queue+1] = w
        end
        if dist[w] == dist[v] + 1 then
          sigma[w] = sigma[w] + sigma[v]
          pred[w][#pred[w]+1] = v
        end
      end
    end

    local delta = {} --: { [unknown]: number }
    for i = 1, #ids do delta[ids[i]] = 0 end
    while #stack > 0 do
      local w = stack[#stack]; stack[#stack] = nil
      local pw = pred[w] or {}
      for i = 1, #pw do
        local v = pw[i]
        if (sigma[w] or 0) > 0 then
          delta[v] = (delta[v] or 0) + ((sigma[v] or 0) / (sigma[w] or 1)) * (1 + (delta[w] or 0))
        end
      end
      if w ~= s then cb[w] = (cb[w] or 0) + (delta[w] or 0) end
    end
  end

  return cb
end

-- PageRank.
-- opts: { damping=0.85, iterations=20 }
-- Returns {node_id -> score} (scores sum to ~1).
function Query:pagerank(opts)
  local self = self --[[: QueryT]]
  opts = opts or {}
  local d    = opts.damping    or 0.85
  local iters = opts.iterations or 20
  local g    = self._g
  local ids  = g:node_ids()
  local n    = #ids

  if n == 0 then return {} end

  -- Initial rank
  local rank = {} --: { [unknown]: number }
  for i = 1, n do rank[ids[i]] = 1 / n end

  -- Out-degree cache
  local out_deg = {} --: { [unknown]: integer }
  for i = 1, n do
    local nbs = g:out_neighbors(ids[i])
    out_deg[ids[i]] = #nbs
  end

  for _ = 1, iters do
    local new_rank = {} --: { [unknown]: number }
    local dangling = 0.0 --: number
    for i = 1, n do
      local id = ids[i]
      if (out_deg[id] or 0) == 0 then dangling = dangling + (rank[id] or 0) end
    end
    for i = 1, n do
      local v = ids[i]
      local s = 0.0 --: number
      for _, u in ipairs(g:in_neighbors(v)) do
        local od = out_deg[u] or 0
        if od > 0 then
          s = s + (rank[u] or 0) / od
        end
      end
      -- Distribute dangling rank equally
      new_rank[v] = (1 - d) / n + d * (s + dangling / n)
    end
    rank = new_rank
  end

  return rank
end

-- Clustering coefficient for each node.
-- For directed graphs uses the undirected neighborhood.
-- Returns {node_id -> coefficient}.
function Query:clustering_coefficient()
  local self = self --[[: QueryT]]
  local g   = self._g
  local ids = g:node_ids()
  local cc  = {} --: { [unknown]: number }

  for i = 1, #ids do
    local v    = ids[i]
    -- Gather all neighbors (undirected: out + in, deduped)
    local nb_set = {}
    for _, nb in ipairs(g:out_neighbors(v)) do nb_set[nb] = true end
    for _, nb in ipairs(g:in_neighbors(v))  do nb_set[nb] = true end
    nb_set[v] = nil  -- exclude self

    local nbs = {}
    for nb in pairs(nb_set) do nbs[#nbs+1] = nb end
    local k = #nbs

    if k < 2 then
      cc[v] = 0
    else
      -- Count edges among neighbors (undirected)
      local edges = 0
      for a = 1, #nbs do
        for b = a + 1, #nbs do
          local u, w = nbs[a], nbs[b]
          if g:has_edge(u, w) or g:has_edge(w, u) then
            edges = edges + 1
          end
        end
      end
      cc[v] = (2 * edges) / (k * (k - 1))
    end
  end

  return cc
end

-- Connected components (treats graph as undirected via out+in neighbors).
-- Returns array of arrays of node ids.
function Query:connected_components()
  local self = self --[[: QueryT]]
  local g       = self._g
  local ids     = g:node_ids()
  local visited = {}
  local comps   = {}

  for i = 1, #ids do
    local start = ids[i]
    if not visited[start] then
      local comp  = {}
      local queue = {start}
      local head  = 1
      visited[start] = true
      while head <= #queue do
        local v = queue[head]; head = head + 1
        comp[#comp+1] = v
        -- Treat as undirected: visit both out and in neighbors
        for _, nb in ipairs(g:out_neighbors(v)) do
          if not visited[nb] then
            visited[nb] = true
            queue[#queue+1] = nb
          end
        end
        for _, nb in ipairs(g:in_neighbors(v)) do
          if not visited[nb] then
            visited[nb] = true
            queue[#queue+1] = nb
          end
        end
      end
      comps[#comps+1] = comp
    end
  end

  return comps
end

-- Graph density = actual_edges / max_possible_edges.
-- For directed: max = n*(n-1); undirected: max = n*(n-1)/2.
-- The queryable graph (QGraph) is always directed.
function Query:density()
  local self = self --[[: QueryT]]
  local g   = self._g
  local ids = g:node_ids()
  local n   = #ids
  if n < 2 then return 0 end

  local edge_count = #g:edge_list()
  local max_edges
  if type(g.is_directed) == "function" and g:is_directed() then
    max_edges = n * (n - 1)
  else
    max_edges = n * (n - 1) / 2
  end
  return edge_count / max_edges
end

-- Degree distribution.
-- Returns {node_id -> {in_deg=N, out_deg=N}}.
function Query:degree_distribution()
  local self = self --[[: QueryT]]
  local g   = self._g
  local ids = g:node_ids()
  local dd  = {}

  for i = 1, #ids do
    local id  = ids[i]
    local out = #g:out_neighbors(id)
    local ins = #g:in_neighbors(id)
    dd[id] = {in_deg = ins, out_deg = out}
  end

  return dd
end

-- ---------------------------------------------------------------------------
-- Make QGraph directly queryable via the same query methods
-- ---------------------------------------------------------------------------
-- Delegate all Query methods to a wrapped Query so callers can do g:nodes(...)
-- directly if they prefer. We bind lazily.

local function attach_query_methods(cls)
  local methods = {
    "nodes", "edges", "path", "reachable", "neighbors",
    "pattern", "betweenness_centrality", "pagerank",
    "clustering_coefficient", "connected_components",
    "density", "degree_distribution",
  }
  for _, mname in ipairs(methods) do
    local qmethod = Query[mname]
    if type(qmethod) == "function" then
      cls[mname] = function(self, ...)
        local q = M.query(self)
        return qmethod(q, ...)
      end
    end
  end
end

attach_query_methods(QGraph)

return M
