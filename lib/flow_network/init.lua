if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- lib/flow_network: network flow algorithms
--   Edmonds-Karp (BFS Ford-Fulkerson) max flow
--   Min cut (max-flow/min-cut theorem)
--   Successive shortest paths min-cost max flow
--   Bipartite maximum matching (via max flow)

local M = {}
M._tier = "pure"

local INF = math.huge

-- ========================
-- INTERNAL: adjacency list
-- ========================

-- Each edge stored as:
--   { from, to, cap, flow, cost, rev_idx }
-- rev_idx: index of the reverse edge in adj[to]
-- For residual graph: reverse edge has cap=0 (or lower bound), cost=-cost

--:: Edge = { from: unknown, to: unknown, cap: number, flow: number, cost: number, rev_idx: integer }
--:: Adj  = { [unknown]: { [integer]: Edge, ... } }

local function new_graph()
  return {} --[[:! Adj]]  -- adj[node] = { edge, ... }
end

--: (Adj, unknown, unknown, number, number | nil) -> Edge
local function graph_add_edge(adj, u, v, cap, cost)
  if not adj[u] then adj[u] = {} end
  if not adj[v] then adj[v] = {} end
  local c = cost or 0
  local fwd = { from = u, to = v, cap = cap, flow = 0, cost = c, rev_idx = #adj[v] + 1 } --[[:! Edge]]
  local rev = { from = v, to = u, cap = 0,   flow = 0, cost = -c, rev_idx = #adj[u] + 1 } --[[:! Edge]]
  adj[u][#adj[u] + 1] = fwd
  adj[v][#adj[v] + 1] = rev
  return fwd
end

-- ========================
-- EDMONDS-KARP (BFS Ford-Fulkerson)
-- ========================

-- BFS to find augmenting path; returns parent table or nil
--: (Adj, unknown, unknown) -> { [unknown]: { node: unknown, edge: Edge } } | nil
local function bfs_path(adj, source, sink)
  local visited = { [source] = true }
  local parent = {}   -- parent[v] = { node = u, edge = e }
  local queue = { source }
  local head = 1

  while head <= #queue do
    local u = queue[head]; head = head + 1
    if u == sink then return parent end
    for _, e in ipairs(adj[u] or {}) do
      local v = e.to
      if not visited[v] and e.cap - e.flow > 0 then
        visited[v] = true
        parent[v] = { node = u, edge = e }
        queue[#queue + 1] = v
      end
    end
  end

  return nil
end

-- Augment along the path found by BFS; returns flow pushed
--: (Adj, { [unknown]: { node: unknown, edge: Edge } }, unknown, unknown) -> number
local function augment(adj, parent, source, sink)
  -- Find bottleneck
  local bottle = INF
  local v = sink
  while v ~= source do
    local p = parent[v]
    local rem = p.edge.cap - p.edge.flow
    if rem < bottle then bottle = rem end
    v = p.node
  end

  -- Update flows
  v = sink
  while v ~= source do
    local p = parent[v]
    local e = p.edge
    e.flow = e.flow + bottle
    -- update reverse edge
    adj[e.to][e.rev_idx].flow = adj[e.to][e.rev_idx].flow - bottle
    v = p.node
  end

  return bottle
end

-- Run Edmonds-Karp; returns total flow
--: (Adj, unknown, unknown) -> number
local function edmonds_karp(adj, source, sink)
  local total = 0 --: number
  while true do
    local parent = bfs_path(adj, source, sink)
    if not parent then break end
    total = total + augment(adj, parent, source, sink)
  end
  return total
end

-- ========================
-- MIN-COST MAX-FLOW (Successive Shortest Paths via Bellman-Ford / SPFA)
-- ========================

-- SPFA (Bellman-Ford queue variant) on residual graph; returns dist, prev
--: (Adj, { [integer]: unknown }, unknown) -> ({ [unknown]: number }, { [unknown]: { node: unknown, edge: Edge } })
local function spfa(adj, nodes, source)
  local dist = {} --: { [unknown]: number }
  local in_queue = {} --: { [unknown]: boolean }
  local prev = {}  -- prev[v] = { node=u, edge=e }

  for _, n in ipairs(nodes) do dist[n] = INF end
  dist[source] = 0

  local queue = { source }
  local head = 1
  in_queue[source] = true

  while head <= #queue do
    local u = queue[head]; head = head + 1
    in_queue[u] = false

    for _, e in ipairs(adj[u] or {}) do
      local v = e.to
      if e.cap - e.flow > 0 and dist[u] + e.cost < dist[v] then
        dist[v] = dist[u] + e.cost
        prev[v] = { node = u, edge = e }
        if not in_queue[v] then
          in_queue[v] = true
          queue[#queue + 1] = v
        end
      end
    end
  end

  return dist, prev
end

-- Augment along cheapest path; returns flow pushed, cost
--: (Adj, { [unknown]: { node: unknown, edge: Edge } }, unknown, unknown) -> (number, number)
local function augment_cost(adj, prev, source, sink)
  -- Find bottleneck
  local bottle = INF
  local v = sink
  while v ~= source do
    local p = prev[v]
    local rem = p.edge.cap - p.edge.flow
    if rem < bottle then bottle = rem end
    v = p.node
  end

  -- Update flows
  local cost = 0 --: number
  v = sink
  while v ~= source do
    local p = prev[v]
    local e = p.edge
    e.flow = e.flow + bottle
    cost = cost + bottle * e.cost
    adj[e.to][e.rev_idx].flow = adj[e.to][e.rev_idx].flow - bottle
    v = p.node
  end

  return bottle, cost
end

-- ========================
-- NETWORK OBJECT
-- ========================

local net_mt = {}
net_mt.__index = net_mt

-- Internal: build the residual adjacency list from stored edge specs.
-- edge_specs: array of { u, v, cap, cost, directed }
-- Returns adj, nodes_array, edge_ref_list
-- edge_ref_list[i] = the forward edge object for edge_specs[i] (for reporting flows)
local function build_adj(edge_specs)
  local adj = new_graph()
  local nodes_set = {}
  local edge_refs = {} --: { [integer]: { spec: unknown, fwd: Edge, reversed?: boolean } }

  for _, spec in ipairs(edge_specs) do
    local u, v, cap, cost = spec.u, spec.v, spec.cap, spec.cost
    nodes_set[u] = true
    nodes_set[v] = true
    local fwd = graph_add_edge(adj, u, v, cap, cost)
    edge_refs[#edge_refs + 1] = { spec = spec, fwd = fwd }
    if not spec.directed then
      -- undirected: second direction also carries capacity
      local fwd2 = graph_add_edge(adj, v, u, cap, cost)
      edge_refs[#edge_refs + 1] = { spec = spec, fwd = fwd2, reversed = true }
    end
  end

  local nodes = {}
  for n in pairs(nodes_set) do nodes[#nodes + 1] = n end

  return adj, nodes, edge_refs
end

function net_mt:add_edge(u, v, capacity, opts)
  opts = opts or {}
  self._specs[#self._specs + 1] = {
    u = u,
    v = v,
    cap = capacity,
    cost = opts.cost or 0,
    directed = opts.directed ~= false,  -- default directed=true
  }
  self._dirty = true
end

-- Rebuild adjacency list if dirty
function net_mt:_ensure_adj()
  if self._dirty or not self._adj then
    self._adj, self._nodes, self._edge_refs = build_adj(self._specs)
    self._dirty = false
  end
end

-- Reset all flows and edge specs, returning to empty network state
function net_mt:reset()
  self._specs = {}
  self._adj = nil
  self._nodes = nil
  self._edge_refs = nil
  self._dirty = true
end

-- max_flow(source, sink) -> flow_value, edge_flows_array
-- edge_flows_array: { {from, to, flow, capacity}, ... }
function net_mt:max_flow(source, sink)
  self:_ensure_adj()
  local adj = self._adj --[[:! Adj]]
  local edge_refs = self._edge_refs --[[:! { [integer]: { spec: unknown, fwd: Edge, reversed?: boolean } }]]

  -- Reset flows first
  for _, er in ipairs(edge_refs) do
    er.fwd.flow = 0
  end
  -- Also reset all reverse edges
  for node, edges in pairs(adj) do  --luacheck: ignore node
    for _, e in ipairs(edges) do
      e.flow = 0
    end
  end

  local total = edmonds_karp(adj, source, sink)

  -- Collect edge flows (only forward, positive-capacity edges from original specs)
  local flows = {}
  for _, er in ipairs(edge_refs) do
    local e = er.fwd
    -- Only report original forward edges (cap > 0)
    if e.cap > 0 then
      flows[#flows + 1] = {
        from = e.from,
        to = e.to,
        flow = e.flow,
        capacity = e.cap,
      }
    end
  end

  return total, flows
end

-- min_cut(source, sink) -> cut_value, s_side_set, t_side_set
function net_mt:min_cut(source, sink)
  -- Run max flow first (uses residual graph state)
  local cut_value = self:max_flow(source, sink)
  local adj = self._adj --[[:! Adj]]

  -- BFS on residual graph from source to find S-reachable nodes
  local visited = { [source] = true }
  local queue = { source }
  local head = 1

  while head <= #queue do
    local u = queue[head]; head = head + 1
    for _, e in ipairs(adj[u] or {}) do
      local v = e.to
      if not visited[v] and e.cap - e.flow > 0 then
        visited[v] = true
        queue[#queue + 1] = v
      end
    end
  end

  -- Build s_side and t_side
  local s_side = {}
  local t_side = {}
  for _, n in ipairs(self._nodes) do
    if visited[n] then
      s_side[#s_side + 1] = n
    else
      t_side[#t_side + 1] = n
    end
  end

  return cut_value, s_side, t_side
end

-- min_cost_flow(source, sink, opts) -> flow_value, total_cost
-- Uses successive shortest paths (SPFA).
-- opts.max_flow: limit flow to this amount (default: send as much as possible)
function net_mt:min_cost_flow(source, sink, opts)
  opts = opts or {}
  local max_f = opts.max_flow or INF

  self:_ensure_adj()
  local adj = self._adj --[[:! Adj]]
  local nodes = self._nodes --[[:! { [integer]: unknown }]]

  -- Reset all flows
  for _, edges in pairs(adj) do
    for _, e in ipairs(edges) do
      e.flow = 0
    end
  end

  local total_flow = 0 --: number
  local total_cost = 0 --: number

  while total_flow < max_f do
    local dist, prev = spfa(adj, nodes, source)
    if dist[sink] == nil or dist[sink] == INF then break end  -- no augmenting path

    -- Limit to remaining allowed flow
    local pushed, cost = augment_cost(adj, prev, source, sink)
    if total_flow + pushed > max_f then
      -- Would overshoot: partial augment
      local limit = max_f - total_flow
      -- Revert and re-augment with limit cap (simpler: just stop, flow is integer for typical use)
      -- For correctness, we do a proper partial push:
      -- Find bottleneck already found as 'pushed'; scale down
      -- We need to redo the augmentation with bottle=limit
      -- Undo what augment_cost did:
      local v = sink
      while v ~= source do
        local p = prev[v]
        local e = p.edge
        e.flow = e.flow - pushed
        adj[e.to][e.rev_idx].flow = adj[e.to][e.rev_idx].flow + pushed
        v = p.node
      end
      -- Redo with limit
      v = sink
      while v ~= source do
        local p = prev[v]
        local e = p.edge
        e.flow = e.flow + limit
        total_cost = total_cost + limit * e.cost
        adj[e.to][e.rev_idx].flow = adj[e.to][e.rev_idx].flow - limit
        v = p.node
      end
      total_flow = total_flow + limit
      break
    end

    total_flow = total_flow + pushed
    total_cost = total_cost + cost
  end

  return total_flow, total_cost
end

-- ========================
-- BIPARTITE MATCHING
-- ========================

-- Maximum bipartite matching via max flow.
-- opts: { left, right, edges }
--   left: array of left-side node identifiers
--   right: array of right-side node identifiers
--   edges: array of {left_node, right_node}
-- Returns: array of {left, right} matched pairs
function M.bipartite_matching(opts)
  local left = opts.left
  local right = opts.right
  local edges = opts.edges

  -- Build a flow network: super-source "S", super-sink "T"
  -- S -> each left node (cap 1)
  -- each right node -> T (cap 1)
  -- each bipartite edge -> (cap 1)
  local adj = new_graph()
  local S = "__S__"
  local T = "__T__"

  for _, l in ipairs(left) do
    graph_add_edge(adj, S, "L:" .. tostring(l), 1, 0)
  end
  for _, r in ipairs(right) do
    graph_add_edge(adj, "R:" .. tostring(r), T, 1, 0)
  end
  for _, e in ipairs(edges) do
    graph_add_edge(adj, "L:" .. tostring(e[1]), "R:" .. tostring(e[2]), 1, 0)
  end

  -- Run max flow
  edmonds_karp(adj, S, T)

  -- Collect matching: forward edges from L: to R: with flow=1
  local matching = {}
  for _, ledges in pairs(adj) do
    for _, e in ipairs(ledges) do
      if e.flow == 1 and e.cap == 1 then
        local f = e.from --[[:! string]]
        local t = e.to --[[:! string]]
        -- Only L:... -> R:... edges
        if f:sub(1, 2) == "L:" and t:sub(1, 2) == "R:" then
          matching[#matching + 1] = {
            left = f:sub(3),
            right = t:sub(3),
          }
        end
      end
    end
  end

  return matching
end

-- max_matching_size(opts) -> number
function M.max_matching_size(opts)
  return #M.bipartite_matching(opts)
end

-- ========================
-- NETWORK CONSTRUCTOR
-- ========================

function M.network()
  local net = setmetatable({}, net_mt)
  net._specs = {}
  net._adj = nil
  net._nodes = nil
  net._edge_refs = nil
  net._dirty = true
  return net
end

return M
